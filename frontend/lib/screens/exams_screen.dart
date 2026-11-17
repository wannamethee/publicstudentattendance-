import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../utils/app_theme.dart';
import '../widgets/exam_timetable_view.dart';
import '../widgets/no_exam_right_dialog.dart';
import '../widgets/question_kinds.dart';
import '../widgets/student_question_card.dart';
import '../widgets/quiz_manager.dart';
import '../widgets/slot_points.dart';

const examTypes = {'midterm': 'กลางภาค', 'final': 'ปลายภาค'};
const choiceLetters = ['ก', 'ข', 'ค', 'ง', 'จ'];
const _thaiMonths = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];

String thaiDateTime(dynamic iso) {
  final dt = DateTime.tryParse('${iso ?? ''}');
  if (dt == null) return '-';
  final hm = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  return '${dt.day} ${_thaiMonths[dt.month]} ${(dt.year + 543) % 100} $hm น.';
}

const _weekdayNames = ['', 'จันทร์', 'อังคาร', 'พุธ', 'พฤหัสบดี', 'ศุกร์', 'เสาร์', 'อาทิตย์'];

/// "วันอังคารที่ 22 ก.ย. 69 • 08.30–10.00 น. (90 นาที)" for one course's exam slot
String examWhen(dynamic startIso, dynamic endIso) {
  final s = DateTime.tryParse('${startIso ?? ''}');
  final e = DateTime.tryParse('${endIso ?? ''}');
  if (s == null || e == null) return 'ยังไม่กำหนดเวลาสอบ';
  String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}.${d.minute.toString().padLeft(2, '0')}';
  final day = 'วัน${_weekdayNames[s.weekday]}ที่ ${s.day} ${_thaiMonths[s.month]} ${(s.year + 543) % 100}';
  if (e.difference(s).inHours >= 24) return '$day ${hm(s)} น. – ${thaiDateTime(endIso)}';
  return '$day • ${hm(s)}–${hm(e)} น. (${e.difference(s).inMinutes} นาที)';
}

String windowText(Map w) {
  if (w['start_at'] == null || w['end_at'] == null) return 'ยังไม่ได้กำหนดวันสอบ';
  return '${thaiDateTime(w['start_at'])} – ${thaiDateTime(w['end_at'])}';
}

Widget windowChip(Map w) {
  late final String text;
  late final Color color;
  if (w['start_at'] == null || w['end_at'] == null) {
    text = 'ยังไม่ตั้ง';
    color = Colors.grey;
  } else if (w['is_open'] == true) {
    text = 'เปิดสอบอยู่';
    color = const Color(0xFF15803D);
  } else if (w['has_ended'] == true) {
    text = 'ปิดแล้ว';
    color = const Color(0xFFB91C1C);
  } else {
    text = 'ยังไม่ถึงเวลา';
    color = const Color(0xFFB45309);
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
  );
}

