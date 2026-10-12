@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-SystemInformer.ps1" %*
set "result=%errorlevel%"
if errorlevel 1 pause
exit /b %result%
