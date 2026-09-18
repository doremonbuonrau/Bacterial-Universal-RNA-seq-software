@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\App\environment\setup_windows_wsl.ps1"
if errorlevel 1 pause