String _num(dynamic v) {
  if (v == null) return '-';
  final d = (v as num).toDouble();
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

/// ข้อสอบ: admin sets the school-wide exam windows; each teacher sets up the กลางภาค / ปลายภาค of own courses
/// (an external link, or a multiple-choice paper the system grades into the scores page).
class ExamsScreen extends StatefulWidget {
  final ApiService apiService;
  const ExamsScreen({super.key, required this.apiService});

  @override
  State<ExamsScreen> createState() => _ExamsScreenState();
}

class _ExamsScreenState extends State<ExamsScreen> {
  String? _term;
  String? _year;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _courses = [];
  Map<String, dynamic> _windows = {};
  String _level = 'ทั้งหมด';
  String _dept = 'ทุกกลุ่มสาระ';
  String? _sortBy; // 'midterm' / 'final' = by that exam's time, 'code' = by course code; null = pick automatically
  Map<String, dynamic>? _viewer; // who the server says is asking
  List<Map<String, dynamic>> _teachers = [];
  String? _teacher; // admin: null = every course
  List<Map<String, dynamic>> _semesters = [];
  Map<String, dynamic> _quizCounts = {}; // course_code -> {count, ready}

  bool get _isAdmin => _viewer?['is_admin'] == true;
  String get _myCode => '${_viewer?['code'] ?? widget.apiService.currentUser?.code ?? ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_term == null) {
        final cur = await widget.apiService.getCurrentSemester();
        _term = cur['term'];
        _year = cur['year'];
      }
      final r = await widget.apiService.getExamCourses(term: _term, year: _year, teacherCode: _teacher);
      if (!mounted) return;
      setState(() {
        _term = '${r['term']}';
        _year = '${r['year']}';
        _viewer = Map<String, dynamic>.from(r['viewer'] as Map);
        _teachers = (r['teachers'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
        _semesters = (r['semesters'] as List? ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
        _teacher = r['selected_teacher'] == null || !_isAdmin ? null : '${r['selected_teacher']}';
        _windows = Map<String, dynamic>.from(r['windows'] as Map);
        _courses = (r['data'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
        _loading = false;
      });
      _loadQuizCounts();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _load, child: const Text('ลองใหม่')),
        ]),
      );
    }
    final levels = ['ทั้งหมด', ...{for (final c in _courses) '${c['class_level'] ?? ''}'}];
    final depts = ['ทุกกลุ่มสาระ', ...{for (final c in _courses) _deptOf(c)}];
    final shown = _courses
        .where((c) => _level == 'ทั้งหมด' || '${c['class_level']}' == _level)
        .where((c) => _dept == 'ทุกกลุ่มสาระ' || _deptOf(c) == _dept)
        .toList();
    final grouped = _isAdmin && _teacher == null;
    final sortBy = _sortBy ?? _autoSortType();
    _order = {};
    if (sortBy != 'code') {
      shown.sort((a, b) {
        final ka = _slotStart(a, sortBy), kb = _slotStart(b, sortBy);
        if (ka != kb) return ka == null ? 1 : (kb == null ? -1 : ka.compareTo(kb));
        return '${a['class_level']}${a['course_code']}'.compareTo('${b['class_level']}${b['course_code']}');
      });
      var n = 0;
      for (final c in shown) {
        if (_slotStart(c, sortBy) != null) _order['${c['course_code']}'] = ++n;
      }
      _orderType = sortBy;
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              const Text('ข้อสอบกลางภาค / ปลายภาค', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              DropdownButton<String>(
                value: '$_term/$_year',
                underline: const SizedBox(),
                items: {
                  '$_term/$_year',
                  for (final x in _semesters) '${x['term']}/${x['year']}',
                }.map((v) => DropdownMenuItem(value: v, child: Text('ภาคเรียนที่ $v'))).toList(),
                onChanged: (v) {
                  if (v == null || v == '$_term/$_year') return;
                  final parts = v.split('/');
                  setState(() {
                    _term = parts[0];
                    _year = parts[1];
                  });
                  _load();
                },
              ),
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded), tooltip: 'โหลดใหม่'),
            ],
          ),
          const SizedBox(height: 8),
          _windowsCard(),
          const SizedBox(height: 14),
          ExamTimetableCard(
            key: ValueKey('tt-$_term-$_year'),
            apiService: widget.apiService,
            term: _term!,
            year: _year!,
            isAdmin: _isAdmin,
            myCourses: _isAdmin && _teacher == null ? <String>{} : {for (final c in _courses) '${c['course_code']}'},
            onChanged: _load,
          ),
          const SizedBox(height: 14),
          _teacherButtons(),
          const SizedBox(height: 10),
          if (_isAdmin)
            const Text('เลือกวิชาที่สอบ: ปิดสวิตช์ = ไม่มีสอบ (ล็อก) ครูประจำวิชาจะตั้งข้อสอบไม่ได้ และนักเรียนไม่เห็นปุ่ม',
                style: TextStyle(fontSize: 12.5)),
          Text(
            grouped ? 'รายวิชาทั้งหมด (${_courses.length} วิชา)' : 'รายวิชาที่${_teacherName(_teacher ?? _myCode)}สอน (${_courses.length} วิชา)',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (grouped) ...[
            DropdownButton<String>(
              value: _dept,
              isExpanded: true,
              items: depts.map((d) => DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setState(() => _dept = v ?? 'ทุกกลุ่มสาระ'),
            ),
            const SizedBox(height: 6),
          ],
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...levels.map((l) => ChoiceChip(label: Text(l), selected: _level == l, onSelected: (_) => setState(() => _level = l))),
              const SizedBox(width: 8),
              const Icon(Icons.sort_rounded, size: 18),
              DropdownButton<String>(
                value: sortBy,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'midterm', child: Text('เรียงตามวันเวลาสอบกลางภาค')),
                  DropdownMenuItem(value: 'final', child: Text('เรียงตามวันเวลาสอบปลายภาค')),
                  DropdownMenuItem(value: 'code', child: Text('เรียงตามรหัสวิชา')),
                ],
                onChanged: (v) => setState(() => _sortBy = v),
              ),
            ],
          ),
          if (!grouped && _order.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('ลำดับที่ = ลำดับวันเวลาสอบ${examTypes[_orderType]} • ส่ง / ตั้งข้อสอบวิชาที่สอบก่อนให้เสร็จก่อน',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800)),
            ),
          const SizedBox(height: 10),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('ไม่พบรายวิชาที่ท่านสอนในภาคเรียนนี้', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade700)),
            ),
          if (grouped) ..._adminGroups(shown) else _cardGrid(shown),
        ],
      ),
    );
  }

  String _teacherName(String code) {
    final t = _teachers.where((t) => '${t['code']}' == code);
    return t.isEmpty ? '${_viewer?['name'] ?? ''}' : '${t.first['name']}';
  }

  /// One button per teacher. A teacher sees only their own (the others are greyed out); an admin can open anyone.
  Future<void> _loadQuizCounts() async {
    try {
      final q = await widget.apiService.getQuizCounts(_term!, _year!);
      if (mounted) setState(() => _quizCounts = q);
    } catch (_) {}
  }

  /// แบบทดสอบย่อย / หลังเรียน of the course (any number, linked to ช่อง 1-8 of the scores page)
  Widget _quizRow(Map<String, dynamic> c) {
    final q = _quizCounts['${c['course_code']}'] as Map?;
    final n = (q?['count'] as num?)?.toInt() ?? 0;
    final ready = (q?['ready'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Icon(Icons.assignment_outlined, size: 20, color: n > 0 ? AppColors.purpleDark : Colors.grey.shade500),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('แบบทดสอบย่อย / หลังเรียน', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            Text(n == 0 ? 'ยังไม่มี • สร้างได้หลายชุด เชื่อมคะแนนกับช่อง 1–8' : '$n ชุด (เปิดให้นักเรียน $ready ชุด)',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ]),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: _term == null
              ? null
              : () async {
                  await QuizManagerDialog.show(context, widget.apiService, c, _term!, _year!);
                  _loadQuizCounts();
                },
          icon: Icon(n == 0 ? Icons.add_rounded : Icons.edit_note_rounded, size: 18),
          label: Text(n == 0 ? 'สร้าง' : 'จัดการ'),
        ),
      ]),
    );
  }

  Widget _teacherButtons() {
    Widget chip(String label, bool selected, VoidCallback? onTap, {String? count}) => ChoiceChip(
          avatar: onTap == null && !selected ? const Icon(Icons.lock_outline, size: 16) : null,
          label: Text(count == null ? label : '$label ($count)'),
          selected: selected,
          onSelected: onTap == null ? null : (_) => onTap(),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ครูผู้สอน', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (_isAdmin) chip('ทุกคน (ตามกลุ่มสาระ)', _teacher == null, () => _pickTeacher(null)),
            for (final t in _teachers)
              chip(
                '${t['name']}',
                _isAdmin ? _teacher == '${t['code']}' : '${t['code']}' == _myCode,
                _isAdmin ? () => _pickTeacher('${t['code']}') : null,
                count: '${t['course_count']}',
              ),
          ],
        ),
      ],
    );
  }

  void _pickTeacher(String? code) {
    if (code == _teacher) return;
    setState(() {
      _teacher = code;
      _level = 'ทั้งหมด';
      _dept = 'ทุกกลุ่มสาระ';
    });
    _load();
  }

  Widget _windowsCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.gold)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('วันเวลาสอบ (ทั้งโรงเรียน)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              _isAdmin
                  ? 'นักเรียนจะเห็นปุ่มข้อสอบเฉพาะในช่วงเวลานี้'
                  : 'ผู้ดูแลระบบเป็นผู้กำหนด • นักเรียนจะเห็นปุ่มข้อสอบเฉพาะในช่วงเวลานี้',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 8),
            for (final et in examTypes.keys)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    SizedBox(width: 64, child: Text(examTypes[et]!, style: const TextStyle(fontWeight: FontWeight.w600))),
                    windowChip(_windows[et] as Map),
                    Text(windowText(_windows[et] as Map)),
                    if (_isAdmin)
                      TextButton.icon(
                        icon: const Icon(Icons.edit_calendar_rounded, size: 18),
                        label: const Text('ตั้งเวลา'),
                        onPressed: () => _editWindow(et),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editWindow(String et) async {
    final w = _windows[et] as Map;
    final res = await showDialog<List<DateTime?>>(
      context: context,
      builder: (_) => _WindowDialog(
        label: examTypes[et]!,
        start: DateTime.tryParse('${w['start_at'] ?? ''}'),
        end: DateTime.tryParse('${w['end_at'] ?? ''}'),
      ),
    );
    if (res == null) return;
    String? iso(DateTime? d) => d == null
        ? null
        : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
            'T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    try {
      await widget.apiService.saveExamWindow(_term!, _year!, et, iso(res[0]), iso(res[1]));
      _snack('บันทึกวันเวลาสอบ${examTypes[et]}แล้ว');
      _load();
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? Colors.red.shade700 : null));
  }

  static String _deptOf(Map c) {
    final d = '${c['department'] ?? ''}'.trim();
    return d.isEmpty ? 'ไม่ระบุกลุ่มสาระ' : d;
  }

  Widget _cardGrid(List<Map<String, dynamic>> list) => LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth >= 760 ? (box.maxWidth - 12) / 2 : box.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: list.map((c) => SizedBox(width: w, child: _courseCard(c))).toList(),
        );
      });

  /// Admin: กลุ่มสาระ -> ระดับชั้น, each with bulk "สอบ / ไม่สอบ" actions
  List<Widget> _adminGroups(List<Map<String, dynamic>> list) {
    final byDept = <String, List<Map<String, dynamic>>>{};
    for (final c in list) {
      byDept.putIfAbsent(_deptOf(c), () => []).add(c);
    }
    final keys = byDept.keys.toList()..sort();
    return [
      for (final d in keys)
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.gold)),
          child: ExpansionTile(
            initiallyExpanded: keys.length == 1,
            shape: const Border(),
            title: Text(d, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(_lockSummary(byDept[d]!), style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _bulkMenu(byDept[d]!, 'ทั้งกลุ่มสาระ'),
              const Icon(Icons.expand_more),
            ]),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            expandedAlignment: Alignment.centerLeft,
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final lv in ({for (final c in byDept[d]!) '${c['class_level']}'}.toList()..sort())) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 6),
                  child: Row(children: [
                    Text('ระดับชั้น $lv', style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    _bulkMenu(byDept[d]!.where((c) => '${c['class_level']}' == lv).toList(), 'ทั้ง $lv'),
                  ]),
                ),
                _cardGrid(byDept[d]!.where((c) => '${c['class_level']}' == lv).toList()),
              ],
            ],
          ),
        ),
    ];
  }

  String _lockSummary(List<Map<String, dynamic>> list) {
    String part(String et) => '${examTypes[et]} สอบ ${list.where((c) => (c['locked'] as Map?)?[et] != true).length}/${list.length}';
    return '${list.length} วิชา • ${part('midterm')} • ${part('final')}';
  }

  Widget _bulkMenu(List<Map<String, dynamic>> list, String scope) {
    // (label, open these, lock these)
    const opts = <(String, List<String>, List<String>)>[
      ('สอบทั้งกลางภาคและปลายภาค', ['midterm', 'final'], []),
      ('สอบเฉพาะกลางภาค', ['midterm'], ['final']),
      ('สอบเฉพาะปลายภาค', ['final'], ['midterm']),
      ('ไม่สอบทั้งสอง (ล็อก)', [], ['midterm', 'final']),
    ];
    return PopupMenuButton<int>(
      tooltip: 'ตั้งพร้อมกัน$scope',
      icon: const Icon(Icons.tune_rounded, size: 20),
      itemBuilder: (_) => [
        PopupMenuItem(enabled: false, child: Text('$scope (${list.length} วิชา)', style: const TextStyle(fontWeight: FontWeight.bold))),
        for (var i = 0; i < opts.length; i++) PopupMenuItem(value: i, child: Text(opts[i].$1)),
      ],
      onSelected: (i) async {
        final o = opts[i];
        if (o.$2.isNotEmpty) await _setLocks(list, o.$2, false, quiet: true);
        if (o.$3.isNotEmpty) await _setLocks(list, o.$3, true, quiet: true);
        _snack('$scope (${list.length} วิชา): ${o.$1}');
      },
    );
  }

  Future<void> _setLocks(List<Map<String, dynamic>> list, List<String> types, bool locked, {bool quiet = false}) async {
    final codes = list.map((c) => '${c['course_code']}').toList();
    setState(() {
      for (final c in list) {
        final m = Map<String, dynamic>.from((c['locked'] as Map?) ?? {});
        for (final et in types) {
          m[et] = locked;
        }
        c['locked'] = m;
      }
    });
    try {
      await widget.apiService.setExamLocks(_term!, _year!, codes, types, locked);
      if (!quiet) {
        _snack('${codes.length == 1 ? codes.first : '${codes.length} วิชา'}: '
            '${types.map((t) => examTypes[t]).join(' / ')} ${locked ? 'ไม่สอบ (ล็อก)' : 'สอบ'}');
      }
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
      _load();
    }
  }

  Map<String, int> _order = {}; // course code -> ลำดับที่ by exam time (in the list shown)
  String _orderType = 'midterm';

  /// The course's own exam start (from the timetable or set per course), null when it only follows the school window.
  String? _slotStart(Map c, String et) {
    final sw = (c['schedule'] as Map?)?[et] as Map?;
    return sw != null && sw['source'] == 'course' ? '${sw['start_at']}' : null;
  }

  /// Sort by the exam that is still to come: midterm while any midterm slot has not ended, else final.
  String _autoSortType() {
    bool upcoming(String et) => _courses.any((c) {
          final sw = (c['schedule'] as Map?)?[et] as Map?;
          return sw != null && sw['source'] == 'course' && sw['has_ended'] != true;
        });
    bool any(String et) => _courses.any((c) => _slotStart(c, et) != null);
    if (upcoming('midterm')) return 'midterm';
    if (upcoming('final') || any('final')) return 'final';
    return any('midterm') ? 'midterm' : 'code';
  }

  /// ไม่มีสิทธิ์สอบ (มส.) of the course, from the attendance summary; opens the list with the teacher's ticks.
  Widget _msLine(Map<String, dynamic> c) {
    final n = (c['ms_count'] as num?)?.toInt() ?? 0;
    final ok = (c['ms_allowed'] as num?)?.toInt() ?? 0;
    final color = n == 0 ? Colors.grey.shade600 : const Color(0xFFB91C1C);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          await NoExamRightDialog.show(context, widget.apiService, '${c['course_code']}', _term!, _year!);
          _load();
        },
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(n == 0 ? Icons.verified_outlined : Icons.report_gmailerrorred_rounded, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            n == 0 ? 'ไม่มีนักเรียนติด มส.' : 'ไม่มีสิทธิ์สอบ (มส.) $n คน${ok > 0 ? ' • อนุญาตให้สอบ $ok คน' : ''} — ดู / ติ๊กอนุญาต',
            style: TextStyle(fontSize: 12.5, color: color, fontWeight: n == 0 ? null : FontWeight.w600, decoration: n == 0 ? null : TextDecoration.underline),
          ),
        ]),
      ),
    );
  }

  Future<void> _toggleBlockMs(Map<String, dynamic> c, String et, bool block) async {
    try {
      await widget.apiService.setExamBlockMs('${c['course_code']}', _term!, _year!, et, block);
      setState(() => (c[et] as Map)['block_ms'] = block);
      _snack('${c['course_code']} ${examTypes[et]}: ${block ? 'นักเรียนติด มส. สอบไม่ได้' : 'ให้สอบทุกคน'}');
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  Widget _courseCard(Map<String, dynamic> c) {
    final rank = _order['${c['course_code']}'];
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: Colors.grey.shade300)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c['course_code']} ${c['course_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  Text(
                    '${c['class_level'] ?? ''} • นักเรียน ${c['student_count']} คน${_isAdmin ? ' • ${c['teacher'] ?? ''}' : ''}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ]),
              ),
              if (rank != null)
                Tooltip(
                  message: 'ลำดับที่ $rank ตามวันเวลาสอบ${examTypes[_orderType]}',
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: AppColors.purpleDark, borderRadius: BorderRadius.circular(20)),
                    child: Text('ลำดับที่ $rank', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
            ]),
            _msLine(c),
            const Divider(height: 16),
            for (final et in examTypes.keys) _slotRow(c, et),
            ..._examTimes(c),
            const Divider(height: 14),
            _quizRow(c),
          ],
        ),
      ),
    );
  }

  Widget _slotRow(Map<String, dynamic> c, String et) {
    final e = c[et] as Map?;
    final locked = (c['locked'] as Map?)?[et] == true;
    String status;
    IconData icon;
    Color color;
    if (locked) {
      status = 'ไม่มีสอบ (ผู้ดูแลระบบล็อก)';
      icon = Icons.lock_rounded;
      color = Colors.grey.shade600;
    } else if (e == null) {
      status = 'ยังไม่ได้ตั้งข้อสอบ';
      icon = Icons.radio_button_unchecked;
      color = Colors.grey;
    } else if (e['mode'] == 'link') {
      status = 'ลิงก์ภายนอก • กรอกคะแนนเองที่หน้าบันทึกคะแนน';
      icon = Icons.link_rounded;
      color = const Color(0xFF1D4ED8);
    } else {
      status = '${e['question_count']} ข้อ${e['duration_min'] != null ? ' • ${e['duration_min']} นาที' : ''}'
          ' • ส่งแล้ว ${e['submitted_count']}/${c['student_count']}${e['ready'] == true ? '' : ' • ยังไม่พร้อมสอบ'}';
      icon = Icons.quiz_rounded;
      color = e['ready'] == true ? const Color(0xFF15803D) : const Color(0xFFB45309);
    }
    final showLink = !locked && (e == null || e['mode'] == 'link');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 2,
        children: [
          SizedBox(width: 64, child: Text(examTypes[et]!, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (_isAdmin)
            Tooltip(
              message: locked ? 'ไม่สอบ — เปิดสวิตช์ให้วิชานี้สอบ' : 'สอบ — ปิดสวิตช์เพื่อล็อกไม่ให้สอบ',
              child: Switch(value: !locked, onChanged: (v) => _setLocks([c], [et], !v)),
            ),
          Icon(icon, size: 18, color: color),
          Text(status, style: TextStyle(fontSize: 12.5, color: color)),
          if (!locked)
            TextButton(
              onPressed: () async {
                final changed = await ExamEditorDialog.show(context, widget.apiService, c, et, _term!, _year!);
                if (changed == true) _load();
              },
              child: Text(e == null ? 'สร้างข้อสอบในระบบ' : (e['mode'] == 'link' ? 'เปลี่ยนเป็นข้อสอบในระบบ' : 'แก้ข้อสอบ')),
            ),
          if (e != null && !locked)
            Tooltip(
              message: 'กดเพื่อสลับ: นักเรียนติด มส. สอบไม่ได้ / ให้สอบทุกคน',
              child: ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(e['block_ms'] != false ? Icons.block_rounded : Icons.groups_rounded, size: 16),
                label: Text(e['block_ms'] != false ? 'มส. สอบไม่ได้' : 'ให้สอบทุกคน', style: const TextStyle(fontSize: 12)),
                onPressed: () => _toggleBlockMs(c, et, e['block_ms'] == false),
              ),
            ),
          if (e != null && e['mode'] == 'quiz')
            TextButton(
              onPressed: () => ExamResultsDialog.show(context, widget.apiService, c, et, _term!, _year!).then((_) => _load()),
              child: const Text('ผลสอบ'),
            ),
        ],
      ),
      if (!locked) _scheduleLine(c, et),
      if (showLink)
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 2, bottom: 6),
          child: _LinkField(
            key: ValueKey('link-${c['course_code']}-$et'),
            initial: e == null ? '' : '${e['link_url'] ?? ''}',
            onSave: (url) => _saveLink(c, et, url),
          ),
        ),
      ]),
    );
  }

  /// วันสอบ / เวลาสอบ attached at the bottom of the course card (from the timetable or the course's own time)
  List<Widget> _examTimes(Map<String, dynamic> c) {
    final rows = <Widget>[];
    for (final et in examTypes.keys) {
      final sw = (c['schedule'] as Map?)?[et] as Map?;
      if (sw == null || sw['source'] != 'course' || (c['locked'] as Map?)?[et] == true) continue;
      final open = sw['is_open'] == true, ended = sw['has_ended'] == true;
      final color = open ? const Color(0xFF15803D) : (ended ? Colors.grey.shade600 : AppColors.purpleDark);
      rows.add(Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          Icon(Icons.event_note_rounded, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text('สอบ${examTypes[et]}: ${examWhen(sw['start_at'], sw['end_at'])}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
          ),
          Text(open ? 'เปิดสอบอยู่' : (ended ? 'สอบแล้ว' : 'เปิดเองเมื่อถึงเวลา'), style: TextStyle(fontSize: 11.5, color: color)),
        ]),
      ));
    }
    return rows;
  }

  /// เวลาสอบของวิชานี้: its own slot (ตารางสอบ) or the school window; admin can set it and ปลดล็อกก่อนเวลา.
  Widget _scheduleLine(Map<String, dynamic> c, String et) {
    final sw = Map<String, dynamic>.from(((c['schedule'] as Map?)?[et] as Map?) ?? {});
    final own = sw['source'] == 'course';
    final early = sw['opened_early'] == true;
    final open = sw['is_open'] == true;
    final when = own
        ? 'ตามตารางสอบ (วันเวลาอยู่ท้ายการ์ด)'
        : (sw['start_at'] == null ? 'ยังไม่กำหนดเวลาสอบ' : '${thaiDateTime(sw['start_at'])} – ${thaiDateTime(sw['end_at'])}');
    final color = open ? const Color(0xFF15803D) : Colors.grey.shade700;
    return Padding(
      padding: const EdgeInsets.only(left: 72, bottom: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 2,
        children: [
          Icon(open ? Icons.lock_open_rounded : Icons.schedule_rounded, size: 16, color: color),
          Text(own ? when : '$when (ช่วงสอบทั้งโรงเรียน)', style: TextStyle(fontSize: 12, color: color)),
          if (early) Text('• ปลดล็อกก่อนเวลาแล้ว', style: TextStyle(fontSize: 12, color: Colors.orange.shade800, fontWeight: FontWeight.w600)),
          if (open && !early) const Text('• เปิดสอบอยู่', style: TextStyle(fontSize: 12, color: Color(0xFF15803D), fontWeight: FontWeight.w600)),
          if (_isAdmin) ...[
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => _editCourseTime(c, et, sw, own),
              child: const Text('ตั้งเวลาวิชานี้', style: TextStyle(fontSize: 12)),
            ),
            if (early || !open)
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () => _openEarly(c, et, !early),
                child: Text(early ? 'ยกเลิกปลดล็อก' : 'ปลดล็อกให้สอบตอนนี้',
                    style: TextStyle(fontSize: 12, color: early ? Colors.red.shade700 : Colors.orange.shade800)),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _editCourseTime(Map<String, dynamic> c, String et, Map sw, bool own) async {
    final res = await showDialog<List<DateTime?>>(
      context: context,
      builder: (_) => _WindowDialog(
        label: '${examTypes[et]} ${c['course_code']}',
        start: own ? DateTime.tryParse('${sw['start_at']}') : null,
        end: own ? DateTime.tryParse('${sw['end_at']}') : null,
        clearLabel: 'ใช้ช่วงสอบทั้งโรงเรียน',
      ),
    );
    if (res == null) return;
    String? iso(DateTime? d) => d == null
        ? null
        : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
            'T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    try {
      await widget.apiService.setExamCourseTime(_term!, _year!, '${c['course_code']}', et, iso(res[0]), iso(res[1]));
      _snack('บันทึกเวลาสอบ${examTypes[et]} ${c['course_code']} แล้ว');
      _load();
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  Future<void> _openEarly(Map<String, dynamic> c, String et, bool open) async {
    if (open) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('ปลดล็อก ${c['course_code']} ให้สอบ${examTypes[et]}ตอนนี้?'),
          content: const Text('นักเรียนที่เรียนวิชานี้จะเห็นปุ่มและเริ่มสอบได้ทันที จนถึงเวลาสิ้นสุดของวิชานี้'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ปลดล็อก')),
          ],
        ),
      );
      if (yes != true) return;
    }
    try {
      await widget.apiService.openExamEarly(_term!, _year!, ['${c['course_code']}'], et, open);
      _snack(open ? 'ปลดล็อก ${c['course_code']} แล้ว นักเรียนสอบได้ทันที' : 'ยกเลิกการปลดล็อก ${c['course_code']} แล้ว');
      _load();
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  /// Saves (or, when emptied, removes) the external link of one exam slot without reloading the page.
  Future<String?> _saveLink(Map<String, dynamic> c, String et, String url) async {
    final code = '${c['course_code']}';
    final e = c[et] as Map?;
    try {
      if (url.isEmpty) {
        if (e != null) await widget.apiService.deleteExamPaper(code, _term!, _year!, et);
        setState(() => c[et] = null);
        return null;
      }
      final saved = await widget.apiService.saveExamPaper({
        'course_code': code,
        'term': _term,
        'year': _year,
        'exam_type': et,
        'mode': 'link',
        'title': e?['title'] ?? 'ข้อสอบ${examTypes[et]} $code',
        'link_url': url,
        'duration_min': null,
        'ready': true,
        'questions': [],
      });
      setState(() => c[et] = {...saved, 'submitted_count': 0});
      return null;
    } catch (err) {
      return err.toString().replaceFirst('Exception: ', '');
    }
  }
}

/// แถบวางลิงก์ข้อสอบ: paste a link and it is saved by itself (or press Enter / the save icon). Empty + save removes it.
class _LinkField extends StatefulWidget {
  final String initial;
  final Future<String?> Function(String url) onSave; // returns an error message, or null when saved
  const _LinkField({super.key, required this.initial, required this.onSave});

  @override
  State<_LinkField> createState() => _LinkFieldState();
}

class _LinkFieldState extends State<_LinkField> {
  static final _url = RegExp(r'^https?://\S+$');
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);
  late String _saved = widget.initial;
  String? _error;
  bool _busy = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  bool get _dirty => _ctrl.text.trim() != _saved;

  Future<void> _save() async {
    _debounce?.cancel();
    final url = _ctrl.text.trim();
    if (url == _saved || _busy) return;
    if (url.isNotEmpty && !_url.hasMatch(url)) {
      setState(() => _error = 'ลิงก์ต้องขึ้นต้นด้วย http:// หรือ https://');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onSave(url);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) _saved = url;
    });
  }

  void _changed(String v) {
    setState(() => _error = null);
    _debounce?.cancel();
    // a pasted, complete link saves itself
    if (_url.hasMatch(v.trim())) _debounce = Timer(const Duration(milliseconds: 700), _save);
  }

  @override
  Widget build(BuildContext context) {
    Widget suffix;
    if (_busy) {
      suffix = const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)));
    } else if (_dirty) {
      suffix = IconButton(tooltip: 'บันทึกลิงก์', icon: const Icon(Icons.save_rounded), onPressed: _save);
    } else if (_saved.isNotEmpty) {
      suffix = const Tooltip(message: 'บันทึกแล้ว', child: Icon(Icons.check_circle_rounded, color: Color(0xFF15803D)));
    } else {
      suffix = const SizedBox.shrink();
    }
    return TextField(
      controller: _ctrl,
      keyboardType: TextInputType.url,
      onChanged: _changed,
      onSubmitted: (_) => _save(),
      onTapOutside: (_) {
        if (_dirty) _save();
      },
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.link_rounded, size: 18),
        hintText: 'วางลิงก์ข้อสอบที่นี่ (เช่น Google Form) — บันทึกให้อัตโนมัติ',
        helperText: _error == null && _saved.isNotEmpty ? 'นักเรียนเปิดลิงก์นี้ได้ในช่วงเวลาสอบ • คะแนนกรอกเองที่หน้าบันทึกคะแนน' : null,
        errorText: _error,
        suffixIcon: suffix,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

