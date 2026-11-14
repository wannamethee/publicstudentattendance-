# ย้ายเซิร์ฟเวอร์ ปพ.5 ไปเครื่องโรงเรียน (Xubuntu) แบบเปิดตลอด

เครื่องเป้าหมาย: Xubuntu 24.04 LTS (แนะนำ) · Ryzen 3 2xxxU · RAM 4 GB · ควรเป็น SSD

## ก่อนย้าย (บนเครื่อง Windows เดิม)
1. ให้ครูหยุดบันทึกข้อมูลชั่วคราว
2. สร้างชุดย้ายเครื่อง: `python deploy/make_migration_bundle.py`
   - ได้ไฟล์ `tmp/schooltranscription_linux_<วันเวลา>.tar.gz` (ประมาณ 310 MB) ฐานข้อมูลถูกสำรองแบบปลอดภัยแม้เซิร์ฟเวอร์ยังเปิดอยู่ และสคริปต์จะไม่ยอมสร้างไฟล์ถ้าขาดไฟล์ที่ระบบต้องใช้
   - ไฟล์นี้มี **ข้อมูลนักเรียนและ token ของ ngrok** ให้คัดลอกด้วย USB หรือในวง LAN เท่านั้น และลบสำเนาทิ้งหลังติดตั้งเสร็จ
3. ปิดเซิร์ฟเวอร์ Windows ก่อนเปิดเครื่องใหม่ เพราะ ngrok ใช้โดเมนเดียวกันได้ทีละเครื่อง

## ติดตั้งบน Xubuntu
```bash
mkdir -p ~/apps && cd ~/apps
tar -xzf /media/$USER/<USB>/schooltranscription_linux_*.tar.gz
cd schooltranscription
sudo bash deploy/linux/setup.sh
```
สคริปต์จะติดตั้งให้ครบ (รันซ้ำได้ปลอดภัย ใช้ตอนอัปเดตโค้ดด้วย):
- LibreOffice แบบไม่มีหน้าต่าง, ฟอนต์ TH SarabunPSK และตั้งให้ใช้แทน Cordia New / TH Sarabun New
- swap 2 GB และเขตเวลา Asia/Bangkok
- ปิดการพักเครื่อง ปิดฝาจอแล้วไม่หลับ และปิดตัวประหยัดพลังงาน/ล็อกหน้าจอของ Xubuntu
- บริการ `school-api`, `school-tunnel` (ngrok), สำรองฐานข้อมูลทุกคืน 02:30 และตัวเฝ้าระวังทุก 5 นาที
- อัปเดตความปลอดภัยอัตโนมัติ (ไม่รีบูตเอง)

## ไดรฟ์พัง / ลงเครื่องใหม่จากไฟล์สำรอง (.zip)
ไฟล์สำรองทั้งระบบ `school_backup_….zip` (ระบบสร้างทุกคืน เก็บ 7 วัน และส่งขึ้น Google Drive ถ้าตั้งค่าไว้) มีทั้ง **ตัวโปรแกรม** (โฟลเดอร์ `program/`) และ **ข้อมูลทั้งหมด** ไฟล์เดียวพอ
1. ลง Xubuntu ใหม่ แล้วดาวน์โหลดไฟล์ .zip ล่าสุดจาก Google Drive (โฟลเดอร์ SchoolBackup) หรือ USB
2. ลงโปรแกรมจากโฟลเดอร์ program/ ในไฟล์:
```bash
mkdir -p ~/apps && cd ~/apps
unzip ~/Downloads/school_backup_*.zip 'program/*' -d restore_tmp
mv restore_tmp/program schooltranscription && rmdir restore_tmp
cd schooltranscription
echo "<token ngrok จาก dashboard.ngrok.com>" > ngrok_token.txt   # ไม่มีในไฟล์สำรองเพื่อความปลอดภัย
sudo bash deploy/linux/setup.sh        # ติดตั้ง rclone ให้ด้วย
```
3. กู้ข้อมูล เลือกทางใดทางหนึ่ง:
   - **ผ่านหน้าเว็บ:** บน **หน้าจอเครื่องเซิร์ฟเวอร์นี้** เปิด `http://localhost:8000` จะขึ้นหน้า "กู้คืนระบบ" เอง (เพราะฐานข้อมูลยังว่าง) แล้วเลือกไฟล์ .zip เดิม (ทำจากเครื่องอื่นหรือผ่าน ngrok ไม่ได้ เพื่อความปลอดภัย)
   - **ผ่านคำสั่ง:** `sudo systemctl stop school-api && venv/bin/python restore_archive.py ~/Downloads/school_backup_*.zip && sudo systemctl start school-api`
