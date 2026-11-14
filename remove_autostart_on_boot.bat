@echo off
chcp 65001 >nul
echo กำลังยกเลิกการเปิดอัตโนมัติเมื่อเปิดเครื่อง...
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
if exist "%STARTUP_DIR%\SGS_PP5_AutoStart.vbs" (
    del /f /q "%STARTUP_DIR%\SGS_PP5_AutoStart.vbs"
    echo [สำเร็จ] ยกเลิกการเปิดอัตโนมัติเรียบร้อยแล้ว
) else (
    echo [แจ้งเตือน] ไม่พบการตั้งค่าเปิดอัตโนมัติใน Startup
)
pause
