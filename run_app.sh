#!/bin/bash
cd "$(dirname "$0")"

echo "========================================================"
echo "  ระบบ SGS ปพ.5 (FastAPI + Flutter Web) บน Xubuntu Linux"
echo "  Local Server:   http://localhost:8000"
echo "  Permanent URL:  <ลิงก์ออนไลน์ ngrok ของโรงเรียน>"
echo "========================================================"

# Check & create directories
mkdir -p uploads outputs

# Check node & start ngrok tunnel in background
if command -v node &> /dev/null; then
    echo "[1/2] เริ่มต้น Ngrok Tunnel ในพื้นหลัง..."
    nohup node start_ngrok.js > ngrok.log 2>&1 &
else
    echo "[!] ไม่พบ node.js (ติดตั้งด้วย: sudo apt install nodejs npm)"
fi

# Start FastAPI server
echo "[2/2] เริ่มต้น FastAPI Server บนพอร์ต 8000..."
python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
