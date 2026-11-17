// ตัวช่วย AI ออกข้อสอบ: the teacher picks the job (แบบทดสอบย่อย / กลางภาค / ปลายภาค) and one of their courses, ticks the
// chapters (เรื่อง) of the course's subject and grade from the topic library (lesson_topics.py, imported from Academic
// Hub: the AI also gets every chapter of that grade as context), attaches or types the lesson, chooses question kinds
// and counts, and gets a draft with the key and a worked solution for each question. Nothing is saved until they send the questions they kept:
// a quiz is made as a draft (not shown to students) tied to a column of the scores page with "คิดเป็นกี่คะแนน";
// midterm / final questions go after the questions already in that paper. The editor opens next for the final check.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../utils/app_theme.dart';
import '../widgets/slot_points.dart';
import 'exams_screen.dart' show ExamEditorDialog;

const _targets = {'quiz': 'แบบทดสอบย่อย', 'midterm': 'ข้อสอบกลางภาค', 'final': 'ข้อสอบปลายภาค'};
const _thaiLetters = ['ก', 'ข', 'ค', 'ง', 'จ'];

class AiAssistantScreen extends StatefulWidget {
  final ApiService apiService;
  const AiAssistantScreen({super.key, required this.apiService});

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  Map<String, dynamic>? _status;
  String? _loadError;
  String _target = 'quiz';
  List<Map<String, dynamic>> _courses = [];
  String _term = '';
  String _year = '';
  Map<String, dynamic>? _course;
  List<String> _labels = List.filled(8, '');
  // เรื่อง from the topic library
  String? _subject;
  String? _grade;
  List<Map<String, dynamic>> _chapters = [];
  Set<String> _suggested = {};
  final Set<String> _openGroups = {};
  final Map<int, Set<int>> _pickedCh = {}; // chapter index -> its picked sub-topics
  bool _topicsLoading = false;
  final _extraTopics = TextEditingController();
  List<String> _topicLabels = []; // the draft's "topic" numbers -> chapter names
  final _content = TextEditingController();
  final _instructions = TextEditingController();
  final List<MapEntry<String, List<int>>> _files = [];
  final Map<String, int> _counts = {'choice': 10};
  String _difficulty = 'mixed';
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _questions = [];
  final Set<int> _keep = {};
  List<String> _notes = [];
  String _modelNote = '';
  // sending
  final _title = TextEditingController();
  int? _slot;
  final _slotPoints = TextEditingController();
  List<dynamic> _unitMax = List.filled(8, null);
  bool _sending = false;

