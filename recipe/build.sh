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
  bazel --version || true
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
# carry an $ORIGIN-relative RPATH that breaks after extraction, so they cannot
# load the env's libprotobuf. Env plumbing cannot fix rules that declare their
# own action env (rules_nodejs rollup does), so repair the RPATH in place.
bazel --output_user_root="${SRC_DIR}/bazel_output_base" version 1>&2
INSTALL_BASE=$(bazel --output_user_root="${SRC_DIR}/bazel_output_base" info install_base)
{ echo "=== DEBUG: install_base=$INSTALL_BASE"; ls "$INSTALL_BASE" | head -30; } 1>&2
for b in process-wrapper linux-sandbox build-runfiles daemonize; do
  if [ -f "$INSTALL_BASE/$b" ]; then
    { echo "=== DEBUG: $b linkage BEFORE patch:"; readelf -d "$INSTALL_BASE/$b" | grep -E 'RPATH|RUNPATH|NEEDED' || true; } 1>&2
    patchelf --set-rpath "${BUILD_PREFIX}/lib" "$INSTALL_BASE/$b" 1>&2 || echo "patchelf failed on $b" 1>&2
  fi
done

# Upstream's README suggests `--config=public_cache` (Google's public remote
# build cache). Deliberately NOT used: every action is compiled locally so the
# shipped binaries are attested-from-source — the entire point of this recipe.
# --repo_env=PATH: propagate PATH into repository rules so rules_nodejs's
# `uname -m` probe resolves (it returned empty on PBP without it).
bazel --output_user_root="${SRC_DIR}/bazel_output_base" \
  run \
  --verbose_failures \
  --announce_rc \
  --jobs=${CPU_COUNT} \
  --repo_env=PATH \
  --repo_env=HERMETIC_PYTHON_VERSION=${PY_VER} \
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
