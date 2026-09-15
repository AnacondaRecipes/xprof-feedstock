@echo on
setlocal enabledelayedexpansion

REM ===================================================================
REM win-64 from-source build (PKG-18061). XLA/Bazel-on-Windows toolchain:
REM conda clang-cl + VS2022 STL. Validated from source on a dev instance
REM (peak disk ~36 GB, ~90 min) -> xprof-2.23.1-py312hd7fb8db_1.conda,
REM imports + CLI OK. This spike branch builds win-64 on CI to probe whether
REM any worker has enough disk; the release recipe (with win skipped) is #2.
REM ===================================================================

REM ---- Reclaim disk (PBP win workers persist between tasks) ----
if exist C:\bzlroot rmdir /s /q C:\bzlroot 2>nul
call conda clean --all --yes 2>nul

REM ---- Fail fast if this worker lacks disk (the XLA tree needs ~36 GB) ----
REM Enumerate all volumes (a roomier secondary drive would show here) and bail
REM in seconds rather than an hour into the compile. Rerun to re-roll workers.
powershell -NoProfile -Command "Get-PSDrive -PSProvider FileSystem | Select-Object Name,@{n='FreeGB';e={[math]::Floor($_.Free/1GB)}},@{n='UsedGB';e={[math]::Floor($_.Used/1GB)}} | Format-Table -AutoSize"
for /f %%F in ('powershell -NoProfile -Command "[math]::Floor((Get-PSDrive C).Free/1GB)"') do set "FREEGB=%%F"
echo Free on C: %FREEGB% GB
if %FREEGB% LSS 38 (
  echo ERROR: insufficient disk for the XLA source build ^(need ~36 GB, have %FREEGB% GB^). Rerun to land on a roomier worker.
  exit 1
)

REM VS provides the MSVC STL/headers; conda clangdev provides clang-cl.
set "BAZEL_VS=%VSINSTALLDIR%"
set "BAZEL_VC=%VSINSTALLDIR%\VC"
set "BAZEL_LLVM=%BUILD_PREFIX:\=/%/Library/"
set "CLANG_COMPILER_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang.exe"
REM Force bazel's Windows cc autoconf to clang-cl (XLA is validated with
REM clang-cl; cl.exe fails per-TU). BAZEL_LLVM points it at conda clang.
set "USE_CLANG_CL=1"
REM bazel shells out to bash for def-file/genrule actions (jaxlib pattern).
set "BAZEL_SH=%BUILD_PREFIX:\=/%/Library/usr/bin/bash.exe"

REM yarn frontend postinstall calls `python3`; conda ships python.exe only.
for %%D in ("%PREFIX%" "%BUILD_PREFIX%") do (
  if exist "%%~D\python.exe" copy /Y "%%~D\python.exe" "%%~D\python3.exe" >nul
)

set "HERMETIC_PY=%PY_VER%"
if "%PY_VER%"=="3.14" set "HERMETIC_PY=3.13"

REM Short output root: bazel on Windows hits MAX_PATH (260) with deep trees.
set "BZLROOT=C:/bzlroot"

REM build_pip_package.sh (MSYS branch) does dest="/c$OUTPUT_DIR": it wants a
REM drive-less forward-slash path. Convert %SRC_DIR% (C:\...\work) accordingly.
set "SRC_FWD=%SRC_DIR:\=/%"
set "PIPOUT_MSYS=%SRC_FWD:~2%/pip_pkg_out"

REM ---- Materialize external repos so we can patch them before compiling ----
REM net_zstd / emsdk come from bazel http_archives, not the xprof source tree,
REM so a recipe patch can't reach them; patch them post-fetch, pre-compile.
bazel --output_user_root=%BZLROOT% fetch //plugin:build_pip_package
if errorlevel 1 exit 1

for /f "usebackq delims=" %%B in (`bazel --output_user_root=%BZLROOT% info output_base`) do set "OBASE=%%B"

REM (1) net_zstd/BUILD globs decompress/*_amd64.S for any x86_64, but that
REM GAS/AT&T asm can't be assembled by MSVC's MASM (A2044/A1012). Windows uses
REM zstd's pure-C decode path, so strip the .S from the zstd srcs (win-only).
powershell -NoProfile -Command "$f='%OBASE%/external/net_zstd/BUILD.bazel'; if(Test-Path $f){$c=[IO.File]::ReadAllText($f); $n=$c.Replace('glob([\"decompress/*_amd64.S\"])','[]'); [IO.File]::WriteAllText($f,$n); if($n -ne $c){Write-Host ZSTD-PATCHED}else{Write-Host ZSTD-PATTERN-UNCHANGED}}else{Write-Host ZSTD-BUILD-NOT-FOUND}"

REM (2) emsdk's emcc/emar/emcc_link .bat call `py -3` (Windows Python Launcher),
REM which conda doesn't provide. Repoint them at the host python (%PYTHON% =
REM _h_env; python is a host dep) by absolute path (the emcc action's PATH does
REM not include the env root, so a bare `python` would not resolve).
powershell -NoProfile -Command "$py=$env:PYTHON; $d='%OBASE%/external/emsdk/emscripten_toolchain'; if(Test-Path $d){Get-ChildItem (Join-Path $d '*.bat') | ForEach-Object { $c=[IO.File]::ReadAllText($_.FullName); $n=$c.Replace('py -3',('\"'+$py+'\"')); if($n -ne $c){[IO.File]::WriteAllText($_.FullName,$n); Write-Host ('EMCC-PATCHED '+$_.Name)} }}else{Write-Host EMSDK-DIR-NOT-FOUND}"

REM C++17 for clang-cl via the _CL_ env var (read only by MSVC-family compilers;
REM emscripten's clang ignores it, so /std:c++17 never leaks into the WASM
REM cross-compile toolchain). Mirrors upstream .bazelrc's ci_windows_amd64.
bazel --output_user_root=%BZLROOT% run ^
  --verbose_failures ^
  --config=windows ^
  --action_env=_CL_="/std:c++17 /Zc:__cplusplus" ^
  --host_action_env=_CL_="/std:c++17 /Zc:__cplusplus" ^
  --compiler=clang-cl ^
  --action_env=CLANG_COMPILER_PATH="%CLANG_COMPILER_PATH%" ^
  --repo_env=CC="%CLANG_COMPILER_PATH%" ^
  -c opt ^
  --enable_runfiles ^
  --experimental_ui_max_stdouterr_bytes=8000000 ^
  --jobs=%CPU_COUNT% ^
  --repo_env=PATH ^
  --repo_env=HERMETIC_PYTHON_VERSION=%HERMETIC_PY% ^
  //plugin:build_pip_package -- --output "%PIPOUT_MSYS%"
if errorlevel 1 exit 1

cd /d "%SRC_DIR%\pip_pkg_out"
"%PYTHON%" -m pip install . -vv --no-deps --no-build-isolation
if errorlevel 1 exit 1

bazel --output_user_root=%BZLROOT% shutdown