  ApiService get _api => widget.apiService;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_extraTopics, _content, _instructions, _title, _slotPoints]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final st = await _api.getAiStatus();
      final c = await _api.getExamCourses();
      if (!mounted) return;
      setState(() {
        _status = st;
        _term = '${c['term']}';
        _year = '${c['year']}';
        _courses = (c['data'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loadError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _pickCourse(Map<String, dynamic>? c) async {
    setState(() {
      _course = c;
      _labels = List.filled(8, '');
      _subject = null;
      _grade = null;
      _chapters = [];
      _suggested = {};
      _openGroups.clear();
      _pickedCh.clear();
      _slot = null;
      _slotPoints.clear();
      _unitMax = List.filled(8, null);
    });
    if (c == null) return;
    final code = '${c['course_code']}';
    _title.text = 'แบบทดสอบย่อย ${c['course_name'] ?? code}';
    _loadTopics(c);
    try {
      final l = await _api.getPp5Labels(courseCode: code, term: _term, year: _year);
      final q = await _api.listQuizzes(code, _term, _year);
      if (!mounted || _course != c) return;
      final ind = ((l['labels'] as Map?)?['indicators'] as List? ?? []).map((e) => '${e ?? ''}'.trim()).toList();
      setState(() {
        _labels = [...ind, ...List.filled(8, '')].take(8).toList();
        _unitMax = (q['unit_max'] as List? ?? List.filled(8, null));
      });
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  List<Map<String, dynamic>> get _libSubjects => ((_status?['topic_library'] as Map?)?['subjects'] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  List<String> _gradesOf(String? sid) =>
      (_libSubjects.firstWhere((s) => s['id'] == sid, orElse: () => <String, dynamic>{})['grades'] as List? ?? []).map((e) => '$e').toList();

  List<String> get _groups {
    final out = <String>[];
    for (final c in _chapters) {
      final g = '${c['group'] ?? ''}';
      if (!out.contains(g)) out.add(g);
    }
    return out;
  }

  /// Chapters of [subject] / [grade]; with neither, the server guesses them from the course.
  Future<void> _loadTopics(Map<String, dynamic> c, {String? subject, String? grade}) async {
    if (_libSubjects.isEmpty) return;
    setState(() => _topicsLoading = true);
    try {
      final d = await _api.getAiTopics(courseCode: '${c['course_code']}', term: _term, year: _year, subject: subject, grade: grade);
      if (!mounted || _course != c) return;
      setState(() {
        _subject = '${d['subject'] ?? ''}'.isEmpty ? null : '${d['subject']}';
        _grade = '${d['grade'] ?? ''}'.isEmpty ? null : '${d['grade']}';
        _chapters = (d['chapters'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _suggested = (d['suggested_groups'] as List? ?? []).map((e) => '$e').toSet();
        _pickedCh.clear();
        _openGroups
          ..clear()
          ..addAll(_suggested.isEmpty ? _groups : _suggested);
      });
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _topicsLoading = false);
    }
  }

  void _changeSubject(String? sid) {
    if (sid == null || _course == null) return;
    final grades = _gradesOf(sid);
    final level = '${_course!['class_level'] ?? ''}';
    _loadTopics(_course!, subject: sid, grade: grades.contains(level) ? level : (grades.isEmpty ? '' : grades.first));
  }

  Set<int> _allSubTopics(int i) => {for (var k = 0; k < ((_chapters[i]['topics'] as List?)?.length ?? 0); k++) k};

  Future<void> _addFiles() async {
    final res = await FilePicker.pickFiles(
      dialogTitle: 'เลือกไฟล์เนื้อหาบทเรียน',
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx', 'doc', 'txt', 'jpg', 'jpeg', 'png'],
    );
    for (final f in res) {
      if (_files.length >= 5) break;
      final bytes = await f.readAsBytes();
      if (bytes.length > 15 * 1024 * 1024) {
        _snack('${f.name} ใหญ่เกิน 15 MB', error: true);
        continue;
      }
      if (mounted) setState(() => _files.add(MapEntry(f.name, bytes)));
    }
  }

  List<String> get _kinds {
    final all = Map<String, dynamic>.from(_status?['kinds'] as Map? ?? {});
    final quiz = (_status?['quiz_kinds'] as List? ?? []).map((e) => '$e').toSet();
    return all.keys.where((k) => _target != 'quiz' || quiz.contains(k)).toList();
  }

  Future<void> _generate() async {
    if (_course == null) return _snack('เลือกรายวิชาก่อน', error: true);
    final kinds = {for (final k in _kinds) if ((_counts[k] ?? 0) > 0) k: _counts[k]};
    if (kinds.isEmpty) return _snack('ใส่จำนวนข้ออย่างน้อย 1 ชนิด', error: true);
    final picked = _pickedCh.keys.toList()..sort();
    final chapters = [
      for (final i in picked)
        {
          'name': _chapters[i]['name'],
          'topics': [for (final k in (_pickedCh[i]!.toList()..sort())) (_chapters[i]['topics'] as List)[k]],
        },
    ];
    if (chapters.isEmpty && _extraTopics.text.trim().isEmpty && _content.text.trim().isEmpty && _files.isEmpty) {
      return _snack('เลือกเรื่องที่จะออกข้อสอบ หรือแนบ/พิมพ์เนื้อหาบทเรียนอย่างน้อย 1 อย่าง', error: true);
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = await _api.aiGenerate({
        'target': _target,
        'course_code': _course!['course_code'],
        'term': _term,
        'year': _year,
        'topics': {'subject': _subject ?? '', 'grade': _grade ?? '', 'chapters': chapters},
        'extra_topics': _extraTopics.text,
        'kinds': kinds,
        'difficulty': _difficulty,
        'content_text': _content.text,
        'instructions': _instructions.text,
      }, _files);
      if (!mounted) return;
      setState(() {
        _questions = (d['questions'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _keep
          ..clear()
          ..addAll(List.generate(_questions.length, (i) => i));
        _notes = (d['notes'] as List? ?? []).map((e) => '$e').toList();
        _topicLabels = (d['topics'] as List? ?? []).map((e) => '$e').toList();
        _modelNote = '${d['model_note'] ?? ''}';
        _status = {...?_status, 'left_today': d['left_today']};
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> get _kept => [for (var i = 0; i < _questions.length; i++) if (_keep.contains(i)) _questions[i]];

  double _pointsOf(Map<String, dynamic> q) {
    final p = (q['points'] as num?)?.toDouble() ?? 1;
    switch ('${q['type']}') {
      case 'truefalse':
      case 'match':
        return p * ((q['items'] as List?)?.length ?? 1);
      case 'cloze':
        return p * RegExp(r'\[\[').allMatches('${q['text'] ?? ''}').length;
      default:
        return p;
    }
  }

  Future<void> _send() async {
    final qs = _kept.map((q) => Map<String, dynamic>.from(q)..remove('topic')).toList();
    if (qs.isEmpty) return _snack('เลือกข้อที่จะใช้อย่างน้อย 1 ข้อ', error: true);
    final c = _course!;
    setState(() => _sending = true);
    try {
      if (_target == 'quiz') {
        final saved = await _api.saveQuiz({
          'course_code': c['course_code'],
          'term': _term,
          'year': _year,
          'title': _title.text.trim().isEmpty ? 'แบบทดสอบย่อย' : _title.text.trim(),
          'unit_slot': _slot,
          'slot_points': _slot == null ? null : double.tryParse(_slotPoints.text.trim()),
          'questions': qs,
          'ready': false,
          'mode': 'quiz',
          'max_attempts': 1,
        });
        if (!mounted) return;
        _snack('สร้างแบบทดสอบ "${saved['title']}" เป็นฉบับร่างแล้ว (${qs.length} ข้อ) ตรวจและตั้งเวลา แล้วกด "เปิดให้นักเรียนเห็น"');
        await ExamEditorDialog.showQuiz(context, _api, c, _term, _year, quizId: (saved['id'] as num).toInt());
      } else {
        final r = await _api.aiAppendExam('${c['course_code']}', _term, _year, _target, qs);
        if (!mounted) return;
        _snack('เพิ่ม ${r['added']} ข้อต่อท้าย${_targets[_target]}แล้ว ตรวจในหน้าข้อสอบได้เลย');
        await ExamEditorDialog.show(context, _api, c, _target, _term, _year);
      }
      if (mounted) setState(() => _questions = []);
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_loadError!, style: TextStyle(color: Colors.red.shade700)),
        const SizedBox(height: 8),
        FilledButton(onPressed: _load, child: const Text('ลองใหม่')),
      ]));
    }
    if (_status == null) return const Center(child: CircularProgressIndicator());
    final configured = _status!['configured'] == true;
    return Scaffold(
      backgroundColor: AppColors.bodyBg,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _header(),
              if (!configured)
                _banner(Icons.key_off_rounded, Colors.orange,
                    'ผู้ดูแลระบบยังไม่ได้ใส่กุญแจ AI (Gemini API key) — ตั้งได้ที่ หน้าตั้งค่า > ตัวช่วย AI'),
              _banner(Icons.shield_outlined, Colors.indigo,
                  'ส่งไป Google เฉพาะเรื่องที่เลือก รายชื่อบทเรียนของชั้นนั้น และเนื้อหาที่ครูให้ ไม่ส่งชื่อหรือข้อมูลนักเรียน และไม่ส่งข้อสอบที่เก็บในระบบ • '
                  'AI แค่ร่าง ครูต้องตรวจโจทย์ เฉลย และวิธีทำทุกข้อก่อนใช้'),
              _step(1, 'จะให้ช่วยออกอะไร', _targetPicker()),
              _step(2, 'รายวิชา', _coursePicker()),
              if (_course != null) ...[
                _step(3, 'เรื่องที่จะออกข้อสอบ', _topicPicker()),
                _step(4, 'เนื้อหาที่เรียน', _contentInput()),
                _step(5, 'ชนิดข้อสอบและจำนวนข้อ', _kindPicker()),
                const SizedBox(height: 4),
                Row(children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.purplePrimary, padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16)),
                    onPressed: !configured || _busy || (_status!['left_today'] ?? 0) <= 0 ? null : _generate,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.auto_awesome_rounded),
                    label: Text(_busy ? 'AI กำลังร่างข้อสอบ (อาจใช้ 1–3 นาที)…' : 'ให้ AI ร่างข้อสอบ'),
                  ),
                  const SizedBox(width: 12),
                  Flexible(child: Text('เหลือวันนี้ ${_status!['left_today']} / ${_status!['daily_limit']} ครั้ง',
                      style: TextStyle(color: Colors.grey.shade700))),
                ]),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: _banner(Icons.error_outline, Colors.red, _error!)),
                if (_questions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _step(6, 'ตรวจข้อสอบที่ AI ร่าง (${_keep.length}/${_questions.length} ข้อที่จะใช้)', _review()),
                  _step(7, _target == 'quiz' ? 'สร้างเป็นแบบทดสอบย่อย และเชื่อมกับหน้าบันทึกคะแนน' : 'เพิ่มเข้า${_targets[_target]}', _sendPanel()),
                ],
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _header() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.borderSubtle)),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.purpleContainer, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.auto_awesome_rounded, color: AppColors.purplePrimary),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('ตัวช่วย AI ออกข้อสอบ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.purpleDark)),
              Text('ร่างแบบทดสอบย่อย ข้อสอบกลางภาค ปลายภาค จากเรื่องและเนื้อหาที่เรียน พร้อมเฉลยและวิธีทำให้ครูตรวจ',
                  style: TextStyle(fontSize: 13)),
            ]),
          ),
        ]),
      );

  Widget _banner(IconData icon, MaterialColor color, String text) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: color.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: color.shade200)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: color.shade900))),
        ]),
      );

  Widget _step(int n, String title, Widget child) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.borderSubtle)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CircleAvatar(radius: 13, backgroundColor: AppColors.gold, child: Text('$n', style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold))),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.purpleDark))),
          ]),
          const SizedBox(height: 10),
          child,
        ]),
      );

  Widget _targetPicker() => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in _targets.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: _target == e.key,
            onSelected: (_) => setState(() {
              _target = e.key;
              _counts.remove(e.key == 'quiz' ? 'photo' : '');
              _questions = [];
            }),
          ),
      ]);

  Widget _coursePicker() {
    if (_courses.isEmpty) return const Text('ภาคเรียนนี้ยังไม่มีรายวิชาที่ท่านสอน');
    return DropdownButtonFormField<String>(
      initialValue: _course == null ? null : '${_course!['course_code']}',
      isExpanded: true,
      decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, labelText: 'รายวิชาของท่าน (ภาคเรียน $_term/$_year)'),
      items: [
        for (final c in _courses)
          DropdownMenuItem(value: '${c['course_code']}', child: Text('${c['course_code']} ${c['course_name'] ?? ''} • ${c['class_level'] ?? ''}', overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => _pickCourse(_courses.firstWhere((c) => '${c['course_code']}' == v)),
    );
  }

  Widget _topicPicker() {
    final subjects = _libSubjects;
    final extra = TextField(
      controller: _extraTopics,
      minLines: 1,
      maxLines: 4,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        labelText: subjects.isEmpty ? 'เรื่องที่จะออกข้อสอบ (บรรทัดละ 1 เรื่อง)' : 'เรื่อง / หัวข้อเพิ่มเติมที่ไม่มีในรายการ (บรรทัดละ 1 เรื่อง)',
        hintText: 'เช่น การแก้โจทย์ปัญหาร้อยละ',
      ),
    );
    if (subjects.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('ยังไม่มีคลังเรื่องในเครื่องนี้ — พิมพ์เรื่องที่จะออกข้อสอบได้เลย', style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
        const SizedBox(height: 8),
        extra,
      ]);
    }
    final grades = _gradesOf(_subject);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 330,
          child: DropdownButtonFormField<String>(
            key: ValueKey('subject-$_subject'),
            initialValue: _subject,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'วิชา (คลังเรื่อง)'),
            items: [
              for (final s in subjects) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _topicsLoading ? null : _changeSubject,
          ),
        ),
        SizedBox(
          width: 150,
          child: DropdownButtonFormField<String>(
            key: ValueKey('grade-$_subject-$_grade'),
            initialValue: grades.contains(_grade) ? _grade : null,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'ชั้น'),
            items: [for (final g in grades) DropdownMenuItem(value: g, child: Text(g))],
            onChanged: _topicsLoading || _subject == null ? null : (g) => _loadTopics(_course!, subject: _subject, grade: g ?? ''),
          ),
        ),
        if (_topicsLoading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
      const SizedBox(height: 6),
      Text(
        _chapters.isNotEmpty
            ? 'ติ๊กบทที่จะออกข้อสอบ แล้วกดหัวข้อย่อยเพื่อเลือกเฉพาะบางหัวข้อได้ • AI เห็นรายชื่อบทเรียนทั้งชั้นเพื่อรู้บริบท'
            : _subject == null
                ? 'เลือกวิชาและชั้นจากคลังเรื่อง'
                : 'ไม่มีบทเรียนของวิชานี้ในชั้นที่เลือก',
        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
      ),
      for (final g in _groups) _groupBlock(g),
      const SizedBox(height: 10),
      extra,
    ]);
  }

  Widget _groupBlock(String g) {
    final idx = [for (var i = 0; i < _chapters.length; i++) if ('${_chapters[i]['group'] ?? ''}' == g) i];
    final open = g.isEmpty || _openGroups.contains(g);
    final picked = idx.where(_pickedCh.containsKey).length;
    final all = idx.isNotEmpty && picked == idx.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (g.isNotEmpty)
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => open ? _openGroups.remove(g) : _openGroups.add(g)),
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: Row(children: [
              Icon(open ? Icons.expand_more_rounded : Icons.chevron_right_rounded, color: AppColors.purpleDark),
              const SizedBox(width: 4),
              Expanded(
                child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(g, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.purpleDark)),
                  if (_suggested.contains(g)) _chip('ตรงกับรายวิชานี้', Colors.green),
                  Text('${idx.length} บท${picked > 0 ? ' • เลือก $picked' : ''}', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                ]),
              ),
              if (open)
                TextButton(
                  onPressed: () => setState(() {
                    for (final i in idx) {
                      all ? _pickedCh.remove(i) : _pickedCh.putIfAbsent(i, () => _allSubTopics(i));
                    }
                  }),
                  child: Text(all ? 'ไม่เลือกทั้งหมด' : 'เลือกทั้งหมด'),
                ),
            ]),
          ),
        ),
      if (open)
        for (final i in idx) _chapterTile(i),
    ]);
  }

  Widget _chapterTile(int i) {
    final c = _chapters[i];
    final topics = (c['topics'] as List? ?? []).map((e) => '$e').toList();
    final sel = _pickedCh[i];
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sel != null ? AppColors.gold : AppColors.borderSubtle),
        color: sel != null ? AppColors.goldContainer : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: sel != null,
          title: Text('${i + 1}. ${c['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: sel != null || topics.isEmpty
              ? null
              : Text(topics.join(' • '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          onChanged: (v) => setState(() => v == true ? _pickedCh[i] = _allSubTopics(i) : _pickedCh.remove(i)),
        ),
        if (sel != null && topics.isNotEmpty) _subTopicChips(i, topics, sel),
      ]),
    );
  }

  Widget _subTopicChips(int i, List<String> topics, Set<int> sel) => Padding(
        padding: const EdgeInsets.fromLTRB(52, 0, 10, 10),
        // a long sub-topic wraps inside its chip instead of being cut off on a phone
        child: LayoutBuilder(
          builder: (context, box) => Wrap(spacing: 6, runSpacing: 6, children: [
            for (var k = 0; k < topics.length; k++)
              FilterChip(
                label: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: (box.maxWidth - 72).clamp(80.0, 900.0)),
                  // chips draw their label on one line unless the text asks to wrap
                  child: Text(topics[k], style: const TextStyle(fontSize: 12), softWrap: true, maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
                selected: sel.contains(k),
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setState(() {
                  v ? sel.add(k) : sel.remove(k);
                  if (sel.isEmpty) _pickedCh.remove(i); // no sub-topic left = the chapter is not picked
                }),
              ),
          ]),
        ),
      );

  Widget _contentInput() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton.icon(
            onPressed: _files.length >= 5 ? null : _addFiles,
            icon: const Icon(Icons.attach_file_rounded),
            label: const Text('แนบไฟล์เนื้อหา (PDF / Word / รูปภาพ)'),
          ),
          for (final f in _files)
            InputChip(label: Text(f.key), onDeleted: () => setState(() => _files.remove(f))),
        ]),
        const SizedBox(height: 4),
        Text('ได้ถึง 5 ไฟล์ ไฟล์ละไม่เกิน 15 MB • PDF และรูปที่สแกนจากหนังสือ AI อ่านได้', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        const SizedBox(height: 8),
        TextField(
          controller: _content,
          minLines: 3,
          maxLines: 12,
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'หรือพิมพ์ / วางเนื้อหาที่เรียน',
              hintText: 'เช่น สรุปบทเรียน สูตร ตัวอย่าง คำศัพท์ที่ต้องรู้'),
        ),
      ]);

  Widget _kindPicker() {
    final names = Map<String, dynamic>.from(_status?['kinds'] as Map? ?? {});
    final levels = Map<String, dynamic>.from(_status?['levels'] as Map? ?? {});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final k in _kinds)
          SizedBox(
            width: 210,
            child: Row(children: [
              Expanded(child: Text('${names[k]}', overflow: TextOverflow.ellipsis)),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: (_counts[k] ?? 0) <= 0 ? null : () => setState(() => _counts[k] = (_counts[k] ?? 0) - 1),
              ),
              SizedBox(width: 26, child: Text('${_counts[k] ?? 0}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold))),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => setState(() => _counts[k] = ((_counts[k] ?? 0) + 1).clamp(0, 40)),
              ),
            ]),
          ),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 300,
          child: DropdownButtonFormField<String>(
            initialValue: _difficulty,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'ระดับความยาก'),
            items: [for (final e in levels.entries) DropdownMenuItem(value: e.key, child: Text('${e.value}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _difficulty = v ?? 'mixed'),
          ),
        ),
        SizedBox(
          width: 420,
          child: TextField(
            controller: _instructions,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'คำสั่งเพิ่มเติมถึง AI (ไม่บังคับ)',
                hintText: 'เช่น เน้นโจทย์ปัญหาในชีวิตประจำวัน ใช้ตัวเลขลงตัว'),
          ),
        ),
      ]),
    ]);
  }

  Widget _review() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_modelNote.isNotEmpty) _banner(Icons.swap_horiz_rounded, Colors.blue, _modelNote),
        if (_notes.isNotEmpty) _banner(Icons.info_outline, Colors.orange, 'ข้อที่ระบบตัดออก (AI ร่างไม่ครบ): ${_notes.join(' • ')}'),
        Row(children: [
          TextButton(onPressed: () => setState(() => _keep.addAll(List.generate(_questions.length, (i) => i))), child: const Text('เลือกทั้งหมด')),
          TextButton(onPressed: () => setState(_keep.clear), child: const Text('ไม่เลือกเลย')),
          const Spacer(),
          Text('รวม ${fmtPoints(_kept.fold<double>(0, (a, q) => a + _pointsOf(q)))} คะแนนดิบ', style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
        for (var i = 0; i < _questions.length; i++) _questionCard(i),
      ]);

  Widget _questionCard(int i) {
    final q = _questions[i];
    final type = '${q['type']}';
    final names = Map<String, dynamic>.from(_status?['kinds'] as Map? ?? {});
    final tn = (q['topic'] as num?)?.toInt();
    final topicText = tn != null && tn >= 1 && tn <= _topicLabels.length ? _topicLabels[tn - 1] : null;
    final on = _keep.contains(i);
    final right = TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.bold);
    final body = <Widget>[];
    switch (type) {
      case 'choice':
        final cs = (q['choices'] as List? ?? []);
        for (var k = 0; k < cs.length; k++) {
          final ok = q['answer'] == k;
          body.add(Text('${ok ? '✓ ' : '   '}${k < _thaiLetters.length ? _thaiLetters[k] : k + 1}. ${cs[k]}', style: ok ? right : null));
        }
      case 'number':
        body.add(Text('เฉลย: ${q['answer']} ${q['unit'] ?? ''}${(q['tolerance'] ?? 0) != 0 ? ' (±${q['tolerance']})' : ''}', style: right));
      case 'text':
        body.add(Text('เฉลย: ${(q['answer'] as List? ?? [q['answer']]).join(' / ')}', style: right));
      case 'truefalse':
        for (final it in (q['items'] as List? ?? [])) {
          body.add(Text('${it['answer'] == true ? '✓ ถูก' : '✗ ผิด'}  ${it['text']}', style: TextStyle(color: it['answer'] == true ? Colors.green.shade800 : Colors.red.shade800)));
        }
      case 'match':
        final opts = (q['options'] as List? ?? []);
        for (final it in (q['items'] as List? ?? [])) {
          final a = (it['answer'] as num?)?.toInt() ?? 0;
          body.add(Text('${it['text']}  →  ${a < opts.length ? opts[a]['text'] : '?'}', style: right));
        }
        body.add(Text('ตัวเลือกด้านขวา: ${opts.map((o) => o['text']).join(' • ')}', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)));
      case 'cloze':
        body.add(Text('${q['text']}'.replaceAllMapped(RegExp(r'\[\[(.+?)\]\]'), (m) => '【${m[1]}】')));
        if ((q['bank'] as List? ?? []).isNotEmpty) body.add(Text('กล่องคำ: ${(q['bank'] as List).join(' • ')}', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)));
      case 'photo':
        body.add(Text('แนวคำตอบ / เกณฑ์: ${q['guide'] ?? '-'}', style: TextStyle(color: Colors.green.shade900)));
    }
    return Opacity(
      opacity: on ? 1 : 0.45,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? AppColors.gold : Colors.grey.shade300),
          color: on ? AppColors.goldContainer : Colors.grey.shade50,
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Checkbox(value: on, onChanged: (v) => setState(() => v == true ? _keep.add(i) : _keep.remove(i))),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('ข้อ ${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                _chip('${names[type] ?? type}', Colors.indigo),
                _chip('${fmtPoints(_pointsOf(q))} คะแนน', Colors.teal),
                if (topicText != null) _chip(topicText, Colors.purple),
              ]),
              const SizedBox(height: 6),
              SelectableText('${q['q']}', style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 4),
              ...body,
              if ('${q['explain'] ?? ''}'.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(10),
                  width: double.infinity,
                  decoration: BoxDecoration(color: Colors.amber.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.amber.shade300)),
                  child: SelectableText('วิธีทำ / เหตุผล (ครูเห็นเท่านั้น)\n${q['explain']}', style: TextStyle(fontSize: 13, color: Colors.brown.shade900)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _chip(String text, MaterialColor c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: c.shade50, borderRadius: BorderRadius.circular(20), border: Border.all(color: c.shade200)),
        child: Text(text, style: TextStyle(fontSize: 12, color: c.shade800)),
      );

  Widget _sendPanel() {
    final raw = _kept.fold<double>(0, (a, q) => a + _pointsOf(q));
    if (_target != 'quiz') {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('ข้อที่เลือก ${_kept.length} ข้อจะต่อท้ายข้อเดิมใน${_targets[_target]}ของวิชานี้ (ไม่ลบข้อเดิม) • คะแนนคิดตามสัดส่วนคะแนนเต็ม${_targets[_target]!.replaceFirst('ข้อสอบ', '')}'
            ' ทศนิยม 1 ตำแหน่ง ปัดขึ้นเสมอ • ถ้ามีนักเรียนเริ่มสอบแล้วจะเพิ่มไม่ได้'),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _sending || _kept.isEmpty ? null : _send,
            icon: const Icon(Icons.playlist_add_rounded),
            label: Text('เพิ่ม ${_kept.length} ข้อต่อท้าย${_targets[_target]} แล้วเปิดตรวจ'),
          ),
        ),
      ]);
    }
    String full(int i) {
      final m = i < _unitMax.length ? _unitMax[i] : null;
      return m == null ? 'ยังไม่ตั้งคะแนนเต็ม' : 'เต็ม ${fmtPoints(m as num)}';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: _title, decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'ชื่อแบบทดสอบ')),
      const SizedBox(height: 10),
      DropdownButtonFormField<int>(
        initialValue: _slot ?? -1,
        isExpanded: true,
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'ส่งคะแนนเข้าช่องตัวชี้วัด (หน้าบันทึกคะแนน)'),
        items: [
          const DropdownMenuItem(value: -1, child: Text('ไม่เชื่อม (ฝึกทำ ไม่เข้าคะแนน)')),
          for (var i = 0; i < 8; i++)
            DropdownMenuItem(
              value: i,
              enabled: i < _unitMax.length && _unitMax[i] != null,
              child: Text('ช่อง ${i + 1} (${full(i)})${_labels[i].isNotEmpty ? ' • ${_labels[i]}' : ''}', overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: i < _unitMax.length && _unitMax[i] != null ? null : Colors.grey)),
            ),
        ],
        onChanged: (v) => setState(() {
          _slot = v == null || v < 0 ? null : v;
          _slotPoints.clear();
        }),
      ),
      if (_slot != null) ...[
        const SizedBox(height: 10),
        SlotPointsField(
          controller: _slotPoints,
          slotFull: (_unitMax[_slot!] as num?)?.toDouble(),
          rawPoints: raw,
          onChanged: () => setState(() {}),
        ),
      ],
      const SizedBox(height: 6),
      Text('สร้างเป็นฉบับร่าง (นักเรียนยังไม่เห็น) แล้วเปิดหน้าแก้ไขให้ตรวจ ตั้งเวลา และกด "เปิดให้นักเรียนเห็น"',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: _sending || _kept.isEmpty ? null : _send,
          icon: const Icon(Icons.post_add_rounded),
          label: Text('สร้างแบบทดสอบย่อย ${_kept.length} ข้อ (ฉบับร่าง)'),
        ),
      ),
    ]);
  }
}
