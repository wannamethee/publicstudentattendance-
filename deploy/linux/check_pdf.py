"""
Run on the new Linux server after setup: converts one ปพ.5 with LibreOffice, reports time and
peak memory, checks the Thai fonts that were really embedded, and writes page PNGs to compare
with the PDF made by Excel on the old Windows server.
Usage: venv/bin/python deploy/linux/check_pdf.py [path/to/file_ปพ5_filled.xlsx]
"""
import glob
import resource
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT))

import fitz  # PyMuPDF
from excel_mapper import convert_excel_to_pdf_libreoffice

src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(sorted(glob.glob(str(ROOT / "outputs" / "2569-2 *_ปพ5_filled.xlsx")))[0])
out_dir = ROOT / "tmp" / "pdf_check"
out_dir.mkdir(parents=True, exist_ok=True)
pdf = out_dir / "libreoffice.pdf"

print("ไฟล์:", src.name)
for fam in ("TH SarabunPSK", "Cordia New"):
    print(f"  fc-match {fam!r} ->", subprocess.run(["fc-match", fam], capture_output=True, text=True).stdout.strip())

t = time.time()
convert_excel_to_pdf_libreoffice(str(src), str(pdf))
elapsed = time.time() - t
peak_mb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024
print(f"แปลงเสร็จใน {elapsed:.1f} วินาที, หน่วยความจำสูงสุดของ LibreOffice ~{peak_mb:.0f} MB")

doc = fitz.open(pdf)
fonts = sorted({f[3] for page in doc for f in page.get_fonts()})
print("จำนวนหน้า:", doc.page_count, "(ควรเป็น 7)")
print("ฟอนต์ที่ฝังใน PDF:", ", ".join(fonts))
if not any("Sarabun" in f for f in fonts):
    print("!! ไม่พบ TH SarabunPSK ใน PDF: ตรวจการติดตั้งฟอนต์ (fc-list | grep -i sarabun)")
for i, page in enumerate(doc):
    page.get_pixmap(dpi=110).save(str(out_dir / f"page_{i + 1}.png"))
print("ภาพแต่ละหน้าอยู่ที่:", out_dir, "— เปิดเทียบกับ PDF เดิมจาก Excel (ไฟล์ _ปพ5_print_ready.pdf)")
