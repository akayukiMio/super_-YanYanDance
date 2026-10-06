@echo off
rem Double-click launcher for the gallery sync console menu.
rem ASCII only on purpose: cmd parses batch files in the OEM codepage.
chcp 65001 >nul
title Gallery Sync Tool
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0menu.ps1"
