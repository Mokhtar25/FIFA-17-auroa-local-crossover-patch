@echo off
rem FIFA 14 Windows capture WITHOUT the thread sampling (kit v4). Use this only if the
rem game fails to start with RUN-ME.cmd but starts normally without the capture.
rem It asks for administrator rights (so it may open the game), runs the
rem reference tests, then waits for you to start the game.
setlocal
cd /d "%~dp0"

rem -- already administrator? (net session only succeeds elevated)
net session >nul 2>&1
if errorlevel 1 (
  if defined CAP_NOELEVATE goto go
  echo Asking for administrator rights...
  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'" 2>nul
  if errorlevel 1 (
    echo.
    echo Could not elevate. Right-click RUN-ME.cmd and choose "Run as administrator".
    pause
  )
  exit /b
)

:go
title FIFA 14 capture
bin\fifa14cap.exe --nothreads %*
echo.
pause
