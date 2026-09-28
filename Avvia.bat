@echo off
rem Avvia Mostra-UsoUSB.ps1 rilevando automaticamente la chiavetta USB collegata.
rem Eventuali argomenti passati al .bat vengono inoltrati allo script (es. Avvia.bat -Chiudi).
title Mostra-UsoUSB
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Mostra-UsoUSB.ps1" %*
echo.
pause
