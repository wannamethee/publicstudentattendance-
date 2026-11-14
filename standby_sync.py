# -*- coding: utf-8 -*-
"""
ระบบสองเครื่อง: Linux = เครื่องหลัก (โรงเรียน)  /  Windows = เครื่องสำรอง (เครื่องแอดมิน ใช้ที่บ้านได้)

กฎข้อเดียว: ทำงานรับครูได้ทีละเครื่องเท่านั้น เครื่องที่ทำงานล่าสุดคือข้อมูลจริง ไม่มีการรวมข้อมูลสองฝั่ง
ครูเข้าผ่านลิงก์ ngrok อย่างเดียว ลิงก์จึงตามเครื่องที่เปิดอุโมงค์ ngrok อยู่

บน Windows (เครื่องสำรอง):
  python standby_sync.py status     ดูสถานะทั้งสองเครื่อง
  python standby_sync.py sync       ดึงสำเนาจาก Linux (ตั้งเวลาให้รันเองทุก 5 นาที ด้วย setup_standby_windows.bat)
  python standby_sync.py takeover   Linux ล่ม -> Windows เปิดรับงานแทน
  python standby_sync.py handback   Linux กลับมา -> ส่งข้อมูลทั้งหมดคืน แล้วให้ Linux ทำงานต่อ
บน Linux (systemd และ ssh เรียกใช้เอง ไม่ต้องสั่งด้วยมือ):
  python standby_sync.py run-guarded -- <คำสั่งเซิร์ฟเวอร์>   เริ่มเซิร์ฟเวอร์เฉพาะเมื่อ Windows ไม่ได้ทำงานแทนอยู่
  python standby_sync.py remote <info|manifest|pack|hold|receive>

ข้อมูลที่ซิงค์: school_archive.db (สำเนาด้วย SQLite backup API ไม่ก๊อปไฟล์ดิบระหว่างเขียน)
และโฟลเดอร์ outputs, uploads, output, data (เฉพาะไฟล์ที่เปลี่ยน)
ช่องทางรับส่ง: ssh ผ่านเครือข่ายส่วนตัว Tailscale (ไม่เปิดอะไรออกอินเทอร์เน็ต)
"""
import hashlib
import io
import json
import os
import shlex
import shutil
import socket
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DB_NAME = "school_archive.db"
SYNC_DIRS = ("outputs", "uploads", "output", "data")
EXCLUDE_PREFIXES = ("data/pdf_page_cache/",)
ACTIVE_FLAG = "STANDBY_ACTIVE"      # Windows: กำลังทำงานแทน Linux อยู่
HELD_FLAG = "HELD_BY_STANDBY"       # Linux: ห้ามเปิดรับงาน เพราะ Windows ทำงานแทนอยู่
GUARD_EXIT = 75                     # systemd: RestartPreventExitStatus=75 -> ไม่เริ่มใหม่เอง
CONFIG_FILE = "standby_config.json"
STATE_FILE = "standby_state.json"
LOG_FILE = "standby_sync.log"
def _domain_file() -> str:
    """The school's fixed ngrok domain, kept in ngrok_domain.txt (git-ignored) like the token."""
    try:
        return (Path(__file__).resolve().parent / "ngrok_domain.txt").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


DEFAULT_DOMAIN = _domain_file()
LINUX_UNITS = ("school-tunnel.service", "school-api.service")
MTIME_SLACK = 2                     # zip/FAT เก็บเวลาไฟล์ละเอียด 2 วินาที


class StandbyError(Exception):
    pass


# --------------------------------------------------------------------------- basics
def node_id() -> str:
    """Short fingerprint of this machine (shown by /api/health; the hostname itself stays private)."""
    name = (os.environ.get("SCHOOL_NODE_NAME") or socket.gethostname()).strip().lower()
    return hashlib.sha256(name.encode("utf-8")).hexdigest()[:12]


