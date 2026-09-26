@echo off
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
echo Ozen: setting up this computer to write captions for the phone. Please wait...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$d=Join-Path $env:TEMP 'ozen-setup'; Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue; New-Item -ItemType Directory $d | Out-Null;" ^
  "$z=Join-Path $d 'server.zip';" ^
  "Invoke-WebRequest -UseBasicParsing 'https://github.com/arbel-source-org/ozen/releases/latest/download/ozen-home-server.zip' -OutFile $z;" ^
  "Expand-Archive $z $d;" ^
  "& (Join-Path $d 'setup-windows.ps1')"
if errorlevel 1 (
    echo.
    echo Setting up did not finish. Please send a photo of this window to whoever gave you Ozen.
    pause
)
