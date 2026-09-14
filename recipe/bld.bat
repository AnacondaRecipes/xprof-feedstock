@echo on
setlocal enabledelayedexpansion

REM WIN-64 FROM-SOURCE SPIKE (PKG-18061). First attempt; expect iteration.
REM Modeled on jaxlib-feedstock (same XLA/Bazel-on-Windows problem): drive
REM bazel with conda clang-cl + the worker VS STL, since xprof's clang-cl
REM toolchain is otherwise a pinned XLA RBE win2022 toolchain.

REM Short output root: bazel on Windows hits MAX_PATH (260) with deep trees.
set "BZLROOT=C:/bzlroot"

REM VS provides the MSVC STL/headers; conda clangdev provides clang-cl.
set "BAZEL_VS=%VSINSTALLDIR%"
set "BAZEL_VC=%VSINSTALLDIR%\VC"
set "BAZEL_LLVM=%BUILD_PREFIX:\=/%/Library/"
set "CLANG_COMPILER_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang.exe"
REM bazel's def-file/genrule actions shell out to bash (msys2-bash).
set "BAZEL_SH=%BUILD_PREFIX:\=/%/Library/usr/bin/bash.exe"

REM Upstream requirements lockfiles exist for 3.10-3.13 only; py3.14 uses 3.13.
set "HERMETIC_PY=%PY_VER%"
if "%PY_VER%"=="3.14" set "HERMETIC_PY=3.13"

bazel --output_user_root=%BZLROOT% run ^
  --verbose_failures ^
  --config=windows ^
  --compiler=clang-cl ^
  --action_env=CLANG_COMPILER_PATH="%CLANG_COMPILER_PATH%" ^
  --repo_env=CC="%CLANG_COMPILER_PATH%" ^
  -c opt ^
  --enable_runfiles ^
  --experimental_ui_max_stdouterr_bytes=8000000 ^
  --jobs=%CPU_COUNT% ^
  --repo_env=PATH ^
  --repo_env=HERMETIC_PYTHON_VERSION=%HERMETIC_PY% ^
  //plugin:build_pip_package -- --output "%SRC_DIR%\pip_pkg_out"
if errorlevel 1 exit 1

cd /d "%SRC_DIR%\pip_pkg_out"
"%PYTHON%" -m pip install . -vv --no-deps --no-build-isolation
if errorlevel 1 exit 1

bazel --output_user_root=%BZLROOT% shutdown
