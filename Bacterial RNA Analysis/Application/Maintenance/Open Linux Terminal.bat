@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "DISTRO_FILE=%~dp0..\App\environment\.wsl_distro"
set "DISTRO="
if exist "%DISTRO_FILE%" set /p DISTRO=<"%DISTRO_FILE%"
if defined DISTRO (
  wsl.exe -d "%DISTRO%" -- /bin/true >nul 2>&1
  if errorlevel 1 set "DISTRO="
)
if not defined DISTRO (
  for /f "usebackq delims=" %%D in (`wsl.exe --list --quiet 2^>nul`) do (
    if not defined DISTRO (
      wsl.exe -d "%%D" -- /bin/true >nul 2>&1
      if not errorlevel 1 set "DISTRO=%%D"
    )
  )
)
if defined DISTRO (wsl.exe -d "%DISTRO%") else (wsl.exe)
