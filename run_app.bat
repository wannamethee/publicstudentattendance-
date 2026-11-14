@echo off
chcp 65001 >nul
cd /d "%~dp0"
title ระบบ SGS ปพ.5 (FastAPI + Ngrok Online)

echo ========================================================
echo   ระบบ SGS ปพ.5
echo   โหมด: เชื่อมต่อออนไลน์ (Online Cloud System)
echo ========================================================
echo   [+] ลิงก์ออนไลน์ถาวร (สำหรับคุณครูทั้งโรงเรียน):
echo       <ลิงก์ออนไลน์ ngrok ของโรงเรียน>
echo ========================================================
echo.

:: 1. Clear any stuck zombie processes on port 8000
echo [1/3] ตรวจสอบและเคลียร์พอร์ต 8000...
for /f "tokens=5" %%a in ('netstat -aon ^| findstr :8000 ^| findstr LISTENING 2^>nul') do (
    taskkill /f /pid %%a >nul 2>&1
)

:: 2. Ensure directories exist
if not exist "uploads" mkdir uploads
if not exist "outputs" mkdir outputs

:: 3. Start Permanent Ngrok Tunnel in background
echo [2/3] เริ่มการทำงาน Ngrok Tunnel ออนไลน์...
start /b "" node start_ngrok.js

:: 4. Start Browser
echo [3/3] กำลังเปิดเว็บเบราว์เซอร์...
start "" "<ลิงก์ออนไลน์ ngrok ของโรงเรียน>"

:: 5. Start FastAPI server
echo.
echo ========================================================
echo   เซิร์ฟเวอร์กำลังทำงาน... ห้ามปิดหน้าต่างนี้ขณะใช้งาน
echo   (หากต้องการหยุดระบบ ให้กดปิดหน้าต่างนี้ หรือกด Ctrl + C)
echo ========================================================
echo.

python -m uvicorn main:app --host 0.0.0.0 --port 8000

pause
