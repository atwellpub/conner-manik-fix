@echo off
rem Builds dist\MANIK-Keyboard-Fix.exe. See build.ps1 for details.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1"
echo.
pause
