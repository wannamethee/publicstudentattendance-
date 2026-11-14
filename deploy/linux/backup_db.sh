#!/usr/bin/env bash
# สำรองฐานข้อมูลแบบปลอดภัยขณะเซิร์ฟเวอร์ทำงาน (SQLite online backup) เก็บย้อนหลัง 30 วัน
# เรียกโดย school-backup.timer ทุกคืน หรือรันเองได้: bash deploy/linux/backup_db.sh
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$APP_DIR/backups/auto"
mkdir -p "$DEST"
STAMP="$(date +%Y%m%d_%H%M)"
sqlite3 "$APP_DIR/school_archive.db" ".backup '$DEST/school_archive_$STAMP.db'"
sqlite3 "$DEST/school_archive_$STAMP.db" "PRAGMA integrity_check;" | grep -qx ok
gzip -f "$DEST/school_archive_$STAMP.db"
find "$DEST" -name 'school_archive_*.db.gz' -mtime +30 -delete
echo "backup ok: $DEST/school_archive_$STAMP.db.gz"
