@echo off
REM Claude Monitor - Windows launcher. First run installs Electron (needs Node.js 18+ and internet).
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js is required. Install it from https://nodejs.org then run this again.
  pause
  exit /b 1
)
if not exist node_modules\electron (
  echo Installing Electron (one-time, ~100 MB^)...
  call npm install --no-audit --no-fund
  if errorlevel 1 ( pause & exit /b 1 )
)
REM Launch without keeping a console window open.
wscript.exe "%~dp0start-hidden.vbs"
echo Claude Monitor started. Look for the orb at the top-right of your screen and the drop icon in the tray.
timeout /t 3 >nul
