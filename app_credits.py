"""
ผู้พัฒนาและออกแบบโปรแกรม: วรรณเมฑี นามบุดดี

The developer credit, in one place. Every edition keeps it (the blank copy on GitHub too): the licence
(LICENSE, CC BY-NC-SA 4.0) lets schools use and change the program for free, not sell it, and asks them to keep
this name. It is shown in the app (side menu, login dialog), the web page head, the API and every saved ปพ.5 file.
"""

DEVELOPER = "วรรณเมฑี นามบุดดี"
CREDIT_LINE = "พัฒนาและออกแบบโดย วรรณเมฑี นามบุดดี"
COPYRIGHT = "© 2569 วรรณเมฑี นามบุดดี"
LICENSE_NAME = "CC BY-NC-SA 4.0 (ใช้ฟรีในสถานศึกษา ห้ามนำไปขาย ต้องคงชื่อผู้พัฒนา)"


def info() -> dict:
    return {"developer": DEVELOPER, "credit": CREDIT_LINE, "copyright": COPYRIGHT, "license": LICENSE_NAME}
