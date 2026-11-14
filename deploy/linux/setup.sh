#!/usr/bin/env bash
# =====================================================================
#  ติดตั้งระบบ ปพ.5 (FastAPI + Flutter Web) บน Xubuntu / Ubuntu 24.04
#  รันจากโฟลเดอร์โปรเจกต์ที่แตกไฟล์แล้ว:   sudo bash deploy/linux/setup.sh
#  รันซ้ำได้ปลอดภัย (ใช้ตอนอัปเดตโค้ดก็ได้)
# =====================================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
APP_PORT="${APP_PORT:-8000}"
ENV_FILE=/etc/schooltranscription.env

if [ "$(id -u)" -ne 0 ]; then echo "กรุณารันด้วย sudo: sudo bash deploy/linux/setup.sh"; exit 1; fi
if [ "$APP_USER" = "root" ]; then echo "รันผ่าน sudo จากบัญชีผู้ใช้ปกติ (ไม่ใช่ root โดยตรง)"; exit 1; fi
echo "== โฟลเดอร์ระบบ: $APP_DIR   ผู้ใช้ที่รันบริการ: $APP_USER"

echo "== [1/12] ติดตั้งแพ็กเกจ (LibreOffice แบบไม่มีหน้าจอ, ฟอนต์ไทย, Python, Node)"
apt-get update
apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip sqlite3 curl fontconfig fonts-thai-tlwg nodejs npm unzip rclone tesseract-ocr tesseract-ocr-tha
# -nogui (no desktop toolkit, lighter on 4 GB RAM) exists from Ubuntu 22.04; older releases fall back
apt-get install -y --no-install-recommends libreoffice-calc-nogui libreoffice-writer-nogui \
  || apt-get install -y --no-install-recommends libreoffice-calc libreoffice-writer

echo "== [2/12] เขตเวลา Asia/Bangkok (ระบบนับเวลาเรียนถึง 'วันนี้' ตามนาฬิกาเครื่อง)"
timedatectl set-timezone Asia/Bangkok || true

