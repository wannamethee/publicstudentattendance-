@echo off
chcp 65001 >nul
title ตั้งค่าเครื่องนี้เป็นเครื่องสำรอง (Windows) ของระบบ ปพ.5
cd /d "c:\schooltranscription"
echo ==================================================================
echo   ตั้งค่าเครื่อง Windows นี้เป็น "เครื่องสำรอง" ของเครื่อง Linux
echo   ใช้หลังจาก Linux ทำงานจริงแล้วเท่านั้น (วันย้ายระบบ)
echo   - เลิกเปิดเซิร์ฟเวอร์เองตอนเปิดเครื่อง (ไม่แย่งลิงก์กับ Linux)
echo   - สร้างกุญแจ ssh และส่งให้เครื่อง Linux (ถามรหัสผ่าน Linux 1 ครั้ง)
echo   - ตั้งเวลาซิงค์ข้อมูลจาก Linux ทุก 5 นาที
echo ==================================================================
set /p OK=พิมพ์ y แล้วกด Enter เพื่อดำเนินการต่อ:
if /i not "%OK%"=="y" goto :eof

if not exist standby_config.json (
  copy /y standby_config.example.json standby_config.json >nul
  echo แก้ชื่อเครื่อง Linux และโฟลเดอร์ในไฟล์ที่เปิดขึ้นมา แล้วบันทึกและปิด Notepad
  notepad standby_config.json
)

echo.
echo [1/4] เลิกเปิดเซิร์ฟเวอร์อัตโนมัติตอนเปิดเครื่อง
set "STARTUP_FILE=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\SGS_PP5_AutoStart.vbs"
if exist "%STARTUP_FILE%" del "%STARTUP_FILE%"
echo     เรียบร้อย

echo [2/4] หยุดเซิร์ฟเวอร์และลิงก์ ngrok บนเครื่องนี้ (Linux เป็นเครื่องหลักแล้ว)
powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort 8000 -State Listen -EA SilentlyContinue | %% { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }; Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | ? { $_.CommandLine -like '*start_ngrok*' } | %% { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }"

echo [3/4] กุญแจ ssh สำหรับคุยกับเครื่อง Linux ผ่าน Tailscale
for /f "delims=" %%h in ('python -c "import json;print(json.load(open('standby_config.json',encoding='utf-8'))['primary_ssh'])"') do set "PRIMARY=%%h"
if not exist "%USERPROFILE%\.ssh\id_ed25519" (
  if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
  ssh-keygen -q -t ed25519 -N "" -f "%USERPROFILE%\.ssh\id_ed25519"
)
echo     ส่งกุญแจไปที่ %PRIMARY% (ใส่รหัสผ่านบัญชีบนเครื่อง Linux)
type "%USERPROFILE%\.ssh\id_ed25519.pub" | ssh -o StrictHostKeyChecking=accept-new %PRIMARY% "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
if errorlevel 1 (
  echo !! ส่งกุญแจไม่สำเร็จ: ตรวจว่า Tailscale เปิดอยู่ทั้งสองเครื่อง และชื่อเครื่องใน standby_config.json ถูกต้อง
  pause
  goto :eof
)

echo [4/4] ตั้งเวลาซิงค์ทุก 5 นาที (เฉพาะตอนเปิดเครื่องและล็อกอินอยู่)
schtasks /create /f /tn "SchoolPP5 Standby Sync" /sc minute /mo 5 /tr "wscript.exe \"c:\schooltranscription\standby_sync_hidden.vbs\"" >nul
echo.
echo ซิงค์ครั้งแรก (ครั้งแรกอาจนาน เพราะเทียบไฟล์ทั้งหมด)...
python standby_sync.py sync
echo.
python standby_sync.py status
pause
