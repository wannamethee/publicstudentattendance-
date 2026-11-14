import 'package:flutter/material.dart';

import '../screens/exams_screen.dart' show ExamEditorDialog, thaiDateTime;
import '../services/api_service.dart';
import '../utils/app_theme.dart';

String _num(dynamic v) {
  if (v == null) return '-';
  final d = (v as num).toDouble();
  return d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(d * 10 == (d * 10).roundToDouble() ? 1 : 2);
}

String quizSlotText(dynamic slot) => slot == null ? 'ไม่เชื่อมคะแนน' : 'เข้าช่อง ${(slot as num).toInt() + 1}';

/// When students may sit it, in one line
String quizWhenText(Map q) {
  final parts = <String>[];
  if (q['start_at'] != null) parts.add('เปิด ${thaiDateTime(q['start_at'])}');
  if (q['end_at'] != null) parts.add('ปิด ${thaiDateTime(q['end_at'])}');
  if (parts.isEmpty) parts.add('เปิดตลอด');
  if (q['class_only'] == true) parts.add('เฉพาะในคาบเรียน');
  final n = (q['max_attempts'] as num?)?.toInt() ?? 1;
  parts.add(n == 0 ? 'ทำได้ไม่จำกัด' : 'ทำได้ $n ครั้ง');
  if (q['duration_min'] != null) parts.add('${q['duration_min']} นาที');
  return parts.join(' • ');
}

Widget quizStateChip(Map q) {
  late final String text;
  late final Color color;
  if (q['ready'] != true) {
    text = 'ร่าง';
    color = Colors.grey;
  } else if (q['has_ended'] == true) {
    text = 'ปิดแล้ว';
    color = const Color(0xFFB91C1C);
  } else if (q['not_yet'] == true) {
    text = 'ยังไม่ถึงเวลา';
    color = const Color(0xFFB45309);
  } else {
    text = q['class_only'] == true ? 'เปิด (ในคาบ)' : 'เปิดอยู่';
    color = const Color(0xFF15803D);
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

Widget _header(BuildContext context, String title, String? sub) => Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
      decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (sub != null) Text(sub, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800)),
          ]),
        ),
        IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context, true)),
      ]),
    );

ShapeBorder get _shape => RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.gold, width: 1.5));

/// ครู: every แบบทดสอบย่อย of one course: make, edit, see results.
class QuizManagerDialog extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> course; // course_code, course_name, class_level
  final String term;
  final String year;
  const QuizManagerDialog({super.key, required this.apiService, required this.course, required this.term, required this.year});

  static Future<bool?> show(BuildContext context, ApiService api, Map<String, dynamic> course, String term, String year) =>
      showDialog<bool>(context: context, builder: (_) => QuizManagerDialog(apiService: api, course: course, term: term, year: year));

  @override
  State<QuizManagerDialog> createState() => _QuizManagerDialogState();
}

class _QuizManagerDialogState extends State<QuizManagerDialog> {
  Map<String, dynamic>? _d;
  String? _error;

