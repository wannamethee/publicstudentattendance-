import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../utils/app_theme.dart';

const _levels = ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'];
const _examTypes = {'midterm': 'กลางภาค', 'final': 'ปลายภาค'};
const _months = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];
const _weekdays = ['', 'จันทร์', 'อังคาร', 'พุธ', 'พฤหัสบดี', 'ศุกร์', 'เสาร์', 'อาทิตย์'];

String _thaiDay(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return 'วัน${_weekdays[d.weekday]}ที่ ${d.day} ${_months[d.month]} ${(d.year + 543) % 100}';
}

int _minutes(String a, String b) {
  int m(String t) => int.parse(t.substring(0, 2)) * 60 + int.parse(t.substring(3, 5));
  return m(b) - m(a);
}

String _shortTeacher(dynamic name) {
  var n = '${name ?? ''}'.trim();
  for (final p in ['นางสาว', 'นาง', 'นาย', 'ว่าที่ร้อยตรี', 'ว่าที่ ร.ต.']) {
    if (n.startsWith(p)) {
      n = n.substring(p.length).trim();
      break;
    }
  }
  final first = n.split(RegExp(r'\s+')).first;
  return first.isEmpty ? '' : 'ครู$first';
}

/// ตารางสอบ (กลางภาค / ปลายภาค) in the school's form: days x time slots x ม.1–ม.6. Admin uploads the form,
/// edits the grid and opens a course early from its cell; each course unlocks for students at its slot.
class ExamTimetableCard extends StatefulWidget {
  final ApiService apiService;
  final String term;
  final String year;
  final bool isAdmin;
  final Set<String> myCourses; // highlighted for a teacher
  final VoidCallback onChanged;

  const ExamTimetableCard({
    super.key,
    required this.apiService,
    required this.term,
    required this.year,
    required this.isAdmin,
    required this.myCourses,
    required this.onChanged,
  });

  @override
  State<ExamTimetableCard> createState() => _ExamTimetableCardState();
}

