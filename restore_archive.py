"""
กู้คืนระบบทั้งหมดจากไฟล์สำรอง .zip (ใช้บนเครื่องใหม่ หรือเมื่อเปิดหน้าเว็บไม่ได้)

  1. ปิดเซิร์ฟเวอร์ก่อน
  2. python restore_archive.py backups/archives/school_backup_....zip
  3. เปิดเซิร์ฟเวอร์ใหม่

ระบบสำรองฐานข้อมูลเดิมไว้ใน backups/ ก่อนเสมอ • PIN ของครูในเครื่องนี้คงเดิม ครูอื่นใช้รหัสครูเป็น PIN แรก
"""
import sys

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    import archive_backup
    res = archive_backup.restore_archive(sys.argv[1])
    print("กู้คืนเรียบร้อย:", res)
    print("ครูที่ไม่ได้ตั้ง PIN ในเครื่องนี้ ให้เข้าสู่ระบบด้วยรหัสครู แล้วเปลี่ยน PIN ใหม่")
