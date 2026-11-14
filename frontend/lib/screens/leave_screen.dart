import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../models/school_theme_config.dart';

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
  // 0: สถิติและประวัติการลาของฉัน, 1: ขอบันทึกการลา, 2: จัดการรายการลาครูทุกคน & พิมพ์รายงาน (เฉพาะหัวหน้าบุคคล หัวหน้าบุคคล)
  int _currentView = 0; 

  bool _isLoading = false;
  List<Map<String, dynamic>> _myLeaves = [];
  String? _errorMessage;

  // Form State
  String _selectedLeaveType = 'ลากิจ'; // 'ลากิจ', 'ลาป่วย', 'ขอเข้าสาย'
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now();
  TimeOfDay _expectedTime = const TimeOfDay(hour: 9, minute: 0);
  final TextEditingController _reasonController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  bool _isSubmitting = false;

  // Special State for the personnel head (หัวหน้าบุคคล) & Admin
  List<Map<String, dynamic>> _allTeachers = [];
  String? _targetTeacherCode; // null means 'ตัวฉันเอง'
  String? _targetTeacherName;

  // View 2: All leaves management (สำหรับหัวหน้าบุคคล)
  List<Map<String, dynamic>> _allLeaves = [];
  bool _isLoadingAllLeaves = false;
  String _selectedFilterTeacherCode = 'all'; // 'all' or teacher code
  String _allLeavesSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadMyLeaves();

    final isPersonnelHead = widget.apiService.isPersonnelHead ||
                           widget.apiService.currentUser?.code == '102' ||
                           widget.apiService.isAdmin;
    if (isPersonnelHead) {
      _loadAllTeachers();
      _loadAllLeaves();
    }
  }

  @override
  void dispose() {
    _reasonController.dispose();
    _phoneController.dispose();
    super.dispose();
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

  Future<void> _submitLeaveRequest() async {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาระบุเหตุผลในการขอลาหรือขอเข้าสาย')),
      );
      return;
    }

    final startStr = DateFormat('yyyy-MM-dd').format(_startDate);
    final endStr = DateFormat('yyyy-MM-dd').format(_endDate);
    final timeStr = '${_expectedTime.hour.toString().padLeft(2, '0')}:${_expectedTime.minute.toString().padLeft(2, '0')}';

    final isPersonnelHead = widget.apiService.isPersonnelHead ||
                           widget.apiService.currentUser?.code == '102' ||
                           widget.apiService.isAdmin;

    final targetCode = (isPersonnelHead && _targetTeacherCode != null)
        ? _targetTeacherCode
        : widget.apiService.currentUser?.code;

    final targetName = (isPersonnelHead && _targetTeacherName != null)
        ? _targetTeacherName
        : widget.apiService.currentUser?.name;

    setState(() => _isSubmitting = true);
    try {
      await widget.apiService.createLeave(
        leaveType: _selectedLeaveType,
        startDate: startStr,
        endDate: _selectedLeaveType == 'ขอเข้าสาย' ? startStr : endStr,
        expectedArrivalTime: _selectedLeaveType == 'ขอเข้าสาย' ? timeStr : null,
        reason: reason,
        contactPhone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
        teacherCode: targetCode,
        teacherName: targetName,
      );

      _reasonController.clear();
      _phoneController.clear();
      if (mounted) {
        final isSelf = _targetTeacherCode == null || _targetTeacherCode == widget.apiService.currentUser?.code;
        setState(() {
          _isSubmitting = false;
          _targetTeacherCode = null;
          _targetTeacherName = null;
          _currentView = isSelf ? 0 : 2; // Switch to personal stats or all leaves
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isSelf
                ? 'บันทึกคำขอ$_selectedLeaveTypeเรียบร้อยแล้ว'
                : 'บันทึกคำขอ$_selectedLeaveTypeแทน ครู$targetName เรียบร้อยแล้ว'),
            backgroundColor: const Color(0xFF15803D),
          ),
        );
        _loadMyLeaves();
        if (isPersonnelHead) {
          _loadAllLeaves();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาด: ${e.toString().replaceFirst('Exception: ', '')}'),
            backgroundColor: const Color(0xFFB91C1C),
          ),
        );
      }
    }
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
        _loadMyLeaves();
        final isPersonnelHead = widget.apiService.isPersonnelHead ||
                               widget.apiService.currentUser?.code == '102' ||
                               widget.apiService.isAdmin;
        if (isPersonnelHead) {
          _loadAllLeaves();
        }
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

  Future<void> _showEditLeaveDialog(Map<String, dynamic> item) async {
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
                      'แก้ไขรายการลาของ: ครู$teacherName',
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
                        children: ['ลากิจ', 'ลาป่วย', 'ขอเข้าสาย'].map((type) {
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
                              firstDate: DateTime.now().subtract(const Duration(days: 90)),
                              lastDate: DateTime.now().add(const Duration(days: 90)),
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
                                    firstDate: DateTime.now().subtract(const Duration(days: 90)),
                                    lastDate: DateTime.now().add(const Duration(days: 90)),
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
                                    lastDate: DateTime.now().add(const Duration(days: 90)),
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

                      await widget.apiService.updateLeave(
                        leaveId,
                        leaveType: editType,
                        startDate: sStr,
                        endDate: editType == 'ขอเข้าสาย' ? sStr : eStr,
                        expectedArrivalTime: editType == 'ขอเข้าสาย' ? timeStr : null,
                        reason: editReasonController.text.trim(),
                        contactPhone: editPhoneController.text.trim(),
                      );
                      if (mounted) {
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            backgroundColor: Color(0xFF15803D),
                            content: Text('แก้ไขข้อมูลเรียบร้อยแล้ว'),
                          ),
                        );
                        _loadMyLeaves();
                        _loadAllLeaves();
                      }
                    } catch (e) {
                      setDialogState(() => isSaving = false);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: Colors.red.shade700,
                            content: Text('แก้ไขไม่สำเร็จ: $e'),
                          ),
                        );
                      }
                    }
                  },
                  icon: isSaving
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.save_rounded, size: 16),
                  label: const Text('บันทึกการแก้ไข'),
                ),
              ],
            );
          },
        );
      },
    );
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
    final isPersonnelHead = widget.apiService.isPersonnelHead ||
                           user?.code == '102' ||
                           widget.apiService.isAdmin;

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
                                'ระบบบันทึกการลา & ขอเข้าสาย',
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
                                : 'บันทึกการลากิจ ลาป่วย และการขอเข้าสายสำหรับคณะครูและบุคลากร',
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
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildTopNavButton(
                        index: 0,
                        icon: Icons.query_stats_rounded,
                        label: 'สถิติวันลาของฉัน',
                        sublabel: 'สถิติวันลาสะสมและประวัติส่วนตัว',
                        primaryColor: primaryColor,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _buildTopNavButton(
                        index: 1,
                        icon: Icons.edit_calendar_rounded,
                        label: isPersonnelHead ? 'เขียนบันทึกการลา (แทนครู)' : 'ขอบันทึกการลา / เข้าสาย',
                        sublabel: isPersonnelHead ? 'เขียนให้ตนเอง หรือเขียนแทนครูท่านอื่น' : 'กรอกแบบฟอร์มส่งคำขอใหม่',
                        primaryColor: primaryColor,
                      ),
                    ),
                    if (isPersonnelHead) ...[
                      const SizedBox(width: 14),
                      Expanded(
                        child: _buildTopNavButton(
                          index: 2,
                          icon: Icons.manage_accounts_rounded,
                          label: 'จัดการรายการลา & พิมพ์รายงาน',
                          sublabel: 'แก้ไขคำขอลาแทนครู และพิมพ์รายงานสรุป',
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
                child: _isLoading
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
                        : _currentView == 0
                            ? _buildStatsAndHistoryView(primaryColor)
                            : _currentView == 1
                                ? _buildRequestFormView(primaryColor, isPersonnelHead)
                                : _buildPersonnelHeadManagementView(primaryColor),
              ),
            ],
          ),
        );
      },
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
                  Text(
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
              label: const Text('ขอบันทึกการลาใหม่'),
              onPressed: () => setState(() => _currentView = 1),
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
  // VIEW 2: ขอบันทึกการลา / ขอเข้าสาย (FORM)
  // -------------------------------------------------------------
  Widget _buildRequestFormView(Color primaryColor, bool isPersonnelHead) {
    final daysPreview = _calculateDays(_startDate, _endDate);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.post_add_rounded, color: primaryColor, size: 24),
                  const SizedBox(width: 10),
                  Text(
                    isPersonnelHead ? 'แบบฟอร์มบันทึกการลา (สามารถเลือกบันทึกแทนครูได้ทุกคน)' : 'แบบฟอร์มขอบันทึกการลา / ขอเข้าสาย',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const Divider(height: 24),

              // 0. TEACHER SELECTOR FOR PERSONNEL HEAD (สิทธิ์หัวหน้าบุคคล)
              if (isPersonnelHead) ...[
                _buildTeacherSelectorForPersonnelHead(primaryColor),
              ],

              // 1. CHOOSE TYPE
              const Text('1. ประเภทการลา:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 10),
              Row(
                children: [
                  _buildTypeChoiceChip('ลากิจ', Icons.business_center_rounded),
                  const SizedBox(width: 12),
                  _buildTypeChoiceChip('ลาป่วย', Icons.healing_rounded),
                  const SizedBox(width: 12),
                  _buildTypeChoiceChip('ขอเข้าสาย', Icons.access_time_filled_rounded),
                ],
              ),
              const SizedBox(height: 20),

              // 2. DATES / TIME
              if (_selectedLeaveType == 'ขอเข้าสาย') ...[
                const Text('2. วันที่และเวลาที่คาดว่าจะมาถึง:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          alignment: Alignment.centerLeft,
                        ),
                        icon: const Icon(Icons.calendar_today_rounded, size: 18),
                        label: Text('วันที่: ${_formatThaiDate(DateFormat('yyyy-MM-dd').format(_startDate))}'),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _startDate,
                            firstDate: DateTime.now().subtract(const Duration(days: 14)),
                            lastDate: DateTime.now().add(const Duration(days: 30)),
                          );
                          if (picked != null) {
                            setState(() {
                              _startDate = picked;
                              _endDate = picked;
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          alignment: Alignment.centerLeft,
                        ),
                        icon: const Icon(Icons.alarm_rounded, size: 18),
                        label: Text('เวลาที่คาดว่าจะถึง: ${_expectedTime.hour.toString().padLeft(2, '0')}:${_expectedTime.minute.toString().padLeft(2, '0')} น.'),
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
                            initialTime: _expectedTime,
                          );
                          if (picked != null) {
                            setState(() => _expectedTime = picked);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('2. วันที่ลา (เริ่มต้น - สิ้นสุด):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _getTypeColor(_selectedLeaveType).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '1 ครั้ง (จำนวน $daysPreview วัน)',
                        style: TextStyle(
                          color: _getTypeColor(_selectedLeaveType),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          alignment: Alignment.centerLeft,
                        ),
                        icon: const Icon(Icons.calendar_today_rounded, size: 18),
                        label: Text('ตั้งแต่วันที่: ${_formatThaiDate(DateFormat('yyyy-MM-dd').format(_startDate))}'),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _startDate,
                            firstDate: DateTime.now().subtract(const Duration(days: 30)),
                            lastDate: DateTime.now().add(const Duration(days: 60)),
                          );
                          if (picked != null) {
                            setState(() {
                              _startDate = picked;
                              if (_endDate.isBefore(_startDate)) {
                                _endDate = _startDate;
                              }
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          alignment: Alignment.centerLeft,
                        ),
                        icon: const Icon(Icons.calendar_today_rounded, size: 18),
                        label: Text('ถึงวันที่: ${_formatThaiDate(DateFormat('yyyy-MM-dd').format(_endDate))}'),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _endDate.isBefore(_startDate) ? _startDate : _endDate,
                            firstDate: _startDate,
                            lastDate: DateTime.now().add(const Duration(days: 60)),
                          );
                          if (picked != null) {
                            setState(() => _endDate = picked);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),

              // 3. REASON
              const Text('3. เหตุผลในการขอลา / ขอเข้าสาย:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 10),
              TextField(
                controller: _reasonController,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: isPersonnelHead && _targetTeacherCode != null
                      ? 'ระบุเหตุผลในการลาแทนครู (เช่น ครูโทรแจ้งส่วนตัวว่าป่วยกระทันหัน, มีธุระราชการเร่งด่วน...)'
                      : 'ระบุเหตุผลอย่างละเอียดและชัดเจน เช่น มีธุระส่วนตัวติดต่อราชการ, ป่วยเป็นไข้หวัด...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                ),
              ),
              const SizedBox(height: 20),

              // 4. PHONE
              const Text('4. เบอร์โทรศัพท์ติดต่อระหว่างลา (ถ้ามี):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 10),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: 'เช่น 081-234-5678',
                  prefixIcon: const Icon(Icons.phone_rounded, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                ),
              ),
              const SizedBox(height: 28),

              // SUBMIT BUTTON
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: isPersonnelHead && _targetTeacherCode != null ? const Color(0xFFD97706) : primaryColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: _isSubmitting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.send_rounded),
                  label: Text(
                    _isSubmitting
                        ? 'กำลังบันทึกข้อมูล...'
                        : (isPersonnelHead && _targetTeacherCode != null
                            ? 'ยืนยันบันทึกการลาแทน ครู$_targetTeacherName'
                            : 'ส่งคำขอบันทึกการลา'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  onPressed: _isSubmitting ? null : _submitLeaveRequest,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTeacherSelectorForPersonnelHead(Color primaryColor) {
    final myCode = widget.apiService.currentUser?.code ?? '';
    final myName = widget.apiService.currentUser?.name ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF22C55E).withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF22C55E).withValues(alpha: 0.05),
            blurRadius: 8,
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
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF16A34A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.badge_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'สิทธิ์หัวหน้าบุคคล: เลือกบันทึกการลาสำหรับคุณครู',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF14532D)),
                    ),
                    Text(
                      'กรณีคุณครูไม่ได้พิมพ์ส่งเอง หรือโทรแจ้งส่วนตัว สามารถคลิกเลือกชื่อครูด้านล่างเพื่อเขียนแทนได้ทันที',
                      style: TextStyle(fontSize: 12, color: Color(0xFF15803D)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Teacher Buttons Wrap
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Button 1: Myself
              ChoiceChip(
                avatar: CircleAvatar(
                  backgroundColor: _targetTeacherCode == null ? Colors.white : const Color(0xFF16A34A),
                  child: Icon(Icons.person, size: 14, color: _targetTeacherCode == null ? const Color(0xFF16A34A) : Colors.white),
                ),
                label: Text('ตัวฉันเอง ($myName)'),
                selected: _targetTeacherCode == null,
                selectedColor: const Color(0xFF16A34A),
                labelStyle: TextStyle(
                  color: _targetTeacherCode == null ? Colors.white : const Color(0xFF1E293B),
                  fontWeight: FontWeight.bold,
                ),
                onSelected: (val) {
                  if (val) {
                    setState(() {
                      _targetTeacherCode = null;
                      _targetTeacherName = null;
                    });
                  }
                },
              ),

              // Button 2+: All Teachers in school
              ..._allTeachers.where((t) => t['teacher_code'] != myCode).map((t) {
                final code = t['teacher_code']?.toString() ?? '';
                final name = t['teacher_name']?.toString() ?? '';
                final isSelected = _targetTeacherCode == code;

                return ChoiceChip(
                  avatar: CircleAvatar(
                    backgroundColor: isSelected ? Colors.white : Colors.grey.shade300,
                    child: Icon(Icons.school, size: 14, color: isSelected ? const Color(0xFFD97706) : Colors.black87),
                  ),
                  label: Text('ครู$name'),
                  selected: isSelected,
                  selectedColor: const Color(0xFFD97706),
                  labelStyle: TextStyle(
                    color: isSelected ? Colors.white : const Color(0xFF1E293B),
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                  onSelected: (val) {
                    setState(() {
                      if (val) {
                        _targetTeacherCode = code;
                        _targetTeacherName = name;
                      } else {
                        _targetTeacherCode = null;
                        _targetTeacherName = null;
                      }
                    });
                  },
                );
              }),
            ],
          ),

          if (_targetTeacherCode != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFF59E0B)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFFB45309)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'กำลังบันทึกคำขอแทน: ครู$_targetTeacherName (รหัส $_targetTeacherCode)',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF92400E)),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ระบบจัดการรายการลา & พิมพ์รายงาน (สิทธิ์หัวหน้าบุคคล)',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                      Text(
                        'สามารถแก้ไข/ยกเลิกคำขอลาแทนคุณครู และสั่งพิมพ์รายงานสรุปอย่างเป็นทางการ',
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
              Row(
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
                    onPressed: () => _showEditLeaveDialog(item),
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

  Widget _buildTypeChoiceChip(String type, IconData icon) {
    final isSelected = _selectedLeaveType == type;
    final color = _getTypeColor(type);

    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _selectedLeaveType = type),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: 0.12) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? color : Colors.grey.shade300,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isSelected ? color : Colors.grey.shade600, size: 22),
              const SizedBox(height: 6),
              Text(
                type,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  color: isSelected ? color : const Color(0xFF1E293B),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
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