class _ExamTimetableCardState extends State<ExamTimetableCard> {
  String _type = 'midterm';
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(pickType: true);
  }

  @override
  void didUpdateWidget(covariant ExamTimetableCard old) {
    super.didUpdateWidget(old);
    if (old.term != widget.term || old.year != widget.year) _load(pickType: true);
  }

  Future<void> _load({bool pickType = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var d = await widget.apiService.getExamTimetable(widget.term, widget.year, _type);
      // open on the exam that actually has a timetable
      if (pickType && (d['days'] as List).isEmpty) {
        final other = _type == 'midterm' ? 'final' : 'midterm';
        final o = await widget.apiService.getExamTimetable(widget.term, widget.year, other);
        if ((o['days'] as List).isNotEmpty) {
          _type = other;
          d = o;
        }
      }
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? Colors.red.shade700 : null));
  }

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
    );
    if (picked.isEmpty) return;
    final f = picked.first;
    try {
      final bytes = await f.readAsBytes();
      final r = await widget.apiService.uploadExamTimetable(widget.term, widget.year, _type, bytes, f.name);
      final draft = (r['draft_days'] as List? ?? []);
      _snack('อัปโหลด ${f.name} แล้ว${draft.isNotEmpty ? ' • อ่านตารางจาก PDF ได้ กรุณาตรวจแล้วกดบันทึก' : ''}');
      await _load();
      if (!mounted) return;
      _openEditor(draft: draft.isNotEmpty ? draft : null, note: '${r['note'] ?? ''}');
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  Future<void> _openEditor({List? draft, String note = ''}) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ExamTimetableEditor(
        apiService: widget.apiService,
        term: widget.term,
        year: widget.year,
        examType: _type,
        days: draft ?? (_data?['days'] as List? ?? []),
        hasFile: _data?['has_file'] == true,
        note: note,
      ),
    );
    if (saved == true) {
      await _load();
      widget.onChanged();
    }
  }

  Future<void> _openEarly(Map info, bool open) async {
    try {
      await widget.apiService.openExamEarly(widget.term, widget.year, ['${info['course_code']}'], _type, open);
      _snack(open ? 'ปลดล็อก ${info['course_code']} แล้ว นักเรียนสอบได้ทันที' : 'ยกเลิกการปลดล็อก ${info['course_code']} แล้ว');
      await _load();
      widget.onChanged();
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final days = (d?['days'] as List? ?? []).cast<Map>();
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.gold)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('ตารางสอบ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                SegmentedButton<String>(
                  segments: [for (final e in _examTypes.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                  selected: {_type},
                  onSelectionChanged: (s) {
                    setState(() => _type = s.first);
                    _load();
                  },
                ),
                if (d?['has_file'] == true)
                  TextButton.icon(
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('ดูไฟล์ต้นฉบับ'),
                    onPressed: () => launchUrl(Uri.parse(widget.apiService.examTimetableFileUrl(widget.term, widget.year, _type)),
                        webOnlyWindowName: '_blank'),
                  ),
                if (widget.isAdmin) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.upload_file_rounded, size: 18),
                    label: const Text('อัปโหลดตารางสอบ (รูป / PDF)'),
                    onPressed: _upload,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_calendar_rounded, size: 18),
                    label: Text(days.isEmpty ? 'สร้างตารางสอบ' : 'แก้ไขตาราง'),
                    onPressed: () => _openEditor(),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'ตารางสอบ${_examTypes[_type]} ภาคเรียนที่ ${widget.term} ปีการศึกษา ${widget.year} • แต่ละวิชาเปิดให้นักเรียนกดเองเมื่อถึงเวลาในตาราง'
              '${widget.isAdmin ? ' • กดที่รายวิชาเพื่อปลดล็อกให้สอบก่อนเวลา' : ''}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Text(_error!, style: TextStyle(color: Colors.red.shade700))
            else if (days.isEmpty)
              Text(
                widget.isAdmin ? 'ยังไม่มีตารางสอบ${_examTypes[_type]} — กด "อัปโหลดตารางสอบ" หรือ "สร้างตารางสอบ"' : 'ยังไม่มีตารางสอบ${_examTypes[_type]}',
                style: TextStyle(color: Colors.grey.shade600),
              )
            else ...[
              _legend(),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final day in days) _day(day)]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static const _wTime = 96.0, _wMin = 48.0, _wCell = 132.0;

  static const _sentBg = Color(0xFFFEF3C7); // ส่งข้อสอบแล้ว: light yellow
  static const _sentBorder = Color(0xFFD97706);

  Widget _legend() {
    final sent = _countSent();
    Widget swatch(Color bg, Color border, String t, {double width = 1}) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 14, height: 14, decoration: BoxDecoration(color: bg, border: Border.all(color: border, width: width), borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 11.5)),
        ]);
    Widget icon(IconData i, Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 14, color: c),
          const SizedBox(width: 3),
          Text(t, style: const TextStyle(fontSize: 11.5)),
        ]);
    return Wrap(spacing: 14, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      swatch(_sentBg, _sentBorder, 'ส่งข้อสอบแล้ว ${sent.$1}/${sent.$2} วิชา'),
      swatch(Colors.white, Colors.grey.shade400, 'ยังไม่ส่ง / สอบกระดาษ'),
      if (!widget.isAdmin && widget.myCourses.isNotEmpty) swatch(Colors.white, AppColors.purpleDark, 'วิชาของท่าน (กรอบเข้ม)', width: 2),
      icon(Icons.lock_clock_rounded, Colors.grey.shade700, 'รอเวลาสอบ'),
      icon(Icons.lock_open_rounded, const Color(0xFF15803D), 'เปิดสอบอยู่'),
      icon(Icons.lock_open_rounded, Colors.orange.shade800, 'ปลดล็อกก่อนเวลา'),
      icon(Icons.check_rounded, Colors.grey.shade600, 'สอบแล้ว'),
    ]);
  }

  /// (sent, all) exam cells in this timetable; for a teacher only their own courses
  (int, int) _countSent() {
    var sent = 0, all = 0;
    for (final d in (_data?['days'] as List? ?? []).cast<Map>()) {
      for (final s in (d['slots'] as List).cast<Map>()) {
        for (final info in ((s['info'] as Map?) ?? {}).values.cast<Map>()) {
          if (!widget.isAdmin && widget.myCourses.isNotEmpty && !widget.myCourses.contains('${info['course_code']}')) continue;
          all++;
          if (info['has_exam'] == true) sent++;
        }
      }
    }
    return (sent, all);
  }

  Widget _box(double w, Widget child, {Color? bg, double h = 54}) => Container(
        width: w,
        height: h,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(color: bg, border: Border.all(color: Colors.grey.shade400, width: 0.6)),
        child: child,
      );

  Widget _day(Map day) {
    final slots = (day['slots'] as List).cast<Map>();
    final head = TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey.shade900);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
          child: Text(_thaiDay('${day['date']}'), style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        Row(children: [
          _box(_wTime, Text('ช่วงเวลา', style: head), bg: Colors.grey.shade100, h: 34),
          _box(_wMin, Text('นาที', style: head), bg: Colors.grey.shade100, h: 34),
          for (final lv in _levels) _box(_wCell, Text(lv, style: head), bg: Colors.grey.shade100, h: 34),
        ]),
        for (final s in slots)
          Row(children: [
            _box(_wTime, Text('${s['start']}–${s['end']}'.replaceAll(':', '.'), style: const TextStyle(fontSize: 12.5))),
            _box(_wMin, Text('${_minutes('${s['start']}', '${s['end']}')}', style: const TextStyle(fontSize: 12.5))),
            if (s['kind'] == 'break')
              _box(_wCell * 6, Text('${s['label'] ?? 'พัก'}', style: TextStyle(color: Colors.grey.shade700)), bg: Colors.grey.shade50)
            else
              for (final lv in _levels) _cell((s['info'] as Map?)?[lv] as Map?),
          ]),
      ]),
    );
  }

  Widget _cell(Map? info) {
    if (info == null) return _box(_wCell, const SizedBox());
    final code = '${info['course_code']}';
    final open = info['is_open'] == true;
    final early = info['opened_early'] == true;
    final online = info['has_exam'] == true; // the teacher built a paper or attached a link (= ส่งข้อสอบแล้ว)
    final ended = info['has_ended'] == true;
    final Color stateColor = early
        ? Colors.orange.shade800
        : open
            ? const Color(0xFF15803D)
            : ended
                ? Colors.grey.shade600
                : Colors.grey.shade700;
    final mine = widget.myCourses.contains(code);
    final content = Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (online) ...[
          Icon(open ? Icons.lock_open_rounded : (ended ? Icons.check_rounded : Icons.lock_clock_rounded), size: 13, color: stateColor),
          const SizedBox(width: 3),
        ],
        Text(code, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: online ? const Color(0xFF78350F) : Colors.grey.shade700)),
      ]),
      Text(_shortTeacher(info['teacher']), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
      if (online) Text('ส่งข้อสอบแล้ว', style: TextStyle(fontSize: 10, color: Colors.orange.shade900, height: 1.1)),
    ]);
    final box = Container(
      width: _wCell,
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: online ? _sentBg : null,
        border: Border.all(
          color: mine ? AppColors.purpleDark : (online ? _sentBorder.withValues(alpha: 0.5) : Colors.grey.shade400),
          width: mine ? 2 : 0.6,
        ),
      ),
      child: content,
    );
    final tip = '${info['course_code']} ${info['course_name'] ?? ''}\n${info['teacher'] ?? ''}\n'
        '${online ? 'ส่งข้อสอบแล้ว • ${early ? 'ปลดล็อกก่อนเวลาแล้ว' : open ? 'เปิดสอบอยู่' : ended ? 'หมดเวลาสอบ' : 'เปิดเองเมื่อถึงเวลา'}' : 'ยังไม่ส่งข้อสอบ (หรือสอบกระดาษ)'}';
    if (!widget.isAdmin) return Tooltip(message: tip, child: box);
    return Tooltip(
      message: tip,
      child: PopupMenuButton<int>(
        tooltip: '',
        padding: EdgeInsets.zero,
        itemBuilder: (_) => [
          PopupMenuItem(enabled: false, child: Text('$code ${info['course_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold))),
          if (!early && !open) const PopupMenuItem(value: 1, child: Text('ปลดล็อกให้สอบตอนนี้')),
          if (early) const PopupMenuItem(value: 0, child: Text('ยกเลิกปลดล็อก')),
          if (open && !early) const PopupMenuItem(enabled: false, child: Text('เปิดสอบอยู่ตามเวลาในตาราง')),
        ],
        onSelected: (v) => _openEarly(info, v == 1),
        child: box,
      ),
    );
  }
}

