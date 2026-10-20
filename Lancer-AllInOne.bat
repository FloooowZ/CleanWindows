@echo off
rem Lance le script en Administrateur avec ExecutionPolicy Bypass (double-clic)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0AllInOne-CleanWindows-Standalone.ps1\"'"
