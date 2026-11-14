import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../utils/app_theme.dart';
import 'student_quizzes.dart';

/// ตารางเรียนของชั้นที่นักเรียนคนนี้อยู่ สำหรับหน้านักเรียน (ดูได้เฉพาะชั้นของตัวเอง:
/// ระดับชั้นมาจากรหัสที่ล็อกอิน เซิร์ฟเวอร์ไม่รับให้ระบุชั้นอื่น)
class StudentTimetableDialog extends StatefulWidget {
  final ApiService apiService;
  const StudentTimetableDialog({super.key, required this.apiService});

  static Future<void> show(BuildContext context, ApiService api) =>
      showDialog(context: context, builder: (_) => StudentTimetableDialog(apiService: api));

  @override
  State<StudentTimetableDialog> createState() => _StudentTimetableDialogState();
}

class _StudentTimetableDialogState extends State<StudentTimetableDialog> {
  Map<String, dynamic>? _d;
  String? _error;
  final Set<String> _quizCodes = {}; // วิชาที่มีแบบทดสอบย่อย
  final Set<String> _openCodes = {}; // ... ที่ทำได้ตอนนี้

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.apiService.getStudentTimetable();
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    try {
      final q = await widget.apiService.getStudentQuizzes();
      if (!mounted) return;
      setState(() {
        for (final c in (q['courses'] as List? ?? [])) {
          final code = '${(c as Map)['course_code']}';
          _quizCodes.add(code);
          if ((c['quizzes'] as List? ?? []).any((x) => (x as Map)['is_open'] == true && x['can_start'] == true)) _openCodes.add(code);
        }
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.gold, width: 1.5)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 900, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
            decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d == null ? 'ตารางเรียนของฉัน' : 'ตารางเรียน ${d['class_level']}${(d['room'] ?? '').toString().isEmpty ? '' : '/${d['room']}'}',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  if (d != null)
                    Text('${d['full_name']} • รหัส ${d['student_id']} • ภาคเรียนที่ ${d['term']}/${d['year']}',
                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800)),
                ]),
              ),
              IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
          else if (d == null)
            const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()))
          else
            Flexible(child: _grid(d)),
        ]),
      ),
    );
  }

  Widget _grid(Map<String, dynamic> d) {
    final weekdays = ((d['weekdays'] as List?) ?? []).cast<String>();
    final periods = ((d['period_configs'] as List?) ?? []).cast<Map>();
    final slots = ((d['slots'] as List?) ?? []).cast<Map>();
    // (day, period) -> slot; a slot spanning several periods fills each of them
    // ช่องหนึ่งมีได้มากกว่าหนึ่งวิชา (ครูสองคนตกลงสอนชั้นนี้คาบเดียวกัน) วิชาที่ลงทะเบียนเรียนขึ้นก่อน
    final byCell = <String, List<Map>>{};
    for (final s in slots) {
      final day = (s['day_of_week'] as num?)?.toInt() ?? 0;
      final p = (s['period_num'] as num?)?.toInt() ?? 0;
      final span = (s['period_span'] as num?)?.toInt() ?? 1;
      for (var k = p; k < p + span; k++) {
        final list = byCell.putIfAbsent('$day|$k', () => []);
        if (!list.any((x) => x['course_code'] == s['course_code'])) list.add(s);
      }
    }
    for (final list in byCell.values) {
      list.sort((a, b) => (b['mine'] == true ? 1 : 0) - (a['mine'] == true ? 1 : 0));
    }
    final teaching = [for (final p in periods) if (((p['period'] as num?)?.toInt() ?? 0) > 0) p];
    const dayW = 86.0;
    const cellW = 118.0;

    Widget head(String text, double w, {Color? bg}) => Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(color: bg ?? AppColors.goldLight, border: Border.all(color: Colors.grey.shade300)),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        );

    Widget cell(int day, Map period) {
      final p = (period['period'] as num?)?.toInt() ?? 0;
      final list = byCell['$day|$p'] ?? const <Map>[];
      final s = list.isEmpty ? null : list.first;
      if (s == null) {
        return Container(
          width: cellW,
          height: 58,
          decoration: BoxDecoration(color: Colors.grey.shade50, border: Border.all(color: Colors.grey.shade300)),
        );
      }
      final mine = s['mine'] == true;
      final code = '${s['course_code'] ?? ''}';
      final name = '${s['course_name'] ?? ''}';
      final teacher = '${s['teacher_name'] ?? ''}';
      final codes = code.split(',').map((x) => x.trim()).toList();
      final hasQuiz = codes.any(_quizCodes.contains);
      final quizOpen = codes.any(_openCodes.contains);
      final box = Container(
        width: cellW,
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFFFEF3C7) : Colors.white,
          border: Border.all(color: mine ? AppColors.gold : Colors.grey.shade300, width: mine ? 1.3 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(code.isEmpty ? name : code, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          if (name.isNotEmpty && code.isNotEmpty)
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5)),
          if (list.length > 1)
            Text('+ ${list.skip(1).map((x) => x['course_code']).join(', ')}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF4338CA)))
          else if (teacher.isNotEmpty)
            Text(teacher, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: Colors.grey.shade700)),
        ]),
      );
      if (!hasQuiz) return box;
      return Tooltip(
        message: quizOpen ? 'มีแบบทดสอบย่อยเปิดให้ทำ — กดเพื่อทำ' : 'มีแบบทดสอบย่อยวิชานี้ — กดเพื่อดู',
        child: InkWell(
          onTap: () => StudentQuizzesPage.open(context, widget.apiService),
          child: Stack(children: [
            box,
            Positioned(
              right: 3,
              top: 3,
              child: Icon(Icons.assignment_rounded, size: 15, color: quizOpen ? const Color(0xFF15803D) : AppColors.purpleDark.withValues(alpha: 0.55)),
            ),
          ]),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(children: [
            Row(children: [
              head('วัน / คาบ', dayW),
              for (final p in teaching) head('คาบ ${p['period']}\n${p['label'] ?? ''}', cellW),
            ]),
            for (var i = 0; i < weekdays.length; i++)
              Row(children: [
                head('วัน${weekdays[i]}', dayW, bg: Colors.grey.shade100),
                for (final p in teaching) cell(i + 1, p),
              ]),
          ]),
        ),
        const SizedBox(height: 10),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
          Container(width: 14, height: 14, decoration: BoxDecoration(color: const Color(0xFFFEF3C7), border: Border.all(color: AppColors.gold))),
          const SizedBox(width: 6),
          const Text('วิชาที่ฉันลงทะเบียนเรียน', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 16),
          Container(width: 14, height: 14, decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey.shade400))),
          const SizedBox(width: 6),
          const Text('กิจกรรม / คาบรวม', style: TextStyle(fontSize: 12)),
          if (_quizCodes.isNotEmpty) ...[
            const SizedBox(width: 16),
            const Icon(Icons.assignment_rounded, size: 15, color: Color(0xFF15803D)),
            const SizedBox(width: 4),
            const Text('มีแบบทดสอบย่อย (สีเขียว = ทำได้ตอนนี้) กดที่ช่องเพื่อทำ', style: TextStyle(fontSize: 12)),
          ],
        ]),
        const SizedBox(height: 6),
        Text('เวลาพักและพักกลางวันดูได้จากช่วงเวลาในหัวตาราง • ถ้าตารางยังว่าง แจ้งครูที่ปรึกษาได้',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
      ]),
    );
  }
}
