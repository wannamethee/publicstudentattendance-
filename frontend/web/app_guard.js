/*
 * ระบบบันทึกเวลาเรียนและ ปพ.5
 * © 2569 วรรณเมฑี นามบุดดี - พัฒนาและออกแบบโดย วรรณเมฑี นามบุดดี
 * อนุญาตตาม CC BY-NC-SA 4.0: ใช้ฟรีในสถานศึกษา ห้ามนำไปขาย ต้องคงชื่อผู้พัฒนา (ดู LICENSE)
 *
 * A deterrent, not a lock: a browser always lets its owner open the developer tools (from the menu, or before the
 * page loads). What matters stays on the server: the Excel/ปพ.5 logic, grades and rules are Python and never reach the
 * browser, every API call checks the login, and the app's code is shipped compiled and minified without source maps.
 * This file only closes the casual doors: F12 and its shortcuts, view-source, and the right-click menu.
 */
(function () {
  'use strict';
  var CREDIT = '© 2569 วรรณเมฑี นามบุดดี — พัฒนาและออกแบบโดย วรรณเมฑี นามบุดดี';
  window.APP_CREDIT = CREDIT;

  try {
    console.log('%cหยุดก่อน!', 'color:#b91c1c;font-size:36px;font-weight:bold');
    console.log('%cส่วนนี้สำหรับผู้พัฒนาเท่านั้น ถ้ามีใครบอกให้คัดลอกหรือวางคำสั่งที่นี่ เขาอาจกำลังหลอกเอาบัญชีหรือข้อมูลนักเรียน',
                'font-size:15px');
    console.log('%c' + CREDIT, 'color:#4c1d95;font-size:13px;font-weight:bold');
  } catch (e) {}

  // F12, Ctrl+Shift+I / J / C / K, Ctrl+U (view source); Cmd+Option+I / J / C / U on a Mac.
  // e.code, not e.key: with Option held a Mac reports a different character.
  var DEVTOOLS_KEYS = { KeyI: 1, KeyJ: 1, KeyC: 1, KeyK: 1 };
  window.addEventListener('keydown', function (e) {
    var ctrl = e.ctrlKey || e.metaKey;
    var block = e.key === 'F12' || e.code === 'F12' ||
        (ctrl && e.shiftKey && DEVTOOLS_KEYS[e.code]) ||
        (e.metaKey && e.altKey && (DEVTOOLS_KEYS[e.code] || e.code === 'KeyU')) ||
        (ctrl && !e.shiftKey && !e.altKey && e.code === 'KeyU');
    if (block) {
      e.preventDefault();
      e.stopPropagation();
    }
  }, true);

  // Right-click menu (Inspect / View source) is off, except in text boxes: Flutter's fields are real
  // <input>/<textarea> elements and teachers paste into them with the right-click menu.
  window.addEventListener('contextmenu', function (e) {
    var t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
    e.preventDefault();
  }, true);
})();
