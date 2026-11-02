@echo off
rem Launches the script as Administrator with ExecutionPolicy Bypass (double-click)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0AllInOne-CleanWindows-Standalone.ps1\"'"
