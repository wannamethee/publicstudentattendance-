@echo off
chcp 65001 >nul
echo กำลังตั้งค่าให้ระบบเปิดอัตโนมัติเมื่อเปิดคอมพิวเตอร์ (Windows Startup)...
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "TARGET_PATH=%STARTUP_DIR%\SGS_PP5_AutoStart.vbs"

copy /y "c:\schooltranscription\launch_background.vbs" "%TARGET_PATH%" >nul

echo ========================================================
echo   [สำเร็จ] ตั้งค่าเปิดระบบอัตโนมัติเรียบร้อยแล้ว!
echo   จากนี้ เมื่อเปิดคอมพิวเตอร์ขึ้นมา:
echo   - เซิร์ฟเวอร์และลิงก์ออนไลน์จะรันในพื้นหลังอัตโนมัติ
echo   - สามารถเข้าผ่านลิงก์ <ลิงก์ออนไลน์ ngrok ของโรงเรียน> ได้ทันที
echo ========================================================
pause
