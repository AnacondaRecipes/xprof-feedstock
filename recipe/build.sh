#!/bin/bash
set -exuo pipefail

# Conda-compiler crosstool for bazel (from the bazel-toolchain package)
source gen-bazel-toolchain

# ---------- DEBUG (bring-up only; remove before release) ----------
# Everything to stderr: build-task stdout does not reliably interleave in PBP
# logs (learned during iteration 2 of this bring-up).
{
  echo "=== DEBUG: host ==="
  uname -a || true
  echo "uname -m -> '$(uname -m)' (rc=$?)"
  echo "=== DEBUG: tools ==="
  for t in uname bazel gcc cc node python git curl; do
    echo "  $t -> $(command -v $t || echo MISSING)"
  done
  bazel version || true
  echo "=== DEBUG: resources ==="
  nproc || true; free -g || true; df -h "${SRC_DIR}" /tmp || true
  echo "=== DEBUG: PATH ==="
  echo "$PATH" | tr ':' '\n'
  echo "=== DEBUG: env (secrets filtered) ==="
  env | sort | grep -viE 'token|secret|key|password|credential' || true
  echo "=== DEBUG: end ==="
} 1>&2
# -------------------------------------------------------------------

# conda's bazel extracts its embedded helpers (process-wrapper, linux-sandbox)
# into the output base, where their $ORIGIN/../lib RPATH no longer resolves the
# conda env's libprotobuf — every repository-rule subprocess then dies with
# rc 127 / empty stdout. Make the env libs visible to those helpers.
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

mkdir -p "${SRC_DIR}/bazel_output_base"

# conda bazel's extracted helper binaries (process-wrapper, linux-sandbox, ...)
# carry a leaked, unrelocated build-prefix RPATH (bazel-feedstock bug), so they
# cannot load the env's libprotobuf. Env plumbing cannot fix rules that declare
# their own action env (rules_nodejs rollup does), so repair the RPATH in
# place. Linux-only: the repair is ELF-specific; revisit for Mach-O if the
# osx-arm64 lane shows the same loader failure.
bazel --output_user_root="${SRC_DIR}/bazel_output_base" version 1>&2
INSTALL_BASE=$(bazel --output_user_root="${SRC_DIR}/bazel_output_base" info install_base)
{ echo "=== DEBUG: install_base=$INSTALL_BASE"; ls "$INSTALL_BASE" | head -30; } 1>&2
for b in process-wrapper linux-sandbox build-runfiles daemonize libcpu_profiler.dylib; do
  if [ -f "$INSTALL_BASE/$b" ]; then
    # bazel validates its install base by comparing the far-future mtimes it
    # stamps at extraction; preserve and restore them or startup FATALs with
    # "corrupt installation: file ... missing or modified"
    touch -r "$INSTALL_BASE/$b" "${SRC_DIR}/.mtime_ref_$b"
    if [[ "$(uname)" == "Linux" ]]; then
      { echo "=== DEBUG: $b RPATH BEFORE patch:"; readelf -d "$INSTALL_BASE/$b" | grep -E 'RPATH|RUNPATH' || true; } 1>&2
      patchelf --set-rpath "${BUILD_PREFIX}/lib" "$INSTALL_BASE/$b" 1>&2 || echo "patchelf failed on $b" 1>&2
    else
      { echo "=== DEBUG: $b LC_RPATH BEFORE patch:"; otool -l "$INSTALL_BASE/$b" | grep -A2 LC_RPATH || true; } 1>&2
      install_name_tool -add_rpath "${BUILD_PREFIX}/lib" "$INSTALL_BASE/$b" 1>&2 || echo "install_name_tool failed on $b" 1>&2
      # modifying a Mach-O invalidates its signature; arm64 macOS kills
      # unsigned binaries, so re-sign ad hoc
      codesign -f -s - "$INSTALL_BASE/$b" 1>&2 || echo "codesign failed on $b" 1>&2
    fi
    touch -r "${SRC_DIR}/.mtime_ref_$b" "$INSTALL_BASE/$b"
  fi
done

