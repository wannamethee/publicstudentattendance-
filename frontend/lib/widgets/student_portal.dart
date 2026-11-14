import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../utils/app_theme.dart';
import 'student_exams.dart';
import 'student_quizzes.dart';
import 'student_timetable.dart';

/// Home screen for a logged-in นักเรียน: own attendance only. Opens the attendance popup on arrival.
class StudentPortalScreen extends StatefulWidget {
  final ApiService apiService;
  const StudentPortalScreen({super.key, required this.apiService});

  @override
  State<StudentPortalScreen> createState() => _StudentPortalScreenState();
}

class _StudentPortalScreenState extends State<StudentPortalScreen> {
  int _openQuizzes = 0; // แบบทดสอบย่อยที่ทำได้ตอนนี้ (ป้ายบนปุ่ม)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) StudentAttendanceDialog.show(context, apiService: widget.apiService);
    });
    _countQuizzes();
  }

  Future<void> _countQuizzes() async {
    try {
      final d = await widget.apiService.getStudentQuizzes();
      var n = 0;
      for (final c in (d['courses'] as List? ?? [])) {
        for (final q in ((c as Map)['quizzes'] as List? ?? [])) {
          if ((q as Map)['is_open'] == true && q['can_start'] == true && q['best'] == null) n++;
        }
      }
      if (mounted) setState(() => _openQuizzes = n);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.apiService.currentUser;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.school_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(user?.name ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('รหัสประจำตัว ${user?.code ?? ''}', style: TextStyle(color: Colors.grey.shade700)),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('ดูการมาเรียนของฉัน'),
              onPressed: () => StudentAttendanceDialog.show(context, apiService: widget.apiService),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.quiz_outlined),
              label: const Text('ข้อสอบของฉัน (กลางภาค / ปลายภาค)'),
              onPressed: () => StudentExamsPage.open(context, widget.apiService),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: Badge(
                isLabelVisible: _openQuizzes > 0,
                label: Text('$_openQuizzes'),
                child: const Icon(Icons.assignment_outlined),
              ),
              label: Text(_openQuizzes > 0 ? 'แบบทดสอบย่อย (เปิดอยู่ $_openQuizzes ชุด)' : 'แบบทดสอบย่อย / หลังเรียน'),
              onPressed: () async {
                await StudentQuizzesPage.open(context, widget.apiService);
                _countQuizzes();
              },
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_view_week_outlined),
              label: const Text('ตารางเรียนของชั้นฉัน'),
              onPressed: () => StudentTimetableDialog.show(context, widget.apiService),
            ),
          ],
        ),
      ),
    );
  }
}

/// Popup dashboard: summary, absent/leave/late days, daily check-in table and per-course attendance.
class StudentAttendanceDialog extends StatelessWidget {
  final ApiService apiService;
  const StudentAttendanceDialog({super.key, required this.apiService});

  static Future<void> show(BuildContext context, {required ApiService apiService}) {
    return showDialog(context: context, builder: (_) => StudentAttendanceDialog(apiService: apiService));
  }

