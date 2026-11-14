import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';

class AttendanceSummaryPdfDialog extends StatefulWidget {
  final ApiService apiService;
  final String initialTerm;
  final String initialYear;
  final String initialMode;

  const AttendanceSummaryPdfDialog({
    super.key,
    required this.apiService,
    required this.initialTerm,
    required this.initialYear,
    required this.initialMode,
  });

  static Future<void> show(
    BuildContext context, {
    required ApiService apiService,
    required String initialTerm,
    required String initialYear,
    required String initialMode,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AttendanceSummaryPdfDialog(
        apiService: apiService,
        initialTerm: initialTerm,
        initialYear: initialYear,
        initialMode: initialMode,
      ),
    );
  }

  @override
  State<AttendanceSummaryPdfDialog> createState() => _AttendanceSummaryPdfDialogState();
}

class _AttendanceSummaryPdfDialogState extends State<AttendanceSummaryPdfDialog> {
  late String _term;
  late String _year;
  late String _mode;
  String _selectedThreshold = 'all'; // 'all', 'under80', 'under60'
  String _selectedClassLevel = 'all'; // 'all', 'ม.1', 'ม.2', ...
  String _evalScope = 'current'; // 'current' or 'full_100'
  String _searchQuery = '';

  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _reportData;
  bool _downloadingPdf = false;

  final List<String> _classLevels = ['all', 'ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'];

  @override
  void initState() {
    super.initState();
    _term = widget.initialTerm;
    _year = widget.initialYear;
    _mode = 'daily'; // Default to daily homeroom attendance per user request
    _fetchSummaryData();
  }

