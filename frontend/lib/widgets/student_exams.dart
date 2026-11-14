import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/exams_screen.dart' show thaiDateTime;
import '../services/api_service.dart';
import '../utils/app_theme.dart';
import 'question_kinds.dart';
import 'student_question_card.dart';

String _num(dynamic v) {
  if (v == null) return '-';
  final d = (v as num).toDouble();
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

/// นักเรียน: one button per enrolled course code, grouped into กลางภาค / ปลายภาค, usable only in the exam window.
class StudentExamsPage extends StatefulWidget {
  final ApiService apiService;
  const StudentExamsPage({super.key, required this.apiService});

  static Future<void> open(BuildContext context, ApiService api) {
    return Navigator.of(context).push(MaterialPageRoute(builder: (_) => StudentExamsPage(apiService: api)));
  }

  @override
  State<StudentExamsPage> createState() => _StudentExamsPageState();
}

class _StudentExamsPageState extends State<StudentExamsPage> {
  late Future<Map<String, dynamic>> _future;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _future = widget.apiService.getStudentExams();
    // each course unlocks by itself at its exam time (or when the admin opens it early)
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) _reload();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _reload() => setState(() => _future = widget.apiService.getStudentExams());

  Future<void> _open(Map exam, Map group) async {
    if (exam['mode'] == 'link') {
      final uri = Uri.tryParse('${exam['link_url'] ?? ''}');
      if (uri == null) return;
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (exam['status'] == 'not_started') {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('เริ่มทำข้อสอบ ${exam['course_code']}?'),
          content: Text(
            '${exam['title'] ?? ''}\n${exam['question_count']} ข้อ'
            '${exam['duration_min'] != null ? ' • เวลา ${exam['duration_min']} นาที (เริ่มนับเมื่อกดเริ่ม)' : ' • ทำได้ถึง ${thaiDateTime(exam['end_at'])}'}\n'
            'สอบได้ครั้งเดียว ระบบบันทึกคำตอบให้ระหว่างทำ',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยังก่อน')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('เริ่มทำ')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ExamTakePage(apiService: widget.apiService, examId: (exam['exam_id'] as num).toInt(), courseCode: '${exam['course_code']}', title: '${exam['title'] ?? ''}'),
    ));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ข้อสอบของฉัน'),
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), tooltip: 'โหลดใหม่')],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData && !snap.hasError) return const Center(child: CircularProgressIndicator());
          if (snap.hasError && !snap.hasData) {
            return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(snap.error.toString().replaceFirst('Exception: ', ''))));
          }
          final groups = (snap.data!['groups'] as List).cast<Map>();
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: groups.map((g) => _group(g)).toList(),
            ),
          );
        },
      ),
    );
  }

  Widget _group(Map g) {
    final exams = (g['exams'] as List).cast<Map>();
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.gold)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ข้อสอบ${g['label']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('แต่ละวิชาเปิดให้กดเองเมื่อถึงเวลาสอบของวิชานั้น', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
            const SizedBox(height: 10),
            if (exams.isEmpty)
              Text('ยังไม่มีข้อสอบ', style: TextStyle(color: Colors.grey.shade600))
            else
              Wrap(spacing: 10, runSpacing: 10, children: exams.map((e) => _button(e, g)).toList()),
          ],
        ),
      ),
    );
  }

  static String _closedText(Map e) {
    if (e['has_ended'] == true) return 'หมดเวลาสอบแล้ว';
    if (e['start_at'] == null) return 'ยังไม่กำหนดเวลาสอบ';
    return 'เปิดสอบ ${thaiDateTime(e['start_at'])}';
  }

  /// ติด มส. in this course and the teacher has not let them sit: a greyed button that cannot be pressed.
  Widget _blockedButton(Map e) {
    final reason = '${e['blocked_reason'] ?? 'ติด มส. กรุณาติดต่อครูประจำวิชา'}';
    return SizedBox(
      width: 200,
      child: Tooltip(
        message: reason,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300, width: 1.4),
          ),
          child: Row(children: [
            Icon(Icons.block_rounded, color: Colors.grey.shade500),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${e['course_code']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey.shade500)),
                Text('${e['course_name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                Text('ติด มส. • ติดต่อครูประจำวิชา', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.red.shade400)),
                if ('${e['teacher'] ?? ''}'.isNotEmpty)
                  Text('${e['teacher']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _button(Map e, Map g) {
    final open = e['is_open'] == true;
    final status = '${e['status']}';
    final result = e['result'] as Map?;
    final submitted = status == 'submitted';
    String sub;
    Color color;
    IconData icon;
    if (submitted) {
      sub = result == null ? 'ส่งแล้ว' : 'ส่งแล้ว • ${_num(result['score'])}/${_num(result['score_max'])} คะแนน';
      color = const Color(0xFF15803D);
      icon = Icons.check_circle_rounded;
    } else if (status == 'in_progress') {
      sub = 'กำลังทำ • กดเพื่อทำต่อ';
      color = const Color(0xFFB45309);
      icon = Icons.edit_note_rounded;
    } else if (e['mode'] == 'link') {
      sub = 'เปิดลิงก์ข้อสอบ';
      color = const Color(0xFF1D4ED8);
      icon = Icons.open_in_new_rounded;
    } else {
      sub = '${e['question_count']} ข้อ${e['duration_min'] != null ? ' • ${e['duration_min']} นาที' : ''}';
      color = AppColors.purpleDark;
      icon = Icons.quiz_rounded;
    }
    final enabled = open && !submitted;
    if (e['blocked'] == true) return _blockedButton(e);
    return SizedBox(
      width: 200,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          side: BorderSide(color: enabled || submitted ? color : Colors.grey.shade300, width: 1.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: submitted ? color.withValues(alpha: 0.06) : null,
        ),
        onPressed: enabled ? () => _open(e, g) : null,
        child: Row(children: [
          Icon(icon, color: enabled || submitted ? color : Colors.grey),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${e['course_code']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: enabled || submitted ? color : Colors.grey)),
              Text('${e['course_name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
              Text(open || submitted ? sub : _closedText(e), style: TextStyle(fontSize: 11.5, color: enabled || submitted ? color : Colors.grey)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The student's own shuffled copy: countdown, answers saved as they go, auto-submit when time is up.
class ExamTakePage extends StatefulWidget {
  final ApiService apiService;
  final int examId;
  final String courseCode;
  final String title;
  /// แบบทดสอบย่อย (examId is the quiz id): several tries, the best counts
  final bool isQuiz;
  const ExamTakePage({super.key, required this.apiService, required this.examId, required this.courseCode, required this.title, this.isQuiz = false});

  @override
  State<ExamTakePage> createState() => _ExamTakePageState();
}

class _ExamTakePageState extends State<ExamTakePage> {
  bool _loading = true;
  String? _error;
  List<Map> _questions = [];
  final Map<String, dynamic> _answers = {}; // ปรนัย: choice index, เติมตัวเลข: the text typed
  Map<String, List<String>> _photos = {}; // เขียนตอบ ถ่ายภาพส่ง: photo names per question
  final Map<String, TextEditingController> _numCtrls = {};
  final Set<String> _uploading = {};
  Map? _result;
  DateTime? _deadline; // in this device's clock
  Duration _left = Duration.zero;
  Timer? _tick;
  Timer? _saveDebounce;
  bool _submitting = false;
  String _saveState = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _saveDebounce?.cancel();
    for (final c in _numCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _answeredCount {
    var n = 0;
    for (var i = 0; i < _questions.length; i++) {
      if (_questions[i]['type'] == 'photo') {
        if ((_photos['$i'] ?? []).isNotEmpty) n++;
      } else if (setTypes.contains(_questions[i]['type'])) {
        if (filledParts(_answers['$i']) > 0) n++;
      } else if (_answers['$i'] != null && '${_answers['$i']}'.trim().isNotEmpty) {
        n++;
      }
    }
    return n;
  }

  Future<void> _start() async {
    try {
      final d = widget.isQuiz ? await widget.apiService.startStudentQuiz(widget.examId) : await widget.apiService.startStudentExam(widget.examId);
      if (!mounted) return;
      if (d['status'] == 'submitted') {
        setState(() {
          _result = d['result'] as Map?;
          _loading = false;
        });
        return;
      }
      final serverNow = DateTime.parse('${d['server_now']}');
      final deadline = DateTime.parse('${d['deadline_at']}');
      setState(() {
        _questions = (d['questions'] as List).cast<Map>();
        (d['answers'] as Map? ?? {}).forEach((k, v) => _answers['$k'] = v);
        _photos = {
          for (final e in (d['photos'] as Map? ?? {}).entries) '${e.key}': (e.value as List).map((x) => '$x').toList(),
        };
        for (var i = 0; i < _questions.length; i++) {
          if (_questions[i]['type'] == 'number' || _questions[i]['type'] == 'text') {
            _numCtrls['$i'] = TextEditingController(text: '${_answers['$i'] ?? ''}');
          }
        }
        _deadline = DateTime.now().add(deadline.difference(serverNow));
        _loading = false;
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
      _onTick();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _onTick() {
    if (_deadline == null || _result != null) return;
    final left = _deadline!.difference(DateTime.now());
    setState(() => _left = left.isNegative ? Duration.zero : left);
    if (left.isNegative && !_submitting) _submit(auto: true);
  }

  void _choose(int qi, dynamic value) {
    setState(() {
      if (value == null || (value is String && value.trim().isEmpty)) {
        _answers.remove('$qi');
      } else {
        _answers['$qi'] = value;
      }
      _saveState = 'กำลังบันทึก...';
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () async {
      try {
        if (widget.isQuiz) {
          await widget.apiService.saveStudentQuizAnswers(widget.examId, Map.of(_answers));
        } else {
          await widget.apiService.saveStudentExamAnswers(widget.examId, Map.of(_answers));
        }
        if (mounted) setState(() => _saveState = 'บันทึกคำตอบแล้ว');
      } catch (_) {
        if (mounted) setState(() => _saveState = 'ยังบันทึกไม่ได้ (ตรวจสอบอินเทอร์เน็ต) — คำตอบยังอยู่ในเครื่อง');
      }
    });
  }

  Future<void> _submit({bool auto = false}) async {
    if (!auto) {
      final missing = _questions.length - _answeredCount;
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('ส่งคำตอบ?'),
          content: Text(missing > 0 ? 'ยังไม่ได้ตอบ $missing ข้อ ส่งแล้วแก้ไม่ได้' : 'ตอบครบทุกข้อแล้ว ส่งแล้วแก้ไม่ได้'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('กลับไปทำต่อ')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ส่งคำตอบ')),
          ],
        ),
      );
      if (yes != true) return;
    }
    setState(() => _submitting = true);
    _saveDebounce?.cancel();
    try {
      final d = widget.isQuiz
          ? await widget.apiService.submitStudentQuiz(widget.examId, Map.of(_answers))
          : await widget.apiService.submitStudentExam(widget.examId, Map.of(_answers));
      _tick?.cancel();
      if (mounted) setState(() => _result = widget.isQuiz ? {...(d['result'] as Map? ?? {}), '_summary': d} : d['result'] as Map?);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ส่งไม่สำเร็จ: ${e.toString().replaceFirst('Exception: ', '')} — ลองกดส่งอีกครั้ง')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ss = (_left.inSeconds % 60).toString().padLeft(2, '0');
    final hurry = _left.inMinutes < 5;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.isQuiz ? 'แบบทดสอบ' : 'ข้อสอบ'} ${widget.courseCode}', overflow: TextOverflow.ellipsis),
        actions: [
          if (_result == null && _deadline != null)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: hurry ? Colors.red.shade700 : Colors.black26, borderRadius: BorderRadius.circular(8)),
                  child: Text('เหลือ ${_left.inHours > 0 ? '${_left.inHours}:' : ''}${(_left.inMinutes % 60).toString().padLeft(2, '0')}:$ss',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()])),
                ),
              ),
            ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: _result == null && _questions.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Row(children: [
                  Expanded(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('ตอบแล้ว $_answeredCount/${_questions.length} ข้อ', style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (_saveState.isNotEmpty) Text(_saveState, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
                    ]),
                  ),
                  FilledButton.icon(
                    onPressed: _submitting ? null : () => _submit(),
                    icon: _submitting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_rounded),
                    label: const Text('ส่งคำตอบ'),
                  ),
                ]),
              ),
            )
          : null,
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)));
    if (_result != null && widget.isQuiz) return _quizResult(_result!);
    if (_result != null) {
      final r = _result!;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.check_circle_rounded, size: 64, color: Color(0xFF15803D)),
            const SizedBox(height: 10),
            const Text('ส่งข้อสอบแล้ว', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (r['earned'] != null)
              Text('ได้ ${_num(r['earned'])} จาก ${_num(r['max_points'])} แต้ม', style: const TextStyle(fontSize: 16))
            else
              Text('ตอบถูก ${r['correct']} จาก ${r['total']} ข้อ', style: const TextStyle(fontSize: 16)),
            Text('${(r['pending'] ?? 0) > 0 ? 'คะแนนเบื้องต้น ' : 'ได้ '}${_num(r['score'])} จาก ${_num(r['score_max'])} คะแนน',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.purpleDark)),
            if ((r['pending'] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('ข้อเขียนที่ถ่ายภาพส่ง ${r['pending']} ข้อ รอครูตรวจ คะแนนจะเพิ่มเมื่อครูตรวจแล้ว',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.blue.shade800)),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('กลับหน้าข้อสอบ')),
          ]),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      itemCount: _questions.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          );
        }
        final qi = i - 1;
        final q = _questions[qi];
        final type = '${q['type'] ?? 'choice'}';
        return StudentQuestionCard(
          api: widget.apiService,
          index: qi,
          q: q,
          answer: _answers['$qi'],
          textCtrl: _numCtrls['$qi'],
          done: studentAnswered(q, _answers['$qi'], photos: (_photos['$qi'] ?? []).length),
          onAnswer: (v) => _choose(qi, v),
          photoArea: type == 'photo' ? _photoItem(qi) : null,
        );
      },
    );
  }

  /// แบบทดสอบย่อย: this try's points, the best so far, and the tries left
  Widget _quizResult(Map r) {
    final sm = (r['_summary'] as Map?) ?? {};
    final best = sm['best'] as Map?;
    final left = sm['tries_left'];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_rounded, size: 64, color: Color(0xFF15803D)),
          const SizedBox(height: 10),
          Text('ส่งแบบทดสอบแล้ว${r['attempt_no'] != null ? ' (ครั้งที่ ${r['attempt_no']})' : ''}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('ตอบถูก ${r['correct']} จาก ${r['total']} ข้อ', style: const TextStyle(fontSize: 16)),
          Text('ได้ ${_num(r['earned'])} จาก ${_num(r['max_points'])} คะแนน',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.purpleDark)),
          if (best != null && (sm['tries'] ?? 1) > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('คะแนนที่ดีที่สุด ${_num(best['earned'])}/${_num(best['max_points'])} (ระบบใช้ครั้งที่ดีที่สุด)',
                  style: TextStyle(color: Colors.blue.shade800)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(left == null ? 'ทำซ้ำได้ไม่จำกัด' : (left > 0 ? 'ทำได้อีก $left ครั้ง' : 'ทำครบจำนวนครั้งแล้ว'),
                style: TextStyle(color: Colors.grey.shade700)),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('กลับหน้าแบบทดสอบ')),
        ]),
      ),
    );
  }

  Widget _photoItem(int qi) {
    final names = _photos['$qi'] ?? [];
    final busy = _uploading.contains('$qi');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (names.isNotEmpty)
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final n in names)
            Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(widget.apiService.studentExamPhotoUrl(widget.examId, n), height: 120, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(width: 90, height: 120, child: Icon(Icons.image_outlined))),
              ),
              Positioned(
                right: 0,
                top: 0,
                child: IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'ลบรูปนี้',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => _removePhoto(qi, n),
                ),
              ),
            ]),
        ]),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton.icon(
          onPressed: busy || names.length >= 5 ? null : () => _addPhoto(qi, ImageSource.camera),
          icon: const Icon(Icons.photo_camera_rounded),
          label: const Text('ถ่ายภาพ'),
        ),
        OutlinedButton.icon(
          onPressed: busy || names.length >= 5 ? null : () => _addPhoto(qi, ImageSource.gallery),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('เลือกรูป'),
        ),
        if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        Text(names.isEmpty ? 'ยังไม่ได้ส่งรูป' : 'ส่งแล้ว ${names.length} รูป (สูงสุด 5)',
            style: TextStyle(fontSize: 12, color: names.isEmpty ? Colors.orange.shade800 : const Color(0xFF15803D))),
      ]),
    ]);
  }

  Future<void> _addPhoto(int qi, ImageSource source) async {
    try {
      final f = await ImagePicker().pickImage(source: source, maxWidth: 2000, imageQuality: 85);
      if (f == null) return;
      setState(() => _uploading.add('$qi'));
      final bytes = await f.readAsBytes();
      final r = await widget.apiService.uploadStudentExamPhoto(widget.examId, qi, bytes, f.name.isEmpty ? 'photo.jpg' : f.name);
      if (!mounted) return;
      setState(() => _photos = {
            for (final e in (r['photos'] as Map).entries) '${e.key}': (e.value as List).map((x) => '$x').toList(),
          });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ส่งรูปไม่สำเร็จ: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    } finally {
      if (mounted) setState(() => _uploading.remove('$qi'));
    }
  }

  Future<void> _removePhoto(int qi, String name) async {
    try {
      final r = await widget.apiService.deleteStudentExamPhoto(widget.examId, qi, name);
      if (!mounted) return;
      setState(() => _photos = {
            for (final e in (r['photos'] as Map).entries) '${e.key}': (e.value as List).map((x) => '$x').toList(),
          });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }
}