  static const _statusColors = {
    'มา': Color(0xFF15803D),
    'สาย': Color(0xFFB45309),
    'ลา': Color(0xFF1D4ED8),
    'ขาด': Color(0xFFB91C1C),
  };

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.gold, width: 1.5),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 820),
        child: FutureBuilder<Map<String, dynamic>>(
          future: apiService.getStudentPortal(),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
            }
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(snap.error.toString().replaceFirst('Exception: ', ''), textAlign: TextAlign.center),
              );
            }
            return _content(context, snap.data!);
          },
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Map<String, dynamic> d) {
    final st = Map<String, dynamic>.from(d['student'] as Map);
    final sum = Map<String, dynamic>.from(d['summary'] as Map);
    final days = (d['days'] as List).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList().reversed.toList();
    final courses = (d['courses'] as List).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final missed = [
      ...(d['absent_dates'] as List).cast<Map>(),
      ...(d['leave_dates'] as List).cast<Map>(),
      ...(d['late_dates'] as List).cast<Map>(),
    ].map((e) => Map<String, dynamic>.from(e)).toList()
      ..sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
    final pct = (sum['percentage'] as num).toDouble();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 12),
          decoration: const BoxDecoration(
            color: AppColors.goldLight,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Row(
            children: [
              if (st['photo_version'] != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    apiService.studentPortalPhotoUrl(st['photo_version']),
                    width: 54,
                    height: 72,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(width: 54, height: 72),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('การมาเรียนของฉัน', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('${st['full_name']} • ${st['class_level']}/${st['room']} เลขที่ ${st['student_no']} • ภาคเรียน ${st['term']}/${st['year']}',
                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800)),
                    Text('ข้อมูลถึงวันที่ ${d['as_of']}', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
                  ],
                ),
              ),
              IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            padding: const EdgeInsets.all(14),
            shrinkWrap: true,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _stat('มาเรียน', '${sum['present']}', 'วัน', _statusColors['มา']!),
                  _stat('สาย', '${sum['late']}', 'วัน', _statusColors['สาย']!),
                  _stat('ลา', '${sum['leave']}', 'วัน', _statusColors['ลา']!),
                  _stat('ขาด', '${sum['absent']}', 'วัน', _statusColors['ขาด']!),
                  _stat('ร้อยละ', pct.toStringAsFixed(1), '%', pct >= 80 ? _statusColors['มา']! : _statusColors['ขาด']!),
                ],
              ),
              const SizedBox(height: 6),
              Text('นับจากวันเรียนที่ผ่านมาแล้ว ${sum['school_days']} วัน (ไม่นับวันหยุด) • เกณฑ์มีสิทธิ์สอบ 80%',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
              const SizedBox(height: 14),
              _title('วันที่ขาด / ลา / สาย'),
              if (missed.isEmpty)
                Text('ไม่มี — มาเรียนครบทุกวัน', style: TextStyle(color: _statusColors['มา']))
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: missed.map((m) => _chip('${m['weekday']} ${_thaiDate(m['date'])}', m['status'])).toList(),
                ),
              const SizedBox(height: 14),
              _title('ตารางการเช็คชื่อ'),
              Table(
                columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(2), 2: FlexColumnWidth(1.4)},
                border: TableBorder.symmetric(inside: BorderSide(color: Colors.grey.shade200)),
                children: [
                  _row(['วันที่', 'วัน', 'สถานะ'], header: true),
                  ...days.map((x) => TableRow(children: [
                        _cell(_thaiDate(x['date'])),
                        _cell(x['weekday']),
                        Padding(padding: const EdgeInsets.all(4), child: _chip(x['status'], x['status'])),
                      ])),
                ],
              ),
              const SizedBox(height: 14),
              _title('เวลาเรียนรายวิชา (ถึงวันนี้)'),
              Table(
                columnWidths: const {0: FlexColumnWidth(3.4), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1.2)},
                border: TableBorder.symmetric(inside: BorderSide(color: Colors.grey.shade200)),
                children: [
                  _row(['รายวิชา', 'มา', 'ขาด', 'ร้อยละ'], header: true),
                  ...courses.map((c) {
                    final p = (c['percentage'] as num).toDouble();
                    return TableRow(children: [
                      _cell('${c['course_code']} ${c['course_name'] ?? ''}'),
                      _cell('${c['present_count']}/${c['elapsed_periods']}'),
                      _cell('${c['absent_count']}'),
                      _cell(p.toStringAsFixed(1), color: p >= 80 ? null : _statusColors['ขาด']),
                    ]);
                  }),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _thaiMonths = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];

  static String _thaiDate(dynamic iso) {
    final dt = DateTime.tryParse(iso.toString());
    if (dt == null) return iso.toString();
    return '${dt.day} ${_thaiMonths[dt.month]} ${(dt.year + 543) % 100}';
  }

  Widget _stat(String label, String value, String unit, Color color) {
    return Container(
      width: 112,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          Text('$value $unit', style: TextStyle(fontSize: 20, color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _chip(String text, dynamic status) {
    final color = _statusColors[status] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold)),
      );

  TableRow _row(List<String> cells, {bool header = false}) => TableRow(
        decoration: header ? BoxDecoration(color: Colors.grey.shade100) : null,
        children: cells.map((c) => _cell(c, bold: header)).toList(),
      );

  Widget _cell(dynamic text, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Text('$text', style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.bold : null, color: color)),
      );
}