/// Admin editor for the grid: days, time slots (exam or break) and the course of each level per slot.
class ExamTimetableEditor extends StatefulWidget {
  final ApiService apiService;
  final String term;
  final String year;
  final String examType;
  final List days;
  final bool hasFile;
  final String note;

  const ExamTimetableEditor({
    super.key,
    required this.apiService,
    required this.term,
    required this.year,
    required this.examType,
    required this.days,
    required this.hasFile,
    this.note = '',
  });

  @override
  State<ExamTimetableEditor> createState() => _ExamTimetableEditorState();
}

/// "8.30", "08:30", "0830", "830", "8" -> minutes after midnight (null when it is not a time)
int? _parseHm(String text) {
  final t = text.trim().replaceAll(' ', '').replaceAll('น.', '');
  var m = RegExp(r'^(\d{1,2})[.:](\d{1,2})$').firstMatch(t);
  m ??= RegExp(r'^(\d{1,2})(\d{2})$').firstMatch(t);
  int h, mi;
  if (m != null) {
    h = int.parse(m.group(1)!);
    mi = int.parse(m.group(2)!);
  } else if (RegExp(r'^\d{1,2}$').hasMatch(t)) {
    h = int.parse(t);
    mi = 0;
  } else {
    return null;
  }
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}

String _fmtHm(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}.${(minutes % 60).toString().padLeft(2, '0')}';