4. ครูเข้าสู่ระบบด้วย **รหัสครู** เป็น PIN แล้วตั้ง PIN ใหม่ (ไฟล์สำรองไม่มี PIN)
5. ไฟล์ ปพ.5 ที่ไม่อยู่ในไฟล์สำรอง ระบบสร้างใหม่จากฐานข้อมูลให้เองตอนกลางคืน (หรือใช้ชุด "รวม ปพ.5" ของวันอาทิตย์)
6. ตั้งค่า Google Drive ใหม่อีกครั้ง (ตั้งค่า → สำรองทั้งระบบ → วิธีตั้งค่า) เพราะบัญชี rclone อยู่ในเครื่องเดิม

## ตรวจหลังติดตั้ง
1. `bash deploy/linux/status.sh` → ต้องขึ้นเครื่องหมายถูกทุกบรรทัด
2. `venv/bin/python deploy/linux/check_pdf.py` → ดูภาพใน `tmp/pdf_check/` แล้วเทียบกับ `_ปพ5_print_ready.pdf` เดิมให้ครบ 7 หน้า (ฟอนต์ไทย, ตัดหน้า, ตารางไม่ล้นขอบ) — เครื่อง Windows เดิมเปลี่ยนมาใช้ LibreOffice แล้วเช่นกัน ไฟล์จึงควรออกมาเหมือนกัน
3. `venv/bin/python -m unittest discover -s tests` → ต้องขึ้น OK
4. `venv/bin/python scratch/verify_attendance.py` → ต้องขึ้น `OK: no problems found`
5. เปิด `http://<IP เครื่อง>:8000` จากเครื่องอื่นในโรงเรียน และเปิดลิงก์ ngrok จากมือถือ
6. ล็อกอินครูหนึ่งคนและนักเรียนหนึ่งคน ลองบันทึกเช็คชื่อและคะแนนอย่างละครั้ง

## เตรียมเครื่องให้เปิดตลอด (ทำครั้งเดียว)
- **ตั้ง IP ให้คงที่** จองในเราเตอร์ตาม MAC address หรือตั้ง static IP ในเครื่อง ลิงก์ในวง LAN จะไม่เปลี่ยน
- **ไม่ต้องล็อกอินหน้าจอค้างไว้** บริการทำงานตั้งแต่เปิดเครื่อง จะปล่อยหน้าจอล็อกอินไว้ก็ได้
- **ปิดฝาจอได้** ตั้งให้ไม่หลับแล้ว แต่ควรวางบนโต๊ะแข็งที่ระบายอากาศได้ ไม่วางบนผ้าหรือในลิ้นชัก
- **เสียบไฟไว้ตลอด** แบตทำหน้าที่สำรองไฟ (ประมาณ 1 ชั่วโมง)
  - ไฟดับและแบตเหลือ 15% ระบบจะหยุดบริการ สำรองฐานข้อมูล แล้วปิดเครื่องเองอย่างปลอดภัย (`journalctl -t school-battery`)
  - เปลี่ยนเปอร์เซ็นต์ได้ที่ `BATTERY_SHUTDOWN_PERCENT` ใน `/etc/schooltranscription.env` แล้ว `sudo systemctl restart school-battery.timer`
  - ถ้าอยากถนอมแบต (เสียบไฟค้างตลอดทำแบตเสื่อมเร็ว) ตั้งเพดานชาร์จ 80% ได้ถ้าเครื่องรองรับ: `sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold <<< 80` แลกกับเวลาสำรองไฟสั้นลงเหลือราว 45 นาที
- **ไฟมาแล้วต้องกดเปิดเครื่องเอง** โน้ตบุ๊กส่วนใหญ่ไม่เปิดเองหลังปิดจากแบตหมด ให้ลองหา `Restore on AC Power Loss` หรือ `AC Recovery` ใน BIOS ถ้าไม่มีก็ต้องมีคนไปกดปุ่มเปิด
- **ห้ามเปิดโปรแกรมหนักบนเครื่องนี้** RAM 4 GB เหลือไม่มาก เบราว์เซอร์ที่เปิดทิ้งไว้แย่งแรมกับ LibreOffice
- **สำรองออกนอกเครื่องสัปดาห์ละครั้ง** คัดลอกไฟล์ล่าสุดใน `backups/auto/` ไป USB หรือ Google Drive ของโรงเรียน ถ้าดิสก์เสียไฟล์สำรองในเครื่องจะหายไปด้วย

