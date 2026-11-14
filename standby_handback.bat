@echo off
chcp 65001 >nul
title คืนงานให้เครื่อง Linux
cd /d "c:\schooltranscription"
python standby_sync.py status
echo.
echo ==================================================================
echo   ส่งข้อมูลทั้งหมดจากเครื่องนี้คืนให้ Linux แล้วให้ Linux ทำงานต่อ
echo   ระหว่างส่ง (ประมาณ 1-5 นาที) ครูจะเข้าระบบไม่ได้ชั่วคราว
echo ==================================================================
set /p OK=พิมพ์ y แล้วกด Enter เพื่อคืนงานให้ Linux:
if /i not "%OK%"=="y" goto :eof
python standby_sync.py handback
pause