def log(msg: str) -> None:
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    try:
        print(line, file=sys.stderr, flush=True)
    except Exception:
        pass
    try:
        with open(ROOT / LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def load_config() -> dict:
    domain = os.environ.get("NGROK_DOMAIN") or DEFAULT_DOMAIN
    cfg = {
        "primary_ssh": "",
        "primary_dir": "",
        "primary_python": "venv/bin/python",
        "public_url": os.environ.get("STANDBY_PUBLIC_URL") or f"https://{domain}",
        "port": int(os.environ.get("APP_PORT") or 8000),
        "ssh_timeout": 10,
        "transfer_timeout": 7200,
    }
    p = ROOT / CONFIG_FILE
    if p.exists():
        cfg.update(json.loads(p.read_text(encoding="utf-8")))
    return cfg


def load_state() -> dict:
    try:
        return json.loads((ROOT / STATE_FILE).read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(st: dict) -> None:
    tmp = ROOT / (STATE_FILE + ".tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, ROOT / STATE_FILE)


def _ago(ts) -> str:
    if not ts:
        return "ไม่เคย"
    m = int((time.time() - float(ts)) // 60)
    when = datetime.fromtimestamp(float(ts)).strftime("%d/%m %H:%M")
    if m < 60:
        return f"{when} ({m} นาทีก่อน)"
    if m < 60 * 48:
        return f"{when} ({m // 60} ชั่วโมงก่อน)"
    return f"{when} ({m // 1440} วันก่อน)"


def _health(url: str, timeout: float = 8):
    req = urllib.request.Request(url.rstrip("/") + "/api/health",
                                 headers={"ngrok-skip-browser-warning": "1", "User-Agent": "school-standby"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode("utf-8"))
            return data if data.get("status") == "ok" else None
    except Exception:
        return None   # ngrok "offline"/502 pages, timeouts and no network all mean: nobody answers


def public_health(cfg: dict):
    return _health(cfg["public_url"], timeout=10)


def local_health(cfg: dict):
    return _health(f"http://127.0.0.1:{cfg['port']}", timeout=3)


# --------------------------------------------------------------------------- data
def _skip(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    if rel.startswith(EXCLUDE_PREFIXES) or name.startswith(("~$", ".standby")):
        return True
    return name.endswith((".tmp", ".part", ".lock"))


def _check_rel(rel: str) -> None:
    parts = rel.split("/")
    if rel.startswith("/") or ":" in rel or ".." in parts or parts[0] not in SYNC_DIRS or _skip(rel):
        raise StandbyError(f"ชื่อไฟล์ในชุดข้อมูลไม่ถูกต้อง: {rel!r}")


def manifest(root: Path) -> dict:
    out = {}
    for d in SYNC_DIRS:
        base = root / d
        if not base.is_dir():
            continue
        for p in base.rglob("*"):
            if not p.is_file():
                continue
            rel = p.relative_to(root).as_posix()
            if _skip(rel):
                continue
            st = p.stat()
            out[rel] = [st.st_size, int(st.st_mtime)]
    return out


def _same(a, b) -> bool:
    return bool(a and b) and a[0] == b[0] and abs(a[1] - b[1]) <= MTIME_SLACK


def db_marker(root: Path) -> float:
    """Last write time of the database (WAL included): grows whenever anyone saves anything."""
    m = 0.0
    for suffix in ("", "-wal"):
        p = root / (DB_NAME + suffix)
        if p.exists():
            m = max(m, p.stat().st_mtime)
    return m


def db_snapshot(root: Path, dest: Path) -> None:
    """Consistent copy of the live DB (safe while the server writes) as one self-contained file."""
    src = sqlite3.connect(f"file:{(root / DB_NAME).as_posix()}?mode=ro", uri=True, timeout=30)
    dst = sqlite3.connect(str(dest))
    try:
        src.backup(dst)
        dst.execute("PRAGMA journal_mode=DELETE;")
        ok = dst.execute("PRAGMA integrity_check;").fetchone()[0]
    finally:
        dst.close()
        src.close()
    if ok != "ok":
        raise StandbyError(f"สำเนาฐานข้อมูลเสีย: {ok}")


def backup_db(root: Path, label: str, keep: int = 30):
    """Keep a copy of this machine's DB before it is replaced (backups/standby/<label>_<time>.db)."""
    if not (root / DB_NAME).exists():
        return None
    d = root / "backups" / "standby"
    d.mkdir(parents=True, exist_ok=True)
    dest = d / f"{label}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.db"
    db_snapshot(root, dest)
    for old in sorted(d.glob("*.db"), key=lambda p: p.stat().st_mtime)[:-keep]:
        old.unlink(missing_ok=True)
    return dest


def pack(root: Path, peer_manifest: dict, out) -> int:
    """Write a .tar.gz bundle: DB snapshot + files that differ from the peer + this side's file list."""
    full = manifest(root)
    want = [r for r, v in full.items() if not _same(peer_manifest.get(r), v)]
    marker = db_marker(root)
    sent = 0
    with tempfile.TemporaryDirectory() as td:
        snap = Path(td) / DB_NAME
        db_snapshot(root, snap)
        with tarfile.open(fileobj=out, mode="w|gz", compresslevel=1) as tar:
            tar.add(str(snap), arcname="db/" + DB_NAME)
            for rel in want:
                try:
                    tar.add(str(root / rel), arcname="files/" + rel)
                    sent += 1
                except FileNotFoundError:
                    full.pop(rel, None)       # deleted while packing
            meta = json.dumps({"node": node_id(), "created": time.time(), "db_marker": marker,
                               "manifest": full, "files": sent}, ensure_ascii=False).encode("utf-8")
            info = tarfile.TarInfo("meta.json")   # written last: a cut-off stream has no meta -> rejected
            info.size, info.mtime = len(meta), int(time.time())
            tar.addfile(info, io.BytesIO(meta))
    return sent


def apply_bundle(root: Path, src, *, keep_old: str = "") -> dict:
    """Unpack a bundle into staging, verify it, then replace DB and files.

    The server on this machine must be stopped. keep_old="label" keeps every file that gets
    replaced or removed under backups/standby/<label>_<time>/ (used when the primary receives data back).
    """
    staging = root / ".standby_staging"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir()
    meta, staged_db, staged = None, None, []
    try:
        with tarfile.open(fileobj=src, mode="r|gz") as tar:
            for m in tar:
                if not m.isfile():
                    continue
                if m.name == "meta.json":
                    meta = json.loads(tar.extractfile(m).read().decode("utf-8"))
                    continue
                if m.name == "db/" + DB_NAME:
                    target = staging / DB_NAME
                    staged_db = target
                elif m.name.startswith("files/"):
                    rel = m.name[len("files/"):]
                    _check_rel(rel)
                    target = staging / "files" / rel
                    staged.append((rel, target, m.mtime))
                else:
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(m) as f, open(target, "wb") as g:
                    shutil.copyfileobj(f, g, 1024 * 1024)
                os.utime(target, (m.mtime, m.mtime))
        if meta is None or staged_db is None:
            raise StandbyError("ชุดข้อมูลไม่ครบ (การส่งขาดกลางทาง) — ไม่ได้แก้ไขอะไร")
        chk = sqlite3.connect(str(staged_db))
        try:
            ok = chk.execute("PRAGMA integrity_check;").fetchone()[0]
        finally:
            chk.close()
        if ok != "ok":
            raise StandbyError(f"ฐานข้อมูลที่ได้รับเสีย ({ok}) — ไม่ได้แก้ไขอะไร")

        old_dir = None
        if keep_old:
            old_dir = root / "backups" / "standby" / f"{keep_old}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
            backup_db(root, keep_old)

        def _stash(rel: str) -> None:
            p = root / rel
            if old_dir is not None:
                dest = old_dir / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(p), str(dest))
            else:
                p.unlink()

        # 1) database first: if it cannot be replaced, nothing else is touched
        for suffix in ("-wal", "-shm"):
            (root / (DB_NAME + suffix)).unlink(missing_ok=True)
        os.replace(staged_db, root / DB_NAME)

        # 2) changed files
        failed = []
        for rel, target, mtime in staged:
            dest = root / rel
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                if dest.exists() and old_dir is not None:
                    _stash(rel)
                os.replace(target, dest)
            except OSError as e:          # e.g. the file is open in Excel on Windows
                failed.append(f"{rel}: {e}")

        # 3) files the source no longer has
        removed = 0
        for rel in set(manifest(root)) - set(meta["manifest"]):
            try:
                _stash(rel)
                removed += 1
            except OSError as e:
                failed.append(f"{rel}: {e}")
        return {"files": len(staged), "removed": removed, "failed": failed,
                "source_node": meta["node"], "db_marker": meta["db_marker"], "created": meta["created"],
                "kept_old": str(old_dir.relative_to(root)) if old_dir and old_dir.exists() else ""}
    finally:
        shutil.rmtree(staging, ignore_errors=True)


# --------------------------------------------------------------------------- services
def _fake_services(role: str, action: str) -> bool:
    fake = os.environ.get("STANDBY_FAKE_SERVICES")
    if not fake:
        return False
    with open(fake, "a", encoding="utf-8") as f:
        f.write(f"{role} {action}\n")
    return True


def linux_services(action: str) -> None:
    if _fake_services("primary", action):
        return
    units = LINUX_UNITS if action == "stop" else tuple(reversed(LINUX_UNITS))
    r = subprocess.run(["sudo", "-n", "systemctl", action, *units], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise StandbyError(f"systemctl {action} ไม่สำเร็จ: {r.stderr.strip()}")


def windows_stop_server(cfg: dict) -> None:
    if _fake_services("standby", "stop"):
        return
    ps = (f"Get-NetTCPConnection -LocalPort {int(cfg['port'])} -State Listen -ErrorAction SilentlyContinue | "
          "ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }; "
          "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | "
          "Where-Object { $_.CommandLine -like '*start_ngrok*' } | "
          "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, timeout=90)
    for _ in range(20):
        if not local_health(cfg):
            return
        time.sleep(1)
    raise StandbyError("หยุดเซิร์ฟเวอร์บน Windows ไม่สำเร็จ")


def windows_start_server(cfg: dict) -> None:
    if _fake_services("standby", "start"):
        return
    subprocess.Popen(["wscript.exe", str(ROOT / "launch_background.vbs")], cwd=str(ROOT))
    for _ in range(60):
        if local_health(cfg):
            return
        time.sleep(1)
    raise StandbyError("เปิดเซิร์ฟเวอร์บน Windows ไม่สำเร็จภายใน 60 วินาที")


def _wait_public(cfg: dict, node: str, seconds: int = 90) -> bool:
    if os.environ.get("STANDBY_FAKE_SERVICES"):
        return True
    end = time.time() + seconds
    while time.time() < end:
        h = public_health(cfg)
        if h and h.get("node") == node:
            return True
        time.sleep(5)
    return False


# --------------------------------------------------------------------------- talking to the primary
def _remote_cmd(cfg: dict, args: list):
    target = cfg.get("primary_ssh") or ""
    if not target:
        raise StandbyError(f"ยังไม่ได้ตั้งค่าเครื่อง Linux ใน {CONFIG_FILE} (primary_ssh)")
    if target.startswith("local:"):                      # tests: the "primary" is another folder here
        d = target[len("local:"):]
        return [sys.executable, str(Path(d) / "standby_sync.py"), "remote", *args], d
    remote = (f"cd {shlex.quote(cfg['primary_dir'])} && "
              f"{cfg['primary_python']} standby_sync.py remote {' '.join(args)}")
    return ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"ConnectTimeout={int(cfg['ssh_timeout'])}", "-o", "ServerAliveInterval=15",
            target, remote], None


def remote(cfg: dict, args: list, *, data: bytes = None, stdin=None, stdout=None, timeout: float = 60):
    cmd, cwd = _remote_cmd(cfg, args)
    env = None
    if cwd:   # local test "primary": give it its own machine fingerprint
        env = {**os.environ, "SCHOOL_NODE_NAME": f"primary@{cwd}"}
    try:
        r = subprocess.run(cmd, cwd=cwd, env=env, input=data, stdin=stdin,
                           stdout=stdout if stdout is not None else subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise StandbyError(f"ติดต่อเครื่อง Linux ไม่ได้: {e}")
    if r.returncode != 0:
        err = (r.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        raise StandbyError("เครื่อง Linux ตอบผิดพลาด: " + (err[-1] if err else f"exit {r.returncode}"))
    return r


def remote_json(cfg: dict, args: list, **kw) -> dict:
    r = remote(cfg, args, **kw)
    return json.loads(r.stdout.decode("utf-8"))


def pull(cfg: dict, st: dict) -> dict:
    """Copy the primary's data onto this machine (server here must not be running)."""
    fd, tmp = tempfile.mkstemp(prefix=".standby_bundle_", suffix=".tar.gz", dir=str(ROOT))
    try:
        with os.fdopen(fd, "wb") as f:
            remote(cfg, ["pack"], data=json.dumps(manifest(ROOT)).encode("utf-8"), stdout=f,
                   timeout=cfg["transfer_timeout"])
        with open(tmp, "rb") as f:
            res = apply_bundle(ROOT, f)
    finally:
        Path(tmp).unlink(missing_ok=True)
    st.update(last_sync=time.time(), primary_node=res["source_node"], primary_db_marker=res["db_marker"])
    save_state(st)
    log(f"ซิงค์จาก Linux สำเร็จ: ไฟล์ใหม่/เปลี่ยน {res['files']}, ลบ {res['removed']}"
        + (f", ทับไม่ได้ {len(res['failed'])} ไฟล์ (ปิดไฟล์ที่เปิดค้างไว้ แล้วรอรอบถัดไป)" if res["failed"] else ""))
    return res


def _hold_primary(cfg: dict, st: dict) -> bool:
    """Tell the primary to stop serving and stay stopped. Returns False if it cannot be reached."""
    try:
        res = remote_json(cfg, ["hold"], timeout=180)
    except StandbyError as e:
        log(f"สั่งพัก Linux ไม่ได้ ({e})")
        return False
    st["primary_held"] = True
    last = float(st.get("primary_db_marker") or 0)
    # both markers come from the primary's own clock, so any increase means writes after the last sync
    if not res.get("already") and float(res.get("db_marker") or 0) > last and st.get("active_since"):
        st["primary_unsynced_backup"] = res.get("backup", "")
        log("!! Linux มีการบันทึกข้อมูลหลังการซิงค์ครั้งสุดท้าย (ก่อนล่ม) ข้อมูลส่วนนั้นจะไม่อยู่บน Windows "
            f"แต่เก็บไว้ที่เครื่อง Linux: {res.get('backup')}")
    save_state(st)
    log("สั่ง Linux หยุดรับงานแล้ว (จะไม่เปิดเองจนกว่าจะสั่ง handback)")
    return True


# --------------------------------------------------------------------------- Windows commands
def cmd_status(cfg: dict) -> int:
    st = load_state()
    me = node_id()
    active = (ROOT / ACTIVE_FLAG).exists()
    print(f"เครื่องนี้ (Windows สำรอง): {'กำลังทำงานแทน Linux' if active else 'โหมดสำรอง (รับสำเนา)'}")
    print(f"  เซิร์ฟเวอร์บนเครื่องนี้: {'เปิดอยู่' if local_health(cfg) else 'ปิดอยู่'}")
    print(f"  ซิงค์ครั้งล่าสุด: {_ago(st.get('last_sync'))}")
    h = public_health(cfg)
    if not h:
        who = "ไม่มีเครื่องไหนตอบ (ครูเข้าระบบไม่ได้)"
    elif h.get("node") == me:
        who = "Windows เครื่องนี้"
    elif h.get("node") == st.get("primary_node"):
        who = "Linux (เครื่องหลัก)"
    else:
        who = f"เครื่องอื่น ({h.get('node', 'ไม่ทราบ')})"
    print(f"ลิงก์ออนไลน์ {cfg['public_url']} -> {who}")
    try:
        info = remote_json(cfg, ["info"], timeout=30)
        print(f"Linux: ติดต่อได้, {'ถูกพักไว้ (Windows ทำงานแทน)' if info['held'] else 'ทำงานปกติ'}, "
              f"บันทึกข้อมูลล่าสุด {_ago(info['db_marker'])}")
    except StandbyError as e:
        print(f"Linux: ติดต่อไม่ได้ ({e})")
    if st.get("primary_unsynced_backup"):
        print(f"!! มีข้อมูลบน Linux ช่วงก่อนล่มที่ไม่ได้ซิงค์มา เก็บไว้ที่ Linux: {st['primary_unsynced_backup']}")
    return 0


def cmd_sync(cfg: dict) -> int:
    st = load_state()
    if (ROOT / ACTIVE_FLAG).exists():
        # Windows is the live system: never pull over it. Keep it serving and keep Linux parked.
        if not local_health(cfg):
            log("เครื่องนี้ทำงานแทนอยู่แต่เซิร์ฟเวอร์ปิด (เช่น เพิ่งรีสตาร์ต) -> เปิดใหม่")
            windows_start_server(cfg)
        if not st.get("primary_held"):
            _hold_primary(cfg, st)
        return 0
    if local_health(cfg):
        log("ข้ามการซิงค์: มีเซิร์ฟเวอร์เปิดอยู่บนเครื่องนี้ (ปิดก่อน หรือใช้ takeover ถ้าตั้งใจให้ทำงานแทน)")
        return 2
    try:
        pull(cfg, st)
    except StandbyError as e:
        log(f"ซิงค์ไม่สำเร็จ: {e}")
        return 1
    return 0


def cmd_takeover(cfg: dict, force: bool) -> int:
    st = load_state()
    me = node_id()
    if (ROOT / ACTIVE_FLAG).exists():
        if not local_health(cfg):
            windows_start_server(cfg)
        print("เครื่องนี้ทำงานแทนอยู่แล้ว")
        return 0
    h = public_health(cfg)
    if h and h.get("node") != me and not force:
        print("ยกเลิก: ลิงก์ออนไลน์ยังมีเครื่องอื่นตอบอยู่ (Linux น่าจะยังทำงานปกติ) ครูยังใช้งานได้\n"
              "ถ้าแน่ใจว่าต้องการสลับ ให้ใช้ takeover --force (Linux จะถูกสั่งพักถ้าติดต่อได้)")
        return 1
    if _hold_primary(cfg, st):
        log("Linux ติดต่อได้: ดึงข้อมูลล่าสุดก่อนเปิดรับงาน")
        pull(cfg, st)
    else:
        if not st.get("last_sync") and not force:
            print("ยกเลิก: เครื่องนี้ยังไม่เคยซิงค์ข้อมูลจาก Linux เลย")
            return 1
        st["primary_held"] = False
        log(f"Linux ติดต่อไม่ได้: ใช้ข้อมูลจากการซิงค์ครั้งล่าสุด {_ago(st.get('last_sync'))}")
    st["active_since"] = time.time()
    save_state(st)
    (ROOT / ACTIVE_FLAG).write_text(json.dumps({"since": st["active_since"]}), encoding="utf-8")
    windows_start_server(cfg)
    if _wait_public(cfg, me):
        log(f"Windows เปิดรับงานแทนแล้ว ครูเข้าได้ที่ {cfg['public_url']}")
    else:
        log("เซิร์ฟเวอร์เปิดแล้ว แต่ลิงก์ออนไลน์ยังไม่ชี้มาที่เครื่องนี้ (ตรวจอินเทอร์เน็ต/ngrok)")
    return 0


def cmd_handback(cfg: dict, force: bool) -> int:
    st = load_state()
    if not (ROOT / ACTIVE_FLAG).exists() and not force:
        print("เครื่องนี้ไม่ได้ทำงานแทนอยู่ ไม่มีอะไรต้องส่งคืน")
        return 1
    try:
        peer = remote_json(cfg, ["manifest"], timeout=300)
    except StandbyError as e:
        print(f"ยกเลิก: {e}\nตรวจว่าเครื่อง Linux เปิดอยู่และต่อ Tailscale แล้ว — Windows ยังทำงานแทนต่อตามเดิม")
        return 1
    log("หยุดเซิร์ฟเวอร์บน Windows แล้วส่งข้อมูลทั้งหมดคืนให้ Linux")
    windows_stop_server(cfg)
    fd, tmp = tempfile.mkstemp(prefix=".standby_bundle_", suffix=".tar.gz", dir=str(ROOT))
    try:
        with os.fdopen(fd, "wb") as f:
            sent = pack(ROOT, peer, f)
        with open(tmp, "rb") as f:
            res = remote_json(cfg, ["receive"], stdin=f, timeout=cfg["transfer_timeout"])
    except Exception as e:
        log(f"ส่งคืนไม่สำเร็จ ({e}) -> เปิดเซิร์ฟเวอร์บน Windows กลับมาทำงานแทนต่อ")
        windows_start_server(cfg)
        return 1
    finally:
        Path(tmp).unlink(missing_ok=True)
    (ROOT / ACTIVE_FLAG).unlink(missing_ok=True)
    st.update(last_sync=time.time(), primary_held=False, active_since=None,
              primary_node=res.get("node") or st.get("primary_node"), primary_db_marker=res.get("db_marker"))
    st.pop("primary_unsynced_backup", None)
    save_state(st)
    log(f"ส่งคืนแล้ว: ไฟล์ {sent}, Linux ย้ายไฟล์เดิมที่ถูกแทนไว้ที่ {res.get('kept_old') or '-'}"
        + (f", ทับไม่ได้ {len(res['failed'])} ไฟล์" if res.get("failed") else ""))
    if _wait_public(cfg, st["primary_node"]):
        log(f"Linux กลับมาทำงานแล้ว ครูเข้าได้ที่ {cfg['public_url']}")
    else:
        log("!! Linux รับข้อมูลแล้ว แต่ลิงก์ออนไลน์ยังไม่ตอบจาก Linux — ดูที่ Linux: bash deploy/linux/status.sh")
    return 0


# --------------------------------------------------------------------------- Linux side
def _held() -> bool:
    return (ROOT / HELD_FLAG).exists()


def guard_ok(cfg: dict) -> bool:
    """May this (primary) machine start serving? No while Windows holds the job."""
    if _held():
        log(f"ไม่เริ่มบริการ: มีไฟล์ {HELD_FLAG} (Windows ทำงานแทนอยู่) — รอคำสั่ง handback จาก Windows")
        return False
    h = public_health(cfg)
    if h and h.get("node") != node_id():
        (ROOT / HELD_FLAG).write_text(json.dumps({"since": time.time(), "by": h.get("node"),
                                                  "reason": "boot-guard"}), encoding="utf-8")
        log("ไม่เริ่มบริการ: ลิงก์ออนไลน์มีเครื่องอื่นทำงานอยู่ (Windows ทำงานแทน) — พักไว้จนกว่าจะ handback")
        return False
    return True


def cmd_run_guarded(cfg: dict, argv: list) -> int:
    if not argv:
        raise StandbyError("run-guarded ต้องตามด้วยคำสั่งเซิร์ฟเวอร์")
    if not guard_ok(cfg):
        return GUARD_EXIT
    if os.name == "nt":        # Windows exec does not quote arguments; just run it as a child
        return subprocess.call(argv)
    os.execvp(argv[0], argv)   # Linux: becomes the server process (systemd keeps watching the same PID)
    return 0


def cmd_remote(cfg: dict, sub: str) -> int:
    out = sys.stdout.buffer
    if sub == "info":
        out.write(json.dumps({"node": node_id(), "held": _held(), "db_marker": db_marker(ROOT)}).encode())
    elif sub == "manifest":
        out.write(json.dumps(manifest(ROOT)).encode("utf-8"))
    elif sub == "pack":
        peer = json.loads(sys.stdin.buffer.read().decode("utf-8") or "{}")
        pack(ROOT, peer, out)
    elif sub == "hold":
        if _held():
            out.write(json.dumps({"held": True, "already": True, "db_marker": db_marker(ROOT)}).encode())
        else:
            marker = db_marker(ROOT)
            b = backup_db(ROOT, "held")
            linux_services("stop")
            (ROOT / HELD_FLAG).write_text(json.dumps({"since": time.time(), "reason": "hold"}), encoding="utf-8")
            log("ถูกสั่งพักจาก Windows: หยุดบริการแล้ว")
            out.write(json.dumps({"held": True, "db_marker": marker,
                                  "backup": str(b.relative_to(ROOT)) if b else ""}, ensure_ascii=False).encode())
    elif sub == "receive":
        fd, tmp = tempfile.mkstemp(prefix=".standby_bundle_", suffix=".tar.gz", dir=str(ROOT))
        try:
            with os.fdopen(fd, "wb") as f:
                shutil.copyfileobj(sys.stdin.buffer, f, 1024 * 1024)   # whole bundle first, then apply
            linux_services("stop")
            if not _held():
                (ROOT / HELD_FLAG).write_text(json.dumps({"since": time.time(), "reason": "receive"}),
                                              encoding="utf-8")
            with open(tmp, "rb") as f:
                res = apply_bundle(ROOT, f, keep_old="before_handback")
        finally:
            Path(tmp).unlink(missing_ok=True)
        (ROOT / HELD_FLAG).unlink(missing_ok=True)
        linux_services("start")
        log(f"รับข้อมูลคืนจาก Windows แล้ว ({res['files']} ไฟล์) และเปิดบริการ")
        res.update(node=node_id(), db_marker=db_marker(ROOT))
        out.write(json.dumps(res, ensure_ascii=False).encode("utf-8"))
    else:
        raise StandbyError(f"ไม่รู้จักคำสั่ง remote {sub}")
    out.flush()
    return 0


def main(argv: list) -> int:
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    os.chdir(ROOT)
    if not argv:
        print(__doc__)
        return 1
    cfg = load_config()
    cmd, rest = argv[0], argv[1:]
    force = "--force" in rest
    try:
        if cmd == "status":
            return cmd_status(cfg)
        if cmd == "sync":
            return cmd_sync(cfg)
        if cmd == "takeover":
            return cmd_takeover(cfg, force)
        if cmd == "handback":
            return cmd_handback(cfg, force)
        if cmd == "run-guarded":
            return cmd_run_guarded(cfg, rest[1:] if rest[:1] == ["--"] else rest)
        if cmd == "remote" and rest:
            return cmd_remote(cfg, rest[0])
    except (StandbyError, OSError) as e:
        log(f"ผิดพลาด: {e}")
        return 1
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
