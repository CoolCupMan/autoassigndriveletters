@echo off
rem Runs the PowerShell script version without compiling it (it elevates itself).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\AutoAssignDriveLetters.ps1" %*
