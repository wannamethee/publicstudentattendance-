# -*- coding: utf-8 -*-
import os
import re
import subprocess
import sys
import time

def main():
    print("=" * 70)
    print(" กำลังเชื่อมต่อ Cloudflare Tunnel เพื่อสร้างลิงก์ออนไลน์...")
    print("=" * 70)

    cloudflared_path = os.path.join(os.path.dirname(__file__), "cloudflared.exe")
    if not os.path.exists(cloudflared_path):
        print(f"[!] ไม่พบไฟล์ {cloudflared_path}")
        input("กด Enter เพื่อออก...")
        return

    # Start cloudflared process
    proc = subprocess.Popen(
        [cloudflared_path, "tunnel", "--url", "http://localhost:8000"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace"
    )

    url = None
    url_pattern = re.compile(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com")

    for line in proc.stdout:
        match = url_pattern.search(line)
        if match:
            url = match.group(0)
            break

    if url:
        # Copy to clipboard on Windows
        try:
            subprocess.run(["powershell", "-Command", f"Set-Clipboard -Value '{url}'"], check=False)
            copied = " (คัดลอกลง Clipboard เรียบร้อยแล้ว - กดวาง/Paste ใน LINE ได้เลย)"
        except Exception:
            copied = ""

        print("\n" + "=" * 70)
        print("  🎉 ลิงก์ออนไลน์พร้อมใช้งานแล้ว! (เข้าได้จากทุกที่ ทั้งมือถือ/คอม)")
        print(f"  👉 URL: {url}")
        print(f" {copied}")
        print("=" * 70)
        print("  * กรุณาเปิดหน้าต่างนี้ทิ้งไว้ขณะที่มีคนใช้งาน")
        print("  * หากต้องการหยุดแชร์ ให้กด Ctrl + C หรือปิดหน้าต่างนี้")
        print("=" * 70 + "\n")
    else:
        print("[!] ไม่สามารถค้นหาลิงก์ trycloudflare ได้")

    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        print("\nปิดการแชร์ออนไลน์เรียบร้อยแล้ว")

if __name__ == "__main__":
    main()
