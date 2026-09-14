@echo on
setlocal enabledelayedexpansion

REM ---- Reclaim disk first (workers persist; prior runs leave GBs) ----
for /f %%F in ('powershell -NoProfile -Command "[math]::Floor((Get-PSDrive C).Free/1GB)"') do set "PRE=%%F"
echo Free before cleanup: %PRE% GB
REM stale bazel output from earlier runs (we use a fixed output_user_root)
if exist C:\bzlroot rmdir /s /q C:\bzlroot 2>nul
REM conda package cache / unused tarballs (re-downloaded on demand)
call conda clean --all --yes 2>nul
REM user + system temp
del /q /s "%TEMP%\*" 2>nul
if exist "C:\Windows\Temp" del /q /s "C:\Windows\Temp\*" 2>nul
for /f %%F in ('powershell -NoProfile -Command "[math]::Floor((Get-PSDrive C).Free/1GB)"') do set "POST=%%F"
echo Free after cleanup: %POST% GB

REM ---- Fail fast if the worker lacks disk for the XLA source build ----
REM The bazel tree + npm + emsdk need tens of GB; some win workers start with
REM only ~5 GB free. Enumerate volumes (so we can see a roomier drive) and
REM bail in seconds rather than dying an hour into the compile. Rerun the task
REM to land on a worker with enough space.
powershell -NoProfile -Command "Get-PSDrive -PSProvider FileSystem | Select-Object Name,@{n='FreeGB';e={[math]::Floor($_.Free/1GB)}},@{n='UsedGB';e={[math]::Floor($_.Used/1GB)}} | Format-Table -AutoSize"
for /f %%F in ('powershell -NoProfile -Command "[math]::Floor((Get-PSDrive C).Free/1GB)"') do set "FREEGB=%%F"
echo Free on C: %FREEGB% GB
if %FREEGB% LSS 25 (
  echo ERROR: insufficient disk for the XLA source build ^(need ~25 GB, have %FREEGB% GB^). Rerun to land on a roomier worker.
  exit 1
)

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
REM Force bazels Windows cc autoconf to use clang-cl (conda clangdev) rather
REM than cl.exe: XLA is validated with clang-cl and cl.exe fails per-TU
REM (e.g. sycl C2370). BAZEL_LLVM above points the toolchain at conda clang.
set "USE_CLANG_CL=1"
REM bazel's def-file/genrule actions shell out to bash (msys2-bash).
set "BAZEL_SH=%BUILD_PREFIX:\=/%/Library/usr/bin/bash.exe"

REM Upstream requirements lockfiles exist for 3.10-3.13 only; py3.14 uses 3.13.
REM yarn postinstall runs `python3 patch_keys.py`; Windows conda ships
REM python.exe, not python3.exe. Copy python.exe -> python3.exe into every
REM dir that may be on the effective PATH (host env, build env, and the
REM host env, next to its stdlib).
REM Only beside the real python (+ its stdlib): a python3.exe copy placed in
REM msys /usr/bin cannot find its stdlib ("No module named encodings").
for %%D in ("%PREFIX%" "%BUILD_PREFIX%") do (
  if exist "%%~D\python.exe" copy /Y "%%~D\python.exe" "%%~D\python3.exe" >nul
)

set "HERMETIC_PY=%PY_VER%"
if "%PY_VER%"=="3.14" set "HERMETIC_PY=3.13"

REM ---------- DEBUG (spike bring-up; remove before release) ----------
echo === DEBUG: host / tools ===
ver
echo where python / python3 / bash / clang / clang-cl / bazel / node / yarn:
where python 2>&1
where python3 2>&1
where bash 2>&1
where clang 2>&1
where clang-cl 2>&1
where bazel 2>&1
where node 2>&1
where yarn 2>&1
python --version 2>&1
"%BAZEL_SH%" -c "uname -a; which python3 bash node yarn" 2>&1
echo === DEBUG: env ===
echo BUILD_PREFIX=%BUILD_PREFIX%
echo PREFIX=%PREFIX%
echo SRC_DIR=%SRC_DIR%
echo PY_VER=%PY_VER%  CPU_COUNT=%CPU_COUNT%  HERMETIC_PY=%HERMETIC_PY%
echo VSINSTALLDIR=%VSINSTALLDIR%
echo BAZEL_VS=%BAZEL_VS%
echo BAZEL_VC=%BAZEL_VC%
echo BAZEL_LLVM=%BAZEL_LLVM%
echo CLANG_COMPILER_PATH=%CLANG_COMPILER_PATH%
echo BAZEL_SH=%BAZEL_SH%
echo === DEBUG: PATH ===
echo %PATH%
echo === DEBUG: free space on C: ===
dir C:\ | findstr /C:"bytes free"
echo === DEBUG END ===
REM ------------------------------------------------------------------

REM cl.exe ignores the base .bazelrc clang-style -std=c++17; the /std:c++17
REM below is the MSVC spelling (clang-cl accepts it too) for absl C++17.
bazel --output_user_root=%BZLROOT% run ^
  --verbose_failures ^
  --config=windows ^
  --cxxopt=/std:c++17 ^
  --host_cxxopt=/std:c++17 ^
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
