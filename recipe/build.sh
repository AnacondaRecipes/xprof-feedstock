#!/bin/bash
set -exuo pipefail

# Conda-compiler crosstool for bazel (from the bazel-toolchain package)
source gen-bazel-toolchain

# bazel's extracted helper binaries (process-wrapper, ...) carry a leaked
# build-time RPATH (bazel-feedstock bug) and cannot load the env's libprotobuf;
# some rules also scrub the action env, so repair the RPATH in the binaries.
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

mkdir -p "${SRC_DIR}/bazel_output_base"
bazel --output_user_root="${SRC_DIR}/bazel_output_base" version >/dev/null
INSTALL_BASE=$(bazel --output_user_root="${SRC_DIR}/bazel_output_base" info install_base)
for b in process-wrapper linux-sandbox build-runfiles daemonize libcpu_profiler.dylib; do
  if [ -f "$INSTALL_BASE/$b" ]; then
    # preserve mtimes: bazel validates its install base by the far-future
    # mtimes stamped at extraction ("corrupt installation" FATAL otherwise)
    touch -r "$INSTALL_BASE/$b" "${SRC_DIR}/.mtime_ref_$b"
    if [[ "$(uname)" == "Linux" ]]; then
      patchelf --set-rpath "${BUILD_PREFIX}/lib" "$INSTALL_BASE/$b"
    else
      install_name_tool -add_rpath "${BUILD_PREFIX}/lib" "$INSTALL_BASE/$b"
      # re-sign: arm64 macOS kills signature-invalidated binaries
      codesign -f -s - "$INSTALL_BASE/$b"
    fi
    touch -r "${SRC_DIR}/.mtime_ref_$b" "$INSTALL_BASE/$b"
  fi
done

# HERMETIC_PYTHON_VERSION selects upstream's requirements lockfile and, on
# platforms without a downloadable hermetic interpreter (osx-arm64), must
# match the host python that runs pip. Lockfiles exist for 3.10-3.13 only.
case "${PY_VER}" in
  3.10|3.11|3.12|3.13) HERMETIC_PY="${PY_VER}" ;;
  *)                   HERMETIC_PY=3.13 ;;  # newest upstream lockfile
esac

EXTRA_BAZEL_FLAGS=""
if [[ "$(uname)" == "Darwin" ]]; then
  # upstream's build_pip_package.sh calls `gcp` (GNU cp) on Darwin; conda's
  # coreutils ships GNU cp unprefixed
  ln -sf "${BUILD_PREFIX}/bin/cp" "${BUILD_PREFIX}/bin/gcp"
  # bazel-toolchain bakes one SDK version into the crosstool's builtin-include
  # (strict-header validation) lists, but clang may resolve a different
  # installed SDK; declare the CLT SDKs parent prefix in those lists only
  python3 - <<'PYEOF'
list_anchor = "cxx_builtin_include_directories = ["
sdk_line = '\n            "/Library/Developer/CommandLineTools/SDKs",'
for cfg in ("bazel_toolchain/cc_toolchain_config.bzl",
            "bazel_toolchain/cc_toolchain_build_config.bzl"):
    s = open(cfg).read()
    assert list_anchor in s, "list anchor missing in " + cfg
    open(cfg, "w").write(s.replace(list_anchor, list_anchor + sdk_line))
PYEOF
  # upstream `macos` config + conda clang crosstool (local_config_apple_cc
  # needs full Xcode); pin arm64 on all three cpu knobs (apple transitions
  # default to x86_64). -Qunused-arguments: .S files inherit -stdlib=libc++
  # from the crosstool and boringssl adds bare -Werror.
  EXTRA_BAZEL_FLAGS="--config=macos --crosstool_top=//bazel_toolchain:toolchain --host_crosstool_top=//bazel_toolchain:toolchain --cpu=darwin_arm64 --host_cpu=darwin_arm64 --macos_cpus=arm64 --copt=-Qunused-arguments --host_copt=-Qunused-arguments"
fi

# Upstream's suggested --config=public_cache (Google's remote build cache) is
# deliberately NOT used: every action is compiled locally so the shipped
# binaries are attested-from-source. --repo_env=PATH lets repository-rule
# subprocesses (uname, node, python) resolve tools.
# -c opt --strip=always: bazel defaults to fastbuild (unoptimized, unstripped);
# ship an optimized, stripped native library like upstream's own wheels
# (fastbuild made profiler_plugin_c_api.so ~220 MB and slower on the hot path)
bazel --output_user_root="${SRC_DIR}/bazel_output_base" \
  run \
  --verbose_failures \
  -c opt \
  --strip=always \
  ${EXTRA_BAZEL_FLAGS} \
  --jobs=${CPU_COUNT} \
  --repo_env=PATH \
  --repo_env=HERMETIC_PYTHON_VERSION=${HERMETIC_PY} \
  --action_env=LD_LIBRARY_PATH \
  --host_action_env=LD_LIBRARY_PATH \
  //plugin:build_pip_package -- --output "${SRC_DIR}/pip_pkg_out"

# assembled tree: setup.py, python sources, locally built native library,
# frontend bundle + trace-viewer wasm
cd "${SRC_DIR}/pip_pkg_out"
# drop __pycache__ from the build env's python (3.14) so the artifact carries
# only the variant-python bytecode pip compiles below
find . -name __pycache__ -type d -prune -exec rm -rf {} +
${PYTHON} -m pip install . -vv --no-deps --no-build-isolation

bazel shutdown || true
