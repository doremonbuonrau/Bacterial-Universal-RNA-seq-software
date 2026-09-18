@echo off
setlocal
cd /d "%~dp0"
echo Starting the OpDetect Windows environment check and repair...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\App\start_opdetect_windows.ps1"
if errorlevel 1 (
  echo.
  echo The launcher reported an error. Review the messages above.
  pause
)
endlocal