const _slotKinds = {'exam': 'สอบ', 'break': 'พักเบรค', 'lunch': 'พักกลางวัน'};
final _autoBreakLabel = RegExp(r'^(พักเบรค|พักกลางวัน|พัก)?(\s*\d+\s*นาที)?$');

/// One row of the form: start, end and minutes kept in step (type any two), exam or break, a course code per level.
class _SlotDraft {
  final TextEditingController start;
  final TextEditingController end;
  final TextEditingController minutes;
  final TextEditingController label;
  String kind; // exam / break / lunch (both breaks are stored as 'break' with their label)
  final Map<String, String?> cells;

  _SlotDraft(String s, String e, this.kind, String l, Map cs)
      : start = TextEditingController(text: s.replaceAll(':', '.')),
        end = TextEditingController(text: e.replaceAll(':', '.')),
        minutes = TextEditingController(),
        label = TextEditingController(text: l),
        cells = {for (final lv in _levels) lv: cs[lv] == null ? null : '${cs[lv]}'} {
    _syncMinutes();
  }

  int? get startMin => _parseHm(start.text);
  int? get endMin => _parseHm(end.text);
  bool get valid => startMin != null && endMin != null && endMin! > startMin!;

  void _syncMinutes() {
    final s = startMin, e = endMin;
    if (s != null && e != null && e > s) minutes.text = '${e - s}';
  }

  /// เวลาเริ่ม changed: keep the length (minutes) and move the end
  void onStart() {
    final s = startMin, m = int.tryParse(minutes.text.trim());
    if (s != null && m != null && m > 0 && s + m < 24 * 60) {
      end.text = _fmtHm(s + m);
    } else {
      _syncMinutes();
    }
  }

  /// เวลาสิ้นสุด changed: recount the minutes
  void onEnd() {
    _syncMinutes();
    _relabel();
  }

  /// จำนวนนาที changed: the end follows
  void onMinutes() {
    final s = startMin, m = int.tryParse(minutes.text.trim());
    if (s != null && m != null && m > 0 && s + m < 24 * 60) end.text = _fmtHm(s + m);
    _relabel();
  }

  /// "พักเบรค 30 นาที" follows the length unless the admin wrote their own label
  void _relabel() {
    if (kind == 'exam' || !_autoBreakLabel.hasMatch(label.text.trim())) return;
    final m = int.tryParse(minutes.text.trim());
    label.text = '${_slotKinds[kind]}${m != null ? ' $m นาที' : ''}';
  }

  void setKind(String k) {
    final wasAuto = _autoBreakLabel.hasMatch(label.text.trim());
    kind = k;
    if (k != 'exam' && wasAuto) {
      label.text = '';
      _relabel();
    }
  }

