@echo off
REM ============================================================
REM compila.bat - Build script for Nim LlamaServer Chatbot
REM ============================================================
REM
REM Usage:
REM   compila            -> builds webui_only.exe (browser only, no TUI)
REM   compila tui        -> builds chatbot_main.exe (full TUI version)
REM   compila both       -> builds both versions
REM   compila clean      -> removes both executables
REM
REM Common flags for both builds:
REM   --threads:on       -> required by httpdserver (createThread)
REM   --define:ssl       -> required for HTTPS remote providers
REM   --path:"my_include" -> module search path
REM   --path:"webui"     -> module search path
REM
REM The webui-only build excludes illwill (TUI library), resulting
REM in a smaller binary with no terminal UI dependency.
REM ============================================================

set FLAGS=--threads:on --path:"my_include" --path:"webui" --define:ssl

if /I "%1"=="tui" goto tui
if /I "%1"=="both" goto both
if /I "%1"=="clean" goto clean
goto webui

:webui
echo.
echo === Building webui_only.exe (browser only, no TUI) ===
echo.
nim c %FLAGS% --out:"webui_only.exe" webui_only.nim
if %ERRORLEVEL% neq 0 (
  echo.
  echo [ERROR] webui_only build failed! (code %ERRORLEVEL%)
  exit /b %ERRORLEVEL%
)
echo.
echo [OK] webui_only.exe created
goto end

:tui
echo.
echo === Building chatbot_main.exe (full TUI version) ===
echo.
nim c %FLAGS% --out:"chatbot_main.exe" main.nim
if %ERRORLEVEL% neq 0 (
  echo.
  echo [ERROR] TUI build failed! (code %ERRORLEVEL%)
  exit /b %ERRORLEVEL%
)
echo.
echo [OK] chatbot_main.exe created
goto end

:both
echo.
echo === Building BOTH versions ===
echo.
call :build_webui
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
call :build_tui
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo.
echo [OK] Both executables built successfully
goto end

:clean
echo.
echo === Cleaning executables ===
echo.
if exist webui_only.exe (
  del webui_only.exe
  echo [OK] webui_only.exe deleted
)
if exist chatbot_main.exe (
  del chatbot_main.exe
  echo [OK] chatbot_main.exe deleted
)
echo.
goto end

:build_webui
nim c %FLAGS% --out:"webui_only.exe" webui_only.nim
exit /b %ERRORLEVEL%

:build_tui
nim c %FLAGS% --out:"chatbot_main.exe" main.nim
exit /b %ERRORLEVEL%

:end
