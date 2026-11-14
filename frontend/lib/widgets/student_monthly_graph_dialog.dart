import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'student_photo_capture.dart';

class StudentMonthlyGraphDialog extends StatefulWidget {
  final ApiService apiService;
  final String term;
  final String year;
  final String studentId;
  final String studentName;
  final String classLevel;
  final String room;
  final String mode;

  const StudentMonthlyGraphDialog({
    super.key,
    required this.apiService,
    required this.term,
    required this.year,
    required this.studentId,
    required this.studentName,
    required this.classLevel,
    required this.room,
    required this.mode,
  });

  static Future<void> show(
    BuildContext context, {
    required ApiService apiService,
    required String term,
    required String year,
    required String studentId,
    required String studentName,
    required String classLevel,
    required String room,
    required String mode,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StudentMonthlyGraphDialog(
        apiService: apiService,
        term: term,
        year: year,
        studentId: studentId,
        studentName: studentName,
        classLevel: classLevel,
        room: room,
        mode: mode,
      ),
    );
  }

  @override
  State<StudentMonthlyGraphDialog> createState() => _StudentMonthlyGraphDialogState();
}

class _StudentMonthlyGraphDialogState extends State<StudentMonthlyGraphDialog> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _profile; // ข้อมูลพื้นฐาน ผู้ปกครอง และรูป (โหลดพร้อมกันกับสถิติ)
  int? _hoveredBarIndex;

  @override
  void initState() {
    super.initState();
    _fetchDetail();
    _fetchProfile();
  }

  Future<void> _fetchProfile() async {
    try {
      final p = await widget.apiService.getStudentProfile(widget.studentId, term: widget.term, year: widget.year);
      if (mounted) setState(() => _profile = p);
    } catch (_) {
      // the attendance part still works without it
    }
  }

  Future<void> _fetchDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.apiService.getStudentMonthlyAttendance(
        term: widget.term,
        year: widget.year,
        studentId: widget.studentId,
        mode: widget.mode,
      );
      if (mounted) {
        setState(() {
          _data = res;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final student = _data?['student'] as Map<String, dynamic>?;
    final overall = _data?['overall'] as Map<String, dynamic>?;
    final List<Map<String, dynamic>> monthlyTrend =
        (_data?['monthly_trend'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final List<Map<String, dynamic>> absences =
        (_data?['absence_records'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final unit = _data?['unit']?.toString() ?? 'วัน';

    final name = student?['full_name']?.toString() ?? widget.studentName;
    final cl = student?['class_level']?.toString() ?? widget.classLevel;
    final rm = student?['room']?.toString() ?? widget.room;
    final sid = student?['student_id']?.toString() ?? widget.studentId;
    final sno = student?['student_no']?.toString() ?? '';

    final double pct = (overall?['percentage'] as num?)?.toDouble() ?? 100.0;
    final riskText = overall?['risk_text']?.toString() ?? 'ผ่านเกณฑ์เวลาเรียน';
    final notStarted = overall?['risk_status'] == 'not_started'; // nothing to count yet (before the semester)
    final asOf = _data?['as_of']?.toString() ?? '';

    Color statusColor;
    if (notStarted) {
      statusColor = Colors.blueGrey.shade300;
    } else if (pct < 60) {
      statusColor = Colors.red.shade700;
    } else if (pct < 80) {
      statusColor = Colors.orange.shade800;
    } else {
      statusColor = Colors.teal.shade700;
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Header with Golden accent
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
              decoration: const BoxDecoration(
                color: Color(0xFF1B0B38), // Deep Night Purple
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFACC15).withValues(alpha: 0.5)),
                    ),
                    child: const Icon(Icons.bar_chart_rounded, color: Color(0xFFFACC15), size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: const TextStyle(
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: statusColor),
                              ),
                              child: Text(
                                riskText,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                  color: notStarted
                                      ? Colors.white70
                                      : (pct < 80 ? const Color(0xFFFCA5A5) : const Color(0xFF86EFAC)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'ชั้น $cl/$rm ${sno.isNotEmpty ? "• เลขที่ $sno " : ""}• รหัสประจำตัว: $sid • ภาคเรียนที่ ${widget.term}/${widget.year}',
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // 2. Body
            Expanded(
              child: _loading
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('กำลังโหลดสถิติเวลาเรียนรายเดือน...', style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    )
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.error_outline_rounded, color: Colors.red.shade400, size: 40),
                                const SizedBox(height: 8),
                                Text('เกิดข้อผิดพลาด: $_error', style: const TextStyle(color: Colors.red)),
                                const SizedBox(height: 12),
                                ElevatedButton(onPressed: _fetchDetail, child: const Text('ลองใหม่')),
                              ],
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Section 0: photo + basic data + guardian (DMC)
                              if (_profile != null) ...[
                                _buildProfileCard(_profile!),
                                const SizedBox(height: 20),
                              ],

                              // Section A: Overall KPI Chips
                              _buildOverallSummaryCards(overall, unit, asOf),
                              const SizedBox(height: 20),

                              // Section B: Monthly Absent Trend Bar Chart
                              _buildMonthlyAbsentChart(monthlyTrend, unit),
                              const SizedBox(height: 20),

                              // Section C: Monthly Details Table
                              _buildMonthlyTable(monthlyTrend, unit),
                              const SizedBox(height: 20),

                              // Section D: Specific Absence Dates (if any)
                              if (absences.isNotEmpty) ...[
                                _buildAbsencesList(absences),
                                const SizedBox(height: 10),
                              ],
                            ],
                          ),
                        ),
            ),

            // 3. Footer
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'เกณฑ์เวลาเรียนมาตรฐาน: ไม่ต่ำกว่า 80% (ปพ.5) | ต่ำกว่า 60% หมดสิทธิ์สอบ (มส.)',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1B0B38),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('ปิดหน้าต่าง', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // STUDENT PROFILE (photo + DMC data)
  // -------------------------------------------------------------
  Widget _buildProfileCard(Map<String, dynamic> p) {
    final info = Map<String, dynamic>.from((p['info'] as Map?) ?? {});
    final photo = Map<String, dynamic>.from((p['photo'] as Map?) ?? {});
    final canEdit = p['can_edit_photo'] == true;
    String s(dynamic v) => (v ?? '').toString().trim();
    String person(dynamic m, {bool relation = false}) {
      final x = Map<String, dynamic>.from((m as Map?) ?? {});
      final parts = [
        s(x['name']),
        if (relation && s(x['relation']).isNotEmpty) '(${s(x['relation'])})',
        if (s(x['occupation']).isNotEmpty) '• อาชีพ ${s(x['occupation'])}',
      ];
      return s(x['name']).isEmpty ? '' : parts.where((e) => e.isNotEmpty).join(' ');
    }

    final basics = <MapEntry<String, String>>[
      MapEntry('เพศ', s(info['gender'])),
      MapEntry('วันเกิด', s(info['birth_date'])),
      MapEntry('อายุ', s(info['age']).isEmpty ? '' : '${s(info['age'])} ปี'),
      MapEntry('กรุ๊ปเลือด', s(info['blood_group'])),
      MapEntry('น้ำหนัก / ส่วนสูง', [
        if (s(info['weight']).isNotEmpty) '${s(info['weight'])} กก.',
        if (s(info['height']).isNotEmpty) '${s(info['height'])} ซม.',
      ].join(' / ')),
      MapEntry('ศาสนา', s(info['religion'])),
      MapEntry('เชื้อชาติ / สัญชาติ', [s(info['race']), s(info['nationality'])].where((e) => e.isNotEmpty).join(' / ')),
      if (s(info['citizen_id']).isNotEmpty) MapEntry('เลขบัตรประชาชน', s(info['citizen_id'])),
    ].where((e) => e.value.isNotEmpty).toList();
    final family = <MapEntry<String, String>>[
      MapEntry('ผู้ปกครอง', person(info['guardian'], relation: true)),
      MapEntry('บิดา', person(info['father'])),
      MapEntry('มารดา', person(info['mother'])),
      MapEntry('ที่อยู่', s(info['address'])),
    ].where((e) => e.value.isNotEmpty).toList();

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ข้อมูลนักเรียน', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
        const SizedBox(height: 8),
        if (info['has_dmc'] != true)
          Text('ยังไม่มีข้อมูลจาก DMC (นำเข้าได้ที่ เช็คเวลาเรียน › นำเข้า DMC)',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        Wrap(
          spacing: 18,
          runSpacing: 8,
          children: [for (final e in basics) _kv(e.key, e.value, width: 150)],
        ),
        if (family.isNotEmpty) ...[
          const SizedBox(height: 10),
          Divider(height: 1, color: Colors.grey.shade200),
          const SizedBox(height: 10),
          for (final e in family)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 78,
                    child: Text(e.key, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                  ),
                  Expanded(child: Text(e.value, style: const TextStyle(fontSize: 12.5, color: Color(0xFF1E293B)))),
                ],
              ),
            ),
        ],
      ],
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final box = !canEdit
              ? _photoBox(photo, canEdit)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _photoBox(photo, canEdit),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: 120,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          foregroundColor: Colors.purple.shade800,
                          side: BorderSide(color: Colors.purple.shade200),
                        ),
                        // มีรูปแล้ว: แก้ไขรูป = ถ่ายใหม่ / เลือกใหม่ / จัดตำแหน่งรูปเดิม / ลบรูป (กรณีใส่ผิด)
                        icon: Icon(photo['exists'] == true ? Icons.edit_rounded : Icons.add_a_photo_rounded, size: 16),
                        label: Text(photo['exists'] == true ? 'แก้ไขรูป' : 'อัปโหลดรูป',
                            style: const TextStyle(fontSize: 12)),
                        onPressed: photo['exists'] == true ? () => _editPhoto(photo['version']) : _uploadPhoto,
                      ),
                    ),
                  ],
                );
          if (c.maxWidth < 460) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Center(child: box), const SizedBox(height: 12), details],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [box, const SizedBox(width: 18), Expanded(child: details)],
          );
        },
      ),
    );
  }

  Widget _photoBox(Map<String, dynamic> photo, bool canEdit) {
    const w = 120.0, h = 160.0;
    final placeholder = Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_rounded, size: 56, color: Colors.grey.shade400),
          Text('ยังไม่มีรูป', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
        ],
      ),
    );
    if (photo['exists'] != true) return placeholder;
    final url = widget.apiService.studentPhotoUrl(widget.studentId, photo['version']);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openPhoto(url, canEdit, photo['version']),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(url, width: w, height: h, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
        ),
      ),
    );
  }

  Future<void> _uploadPhoto() async {
    final saved = await pickAndUploadStudentPhoto(
      context,
      apiService: widget.apiService,
      studentId: widget.studentId,
      studentName: _profile?['student']?['full_name']?.toString() ?? widget.studentName,
      term: widget.term,
      year: widget.year,
    );
    if (saved == PhotoResult.saved && mounted) _fetchProfile();
  }

  Future<void> _editPhoto(dynamic version) async {
    final changed = await editStudentPhoto(
      context,
      apiService: widget.apiService,
      studentId: widget.studentId,
      studentName: _profile?['student']?['full_name']?.toString() ?? widget.studentName,
      term: widget.term,
      year: widget.year,
      version: version,
    );
    if (changed && mounted) _fetchProfile();
  }

  Future<void> _openPhoto(String url, bool canEdit, dynamic version) async {
    final name = _profile?['student']?['full_name']?.toString() ?? widget.studentName;
    final edit = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(url, width: 330, height: 440, fit: BoxFit.cover),
              ),
              const SizedBox(height: 10),
              Text('$name • ${widget.studentId}', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (canEdit)
                    TextButton.icon(
                      icon: Icon(Icons.edit_rounded, color: Colors.purple.shade800, size: 18),
                      label: Text('แก้ไขรูป', style: TextStyle(color: Colors.purple.shade800)),
                      onPressed: () => Navigator.of(ctx).pop(true),
                    ),
                  TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('ปิด')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (edit == true && mounted) await _editPhoto(version);
  }

  Widget _kv(String label, String value, {double width = 150}) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const SizedBox(height: 1),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B))),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // OVERALL SUMMARY CARDS
  // -------------------------------------------------------------
  static const _thaiShortMonths = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];

  String _thaiDate(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : '${d.day} ${_thaiShortMonths[d.month]} ${d.year + 543}';
  }

  Widget _buildOverallSummaryCards(Map<String, dynamic>? overall, String unit, String asOf) {
    // total_units = school days up to today (what มา/ขาด/ร้อยละ are out of); school_days = the whole semester
    final int tot = (overall?['total_units'] as num?)?.toInt() ?? 100;
    final int schoolDays = (overall?['school_days'] as num?)?.toInt() ?? tot;
    final int pres = (overall?['present'] as num?)?.toInt() ?? 100;
    final int abs = (overall?['absent'] as num?)?.toInt() ?? 0;
    final int lv = (overall?['leave'] as num?)?.toInt() ?? 0;
    final int lt = (overall?['late'] as num?)?.toInt() ?? 0;
    final double pct = (overall?['percentage'] as num?)?.toDouble() ?? 100.0;
    final bool notStarted = overall?['risk_status'] == 'not_started';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'สรุปเวลาเรียนรวมตลอดภาคเรียน',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: notStarted
                      ? const Color(0xFFF1F5F9)
                      : (pct >= 80 ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  notStarted ? 'ยังไม่ได้เช็คเวลาเรียน' : 'ร้อยละเวลาเรียน: $pct%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: notStarted
                        ? const Color(0xFF475569)
                        : (pct >= 80 ? const Color(0xFF15803D) : const Color(0xFFB91C1C)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'นับถึงวันนี้${asOf.isEmpty ? '' : ' (${_thaiDate(asOf)})'} • เรียนไปแล้ว $tot จาก $schoolDays $unit • ไม่นับวันหยุด',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildMiniKpi('เรียนไปแล้ว', '$tot $unit', Colors.blue.shade700, Icons.access_time_rounded),
              const SizedBox(width: 8),
              _buildMiniKpi('มาเรียน', '$pres $unit', Colors.teal.shade700, Icons.check_circle_outline_rounded),
              const SizedBox(width: 8),
              _buildMiniKpi('ขาดเรียน', '$abs $unit', abs > 0 ? Colors.red.shade700 : Colors.grey.shade600, Icons.cancel_outlined),
              const SizedBox(width: 8),
              _buildMiniKpi('ลา', '$lv $unit', Colors.amber.shade800, Icons.event_busy_rounded),
              const SizedBox(width: 8),
              _buildMiniKpi('สาย', '$lt $unit', Colors.orange.shade800, Icons.schedule_rounded),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniKpi(String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: color),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // MONTHLY ABSENT TREND BAR CHART
  // -------------------------------------------------------------
  Widget _buildMonthlyAbsentChart(List<Map<String, dynamic>> monthlyTrend, String unit) {
    if (monthlyTrend.isEmpty) {
      return const SizedBox.shrink();
    }

    // Find maximum absent count for proportional scaling
    int maxAbs = 0;
    for (final m in monthlyTrend) {
      final a = (m['absent'] as num?)?.toInt() ?? 0;
      if (a > maxAbs) maxAbs = a;
    }
    final int chartScale = (maxAbs < 4) ? 5 : (maxAbs + 2);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.show_chart_rounded, size: 18, color: Color(0xFF1B0B38)),
                  SizedBox(width: 8),
                  Text(
                    'กราฟจำนวนขาดเรียนในแต่ละเดือน (Monthly Absence Trend)',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                  ),
                ],
              ),
              Row(
                children: [
                  _buildLegendIndicator('0 $unit (ปกติ)', Colors.teal.shade500),
                  const SizedBox(width: 10),
                  _buildLegendIndicator('1-2 $unit (เตือน)', Colors.amber.shade700),
                  const SizedBox(width: 10),
                  _buildLegendIndicator('3+ $unit (เสี่ยง)', Colors.red.shade600),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Chart Canvas
          SizedBox(
            height: 180,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: monthlyTrend.asMap().entries.map((entry) {
                final idx = entry.key;
                final m = entry.value;
                final int absent = (m['absent'] as num?)?.toInt() ?? 0;
                final String monthName = m['short_name']?.toString() ?? '';
                final String fullName = m['name']?.toString() ?? '';
                final double pct = (m['percentage'] as num?)?.toDouble() ?? 100.0;
                final bool isCurrent = m['is_current'] == true;
                final bool upcoming = m['upcoming'] == true; // not reached yet: nothing checked
                final String tip = upcoming
                    ? '$fullName\nยังไม่ถึง (ยังไม่ได้เช็คเวลาเรียน)'
                    : '$fullName\nขาด: $absent $unit\nมาเรียน: ${m['present']} $unit\nร้อยละ: $pct%'
                        '${isCurrent ? "\nนับถึงวันนี้ ${m['total_units']} จาก ${m['school_days']} $unit" : ""}';

                // Color coding
                Color barColor;
                if (upcoming) {
                  barColor = Colors.grey.shade300;
                } else if (absent == 0) {
                  barColor = Colors.teal.shade400;
                } else if (absent <= 2) {
                  barColor = Colors.amber.shade600;
                } else {
                  barColor = Colors.red.shade600;
                }

                final double barRatio = (absent / chartScale).clamp(0.05, 1.0);
                final isHovered = _hoveredBarIndex == idx;

                return Expanded(
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _hoveredBarIndex = idx),
                    onExit: (_) => setState(() => _hoveredBarIndex = null),
                    child: Tooltip(
                      message: tip,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          // Value label on top
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isHovered
                                  ? barColor
                                  : (absent > 0 ? barColor.withValues(alpha: 0.15) : Colors.transparent),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              upcoming ? '–' : '$absent',
                              style: TextStyle(
                                fontSize: isHovered ? 12 : 11,
                                fontWeight: FontWeight.bold,
                                color: isHovered
                                    ? Colors.white
                                    : (absent > 0 ? barColor : Colors.grey.shade400),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),

                          // Vertical Bar
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: barRatio,
                                widthFactor: 0.45,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  decoration: BoxDecoration(
                                    color: isHovered ? barColor.withValues(alpha: 0.9) : barColor,
                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                                    border: isCurrent
                                        ? Border.all(color: const Color(0xFF1B0B38), width: 1.5)
                                        : null,
                                    boxShadow: isHovered
                                        ? [
                                            BoxShadow(
                                              color: barColor.withValues(alpha: 0.4),
                                              blurRadius: 8,
                                              offset: const Offset(0, -2),
                                            ),
                                          ]
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),

                          // Month Label
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: isCurrent
                                ? BoxDecoration(
                                    color: const Color(0xFF1B0B38),
                                    borderRadius: BorderRadius.circular(4),
                                  )
                                : null,
                            child: Text(
                              monthName,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                                color: isCurrent ? Colors.white : const Color(0xFF475569),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendIndicator(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700)),
      ],
    );
  }

  // -------------------------------------------------------------
  // MONTHLY BREAKDOWN TABLE
  // -------------------------------------------------------------
  Widget _buildMonthlyTable(List<Map<String, dynamic>> monthlyTrend, String unit) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: const Text(
              'ตารางแจกแจงสถิติเวลาเรียนรายเดือน',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 36,
              dataRowMinHeight: 34,
              dataRowMaxHeight: 38,
              horizontalMargin: 16,
              columnSpacing: 24,
              columns: const [
                DataColumn(label: Text('เดือน', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
                DataColumn(label: Text('มาเรียน', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
                DataColumn(label: Text('ขาดเรียน', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
                DataColumn(label: Text('ลา', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
                DataColumn(label: Text('สาย', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
                DataColumn(label: Text('ร้อยละ (%)', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
                DataColumn(label: Text('สถานะ', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
              ],
              rows: monthlyTrend.map((m) {
                final int a = (m['absent'] as num?)?.toInt() ?? 0;
                final int p = (m['present'] as num?)?.toInt() ?? 0;
                final int lv = (m['leave'] as num?)?.toInt() ?? 0;
                final int lt = (m['late'] as num?)?.toInt() ?? 0;
                final double pct = (m['percentage'] as num?)?.toDouble() ?? 100.0;
                final bool isCurrent = m['is_current'] == true;
                // a month not reached yet: nothing has been checked, so 0 / 0% (not 100%) and a grey "ยังไม่ถึง"
                final bool upcoming = m['upcoming'] == true;
                final bool noSchool = !upcoming && ((m['school_days'] as num?)?.toInt() ?? 1) == 0; // holidays only
                final bool idle = upcoming || noSchool;
                final Color dim = Colors.grey.shade500;

                Color pctCol = idle
                    ? dim
                    : (pct >= 80 ? Colors.teal.shade800 : (pct >= 60 ? Colors.orange.shade800 : Colors.red.shade700));
                final String statusText = upcoming
                    ? 'ยังไม่ถึง'
                    : noSchool
                        ? 'ไม่มีวันเรียน'
                        : (pct >= 80 ? 'ปกติ' : (pct >= 60 ? 'เฝ้าระวัง' : 'เสี่ยงสูง'));
                final Color statusBg = idle
                    ? const Color(0xFFF1F5F9)
                    : (pct >= 80 ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2));
                final Color statusFg = idle
                    ? const Color(0xFF64748B)
                    : (pct >= 80 ? const Color(0xFF15803D) : const Color(0xFFB91C1C));

                return DataRow(
                  color: isCurrent ? WidgetStateProperty.all(const Color(0xFFEFF6FF)) : null,
                  cells: [
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(m['name']?.toString() ?? '', style: TextStyle(fontSize: 12, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                          if (isCurrent) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(color: const Color(0xFF2563EB), borderRadius: BorderRadius.circular(4)),
                              child: const Text('เดือนนี้', style: TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    DataCell(Text('$p $unit', style: TextStyle(fontSize: 12, color: idle ? dim : Colors.teal))),
                    DataCell(
                      Text(
                        '$a $unit',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: a > 0 ? FontWeight.bold : FontWeight.normal,
                          color: a > 0 ? Colors.red.shade700 : (idle ? dim : Colors.grey.shade600),
                        ),
                      ),
                    ),
                    DataCell(Text('$lv $unit', style: TextStyle(fontSize: 12, color: idle ? dim : null))),
                    DataCell(Text('$lt $unit', style: TextStyle(fontSize: 12, color: idle ? dim : null))),
                    DataCell(Text(noSchool ? '–' : '$pct%',
                        style: TextStyle(fontSize: 12, fontWeight: idle ? FontWeight.normal : FontWeight.bold, color: pctCol))),
                    DataCell(
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: statusBg,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          statusText,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: statusFg,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
            child: Text(
              'เดือนนี้นับถึงวันนี้ • เดือนที่ยังไม่ถึงเป็น 0% เพราะยังไม่ได้เช็คเวลาเรียน • ไม่นับวันหยุด • '
              'วันที่ไม่ได้เช็คชื่อนับเป็นขาด (เหมือนหน้าเช็คเวลาเรียน)',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // SPECIFIC ABSENCES LIST (IF ANY)
  // -------------------------------------------------------------
  Widget _buildAbsencesList(List<Map<String, dynamic>> absences) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        leading: Icon(Icons.event_busy_rounded, color: Colors.red.shade700, size: 20),
        title: Text(
          'รายการบันทึกการขาด/ลาในระบบ (${absences.length} รายการ)',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.red.shade900),
        ),
        subtitle: const Text('คลิกเพื่อดูรายละเอียดวันที่และรหัสวิชาที่ขาดเรียน', style: TextStyle(fontSize: 11, color: Colors.black54)),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: absences.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (ctx, idx) {
                final it = absences[idx];
                final dt = it['date']?.toString() ?? '';
                final ccode = it['course_code']?.toString() ?? '';
                final stText = it['status_text']?.toString() ?? 'ขาดเรียน';
                final st = it['status']?.toString() ?? 'absent';
                // ขาด = red, ลา = amber, a school day nobody checked (counted as ขาด) = grey
                final MaterialColor tone = st == 'leave' ? Colors.amber : (st == 'unchecked' ? Colors.blueGrey : Colors.red);

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: tone.shade100,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(stText, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: tone.shade900)),
                      ),
                      const SizedBox(width: 10),
                      Text('วันที่ $dt', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      if (ccode.isNotEmpty)
                        Text('วิชา $ccode', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
