const ngrok = require('@ngrok/ngrok');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

// The authtoken is a secret: read it from NGROK_AUTHTOKEN (Linux service env file)
// or from ngrok_token.txt next to this script (git-ignored), never from source code.
function readToken() {
  if (process.env.NGROK_AUTHTOKEN) return process.env.NGROK_AUTHTOKEN.trim();
  const file = path.join(__dirname, 'ngrok_token.txt');
  if (fs.existsSync(file)) return fs.readFileSync(file, 'utf8').trim();
  throw new Error('ไม่พบ ngrok authtoken: ตั้ง NGROK_AUTHTOKEN หรือสร้างไฟล์ ngrok_token.txt');
}
const AUTHTOKEN = readToken();
// The school's fixed ngrok domain: NGROK_DOMAIN (Linux service env file) or ngrok_domain.txt next to this script
// (git-ignored). Without one, ngrok gives a new random link at every start.
function readDomain() {
  if (process.env.NGROK_DOMAIN) return process.env.NGROK_DOMAIN.trim();
  const file = path.join(__dirname, 'ngrok_domain.txt');
  if (fs.existsSync(file)) return fs.readFileSync(file, 'utf8').trim();
  return '';
}
const DOMAIN = readDomain();
const PORT = Number(process.env.APP_PORT || 8000);

// Linux main server only (STANDBY_GUARD=1 in the service env): if the Windows standby has taken over
// the link, back off and stay down until standby_sync.py handback. Checked before every (re)connect,
// so Linux coming back online after an outage never fights Windows for the domain.
const HELD_FLAG = path.join(__dirname, 'HELD_BY_STANDBY');
const GUARD_EXIT = 75;   // systemd RestartPreventExitStatus=75
function nodeId() {
  const name = (process.env.SCHOOL_NODE_NAME || os.hostname()).trim().toLowerCase();
  return crypto.createHash('sha256').update(name, 'utf8').digest('hex').slice(0, 12);
}
async function standbyHoldsLink() {
  if (process.env.STANDBY_GUARD !== '1') return false;
  if (fs.existsSync(HELD_FLAG)) return true;
  const base = process.env.STANDBY_PUBLIC_URL || `https://${DOMAIN}`;
  try {
    const res = await fetch(`${base}/api/health`, {
      headers: { 'ngrok-skip-browser-warning': '1', 'User-Agent': 'school-standby' },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return false;
    const data = await res.json();
    if (data.status === 'ok' && data.node !== nodeId()) {
      fs.writeFileSync(HELD_FLAG, JSON.stringify({ since: Date.now() / 1000, by: data.node, reason: 'tunnel-guard' }));
      return true;
    }
  } catch (_) { /* offline page, timeout, no network: nobody else is serving */ }
  return false;
}

let listener = null;

async function startTunnel() {
  while (true) {
    try {
      if (!listener) {
        if (await standbyHoldsLink()) {
          console.log(`[${new Date().toLocaleTimeString('th-TH')}] เครื่องสำรอง (Windows) ทำงานแทนอยู่ — ไม่เปิดลิงก์ รอคำสั่ง handback`);
          process.exit(GUARD_EXIT);
        }
        console.log(`[${new Date().toLocaleTimeString('th-TH')}] กำลังเชื่อมต่อ Ngrok Tunnel...`);
        listener = await ngrok.forward({
          addr: PORT,
          authtoken: AUTHTOKEN,
          ...(DOMAIN ? { domain: DOMAIN } : {}),
        });
        console.log(`[${new Date().toLocaleTimeString('th-TH')}] ลิงก์ออนไลน์พร้อมใช้งาน: ${listener.url()}`);
      }
      // Check interval
      await new Promise(r => setTimeout(r, 15000));
    } catch (err) {
      console.error(`[${new Date().toLocaleTimeString('th-TH')}] ขัดข้อง:`, err.message || err);
      listener = null;
      console.log('กำลังเชื่อมต่อใหม่อัตโนมัติในอีก 5 วินาที...');
      await new Promise(r => setTimeout(r, 5000));
    }
  }
}

startTunnel();