class _WindowDialog extends StatefulWidget {
  final String label;
  final DateTime? start;
  final DateTime? end;
  final String clearLabel;
  const _WindowDialog({required this.label, this.start, this.end, this.clearLabel = 'ล้าง (ปิดการสอบ)'});

  @override
  State<_WindowDialog> createState() => _WindowDialogState();
}

class _WindowDialogState extends State<_WindowDialog> {
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    _start = widget.start;
    _end = widget.end;
  }

  Future<DateTime?> _pick(DateTime? initial, {required bool isEnd}) async {
    final now = DateTime.now();
    final base = initial ?? (isEnd && _start != null ? _start! : now);
    final d = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (d == null || !mounted) return null;
    final t = await showTimePicker(
      context: context,
      builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
      initialTime: initial != null ? TimeOfDay.fromDateTime(initial) : TimeOfDay(hour: isEnd ? 16 : 8, minute: isEnd ? 30 : 0),
    );
    if (t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('วันเวลาสอบ${widget.label}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('เปิดสอบ'),
            subtitle: Text(_start == null ? 'ยังไม่เลือก' : thaiDateTime(_start!.toIso8601String())),
            onTap: () async {
              final d = await _pick(_start, isEnd: false);
              if (d != null) setState(() => _start = d);
            },
          ),
          ListTile(
            leading: const Icon(Icons.stop_circle_outlined),
            title: const Text('ปิดสอบ'),
            subtitle: Text(_end == null ? 'ยังไม่เลือก' : thaiDateTime(_end!.toIso8601String())),
            onTap: () async {
              final d = await _pick(_end, isEnd: true);
              if (d != null) setState(() => _end = d);
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, <DateTime?>[null, null]), child: Text(widget.clearLabel)),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ยกเลิก')),
        FilledButton(
          onPressed: _start != null && _end != null && _end!.isAfter(_start!) ? () => Navigator.pop(context, [_start, _end]) : null,
          child: const Text('บันทึก'),
        ),
      ],
    );
  }
}

const questionTypes = {
  'choice': 'ปรนัย',
  'number': 'เติมตัวเลข',
  'text': 'เติมคำ',
  'truefalse': 'ถูก / ผิด',
  'match': 'จับคู่',
  'cloze': 'เติมคำในเรื่อง (cloze)',
  'photo': 'เขียนตอบ ถ่ายภาพส่ง',
};