# Upstream's README suggests `--config=public_cache` (Google's public remote
# build cache). Deliberately NOT used: every action is compiled locally so the
# shipped binaries are attested-from-source — the entire point of this recipe.
# --repo_env=PATH: propagate PATH into repository rules so rules_nodejs's
# `uname -m` probe resolves (it returned empty on PBP without it).
# macOS: upstream's `macos` bazelrc config supplies the apple platform type
# and linker opts, but its local_config_apple_cc crosstool needs full Xcode
# (empty toolchain on CLT-only machines). Override the crosstool to the conda
# clang toolchain gen-bazel-toolchain generated at //bazel_toolchain
# (tensorflow-feedstock pattern), and pin the arm64 CPU — without it,
# resolution targets macos_x86_64.
# HERMETIC_PYTHON_VERSION selects upstream's requirements lockfile AND (on
# platforms without a downloadable hermetic interpreter, e.g. osx-arm64) must
# match the host python actually running pip. Upstream ships lockfiles for
# 3.10-3.13 only; py3.14 uses the 3.13 lockfile (its floors accept 3.14).
case "${PY_VER}" in
  3.10|3.11|3.12|3.13) HERMETIC_PY="${PY_VER}" ;;
  *)                   HERMETIC_PY=3.13 ;;  # newest upstream lockfile
esac

EXTRA_BAZEL_FLAGS=""
if [[ "$(uname)" == "Darwin" ]]; then
  # upstream's build_pip_package.sh uses `gcp` (GNU cp) on Darwin; conda's
  # coreutils ships GNU cp unprefixed, so provide the expected name
  ln -sf "${BUILD_PREFIX}/bin/cp" "${BUILD_PREFIX}/bin/gcp"
  python3 - <<'PYEOF'
# bazel-toolchain bakes one SDK version into the builtin-include list, but
# clang may resolve a different installed SDK; declare the CLT SDKs parent
# prefix (bazel treats entries as directory prefixes) so strict-header
# validation accepts whichever SDK the compiler actually used. Insert ONLY
# inside cxx_builtin_include_directories list literals (validation-only) —
# the same SDK path also appears in compile-flag lists where a bare entry
# becomes a stray compiler argument.
list_anchor = "cxx_builtin_include_directories = ["
sdk_line = '\n            "/Library/Developer/CommandLineTools/SDKs",'
for cfg in ("bazel_toolchain/cc_toolchain_config.bzl",
            "bazel_toolchain/cc_toolchain_build_config.bzl"):
    s = open(cfg).read()
    assert list_anchor in s, "list anchor missing in " + cfg
    open(cfg, "w").write(s.replace(list_anchor, list_anchor + sdk_line))
PYEOF
  # --macos_cpus: apple rule transitions default to x86_64 regardless of --cpu.
  # -Qunused-arguments: .S files inherit -stdlib=libc++ from the crosstool and
  # rules that add bare -Werror (boringssl) turn the unused-arg warning fatal.
  EXTRA_BAZEL_FLAGS="--config=macos --crosstool_top=//bazel_toolchain:toolchain --host_crosstool_top=//bazel_toolchain:toolchain --cpu=darwin_arm64 --host_cpu=darwin_arm64 --macos_cpus=arm64 --copt=-Qunused-arguments --host_copt=-Qunused-arguments"
fi

bazel --output_user_root="${SRC_DIR}/bazel_output_base" \
  run \
  --verbose_failures \
  --announce_rc \
  ${EXTRA_BAZEL_FLAGS} \
  --jobs=${CPU_COUNT} \
  --repo_env=PATH \
  --repo_env=HERMETIC_PYTHON_VERSION=${HERMETIC_PY} \
  --action_env=LD_LIBRARY_PATH \
  --host_action_env=LD_LIBRARY_PATH \
  //plugin:build_pip_package -- --output "${SRC_DIR}/pip_pkg_out"

# DEBUG (bring-up only): show what the build produced before installing
{ echo "=== DEBUG: pip_pkg_out contents ==="; find "${SRC_DIR}/pip_pkg_out" -maxdepth 3 | head -60; } 1>&2

# build_pip_package assembles the package tree (setup.py, python sources,
# locally-built profiler_plugin_c_api.so, frontend bundle + trace-viewer wasm)
cd "${SRC_DIR}/pip_pkg_out"
${PYTHON} -m pip install . -vv --no-deps --no-build-isolation

bazel shutdown || true
