@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "APP_ROOT=%~dp0..\App"
set "DISTRO_FILE=%APP_ROOT%\environment\.wsl_distro"
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
if not defined DISTRO (
  echo No runnable WSL Linux distribution was found.
  echo Use Install or Repair from this Maintenance folder first.
  pause
  exit /b 1
)
for %%I in ("%APP_ROOT%") do set "APP_FULL=%%~fI"
set "DRIVE=!APP_FULL:~0,1!"
set "TAIL=!APP_FULL:~2!"
set "TAIL=!TAIL:\=/!"
for %%L in (a b c d e f g h i j k l m n o p q r s t u v w x y z) do if /i "!DRIVE!"=="%%L" set "DRIVE=%%L"
set "LINUX_APP=/mnt/!DRIVE!!TAIL!"
wsl.exe -d "%DISTRO%" -- /bin/bash "%LINUX_APP%/environment/check_environment.sh"
pause
