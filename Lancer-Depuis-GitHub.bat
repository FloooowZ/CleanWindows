@echo off
rem Telecharge la derniere version depuis GitHub et la lance (le script demande les droits admin)
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/FloooowZ/CleanWindows/main/AllInOne-CleanWindows-Standalone.ps1' -OutFile $env:TEMP\a.ps1; & $env:TEMP\a.ps1"
