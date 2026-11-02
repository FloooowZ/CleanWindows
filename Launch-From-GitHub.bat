@echo off
rem Downloads the latest version from GitHub and runs it (the script asks for admin rights)
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/FloooowZ/CleanWindows/main/AllInOne-CleanWindows-Standalone.ps1' -OutFile $env:TEMP\a.ps1; & $env:TEMP\a.ps1"
