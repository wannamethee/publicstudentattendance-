@echo off
chcp 65001 >nul
title สถานะระบบสองเครื่อง (Linux หลัก / Windows สำรอง)
cd /d "c:\schooltranscription"
python standby_sync.py status
echo.
echo บันทึกการทำงานล่าสุด:
powershell -NoProfile -Command "if (Test-Path standby_sync.log) { Get-Content standby_sync.log -Tail 10 -Encoding UTF8 }"
pause
