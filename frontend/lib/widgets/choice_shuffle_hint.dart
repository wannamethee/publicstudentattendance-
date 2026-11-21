/// How the server treats a choice question's choices when it shuffles a student's copy.
/// Same patterns as exams.py (`choice_shuffle_kind`); this copy only drives the hint under a question in the editor,
/// the server decides what students really get.
///   'fixed' -> the choices keep the order written (one of them names other choices, e.g. "ข้อ ก และ ข ถูก")
///   'tail'  -> "ถูกทุกข้อ" / "ไม่มีข้อใดถูก" / "all of the above" stay last, the rest are shuffled
///   null    -> all choices are shuffled
library;

// ASCII word edges, as in exams.py
const _w0 = r'(?<![A-Za-z0-9_])';
const _w1 = r'(?![A-Za-z0-9_])';

final _tailTh = RegExp(
    r'ทุกข้อ|ทุกตัวเลือก|ทุกคำตอบ|ไม่มีข้อ(?:ใด|ถูก|ผิด)|ไม่มี(?:ตัวเลือก|คำตอบ)|ถูกทั้งหมด|ผิดทั้งหมด|ทั้งหมดถูก|ทั้งหมดผิด|'
    r'ถูกหมด|ผิดหมด|ข้างต้น|ข้างบน|^\s*ทั้งหมด\s*$');
final _tailEn = RegExp(
    '$_w0(?:all|none|neither|both)\\s+of\\s+(?:the|these|those|them)$_w1|$_w0(?:all|none)\\s+the\\s+above$_w1',
    caseSensitive: false);
final _namesTh = [
  RegExp(r'(?:ข้อ|ตัวเลือก|คำตอบ)\s*(?:ที่\s*)?[กขคงจ](?![ก-๙])'),
  RegExp(r'(?<![ก-๙])[กขคงจ]\s*(?:และ|กับ|หรือ|,|/|-|–|ถึง)\s*[กขคงจ](?![ก-๙])'),
  RegExp(r'(?:ข้อ|ตัวเลือก|คำตอบ)\s*(?:ที่\s*)?[1-9๑-๙]'),
  RegExp('$_w0(?:option|choice|answer)s?\\s*[A-Ea-e1-5]$_w1', caseSensitive: false),
];
final _namesUpper = RegExp('$_w0[A-E]\\s*(?:and|or|&|,)\\s*[A-E]$_w1');
final _namesLower = RegExp('$_w0[a-e]\\s*(?:and|or|&|,)\\s*[a-e]$_w1');
final _namesNumber = RegExp('$_w0[1-5]\\s*(?:and|or|&|,)\\s*[1-5]$_w1');

bool isTailChoice(String t) => _tailTh.hasMatch(t) || _tailEn.hasMatch(t);

bool namesOtherChoices(String t, {String labels = 'thai'}) =>
    _namesTh.any((p) => p.hasMatch(t)) ||
    _namesUpper.hasMatch(t) ||
    (labels == 'latin' && _namesLower.hasMatch(t)) ||
    (labels == 'number' && _namesNumber.hasMatch(t));

/// [choices] as typed (blank ones are ignored, as the server drops them); [labels] is 'thai' | 'latin' | 'number'.
String? choiceShuffleKind(List<String> choices, {String labels = 'thai'}) {
  final texts = [for (final c in choices) if (c.trim().isNotEmpty) c.trim()];
  if (texts.length < 2) return null;
  if (texts.any((t) => namesOtherChoices(t, labels: labels))) return 'fixed';
  final tail = [for (final t in texts) isTailChoice(t)];
  if (tail.every((x) => x)) return 'fixed';
  return tail.any((x) => x) ? 'tail' : null;
}

/// the note shown under a question's choices (null = nothing to say)
String? choiceShuffleHint(String? kind) => switch (kind) {
      'fixed' => 'ข้อนี้ระบบไม่สลับตัวเลือก (มีตัวเลือกที่อ้างถึงตัวเลือกอื่น หรือเป็น "ทุกข้อ / ไม่มีข้อใด" ทั้งหมด) • ข้ออื่นยังสลับตามปกติ',
      'tail' => 'ตัวเลือก "ถูกทุกข้อ / ไม่มีข้อใดถูก" จะอยู่ท้ายสุดเสมอ • ตัวเลือกที่เหลือสลับให้แต่ละคน',
      _ => null,
    };
