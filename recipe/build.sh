#!/bin/bash
set -exuo pipefail

# Conda-compiler crosstool for bazel (from the bazel-toolchain package)
source gen-bazel-toolchain

# rules_nodejs resolves the host arch by shelling out to `uname -m` inside a
# repository rule; surface the tool's availability in the log before bazel runs
command -v uname && uname -m

mkdir -p "${SRC_DIR}/bazel_output_base"

# Upstream's README suggests `--config=public_cache` (Google's public remote
# build cache). Deliberately NOT used: every action is compiled locally so the
# shipped binaries are attested-from-source — the entire point of this recipe.
# --repo_env=PATH: propagate PATH into repository rules so rules_nodejs's
# `uname -m` probe resolves (it returned empty on PBP without it).
bazel --output_user_root="${SRC_DIR}/bazel_output_base" \
  run \
  --verbose_failures \
  --jobs=${CPU_COUNT} \
  --repo_env=PATH \
  --repo_env=HERMETIC_PYTHON_VERSION=${PY_VER} \
  //plugin:build_pip_package -- --output "${SRC_DIR}/pip_pkg_out"

# build_pip_package assembles a pip-installable tree (setup.py, python sources,
# locally-built profiler_plugin_c_api.so, frontend bundle + trace-viewer wasm)
cd "${SRC_DIR}/pip_pkg_out"
${PYTHON} -m pip install . -vv --no-deps --no-build-isolation

bazel shutdown || true
