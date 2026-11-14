import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../utils/app_theme.dart';

/// นักเรียนไม่มีสิทธิ์สอบ (มส.) of one course, from the same attendance summary as the scores page and ปพ.5.
/// The course teacher ticks the students who may still sit the exam; unticked ones see a greyed exam button.
class NoExamRightDialog extends StatefulWidget {
  final ApiService apiService;
  final String courseCode;
  final String term;
  final String year;
  const NoExamRightDialog({super.key, required this.apiService, required this.courseCode, required this.term, required this.year});

  /// Returns true when a tick was changed (so the caller can refresh its counts).
  static Future<bool?> show(BuildContext context, ApiService api, String courseCode, String term, String year) => showDialog<bool>(
        context: context,
        builder: (_) => NoExamRightDialog(apiService: api, courseCode: courseCode, term: term, year: year),
      );

  @override
  State<NoExamRightDialog> createState() => _NoExamRightDialogState();
}

class _NoExamRightDialogState extends State<NoExamRightDialog> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _changed = false;
  final Set<String> _saving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.apiService.getNoExamRight(widget.courseCode, widget.term, widget.year);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _toggle(Map st, bool allowed) async {
    final sid = '${st['student_id']}';
    setState(() {
      _saving.add(sid);
      st['allowed'] = allowed;
    });
    try {
      await widget.apiService.setExamPermit(widget.courseCode, widget.term, widget.year, sid, allowed);
      _changed = true;
    } catch (e) {
      if (!mounted) return;
      setState(() => st['allowed'] = !allowed);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Colors.red.shade700));
    } finally {
      if (mounted) setState(() => _saving.remove(sid));
    }
  }

  String _num(dynamic v) {
    if (v == null) return '-';
    final d = (v as num).toDouble();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final rows = ((d?['students'] as List?) ?? []).cast<Map>();
    final canEdit = d?['can_edit'] == true;
    final allowed = rows.where((r) => r['allowed'] == true).length;
    final block = (d?['block_ms'] as Map?) ?? {};
    String paperRule(String et, String label) => block[et] == null
        ? '$label: ยังไม่ได้ตั้งข้อสอบ'
        : (block[et] == true ? '$label: นักเรียน มส. สอบไม่ได้ (ยกเว้นที่ติ๊ก)' : '$label: ให้สอบทุกคน');
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.gold, width: 1.5)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
            decoration: const BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('นักเรียนไม่มีสิทธิ์สอบ (มส.) • ${widget.courseCode} ${d?['course_name'] ?? ''}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  if (d != null)
                    Text('${rows.length} คน • อนุญาตให้สอบ $allowed คน • ${d['teacher'] ?? ''}',
                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800)),
                ]),
              ),
              IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context, _changed)),
            ]),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(20), child: Text(_error!))
          else if (d == null)
            const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()))
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                'ติด มส. = เวลาเรียนไม่ถึง 80% (ตามสรุปการมาเรียน) หรือครูกำหนด มส. ในหน้าบันทึกคะแนน\n'
                '${canEdit ? 'ติ๊ก "สอบได้" ให้คนที่อนุญาต • คนที่ไม่ติ๊กจะกดปุ่มสอบวิชานี้ไม่ได้' : 'ครูประจำวิชาเป็นผู้ติ๊กอนุญาต (ท่านดูได้อย่างเดียว)'}\n'
                '${paperRule('midterm', 'กลางภาค')} • ${paperRule('final', 'ปลายภาค')}',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800),
              ),
            ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('ไม่มีนักเรียนติด มส. ในรายวิชานี้ — ทุกคนมีสิทธิ์สอบ', textAlign: TextAlign.center),
              )
            else
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: Colors.grey.shade200),
                  itemBuilder: (context, i) {
                    final st = rows[i];
                    final ok = st['allowed'] == true;
                    final busy = _saving.contains('${st['student_id']}');
                    final pct = st['percentage'];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        SizedBox(width: 30, child: Text('${i + 1}', style: TextStyle(color: Colors.grey.shade700))),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${st['full_name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(
                              '${st['student_id']} • ${st['class_level']}/${st['room']} เลขที่ ${st['student_no'] ?? '-'} • '
                              '${st['by_teacher'] == true ? 'ครูกำหนด มส.' : 'มา ${_num(st['present'])}/${_num(st['total'])} ชม. (ขาด ${_num(st['absent'])} ลา ${_num(st['leave'])}) • ${pct == null ? '-' : '${_num(pct)}%'}'}',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                            ),
                            if (ok && st['allowed_by'] != null)
                              Text('อนุญาตโดย ${st['allowed_by']}', style: const TextStyle(fontSize: 11.5, color: Color(0xFF15803D))),
                          ]),
                        ),
                        if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 6),
                        Text(ok ? 'สอบได้' : 'สอบไม่ได้',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ok ? const Color(0xFF15803D) : Colors.red.shade700)),
                        Checkbox(
                          value: ok,
                          onChanged: canEdit && !busy ? (v) => _toggle(st, v ?? false) : null,
                        ),
                      ]),
                    );
                  },
                ),
              ),
          ],
        ]),
      ),
    );
  }
}
