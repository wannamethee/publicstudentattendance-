import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../models/school_theme_config.dart';
import '../widgets/teacher_attendance_grid.dart';

class LeaveScreen extends StatefulWidget {
  final ApiService apiService;

  const LeaveScreen({
    super.key,
    required this.apiService,
  });

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  // 0: ตารางลงเวลาครู, 1: สถิติและประวัติการลาของฉัน, 2: รายการลาครูทุกคน & พิมพ์รายงาน
  int _currentView = 0;

  bool _isLoading = false;
  List<Map<String, dynamic>> _myLeaves = [];
  String? _errorMessage;

  // ตารางลงเวลาครู (GET /api/v1/leaves/attendance-grid)
  Map<String, dynamic>? _grid;
  bool _gridLoading = false;
  String? _gridError;
  int? _weekRange; // null = ช่วงที่มีวันนี้, 1 = สัปดาห์ 1-10, 2 = 11-20, 0 = ทั้งหมด

  // รายชื่อครูสำหรับตัวกรองในหน้ารายการลา
  List<Map<String, dynamic>> _allTeachers = [];

  // View 2: รายการลาของครูทุกคน (หัวหน้างานบุคคล ผู้ดูแลระบบ ผู้อำนวยการ)
  List<Map<String, dynamic>> _allLeaves = [];
  bool _isLoadingAllLeaves = false;
  String _selectedFilterTeacherCode = 'all'; // 'all' or teacher code
  String _allLeavesSearchQuery = '';

  /// ลงข้อมูลแทนครูคนอื่นได้: หัวหน้างานบุคคล / ผู้ดูแลระบบ
  bool get _canEditOthers => widget.apiService.isPersonnelHead || widget.apiService.isAdmin;

  /// เห็นครูทุกคน: หัวหน้างานบุคคล ผู้ดูแลระบบ และผู้อำนวยการ (ดูได้อย่างเดียว)
  bool get _seeAll => _canEditOthers || widget.apiService.isDirector;

  @override
  void initState() {
    super.initState();
    _loadGrid();
    _loadMyLeaves();
    if (_seeAll) {
      _loadAllTeachers();
      _loadAllLeaves();
    }
  }

