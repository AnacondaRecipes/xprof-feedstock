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

mkdir -p "${SRC_DIR}/bazel_output_base"

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
  //plugin:build_pip_package -- --output "${SRC_DIR}/pip_pkg_out"

# DEBUG (bring-up only): show what the build produced before pip install
{ echo "=== DEBUG: pip_pkg_out contents ==="; find "${SRC_DIR}/pip_pkg_out" -maxdepth 3 | head -60; } 1>&2

# build_pip_package assembles the package tree (setup.py, python sources,
# locally-built profiler_plugin_c_api.so, frontend bundle + trace-viewer wasm)
cd "${SRC_DIR}/pip_pkg_out"
${PYTHON} -m pip install . -vv --no-deps --no-build-isolation

bazel shutdown || true