  void moveTo(int startMinute) {
    final m = int.tryParse(minutes.text.trim()) ?? ((endMin ?? startMinute) - (startMin ?? startMinute));
    start.text = _fmtHm(startMinute);
    end.text = _fmtHm(startMinute + (m > 0 ? m : 60));
    _syncMinutes();
  }

  void dispose() {
    start.dispose();
    end.dispose();
    minutes.dispose();
    label.dispose();
  }

  Map<String, dynamic> toJson() => {
        'start': startMin == null ? start.text.trim() : _fmtHm(startMin!).replaceAll('.', ':'),
        'end': endMin == null ? end.text.trim() : _fmtHm(endMin!).replaceAll('.', ':'),
        'kind': kind == 'exam' ? 'exam' : 'break',
        'label': kind == 'exam' ? '' : (label.text.trim().isEmpty ? _slotKinds[kind] : label.text.trim()),
        'cells': kind == 'exam' ? {for (final e in cells.entries) if (e.value != null && e.value!.trim().isNotEmpty) e.key: e.value!.trim()} : {},
      };
}

class _DayDraft {
  DateTime date;
  final List<_SlotDraft> slots;
  _DayDraft(this.date, this.slots);
}

class _ExamTimetableEditorState extends State<ExamTimetableEditor> {
  final List<_DayDraft> _days = [];
  bool _saving = false;
  List<Map<String, dynamic>> _courses = []; // every course of the semester, for the code fields

  @override
  void initState() {
    super.initState();
    widget.apiService.getExamCourses(term: widget.term, year: widget.year).then((r) {
      if (mounted) setState(() => _courses = (r['data'] as List).map((e) => Map<String, dynamic>.from(e)).toList());
    }).catchError((_) {});
    for (final d in widget.days.cast<Map>()) {
      _days.add(_DayDraft(
        DateTime.tryParse('${d['date']}') ?? DateTime.now(),
        [
          for (final s in (d['slots'] as List).cast<Map>())
            _SlotDraft(
              '${s['start']}',
              '${s['end']}',
              s['kind'] == 'break' ? ('${s['label'] ?? ''}'.contains('กลางวัน') ? 'lunch' : 'break') : 'exam',
              '${s['label'] ?? ''}',
              (s['cells'] as Map?) ?? {},
            ),
        ],
      ));
    }
    if (_days.isEmpty) _addDay(notify: false);
  }

  @override
  void dispose() {
    for (final d in _days) {
      for (final s in d.slots) {
        s.dispose();
      }
    }
    super.dispose();
  }

  List<Map<String, dynamic>> _coursesOf(String lv) => _courses
      .where((c) => '${c['class_level'] ?? ''}'.split(RegExp(r'[,\s]+')).contains(lv))
      .toList()
    ..sort((a, b) => '${a['course_code']}'.compareTo('${b['course_code']}'));

  Map<String, dynamic>? _course(String? code) {
    if (code == null || code.trim().isEmpty) return null;
    for (final c in _courses) {
      if ('${c['course_code']}' == code.trim()) return c;
    }
    return null;
  }

  /// A new day copies the previous day's times and breaks (courses left empty); the first day gets the usual pattern.
  void _addDay({bool notify = true}) {
    final last = _days.isEmpty ? DateTime.now() : _days.last.date.add(const Duration(days: 1));
    final slots = _days.isEmpty
        ? [
            _SlotDraft('08:30', '09:30', 'exam', '', {}),
            _SlotDraft('09:30', '10:00', 'break', 'พักเบรค 30 นาที', {}),
            _SlotDraft('10:00', '11:00', 'exam', '', {}),
            _SlotDraft('11:00', '12:00', 'exam', '', {}),
            _SlotDraft('12:00', '13:00', 'lunch', 'พักกลางวัน 60 นาที', {}),
            _SlotDraft('13:00', '14:00', 'exam', '', {}),
          ]
        : [for (final s in _days.last.slots) _SlotDraft(s.start.text, s.end.text, s.kind, s.kind == 'exam' ? '' : s.label.text, {})];
    final day = _DayDraft(DateTime(last.year, last.month, last.day), slots);
    if (notify) {
      setState(() => _days.add(day));
    } else {
      _days.add(day);
    }
  }

