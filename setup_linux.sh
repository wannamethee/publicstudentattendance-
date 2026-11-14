#!/usr/bin/env bash
# ตัวติดตั้งเดิมย้ายไปที่ deploy/linux/setup.sh (ติดตั้งบริการ systemd, ฟอนต์, LibreOffice, ngrok)
exec sudo bash "$(dirname "$0")/deploy/linux/setup.sh" "$@"
