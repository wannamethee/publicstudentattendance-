@echo off
chcp 65001 >nul
title เปิดใช้งานแทนเครื่อง Linux (เครื่องหลักล่ม)
cd /d "c:\schooltranscription"
python standby_sync.py status
echo.
echo ==================================================================
echo   ใช้เมื่อเครื่อง Linux ที่โรงเรียนล่ม / ไฟดับ / เน็ตโรงเรียนดับ เท่านั้น
echo   เครื่องนี้จะเปิดรับงานแทน และลิงก์ออนไลน์จะชี้มาที่เครื่องนี้
echo   เมื่อ Linux กลับมา ให้ดับเบิลคลิก standby_handback.bat เพื่อคืนงาน
echo ==================================================================
set /p OK=พิมพ์ y แล้วกด Enter เพื่อเปิดใช้งานแทน:
if /i not "%OK%"=="y" goto :eof
python standby_sync.py takeover
pause
