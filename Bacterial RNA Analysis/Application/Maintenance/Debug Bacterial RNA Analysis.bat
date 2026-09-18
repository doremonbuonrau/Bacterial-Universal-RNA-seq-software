@echo off
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0..\App\rnaseq_gui.ps1"
pause
