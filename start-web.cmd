@echo off
rem Double-click launcher for the local WEB console (same actions as the console menu).
rem ASCII only on purpose: cmd parses batch files in the OEM codepage (same rule as start.cmd).
chcp 65001 >nul
title Gallery Sync Web Console
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo [web] node.exe not found in PATH.
  echo [web] Use start.cmd for the console menu instead.
  pause
  exit /b 1
)

echo [web] starting http://127.0.0.1:8787/  (use start-web.vbs for silent launch)
node "%~dp0web\server.mjs" --open
if errorlevel 1 pause
