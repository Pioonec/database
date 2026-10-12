@echo off
cd /d "%~dp0"
if not exist node_modules call npm install
start "" /b powershell -NoProfile -WindowStyle Hidden -Command "Start-Sleep 4; Start-Process http://127.0.0.1:4173/"
node server.mjs
pause