/// One question in the editor: ปรนัย (choices + the right one), เติมตัวเลข (numeric key, ± tolerance, unit)
/// or เขียนตอบ ถ่ายภาพส่ง (the teacher's เฉลย / แนวคำตอบ, marked by hand); each with its own points.
class _QuestionDraft {
  String type;
  final TextEditingController q;
  final List<TextEditingController> choices;
  int? answer;
  final TextEditingController points;
  final TextEditingController numAnswer;
  final TextEditingController tolerance;
  final TextEditingController unit;
  final TextEditingController guide;
  final TextEditingController textAnswer; // เติมคำ: accepted words, "a / b"
  final TextEditingController explain; // วิธีทำ / คำอธิบายเฉลย: the teacher's view only (the AI helper fills it)
  bool showExplain = false;
  final KindDraft kind = KindDraft(); // ถูก/ผิด, จับคู่, cloze
  String? image; // a picture with the question
  bool asImage = false; // students see the picture (the question as printed) instead of the text
  String labels = 'thai'; // ปรนัย printed as ก ข ค / a b c (latin) / 1 2 3 (number)
  String get letterSet => labels == 'latin' ? 'abcde' : labels == 'number' ? '12345' : choiceLetters.join();

  _QuestionDraft(this.type, String text, List<String> cs, this.answer,
      {String pts = '1', String num = '', String tol = '', String un = '', String gd = '', String ta = '', String ex = '', this.image})
      : q = TextEditingController(text: text),
        explain = TextEditingController(text: ex),
        textAnswer = TextEditingController(text: ta),
        choices = cs.map((c) => TextEditingController(text: c)).toList(),
        points = TextEditingController(text: pts),
        numAnswer = TextEditingController(text: num),
        tolerance = TextEditingController(text: tol),
        unit = TextEditingController(text: un),
        guide = TextEditingController(text: gd);

  factory _QuestionDraft.blank([String type = 'choice']) => _QuestionDraft(type, '', ['', '', '', ''], null)..kind.ensure(type);

  factory _QuestionDraft.fromJson(Map q) {
    final type = '${q['type'] ?? 'choice'}';
    String n(dynamic v) => v == null ? '' : (v is num && v == v.roundToDouble() ? '${v.toInt()}' : '$v');
    final ans = q['answer'];
    return _QuestionDraft(
      type,
      '${q['q'] ?? ''}',
      type == 'choice' ? (q['choices'] as List? ?? []).map((e) => '$e').toList() : ['', '', '', ''],
      type == 'choice' ? (q['answer'] as num?)?.toInt() : null,
      pts: n(q['points'] ?? 1),
      num: type == 'number' ? '${q['answer'] ?? ''}' : '',
      tol: type == 'number' && (q['tolerance'] ?? 0) != 0 ? n(q['tolerance']) : '',
      un: '${q['unit'] ?? ''}',
      gd: '${q['guide'] ?? ''}',
      ta: type == 'text' ? (ans is List ? ans.map((e) => '$e').join(' / ') : '${ans ?? ''}') : '',
      ex: '${q['explain'] ?? ''}',
      image: q['image'] == null || '${q['image']}'.isEmpty ? null : '${q['image']}',
    )
      ..kind.load(type, q)
      ..asImage = q['as_image'] == true && q['image'] != null
      ..labels = q['labels'] == 'latin' || q['labels'] == 'number' ? '${q['labels']}' : 'thai';
  }

  bool get hasKey => switch (type) {
        'choice' => answer != null,
        'number' => numAnswer.text.trim().isNotEmpty,
        'text' => splitAccepts(textAnswer.text).isNotEmpty,
        _ => kind.hasKey(type),
      };

  /// points of one part (a set's statement / pair / blank) or of the whole question
  double get pointEach => double.tryParse(points.text.trim()) ?? 1;
  int get parts => setTypes.contains(type) ? kind.parts(type) : 1;
  double get pointValue => pointEach * parts;

  void dispose() {
    for (final c in [q, points, numAnswer, tolerance, unit, guide, textAnswer, explain, ...choices]) {
      c.dispose();
    }
    kind.dispose();
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'q': q.text,
        'points': points.text.trim().isEmpty ? 1 : points.text.trim(),
        if (type == 'choice') ...{'choices': choices.map((c) => c.text).toList(), 'answer': answer},
        if (type == 'number') ...{'answer': numAnswer.text.trim(), 'tolerance': tolerance.text.trim().isEmpty ? 0 : tolerance.text.trim(), 'unit': unit.text.trim()},
        if (type == 'photo') 'guide': guide.text,
        if (type == 'text') ...{'answer': textAnswer.text.trim(), 'unit': unit.text.trim()},
        ...kind.toJson(type),
        if (image != null) 'image': image,
        if (image != null && asImage) 'as_image': true,
        if (type == 'choice' && labels != 'thai') 'labels': labels,
        if (explain.text.trim().isNotEmpty) 'explain': explain.text.trim(),
      };
}

/// Sets up one exam slot: an external link, or a multiple-choice paper (typed here or pasted from Word / Excel).
class ExamEditorDialog extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> course;
  final String examType;
  final String term;
  final String year;
  /// แบบทดสอบย่อย (many per course, linked to ช่อง 1-8) instead of the กลางภาค / ปลายภาค paper
  final bool isQuiz;
  final int? quizId;
  const ExamEditorDialog({super.key, required this.apiService, required this.course, required this.examType, required this.term, required this.year,
      this.isQuiz = false, this.quizId});

  static Future<bool?> show(BuildContext context, ApiService api, Map<String, dynamic> course, String et, String term, String year) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ExamEditorDialog(apiService: api, course: course, examType: et, term: term, year: year),
    );
  }

  static Future<bool?> showQuiz(BuildContext context, ApiService api, Map<String, dynamic> course, String term, String year, {int? quizId}) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ExamEditorDialog(apiService: api, course: course, examType: 'quiz', term: term, year: year, isQuiz: true, quizId: quizId),
    );
  }

  @override
  State<ExamEditorDialog> createState() => _ExamEditorDialogState();
}

class _ExamEditorDialogState extends State<ExamEditorDialog> {
  bool _loading = true;
  bool _saving = false;
  bool _exists = false;
  int _attempts = 0;
  String _mode = 'quiz';
  bool _ready = true;
  bool _blockMs = true; // นักเรียนติด มส. สอบไม่ได้ (ยกเว้นที่ครูติ๊กอนุญาต)
  final _title = TextEditingController();
  final _link = TextEditingController();
  final _duration = TextEditingController();
  final _slotPoints = TextEditingController(); // แบบทดสอบย่อย: what it is worth in its column (empty = shares the rest)
  final List<_QuestionDraft> _questions = [];
  // แบบทดสอบย่อย
  int? _slot; // 0..7 = ช่อง 1..8, null = not linked
  DateTime? _qStart;
  DateTime? _qEnd;
  bool _classOnly = false;
  int _maxAttempts = 1; // 0 = unlimited
  List<dynamic> _unitMax = List.filled(8, null);

