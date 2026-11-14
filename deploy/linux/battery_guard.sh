#!/usr/bin/env bash
# โน้ตบุ๊กเป็นเซิร์ฟเวอร์: แบตทำหน้าที่เป็น UPS (ไฟดับแล้วอยู่ได้ประมาณ 1 ชั่วโมง)
# ถ้าไฟดับนานกว่านั้น ต้องปิดเครื่องให้เรียบร้อยก่อนแบตหมด ไม่ปล่อยให้ดับกลางที่กำลังเขียนฐานข้อมูล
#
# setup.sh ปิด sleep/suspend/hibernate ไว้ทั้งหมด (เครื่องต้องไม่หลับตอนเป็นเซิร์ฟเวอร์) ตัวจัดการพลังงานของระบบ
# จึงทำอะไรตอนแบตใกล้หมดไม่ได้เลย สคริปต์นี้ทำหน้าที่นั้นแทน เรียกโดย school-battery.timer ทุก 2 นาที
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SHUTDOWN_AT="${BATTERY_SHUTDOWN_PERCENT:-15}"   # เหลือกี่ % แล้วปิดเครื่อง
WARN_AT="${BATTERY_WARN_PERCENT:-40}"
STATE_FILE="$APP_DIR/data/power_state.json"

bat="$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1 || true)"
[ -n "$bat" ] || exit 0   # ไม่ใช่โน้ตบุ๊ก

status="$(cat "$bat/status" 2>/dev/null || echo Unknown)"
pct="$(cat "$bat/capacity" 2>/dev/null || echo 100)"
on_ac=1
for ac in /sys/class/power_supply/A{C,DP}*/online /sys/class/power_supply/*/online; do
  [ -f "$ac" ] || continue
  case "$ac" in *BAT*) continue;; esac
  on_ac="$(cat "$ac")"
  break
done

mkdir -p "$(dirname "$STATE_FILE")"
printf '{"on_ac": %s, "battery_percent": %s, "status": "%s", "checked_at": "%s"}\n' \
  "$on_ac" "$pct" "$status" "$(date -Is)" > "$STATE_FILE"

[ "$status" = "Discharging" ] || exit 0   # เสียบไฟอยู่: ไม่ต้องทำอะไร

if [ "$pct" -le "$SHUTDOWN_AT" ]; then
  logger -t school-battery "battery $pct% on mains failure: stopping services and powering off"
  # หยุดบริการก่อน เพื่อให้ SQLite ปิดไฟล์และรวม WAL ให้เรียบร้อย แล้วสำรองข้อมูลไว้เป็นชุดสุดท้าย
  systemctl stop school-tunnel.service school-api.service || true
  sleep 3
  bash "$APP_DIR/deploy/linux/backup_db.sh" >/dev/null 2>&1 || true
  sqlite3 "$APP_DIR/school_archive.db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  logger -t school-battery "clean shutdown now (battery $pct%)"
  systemctl poweroff
  exit 0
fi

if [ "$pct" -le "$WARN_AT" ]; then
  logger -t school-battery "mains failure, battery $pct% (จะปิดเครื่องเองที่ $SHUTDOWN_AT%)"
fi