## คำสั่งที่ใช้บ่อย
| งาน | คำสั่ง |
|---|---|
| ดูสถานะทุกอย่าง | `bash deploy/linux/status.sh` |
| ดูสถานะบริการ | `systemctl status school-api school-tunnel` |
| ดู log | `journalctl -u school-api -f` |
| restart หลังแก้โค้ด | `sudo systemctl restart school-api` |
| สำรองทันที | `bash deploy/linux/backup_db.sh` (ไฟล์อยู่ใน `backups/auto/`) |
| อัปเดตโค้ด / ติดตั้งซ้ำ | `sudo bash deploy/linux/setup.sh` |
| ตรวจว่าต้องรีบูตไหม | `cat /var/run/reboot-required 2>/dev/null` (ถ้ามี ให้รีบูตช่วงเย็นหรือวันหยุด) |

## เมื่อมีปัญหา
| อาการ | ทำอะไร |
|---|---|
| เปิดเว็บไม่ได้แม้ใน LAN | `bash deploy/linux/status.sh` แล้วดู `journalctl -u school-api -n 50` |
| เปิดใน LAN ได้ แต่ลิงก์ออนไลน์ไม่ได้ | `sudo systemctl restart school-tunnel` แล้วดู log ของ tunnel (token หรือเน็ตโรงเรียน) |
| ปพ.5 PDF ฟอนต์เพี้ยนหรือไม่มี PDF | `fc-match "TH SarabunPSK"` แล้วรัน `check_pdf.py` ใหม่ ถ้า LibreOffice ค้างให้ `pkill soffice` |
| เครื่องช้าตอนกลางคืน | ปกติ ระบบสร้างไฟล์ ปพ.5 และ PDF ใหม่หลังเที่ยงคืน ใช้เวลาประมาณ 30–60 นาที |
| ข้อมูลผิดหลังไฟดับ | หยุดบริการ แล้วกู้จากไฟล์ล่าสุดใน `backups/auto/` (`gunzip` แล้ววางแทน `school_archive.db`) |
| เครื่องปิดเองตอนไฟดับ | ปกติ (แบตใกล้หมด) ไฟมาแล้วกดเปิดเครื่อง บริการจะเริ่มเอง แล้วรัน `status.sh` ตรวจ |

## ข้อควรรู้
- ต้องรัน uvicorn แบบ **1 worker เท่านั้น** เพราะคิวอัปเดตไฟล์ ปพ.5 และ lock ของไฟล์อยู่ในโปรเซสเดียว ตั้งไว้ในบริการแล้ว
- ตัวแปลง PDF ใช้ LibreOffice ทั้งสองระบบ (ประมาณ 4 วินาที/ไฟล์) ถ้าจำเป็นต้องกลับไปใช้ Excel บน Windows ตั้ง `PP5_PDF_ENGINE=excel`
- บน Linux ระบบสร้าง PDF ล่วงหน้าเบื้องหลังให้เอง ด้วยลำดับความสำคัญต่ำ จึงไม่มีหน้าต่าง "Publishing..." แบบ Windows
- หลังเที่ยงคืน ระบบจะนับเวลาเรียนถึงวันใหม่และสร้างไฟล์ ปพ.5 กับ PDF ใหม่ทั้งหมด
- รหัสลงชื่อเข้าใช้ (`SCHOOL_AUTH_SECRET`) และ token ngrok ย้ายไปอยู่ใน `/etc/schooltranscription.env` ซึ่งอ่านได้เฉพาะ root ไฟล์ `auth_secret.txt` และ `ngrok_token.txt` ในโฟลเดอร์โปรเจกต์จะถูกลบ
- ตัวเฝ้าระวัง restart บริการเองเมื่อเว็บไม่ตอบ 3 ครั้งติดกัน (ดูได้ที่ `journalctl -t school-watchdog`)
- ครูยังล็อกอินค้างได้หลังย้ายเครื่อง เพราะใช้รหัสลงชื่อเข้าใช้ชุดเดิม
