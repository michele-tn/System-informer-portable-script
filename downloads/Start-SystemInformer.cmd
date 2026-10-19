@echo off
rem Preview: Start-SystemInformer.cmd -Channel Canary -NoLaunch
rem Nightly is an alias for Canary. Default: Stable.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-SystemInformer.ps1" %*
set "result=%errorlevel%"
if errorlevel 1 pause
exit /b %result%
