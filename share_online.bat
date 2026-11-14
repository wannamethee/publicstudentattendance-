@echo off
chcp 65001 > nul
cd /d "%~dp0"
title Share Online via Cloudflare Tunnel
python share_online.py
pause