  void _addSlot(_DayDraft d, String kind, {int? after}) {
    final at = after == null ? d.slots.length : after + 1;
    final prev = at > 0 ? d.slots[at - 1] : null;
    final start = prev?.endMin ?? 8 * 60 + 30;
    final len = kind == 'break' ? 30 : 60;
    final s = _SlotDraft(_fmtHm(start), _fmtHm(start + len), kind, kind == 'exam' ? '' : '${_slotKinds[kind]} $len นาที', {});
    setState(() => d.slots.insert(at, s));
  }

  /// Each row starts when the one before ends, keeping its own length (after a break or exam changed length).
  void _chain(_DayDraft d) {
    setState(() {
      for (var i = 1; i < d.slots.length; i++) {
        final prevEnd = d.slots[i - 1].endMin;
        if (prevEnd != null) d.slots[i].moveTo(prevEnd);
      }
    });
  }

  String? _problem(_DayDraft d, int i) {
    final s = d.slots[i];
    if (s.startMin == null || s.endMin == null) return 'เวลาไม่ถูกต้อง (เช่น 08.30)';
    if (s.endMin! <= s.startMin!) return 'เวลาสิ้นสุดต้องหลังเวลาเริ่ม';
    if (i > 0 && d.slots[i - 1].endMin != null && s.startMin! < d.slots[i - 1].endMin!) return 'ซ้อนกับช่วงก่อนหน้า';
    if (s.kind == 'exam') {
      for (final lv in _levels) {
        final code = s.cells[lv];
        if (code != null && code.trim().isNotEmpty && !_coursesOf(lv).any((c) => '${c['course_code']}' == code.trim())) {
          return '$lv: ไม่พบรหัส ${code.trim()} ในชั้นนี้';
        }
      }
    }
    return null;
  }

