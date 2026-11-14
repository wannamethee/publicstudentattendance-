import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/exams_screen.dart' show thaiDateTime;
import '../services/api_service.dart';
import '../utils/app_theme.dart';
import 'student_exams.dart' show ExamTakePage;

String _num(dynamic v) {
  if (v == null) return '-';
  final d = (v as num).toDouble();
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

/// นักเรียน: แบบทดสอบย่อย / หลังเรียน of each enrolled course, opening by themselves at the time the teacher set
/// (or only during that course's class period).
class StudentQuizzesPage extends StatefulWidget {
  final ApiService apiService;
  const StudentQuizzesPage({super.key, required this.apiService});

  static Future<void> open(BuildContext context, ApiService api) {
    return Navigator.of(context).push(MaterialPageRoute(builder: (_) => StudentQuizzesPage(apiService: api)));
  }

  @override
  State<StudentQuizzesPage> createState() => _StudentQuizzesPageState();
}

class _StudentQuizzesPageState extends State<StudentQuizzesPage> {
  late Future<Map<String, dynamic>> _future;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _future = widget.apiService.getStudentQuizzes();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) _reload();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _reload() => setState(() => _future = widget.apiService.getStudentQuizzes());

  Future<void> _open(Map c, Map q) async {
    if (q['mode'] == 'link') {
      final uri = Uri.tryParse('${q['link_url'] ?? ''}');
      if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (q['status'] != 'in_progress') {
      final left = q['tries_left'];
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('เริ่มทำ "${q['title']}"?'),
          content: Text(
            '${c['course_code']} ${c['course_name'] ?? ''}\n'
            '${q['question_count']} ข้อ ${_num(q['points'])} คะแนน'
            '${q['duration_min'] == null ? '' : q['time_ends_at'] != null ? ' • เหลือเวลา ${q['time_left_min'] ?? 0} นาที (${q['duration_min']} นาที รวมทุกครั้ง นับจากครั้งแรก)' : ' • เวลา ${q['duration_min']} นาที รวมทุกครั้ง (เริ่มนับเมื่อกดเริ่มครั้งแรก)'}\n'
            '${q['class_only'] == true ? 'ต้องส่งก่อนหมดคาบเรียน\n' : (q['ends_at'] != null ? 'ต้องส่งก่อน ${thaiDateTime(q['ends_at'])}\n' : '')}'
            '${left == null ? 'ทำซ้ำได้ไม่จำกัด' : 'ครั้งนี้เป็นครั้งที่ ${(q['tries'] ?? 0) + 1} (ทำได้อีก $left ครั้ง)'} • ระบบใช้คะแนนครั้งที่ดีที่สุด\n'
            'ระบบบันทึกคำตอบให้ระหว่างทำ',
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
      builder: (_) => ExamTakePage(
          apiService: widget.apiService, examId: (q['quiz_id'] as num).toInt(), courseCode: '${c['course_code']}', title: '${q['title'] ?? ''}', isQuiz: true),
    ));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('แบบทดสอบย่อย'),
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), tooltip: 'โหลดใหม่')],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData && !snap.hasError) return const Center(child: CircularProgressIndicator());
          if (snap.hasError && !snap.hasData) {
            return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(snap.error.toString().replaceFirst('Exception: ', ''))));
          }
          final courses = (snap.data!['courses'] as List).cast<Map>();
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: courses.isEmpty
                  ? [
                      const SizedBox(height: 60),
                      Icon(Icons.assignment_outlined, size: 56, color: Colors.grey.shade400),
                      const SizedBox(height: 8),
                      Center(child: Text('ยังไม่มีแบบทดสอบย่อย', style: TextStyle(color: Colors.grey.shade600, fontSize: 16))),
                    ]
                  : courses.map(_course).toList(),
            ),
          );
        },
      ),
    );
  }

  Widget _course(Map c) {
    final qs = (c['quizzes'] as List).cast<Map>();
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.gold)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${c['course_code']} ${c['course_name'] ?? ''}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          if ('${c['teacher'] ?? ''}'.isNotEmpty) Text('${c['teacher']}', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 10, children: qs.map((q) => _button(c, q)).toList()),
        ]),
      ),
    );
  }

  String _closedText(Map q) {
    if (q['opens_at'] != null) return 'เปิด ${thaiDateTime(q['opens_at'])}';
    return '${q['reason'] ?? 'ยังไม่เปิด'}';
  }

  Widget _button(Map c, Map q) {
    final open = q['is_open'] == true;
    final status = '${q['status']}';
    final best = q['best'] as Map?;
    final canStart = q['can_start'] == true;
    final enabled = open && canStart;
    final left = q['tries_left'];
    late final String sub;
    late final Color color;
    late final IconData icon;
    if (q['mode'] == 'link') {
      sub = 'เปิดลิงก์แบบทดสอบ';
      color = const Color(0xFF1D4ED8);
      icon = Icons.open_in_new_rounded;
    } else if (status == 'in_progress') {
      sub = 'กำลังทำ • กดเพื่อทำต่อ';
      color = const Color(0xFFB45309);
      icon = Icons.edit_note_rounded;
    } else if (best != null) {
      sub = 'ได้ ${_num(best['earned'])}/${_num(best['max_points'])}'
          '${q['time_up'] == true ? ' • หมดเวลาแล้ว' : (left == null ? ' • ทำซ้ำได้' : (left > 0 ? ' • ทำได้อีก $left ครั้ง' : ' • ครบแล้ว'))}';
      color = const Color(0xFF15803D);
      icon = Icons.check_circle_rounded;
    } else {
      sub = '${q['question_count']} ข้อ ${_num(q['points'])} คะแนน${q['duration_min'] != null ? ' • ${q['duration_min']} นาที' : ''}';
      color = AppColors.purpleDark;
      icon = Icons.assignment_rounded;
    }
    final lit = enabled || best != null;
    return SizedBox(
      width: 260,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          side: BorderSide(color: lit ? color : Colors.grey.shade300, width: 1.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: best != null ? color.withValues(alpha: 0.06) : null,
        ),
        onPressed: enabled ? () => _open(c, q) : null,
        child: Row(children: [
          Icon(icon, color: lit ? color : Colors.grey),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${q['title']}', maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: lit ? color : Colors.grey)),
              Text(sub, style: TextStyle(fontSize: 11.5, color: lit ? color : Colors.grey)),
              if (!open && status != 'in_progress')
                Text(_closedText(q), style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700))
              else if (open && q['time_ends_at'] != null && q['time_up'] != true)
                Text('เหลือเวลา ${q['time_left_min'] ?? 0} นาที (รวมทุกครั้ง)', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700))
              else if (open && q['class_only'] == true)
                Text('ในคาบเรียน • ส่งก่อน ${thaiDateTime(q['ends_at'])}', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700))
              else if (open && q['end_at'] != null)
                Text('ปิด ${thaiDateTime(q['end_at'])}', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
            ]),
          ),
        ]),
      ),
    );
  }
}
