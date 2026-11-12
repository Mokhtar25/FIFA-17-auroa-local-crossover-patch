@echo off
rem FIFA 14 Windows capture. Double-click this file. That is the whole job.
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
rem -- kit v5: read-only facts about this PC, and a hook audit that runs beside
rem    the capture (compares the game's loaded system DLLs with the files on disk).
set X=extra-%COMPUTERNAME%
if not exist "%X%" mkdir "%X%"
call bin\env.cmd > "%X%\env.txt" 2>&1
start "" /b cmd /c "bin\hookaudit.exe wait fifa14.exe 1500,3000,6000,15000,40000 %X%\hooks > %X%\hooks-console.txt 2>&1"
bin\fifa14cap.exe %*
tar -a -c -f "%X%.zip" "%X%" >nul 2>&1
echo.
echo Send BOTH files: the capture-....zip above and %X%.zip
echo.
pause
