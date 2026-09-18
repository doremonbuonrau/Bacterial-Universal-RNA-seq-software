@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0App\differential_expression_gui.ps1"
endlocal