  Future<void> _loadMyLeaves() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final leaves = await widget.apiService.getMyLeaves();
      if (mounted) {
        setState(() {
          _myLeaves = leaves;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadAllTeachers() async {
    try {
      final summary = await widget.apiService.getLeavesSummaryByTeacher();
      if (mounted) {
        setState(() {
          _allTeachers = summary;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadAllLeaves() async {
    setState(() => _isLoadingAllLeaves = true);
    try {
      final leaves = await widget.apiService.getAllLeaves();
      if (mounted) {
        setState(() {
          _allLeaves = leaves;
          _isLoadingAllLeaves = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingAllLeaves = false);
      }
    }
  }

  int _calculateDays(DateTime start, DateTime end) {
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    if (e.isBefore(s)) return 1;
    return e.difference(s).inDays + 1;
  }

  Future<void> _deleteLeave(int id, String type) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ยืนยันการยกเลิก'),
        content: Text('คุณต้องการยกเลิกคำขอ$typeนี้ใช่หรือไม่?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ไม่ยกเลิก'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ยืนยันยกเลิก'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await widget.apiService.deleteLeave(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF15803D),
            content: Text('ยกเลิกคำขอเรียบร้อยแล้ว'),
          ),
        );
        _reloadAll();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('ยกเลิกไม่สำเร็จ: $e'),
          ),
        );
      }
    }
  }

  Future<void> _printLeaveReport() async {
    final url = '${widget.apiService.baseUrl}/api/v1/leaves/report-print?teacher_code=$_selectedFilterTeacherCode';
    final uri = Uri.parse(url);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('ไม่สามารถเปิดหน้าพิมพ์รายงานได้: $e'),
          ),
        );
      }
    }
  }

  /// ฟอร์มเดิม (ประเภท วันที่ เวลา เหตุผล เบอร์โทร) เป็นป๊อปอัพ: แก้ไขรายการ หรือ create = บันทึกใหม่จากตาราง
  /// คืนค่า true เมื่อบันทึกสำเร็จ
  Future<bool> _showLeaveFormDialog(Map<String, dynamic> item, {bool create = false, List<String>? types}) async {
    final leaveId = item['id'] as int? ?? 0;
    final teacherName = item['teacher_name']?.toString() ?? '';
    String editType = item['leave_type']?.toString() ?? 'ลากิจ';
    DateTime editStartDate = DateTime.tryParse(item['start_date']?.toString() ?? '') ?? DateTime.now();
    DateTime editEndDate = DateTime.tryParse(item['end_date']?.toString() ?? '') ?? editStartDate;

    TimeOfDay editTime = const TimeOfDay(hour: 9, minute: 0);
    final rawTime = item['expected_arrival_time']?.toString() ?? item['late_time']?.toString();
    if (rawTime != null && rawTime.contains(':')) {
      final parts = rawTime.split(':');
      editTime = TimeOfDay(hour: int.tryParse(parts[0]) ?? 9, minute: int.tryParse(parts[1]) ?? 0);
    }

    final editReasonController = TextEditingController(text: item['reason']?.toString() ?? '');
    final editPhoneController = TextEditingController(text: item['contact_phone']?.toString() ?? item['phone']?.toString() ?? '');
    bool isSaving = false;
    bool saved = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final days = _calculateDays(editStartDate, editEndDate);

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.edit_note_rounded, color: Color(0xFFD97706), size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      create
                          ? '${editType == 'ขอเข้าสาย' ? 'ขอเข้าสาย' : 'บันทึกการลา'}: $teacherName'
                          : 'แก้ไขรายการลาของ: $teacherName',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('ประเภทการลา:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        children: (types ?? const ['ลากิจ', 'ลาป่วย', 'ขอเข้าสาย']).map((type) {
                          final isSel = editType == type;
                          return ChoiceChip(
                            label: Text(type),
                            selected: isSel,
                            selectedColor: _getTypeColor(type),
                            labelStyle: TextStyle(
                              color: isSel ? Colors.white : const Color(0xFF1E293B),
                              fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                            ),
                            onSelected: (val) {
                              if (val) setDialogState(() => editType = type);
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 14),

                      if (editType == 'ขอเข้าสาย') ...[
                        const Text('วันที่ขอเข้าสาย:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: editStartDate,
                              firstDate: DateTime.now().subtract(const Duration(days: 365)),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null) {
                              setDialogState(() {
                                editStartDate = picked;
                                editEndDate = picked;
                              });
                            }
                          },
                          icon: const Icon(Icons.calendar_today_rounded, size: 16),
                          label: Text(_formatThaiDate(DateFormat('yyyy-MM-dd').format(editStartDate))),
                        ),
                        const SizedBox(height: 10),
                        const Text('เวลาที่คาดว่าจะมาถึง:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await showTimePicker(
                              context: context,
                              builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
                              initialTime: editTime,
                            );
                            if (picked != null) {
                              setDialogState(() => editTime = picked);
                            }
                          },
                          icon: const Icon(Icons.alarm_rounded, size: 16),
                          label: Text('${editTime.hour.toString().padLeft(2, '0')}:${editTime.minute.toString().padLeft(2, '0')} น.'),
                        ),
                      ] else ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('ช่วงวันที่ลา:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text('1 ครั้ง ($days วัน)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: editStartDate,
                                    firstDate: DateTime.now().subtract(const Duration(days: 365)),
                                    lastDate: DateTime.now().add(const Duration(days: 365)),
                                  );
                                  if (picked != null) {
                                    setDialogState(() {
                                      editStartDate = picked;
                                      if (editEndDate.isBefore(editStartDate)) {
                                        editEndDate = editStartDate;
                                      }
                                    });
                                  }
                                },
                                child: Text('เริ่ม: ${_formatThaiDate(DateFormat('yyyy-MM-dd').format(editStartDate))}'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: editEndDate.isBefore(editStartDate) ? editStartDate : editEndDate,
                                    firstDate: editStartDate,
                                    lastDate: DateTime.now().add(const Duration(days: 365)),
                                  );
                                  if (picked != null) {
                                    setDialogState(() => editEndDate = picked);
                                  }
                                },
                                child: Text('ถึง: ${_formatThaiDate(DateFormat('yyyy-MM-dd').format(editEndDate))}'),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 14),

                      const Text('เหตุผลการลา / ขอเข้าสาย:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: editReasonController,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: 'ระบุเหตุผล...',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          contentPadding: const EdgeInsets.all(10),
                        ),
                      ),
                      const SizedBox(height: 12),

                      const Text('เบอร์โทรศัพท์ติดต่อ (ถ้ามี):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: editPhoneController,
                        decoration: InputDecoration(
                          hintText: 'เบอร์โทร...',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  child: const Text('ยกเลิก'),
                ),
                FilledButton.icon(
                  onPressed: isSaving ? null : () async {
                    if (editReasonController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('กรุณาระบุเหตุผล')),
                      );
                      return;
                    }
                    setDialogState(() => isSaving = true);
                    try {
                      final timeStr = '${editTime.hour.toString().padLeft(2, '0')}:${editTime.minute.toString().padLeft(2, '0')}';
                      final sStr = DateFormat('yyyy-MM-dd').format(editStartDate);
                      final eStr = DateFormat('yyyy-MM-dd').format(editEndDate);

                      if (create) {
                        final phone = editPhoneController.text.trim();
                        await widget.apiService.createLeave(
                          leaveType: editType,
                          startDate: sStr,
                          endDate: editType == 'ขอเข้าสาย' ? sStr : eStr,
                          expectedArrivalTime: editType == 'ขอเข้าสาย' ? timeStr : null,
                          reason: editReasonController.text.trim(),
                          contactPhone: phone.isEmpty ? null : phone,
                          teacherCode: item['teacher_code']?.toString(),
                          teacherName: item['teacher_name']?.toString(),
                        );
                      } else {
                        await widget.apiService.updateLeave(
                          leaveId,
                          leaveType: editType,
                          startDate: sStr,
                          endDate: editType == 'ขอเข้าสาย' ? sStr : eStr,
                          expectedArrivalTime: editType == 'ขอเข้าสาย' ? timeStr : null,
                          reason: editReasonController.text.trim(),
                          contactPhone: editPhoneController.text.trim(),
                        );
                      }
                      saved = true;
                      if (mounted) {
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: const Color(0xFF15803D),
                            content: Text(create ? 'บันทึก$editTypeของ $teacherName เรียบร้อยแล้ว' : 'แก้ไขข้อมูลเรียบร้อยแล้ว'),
                          ),
                        );
                        _reloadAll();
                      }
                    } catch (e) {
                      setDialogState(() => isSaving = false);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: Colors.red.shade700,
                            content: Text('${create ? 'บันทึก' : 'แก้ไข'}ไม่สำเร็จ: ${e.toString().replaceFirst('Exception: ', '')}'),
                          ),
                        );
                      }
                    }
                  },
                  icon: isSaving
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.save_rounded, size: 16),
                  label: Text(create ? 'บันทึก' : 'บันทึกการแก้ไข'),
                ),
              ],
            );
          },
        );
      },
    );
    return saved;
  }

  Color _getTypeColor(String type) {
    switch (type) {
      case 'ลากิจ':
        return const Color(0xFFD97706); // Amber
      case 'ลาป่วย':
        return const Color(0xFF059669); // Emerald
      case 'ขอเข้าสาย':
        return const Color(0xFF2563EB); // Royal Blue
      default:
        return Colors.grey.shade700;
    }
  }

  IconData _getTypeIcon(String type) {
    switch (type) {
      case 'ลากิจ':
        return Icons.business_center_rounded;
      case 'ลาป่วย':
        return Icons.healing_rounded;
      case 'ขอเข้าสาย':
        return Icons.access_time_filled_rounded;
      default:
        return Icons.event_note_rounded;
    }
  }

  String _formatThaiDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '-';
    try {
      final d = DateTime.parse(dateStr);
      final thaiMonths = [
        '', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.',
        'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'
      ];
      final thaiYear = d.year + 543;
      return '${d.day} ${thaiMonths[d.month]} $thaiYear';
    } catch (_) {
      return dateStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.apiService.currentUser;
    final isPersonnelHead = _canEditOthers;
    final isDirector = widget.apiService.isDirector && !_canEditOthers;
    final narrow = MediaQuery.of(context).size.width < 700;

    return ValueListenableBuilder<SchoolThemeConfig>(
      valueListenable: widget.apiService.themeNotifier,
      builder: (context, theme, _) {
        final primaryColor = theme.primaryColor;

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          body: Column(
            children: [
              // 1. PAGE HEADER
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: isPersonnelHead ? const Color(0xFF16A34A).withValues(alpha: 0.12) : primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        isPersonnelHead ? Icons.manage_accounts_rounded : Icons.calendar_month_rounded,
                        color: isPersonnelHead ? const Color(0xFF16A34A) : primaryColor,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'ลงเวลาครู & บันทึกการลา',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              if (isPersonnelHead) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: const Color(0xFF16A34A)),
                                  ),
                                  child: const Text(
                                    'หัวหน้าบุคคล',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF15803D),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          Text(
                            isPersonnelHead
                                ? 'ผู้ใช้งาน: ${user?.name ?? "หัวหน้าบุคคล"} (สิทธิ์หัวหน้าบุคคล: สามารถบันทึกแทนครูทุกคนและพิมพ์รายงานได้)'
                                : isDirector
                                    ? 'ผู้อำนวยการ: ดูภาพรวมการมาของครูและรายบุคคลได้ (แก้ไขไม่ได้)'
                                    : 'ตารางลงเวลา การลากิจ ลาป่วย และการขอเข้าสายของครู',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 2. PRIMARY BUTTONS TOGGLE
              Container(
                color: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: narrow ? 10 : 24, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildTopNavButton(
                        index: 0,
                        icon: Icons.fact_check_rounded,
                        label: 'ตารางลงเวลาครู',
                        sublabel: _seeAll ? 'ภาพรวมการมาของครูทุกคนและรายบุคคล' : 'มา สาย ลา ของฉัน • แตะวันเพื่อขอลา/ขอเข้าสาย',
                        primaryColor: primaryColor,
                      ),
                    ),
                    if (!isDirector) ...[
                      SizedBox(width: narrow ? 8 : 14),
                      Expanded(
                        child: _buildTopNavButton(
                          index: 1,
                          icon: Icons.query_stats_rounded,
                          label: 'สถิติวันลาของฉัน',
                          sublabel: 'สถิติวันลาสะสมและประวัติส่วนตัว',
                          primaryColor: primaryColor,
                        ),
                      ),
                    ],
                    if (_seeAll) ...[
                      SizedBox(width: narrow ? 8 : 14),
                      Expanded(
                        child: _buildTopNavButton(
                          index: 2,
                          icon: Icons.manage_accounts_rounded,
                          label: isPersonnelHead ? 'จัดการรายการลา & พิมพ์รายงาน' : 'รายการลา & พิมพ์รายงาน',
                          sublabel: isPersonnelHead ? 'แก้ไขคำขอลาแทนครู และพิมพ์รายงานสรุป' : 'ดูรายการลาของครูทุกคน และพิมพ์รายงาน',
                          primaryColor: const Color(0xFF15803D),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),

              // 3. MAIN BODY
              Expanded(
                child: _currentView == 0
                    ? _buildAttendanceGridView(primaryColor)
                    : _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _errorMessage != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.error_outline_rounded, size: 48, color: Colors.red.shade400),
                                  const SizedBox(height: 12),
                                  Text(_errorMessage!, style: const TextStyle(fontSize: 16)),
                                  const SizedBox(height: 16),
                                  FilledButton(onPressed: _loadMyLeaves, child: const Text('ลองใหม่')),
                                ],
                              ),
                            ),
                          )
                        : _currentView == 1
                            ? _buildStatsAndHistoryView(primaryColor)
                            : _buildPersonnelHeadManagementView(primaryColor),
              ),
            ],
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------
  // VIEW 0: ตารางลงเวลาครู (/ มา อัตโนมัติ 06:00, ส, ขส, ล, ร)
  // -------------------------------------------------------------
  Future<void> _loadGrid() async {
    setState(() {
      _gridLoading = true;
      _gridError = null;
    });
    try {
      var sem = widget.apiService.defaultSemesterNotifier.value;
      if (sem == null) {
        await widget.apiService.getSemesterConfigs();
        sem = widget.apiService.defaultSemesterNotifier.value;
      }
      if (sem == null) throw Exception('ยังไม่ได้ตั้งค่าภาคเรียน');
      final data = await widget.apiService.getTeacherAttendanceGrid(term: sem.term, year: sem.year);
      if (mounted) {
        setState(() {
          _grid = data;
          _gridLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _gridError = e.toString().replaceFirst('Exception: ', '');
          _gridLoading = false;
        });
      }
    }
  }

  /// หลังบันทึก / แก้ไข / ลบ: โหลดทุกส่วนที่ใช้ข้อมูลการลาใหม่
  void _reloadAll() {
    _loadMyLeaves();
    if (_seeAll) _loadAllLeaves();
    _loadGrid();
  }

  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: ok ? const Color(0xFF15803D) : const Color(0xFFB91C1C),
    ));
  }

  Future<void> _setMark(Map<String, dynamic> row, String date, String status) async {
    final g = _grid;
    if (g == null) return;
    try {
      await widget.apiService.setTeacherAttendanceMark(
        term: g['term'].toString(),
        year: g['year'].toString(),
        teacherCode: row['teacher_code'].toString(),
        date: date,
        status: status,
      );
      _toast(status.isEmpty
          ? 'บันทึก ${row['teacher_name']} วันที่ ${thaiShortDate(date)} เป็น มา แล้ว'
          : 'บันทึก ${row['teacher_name']} วันที่ ${thaiShortDate(date)} เป็น ${TeacherMark.label[status]} ($status) แล้ว');
      await _loadGrid();
    } catch (e) {
      _toast('บันทึกไม่สำเร็จ: ${e.toString().replaceFirst('Exception: ', '')}', ok: false);
    }
  }

  /// รายการลาเต็ม (มีเหตุผล เบอร์โทร) จากรายการที่โหลดไว้; ไม่เจอให้โหลดใหม่หนึ่งครั้ง
  Future<Map<String, dynamic>?> _leaveFull(dynamic id) async {
    Map<String, dynamic>? find() {
      for (final l in [..._allLeaves, ..._myLeaves]) {
        if (l['id'] == id) return l;
      }
      return null;
    }

    final hit = find();
    if (hit != null) return hit;
    await _loadMyLeaves();
    if (_seeAll) await _loadAllLeaves();
    return find();
  }

  /// เปิดฟอร์มเดิม (ป๊อปอัพ) เพื่อบันทึก ขส หรือ ล ของครูในแถวนั้น เริ่มที่วันที่แตะ
  Future<void> _requestFromGrid(Map<String, dynamic> row, String date, String symbol) async {
    await _showLeaveFormDialog({
      'teacher_code': row['teacher_code'],
      'teacher_name': row['teacher_name'],
      'leave_type': symbol == 'ขส' ? 'ขอเข้าสาย' : 'ลากิจ',
      'start_date': date,
      'end_date': date,
    }, create: true, types: symbol == 'ขส' ? const ['ขอเข้าสาย'] : const ['ลากิจ', 'ลาป่วย']);
  }

  Future<void> _editFromGrid(dynamic leaveId) async {
    final full = await _leaveFull(leaveId);
    if (full == null) {
      _toast('ไม่พบรายการลานี้ กรุณารีเฟรช', ok: false);
      return;
    }
    await _showLeaveFormDialog(full);
  }

  Future<void> _onGridCellTap(Map<String, dynamic> row, int slot) async {
    final g = _grid;
    if (g == null) return;
    final dates = (g['dates'] as List).map((e) => e.toString()).toList();
    final date = dates[slot];
    final isFuture = date.compareTo(g['today']?.toString() ?? '') > 0;
    final status = ((row['status_list'] as List)[slot] ?? '').toString();
    final infoRaw = (row['info'] as List)[slot];
    final info = infoRaw is Map ? Map<String, dynamic>.from(infoRaw) : null;
    final canEdit = g['can_edit'] == true;
    final isMine = row['teacher_code'].toString() == (g['my_code'] ?? '').toString();
    final full = info == null ? null : await _leaveFull(info['leave_id']);
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) {
        void run(VoidCallback action) {
          Navigator.of(sheetCtx).pop();
          action();
        }

        Widget option(String sym, String title, String subtitle, VoidCallback? onTap) {
          final current = status == sym;
          return ListTile(
            enabled: onTap != null || current,
            leading: CircleAvatar(
              radius: 18,
              backgroundColor: sym == '/' ? const Color(0xFFDCFCE7) : TeacherMark.fill(sym),
              child: Text(sym,
                  style: TextStyle(fontWeight: FontWeight.bold, color: TeacherMark.color(sym), fontSize: sym.length > 1 ? 13 : 16)),
            ),
            title: Text(title, style: TextStyle(fontWeight: current ? FontWeight.bold : FontWeight.w600)),
            subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
            trailing: current ? Icon(Icons.check_circle_rounded, color: TeacherMark.color(sym)) : null,
            onTap: onTap == null ? null : () => run(onTap),
          );
        }

        Widget note(String text, {Color color = const Color(0xFF475569)}) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(text, style: TextStyle(fontSize: 13, color: color)),
            );

        final children = <Widget>[];
        if (info != null) {
          final type = info['leave_type']?.toString() ?? '';
          final start = info['start_date']?.toString() ?? date;
          final end = info['end_date']?.toString() ?? start;
          final time = info['time']?.toString() ?? '';
          final reason = (full?['reason'] ?? '').toString();
          final phone = (full?['contact_phone'] ?? full?['phone'] ?? '').toString();
          final approval = info['approval']?.toString() ?? 'pending';
          children.add(Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: TeacherMark.fill(status),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TeacherMark.color(status).withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(type, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: TeacherMark.color(status))),
                  const SizedBox(width: 8),
                  _buildStatusBadge(approval),
                ]),
                const SizedBox(height: 6),
                Text(start == end ? 'วันที่ ${thaiShortDate(start)}' : 'วันที่ ${thaiShortDate(start)} ถึง ${thaiShortDate(end)}',
                    style: const TextStyle(fontSize: 13)),
                if (time.isNotEmpty) Text('เวลาที่คาดว่าจะมาถึง $time น.', style: const TextStyle(fontSize: 13)),
                if (reason.isNotEmpty) Text('เหตุผล: $reason', style: const TextStyle(fontSize: 13)),
                if (phone.isNotEmpty) Text('เบอร์ติดต่อ: $phone', style: const TextStyle(fontSize: 13)),
              ],
            ),
          ));
          if (canEdit || isMine) {
            children.add(Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Wrap(spacing: 10, runSpacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_note_rounded, size: 18),
                  label: const Text('แก้ไขรายการนี้'),
                  onPressed: () => run(() => _editFromGrid(info['leave_id'])),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C)),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text(canEdit ? 'ลบรายการนี้' : 'ยกเลิกคำขอ'),
                  onPressed: () => run(() => _deleteLeave(info['leave_id'] as int, type)),
                ),
              ]),
            ));
            if (start != end) children.add(note('รายการนี้ครอบคลุมหลายวัน การลบจะลบทั้งรายการ ถ้าจะเปลี่ยนบางวันให้กด "แก้ไขรายการนี้" แล้วเลื่อนวันที่'));
          }
        } else if (canEdit) {
          children.addAll([
            option('/', 'มา', 'มาตรงเวลา (ระบบลงให้อัตโนมัติทุกวันเรียนตั้งแต่ ${g['day_starts'] ?? '06:00'} น.)',
                status == 'ส' || status == 'ร' ? () => _setMark(row, date, '') : null),
            option('ส', 'มาสาย', isFuture ? 'ลงได้เฉพาะวันนี้หรือวันที่ผ่านมาแล้ว' : 'มาไม่ทันลงเวลา (ไม่ต้องกรอกรายละเอียด)',
                isFuture || status == 'ส' ? null : () => _setMark(row, date, 'ส')),
            option('ขส', 'ขอเข้าสาย', 'กรอกเวลาที่จะมาถึงและเหตุผล (ฟอร์มเดิม)', () => _requestFromGrid(row, date, 'ขส')),
            option('ล', 'ลา (ลากิจ / ลาป่วย)', 'กรอกช่วงวันที่ลาและเหตุผล (ฟอร์มเดิม)', () => _requestFromGrid(row, date, 'ล')),
            option('ร', 'ไปราชการ', 'ไม่ต้องกรอกรายละเอียด', status == 'ร' ? null : () => _setMark(row, date, 'ร')),
          ]);
        } else if (isMine) {
          if (status == 'ส' || status == 'ร') {
            children.add(note('หัวหน้างานบุคคลบันทึกวันนี้เป็น ${TeacherMark.label[status]} ($status) หากไม่ถูกต้องกรุณาติดต่อหัวหน้างานบุคคล'));
          } else {
            children.addAll([
              option('ขส', 'ขอเข้าสาย', 'กรอกเวลาที่จะมาถึงและเหตุผล', () => _requestFromGrid(row, date, 'ขส')),
              option('ล', 'ลา (ลากิจ / ลาป่วย)', 'กรอกช่วงวันที่ลาและเหตุผล', () => _requestFromGrid(row, date, 'ล')),
            ]);
          }
        } else {
          children.add(note(status.isEmpty ? 'ยังไม่ถึงวันนี้' : 'สถานะ: ${TeacherMark.label[status] ?? status} (ดูได้อย่างเดียว)'));
        }

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${row['teacher_name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        Text('วัน${dayFullThai[slot % 5]}ที่ ${thaiShortDate(date)}${isFuture ? ' (ล่วงหน้า)' : ''}',
                            style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                      ]),
                    ),
                    if (status.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: status == '/' ? const Color(0xFFDCFCE7) : TeacherMark.fill(status),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('$status ${TeacherMark.label[status] ?? ''}',
                            style: TextStyle(fontWeight: FontWeight.bold, color: TeacherMark.color(status))),
                      ),
                  ]),
                ),
                const Divider(height: 1),
                const SizedBox(height: 6),
                ...children,
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  /// สรุปของครูหนึ่งคน: มา (รวม ส ขส ร) • ส • ขส • ล • ร  นับเฉพาะวันเรียนที่ผ่านมาแล้ว
  Widget _summaryChips(Map<String, dynamic> s) {
    Widget chip(String label, String value, Color color, {String? sub}) => Container(
          constraints: const BoxConstraints(minWidth: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border(left: BorderSide(color: color, width: 4), top: const BorderSide(color: Color(0xFFE2E8F0)),
                right: const BorderSide(color: Color(0xFFE2E8F0)), bottom: const BorderSide(color: Color(0xFFE2E8F0))),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
            if (sub != null) Text(sub, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          ]),
        );
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    return Wrap(spacing: 10, runSpacing: 10, children: [
      chip('วันเรียนถึงวันนี้', '${n('school_days')} วัน', const Color(0xFF94A3B8)),
      chip('มา (/)', '${n('present')} วัน', TeacherMark.color('/'), sub: 'ตรงเวลา ${n('on_time')} วัน'),
      chip('มาสาย (ส)', '${n('late')} วัน', TeacherMark.color('ส')),
      chip('ขอเข้าสาย (ขส)', '${n('late_request')} ครั้ง', TeacherMark.color('ขส')),
      chip('ลา (ล)', '${n('leave')} วัน', TeacherMark.color('ล'), sub: 'ลากิจ ${n('leave_kij')} • ลาป่วย ${n('leave_puay')}'),
      chip('ไปราชการ (ร)', '${n('official')} วัน', TeacherMark.color('ร')),
    ]);
  }

  /// รายบุคคล: สรุป + ทุกวันที่ไม่ใช่ "มา" ตามปกติ (ผู้อำนวยการ หัวหน้างานบุคคล ผู้ดูแลระบบ หรือครูดูของตัวเอง)
  Future<void> _showTeacherDetail(Map<String, dynamic> row) async {
    final g = _grid;
    if (g == null) return;
    final dates = (g['dates'] as List).map((e) => e.toString()).toList();
    final status = (row['status_list'] as List).map((e) => (e ?? '').toString()).toList();
    final info = row['info'] as List;
    final today = g['today']?.toString() ?? '';
    final code = row['teacher_code'].toString();
    if (_seeAll && _allLeaves.isEmpty) await _loadAllLeaves();
    if (!mounted) return;
    final events = <Widget>[];
    for (var i = 0; i < dates.length && i < status.length; i++) {
      final st = status[i];
      if (st.isEmpty || st == '/') continue;
      final inf = info[i] is Map ? Map<String, dynamic>.from(info[i] as Map) : null;
      Map<String, dynamic>? full;
      for (final l in [..._allLeaves, ..._myLeaves]) {
        if (inf != null && l['id'] == inf['leave_id']) full = l;
      }
      final parts = <String>[
        if (inf != null) inf['leave_type'].toString() else TeacherMark.label[st] ?? st,
        if (inf != null && (inf['time'] ?? '').toString().isNotEmpty) 'ถึง ${inf['time']} น.',
        if ((full?['reason'] ?? '').toString().isNotEmpty) full!['reason'].toString(),
      ];
      events.add(ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(
          radius: 15,
          backgroundColor: TeacherMark.fill(st),
          child: Text(st, style: TextStyle(fontSize: st.length > 1 ? 11 : 14, fontWeight: FontWeight.bold, color: TeacherMark.color(st))),
        ),
        title: Text('วัน${dayFullThai[i % 5]}ที่ ${thaiShortDate(dates[i])}${dates[i].compareTo(today) > 0 ? ' (ล่วงหน้า)' : ''}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(parts.join(' • ')),
      ));
    }
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('${row['teacher_name']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('ภาคเรียนที่ ${g['term']}/${g['year']} • รหัสครู $code',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
              const SizedBox(height: 12),
              _summaryChips(Map<String, dynamic>.from((row['summary'] as Map?) ?? const {})),
              const SizedBox(height: 16),
              const Text('วันที่ไม่ได้มาตรงเวลาตามปกติ', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              if (events.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('มาตรงเวลาทุกวัน', style: TextStyle(color: Color(0xFF15803D))),
                )
              else
                ...events,
            ]),
          ),
        ),
        actions: [
          if (_seeAll)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                setState(() {
                  _selectedFilterTeacherCode = _allTeachers.any((t) => t['teacher_code'] == code) ? code : 'all';
                  _currentView = 2;
                });
              },
              child: const Text('ดูรายการลาทั้งหมดของครูคนนี้'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('ปิด')),
        ],
      ),
    );
  }

  Widget _buildAttendanceGridView(Color primaryColor) {
    final narrow = MediaQuery.of(context).size.width < 600;
    if (_grid == null) {
      if (_gridError != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.error_outline_rounded, size: 48, color: Colors.red.shade400),
              const SizedBox(height: 12),
              Text(_gridError!, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _loadGrid, child: const Text('ลองใหม่')),
            ]),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final g = _grid!;
    final rows = ((g['teachers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final seeAll = g['see_all'] == true;
    final canEdit = g['can_edit'] == true;
    final todaySlot = g['today_slot'] as int?;
    final holidays = ((g['holidays'] as List?) ?? const []).map((e) => e as int).toSet();
    final range = _weekRange ?? (todaySlot != null && todaySlot >= 50 ? 2 : 1);
    final from = range == 2 ? 10 : 0;
    final to = range == 1 ? 9 : 19;

    // ภาพรวมวันนี้ (ผู้ที่เห็นครูทุกคน)
    final todayCounts = <String, int>{for (final s in TeacherMark.order) s: 0};
    final isSchoolDay = todaySlot != null && !holidays.contains(todaySlot);
    if (isSchoolDay) {
      for (final r in rows) {
        final st = ((r['status_list'] as List)[todaySlot] ?? '').toString();
        if (todayCounts.containsKey(st)) todayCounts[st] = todayCounts[st]! + 1;
      }
    }
    final hint = canEdit
        ? 'แตะช่องวันเพื่อเปลี่ยนเป็น ส ขส ล หรือ ร • แตะชื่อครูเพื่อดูรายบุคคล'
        : seeAll
            ? 'ผู้อำนวยการดูได้อย่างเดียว • แตะชื่อครูเพื่อดูรายบุคคล แตะช่องวันเพื่อดูรายละเอียด'
            : 'แตะช่องวันเพื่อขอเข้าสาย (ขส) หรือลา (ล) • ส และ ร หัวหน้างานบุคคลเป็นผู้ลง';

    Widget legend(String sym, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 26,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: sym == '/' ? Colors.white : TeacherMark.fill(sym),
              border: Border.all(color: const Color(0xFFCBD5E1)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(sym, style: TextStyle(fontSize: sym.length > 1 ? 10.5 : 13, fontWeight: FontWeight.bold, color: TeacherMark.color(sym))),
          ),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(fontSize: 12.5)),
        ]);
    Widget swatch(Color c, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 26,
            height: 22,
            decoration: BoxDecoration(color: c, border: Border.all(color: const Color(0xFFCBD5E1)), borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(fontSize: 12.5)),
        ]);

    return RefreshIndicator(
      onRefresh: _loadGrid,
      child: ListView(
        padding: EdgeInsets.all(narrow ? 12 : 24),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.fact_check_rounded, color: primaryColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('ตารางลงเวลาครู ภาคเรียนที่ ${g['term']}/${g['year']}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                ),
                IconButton(
                  tooltip: 'โหลดใหม่',
                  onPressed: _gridLoading ? null : _loadGrid,
                  icon: _gridLoading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh_rounded),
                ),
              ]),
              Text(
                'ทุกวันเรียน ระบบลง / (มา) ให้ครูทุกคนอัตโนมัติเวลา ${g['day_starts'] ?? '06:00'} น. ตามนาฬิกาเครื่องเซิร์ฟเวอร์ '
                '• วันหยุดใช้ปฏิทินเดียวกับตารางเช็คชื่อนักเรียน',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 4),
              Text(hint, style: TextStyle(fontSize: 12.5, color: primaryColor, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Wrap(spacing: 14, runSpacing: 8, children: [
                for (final s in TeacherMark.order) legend(s, TeacherMark.label[s]!),
                swatch(const Color(0xFFE2E8F0), 'วันหยุด'),
                swatch(const Color(0xFFFDE68A), 'วันนี้'),
              ]),
            ]),
          ),
          const SizedBox(height: 14),
          if (seeAll && isSchoolDay) ...[
            Text(
              g['day_started'] == true
                  ? 'วันนี้ (${thaiShortDate(g['today'].toString())}) ครูทั้งหมด ${rows.length} คน'
                  : 'วันนี้ (${thaiShortDate(g['today'].toString())}) ระบบจะลง / ให้ครูทุกคนเวลา ${g['day_starts'] ?? '06:00'} น.',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF334155)),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final s in TeacherMark.order)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: s == '/' ? const Color(0xFFF0FDF4) : TeacherMark.fill(s),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: TeacherMark.color(s).withValues(alpha: 0.3)),
                  ),
                  child: Text('${TeacherMark.label[s]} ${todayCounts[s]} คน',
                      style: TextStyle(fontWeight: FontWeight.bold, color: TeacherMark.color(s))),
                ),
            ]),
            const SizedBox(height: 14),
          ],
          if (!seeAll && rows.isNotEmpty) ...[
            const Text('สรุปของฉัน (นับถึงวันนี้)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF334155))),
            const SizedBox(height: 8),
            _summaryChips(Map<String, dynamic>.from((rows.first['summary'] as Map?) ?? const {})),
            const SizedBox(height: 14),
          ],
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('สัปดาห์ 1–10')),
                ButtonSegment(value: 2, label: Text('สัปดาห์ 11–20')),
                ButtonSegment(value: 0, label: Text('ทั้งหมด 20 สัปดาห์')),
              ],
              selected: {range},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _weekRange = v.first),
            ),
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            _buildEmptyCard('ไม่พบชื่อของท่านในรายชื่อครูของระบบ')
          else
            TeacherAttendanceGrid(
              data: g,
              weekFrom: from,
              weekTo: to,
              onCellTap: _onGridCellTap,
              onNameTap: _showTeacherDetail,
            ),
          if (seeAll && rows.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('สรุปรายบุคคล (นับเฉพาะวันเรียนที่ผ่านมาแล้ว • มา รวม ส ขส ร)',
                style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF334155))),
            const SizedBox(height: 8),
            TeacherAttendanceSummaryTable(rows: rows, onNameTap: _showTeacherDetail),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildTopNavButton({
    required int index,
    required IconData icon,
    required String label,
    required String sublabel,
    required Color primaryColor,
  }) {
    final isSelected = _currentView == index;
    final narrow = MediaQuery.of(context).size.width < 700;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _currentView = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor.withValues(alpha: 0.08) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? primaryColor : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected ? primaryColor : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: isSelected ? Colors.white : Colors.grey.shade700,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                      color: isSelected ? primaryColor : const Color(0xFF1E293B),
                    ),
                  ),
                  if (!narrow) Text(
                    sublabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: isSelected ? primaryColor.withValues(alpha: 0.8) : Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded, color: primaryColor, size: 18),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // VIEW 1: สถิติวันลา จำนวนวันลา และประวัติเหตุผลของตัวเอง
  // -------------------------------------------------------------
  Widget _buildStatsAndHistoryView(Color primaryColor) {
    final kijLeaves = _myLeaves.where((e) => e['leave_type'] == 'ลากิจ').toList();
    final puayLeaves = _myLeaves.where((e) => e['leave_type'] == 'ลาป่วย').toList();
    final lateLeaves = _myLeaves.where((e) => e['leave_type'] == 'ขอเข้าสาย').toList();

    final kijTimes = kijLeaves.length;
    final kijDays = kijLeaves.fold<int>(0, (sum, e) => sum + ((e['days_count'] as int?) ?? 1));

    final puayTimes = puayLeaves.length;
    final puayDays = puayLeaves.fold<int>(0, (sum, e) => sum + ((e['days_count'] as int?) ?? 1));

    final lateTimes = lateLeaves.length;
    final totalLeaveTimes = kijTimes + puayTimes;
    final totalLeaveDays = kijDays + puayDays;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // 1. STATS OVERVIEW CARDS
        Row(
          children: [
            Expanded(
              child: _buildSummaryCard(
                title: 'สถิติลากิจสะสม',
                value: kijTimes > 0 ? '$kijTimes ครั้ง ($kijDays วัน)' : '0 ครั้ง (0 วัน)',
                color: const Color(0xFFD97706),
                icon: Icons.business_center_rounded,
                subtitle: 'ลากิจ $kijTimes ครั้ง • สะสม $kijDays วัน',
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _buildSummaryCard(
                title: 'สถิติลาป่วยสะสม',
                value: puayTimes > 0 ? '$puayTimes ครั้ง ($puayDays วัน)' : '0 ครั้ง (0 วัน)',
                color: const Color(0xFF059669),
                icon: Icons.healing_rounded,
                subtitle: 'ลาป่วย $puayTimes ครั้ง • สะสม $puayDays วัน',
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _buildSummaryCard(
                title: 'ขอเข้าสายสะสม',
                value: '$lateTimes ครั้ง',
                color: const Color(0xFF2563EB),
                icon: Icons.access_time_filled_rounded,
                subtitle: 'บันทึกแจ้งขอเข้าสาย $lateTimes ครั้ง',
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _buildSummaryCard(
                title: 'รวมการลาทั้งหมด',
                value: totalLeaveTimes > 0 ? '$totalLeaveTimes ครั้ง ($totalLeaveDays วัน)' : '0 ครั้ง (0 วัน)',
                color: const Color(0xFF7C3AED),
                icon: Icons.date_range_rounded,
                subtitle: 'ลากิจ + ลาป่วย รวมสะสม',
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // 2. SECTION HEADER
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'ประวัติการขอลาและขอเข้าสายของฉัน (พร้อมเหตุผลแต่ละครั้ง)',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Color(0xFF0F172A),
              ),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: primaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('ขอลา / ขอเข้าสาย (แตะวันในตาราง)'),
              onPressed: () => setState(() => _currentView = 0),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // 3. LEAVE HISTORY ITEMS
        if (_myLeaves.isEmpty)
          _buildEmptyCard('คุณยังไม่มีประวัติการบันทึกการลาหรือขอเข้าสาย')
        else
          ..._myLeaves.map((item) => _buildMyLeaveHistoryCard(item)),
      ],
    );
  }

  Widget _buildSummaryCard({
    required String title,
    required String value,
    required Color color,
    required IconData icon,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _buildMyLeaveHistoryCard(Map<String, dynamic> item) {
    final id = item['id'] as int? ?? 0;
    final type = item['leave_type'] as String? ?? 'ลากิจ';
    final startDate = item['start_date'] as String? ?? '';
    final endDate = item['end_date'] as String? ?? '';
    final arrivalTime = item['expected_arrival_time'] as String? ?? item['late_time'] as String? ?? '';
    final reason = item['reason'] as String? ?? '-';
    final phone = item['contact_phone'] as String? ?? item['phone'] as String? ?? '';
    final status = item['status'] as String? ?? 'pending';
    final createdAt = item['created_at'] as String? ?? '';
    final approvedBy = item['approved_by'] as String? ?? '';
    final daysCount = item['days_count'] as int? ?? 1;

    final color = _getTypeColor(type);
    final icon = _getTypeIcon(type);

    String durationText;
    if (type == 'ขอเข้าสาย') {
      durationText = 'ขอเข้าสาย 1 ครั้ง (เวลา $arrivalTime น.)';
    } else {
      durationText = '1 ครั้ง ($daysCount วัน)';
    }

    String dateText;
    if (type == 'ขอเข้าสาย' || startDate == endDate || endDate.isEmpty) {
      dateText = '${_formatThaiDate(startDate)} (1 ครั้ง)';
    } else {
      dateText = '${_formatThaiDate(startDate)} ถึง ${_formatThaiDate(endDate)} (1 ครั้ง $daysCount วัน)';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
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
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 16, color: color),
                    const SizedBox(width: 6),
                    Text(
                      type,
                      style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  durationText,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF334155)),
                ),
              ),
              const Spacer(),
              _buildStatusBadge(status),
            ],
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Icon(Icons.calendar_month_rounded, size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 8),
              Text(
                'วันที่ลา: $dateText',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 8),

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.chat_bubble_outline_rounded, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(fontSize: 14, color: Color(0xFF1E293B)),
                      children: [
                        const TextSpan(
                          text: 'เหตุผลในการขอลา/เข้าสาย: ',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        TextSpan(text: reason),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          if (phone.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(Icons.phone_rounded, size: 15, color: Colors.grey.shade600),
                  const SizedBox(width: 8),
                  Text('เบอร์โทรศัพท์ติดต่อ: $phone', style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                ],
              ),
            ),

          const Divider(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'บันทึกคำขอเมื่อ: ${_formatThaiDate(createdAt.split(' ').first)} ${createdAt.split(' ').length > 1 ? createdAt.split(' ')[1].substring(0, 5) : ''}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Color(0xFFB91C1C)),
                tooltip: 'ยกเลิกคำขอ',
                onPressed: () => _deleteLeave(id, type),
              ),
            ],
          ),
          if (approvedBy.isNotEmpty)
            Text(
              'รับทราบแล้วโดย: $approvedBy',
              style: const TextStyle(fontSize: 12, color: Color(0xFF059669), fontStyle: FontStyle.italic),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // VIEW 3: จัดการรายการลาครูทุกคน & พิมพ์รายงาน (สำหรับหัวหน้าบุคคล)
  // -------------------------------------------------------------
  Widget _buildPersonnelHeadManagementView(Color primaryColor) {
    final filtered = _allLeaves.where((l) {
      if (_selectedFilterTeacherCode != 'all') {
        if (l['teacher_code'] != _selectedFilterTeacherCode) return false;
      }
      if (_allLeavesSearchQuery.isNotEmpty) {
        final q = _allLeavesSearchQuery.toLowerCase();
        final name = (l['teacher_name'] ?? '').toString().toLowerCase();
        final code = (l['teacher_code'] ?? '').toString().toLowerCase();
        final reason = (l['reason'] ?? '').toString().toLowerCase();
        return name.contains(q) || code.contains(q) || reason.contains(q);
      }
      return true;
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // 1. Management Header
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF16A34A).withValues(alpha: 0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Wrap(
            spacing: 14,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.manage_accounts_rounded, color: Color(0xFF15803D), size: 24),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _canEditOthers ? 'ระบบจัดการรายการลา & พิมพ์รายงาน (สิทธิ์หัวหน้าบุคคล)' : 'รายการลาของครูทุกคน & พิมพ์รายงาน',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                      Text(
                        _canEditOthers
                            ? 'สามารถแก้ไข/ยกเลิกคำขอลาแทนคุณครู และสั่งพิมพ์รายงานสรุปอย่างเป็นทางการ'
                            : 'ผู้อำนวยการดูและพิมพ์รายงานได้ แก้ไขไม่ได้',
                        style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ],
              ),

              // Action Buttons: Print Report + Refresh
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B0B38),
                      foregroundColor: const Color(0xFFFFD95A),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 2,
                    ),
                    icon: const Icon(Icons.print_rounded, size: 18),
                    label: const Text('พิมพ์รายงานการลา', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: _printLeaveReport,
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: _isLoadingAllLeaves
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('รีเฟรช'),
                    onPressed: _isLoadingAllLeaves ? null : _loadAllLeaves,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 2. Filters & Search Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Teacher filter dropdown
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('กรองตามครู:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: DropdownButton<String>(
                      value: _selectedFilterTeacherCode,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: [
                        const DropdownMenuItem(value: 'all', child: Text('ทั้งหมด (ครูทุกคน)')),
                        ..._allTeachers.map((t) {
                          final c = t['teacher_code']?.toString() ?? '';
                          final n = t['teacher_name']?.toString() ?? '';
                          return DropdownMenuItem(value: c, child: Text('ครู$n (รหัส $c)'));
                        }),
                      ],
                      onChanged: (val) {
                        if (val != null) setState(() => _selectedFilterTeacherCode = val);
                      },
                    ),
                  ),
                ],
              ),

              // Search box
              SizedBox(
                width: 280,
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    hintText: 'ค้นหาชื่อครู, รหัส หรือเหตุผล...',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (val) => setState(() => _allLeavesSearchQuery = val),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 3. Results count
        Text(
          'พบข้อมูลทั้งหมด ${filtered.length} รายการ',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569)),
        ),
        const SizedBox(height: 10),

        // 4. List of leave records
        if (_isLoadingAllLeaves && _allLeaves.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
        else if (filtered.isEmpty)
          _buildEmptyCard('ไม่พบรายการลาตามเงื่อนไขที่เลือก')
        else
          ...filtered.map((item) => _buildPersonnelHeadLeaveItemCard(item)),
      ],
    );
  }

  Widget _buildPersonnelHeadLeaveItemCard(Map<String, dynamic> item) {
    final id = item['id'] as int? ?? 0;
    final teacherCode = item['teacher_code']?.toString() ?? '';
    final teacherName = item['teacher_name']?.toString() ?? '';
    final type = item['leave_type'] as String? ?? 'ลากิจ';
    final startDate = item['start_date'] as String? ?? '';
    final endDate = item['end_date'] as String? ?? '';
    final arrivalTime = item['expected_arrival_time'] as String? ?? item['late_time'] as String? ?? '';
    final reason = item['reason'] as String? ?? '-';
    final phone = item['contact_phone'] as String? ?? item['phone'] as String? ?? '';
    final status = item['status'] as String? ?? 'pending';
    final createdAt = item['created_at'] as String? ?? '';
    final daysCount = item['days_count'] as int? ?? 1;

    final color = _getTypeColor(type);
    final icon = _getTypeIcon(type);

    String durationText;
    if (type == 'ขอเข้าสาย') {
      durationText = 'ขอเข้าสาย 1 ครั้ง (เวลา $arrivalTime น.)';
    } else {
      durationText = '1 ครั้ง ($daysCount วัน)';
    }

    String dateText;
    if (type == 'ขอเข้าสาย' || startDate == endDate || endDate.isEmpty) {
      dateText = '${_formatThaiDate(startDate)} (1 ครั้ง)';
    } else {
      dateText = '${_formatThaiDate(startDate)} ถึง ${_formatThaiDate(endDate)} (1 ครั้ง $daysCount วัน)';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Teacher Name & Code + Leave Type + Status
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: const Color(0xFFDCFCE7),
                child: const Icon(Icons.person, size: 16, color: Color(0xFF15803D)),
              ),
              const SizedBox(width: 8),
              Text(
                'ครู$teacherName',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF0F172A)),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('รหัส $teacherCode', style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 4),
                    Text(type, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(durationText, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
              const Spacer(),
              _buildStatusBadge(status),
            ],
          ),
          const SizedBox(height: 10),

          // Date
          Row(
            children: [
              Icon(Icons.calendar_month_rounded, size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 8),
              Text('ช่วงวันที่ลา: $dateText', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            ],
          ),
          const SizedBox(height: 8),

          // Reason Box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.chat_bubble_outline_rounded, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(fontSize: 13.5, color: Color(0xFF1E293B)),
                      children: [
                        const TextSpan(text: 'เหตุผล: ', style: TextStyle(fontWeight: FontWeight.bold)),
                        TextSpan(text: reason),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          if (phone.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(Icons.phone_rounded, size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Text('โทร: $phone', style: TextStyle(color: Colors.grey.shade700, fontSize: 12.5)),
                ],
              ),
            ),

          const Divider(height: 16),

          // Footer: Timestamp + Action Buttons for the personnel head (Edit / Delete)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ยื่นเมื่อ: ${_formatThaiDate(createdAt.split(' ').first)}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              if (_canEditOthers) Row(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFD97706),
                      side: const BorderSide(color: Color(0xFFF59E0B)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    icon: const Icon(Icons.edit_note_rounded, size: 16),
                    label: const Text('แก้ไขข้อมูล'),
                    onPressed: () => _showLeaveFormDialog(item),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFB91C1C),
                      side: BorderSide(color: Colors.red.shade300),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    label: const Text('ยกเลิกคำขอ'),
                    onPressed: () => _deleteLeave(id, type),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color bg;
    Color fg;
    String label;
    IconData icon;

    if (status == 'approved') {
      bg = const Color(0xFFDCFCE7);
      fg = const Color(0xFF15803D);
      label = 'อนุมัติแล้ว';
      icon = Icons.check_circle_rounded;
    } else if (status == 'rejected') {
      bg = const Color(0xFFFEE2E2);
      fg = const Color(0xFFB91C1C);
      label = 'ไม่อนุมัติ';
      icon = Icons.cancel_rounded;
    } else {
      bg = const Color(0xFFFEF3C7);
      fg = const Color(0xFFB45309);
      label = 'รออนุมัติ';
      icon = Icons.hourglass_top_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: fg)),
        ],
      ),
    );
  }

  Widget _buildEmptyCard(String text) {
    return Container(
      padding: const EdgeInsets.all(48),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.event_available_rounded, size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(
              text,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
