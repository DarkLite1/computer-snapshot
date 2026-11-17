@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA ^
    -File "%~dp0Engine\Scripts\Caller.ps1"
if errorlevel 1 pause