  String get _code => '${widget.course['course_code']}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.apiService.listQuizzes(_code, widget.term, widget.year);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _edit([int? id]) async {
    final saved = await ExamEditorDialog.showQuiz(context, widget.apiService, widget.course, widget.term, widget.year, quizId: id);
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = ((_d?['quizzes'] as List?) ?? []).cast<Map>();
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: _shape,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 820, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context, 'แบบทดสอบย่อย / หลังเรียน • $_code ${widget.course['course_name'] ?? ''}',
              'นักเรียนที่ลงทะเบียนวิชานี้เห็นปุ่มแบบทดสอบในหน้านักเรียน (และในตารางเรียน) • ระบบตรวจและเติมคะแนนเข้าช่องที่เชื่อมไว้ให้เอง'),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
          else if (_d == null)
            const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
          else
            Flexible(
              child: ListView(padding: const EdgeInsets.all(14), shrinkWrap: true, children: [
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text('ยังไม่มีแบบทดสอบย่อย — กด "สร้างแบบทดสอบย่อย"', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
                  ),
                for (final q in list) _tile(q),
              ]),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('ปิด')),
              FilledButton.icon(onPressed: _d == null ? null : () => _edit(), icon: const Icon(Icons.add_rounded), label: const Text('สร้างแบบทดสอบย่อย')),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _tile(Map q) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade300)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${q['title']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
            quizStateChip(q),
          ]),
          const SizedBox(height: 2),
          Text(
              q['mode'] == 'link'
                  ? 'ลิงก์ภายนอก • ${q['link_url']} • ครูกรอกคะแนนเองในหน้าบันทึกคะแนน'
                  : '${q['question_count']} ข้อ ${_num(q['points'])} คะแนน • ${quizSlotText(q['unit_slot'])} • ส่งแล้ว ${q['submitted_count']}/${q['student_count']} คน',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800)),
          Text(quizWhenText(q), style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(spacing: 4, children: [
              if (q['mode'] != 'link') TextButton.icon(
                onPressed: () => QuizResultsDialog.show(context, widget.apiService, q).then((_) => _load()),
                icon: const Icon(Icons.leaderboard_outlined, size: 18),
                label: const Text('ผล'),
              ),
              TextButton.icon(onPressed: () => _edit((q['id'] as num).toInt()), icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('แก้ไข')),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Who has sent one quiz, their tries and best points; reset a student's tries.
class QuizResultsDialog extends StatefulWidget {
  final ApiService apiService;
  final Map quiz;
  const QuizResultsDialog({super.key, required this.apiService, required this.quiz});

  static Future<void> show(BuildContext context, ApiService api, Map quiz) =>
      showDialog(context: context, builder: (_) => QuizResultsDialog(apiService: api, quiz: quiz));

  @override
  State<QuizResultsDialog> createState() => _QuizResultsDialogState();
}

class _QuizResultsDialogState extends State<QuizResultsDialog> {
  Map<String, dynamic>? _d;
  String? _error;

  int get _id => (widget.quiz['id'] as num).toInt();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.apiService.getQuizResults(_id);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _reset(Map st) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('ล้างผลของ ${st['full_name']}?'),
        content: const Text('ลบทุกครั้งที่ทำแบบทดสอบนี้ นักเรียนทำใหม่ได้ตามจำนวนครั้งที่ตั้งไว้ • คะแนนในช่องที่เชื่อมคำนวณใหม่ทันที'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ล้างผล')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.apiService.resetQuizAttempts(_id, '${st['student_id']}');
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = ((_d?['students'] as List?) ?? []).cast<Map>();
    final done = rows.where((r) => r['best'] != null).toList();
    final avg = done.isEmpty ? null : done.fold<double>(0, (a, r) => a + (r['best'] as num).toDouble()) / done.length;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: _shape,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 860, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context, 'ผล: ${widget.quiz['title']}',
              _d == null ? null : 'ส่งแล้ว ${done.length}/${rows.length} คน${avg == null ? '' : ' • เฉลี่ย ${_num(avg)}/${_num(widget.quiz['points'])} คะแนน'} • ${quizSlotText(widget.quiz['unit_slot'])}'),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
          else if (_d == null)
            const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
          else
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowHeight: 38,
                    dataRowMinHeight: 36,
                    dataRowMaxHeight: 44,
                    columnSpacing: 18,
                    columns: const [
                      DataColumn(label: Text('เลขที่')),
                      DataColumn(label: Text('รหัส')),
                      DataColumn(label: Text('ชื่อ - สกุล')),
                      DataColumn(label: Text('สถานะ')),
                      DataColumn(label: Text('ครั้ง'), numeric: true),
                      DataColumn(label: Text('ดีที่สุด'), numeric: true),
                      DataColumn(label: Text('ทุกครั้ง')),
                      DataColumn(label: Text('')),
                    ],
                    rows: [
                      for (final r in rows)
                        DataRow(cells: [
                          DataCell(Text('${r['student_no'] ?? ''}')),
                          DataCell(Text('${r['student_id']}')),
                          DataCell(Text('${r['full_name'] ?? ''}')),
                          DataCell(Text('${r['status']}',
                              style: TextStyle(
                                  color: r['status'] == 'ส่งแล้ว'
                                      ? const Color(0xFF15803D)
                                      : (r['status'] == 'กำลังทำ' ? const Color(0xFFB45309) : Colors.grey.shade600)))),
                          DataCell(Text('${r['tries']}')),
                          DataCell(Text(r['best'] == null ? '-' : '${_num(r['best'])}/${_num(r['max_points'])}',
                              style: const TextStyle(fontWeight: FontWeight.bold))),
                          DataCell(Text(((r['history'] as List?) ?? []).map(_num).join(', '))),
                          DataCell(r['status'] == 'ยังไม่ทำ'
                              ? const SizedBox()
                              : TextButton(onPressed: () => _reset(r), child: const Text('ล้างผล / ให้ทำใหม่'))),
                        ]),
                    ],
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// หน้าบันทึกคะแนน: pick which column (ช่อง 1-8) each quiz of the course fills; the column is added up automatically.
class QuizLinksDialog extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> course;
  final String term;
  final String year;
  const QuizLinksDialog({super.key, required this.apiService, required this.course, required this.term, required this.year});

  /// true when the links changed (the scores page reloads)
  static Future<bool?> show(BuildContext context, ApiService api, Map<String, dynamic> course, String term, String year) =>
      showDialog<bool>(context: context, builder: (_) => QuizLinksDialog(apiService: api, course: course, term: term, year: year));

  @override
  State<QuizLinksDialog> createState() => _QuizLinksDialogState();
}

class _QuizLinksDialogState extends State<QuizLinksDialog> {
  Map<String, dynamic>? _d;
  String? _error;
  final Map<String, int?> _links = {};
  bool _saving = false;
  bool _changed = false;

  String get _code => '${widget.course['course_code']}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.apiService.listQuizzes(_code, widget.term, widget.year);
      if (!mounted) return;
      setState(() {
        _d = d;
        _links.clear();
        for (final q in (d['quizzes'] as List).cast<Map>()) {
          if (q['mode'] == 'link') continue;   // an outside form: the teacher types its score
          _links['${q['id']}'] = (q['unit_slot'] as num?)?.toInt();
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  List<dynamic> get _unitMax => (_d?['unit_max'] as List?) ?? List.filled(8, null);

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.apiService.saveQuizLinks(_code, widget.term, widget.year, _links);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Colors.red.shade700));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ((_d?['quizzes'] as List?) ?? []).cast<Map>();
    // ช่อง -> ชุดที่เชื่อม (ตามที่เลือกอยู่ในหน้านี้)
    final bySlot = <int, List<Map>>{};
    for (final q in list) {
      final s = _links['${q['id']}'];
      if (s != null && q['ready'] == true) bySlot.putIfAbsent(s, () => []).add(q);
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: _shape,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 820, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
            decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
            child: Row(children: [
              Expanded(
                child: Text('คะแนนแบบทดสอบย่อย • $_code ${widget.course['course_name'] ?? ''}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context, _changed)),
            ]),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
          else if (_d == null)
            const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
          else
            Flexible(
              child: ListView(padding: const EdgeInsets.all(14), shrinkWrap: true, children: [
                Text(
                  'เลือกว่าแบบทดสอบแต่ละชุดเติมคะแนนลงช่องไหน (ช่อง 1–8) • หลายชุดลงช่องเดียวกันได้: รวมคะแนนดิบ (ครั้งที่ดีที่สุด, ยังไม่ทำ = 0) แล้วเทียบคะแนนเต็มของช่อง • ช่องที่เชื่อมแล้วระบบคิดให้เอง (แก้มือในตารางไม่ได้)',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800),
                ),
                const SizedBox(height: 10),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text('วิชานี้ยังไม่มีแบบทดสอบย่อย — กด "สร้าง / แก้ไขแบบทดสอบ"', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
                  ),
                for (final q in list) _row(q),
                if (bySlot.isNotEmpty) ...[
                  const Divider(height: 22),
                  const Text('สรุปการรวมคะแนน', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  for (final e in (bySlot.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        'ช่อง ${e.key + 1}: ${e.value.map((q) => '${q['title']} (${_num(q['points'])})').join(' + ')}'
                        ' = ${_num(e.value.fold<double>(0, (a, q) => a + (q['points'] as num).toDouble()))} คะแนน'
                        ' → เทียบเต็ม ${_num(_unitMax[e.key])}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
                if (list.any((q) => q['ready'] != true && _links['${q['id']}'] != null))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('ชุดที่ยังเป็นร่าง (ยังไม่เปิดให้นักเรียนเห็น) ยังไม่นับในช่อง', style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
                  ),
              ]),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: _d == null
                    ? null
                    : () async {
                        await QuizManagerDialog.show(context, widget.apiService, widget.course, widget.term, widget.year);
                        _changed = true;
                        _load();
                      },
                icon: const Icon(Icons.assignment_outlined),
                label: const Text('สร้าง / แก้ไขแบบทดสอบ'),
              ),
              TextButton(onPressed: () => Navigator.pop(context, _changed), child: const Text('ยกเลิก')),
              FilledButton.icon(
                onPressed: _d == null || _saving || _links.isEmpty ? null : _save,
                icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link_rounded),
                label: const Text('บันทึกและรวมคะแนน'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _row(Map q) {
    final id = '${q['id']}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade300)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 240, maxWidth: 380),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text('${q['title']}', style: const TextStyle(fontWeight: FontWeight.bold))),
                const SizedBox(width: 6),
                quizStateChip(q),
              ]),
              Text('${q['question_count']} ข้อ ${_num(q['points'])} คะแนน • ส่งแล้ว ${q['submitted_count']}/${q['student_count']} คน',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            ]),
          ),
          if (q['mode'] == 'link')
            Text('ลิงก์ภายนอก — กรอกคะแนนเองในตาราง', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700))
          else
          SizedBox(
            width: 230,
            child: DropdownButtonFormField<int>(
              key: ValueKey('slot-$id-${identityHashCode(_d)}'),
              initialValue: _links[id] ?? -1,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), labelText: 'เติมคะแนนลง'),
              items: [
                const DropdownMenuItem(value: -1, child: Text('ไม่เชื่อม')),
                for (var i = 0; i < 8; i++)
                  DropdownMenuItem(
                    value: i,
                    enabled: _unitMax.length > i && _unitMax[i] != null,
                    child: Text('ช่อง ${i + 1} ${_unitMax.length > i && _unitMax[i] != null ? '(เต็ม ${_num(_unitMax[i])})' : '(ยังไม่ตั้งคะแนนเต็ม)'}',
                        style: TextStyle(color: _unitMax.length > i && _unitMax[i] != null ? null : Colors.grey)),
                  ),
              ],
              onChanged: (v) => setState(() => _links[id] = v == null || v < 0 ? null : v),
            ),
          ),
        ]),
      ),
    );
  }
}
