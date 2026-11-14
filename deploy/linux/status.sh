#!/usr/bin/env bash
# สรุปสถานะเครื่องเซิร์ฟเวอร์ ปพ.5 (ใช้ดูว่าทุกอย่างปกติไหม): bash deploy/linux/status.sh
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="$(grep -oP '(?<=^APP_PORT=).*' /etc/schooltranscription.env 2>/dev/null || echo 8000)"

ok() { printf '  \033[32m✔\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m!\033[0m %s\n' "$1"; }

echo "== บริการ"
for s in school-api school-tunnel; do
  if systemctl is-active --quiet "$s"; then
    ok "$s ทำงาน (เริ่มมาแล้ว $(systemctl show -p ActiveEnterTimestamp --value "$s" | cut -d' ' -f2-3))"
  else
    bad "$s ไม่ทำงาน — ดู: journalctl -u $s -n 50"
  fi
done
systemctl is-enabled --quiet school-api && ok "เปิดเครื่องแล้วเริ่มเอง" || bad "ยังไม่ตั้งให้เริ่มเองตอนเปิดเครื่อง"
systemctl list-timers --all 2>/dev/null | grep -q school-backup && ok "ตั้งเวลาสำรองข้อมูลไว้แล้ว" || bad "ไม่มีตัวตั้งเวลาสำรองข้อมูล"

echo "== เว็บ"
code="$(curl -fs -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/health" 2>/dev/null || echo 000)"
[ "$code" = "200" ] && ok "ในเครื่อง: HTTP $code" || bad "ในเครื่องไม่ตอบ (HTTP $code)"
echo "  ในโรงเรียน: http://$(hostname -I | awk '{print $1}'):$PORT"
dom="$(grep -oP '(?<=^NGROK_DOMAIN=).*' /etc/schooltranscription.env 2>/dev/null)"
if [ -n "$dom" ]; then
  code="$(curl -fs -o /dev/null -w '%{http_code}' "https://$dom/api/health" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && ok "ออนไลน์ https://$dom: HTTP $code" || bad "ลิงก์ออนไลน์ไม่ตอบ (HTTP $code) — journalctl -u school-tunnel -n 30"
fi

echo "== ข้อมูล"
db="$APP_DIR/school_archive.db"
echo "  ฐานข้อมูล: $(du -h "$db" | cut -f1)   นักเรียนที่กำลังศึกษา: $(sqlite3 "$db" 'SELECT COUNT(DISTINCT student_id) FROM class_students WHERE is_active=1;' 2>/dev/null)"
last="$(ls -t "$APP_DIR"/backups/auto/*.db.gz 2>/dev/null | head -1)"
if [ -n "$last" ]; then
  age=$(( ($(date +%s) - $(stat -c %Y "$last")) / 3600 ))
  [ "$age" -lt 30 ] && ok "สำรองล่าสุด $age ชั่วโมงที่แล้ว ($(basename "$last"))" || bad "สำรองล่าสุดนานแล้ว $age ชั่วโมง"
  echo "  จำนวนไฟล์สำรองอัตโนมัติ: $(ls "$APP_DIR"/backups/auto/*.db.gz | wc -l) ไฟล์"
else
  bad "ยังไม่มีไฟล์สำรองอัตโนมัติ — รันเอง: bash deploy/linux/backup_db.sh"
fi
echo "  ไฟล์ ปพ.5: $(ls "$APP_DIR"/outputs/*_ปพ5_filled.xlsx 2>/dev/null | wc -l) Excel, $(ls "$APP_DIR"/outputs/*_print_ready.pdf 2>/dev/null | wc -l) PDF"

echo "== เครื่อง"
free -h | awk '/Mem:/{printf "  RAM ใช้ %s จาก %s (เหลือ %s)\n", $3, $2, $7} /Swap:/{printf "  Swap ใช้ %s จาก %s\n", $3, $2}'
df -h "$APP_DIR" | awk 'NR==2{printf "  ดิสก์ใช้ %s จาก %s (%s) เหลือ %s\n", $3, $2, $5, $4}'
avail=$(df --output=pcent "$APP_DIR" | tail -1 | tr -dc '0-9')
[ "${avail:-0}" -ge 90 ] && bad "ดิสก์เกือบเต็ม — ลบไฟล์สำรองเก่าหรือ outputs เก่า" || ok "พื้นที่ดิสก์เพียงพอ"
bat="$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1 || true)"
if [ -n "$bat" ]; then
  pct="$(cat "$bat/capacity" 2>/dev/null)"; st="$(cat "$bat/status" 2>/dev/null)"
  if [ "$st" = "Discharging" ]; then
    bad "ไฟดับอยู่! ใช้แบต เหลือ $pct% (เครื่องจะปิดเองอย่างปลอดภัยที่ 15%)"
  else
    ok "เสียบไฟอยู่ แบต $pct% ($st) — แบตทำหน้าที่สำรองไฟประมาณ 1 ชั่วโมง"
  fi
  systemctl list-timers --all 2>/dev/null | grep -q school-battery     && ok "ตัวเฝ้าแบตทำงาน" || bad "ไม่มีตัวเฝ้าแบต — รัน sudo bash deploy/linux/setup.sh ซ้ำ"
fi
echo "  เขตเวลา: $(timedatectl show -p Timezone --value)   เวลาเครื่อง: $(date '+%d/%m/%Y %H:%M')"
echo "  เปิดเครื่องต่อเนื่อง: $(uptime -p 2>/dev/null || uptime)"
systemctl is-enabled --quiet sleep.target 2>/dev/null && bad "เครื่องยังพักหน้าจอ/sleep ได้ — รัน sudo bash deploy/linux/setup.sh ซ้ำ" || ok "ปิดการ sleep แล้ว"
fc-match "TH SarabunPSK" | grep -qi sarabun && ok "ฟอนต์ TH SarabunPSK พร้อม (ปพ.5 PDF)" || bad "ไม่พบฟอนต์ TH SarabunPSK — PDF จะเพี้ยน"
if command -v soffice >/dev/null || command -v libreoffice >/dev/null; then ok "LibreOffice พร้อมแปลง PDF"; else bad "ไม่พบ LibreOffice — สร้าง PDF ไม่ได้"; fi