  Future<void> _save() async {
    for (final d in _days) {
      for (var i = 0; i < d.slots.length; i++) {
        final p = _problem(d, i);
        if (p != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${_thaiDay(d.date.toIso8601String())} แถวที่ ${i + 1}: $p'),
            backgroundColor: Colors.red.shade700,
          ));
          return;
        }
      }
    }
    setState(() => _saving = true);
    try {
      await widget.apiService.saveExamTimetable(widget.term, widget.year, widget.examType, [
        for (final d in _days)
          {
            'date': '${d.date.year.toString().padLeft(4, '0')}-${d.date.month.toString().padLeft(2, '0')}-${d.date.day.toString().padLeft(2, '0')}',
            'slots': d.slots.map((s) => s.toJson()).toList(),
          }
      ]);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Colors.red.shade700));
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Dialog(
      insetPadding: const EdgeInsets.all(10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.gold, width: 1.5)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 1360, maxHeight: size.height * 0.94),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
              decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
              child: Row(children: [
                Expanded(
                  child: Text('แบบฟอร์มตารางสอบ${_examTypes[widget.examType]} ${widget.term}/${widget.year}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                if (widget.hasFile)
                  TextButton.icon(
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('ดูไฟล์ต้นฉบับ'),
                    onPressed: () => launchUrl(Uri.parse(widget.apiService.examTimetableFileUrl(widget.term, widget.year, widget.examType)),
                        webOnlyWindowName: '_blank'),
                  ),
                IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'กรอกเวลาเริ่ม + เวลาสิ้นสุด แล้วระบบนับนาทีให้ หรือกรอกเวลาเริ่ม + จำนวนนาที แล้วระบบหาเวลาสิ้นสุดให้ • '
                'พิมพ์รหัสวิชาในช่องชั้นนั้น (หรือเลือกจากรายการ) ระบบขึ้นชื่อครูประจำวิชาให้ • ช่วงพักเบรค / พักกลางวัน ปรับเวลาได้ แล้วกด "เลื่อนเวลาให้ต่อกัน"',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800),
              ),
            ),
            if (widget.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(widget.note, style: TextStyle(fontSize: 12.5, color: Colors.orange.shade900)),
              ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.all(12),
                shrinkWrap: true,
                children: [
                  for (final d in _days) _dayEditor(d),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _addDay,
                      icon: const Icon(Icons.add),
                      label: Text(_days.isEmpty ? 'เพิ่มวันสอบ' : 'เพิ่มวันสอบ (ใช้ช่วงเวลาเดียวกับวันก่อน)'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                Expanded(
                  child: Text('บันทึกแล้ว ทุกวิชาในตารางจะได้เวลาสอบตามช่องนี้ และเปิดให้นักเรียนเองเมื่อถึงเวลา',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                ),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('ยกเลิก')),
                const SizedBox(width: 6),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded),
                  label: const Text('บันทึกตารางสอบ'),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  static const _wTime = 78.0, _wMin = 64.0, _wKind = 124.0, _wCell = 150.0;

  Widget _dayEditor(_DayDraft d) {
    final examCount = d.slots.where((s) => s.kind == 'exam').fold<int>(0, (a, s) => a + s.cells.values.where((v) => v != null && v.trim().isNotEmpty).length);
    final first = d.slots.isEmpty ? null : d.slots.first.startMin;
    final last = d.slots.isEmpty ? null : d.slots.last.endMin;
    TextStyle head = const TextStyle(fontWeight: FontWeight.w600, fontSize: 13);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade300)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            TextButton.icon(
              icon: const Icon(Icons.event_rounded),
              label: Text(_thaiDay(d.date.toIso8601String()), style: const TextStyle(fontWeight: FontWeight.bold)),
              onPressed: () async {
                final picked = await showDatePicker(context: context, initialDate: d.date, firstDate: DateTime(2020), lastDate: DateTime(2035));
                if (picked != null) setState(() => d.date = picked);
              },
            ),
            Text('${first != null && last != null ? '${_fmtHm(first)}–${_fmtHm(last)} น. • ' : ''}$examCount วิชา',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
            TextButton.icon(
              onPressed: () => _chain(d),
              icon: const Icon(Icons.low_priority_rounded, size: 18),
              label: const Text('เลื่อนเวลาให้ต่อกัน'),
            ),
            IconButton(
              tooltip: 'ลบวันนี้',
              icon: Icon(Icons.delete_outline, color: Colors.red.shade700),
              onPressed: () {
                setState(() => _days.remove(d));
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  for (final s in d.slots) {
                    s.dispose();
                  }
                });
              },
            ),
          ]),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SizedBox(width: _wTime, child: Text('เริ่ม', style: head)),
                SizedBox(width: _wTime, child: Text('สิ้นสุด', style: head)),
                SizedBox(width: _wMin, child: Text('นาที', style: head)),
                SizedBox(width: _wKind, child: Text('ประเภท', style: head)),
                for (final lv in _levels) SizedBox(width: _wCell, child: Text('$lv (รหัสวิชา)', style: head)),
              ]),
              const SizedBox(height: 4),
              for (var i = 0; i < d.slots.length; i++) _slotEditor(d, i),
            ]),
          ),
          Wrap(spacing: 8, children: [
            TextButton.icon(onPressed: () => _addSlot(d, 'exam'), icon: const Icon(Icons.add, size: 18), label: const Text('เพิ่มช่วงสอบ')),
            TextButton.icon(onPressed: () => _addSlot(d, 'break'), icon: const Icon(Icons.free_breakfast_outlined, size: 18), label: const Text('เพิ่มพักเบรค')),
            TextButton.icon(onPressed: () => _addSlot(d, 'lunch'), icon: const Icon(Icons.restaurant_outlined, size: 18), label: const Text('เพิ่มพักกลางวัน')),
          ]),
        ]),
      ),
    );
  }

  Widget _slotEditor(_DayDraft d, int i) {
    final s = d.slots[i];
    final problem = _problem(d, i);
    InputDecoration dec(String hint, {bool bad = false}) => InputDecoration(
          isDense: true,
          hintText: hint,
          border: const OutlineInputBorder(),
          enabledBorder: bad ? OutlineInputBorder(borderSide: BorderSide(color: Colors.red.shade400)) : null,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        );
    const ts = TextStyle(fontSize: 13);
    final isBreak = s.kind != 'exam';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: 3),
      color: isBreak ? Colors.grey.shade100 : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: _wTime,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextField(
                controller: s.start,
                style: ts,
                decoration: dec('08.30', bad: s.startMin == null),
                onChanged: (_) => setState(s.onStart),
              ),
            ),
          ),
          SizedBox(
            width: _wTime,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextField(
                controller: s.end,
                style: ts,
                decoration: dec('10.00', bad: !s.valid),
                onChanged: (_) => setState(s.onEnd),
              ),
            ),
          ),
          SizedBox(
            width: _wMin,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextField(
                controller: s.minutes,
                style: ts,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: dec('60'),
                onChanged: (_) => setState(s.onMinutes),
              ),
            ),
          ),
          SizedBox(
            width: _wKind,
            child: Padding(
              padding: const EdgeInsets.only(right: 6, top: 4),
              child: DropdownButton<String>(
                value: s.kind,
                isDense: true,
                isExpanded: true,
                items: [for (final k in _slotKinds.entries) DropdownMenuItem(value: k.key, child: Text(k.value, style: ts))],
                onChanged: (v) => setState(() => s.setKind(v ?? 'exam')),
              ),
            ),
          ),
          if (isBreak)
            SizedBox(width: _wCell * 6, child: TextField(controller: s.label, style: ts, decoration: dec('เช่น พักเบรค 30 นาที')))
          else
            for (final lv in _levels) SizedBox(width: _wCell, child: _codeCell(s, lv)),
          PopupMenuButton<String>(
            tooltip: 'เพิ่ม / ลบแถว',
            icon: const Icon(Icons.more_vert, size: 20),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'exam', child: Text('แทรกช่วงสอบถัดจากแถวนี้')),
              PopupMenuItem(value: 'break', child: Text('แทรกพักเบรคถัดจากแถวนี้')),
              PopupMenuItem(value: 'lunch', child: Text('แทรกพักกลางวันถัดจากแถวนี้')),
              PopupMenuItem(value: 'delete', child: Text('ลบแถวนี้')),
            ],
            onSelected: (v) {
              if (v == 'delete') {
                setState(() => d.slots.remove(s));
                WidgetsBinding.instance.addPostFrameCallback((_) => s.dispose());
              } else {
                _addSlot(d, v, after: i);
              }
            },
          ),
        ]),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: Text(problem, style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
          ),
      ]),
    );
  }

  /// Type a course code (or pick one of this level's courses); the course's teacher shows underneath.
  Widget _codeCell(_SlotDraft s, String lv) {
    final options = _coursesOf(lv);
    final code = s.cells[lv]?.trim() ?? '';
    final c = _course(code);
    final known = c != null && options.contains(c);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Autocomplete<Map<String, dynamic>>(
          key: ValueKey('${identityHashCode(s)}-$lv-${_courses.length}'),
          initialValue: TextEditingValue(text: code),
          displayStringForOption: (o) => '${o['course_code']}',
          optionsBuilder: (v) {
            final q = v.text.trim();
            if (q.isEmpty) return options;
            return options.where((o) => '${o['course_code']}'.contains(q) || '${o['course_name'] ?? ''}'.contains(q));
          },
          onSelected: (o) => setState(() => s.cells[lv] = '${o['course_code']}'),
          fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
            controller: ctrl,
            focusNode: focus,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: '-',
              border: const OutlineInputBorder(),
              enabledBorder: code.isNotEmpty && !known ? OutlineInputBorder(borderSide: BorderSide(color: Colors.red.shade400)) : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
            ),
            onChanged: (v) => setState(() => s.cells[lv] = v.trim().isEmpty ? null : v.trim()),
            onSubmitted: (_) => onSubmit(),
          ),
          optionsViewBuilder: (context, onSelected, opts) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 300, maxWidth: 320, maxHeight: 260),
                child: ListView(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  children: [
                    for (final o in opts)
                      ListTile(
                        dense: true,
                        title: Text('${o['course_code']} ${o['course_name'] ?? ''}', style: const TextStyle(fontSize: 13)),
                        subtitle: Text(_shortTeacher(o['teacher']), style: const TextStyle(fontSize: 12)),
                        onTap: () => onSelected(o),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (code.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 2),
            child: Text(
              known ? _shortTeacher(c['teacher']) : 'ไม่พบรหัสนี้ใน $lv',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: known ? AppColors.purpleDark : Colors.red.shade700),
            ),
          ),
      ]),
    );
  }
}