  Future<void> _fetchSummaryData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.apiService.getAttendanceSummaryData(
        term: _term,
        year: _year,
        mode: _mode,
        threshold: _selectedThreshold,
        classLevel: _selectedClassLevel,
        evalScope: _evalScope,
      );
      if (mounted) {
        setState(() {
          _reportData = res;
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

  Future<void> _downloadPdf({bool inline = false}) async {
    setState(() => _downloadingPdf = true);
    try {
      final downloadUrl = widget.apiService.getAttendanceSummaryPdfUrl(
        term: _term,
        year: _year,
        mode: _mode,
        threshold: _selectedThreshold,
        classLevel: _selectedClassLevel,
        evalScope: _evalScope,
        inline: inline,
      );

      final uri = Uri.parse(downloadUrl);
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('เกิดข้อผิดพลาดในการดาวน์โหลด PDF: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _downloadingPdf = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _reportData?['summary'] as Map<String, dynamic>?;
    final List<Map<String, dynamic>> allStudents =
        (_reportData?['students'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final filteredStudents = allStudents.where((s) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      final name = (s['full_name'] ?? '').toString().toLowerCase();
      final sid = (s['student_id'] ?? '').toString().toLowerCase();
      final cl = (s['class_level'] ?? '').toString().toLowerCase();
      return name.contains(q) || sid.contains(q) || cl.contains(q);
    }).toList();

    final int total = (summary?['total_students'] as num?)?.toInt() ?? 0;
    final int passCnt = (summary?['pass_count'] as num?)?.toInt() ?? 0;
    final int warnCnt = (summary?['warning_count'] as num?)?.toInt() ?? 0;
    final int critCnt = (summary?['critical_count'] as num?)?.toInt() ?? 0;
    final double avgPct = (summary?['average_attendance_pct'] as num?)?.toDouble() ?? 100.0;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Header
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
                    child: const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFFACC15), size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'รายงานสรุปเวลาเรียนของนักเรียนทั้งหมด (ประเมินเกณฑ์ 80% และ 60%)',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'ภาคเรียนที่ $_term/$_year • ${widget.apiService.schoolFullName} • หน้าเช็คเวลาเรียน (ประเมินสะสม ${summary?['evaluated_days'] ?? 100} วัน จากเกณฑ์เต็ม ${summary?['full_term_criterion'] ?? 100} วัน)',
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Section A: Executive KPI Metric Cards
                    Row(
                      children: [
                        _buildKpiCard(
                          title: 'นักเรียนทั้งหมด',
                          value: '$total คน',
                          sub: 'เฉลี่ย $avgPct%',
                          color: const Color(0xFF1E293B),
                          bg: const Color(0xFFF8FAFC),
                          borderColor: const Color(0xFFCBD5E1),
                        ),
                        const SizedBox(width: 10),
                        _buildKpiCard(
                          title: 'ผ่านเกณฑ์ (80% ขึ้นไป)',
                          value: '$passCnt คน',
                          sub: '${summary?['pass_pct'] ?? 100}% มีสิทธิ์สอบปกติ',
                          color: const Color(0xFF15803D),
                          bg: const Color(0xFFF0FDF4),
                          borderColor: const Color(0xFFBBF7D0),
                        ),
                        const SizedBox(width: 10),
                        _buildKpiCard(
                          title: 'เสี่ยง มส. (60% – 79.9%)',
                          value: '$warnCnt คน',
                          sub: '${summary?['warning_pct'] ?? 0}% ไม่ถึง 80%',
                          color: const Color(0xFFB45309),
                          bg: const Color(0xFFFFFBEB),
                          borderColor: const Color(0xFFFDE68A),
                        ),
                        const SizedBox(width: 10),
                        _buildKpiCard(
                          title: 'หมดสิทธิ์สอบ (ต่ำกว่า 60%)',
                          value: '$critCnt คน',
                          sub: '${summary?['critical_pct'] ?? 0}% มส. เข้มงวด',
                          color: const Color(0xFFB91C1C),
                          bg: const Color(0xFFFEF2F2),
                          borderColor: const Color(0xFFFECACA),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    // Section B: Filter & Controls Bar
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          // Evaluation Scope Filter (ถึงวันปัจจุบัน vs เต็ม 100 วัน)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('เกณฑ์ประเมิน: ', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                              const SizedBox(width: 6),
                              ChoiceChip(
                                avatar: const Icon(Icons.today_rounded, size: 14),
                                label: Text('ถึงวันปัจจุบัน (${summary?['evaluated_days'] ?? 100} วัน)', style: const TextStyle(fontSize: 12)),
                                selected: _evalScope == 'current',
                                selectedColor: const Color(0xFFDCFCE7),
                                onSelected: (sel) {
                                  if (sel) {
                                    setState(() => _evalScope = 'current');
                                    _fetchSummaryData();
                                  }
                                },
                              ),
                              const SizedBox(width: 6),
                              ChoiceChip(
                                avatar: const Icon(Icons.calendar_month_rounded, size: 14),
                                label: const Text('เกณฑ์เต็ม 100 วันทั้งเทอม', style: TextStyle(fontSize: 12)),
                                selected: _evalScope == 'full_100',
                                selectedColor: const Color(0xFFE0E7FF),
                                onSelected: (sel) {
                                  if (sel) {
                                    setState(() => _evalScope = 'full_100');
                                    _fetchSummaryData();
                                  }
                                },
                              ),
                            ],
                          ),

                          // Threshold Filters
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('คัดกรอง: ', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                              const SizedBox(width: 6),
                              ChoiceChip(
                                label: const Text('ทั้งหมด', style: TextStyle(fontSize: 12)),
                                selected: _selectedThreshold == 'all',
                                onSelected: (sel) {
                                  if (sel) {
                                    setState(() => _selectedThreshold = 'all');
                                    _fetchSummaryData();
                                  }
                                },
                              ),
                              const SizedBox(width: 6),
                              ChoiceChip(
                                label: Text('เสี่ยง มส. <80% ($warnCnt คน)', style: const TextStyle(fontSize: 12)),
                                selected: _selectedThreshold == 'under80',
                                selectedColor: const Color(0xFFFEF3C7),
                                onSelected: (sel) {
                                  if (sel) {
                                    setState(() => _selectedThreshold = 'under80');
                                    _fetchSummaryData();
                                  }
                                },
                              ),
                              const SizedBox(width: 6),
                              ChoiceChip(
                                label: Text('หมดสิทธิ์สอบ <60% ($critCnt คน)', style: const TextStyle(fontSize: 12)),
                                selected: _selectedThreshold == 'under60',
                                selectedColor: const Color(0xFFFEE2E2),
                                onSelected: (sel) {
                                  if (sel) {
                                    setState(() => _selectedThreshold = 'under60');
                                    _fetchSummaryData();
                                  }
                                },
                              ),
                            ],
                          ),

                          // Level Selector
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('ระดับชั้น: ', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                              const SizedBox(width: 6),
                              DropdownButton<String>(
                                value: _selectedClassLevel,
                                isDense: true,
                                style: const TextStyle(fontSize: 13, color: Colors.black87),
                                items: _classLevels.map((lvl) {
                                  return DropdownMenuItem(
                                    value: lvl,
                                    child: Text(lvl == 'all' ? 'ทุกระดับชั้น (ม.1 – ม.6)' : 'ระดับชั้น $lvl'),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _selectedClassLevel = val);
                                    _fetchSummaryData();
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Search input
                    TextField(
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'ค้นหาด้วยชื่อ-สกุล, รหัสนักเรียน หรือระดับชั้น...',
                        hintStyle: const TextStyle(fontSize: 12),
                        prefixIcon: const Icon(Icons.search, size: 16),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        fillColor: Colors.white,
                        filled: true,
                      ),
                      onChanged: (val) => setState(() => _searchQuery = val.trim()),
                    ),

                    const SizedBox(height: 12),

                    // Section C: Table Roster Preview
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: _loading
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(32.0),
                                child: CircularProgressIndicator(),
                              ),
                            )
                          : _error != null
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24.0),
                                    child: Text('เกิดข้อผิดพลาด: $_error', style: const TextStyle(color: Colors.red)),
                                  ),
                                )
                              : filteredStudents.isEmpty
                                  ? const Center(
                                      child: Padding(
                                        padding: EdgeInsets.all(32.0),
                                        child: Text('ไม่พบรายชื่อนักเรียนตามเงื่อนไขที่เลือก', style: TextStyle(color: Colors.grey)),
                                      ),
                                    )
                                  : ConstrainedBox(
                                      constraints: const BoxConstraints(maxHeight: 280),
                                      child: SingleChildScrollView(
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: DataTable(
                                            headingRowHeight: 36,
                                            dataRowMinHeight: 34,
                                            dataRowMaxHeight: 36,
                                            horizontalMargin: 12,
                                            columnSpacing: 18,
                                            headingRowColor: WidgetStateProperty.all(const Color(0xFF1B0B38)),
                                            columns: [
                                              const DataColumn(label: Text('ลำดับ', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('ชั้น/ห้อง', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('เลขที่', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('รหัสนักเรียน', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('ชื่อ - นามสกุล', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              DataColumn(label: Text('เกณฑ์ (${summary?['evaluated_days'] ?? 100} วัน)', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('มา (วัน)', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('ขาด (วัน)', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('ลา (วัน)', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('สาย (วัน)', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('ร้อยละ (%)', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                              const DataColumn(label: Text('ผลการประเมินเวลาเรียน', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white))),
                                            ],
                                            rows: filteredStudents.asMap().entries.map((entry) {
                                              final idx = entry.key + 1;
                                              final s = entry.value;
                                              final String code = s['status_code']?.toString() ?? 'pass';
                                              final double pct = (s['percentage'] as num?)?.toDouble() ?? 100.0;
                                              final String statusText = s['status_text']?.toString() ?? 'ผ่านเกณฑ์';

                                              Color rowBg;
                                              Color fgColor;
                                              if (code == 'critical') {
                                                rowBg = const Color(0xFFFEE2E2);
                                                fgColor = const Color(0xFFB91C1C);
                                              } else if (code == 'warning') {
                                                rowBg = const Color(0xFFFEF3C7);
                                                fgColor = const Color(0xFFB45309);
                                              } else {
                                                rowBg = idx % 2 == 1 ? Colors.white : const Color(0xFFF8FAFC);
                                                fgColor = const Color(0xFF15803D);
                                              }

                                              return DataRow(
                                                color: WidgetStateProperty.all(rowBg),
                                                cells: [
                                                  DataCell(Text('$idx', style: const TextStyle(fontSize: 11.5))),
                                                  DataCell(Text('${s['class_level']}/${s['room']}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
                                                  DataCell(Text('${s['student_no']}', style: const TextStyle(fontSize: 11.5))),
                                                  DataCell(Text('${s['student_id']}', style: const TextStyle(fontSize: 11.5))),
                                                  DataCell(Text('${s['full_name']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                                                  DataCell(Text('${s['total_periods']}', style: const TextStyle(fontSize: 11.5))),
                                                  DataCell(Text('${s['present']}', style: const TextStyle(fontSize: 11.5, color: Colors.teal))),
                                                  DataCell(Text('${s['absent']}', style: TextStyle(fontSize: 11.5, fontWeight: (s['absent'] as num? ?? 0) > 0 ? FontWeight.bold : FontWeight.normal, color: (s['absent'] as num? ?? 0) > 0 ? Colors.red : Colors.grey))),
                                                  DataCell(Text('${s['leave'] ?? 0}', style: const TextStyle(fontSize: 11.5, color: Colors.blueGrey))),
                                                  DataCell(Text('${s['late'] ?? 0}', style: TextStyle(fontSize: 11.5, color: (s['late'] as num? ?? 0) > 0 ? Colors.blue.shade800 : Colors.grey))),
                                                  DataCell(Text('$pct%', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: fgColor))),
                                                  DataCell(
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: fgColor.withValues(alpha: 0.12),
                                                        borderRadius: BorderRadius.circular(4),
                                                      ),
                                                      child: Text(
                                                        statusText,
                                                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: fgColor),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              );
                                            }).toList(),
                                          ),
                                        ),
                                      ),
                                    ),
                    ),
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
                    'แสดง ${filteredStudents.length} จากทั้งหมด $total คน',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade700),
                  ),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.visibility_outlined, size: 16),
                        label: const Text('ดูตัวอย่างในเบราว์เซอร์'),
                        onPressed: _downloadingPdf ? null : () => _downloadPdf(inline: true),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1B0B38),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                        icon: _downloadingPdf
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.file_download_rounded, size: 18),
                        label: Text(
                          _downloadingPdf ? 'กำลังสร้างไฟล์ PDF...' : 'ดาวน์โหลดรายงาน PDF (80% / 60%)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onPressed: _downloadingPdf ? null : () => _downloadPdf(inline: false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required String sub,
    required Color color,
    required Color bg,
    required Color borderColor,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey.shade700)),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text(sub, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}
