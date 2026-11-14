@echo off
chcp 65001 >nul
title ระบบจัดการข้อมูล ปพ.5 และตารางสอน
cd /d "c:\schooltranscription"

echo ========================================================
echo   กำลังเริ่มต้นเซิร์ฟเวอร์ระบบ ปพ.5 (FastAPI Port 8000)...
echo ========================================================
start "SchoolTranscriptionBackend" /min python -m uvicorn main:app --host 0.0.0.0 --port 8000
timeout /t 3 /nobreak >nul

echo ========================================================
echo   กำลังเชื่อมต่อ Cloudflare Tunnel...
echo   คัดลอกลิงก์ https://....trycloudflare.com เพื่อเข้าใช้งาน
echo   (สามารถเปิดผ่านมือถือ หรือเครือข่ายอื่นได้ทันที)
echo ========================================================
"c:\schooltranscription\cloudflared.exe" tunnel --url http://localhost:8000
pause