  String get _code => '${widget.course['course_code']}';
  Map<String, String> get _types => widget.isQuiz ? {for (final e in questionTypes.entries) if (e.key != 'photo') e.key: e.value} : questionTypes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _link.dispose();
    _duration.dispose();
    _slotPoints.dispose();
    for (final q in _questions) {
      q.dispose();
    }
    super.dispose();
  }

  Future<void> _loadQuiz() async {
    final list = await widget.apiService.listQuizzes(_code, widget.term, widget.year);
    final p = widget.quizId == null ? null : await widget.apiService.getQuiz(widget.quizId!);
    if (!mounted) return;
    setState(() {
      _unitMax = (list['unit_max'] as List? ?? []);
      if (p != null) {
        _exists = true;
        _attempts = (p['attempt_count'] as num?)?.toInt() ?? 0;
        _ready = p['ready'] == true;
        _title.text = '${p['title'] ?? ''}';
        _duration.text = p['duration_min'] == null ? '' : '${p['duration_min']}';
        _slot = (p['unit_slot'] as num?)?.toInt();
        _slotPoints.text = p['slot_points'] == null ? '' : _num(p['slot_points']);
        _qStart = DateTime.tryParse('${p['start_at'] ?? ''}');
        _qEnd = DateTime.tryParse('${p['end_at'] ?? ''}');
        _classOnly = p['class_only'] == true;
        _maxAttempts = (p['max_attempts'] as num?)?.toInt() ?? 1;
        _mode = '${p['mode'] ?? 'quiz'}';
        _link.text = '${p['link_url'] ?? ''}';
        for (final q in (p['questions'] as List? ?? [])) {
          _questions.add(_QuestionDraft.fromJson(q as Map));
        }
      } else {
        _ready = false;
        _title.text = 'แบบทดสอบย่อย ${(list['quizzes'] as List? ?? []).length + 1}';
      }
      if (_questions.isEmpty) _questions.add(_QuestionDraft.blank());
      _loading = false;
    });
  }

  Future<void> _load() async {
    if (widget.isQuiz) {
      try {
        await _loadQuiz();
      } catch (e) {
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
      return;
    }
    try {
      final p = await widget.apiService.getExamPaper(_code, widget.term, widget.year, widget.examType);
      if (!mounted) return;
      setState(() {
        if (p != null) {
          _exists = true;
          _attempts = (p['attempt_count'] as num?)?.toInt() ?? 0;
          _mode = '${p['mode']}';
          _ready = p['ready'] == true;
          _blockMs = p['block_ms'] != false;
          _title.text = '${p['title'] ?? ''}';
          _link.text = '${p['link_url'] ?? ''}';
          _duration.text = p['duration_min'] == null ? '' : '${p['duration_min']}';
          for (final q in (p['questions'] as List? ?? [])) {
            _questions.add(_QuestionDraft.fromJson(q as Map));
          }
        } else {
          _title.text = 'ข้อสอบ${examTypes[widget.examType]} $_code';
        }
        if (_questions.isEmpty) _questions.add(_QuestionDraft.blank());
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  bool _reading = false;
  String _readingMsg = '';
  bool _phone = true; // the student's phone beside the editor (wide screens)

  /// the paper as a student gets it, for the phone preview
  List<Map<String, dynamic>> _studentQuestions() => [
        for (final q in _questions)
          if (q.q.text.trim().isNotEmpty || q.image != null || (setTypes.contains(q.type) && q.parts > 0) || q.choices.any((c) => c.text.trim().isNotEmpty))
            studentCopy(q.toJson(), parts: q.parts),
      ];

  String get _phoneHeader => '${widget.isQuiz ? 'แบบทดสอบ' : 'ข้อสอบ'} $_code';

  void _openPhone() {
    final size = MediaQuery.of(context).size;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(8),
        backgroundColor: Colors.transparent,
        child: Stack(children: [
          StudentPhonePreview(
            api: widget.apiService,
            title: _title.text.trim(),
            header: _phoneHeader,
            durationMin: int.tryParse(_duration.text.trim()),
            height: (size.height - 80).clamp(400, 820).toDouble(),
            questions: _studentQuestions,
          ),
          Positioned(right: 4, top: 4, child: IconButton.filledTonal(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx))),
        ]),
      ),
    );
  }

  /// ข้อสอบทั้งชุดจากไฟล์ Word / PDF ของครู -> ข้อในตัวแก้ไข (ตรวจและเลือกเฉลยที่ขาดได้ก่อนบันทึก)
  Future<void> _uploadFile() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['docx', 'doc', 'pdf', 'jpg', 'jpeg', 'png', 'webp']);
    if (picked.isEmpty) return;
    final f = picked.first;
    setState(() {
      _reading = true;
      _readingMsg = '';
    });
    try {
      final bytes = await f.readAsBytes();
      final r = await widget.apiService.parseExamFile(bytes, f.name, onProgress: (m) {
        if (mounted) setState(() => _readingMsg = m);
      });
      if (!mounted) return;
      final qs = (r['questions'] as List).cast<Map>();
      final notes = (r['notes'] as List? ?? []).map((e) => '$e').toList();
      final counts = Map<String, dynamic>.from(r['counts'] as Map? ?? {});
      final photos = (counts['photo'] as num?)?.toInt() ?? 0;
      final skipPhoto = widget.isQuiz && photos > 0;
      final hasExisting = _questions.any((q) => q.q.text.trim().isNotEmpty || q.image != null || (setTypes.contains(q.type) && q.parts > 0));
      final scans = qs.where((q) => q['scan_image'] != null).length;
      // PDF / scans / photos / Word with formulas: the picture of each question unless the teacher wants text
      var useScan = scans > 0;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
          title: Text('อ่าน "${f.name}" ได้ ${qs.length} ข้อ'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  [
                    for (final t in questionTypes.entries)
                      if (((counts[t.key] as num?)?.toInt() ?? 0) > 0) '${t.value} ${counts[t.key]} ${setTypes.contains(t.key) ? 'ชุด' : 'ข้อ'}',
                  ].join(' • '),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final n in notes)
                // as pictures, notes about cut-out drawings do not apply
                if (!(useScan && (n.startsWith('ตัดรูปประกอบ') || n.startsWith('ใส่รูปจากไฟล์') || n.startsWith('ในไฟล์มีรูปภาพที่ไม่ได้นำเข้า'))))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.orange.shade800),
                    const SizedBox(width: 6),
                    Expanded(child: Text(n, style: TextStyle(fontSize: 13, color: Colors.orange.shade900))),
                  ]),
                ),
              if (skipPhoto)
                Text('แบบทดสอบย่อยตรวจอัตโนมัติ ใช้ข้อเขียนตอบไม่ได้ — จะข้ามข้อเขียน $photos ข้อ',
                    style: TextStyle(fontSize: 13, color: Colors.red.shade700)),
              if (scans > 0) ...[
                const SizedBox(height: 6),
                const Text('นำเข้าข้อสอบแบบ', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                SegmentedButton<bool>(
                  showSelectedIcon: true,
                  segments: const [
                    ButtonSegment(value: true, icon: Icon(Icons.image_outlined), label: Text('เป็นภาพตามต้นฉบับ (แนะนำ)')),
                    ButtonSegment(value: false, icon: Icon(Icons.text_fields_rounded), label: Text('เป็นข้อความ')),
                  ],
                  selected: {useScan},
                  onSelectionChanged: (v) => setD(() => useScan = v.first),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      useScan
                          ? 'แต่ละข้อเป็นภาพจากไฟล์ (โจทย์ รูป สูตร ตัวเลือก ครบตามกระดาษ) ไม่ต้องแก้ข้อความ • ตัวเลือกเป็น ก ข ค ง ให้กดเลือก • ครูเลือกเฉลยแต่ละข้อ • ปิดเลขข้อและคำตอบในวงเล็บไว้แล้ว'
                          : 'แปลงเป็นข้อความให้แก้ไขได้ — สูตร ตาราง รูปวาด และไฟล์สแกน อาจเพี้ยน ต้องตรวจทุกข้อ',
                      style: TextStyle(fontSize: 12.5, color: useScan ? const Color(0xFF6D28D9) : Colors.orange.shade900)),
                ),
              ],
              const SizedBox(height: 6),
              Text('ตรวจทุกข้อกับต้นฉบับ (โจทย์ ตัวเลือก เฉลย คะแนน รูป) ก่อนกดบันทึก • คำตอบที่ครูเขียนในช่องว่างเป็นเฉลย นักเรียนเห็นเป็นช่องว่าง',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ยกเลิก')),
            if (hasExisting) OutlinedButton(onPressed: () => Navigator.pop(ctx, 'replace'), child: const Text('แทนที่ข้อเดิมทั้งหมด')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'append'), child: Text(hasExisting ? 'เพิ่มต่อท้าย' : 'ใส่ข้อสอบ')),
          ],
        )),
      );
      if (choice == null || !mounted) return;
      final gone = <_QuestionDraft>[];
      var added = 0;
      setState(() {
        if (choice == 'replace') {
          gone.addAll(_questions);
          _questions.clear();
        } else {
          final blank = _questions
              .where((q) => q.q.text.trim().isEmpty && q.choices.every((c) => c.text.trim().isEmpty) && !(setTypes.contains(q.type) && q.parts > 0))
              .toList();
          gone.addAll(blank);
          _questions.removeWhere(blank.contains);
        }
        for (final q in qs) {
          if (skipPhoto && q['type'] == 'photo') continue;
          final m = Map<String, dynamic>.from(q);
          if (useScan && m['scan_image'] != null) {
            // the question is its picture: no text to clean up, the choices are the printed letters
            m['image'] = m['scan_image'];
            m['as_image'] = true;
            m['q'] = '';
            if (m['type'] == 'choice') {
              final found = (m['choices'] as List? ?? []).length;
              final n = found >= 4 ? (found > choiceLetters.length ? choiceLetters.length : found) : 4;
              final String set = m['labels'] == 'latin' ? 'abcde' : m['labels'] == 'number' ? '12345' : choiceLetters.join();
              m['choices'] = [for (var c = 0; c < n; c++) set[c]];
              final a = (m['answer'] as num?)?.toInt();
              m['answer'] = a != null && a < n ? a : null;
            }
          }
          _questions.add(_QuestionDraft.fromJson(m));
          added++;
        }
        if (_questions.isEmpty) _questions.add(_QuestionDraft.blank());
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final q in gone) {
          q.dispose();
        }
      });
      _snack('ใส่ข้อสอบจากไฟล์แล้ว $added ข้อ — ตรวจแล้วกดบันทึก');
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _paste() async {
    final ctrl = TextEditingController();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text != null) ctrl.text = clip!.text!;
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('วางข้อสอบจาก Word / Excel'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Word: ขึ้นข้อด้วยเลข "1." ตัวเลือก "ก." "ข." ... และบรรทัด "ตอบ ข"\n'
                '• ไม่มีตัวเลือก + "ตอบ 45" = เติมตัวเลข  • ไม่มีตัวเลือก + "เฉลย ..." หรือไม่มีคำตอบ = เขียนตอบ ถ่ายภาพส่ง\n'
                'Excel: 1 แถวต่อ 1 ข้อ — โจทย์ | ก | ข | ค | ง | คำตอบ (ก หรือ 1)  หรือ  โจทย์ | ตัวเลขคำตอบ',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 14,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '1. 2+2 เท่ากับเท่าไร\nก. 3\nข. 4\nค. 5\nง. 6\nตอบ ข',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('แปลงเป็นข้อสอบ')),
        ],
      ),
    );
    ctrl.dispose();
    if (text == null || text.trim().isEmpty) return;
    try {
      final qs = await widget.apiService.parseExamText(text);
      if (!mounted) return;
      if (qs.isEmpty) {
        _snack('ไม่พบข้อสอบในข้อความที่วาง', error: true);
        return;
      }
      setState(() {
        _questions.removeWhere((q) => q.q.text.trim().isEmpty && q.choices.every((c) => c.text.trim().isEmpty));
        for (final q in qs) {
          _questions.add(_QuestionDraft.fromJson(q));
        }
      });
      _snack('เพิ่ม ${qs.length} ข้อแล้ว');
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? Colors.red.shade700 : null));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    if (widget.isQuiz) {
      try {
        String? iso(DateTime? d) => d?.toIso8601String().substring(0, 16);
        await widget.apiService.saveQuiz({
          'course_code': _code,
          'term': widget.term,
          'year': widget.year,
          'id': widget.quizId,
          'title': _title.text,
          'unit_slot': _slot,
          'slot_points': _slot == null ? null : double.tryParse(_slotPoints.text.trim()),
          'duration_min': int.tryParse(_duration.text.trim()),
          'start_at': iso(_qStart),
          'end_at': iso(_qEnd),
          'class_only': _classOnly,
          'max_attempts': _maxAttempts,
          'ready': _ready,
          'mode': _mode,
          'link_url': _link.text,
          'questions': _mode == 'quiz' ? _questions.map((q) => q.toJson()).toList() : [],
        });
        if (!mounted) return;
        _snack('บันทึกแบบทดสอบ "${_title.text.trim()}" แล้ว${_slot != null ? ' • คะแนนเข้าช่อง ${_slot! + 1} ให้เอง' : ''}');
        Navigator.pop(context, true);
      } catch (e) {
        setState(() => _saving = false);
        _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
      }
      return;
    }
    try {
      await widget.apiService.saveExamPaper({
        'course_code': _code,
        'term': widget.term,
        'year': widget.year,
        'exam_type': widget.examType,
        'mode': _mode,
        'title': _title.text,
        'link_url': _link.text,
        'duration_min': int.tryParse(_duration.text.trim()),
        'ready': _ready,
        'block_ms': _blockMs,
        'questions': _mode == 'quiz' ? _questions.map((q) => q.toJson()).toList() : [],
      });
      if (!mounted) return;
      _snack('บันทึกข้อสอบ${examTypes[widget.examType]} $_code แล้ว');
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _saving = false);
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isQuiz ? 'ลบแบบทดสอบนี้?' : 'ลบข้อสอบนี้?'),
        content: Text(widget.isQuiz
            ? (_attempts > 0
                ? 'มีนักเรียนทำแล้ว $_attempts คน ผลจะถูกลบด้วย${_slot != null ? ' • ช่อง ${_slot! + 1} คำนวณใหม่จากชุดที่เหลือ' : ''}'
                : 'นักเรียนจะไม่เห็นแบบทดสอบนี้')
            : (_attempts > 0 ? 'มีนักเรียนสอบแล้ว $_attempts คน ผลสอบจะถูกลบด้วย (คะแนนที่เข้าหน้าบันทึกคะแนนแล้วยังอยู่)' : 'นักเรียนจะไม่เห็นปุ่มข้อสอบวิชานี้')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700), onPressed: () => Navigator.pop(ctx, true), child: const Text('ลบ')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      if (widget.isQuiz) {
        await widget.apiService.deleteQuiz(widget.quizId!);
        if (mounted) Navigator.pop(context, true);
        return;
      }
      await widget.apiService.deleteExamPaper(_code, widget.term, widget.year, widget.examType);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // a phone beside the editor when there is room for both (and the paper is built here, not a link)
    final roomy = size.width >= 1290;
    final showPhone = roomy && _phone && _mode == 'quiz' && !_loading;
    final phoneH = (size.height * 0.92 - 60).clamp(420, 800).toDouble();
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.gold, width: 1.5)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: showPhone ? 1290 : 860, maxHeight: size.height * 0.92),
        child: _loading
            ? const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()))
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
                    decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                    child: Row(children: [
                      Expanded(
                        child: Text('${widget.isQuiz ? 'แบบทดสอบย่อย' : 'ข้อสอบ${examTypes[widget.examType]}'} • $_code ${widget.course['course_name'] ?? ''}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                      if (_mode == 'quiz')
                        TextButton.icon(
                          onPressed: roomy ? () => setState(() => _phone = !_phone) : _openPhone,
                          icon: const Icon(Icons.phone_android_rounded, size: 18),
                          label: Text(roomy ? (_phone ? 'ซ่อนมุมมองนักเรียน' : 'มุมมองนักเรียน (มือถือ)') : 'ดูแบบนักเรียน'),
                        ),
                      IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
                    ]),
                  ),
                  Flexible(
                    child: ListView(
                      padding: const EdgeInsets.all(14),
                      shrinkWrap: true,
                      children: widget.isQuiz
                          ? [
                              TextField(controller: _title, decoration: const InputDecoration(labelText: 'ชื่อแบบทดสอบ', hintText: 'เช่น แบบทดสอบหลังเรียน หน่วยที่ 1', border: OutlineInputBorder())),
                              const SizedBox(height: 12),
                              SegmentedButton<String>(
                                segments: const [
                                  ButtonSegment(value: 'quiz', icon: Icon(Icons.quiz_outlined), label: Text('สร้างแบบทดสอบในระบบ')),
                                  ButtonSegment(value: 'link', icon: Icon(Icons.link_rounded), label: Text('แนบลิงก์ภายนอก')),
                                ],
                                selected: {_mode},
                                onSelectionChanged: (s) => setState(() => _mode = s.first),
                              ),
                              const SizedBox(height: 12),
                              if (_mode == 'link') ...[
                                TextField(
                                  controller: _link,
                                  keyboardType: TextInputType.url,
                                  decoration: const InputDecoration(labelText: 'ลิงก์แบบทดสอบ (เช่น Google Form, Quizizz, Kahoot)', hintText: 'https://...', border: OutlineInputBorder()),
                                ),
                                const SizedBox(height: 6),
                                _note(Icons.info_outline,
                                    'นักเรียนกดปุ่มแล้วเปิดลิงก์นี้ (เฉพาะช่วงเวลาที่ตั้งด้านล่าง) • ระบบไม่รู้คะแนนจากเว็บภายนอก จึงไม่เติมช่องคะแนนให้ — ครูกรอกคะแนนเองในหน้าบันทึกคะแนน'),
                                const SizedBox(height: 12),
                                ..._quizSettings(link: true),
                                FilterChip(
                                  label: const Text('เปิดให้นักเรียนเห็น'),
                                  selected: _ready,
                                  onSelected: (v) => setState(() => _ready = v),
                                ),
                              ] else ...[
                                ..._quizSettings(),
                                const SizedBox(height: 12),
                                ..._quizFields(),
                              ],
                            ]
                          : [
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'quiz', icon: Icon(Icons.quiz_outlined), label: Text('สร้างข้อสอบในระบบ')),
                            ButtonSegment(value: 'link', icon: Icon(Icons.link_rounded), label: Text('แนบลิงก์ภายนอก')),
                          ],
                          selected: {_mode},
                          onSelectionChanged: (s) => setState(() => _mode = s.first),
                        ),
                        const SizedBox(height: 12),
                        TextField(controller: _title, decoration: const InputDecoration(labelText: 'ชื่อข้อสอบ', border: OutlineInputBorder())),
                        const SizedBox(height: 10),
                        const Text('สิทธิ์สอบ', style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: true, icon: Icon(Icons.block_rounded), label: Text('นักเรียนติด มส. สอบไม่ได้')),
                            ButtonSegment(value: false, icon: Icon(Icons.groups_rounded), label: Text('ให้สอบทุกคน')),
                          ],
                          selected: {_blockMs},
                          onSelectionChanged: (v) => setState(() => _blockMs = v.first),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _blockMs
                                ? 'มส. = เวลาเรียนไม่ถึง 80% ตามสรุปการมาเรียน (หรือครูกำหนด มส. ในหน้าบันทึกคะแนน) • นักเรียนจะเห็นปุ่มซีดและข้อความให้ติดต่อครูประจำวิชา • ติ๊กอนุญาตรายคนได้ที่ "ไม่มีสิทธิ์สอบ" (หน้าคลังข้อมูล หรือบนการ์ดวิชา)'
                                : 'นักเรียนทุกคนกดปุ่มสอบวิชานี้ได้ รวมถึงคนที่ติด มส.',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_mode == 'link') ..._linkFields() else ..._quizFields(),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_exists) TextButton.icon(onPressed: _saving ? null : _delete, icon: Icon(Icons.delete_outline, color: Colors.red.shade700), label: Text(widget.isQuiz ? 'ลบแบบทดสอบ' : 'ลบข้อสอบ', style: TextStyle(color: Colors.red.shade700))),
                        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ยกเลิก')),
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded),
                          label: const Text('บันทึก'),
                        ),
                      ],
                    ),
                  ),
                ],
              )),
              if (showPhone)
                Container(
                  width: 420,
                  padding: const EdgeInsets.fromLTRB(8, 14, 14, 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    border: Border(left: BorderSide(color: Colors.grey.shade300)),
                    borderRadius: const BorderRadius.only(topRight: Radius.circular(16), bottomRight: Radius.circular(16)),
                  ),
                  child: SingleChildScrollView(
                    child: StudentPhonePreview(
                      api: widget.apiService,
                      title: _title.text.trim(),
                      header: _phoneHeader,
                      durationMin: int.tryParse(_duration.text.trim()),
                      height: phoneH,
                      questions: _studentQuestions,
                    ),
                  ),
                ),
            ]),
      ),
    );
  }

  List<Widget> _linkFields() => [
        TextField(
          controller: _link,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'ลิงก์ข้อสอบ (เช่น Google Form)', hintText: 'https://...', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        _note(Icons.info_outline, 'นักเรียนกดปุ่มรหัสวิชาแล้วจะเปิดลิงก์นี้ (เฉพาะในช่วงเวลาสอบ) • คะแนนให้ครูกรอกเองที่หน้า "บันทึกคะแนน"'),
      ];

  List<Widget> _quizFields() => [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: TextField(
                controller: _duration,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                    labelText: widget.isQuiz ? 'เวลาทำ (นาที) รวมทุกครั้ง' : 'เวลาทำ (นาที)',
                    hintText: widget.isQuiz ? 'ว่าง = ไม่จำกัดเวลา' : 'ว่าง = ถึงเวลาปิดสอบ',
                    helperText: widget.isQuiz ? 'นับจากครั้งแรกที่นักเรียนกดเริ่ม ทำซ้ำได้ภายในเวลานี้' : null,
                    border: const OutlineInputBorder()),
              ),
            ),
            FilterChip(
              label: Text(widget.isQuiz ? 'เปิดให้นักเรียนเห็น' : 'พร้อมสอบ (นักเรียนเห็นปุ่ม)'),
              selected: _ready,
              onSelected: (v) => setState(() => _ready = v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.isQuiz)
          _note(Icons.calculate_outlined,
              'ทุกแบบ (ปรนัย เติมตัวเลข เติมคำ ถูก/ผิด จับคู่ cloze) ระบบตรวจกับเฉลยเองทันทีที่นักเรียนส่ง • ชุดข้อย่อยคิดคะแนนต่อช่อง • สลับข้อและตัวเลือกให้แต่ละคน • ยังไม่กด "เปิดให้นักเรียนเห็น" = ร่าง (ไม่นับคะแนน)')
        else
          _note(Icons.calculate_outlined,
              'ปรนัย เติมตัวเลข เติมคำ ถูก/ผิด จับคู่ cloze ระบบตรวจกับเฉลยเอง (ชุดข้อย่อยคิดคะแนนต่อช่อง ครูกดให้ถูก/ผิดรายช่องได้ในหน้า "ผลสอบ") • ข้อเขียนตอบ ถ่ายภาพส่ง ครูให้คะแนนในหน้า "ผลสอบ" • คะแนนรวมคิดตามสัดส่วนคะแนนเต็มช่อง${examTypes[widget.examType]} (ทศนิยม 1 ตำแหน่ง ปัดขึ้นเสมอ) แล้วเติมให้เอง • สลับข้อให้แต่ละคน • สอบได้ครั้งเดียว'),
        if (_attempts > 0)
          _note(Icons.warning_amber_rounded, 'มีนักเรียนเริ่มทำแล้ว $_attempts คน — การแก้ข้อสอบมีผลกับครั้งที่เริ่มทำหลังจากนี้เท่านั้น', color: const Color(0xFFB45309)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: _reading ? null : _uploadFile,
            icon: _reading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file_rounded),
            label: Text(_reading
                ? (_readingMsg.isEmpty ? 'กำลังอ่านไฟล์... (ภาพสแกนใช้เวลาหน้าละหลายวินาที)' : '$_readingMsg (ปิดหน้านี้ไม่ได้ระหว่างอ่าน)')
                : 'อัปโหลดไฟล์ Word / PDF / รูปถ่าย'),
          ),
          OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste_rounded), label: const Text('วางข้อสอบจาก Word / Excel')),
          for (final t in _types.entries)
            OutlinedButton.icon(
              onPressed: () => setState(() => _questions.add(_QuestionDraft.blank(t.key))),
              icon: Icon(_typeIcon(t.key)),
              label: Text('เพิ่มข้อ${t.value}'),
            ),
          OutlinedButton.icon(onPressed: _showKey, icon: const Icon(Icons.fact_check_outlined), label: const Text('ดูเฉลยทั้งชุด')),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('ทั้งหมด ${_questions.length} ข้อ • ${_num(_questions.fold<double>(0, (a, q) => a + q.pointValue))} คะแนน',
                style: TextStyle(color: Colors.grey.shade700)),
          ),
        ]),
        const SizedBox(height: 10),
        for (var i = 0; i < _questions.length; i++) _questionCard(i),
      ];

  Future<DateTime?> _pickWhen(DateTime? initial, {required bool isEnd}) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: initial ?? (isEnd && _qStart != null ? _qStart! : now),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (d == null || !mounted) return null;
    final t = await showTimePicker(
      context: context,
      builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
      initialTime: initial != null ? TimeOfDay.fromDateTime(initial) : TimeOfDay(hour: isEnd ? 16 : 8, minute: isEnd ? 30 : 0),
    );
    if (t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  /// แบบทดสอบย่อย: which column of the scores page it fills, when students may sit it, how many tries
  List<Widget> _quizSettings({bool link = false}) {
    String full(int i) {
      final m = i < _unitMax.length ? _unitMax[i] : null;
      return m == null ? 'ยังไม่ตั้งคะแนนเต็ม' : 'เต็ม ${_num(m)}';
    }

    Widget when(String label, DateTime? v, IconData icon, bool isEnd) => InputChip(
          avatar: Icon(icon, size: 18),
          label: Text('$label: ${v == null ? (isEnd ? 'ไม่กำหนด (เปิดตลอด)' : 'ทันที') : thaiDateTime(v.toIso8601String())}'),
          onPressed: () async {
            final d = await _pickWhen(v, isEnd: isEnd);
            if (d != null) setState(() => isEnd ? _qEnd = d : _qStart = d);
          },
          onDeleted: v == null ? null : () => setState(() => isEnd ? _qEnd = null : _qStart = null),
        );

    return [
      if (!link) ...[
      const Text('เชื่อมคะแนนกับหน้าบันทึกคะแนน', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      DropdownButtonFormField<int>(
        initialValue: _slot ?? -1,
        isExpanded: true,
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'ช่องคะแนนตัวชี้วัด (ช่อง 1–8)'),
        items: [
          const DropdownMenuItem(value: -1, child: Text('ไม่เชื่อม (ฝึกทำ ไม่เข้าคะแนน)')),
          for (var i = 0; i < 8; i++)
            DropdownMenuItem(
              value: i,
              enabled: i < _unitMax.length && _unitMax[i] != null,
              child: Text('ช่อง ${i + 1} (${full(i)})',
                  style: TextStyle(color: i < _unitMax.length && _unitMax[i] != null ? null : Colors.grey)),
            ),
        ],
        onChanged: (v) => setState(() {
          final next = v == null || v < 0 ? null : v;
          if (next != _slot) _slotPoints.clear();
          _slot = next;
        }),
      ),
      if (_slot != null) ...[
        const SizedBox(height: 10),
        SlotPointsField(
          controller: _slotPoints,
          slotFull: _slot! < _unitMax.length ? (_unitMax[_slot!] as num?)?.toDouble() : null,
          rawPoints: _questions.fold<double>(0, (a, q) => a + q.pointValue),
          onChanged: () => setState(() {}),
        ),
      ],
      _note(Icons.functions_rounded,
          'ตั้ง "คิดเป็นกี่คะแนน" ได้ เช่น ช่องเต็ม 10 ข้อสอบ 10 ข้อ แต่ให้คิด 5 คะแนน • หลายชุดในช่องเดียวกัน = รวมคะแนนแต่ละชุด (ห้ามเกินคะแนนเต็มช่อง) '
          '• ชุดที่ไม่ได้ตั้งจะแบ่งคะแนนที่เหลือของช่องตามคะแนนดิบ • ทศนิยม 1 ตำแหน่ง ปัดขึ้นเสมอ • ช่องที่ยังไม่ตั้งคะแนนเต็ม ให้ตั้งที่หน้าบันทึกคะแนนก่อน'),
      const SizedBox(height: 12),
      ],
      const Text('เวลาที่นักเรียนทำได้', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        when('เปิด', _qStart, Icons.play_circle_outline, false),
        when('ปิด', _qEnd, Icons.stop_circle_outlined, true),
      ]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _classOnly,
        onChanged: (v) => setState(() => _classOnly = v),
        title: const Text('ทำได้เฉพาะในคาบเรียนวิชานี้'),
        subtitle: const Text('ตามตารางเรียนของนักเรียน • ต้องส่งก่อนหมดคาบ (คาบติดกันนับต่อเนื่อง) • ถ้าตั้งวันเปิด/ปิดด้วย ต้องอยู่ในช่วงนั้นด้วย'),
      ),
      if (!link) Row(children: [
        const Text('ทำได้', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        DropdownButton<int>(
          value: _maxAttempts,
          items: [
            for (final n in {1, 2, 3, 5, 10, _maxAttempts}.where((n) => n > 0).toList()..sort())
              DropdownMenuItem(value: n, child: Text('$n ครั้ง')),
            const DropdownMenuItem(value: 0, child: Text('ไม่จำกัด')),
          ],
          onChanged: (v) => setState(() => _maxAttempts = v ?? 1),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text('นับครั้งที่ได้คะแนนสูงสุด • ครูรีเซ็ตให้รายคนได้ที่ "ผล"', style: TextStyle(fontSize: 12, color: Colors.grey.shade700))),
      ]),
    ];
  }

  Widget _note(IconData icon, String text, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: color ?? Colors.grey.shade700),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color ?? Colors.grey.shade700))),
        ]),
      );

  static IconData _typeIcon(String t) => switch (t) {
        'number' => Icons.pin_outlined,
        'text' => Icons.short_text_rounded,
        'truefalse' => Icons.rule_rounded,
        'match' => Icons.compare_arrows_rounded,
        'cloze' => Icons.notes_rounded,
        'photo' => Icons.photo_camera_outlined,
        _ => Icons.radio_button_checked,
      };

  /// เฉลย for the whole paper, to check (and print with the browser) before the exam
  void _showKey() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isQuiz ? 'เฉลย ${_title.text.trim()} $_code' : 'เฉลยข้อสอบ${examTypes[widget.examType]} $_code'),
        content: SizedBox(
          width: 620,
          child: ListView(shrinkWrap: true, children: [
            for (var i = 0; i < _questions.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${i + 1}. ${_questions[i].q.text}  (${_num(_questions[i].pointValue)} คะแนน • ${questionTypes[_questions[i].type]})',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    switch (_questions[i].type) {
                      'choice' => _questions[i].answer == null
                          ? 'ยังไม่ได้เลือกคำตอบที่ถูก'
                          : 'ตอบ ${_questions[i].letterSet[_questions[i].answer!]}${_questions[i].asImage ? ' (ตามภาพ)' : '. ${_questions[i].choices[_questions[i].answer!].text}'}',
                      'number' => _questions[i].numAnswer.text.trim().isEmpty
                          ? 'ยังไม่ใส่เฉลย'
                          : 'ตอบ ${_questions[i].numAnswer.text.trim()} ${_questions[i].unit.text.trim()}'
                              '${_questions[i].tolerance.text.trim().isEmpty ? '' : ' (± ${_questions[i].tolerance.text.trim()})'}',
                      'text' => _questions[i].textAnswer.text.trim().isEmpty ? 'ยังไม่ใส่เฉลย' : 'ตอบ ${_questions[i].textAnswer.text.trim()}',
                      'truefalse' || 'match' || 'cloze' => setKeyText(_questions[i].type, _questions[i].kind),
                      _ => _questions[i].guide.text.trim().isEmpty ? 'แนวคำตอบ: (ไม่ได้ใส่)' : 'แนวคำตอบ: ${_questions[i].guide.text.trim()}',
                    },
                    style: TextStyle(color: _questions[i].hasKey ? const Color(0xFF15803D) : Colors.orange.shade800),
                  ),
                ]),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ปิด'))],
      ),
    );
  }

  Widget _questionCard(int i) {
    final q = _questions[i];
    InputDecoration dec(String label, {String? hint}) =>
        InputDecoration(isDense: true, labelText: label, hintText: hint, border: const OutlineInputBorder());
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: q.hasKey ? Colors.grey.shade300 : Colors.orange.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('ข้อ ${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
              DropdownButton<String>(
                value: q.type,
                isDense: true,
                items: [
                  for (final t in (_types.containsKey(q.type) ? _types : questionTypes).entries)
                    DropdownMenuItem(value: t.key, child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(_typeIcon(t.key), size: 16), const SizedBox(width: 6), Text(t.value)])),
                ],
                onChanged: (v) => setState(() {
                  q.type = v ?? 'choice';
                  q.kind.ensure(q.type);
                }),
              ),
              SizedBox(
                width: setTypes.contains(q.type) ? 120 : 90,
                child: TextField(
                  controller: q.points,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec(setTypes.contains(q.type) ? 'คะแนนต่อช่อง' : 'คะแนน'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (setTypes.contains(q.type))
                Text('${q.parts} ช่อง = ${_num(q.pointValue)} คะแนน', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              IconButton(
                tooltip: 'ลบข้อนี้',
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  setState(() => _questions.removeAt(i));
                  WidgetsBinding.instance.addPostFrameCallback((_) => q.dispose());
                },
              ),
            ]),
            const SizedBox(height: 6),
            if (q.asImage && q.image != null) ...[
              ExamImage(api: widget.apiService, name: q.image!, height: 520, wide: true),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
                Switch(value: true, onChanged: (v) => setState(() => q.asImage = v)),
                const Text('โจทย์จากภาพ (นักเรียนเห็นภาพนี้)', style: TextStyle(fontSize: 12, color: Color(0xFF6D28D9))),
                TextButton.icon(
                  onPressed: () async {
                    final n = await pickExamImage(context, widget.apiService);
                    if (n != null) setState(() => q.image = n);
                  },
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: const Text('เปลี่ยนรูป'),
                ),
              ]),
            ] else ...[
            TextField(
                controller: q.q,
                minLines: 1,
                maxLines: 6,
                decoration: dec(setTypes.contains(q.type) ? 'คำสั่ง (ว่างได้)' : 'โจทย์',
                    hint: switch (q.type) {
                      'truefalse' => 'เช่น เลือก ✓ หน้าข้อความที่ถูก และ ✗ หน้าข้อความที่ผิด',
                      'match' => 'เช่น Match the sentence with the picture.',
                      'cloze' => 'เช่น Read and fill in the blanks.',
                      'text' => 'เช่น The sun rises in the ________.',
                      _ => null,
                    })),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
              ImageSlot(
                  api: widget.apiService,
                  name: q.image,
                  label: 'ใส่รูปประกอบโจทย์',
                  height: q.asImage ? 160 : 90,
                  onChanged: (n) => setState(() {
                        q.image = n;
                        if (n == null) q.asImage = false;
                      })),
              if (q.image == null) Text('รูปประกอบโจทย์ (ถ้ามี)', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              if (q.image != null)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(value: q.asImage, onChanged: (v) => setState(() => q.asImage = v)),
                  Text(q.asImage ? 'นักเรียนเห็นข้อนี้เป็นภาพ (ซ่อนข้อความ ตัวเลือกแสดงแค่ ก ข ค ง)' : 'ใช้ภาพนี้เป็นโจทย์ (ไม่ต้องพิมพ์โจทย์/ตัวเลือก)',
                      style: TextStyle(fontSize: 12, color: q.asImage ? const Color(0xFF6D28D9) : Colors.grey.shade700)),
                ]),
            ]),
            ],
            if (setTypes.contains(q.type))
              KindEditor(key: ObjectKey(q), type: q.type, d: q.kind, api: widget.apiService, onChanged: () => setState(() {})),
            if (q.type == 'text')
              Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(
                  width: 320,
                  child: TextField(
                    controller: q.textAnswer,
                    decoration: dec('เฉลย (ตอบได้หลายแบบ คั่นด้วย / )', hint: 'เช่น east  หรือ  Bangkok / กรุงเทพ'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                SizedBox(width: 120, child: TextField(controller: q.unit, decoration: dec('หน่วย', hint: 'ถ้ามี'))),
                Text('ระบบไม่สนตัวพิมพ์เล็ก/ใหญ่ ช่องว่าง และจุด • ครูกดให้ถูกรายคนได้ในหน้า "ผลสอบ"',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              ]),
            const SizedBox(height: 6),
            if (q.type == 'choice' && q.asImage && q.image != null)
              Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                const Text('เฉลย:'),
                for (var j = 0; j < q.choices.length; j++)
                  ChoiceChip(
                    showCheckmark: false,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                    label: Text(q.letterSet[j], style: TextStyle(fontSize: 18, fontWeight: q.answer == j ? FontWeight.bold : FontWeight.normal)),
                    selected: q.answer == j,
                    selectedColor: const Color(0xFFDCFCE7),
                    onSelected: (_) => setState(() => q.answer = j),
                  ),
                if (q.choices.length > 2)
                  IconButton(
                    tooltip: 'ลดตัวเลือก (เอา ${q.letterSet[q.choices.length - 1]} ออก)',
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                    onPressed: () {
                      final gone = q.choices.removeLast();
                      setState(() {
                        if (q.answer != null && q.answer! >= q.choices.length) q.answer = null;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
                    },
                  ),
                if (q.choices.length < choiceLetters.length)
                  IconButton(
                    tooltip: 'เพิ่มตัวเลือก ${q.letterSet[q.choices.length]}',
                    icon: const Icon(Icons.add_circle_outline, size: 20),
                    onPressed: () => setState(() => q.choices.add(TextEditingController(text: q.letterSet[q.choices.length]))),
                  ),
                Text(q.answer == null ? 'กดตัวอักษรที่เป็นคำตอบที่ถูก (ตามภาพ)' : 'เฉลย ${q.letterSet[q.answer!]}',
                    style: TextStyle(fontSize: 12, color: q.answer == null ? Colors.orange.shade800 : const Color(0xFF15803D))),
              ])
            else if (q.type == 'choice') ...[
              for (var j = 0; j < q.choices.length; j++)
                Row(children: [
                  IconButton(
                    tooltip: 'เลือกเป็นคำตอบที่ถูก',
                    icon: Icon(q.answer == j ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: q.answer == j ? const Color(0xFF15803D) : Colors.grey),
                    onPressed: () => setState(() => q.answer = j),
                  ),
                  Text('${choiceLetters[j]}.'),
                  const SizedBox(width: 6),
                  Expanded(child: TextField(controller: q.choices[j], decoration: const InputDecoration(isDense: true, hintText: 'ตัวเลือก'))),
                  if (q.choices.length > 2)
                    IconButton(
                      tooltip: 'ลบตัวเลือก',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        final gone = q.choices[j];
                        setState(() {
                          q.choices.removeAt(j);
                          if (q.answer == j) {
                            q.answer = null;
                          } else if (q.answer != null && q.answer! > j) {
                            q.answer = q.answer! - 1;
                          }
                        });
                        WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
                      },
                    ),
                ]),
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (q.choices.length < choiceLetters.length)
                  TextButton.icon(
                    onPressed: () => setState(() => q.choices.add(TextEditingController())),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('ตัวเลือก'),
                  ),
                Text(q.answer == null ? 'กดวงกลมหน้าคำตอบที่ถูก' : 'เฉลย ${choiceLetters[q.answer!]}',
                    style: TextStyle(fontSize: 12, color: q.answer == null ? Colors.orange.shade800 : const Color(0xFF15803D))),
              ]),
            ],
            if (q.type == 'number')
              Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: q.numAnswer,
                    decoration: dec('เฉลย (ตัวเลข)', hint: 'เช่น 45, -3.5, 3/4'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                SizedBox(width: 180, child: TextField(controller: q.tolerance, decoration: dec('คลาดเคลื่อนได้ ±', hint: 'ว่าง = ต้องตรง'))),
                SizedBox(width: 120, child: TextField(controller: q.unit, decoration: dec('หน่วย', hint: 'เช่น ซม.'))),
                Text('ระบบตรวจเอง: 0.75 = 3/4, 1,200 = 1200, เลขไทยได้',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              ]),
            if (q.type == 'photo') ...[
              TextField(
                controller: q.guide,
                minLines: 2,
                maxLines: 6,
                decoration: dec('เฉลย / แนวคำตอบ / เกณฑ์ให้คะแนน (นักเรียนไม่เห็น)', hint: 'เช่น สูตร 2 คะแนน แทนค่า 2 คะแนน คำตอบ 1 คะแนน'),
              ),
              const SizedBox(height: 4),
              Text('นักเรียนเขียนตอบในกระดาษแล้วกดถ่ายภาพส่ง (ได้ถึง 5 รูป) • ครูดูรูปคู่กับเฉลยแล้วให้คะแนนในหน้า "ผลสอบ"',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            ],
            const SizedBox(height: 6),
            if (q.showExplain || q.explain.text.trim().isNotEmpty)
              TextField(
                controller: q.explain,
                minLines: 1,
                maxLines: 8,
                decoration: dec('วิธีทำ / คำอธิบายเฉลย (ครูเห็นเท่านั้น นักเรียนไม่เห็น)',
                    hint: 'เช่น พื้นที่ = กว้าง × ยาว = 3 × 4 = 12'),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.calculate_outlined, size: 18),
                  label: const Text('เพิ่มวิธีทำ / คำอธิบายเฉลย'),
                  onPressed: () => setState(() => q.showExplain = true),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Who has sat the paper, their marks, and a retake button.
class ExamResultsDialog extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> course;
  final String examType;
  final String term;
  final String year;
  const ExamResultsDialog({super.key, required this.apiService, required this.course, required this.examType, required this.term, required this.year});

  static Future<void> show(BuildContext context, ApiService api, Map<String, dynamic> course, String et, String term, String year) {
    return showDialog(context: context, builder: (_) => ExamResultsDialog(apiService: api, course: course, examType: et, term: term, year: year));
  }

  @override
  State<ExamResultsDialog> createState() => _ExamResultsDialogState();
}