echo "== [3/12] ฟอนต์ TH SarabunPSK และแทน Cordia New"
install -d /usr/local/share/fonts/schooltranscription
install -m 644 "$APP_DIR"/deploy/linux/fonts/*.ttf /usr/local/share/fonts/schooltranscription/
install -m 644 "$APP_DIR"/deploy/linux/60-school-thai-fonts.conf /etc/fonts/conf.d/60-school-thai-fonts.conf
fc-cache -f >/dev/null
fc-match "TH SarabunPSK"; fc-match "Cordia New"

echo "== [4/12] Swap 2 GB (RAM 4 GB: กันเครื่องค้างตอน LibreOffice แปลง PDF)"
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -q vm.swappiness=10 && echo 'vm.swappiness=10' > /etc/sysctl.d/99-schooltranscription.conf

echo "== [5/12] ห้ามเครื่องพัก/ปิดจอ (เป็นเซิร์ฟเวอร์ เปิดตลอด)"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
install -d /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/schooltranscription.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF
# Xubuntu desktop session: its own power manager and screensaver can still blank or suspend the machine
APP_HOME_EARLY="$(getent passwd "$APP_USER" | cut -d: -f6)"
xq() { sudo -u "$APP_USER" env HOME="$APP_HOME_EARLY" DISPLAY=:0 xfconf-query "$@" >/dev/null 2>&1 || true; }
if command -v xfconf-query >/dev/null; then
  for p in inactivity-on-ac inactivity-on-battery blank-on-ac blank-on-battery; do
    xq -c xfce4-power-manager -p "/xfce4-power-manager/$p" -n -t int -s 0
  done
  xq -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false
  xq -c xfce4-screensaver -p /saver/enabled -n -t bool -s false
  xq -c xfce4-screensaver -p /lock/enabled -n -t bool -s false
fi

echo "== [6/12] Python virtualenv + ไลบรารี"
sudo -u "$APP_USER" python3 -m venv "$APP_DIR/venv"
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip -q
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q

echo "== [7/12] ngrok (Node) — node_modules จาก Windows ใช้บน Linux ไม่ได้ ต้องติดตั้งใหม่"
rm -rf "$APP_DIR/node_modules"
sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && npm install --omit=dev --no-audit --no-fund"
if [ ! -f "$ENV_FILE" ]; then
  TOKEN=""
  [ -f "$APP_DIR/ngrok_token.txt" ] && TOKEN="$(tr -d '\r\n' < "$APP_DIR/ngrok_token.txt")"
  umask 077
  DOMAIN=""
  [ -f "$APP_DIR/ngrok_domain.txt" ] && DOMAIN="$(tr -d '\r\n' < "$APP_DIR/ngrok_domain.txt")"
  printf 'NGROK_AUTHTOKEN=%s\nNGROK_DOMAIN=%s\nAPP_PORT=%s\n' "$TOKEN" "$DOMAIN" "$APP_PORT" > "$ENV_FILE"
  rm -f "$APP_DIR/ngrok_token.txt"   # token now lives only in $ENV_FILE (root-readable)
fi
# Login signing secret (auth.py): same value as the old server, so teachers stay logged in after the move
if ! grep -q '^SCHOOL_AUTH_SECRET=' "$ENV_FILE"; then
  if [ -f "$APP_DIR/auth_secret.txt" ]; then
    SECRET="$(tr -d '\r\n' < "$APP_DIR/auth_secret.txt")"
  else
    SECRET="$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=')"
  fi
  printf 'SCHOOL_AUTH_SECRET=%s\n' "$SECRET" >> "$ENV_FILE"
fi
rm -f "$APP_DIR/auth_secret.txt"
chmod 600 "$ENV_FILE"

echo "== [8/12] สิทธิ์ไฟล์ + บริการ systemd (เปิดเครื่องแล้วเริ่มเอง, ล่มแล้วเริ่มใหม่เอง)"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
mkdir -p "$APP_DIR/backups/auto" && chown "$APP_USER":"$APP_USER" "$APP_DIR/backups/auto"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"

cat > /etc/systemd/system/school-api.service <<EOF
[Unit]
Description=ระบบ ปพ.5 - FastAPI server
After=network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
Environment=HOME=$APP_HOME
EnvironmentFile=-$ENV_FILE
# ต้องมี 1 worker เท่านั้น: คิวอัปเดตไฟล์ ปพ.5 และ lock ของไฟล์อยู่ในโปรเซสเดียว
# run-guarded: ถ้า Windows (เครื่องสำรอง) ทำงานแทนอยู่ จะไม่เริ่ม (exit 75) จนกว่า Windows สั่ง handback
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/standby_sync.py run-guarded -- $APP_DIR/venv/bin/uvicorn main:app --host 0.0.0.0 --port \${APP_PORT} --workers 1 --timeout-keep-alive 30 --log-level warning
Restart=always
RestartSec=3
RestartPreventExitStatus=75
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/school-tunnel.service <<EOF
[Unit]
Description=ระบบ ปพ.5 - ngrok tunnel
After=network-online.target school-api.service
Wants=network-online.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
# STANDBY_GUARD=1: ก่อนเชื่อมต่อทุกครั้ง ถ้า Windows ทำงานแทนอยู่ จะถอยออก (exit 75) ไม่แย่งลิงก์
Environment=STANDBY_GUARD=1
ExecStart=/usr/bin/node $APP_DIR/start_ngrok.js
Restart=always
RestartSec=5
RestartPreventExitStatus=75

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/school-backup.service <<EOF
[Unit]
Description=ระบบ ปพ.5 - สำรองฐานข้อมูลรายวัน

[Service]
Type=oneshot
User=$APP_USER
ExecStart=/bin/bash $APP_DIR/deploy/linux/backup_db.sh
EOF

cat > /etc/systemd/system/school-backup.timer <<'EOF'
[Unit]
Description=สำรองฐานข้อมูล ปพ.5 ทุกคืน 02:30

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl restart systemd-logind || true
systemctl enable --now school-api.service school-tunnel.service school-backup.timer

if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow "$APP_PORT"/tcp comment 'school ปพ.5 (LAN)'
fi

echo "== [9/12] อัปเดตความปลอดภัยอัตโนมัติ (เครื่องเปิดตลอด ไม่รีบูตเอง)"
apt-get install -y --no-install-recommends unattended-upgrades >/dev/null
cat > /etc/apt/apt.conf.d/52school-unattended <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
// ไม่รีบูตเอง: ครูอาจใช้งานอยู่ (ถ้าต้องรีบูต status.sh จะแจ้ง)
Unattended-Upgrade::Automatic-Reboot "false";
EOF

echo "== [10/12] ตัวเฝ้าระวัง: ถ้าเว็บไม่ตอบ 3 ครั้งติดกัน ให้เริ่มบริการใหม่เอง"
cat > /usr/local/bin/school-watchdog <<EOF
#!/usr/bin/env bash
# Restart=always only covers a crash; this also catches a server that answers nothing (hang).
# Parked while the Windows standby serves (standby_sync.py): stopped on purpose, do not restart.
[ -f "$APP_DIR/HELD_BY_STANDBY" ] && exit 0
for i in 1 2 3; do
  curl -fs -m 20 -o /dev/null "http://127.0.0.1:\${APP_PORT}/api/health" && exit 0
  sleep 10
done
logger -t school-watchdog "health check failed 3 times, restarting school-api"
systemctl restart school-api.service
EOF
chmod 755 /usr/local/bin/school-watchdog
cat > /etc/systemd/system/school-watchdog.service <<EOF
[Unit]
Description=ระบบ ปพ.5 - ตรวจว่าเว็บยังตอบอยู่

[Service]
Type=oneshot
EnvironmentFile=-$ENV_FILE
Environment=APP_PORT=$APP_PORT
ExecStart=/usr/local/bin/school-watchdog
EOF
cat > /etc/systemd/system/school-watchdog.timer <<'EOF'
[Unit]
Description=ตรวจเว็บ ปพ.5 ทุก 5 นาที

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now school-watchdog.timer

echo "== [11/12] โน้ตบุ๊ก: แบตเป็น UPS — ไฟดับนานแล้วปิดเครื่องให้เรียบร้อยก่อนแบตหมด"
if ls -d /sys/class/power_supply/BAT* >/dev/null 2>&1; then
  cat > /etc/systemd/system/school-battery.service <<EOF
[Unit]
Description=ระบบ ปพ.5 - เฝ้าแบต (ไฟดับ -> ปิดเครื่องอย่างปลอดภัย)

[Service]
Type=oneshot
EnvironmentFile=-$ENV_FILE
ExecStart=/bin/bash $APP_DIR/deploy/linux/battery_guard.sh
EOF
  cat > /etc/systemd/system/school-battery.timer <<'EOF'
[Unit]
Description=ตรวจแบตทุก 2 นาที

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
  grep -q '^BATTERY_SHUTDOWN_PERCENT=' "$ENV_FILE" || printf 'BATTERY_SHUTDOWN_PERCENT=15
BATTERY_WARN_PERCENT=40
' >> "$ENV_FILE"
  systemctl daemon-reload
  systemctl enable --now school-battery.timer
  # ถ้าเครื่องรองรับ ให้หยุดชาร์จที่ 80% เพื่อถนอมแบต (เสียบไฟค้างตลอดทำแบตเสื่อมเร็ว)
  THR="$(ls /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null | head -1 || true)"
  if [ -n "$THR" ]; then
    echo "   เครื่องนี้ตั้งเพดานการชาร์จได้: $THR  (ค่าตอนนี้ $(cat "$THR")%)"
    echo "   ถ้าต้องการถนอมแบต (แลกกับเวลาสำรองไฟสั้นลง) ให้รัน: sudo tee $THR <<< 80"
  fi
  echo "   ตั้งไว้: ไฟดับและแบตเหลือ 15% -> หยุดบริการ สำรองข้อมูล แล้วปิดเครื่องเอง"
else
  echo "   ไม่พบแบตเตอรี่ (เครื่องตั้งโต๊ะ) ข้ามขั้นนี้ — ควรต่อ UPS"
fi

echo "== [เพิ่ม] เครื่องสำรอง Windows: ssh + Tailscale + สิทธิ์หยุด/เริ่มบริการ (standby_sync.py)"
apt-get install -y --no-install-recommends openssh-server >/dev/null
systemctl enable --now ssh >/dev/null 2>&1 || true
# standby_sync.py (รันเป็น $APP_USER ผ่าน ssh) สั่งได้แค่หยุด/เริ่ม 2 บริการนี้เท่านั้น
SUDOERS=/etc/sudoers.d/schooltranscription-standby
printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl stop school-tunnel.service school-api.service\n%s ALL=(root) NOPASSWD: /usr/bin/systemctl start school-api.service school-tunnel.service\n' \
  "$APP_USER" "$APP_USER" > "$SUDOERS.tmp"
chmod 440 "$SUDOERS.tmp"
if visudo -cf "$SUDOERS.tmp" >/dev/null; then mv "$SUDOERS.tmp" "$SUDOERS"; else rm -f "$SUDOERS.tmp"; echo "!! sudoers ไม่ผ่านการตรวจ ข้าม"; fi
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh || echo "!! ติดตั้ง Tailscale ไม่สำเร็จ ลองใหม่ภายหลัง"
fi
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow in on tailscale0 to any port 22 proto tcp comment 'ssh from Windows standby (Tailscale only)'
fi
if command -v tailscale >/dev/null && ! tailscale status >/dev/null 2>&1; then
  echo "   ยังไม่ได้ล็อกอิน Tailscale: รัน  sudo tailscale up  แล้วเปิดลิงก์ที่แสดง ล็อกอินบัญชีเดียวกับเครื่อง Windows"
fi

echo "== [12/12] ตรวจสอบ"
for i in $(seq 1 30); do curl -fs "http://127.0.0.1:$APP_PORT/" >/dev/null && break; sleep 1; done
curl -fs -o /dev/null -w "หน้าเว็บ: HTTP %{http_code}\n" "http://127.0.0.1:$APP_PORT/" || echo "!! เซิร์ฟเวอร์ยังไม่ตอบ: journalctl -u school-api -n 50"
sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && venv/bin/python -m unittest discover -s tests -q" || true
LAN_IP="$(hostname -I | awk '{print $1}')"
echo "======================================================================"
echo " ติดตั้งเสร็จ   ในโรงเรียน: http://$LAN_IP:$APP_PORT    ออนไลน์: ลิงก์ ngrok ของโรงเรียน (ดู journalctl -u school-tunnel)"
echo " ดูสถานะ:  systemctl status school-api school-tunnel"
echo " ดู log:   journalctl -u school-api -f"
echo " ดูสถานะรวมทุกอย่าง:  bash $APP_DIR/deploy/linux/status.sh"
echo " ทดสอบ PDF ภาษาไทย:  cd $APP_DIR && venv/bin/python deploy/linux/check_pdf.py"
echo "======================================================================"