class _ExamResultsDialogState extends State<ExamResultsDialog> {
  late Future<Map<String, dynamic>> _future;
  String get _code => '${widget.course['course_code']}';

  @override
  void initState() {
    super.initState();
    _future = widget.apiService.getExamResults(_code, widget.term, widget.year, widget.examType);
  }

  Future<void> _reset(Map st) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ให้สอบใหม่?'),
        content: Text('${st['full_name']} จะทำข้อสอบได้อีกครั้ง (ในช่วงเวลาสอบ) คะแนนใหม่จะแทนคะแนนเดิมเมื่อส่ง'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ให้สอบใหม่')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.apiService.resetExamAttempt(_code, widget.term, widget.year, widget.examType, '${st['student_id']}');
      setState(() => _future = widget.apiService.getExamResults(_code, widget.term, widget.year, widget.examType));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.gold, width: 1.5)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 820, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text(snap.error.toString().replaceFirst('Exception: ', '')));
            final rows = (snap.data!['students'] as List).cast<Map>();
            final done = rows.where((r) => r['status'] == 'ส่งแล้ว').length;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
                  decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                  child: Row(children: [
                    Expanded(
                      child: Text('ผลสอบ${examTypes[widget.examType]} • $_code • ส่งแล้ว $done/${rows.length} คน',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: Text('คะแนนเข้าช่อง${examTypes[widget.examType]}ในหน้าบันทึกคะแนนแล้ว แก้ไขต่อที่หน้านั้นได้ • * = ยังรอครูตรวจข้อเขียน (คะแนนจะปรับเองเมื่อตรวจ)',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowHeight: 38,
                        dataRowMinHeight: 34,
                        dataRowMaxHeight: 44,
                        columnSpacing: 16,
                        columns: const [
                          DataColumn(label: Text('ห้อง')),
                          DataColumn(label: Text('เลขที่')),
                          DataColumn(label: Text('ชื่อ')),
                          DataColumn(label: Text('สถานะ')),
                          DataColumn(label: Text('ได้ / เต็ม (แต้ม)')),
                          DataColumn(label: Text('คะแนนช่อง')),
                          DataColumn(label: Text('')),
                        ],
                        rows: rows.map((r) {
                          final st = '${r['status']}';
                          final color = switch (st) {
                            'ส่งแล้ว' => const Color(0xFF15803D),
                            'รอครูตรวจ' => const Color(0xFF1D4ED8),
                            'กำลังทำ' => const Color(0xFFB45309),
                            _ => Colors.grey.shade600,
                          };
                          return DataRow(cells: [
                            DataCell(Text('${r['class_level']}/${r['room']}')),
                            DataCell(Text('${r['student_no'] ?? ''}')),
                            DataCell(Text('${r['full_name']}')),
                            DataCell(Text(st, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
                            DataCell(Text(r['earned'] == null
                                ? (r['correct'] == null ? '-' : '${r['correct']}/${r['total']}')
                                : '${_num(r['earned'])}/${_num(r['max_points'])}')),
                            DataCell(Text(r['score'] == null ? '-' : '${_num(r['score'])}/${_num(r['score_max'])}${(r['pending'] ?? 0) > 0 ? ' *' : ''}')),
                            DataCell(st == 'ยังไม่สอบ'
                                ? const SizedBox()
                                : Row(mainAxisSize: MainAxisSize.min, children: [
                                    if (st == 'ส่งแล้ว' || st == 'รอครูตรวจ')
                                      TextButton(
                                        onPressed: () async {
                                          await AttemptReviewDialog.show(context, widget.apiService, _code, widget.term, widget.year,
                                              widget.examType, '${r['student_id']}');
                                          if (mounted) {
                                            setState(() => _future = widget.apiService.getExamResults(_code, widget.term, widget.year, widget.examType));
                                          }
                                        },
                                        child: Text(st == 'รอครูตรวจ' ? 'ตรวจข้อเขียน' : 'ดูคำตอบ'),
                                      ),
                                    TextButton(onPressed: () => _reset(r), child: const Text('ให้สอบใหม่')),
                                  ])),
                          ]);
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}


/// One student's answers next to the เฉลย; the teacher marks the photo (written) answers here.
class AttemptReviewDialog extends StatefulWidget {
  final ApiService apiService;
  final String courseCode;
  final String term;
  final String year;
  final String examType;
  final String studentId;
  const AttemptReviewDialog({
    super.key,
    required this.apiService,
    required this.courseCode,
    required this.term,
    required this.year,
    required this.examType,
    required this.studentId,
  });

  static Future<void> show(BuildContext context, ApiService api, String code, String term, String year, String et, String sid) =>
      showDialog(
        context: context,
        builder: (_) => AttemptReviewDialog(apiService: api, courseCode: code, term: term, year: year, examType: et, studentId: sid),
      );

  @override
  State<AttemptReviewDialog> createState() => _AttemptReviewDialogState();
}

class _AttemptReviewDialogState extends State<AttemptReviewDialog> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _saving = false;
  final Map<String, TextEditingController> _marks = {};
  final Map<String, bool?> _over = {}; // "ข้อ:ช่อง" -> ให้ถูก / ให้ผิด / null = ระบบตรวจ (only what the teacher changed here)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _marks.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.apiService.getExamAttempt(widget.courseCode, widget.term, widget.year, widget.examType, widget.studentId);
      if (!mounted) return;
      for (final it in (d['items'] as List).cast<Map>()) {
        if (it['type'] == 'photo') {
          _marks.putIfAbsent('${it['index']}', () => TextEditingController(text: it['mark'] == null ? '' : _num(it['mark'])));
        }
      }
      setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.apiService.markExamPhotos(widget.courseCode, widget.term, widget.year, widget.examType, widget.studentId,
          {for (final e in _marks.entries) e.key: e.value.text.trim(), for (final e in _over.entries) e.key: e.value});
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Colors.red.shade700));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final st = (d?['student'] as Map?) ?? {};
    final res = (d?['result'] as Map?) ?? {};
    return Dialog(
      insetPadding: const EdgeInsets.all(10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.gold, width: 1.5)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 900, maxHeight: MediaQuery.of(context).size.height * 0.94),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
            decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
            child: Row(children: [
              Expanded(
                child: Text(
                  d == null
                      ? 'คำตอบของนักเรียน'
                      : '${st['full_name'] ?? widget.studentId} • ${widget.courseCode} ${examTypes[widget.examType]} • '
                          'ได้ ${_num(res['earned'])}/${_num(res['max_points'])} แต้ม = ${_num(res['score'])}/${_num(res['score_max'])} คะแนน',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(20), child: Text(_error!))
          else if (d == null)
            const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()))
          else
            Flexible(
              child: ListView(padding: const EdgeInsets.all(14), shrinkWrap: true, children: [
                for (final it in (d['items'] as List).cast<Map>()) _item(it),
              ]),
            ),
          if (_marks.isNotEmpty || _over.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                Expanded(
                    child: Text(
                        _over.isNotEmpty
                            ? 'แก้ผลตรวจ ${_over.length} ช่อง — กดบันทึก คะแนนในหน้าบันทึกคะแนนจะปรับให้เอง'
                            : 'ให้คะแนนข้อเขียนแล้วกดบันทึก คะแนนในหน้าบันทึกคะแนนจะปรับให้เอง',
                        style: const TextStyle(fontSize: 12))),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded),
                  label: const Text('บันทึกคะแนน'),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _item(Map it) {
    final type = '${it['type']}';
    final ok = it['correct'] == true;
    Widget verdict(bool good) => Icon(good ? Icons.check_circle_rounded : Icons.cancel_rounded, color: good ? const Color(0xFF15803D) : Colors.red.shade700, size: 20);
    final body = <Widget>[];
    if (it['image'] != null) {
      body.add(Padding(padding: const EdgeInsets.only(bottom: 6), child: ExamImage(api: widget.apiService, name: '${it['image']}', height: 110)));
    }
    if (type != 'photo' && it['parts'] != null) {
      body.add(PartsReview(
        api: widget.apiService,
        it: it,
        overrides: _over,
        onOverride: (k, v) => setState(() {
          final parts = (it['parts'] as List).cast<Map>();
          final saved = parts[int.parse(k.split(':')[1])]['override'] as bool?;
          if (v == saved) {
            _over.remove(k);
          } else {
            _over[k] = v;
          }
        }),
      ));
    } else if (type == 'choice' || type == 'number') {
      body.add(Row(children: [verdict(ok), const SizedBox(width: 6), Expanded(child: Text('ตอบ: ${it['given'] ?? '(ไม่ได้ตอบ)'}'))]));
    } else {
      final photos = (it['photos'] as List? ?? []).map((e) => '$e').toList();
      if ('${it['guide'] ?? ''}'.isNotEmpty) {
        body.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF86EFAC))),
          child: Text('เฉลย / แนวคำตอบ: ${it['guide']}', style: const TextStyle(fontSize: 13)),
        ));
      }
      body.add(photos.isEmpty
          ? Text('ไม่ได้ส่งรูป (ได้ 0 คะแนน)', style: TextStyle(color: Colors.red.shade700))
          : Wrap(spacing: 8, runSpacing: 8, children: [
              for (final n in photos)
                InkWell(
                  onTap: () => _zoom(n),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      widget.apiService.teacherExamPhotoUrl(widget.courseCode, widget.term, widget.year, widget.examType, widget.studentId, n),
                      height: 180,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const SizedBox(width: 120, height: 120, child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
                ),
            ]));
      body.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          const Text('ให้คะแนน: '),
          SizedBox(
            width: 90,
            child: TextField(
              controller: _marks['${it['index']}'],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'ยังไม่ตรวจ'),
            ),
          ),
          Text('  จาก ${_num(it['points'])}'),
        ]),
      ));
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ข้อ ${(it['index'] as num).toInt() + 1} • ${questionTypes[type]} • ${_num(it['points'])} คะแนน${setTypes.contains(type) ? 'ต่อช่อง' : ''}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          const SizedBox(height: 2),
          Text('${it['q']}', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...body,
        ]),
      ),
    );
  }

  void _zoom(String name) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(8),
        child: Stack(children: [
          InteractiveViewer(
            maxScale: 5,
            child: Image.network(widget.apiService.teacherExamPhotoUrl(widget.courseCode, widget.term, widget.year, widget.examType, widget.studentId, name)),
          ),
          Positioned(right: 4, top: 4, child: IconButton.filledTonal(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx))),
        ]),
      ),
    );
  }
}
