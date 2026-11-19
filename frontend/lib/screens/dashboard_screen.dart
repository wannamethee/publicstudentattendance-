import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../models/semester_config.dart';
import '../widgets/dmc_import_dialog.dart';
import '../widgets/student_monthly_graph_dialog.dart';
import '../widgets/attendance_summary_pdf_dialog.dart';
import '../widgets/app_3d_button.dart';
import '../widgets/enrollment_chart.dart';
import '../widgets/responsive_fields_row.dart';
import '../widgets/teacher_dashboard_view.dart';
import '../utils/app_theme.dart';

class DashboardScreen extends StatefulWidget {
  final ApiService apiService;
  final Function(String classLevel)? onNavigateToAttendance;
  final VoidCallback? onNavigateToUpload;

  const DashboardScreen({
    super.key,
    required this.apiService,
    this.onNavigateToAttendance,
    this.onNavigateToUpload,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = false;
  String _selectedTerm = '1';
  String _selectedYear = '2568';
  String _mode = 'daily'; // 'daily' or 'subject'
  String _selectedMonth = 'all'; // 'all' or 'YYYY-MM'
  bool _isMonthlyMode = false;
  List<SemesterConfigItem> _semesters = [];
  Map<String, dynamic>? _dashboardData;
  Map<String, dynamic>? _riskData;
  String _tableSearchQuery = '';

  // Director / Admin Teacher Leaves Dashboard State
  String _dashboardTarget = 'student'; // 'student' or 'teacher'
  List<Map<String, dynamic>> _teacherLeavesSummary = [];
  bool _loadingTeacherLeaves = false;
  String? _teacherLeavesError;
  String _teacherSearchQuery = '';
  final GlobalKey<TeacherDashboardViewState> _teacherViewKey = GlobalKey<TeacherDashboardViewState>();

  @override
  void initState() {
    super.initState();
    widget.apiService.dashboardResetNotifier.addListener(_onDashboardResetTriggered);
    _loadSemestersAndDashboard(resetToDefault: true);
    if (widget.apiService.isDirector || widget.apiService.isAdmin || widget.apiService.isPersonnelHead || widget.apiService.currentUser?.code == '102') {
      _loadTeacherLeavesSummary(reloadView: false);
    }
  }

  @override
  void dispose() {
    widget.apiService.dashboardResetNotifier.removeListener(_onDashboardResetTriggered);
    super.dispose();
  }

  void _onDashboardResetTriggered() {
    if (!mounted) return;
    _loadSemestersAndDashboard(resetToDefault: true);
  }

  Future<void> _loadSemestersAndDashboard({bool resetToDefault = true}) async {
    setState(() => _loading = true);
    try {
      final list = await widget.apiService.getSemesterConfigs();
      _semesters = list;
      if (list.isNotEmpty && resetToDefault) {
        final pinned = list.firstWhere(
          (s) => s.isDefault,
          orElse: () => list.firstWhere((s) => s.isActive, orElse: () => list.first),
        );
        _selectedTerm = pinned.term;
        _selectedYear = pinned.year;
      }
      await _fetchDashboardData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('โหลดข้อมูลแดชบอร์ดไม่สำเร็จ: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Mark ภาคเรียนไว้ดูเอง ทุกคนทำได้ (รวมผู้อำนวยการ) ไม่กระทบคนอื่น
  /// ผู้ดูแลระบบจะตั้งเป็นค่าเริ่มต้นของทั้งโรงเรียนให้ด้วย
  Future<void> _markDefaultSemester(String term, String year) async {
    final api = widget.apiService;
    if (api.isGuest) return;
    try {
      await api.markMySemester(term: term, year: year);
      if (!api.isAdmin) {
        if (mounted) {
          setState(() {
            _selectedTerm = term;
            _selectedYear = year;
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Colors.green.shade800,
            content: Text('Mark ปีการศึกษา $year ภาคเรียนที่ $term ไว้ดูเองแล้ว (เฉพาะบัญชีของท่าน)'),
          ));
        }
        await _fetchDashboardData();
        return;
      }
      final res = await api.setDefaultSemester(term: term, year: year);
      final updatedRaw = (res['data'] as List?) ?? [];
      if (mounted) {
        setState(() {
          if (updatedRaw.isNotEmpty) {
            _semesters = updatedRaw
                .map((e) => SemesterConfigItem.fromJson(e as Map<String, dynamic>))
                .toList();
          } else {
            _semesters = _semesters
                .map((s) => s.copyWith(isDefault: s.term == term && s.year == year))
                .toList();
          }
          _selectedTerm = term;
          _selectedYear = year;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.green.shade800,
            content: Text(
              res['message']?.toString() ??
                  'ตั้งค่า ปีการศึกษา $year ภาคเรียนที่ $term ให้แสดงเป็นค่าเริ่มต้นเสมอเรียบร้อยแล้ว',
            ),
          ),
        );
      }
      await _fetchDashboardData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('ไม่สามารถตั้งค่าเทอมหลักได้: $e'),
          ),
        );
      }
    }
  }

  Future<void> _fetchDashboardData() async {
    setState(() => _loading = true);
    // Risk forecast loads alongside and never blocks the dashboard (not for บุคคลทั่วไป)
    if (!widget.apiService.isGuest) {
      widget.apiService
          .getAttendanceRisk(term: _selectedTerm, year: _selectedYear)
          .then((r) {
        if (mounted) setState(() => _riskData = r);
      }).catchError((_) {
        if (mounted) setState(() => _riskData = null);
      });
    } else {
      _riskData = null;
    }
    try {
      final data = await widget.apiService.getAttendanceDashboard(
        term: _selectedTerm,
        year: _selectedYear,
        mode: _mode,
        month: _isMonthlyMode ? _selectedMonth : 'all',
      );
      if (mounted) {
        setState(() {
          _dashboardData = data;
          if (_isMonthlyMode && _selectedMonth == 'all') {
            final defM = data['default_month']?.toString();
            if (defM != null && defM.isNotEmpty && defM != 'all') {
              _selectedMonth = defM;
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('โหลดข้อมูลสถิติไม่สำเร็จ: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onTogglePeriodMode(bool monthly) {
    setState(() {
      _isMonthlyMode = monthly;
      if (monthly) {
        final defM = _dashboardData?['default_month']?.toString() ?? 'all';
        _selectedMonth = (defM != 'all') ? defM : 'all';
      } else {
        _selectedMonth = 'all';
      }
    });
    _fetchDashboardData();
  }

  void _onMonthChanged(String newMonth) {
    if (_selectedMonth == newMonth) return;
    setState(() {
      _selectedMonth = newMonth;
    });
    _fetchDashboardData();
  }

  void _openAttendanceSummaryPdfDialog() {
    if (widget.apiService.isGuest) return;
    AttendanceSummaryPdfDialog.show(
      context,
      apiService: widget.apiService,
      initialTerm: _selectedTerm,
      initialYear: _selectedYear,
      initialMode: _mode,
    );
  }

  void _onSemesterChanged(String term, String year) {
    setState(() {
      _selectedTerm = term;
      _selectedYear = year;
    });
    _fetchDashboardData();
  }

  void _onModeChanged(String newMode) {
    if (_mode == newMode) return;
    setState(() => _mode = newMode);
    _fetchDashboardData();
  }

  Future<void> _openImportDmcDialog() async {
    final res = await DmcImportDialog.show(
      context,
      apiService: widget.apiService,
      initialTerm: _selectedTerm,
      initialYear: _selectedYear,
      semesters: _semesters,
    );
    if (res != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.teal.shade700,
          content: Text(res['message'] ?? 'นำเข้าข้อมูลนักเรียนจากระบบ DMC สำเร็จ'),
        ),
      );
      _fetchDashboardData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 1100;
    final isTablet = MediaQuery.of(context).size.width >= 700;

    final summary = _dashboardData?['summary'] as Map<String, dynamic>?;
    final levels = (_dashboardData?['levels'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final schoolTop = (_dashboardData?['school_top_absent'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final availableMonths = (_dashboardData?['available_months'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final filteredSchoolTop = schoolTop.where((st) {
      if (_tableSearchQuery.isEmpty) return true;
      final q = _tableSearchQuery.toLowerCase();
      final name = (st['full_name'] ?? '').toString().toLowerCase();
      final sid = (st['student_id'] ?? '').toString().toLowerCase();
      final cl = (st['class_level'] ?? '').toString().toLowerCase();
      return name.contains(q) || sid.contains(q) || cl.contains(q);
    }).toList();

    final isPrivileged = widget.apiService.isDirector ||
                         widget.apiService.isAdmin ||
                         widget.apiService.isPersonnelHead ||
                         widget.apiService.currentUser?.code == '102';

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFFFF4B8), // luminous radiant highlight top
              Color(0xFFFFD95A), // radiant gold (#ffd95a from sample)
              Color(0xFFFBC848), // rich warm metallic gold (#fbc848 from sample)
              Color(0xFFF5B338), // warm amber gold
              Color(0xFFEFA92F), // deep gold base (#efa92f from sample)
            ],
            stops: [0.0, 0.20, 0.50, 0.75, 1.0],
          ),
        ),
        child: (_loading && _dashboardData == null && _dashboardTarget == 'student') ||
                (_loadingTeacherLeaves && _teacherLeavesSummary.isEmpty && _dashboardTarget == 'teacher')
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () async {
                  if (isPrivileged && _dashboardTarget == 'teacher') {
                    await _loadTeacherLeavesSummary();
                  } else {
                    await _loadSemestersAndDashboard(resetToDefault: true);
                  }
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 0. Toggle [นักเรียน] / [ครู] (เฉพาะ ผู้อำนวยการ / ผู้ดูแลระบบ)
                      if (isPrivileged) ...[
                        _buildTargetToggle(isTablet),
                        const SizedBox(height: 16),
                      ],

                      if (_dashboardTarget == 'student' || !isPrivileged) ...[
                        // 1. Header Toolbar
                        _buildHeaderToolbar(theme, isTablet),
                      const SizedBox(height: 16),

                      // 2. Overview KPI Stat Cards
                      _buildKpiStatRow(summary, isTablet),
                      const SizedBox(height: 20),

                      // 2.0 Students per class / room / gender (counts only: safe for บุคคลทั่วไป too):
                      // regular classes, and the โปรแกรม 3 รูปแบบ group (locked: no daily check / ปพ.5)
                      if (levels.isNotEmpty) ...[
                        if (levels.any((l) => ((l['program3_breakdown'] as List?) ?? const []).isNotEmpty))
                          ResponsiveFieldsRow(
                            flexes: const [3, 2],
                            spacing: 16,
                            breakpoint: 1000,
                            children: [
                              EnrollmentChart(levels: levels, totalLabel: 'นักเรียนห้องเรียนปกติ'),
                              EnrollmentChart(
                                levels: levels,
                                breakdownKey: 'program3_breakdown',
                                title: 'นักเรียนโปรแกรม 3 รูปแบบ (เรียนและทำงาน)',
                                totalLabel: 'โปรแกรม 3 รูปแบบ',
                                icon: Icons.work_history_rounded,
                              ),
                            ],
                          )
                        else
                          EnrollmentChart(levels: levels),
                        const SizedBox(height: 20),
                      ],

                      // 2.1 Early warning: students forecast to fall below 80% (มส.)
                      if (_riskData != null) ...[
                        _buildRiskPanel(_riskData!),
                        const SizedBox(height: 20),
                      ],

                      // 3. Section Title & Monthly Controls: Top 3 Absentees per Class Level
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.red.shade200),
                                ),
                                child: Icon(Icons.person_off_rounded, color: Colors.red.shade700, size: 20),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        _isMonthlyMode
                                            ? 'สถิติรายเดือน: ขาดเรียนมากที่สุด (${_dashboardData?["month_name"] ?? "รายเดือน"})'
                                            : 'รายงานนักเรียนที่ขาดเรียนมากที่สุดของแต่ละชั้น (3 คนแรก)',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                      ),
                                      if (_isMonthlyMode && _dashboardData?['is_current_month'] == true) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFDCFCE7),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: const Color(0xFF16A34A)),
                                          ),
                                          child: const Text(
                                            'เดือนปัจจุบัน',
                                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF15803D)),
                                          ),
                                        ),
                                      ],
                                      // a month not reached yet: nothing checked, every figure is 0
                                      if (_isMonthlyMode && _dashboardData?['month_not_started'] == true) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF1F5F9),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: const Color(0xFF94A3B8)),
                                          ),
                                          child: const Text(
                                            'ยังไม่ถึงเดือนนี้ • ยังไม่ได้เช็คเวลาเรียน',
                                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  Text(
                                    'ระดับชั้น ม.1 – ม.6 • คลิกที่ชื่อนักเรียนเพื่อดูกราฟสถิติรายเดือน • โหมด: ${_mode == "subject" ? "เวลาเรียนรายวิชา (ปพ.5)" : "เวลาเรียนประจำวัน (โฮมรูม)"}',
                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                  ),
                                ],
                              ),
                            ],
                          ),

                          // Period Mode Selector: [สะสมทั้งเทอม] vs [สถิติรายเดือน]
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: AppColors.gold.withValues(alpha: 0.6)),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.04),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                      borderRadius: BorderRadius.circular(7),
                                      onTap: () => _onTogglePeriodMode(false),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: !_isMonthlyMode ? const Color(0xFF1B0B38) : Colors.transparent,
                                          borderRadius: BorderRadius.circular(7),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.calendar_today_rounded, size: 14, color: !_isMonthlyMode ? Colors.white : Colors.black87),
                                            const SizedBox(width: 4),
                                            Text(
                                              'สะสมทั้งเทอม',
                                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: !_isMonthlyMode ? Colors.white : Colors.black87),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(7),
                                      onTap: () => _onTogglePeriodMode(true),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: _isMonthlyMode ? const Color(0xFF1B0B38) : Colors.transparent,
                                          borderRadius: BorderRadius.circular(7),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.date_range_rounded, size: 14, color: _isMonthlyMode ? Colors.white : Colors.black87),
                                            const SizedBox(width: 4),
                                            Text(
                                              'สถิติรายเดือน',
                                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _isMonthlyMode ? Colors.white : Colors.black87),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Month Dropdown if in monthly mode
                              if (_isMonthlyMode) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: AppColors.gold, width: 1.2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.04),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: DropdownButton<String>(
                                    value: availableMonths.any((m) => m['key'] == _selectedMonth)
                                        ? _selectedMonth
                                        : (availableMonths.isNotEmpty ? availableMonths.first['key'] : 'all'),
                                    underline: const SizedBox.shrink(),
                                    isDense: true,
                                    items: availableMonths.map((m) {
                                      final k = m['key']?.toString() ?? '';
                                      final n = m['name']?.toString() ?? '';
                                      final isCur = k == _dashboardData?['default_month'];
                                      return DropdownMenuItem(
                                        value: k,
                                        child: Text(
                                          isCur ? '$n (เดือนนี้)' : n,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: isCur ? FontWeight.bold : FontWeight.w500,
                                            color: isCur ? const Color(0xFF15803D) : const Color(0xFF1E293B),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                    onChanged: (val) {
                                      if (val != null) _onMonthChanged(val);
                                    },
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // 4. Six Class Level Cards Grid
                      _buildClassCardsGrid(levels, isDesktop, isTablet),
                      const SizedBox(height: 24),

                      // 5. School-wide Watchlist Table
                      _buildSchoolWatchlistCard(filteredSchoolTop),
                      const SizedBox(height: 40),
                      ] else ...[
                        // 2. แดชบอร์ดวันลาและขอเข้าสายของครู (สำหรับผู้อำนวยการ)
                        _buildTeacherLeavesDashboard(theme, isDesktop, isTablet),
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  // -------------------------------------------------------------
  // HEADER TOOLBAR
  // -------------------------------------------------------------
  Widget _buildHeaderToolbar(ThemeData theme, bool isTablet) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: AppColors.purplePrimary.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Title
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.purpleContainer,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
                ),
                child: const Icon(Icons.dashboard_rounded, color: AppColors.purplePrimary, size: 24),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'รายงานผล & แดชบอร์ดสถิติเวลาเรียน',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                  ),
                  Text(
                    'สรุปภาพรวมเวลาเรียนและเฝ้าระวังนักเรียนขาดเรียนสะสม',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ],
          ),

          // Controls
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [
              // Semester Selector with Mark Button inside each row + after selector
              Builder(
                builder: (ctx) {
                  final currentSem = _semesters.where((s) => s.term == _selectedTerm && s.year == _selectedYear).firstOrNull ??
                      (_semesters.isNotEmpty ? _semesters.first : null);
                  final currentTitle = currentSem != null
                      ? (currentSem.title.isNotEmpty ? currentSem.title : 'ภาคเรียนที่ ${currentSem.term}/${currentSem.year}')
                      : 'ปีการศึกษา $_selectedYear ภาคเรียนที่ $_selectedTerm';
                  final isCurrentDefault = currentSem?.isDefault ?? false;
                  final isMyMark = widget.apiService.myMarkedSemester == '$_selectedTerm-$_selectedYear';

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PopupMenuButton<String>(
                        tooltip: 'เลือกภาคเรียน (คลิกปุ่ม Mark หลังภาคเรียนเพื่อตั้งให้แสดงเสมอเมื่อรีเฟรชหรือกดแดชบอร์ด)',
                        offset: const Offset(0, 42),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        onSelected: (val) {
                          final parts = val.split('-');
                          if (parts.length == 2) {
                            _onSemesterChanged(parts[0], parts[1]);
                          }
                        },
                        itemBuilder: (menuCtx) {
                          return _semesters.map((s) {
                            final key = '${s.term}-${s.year}';
                            final isSelected = s.term == _selectedTerm && s.year == _selectedYear;
                            final label = s.title.isNotEmpty ? s.title : 'ภาคเรียนที่ ${s.term}/${s.year}';
                            // ครู/ผอ. เห็นหมุดของตัวเอง ผู้ดูแลระบบเห็นหมุดของโรงเรียน
                            final marked = widget.apiService.isAdmin
                                ? s.isDefault
                                : (widget.apiService.myMarkedSemester == key ||
                                    (widget.apiService.myMarkedSemester == null && s.isDefault));

                            return PopupMenuItem<String>(
                              value: key,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                                    size: 16,
                                    color: isSelected ? const Color(0xFF1E3A8A) : Colors.grey.shade400,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      label,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: isSelected || s.isDefault ? FontWeight.bold : FontWeight.w500,
                                        color: isSelected ? const Color(0xFF1E3A8A) : const Color(0xFF1E293B),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // Mark button right after semester name (ปุ่ม mark หลัง ภาคเรียน)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () {
                                      Navigator.of(menuCtx).pop();
                                      _markDefaultSemester(s.term, s.year);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: marked ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: marked ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            marked ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                                            size: 14,
                                            color: marked ? const Color(0xFF15803D) : const Color(0xFF64748B),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            marked ? 'Mark แล้ว' : 'Mark',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: marked ? const Color(0xFF15803D) : const Color(0xFF475569),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isCurrentDefault ? const Color(0xFF16A34A) : Colors.grey.shade300,
                              width: isCurrentDefault ? 1.4 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                currentTitle,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.arrow_drop_down_rounded, size: 20),
                            ],
                          ),
                        ),
                      ),
                      if (!widget.apiService.isAdmin && widget.apiService.myMarkedSemester != null) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: 'เลิก Mark ของตัวเอง แล้วกลับไปใช้ภาคเรียนเริ่มต้นของโรงเรียน',
                          child: IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.restart_alt_rounded, size: 20),
                            onPressed: () async {
                              await widget.apiService.markMySemester(clear: true);
                              if (!mounted) return;
                              await _loadSemestersAndDashboard(resetToDefault: true);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('กลับไปใช้ภาคเรียนเริ่มต้นของโรงเรียนแล้ว'),
                              ));
                            },
                          ),
                        ),
                      ],
                      const SizedBox(width: 6),
                      // Quick Mark button right after the semester box on toolbar
                      Tooltip(
                        message: widget.apiService.isAdmin
                            ? (isCurrentDefault
                                ? 'ภาคเรียนนี้เป็นค่าเริ่มต้นของทั้งโรงเรียนแล้ว (ทุกคนที่ไม่ได้ Mark เอง จะเห็นเทอมนี้)'
                                : 'กดเพื่อตั้งภาคเรียนนี้เป็นค่าเริ่มต้นของทั้งโรงเรียน')
                            : (isMyMark
                                ? 'ท่าน Mark ภาคเรียนนี้ไว้ดูเองแล้ว'
                                : 'กดเพื่อ Mark ภาคเรียนนี้ไว้ดูเอง (ไม่กระทบคนอื่น)'),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _markDefaultSemester(_selectedTerm, _selectedYear),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: isCurrentDefault ? const Color(0xFFDCFCE7) : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isCurrentDefault ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isCurrentDefault ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
                                  size: 16,
                                  color: isCurrentDefault ? const Color(0xFF15803D) : const Color(0xFF475569),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  isCurrentDefault ? 'Mark แล้ว' : 'Mark เทอมหลัก',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isCurrentDefault ? const Color(0xFF15803D) : const Color(0xFF475569),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(width: 8),

              // Mode Toggle (Subject vs Daily)
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'subject',
                    icon: Icon(Icons.menu_book_rounded, size: 15),
                    label: Text('ปพ.5 (รายวิชา)', style: TextStyle(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: 'daily',
                    icon: Icon(Icons.today_rounded, size: 15),
                    label: Text('โฮมรูม (ประจำวัน)', style: TextStyle(fontSize: 11)),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (set) => _onModeChanged(set.first),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 8),

              // Refresh Button
              IconButton(
                tooltip: 'รีเฟรชข้อมูล (กลับไปยังเทอมที่ Mark ไว้)',
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: _loading ? null : () => _loadSemestersAndDashboard(resetToDefault: true),
              ),

              const SizedBox(width: 8),
              if (widget.apiService.currentUser?.canDownload ?? true)
                App3DButton.primary(
                  icon: Icons.picture_as_pdf_rounded,
                  label: 'สรุปเวลาเรียนทั้งหมด (PDF 80%/60%)',
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  depth: 3.0,
                  onPressed: _openAttendanceSummaryPdfDialog,
                ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // KPI STAT ROW
  // -------------------------------------------------------------
  Widget _buildKpiStatRow(Map<String, dynamic>? summary, bool isTablet) {
    // Whole school, every room: regular students + โปรแกรม 3 รูปแบบ (locked, not in attendance stats)
    final levelsData = (_dashboardData?['levels'] as List?)?.cast<Map>() ?? const [];
    final int totalStudents = levelsData.isEmpty
        ? (summary?['total_students'] as num?)?.toInt() ?? 0
        : levelsData.fold<int>(0, (a, l) => a + ((l['student_count'] as num?)?.toInt() ?? 0) + ((l['locked_count'] as num?)?.toInt() ?? 0));
    final double avgPct = (summary?['average_attendance_pct'] as num?)?.toDouble() ?? 100.0;
    final int atRiskCount = (summary?['at_risk_count'] as num?)?.toInt() ?? 0;
    final int warningCount = (summary?['warning_count'] as num?)?.toInt() ?? 0;
    final bool notStarted = _isMonthlyMode && _dashboardData?['month_not_started'] == true; // 0% = not checked yet

    final cards = [
      _buildStatCard(
        title: 'นักเรียนทั้งหมด',
        value: '$totalStudents คน',
        subtitle: 'รวม 6 ระดับชั้น (ม.1 – ม.6)',
        icon: Icons.people_alt_rounded,
        color: AppColors.purplePrimary,
        badgeText: '6 ระดับชั้น',
      ),
      _buildStatCard(
        title: 'อัตราการมาเรียนเฉลี่ย',
        value: '$avgPct%',
        subtitle: 'เกณฑ์ ปพ.5 มาตรฐาน ไม่ต่ำกว่า 80%',
        icon: Icons.percent_rounded,
        color: notStarted ? Colors.blueGrey : (avgPct >= 80 ? Colors.teal : Colors.red),
        badgeText: notStarted ? 'ยังไม่ถึงเดือนนี้' : (avgPct >= 80 ? 'ผ่านเกณฑ์ภาพรวม' : 'ต่ำกว่าเกณฑ์'),
      ),
      _buildStatCard(
        title: 'กลุ่มเสี่ยงขาดเรียนสูง',
        value: '$atRiskCount คน',
        subtitle: 'เกณฑ์ ปพ.5 มาตรฐาน ไม่ต่ำกว่า 80%',
        icon: Icons.warning_amber_rounded,
        color: atRiskCount > 0 ? Colors.red.shade700 : Colors.green,
        badgeText: atRiskCount > 0 ? 'เฝ้าระวังเข้มงวด' : 'ไม่มีกลุ่มเสี่ยง',
      ),
      _buildStatCard(
        title: 'กลุ่มเฝ้าระวัง',
        value: '$warningCount คน',
        subtitle: 'เกณฑ์ ปพ.5 มาตรฐาน ไม่ต่ำกว่า 80%',
        icon: Icons.remove_circle_outline_rounded,
        color: Colors.orange.shade700,
        badgeText: 'ใกล้แตะเกณฑ์',
      ),
    ];

    if (isTablet) {
      return Row(
        children: cards.map((c) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: c))).toList(),
      );
    } else {
      return Column(
        children: cards.map((c) => Padding(padding: const EdgeInsets.only(bottom: 8), child: c)).toList(),
      );
    }
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required String badgeText,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: AppColors.purplePrimary.withValues(alpha: 0.03),
            blurRadius: 4,
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
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // EARLY WARNING มส. (Beta-Binomial forecast from /dashboard/attendance-risk)
  // -------------------------------------------------------------
  static const Map<String, Color> _riskColors = {
    'หมดสิทธิ์ (มส.)': Color(0xFF991B1B),
    'เสี่ยงสูง': Color(0xFFDC2626),
    'เฝ้าระวัง': Color(0xFFD97706),
    'ปกติ': Color(0xFF15803D),
  };

  Widget _buildRiskPanel(Map<String, dynamic> risk) {
    final summary = (risk['summary'] as Map?)?.cast<String, dynamic>() ?? {};
    final students = (risk['students'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final flagged = students.where((s) => s['worst_level'] != 'ปกติ').toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_rounded, color: Colors.red.shade700, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'เฝ้าระวังเวลาเรียนไม่ถึง 80% (มส.) — พยากรณ์รายวิชา',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              Text('ข้อมูลถึง ${risk['as_of'] ?? ''}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'คำนวณจากชั่วโมงที่สอนไปแล้วตามตารางสอน (ไม่นับวันหยุด) และคาดการณ์ชั่วโมงที่เหลือด้วยแบบจำลอง Beta-Binomial',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _riskColors.entries.map((e) {
              return Chip(
                visualDensity: VisualDensity.compact,
                backgroundColor: e.value.withValues(alpha: 0.08),
                side: BorderSide(color: e.value.withValues(alpha: 0.4)),
                label: Text('${e.key}: ${summary[e.key] ?? 0} คน',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: e.value)),
              );
            }).toList(),
          ),
          if (flagged.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...flagged.take(15).map((s) {
              final courses = (s['courses_at_risk'] as List?)?.cast<Map<String, dynamic>>() ?? [];
              final color = _riskColors[s['worst_level']] ?? Colors.grey;
              final worst = courses.isNotEmpty ? courses.first : null;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: color.withValues(alpha: 0.12),
                  child: Text('${courses.length}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
                ),
                title: Text('${s['class_level']}/${s['room'] ?? '1'}  ${s['full_name'] ?? ''}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  [
                    if (worst != null)
                      '${worst['course_code']} ${worst['course_name'] ?? ''}: คาดการณ์ ${worst['projected_pct']}% • ขาดได้อีก ${worst['can_still_miss_hours']} ชม.',
                    if (s['absence_pattern'] != null) s['absence_pattern'].toString(),
                  ].join('\n'),
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                ),
                trailing: Text(s['worst_level'].toString(),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
              );
            }),
            if (flagged.length > 15)
              Text('และอีก ${flagged.length - 15} คน', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // CLASS CARDS GRID (ม.1 – ม.6)
  // -------------------------------------------------------------
  Widget _buildClassCardsGrid(List<Map<String, dynamic>> levels, bool isDesktop, bool isTablet) {
    if (levels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            children: [
              Icon(Icons.school_outlined, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              const Text('ยังไม่มีข้อมูลระดับชั้นในภาคเรียนนี้', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    int crossAxisCount = 1;
    if (isDesktop) {
      crossAxisCount = 3;
    } else if (isTablet) {
      crossAxisCount = 2;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final double itemWidth = (constraints.maxWidth - (crossAxisCount - 1) * 14) / crossAxisCount;

        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: levels.map((lvl) {
            return SizedBox(
              width: itemWidth,
              child: _buildSingleClassCard(lvl),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildSingleClassCard(Map<String, dynamic> lvl) {
    final String classLevel = lvl['class_level']?.toString() ?? '';
    final int count = (lvl['student_count'] as num?)?.toInt() ?? 0;
    final double avgPct = (lvl['average_pct'] as num?)?.toDouble() ?? 100.0;
    final String unit = lvl['unit']?.toString() ?? (_mode == 'subject' ? 'คาบ' : 'วัน');
    final List<Map<String, dynamic>> topAbsent = (lvl['top_absent'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final bool hasAbsences = lvl['has_absences'] == true;
    final String genderText = lvl['gender_text']?.toString() ?? '';
    final List<Map<String, dynamic>> roomsBreakdown =
        (lvl['rooms_breakdown'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final bool notStarted = _isMonthlyMode && _dashboardData?['month_not_started'] == true; // month not reached yet

    Color headerColor;
    if (notStarted) {
      headerColor = Colors.blueGrey.shade600;
    } else if (avgPct >= 85) {
      headerColor = Colors.teal.shade800;
    } else if (avgPct >= 80) {
      headerColor = Colors.orange.shade800;
    } else {
      headerColor = Colors.red.shade800;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: AppColors.purplePrimary.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Card Header (แถบสีม่วงของแต่ละชั้น)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.purpleContainer,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(13),
                topRight: Radius.circular(13),
              ),
              border: Border(bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.3))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // แถวบน: ไอคอน, ระดับชั้น, จำนวนคนรวม, เปอร์เซ็นต์เฉลี่ย
                Row(
                  children: [
                    const Icon(Icons.school_rounded, color: AppColors.purplePrimary, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'ระดับชั้น $classLevel',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: AppColors.purpleDark),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
                      ),
                      child: Text(
                        '$count คน',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: headerColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'เฉลี่ย $avgPct%',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: headerColor),
                      ),
                    ),
                  ],
                ),
                // แถวล่าง: แจกแจงห้องและเพศ ช / ญ พอดีไม่เกินขอบ
                if (roomsBreakdown.isNotEmpty || genderText.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.gold.withValues(alpha: 0.25), width: 0.8),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: (roomsBreakdown.isNotEmpty
                              ? roomsBreakdown
                              : [
                                  {'room': '1', 'text': genderText}
                                ])
                          .map((rmData) {
                        final String rm = rmData['room']?.toString() ?? '1';
                        final int m = (rmData['male'] as num?)?.toInt() ?? 0;
                        final int f = (rmData['female'] as num?)?.toInt() ?? 0;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'ห้อง $rm : ',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF334155),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                'ช $m',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue.shade800,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.pink.shade50,
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                'ญ $f',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.pink.shade700,
                                ),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 2. Card Content: Top 3 Absentees
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: count == 0
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'ไม่มีรายชื่อนักเรียนในชั้นนี้',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                  )
                : notStarted
                    ? Container(
                        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                        alignment: Alignment.center,
                        child: Column(
                          children: [
                            Icon(Icons.event_rounded, size: 36, color: Colors.blueGrey.shade300),
                            const SizedBox(height: 6),
                            Text(
                              'ยังไม่ถึงเดือนนี้',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blueGrey.shade700),
                            ),
                            Text(
                              'ยังไม่ได้เช็คเวลาเรียน (0%)',
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      )
                : !hasAbsences && _mode == 'daily'
                    ? Container(
                        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                        alignment: Alignment.center,
                        child: Column(
                          children: [
                            Icon(Icons.sentiment_very_satisfied_rounded, size: 36, color: Colors.teal.shade400),
                            const SizedBox(height: 6),
                            const Text(
                              'นักเรียนทุกคนมาเรียนครบ 100%',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.teal),
                            ),
                            Text(
                              'ไม่มีการบันทึกการขาดเรียนในโฮมรูม',
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      )
                    : Column(
                        children: topAbsent.map((st) {
                          return _buildStudentRankRow(st, unit, classLevel);
                        }).toList(),
                      ),
          ),

          // 3. Card Footer Action
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(13),
                bottomRight: Radius.circular(13),
              ),
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'เกณฑ์เวลาเรียน: 80% (ปพ.5)',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.arrow_forward_rounded, size: 14),
                  label: const Text('เช็คเวลาเรียนชั้นนี้', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Colors.indigo.shade700,
                  ),
                  onPressed: () {
                    widget.onNavigateToAttendance?.call(classLevel);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudentRankRow(Map<String, dynamic> st, String unit, String classLevel) {
    final int rank = (st['rank'] as num?)?.toInt() ?? 1;
    final int studentNo = (st['student_no'] as num?)?.toInt() ?? 0;
    final String studentId = st['student_id']?.toString() ?? '';
    final String fullName = st['full_name']?.toString() ?? '';
    final String room = st['room']?.toString() ?? '1';
    final int absent = (st['effective_absent'] as num?)?.toInt() ?? 0;
    final int present = (st['effective_present'] as num?)?.toInt() ?? 0;
    final int leave = (st['effective_leave'] as num?)?.toInt() ?? 0;
    final int late = (st['effective_late'] as num?)?.toInt() ?? (st['late_count'] as num?)?.toInt() ?? 0;
    final double pct = (st['percentage'] as num?)?.toDouble() ?? 100.0;
    final String risk = st['risk_status']?.toString() ?? 'normal';

    Color rankColor;
    Color rankBg;
    if (rank == 1) {
      rankColor = Colors.red.shade900;
      rankBg = Colors.red.shade100;
    } else if (rank == 2) {
      rankColor = Colors.orange.shade900;
      rankBg = Colors.orange.shade100;
    } else {
      rankColor = Colors.amber.shade900;
      rankBg = Colors.amber.shade100;
    }

    Color pctColor = pct >= 80 ? Colors.teal.shade800 : (pct >= 60 ? Colors.orange.shade800 : Colors.red.shade700);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (widget.apiService.isGuest) return; // individual student data: not for guests
          StudentMonthlyGraphDialog.show(
            context,
            apiService: widget.apiService,
            term: _selectedTerm,
            year: _selectedYear,
            studentId: studentId,
            studentName: fullName,
            classLevel: classLevel,
            room: room,
            mode: _mode,
          );
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: rank == 1 && absent > 0 ? Colors.red.shade50.withValues(alpha: 0.35) : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: rank == 1 && absent > 0 ? Colors.red.shade200 : Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Rank Badge
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: rankBg,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$rank',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: rankColor),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Student Info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'เลขที่ $studentNo • $studentId',
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                        ),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                fullName,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E3A8A),
                                  decoration: TextDecoration.underline,
                                  decorationColor: Color(0xFF93C5FD),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.insights_rounded, size: 14, color: Colors.indigo.shade600),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Absent Badge
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: absent > 0 ? Colors.red.shade50 : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: absent > 0 ? Colors.red.shade300 : Colors.grey.shade300),
                        ),
                        child: Text(
                          'ขาด $absent $unit',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: absent > 0 ? Colors.red.shade800 : Colors.grey.shade700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'มา $present${late > 0 ? " • สาย $late" : ""} • ลา $leave',
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // Percentage Bar & Risk Pill
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (pct / 100.0).clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          pct >= 85 ? Colors.teal : (pct >= 80 ? Colors.orange : Colors.red),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$pct%',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: pctColor),
                  ),
                  if (risk == 'critical') ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.red.shade700,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'เสี่ยง มส.',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // SCHOOL-WIDE WATCHLIST CARD & TABLE
  // -------------------------------------------------------------
  Widget _buildSchoolWatchlistCard(List<Map<String, dynamic>> schoolTop) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: AppColors.purplePrimary.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.format_list_numbered_rounded, color: AppColors.purplePrimary, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'ตารางเฝ้าระวังนักเรียนขาดเรียนสะสมทั่วทั้งโรงเรียน (Top 15)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                    ),
                  ],
                ),
                // Search box
                SizedBox(
                  width: 220,
                  height: 34,
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'ค้นหาชื่อ, รหัส, ชั้น...',
                      hintStyle: const TextStyle(fontSize: 11),
                      prefixIcon: const Icon(Icons.search, size: 16),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                    ),
                    onChanged: (val) => setState(() => _tableSearchQuery = val),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Table
          if (schoolTop.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24.0),
              child: Center(
                child: Text('ไม่มีข้อมูลที่ตรงกับคำค้นหา', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 40,
                dataRowMinHeight: 40,
                dataRowMaxHeight: 46,
                headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),
                columns: const [
                  DataColumn(label: Text('อันดับ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('ชั้น', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('เลขที่', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('รหัสนักเรียน', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('ชื่อ - นามสกุล (คลิกดูกราฟ)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('จำนวนที่ขาด', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('จำนวนที่มา', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('% เวลาเรียน', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('สถานะความเสี่ยง', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('กราฟรายเดือน', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                ],
                rows: schoolTop.asMap().entries.map((entry) {
                  final idx = entry.key + 1;
                  final st = entry.value;
                  final int absent = (st['effective_absent'] as num?)?.toInt() ?? 0;
                  final int present = (st['effective_present'] as num?)?.toInt() ?? 0;
                  final double pct = (st['percentage'] as num?)?.toDouble() ?? 100.0;
                  final String unit = st['unit']?.toString() ?? (_mode == 'subject' ? 'คาบ' : 'วัน');
                  final String studentId = st['student_id']?.toString() ?? '';
                  final String fullName = st['full_name']?.toString() ?? '';
                  final String classLevel = st['class_level']?.toString() ?? '';
                  final String room = st['room']?.toString() ?? '1';

                  Color statusBg;
                  Color statusText;
                  String statusLabel;
                  if (pct < 80.0) {
                    statusBg = Colors.red.shade100;
                    statusText = Colors.red.shade900;
                    statusLabel = '🚨 เสี่ยง มส. (<80%)';
                  } else if (pct < 85.0 || absent > 0) {
                    statusBg = Colors.orange.shade100;
                    statusText = Colors.orange.shade900;
                    statusLabel = '⚠️ เฝ้าระวัง';
                  } else {
                    statusBg = Colors.green.shade100;
                    statusText = Colors.green.shade900;
                    statusLabel = '✅ ปกติ';
                  }

                  return DataRow(
                    cells: [
                      DataCell(Center(child: Text('$idx', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)))),
                      DataCell(Text(classLevel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                      DataCell(Center(child: Text('${st['student_no']}'))),
                      DataCell(Text(studentId, style: TextStyle(color: Colors.grey.shade800, fontSize: 12))),
                      DataCell(
                        InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () {
                            if (widget.apiService.isGuest) return; // individual student data: not for guests
                            StudentMonthlyGraphDialog.show(
                              context,
                              apiService: widget.apiService,
                              term: _selectedTerm,
                              year: _selectedYear,
                              studentId: studentId,
                              studentName: fullName,
                              classLevel: classLevel,
                              room: room,
                              mode: _mode,
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  fullName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    color: Color(0xFF1E3A8A),
                                    decoration: TextDecoration.underline,
                                    decorationColor: Color(0xFF93C5FD),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.insights_rounded, size: 14, color: Color(0xFF2563EB)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          '$absent $unit',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: absent > 0 ? Colors.red.shade800 : Colors.grey.shade700,
                          ),
                        ),
                      ),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$present $unit', style: const TextStyle(fontSize: 12)),
                            if (((st['effective_late'] ?? st['late_count']) as num? ?? 0) > 0)
                              Container(
                                margin: const EdgeInsets.only(left: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade50,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.blue.shade200, width: 0.5),
                                ),
                                child: Text(
                                  'สาย ${st['effective_late'] ?? st['late_count']}',
                                  style: TextStyle(fontSize: 10, color: Colors.blue.shade900, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                      ),
                      DataCell(
                        Text(
                          '$pct%',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: pct >= 80 ? Colors.teal.shade800 : (pct >= 60 ? Colors.orange.shade800 : Colors.red.shade800),
                          ),
                        ),
                      ),
                      DataCell(
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: statusBg,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            statusLabel,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusText),
                          ),
                        ),
                      ),
                      DataCell(
                        IconButton(
                          icon: const Icon(Icons.bar_chart_rounded, size: 20, color: Color(0xFF1E3A8A)),
                          tooltip: 'ดูกราฟการขาดเรียนรายเดือนของ $fullName',
                          onPressed: () {
                            if (widget.apiService.isGuest) return; // individual student data: not for guests
                            StudentMonthlyGraphDialog.show(
                              context,
                              apiService: widget.apiService,
                              term: _selectedTerm,
                              year: _selectedYear,
                              studentId: studentId,
                              studentName: fullName,
                              classLevel: classLevel,
                              room: room,
                              mode: _mode,
                            );
                          },
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }


  // ===========================================================================
  // TEACHER LEAVES DASHBOARD (สำหรับ ผู้อำนวยการ / ผู้ดูแลระบบ)
  // ===========================================================================

  /// reloadView: โหลดส่วนใครไม่อยู่/สถิติรายช่วงใหม่ด้วย (ไม่ต้องตอนเปิดหน้าครั้งแรก เพราะส่วนนั้นโหลดเองอยู่แล้ว)
  Future<void> _loadTeacherLeavesSummary({bool reloadView = true}) async {
    if (!mounted) return;
    setState(() {
      _loadingTeacherLeaves = true;
      _teacherLeavesError = null;
    });
    try {
      final data = await widget.apiService.getLeavesSummaryByTeacher();
      if (mounted) {
        setState(() {
          _teacherLeavesSummary = data;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _teacherLeavesError = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingTeacherLeaves = false;
        });
      }
    }
    if (reloadView) _teacherViewKey.currentState?.reload();
  }

  Future<void> _handleUpdateLeaveStatus(int leaveId, String newStatus, VoidCallback onSuccess) async {
    try {
      await widget.apiService.updateLeaveStatus(leaveId, newStatus);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: newStatus == 'approved' ? Colors.green.shade800 : Colors.red.shade800,
            content: Text(newStatus == 'approved' ? 'อนุมัติคำขอเรียบร้อยแล้ว' : 'ไม่อนุมัติคำขอนี้แล้ว'),
          ),
        );
      }
      await _loadTeacherLeavesSummary();
      onSuccess();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('อัปเดตสถานะไม่สำเร็จ: $e'),
          ),
        );
      }
    }
  }

  String _formatLeaveDate(String? start, String? end) {
    if (start == null || start.isEmpty) return '-';
    if (end == null || end.isEmpty || start == end) {
      return _formatThaiDateStr(start);
    }
    return '${_formatThaiDateStr(start)} ถึง ${_formatThaiDateStr(end)}';
  }

  String _formatThaiDateStr(String dateStr) {
    try {
      final parts = dateStr.split('-');
      if (parts.length == 3) {
        final y = int.parse(parts[0]) + 543;
        final m = int.parse(parts[1]);
        final d = int.parse(parts[2]);
        const months = [
          '', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.',
          'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'
        ];
        return '$d ${months[m]} $y';
      }
    } catch (_) {}
    return dateStr;
  }

  /// Toggle bar switching between [นักเรียน] and [ครู]
  Widget _buildTargetToggle(bool isTablet) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gold, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 10,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF3B1E54), Color(0xFF1B0B38)],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.purplePrimary.withValues(alpha: 0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(Icons.admin_panel_settings_rounded, color: Color(0xFFFFD95A), size: 22),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(
                    builder: (context) {
                      final isPersonnelHead = widget.apiService.isPersonnelHead || widget.apiService.currentUser?.code == '102';
                      final isDirector = widget.apiService.isDirector;
                      final titleText = isDirector
                          ? 'มุมมองแดชบอร์ดผู้อำนวยการ'
                          : (isPersonnelHead
                              ? 'มุมมองแดชบอร์ดหัวหน้าบุคคล (${widget.apiService.currentUser?.name ?? ''})'
                              : 'มุมมองแดชบอร์ดผู้ดูแลระบบ');
                      final subtitleText = isPersonnelHead
                          ? 'สลับข้อมูลระหว่างแดชบอร์ดนักเรียน และสถิติวันลา/เข้าสายของครูทุกคน (สิทธิ์หัวหน้าบุคคล)'
                          : 'สลับข้อมูลระหว่างแดชบอร์ดนักเรียน และข้อมูลวันลา/เข้าสายของครู';

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            titleText,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                          Text(
                            subtitleText,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ],
          ),

          // Two-button toggle: [นักเรียน] & [ครู]
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFCBD5E1)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildToggleButton(
                  title: 'นักเรียน',
                  subtitle: 'แดชบอร์ดเวลาเรียนเดิม',
                  icon: Icons.school_rounded,
                  isSelected: _dashboardTarget == 'student',
                  onTap: () {
                    if (_dashboardTarget != 'student') {
                      setState(() => _dashboardTarget = 'student');
                    }
                  },
                ),
                const SizedBox(width: 6),
                _buildToggleButton(
                  title: 'ครู',
                  subtitle: 'ข้อมูลวันลา / เข้าสาย',
                  icon: Icons.badge_rounded,
                  isSelected: _dashboardTarget == 'teacher',
                  onTap: () {
                    if (_dashboardTarget != 'teacher') {
                      setState(() => _dashboardTarget = 'teacher');
                      if (_teacherLeavesSummary.isEmpty) {
                        _loadTeacherLeavesSummary(reloadView: false);
                      }
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleButton({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: isSelected
                ? const LinearGradient(
                    colors: [Color(0xFF3B1E54), Color(0xFF1B0B38)],
                  )
                : null,
            color: isSelected ? null : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: const Color(0xFF1B0B38).withValues(alpha: 0.25),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected ? const Color(0xFFFFD95A) : const Color(0xFF475569),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? Colors.white : const Color(0xFF1E293B),
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: isSelected ? const Color(0xFFFFD95A).withValues(alpha: 0.9) : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Teacher Leaves Dashboard Body
  Widget _buildTeacherLeavesDashboard(ThemeData theme, bool isDesktop, bool isTablet) {
    if (_loadingTeacherLeaves && _teacherLeavesSummary.isEmpty) {
      return Container(
        height: 320,
        alignment: Alignment.center,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'กำลังโหลดข้อมูลสถิติการลาของครู...',
              style: TextStyle(fontSize: 14, color: Color(0xFF1E293B)),
            ),
          ],
        ),
      );
    }

    if (_teacherLeavesError != null) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.red.shade300),
        ),
        child: Column(
          children: [
            Icon(Icons.error_outline_rounded, size: 48, color: Colors.red.shade700),
            const SizedBox(height: 12),
            Text(
              'เกิดข้อผิดพลาดในการโหลดข้อมูล: $_teacherLeavesError',
              style: TextStyle(color: Colors.red.shade800, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadTeacherLeavesSummary,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('ลองใหม่อีกครั้ง'),
            ),
          ],
        ),
      );
    }

    final filteredTeachers = _teacherLeavesSummary.where((t) {
      if (_teacherSearchQuery.trim().isEmpty) return true;
      final q = _teacherSearchQuery.trim().toLowerCase();
      final name = (t['teacher_name'] ?? '').toString().toLowerCase();
      final code = (t['teacher_code'] ?? '').toString().toLowerCase();
      return name.contains(q) || code.contains(q);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Teacher Dashboard Header Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
            boxShadow: [
              BoxShadow(
                color: AppColors.purplePrimary.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Wrap(
            spacing: 12,
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
                      color: AppColors.purpleContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
                    ),
                    child: const Icon(Icons.badge_rounded, color: AppColors.purplePrimary, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ครูไม่อยู่วันนี้ & สถิติวันลา วันขอเข้าสายของครู',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                        ),
                        Text(
                          'ใครไม่อยู่ในแต่ละวัน (เชื่อมตารางสอน) สถิติรายสัปดาห์ รายเดือน และประวัติการลาของครูทุกคน',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // Action buttons: Refresh
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: _loadingTeacherLeaves ? null : _loadTeacherLeavesSummary,
                    icon: _loadingTeacherLeaves
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('รีเฟรชข้อมูล'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.purplePrimary,
                      side: const BorderSide(color: AppColors.gold),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 2. ใครไม่อยู่ในแต่ละวัน (เชื่อมตารางสอน) + สถิติรายสัปดาห์ / เดือน / ทั้งภาคเรียน พร้อมกราฟ
        TeacherDashboardView(key: _teacherViewKey, apiService: widget.apiService),
        const SizedBox(height: 24),

        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'ประวัติการลาและการอนุมัติของครูแต่ละคน',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
          ),
        ),

        // 3. Search Bar & Count
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded, color: Colors.grey.shade600, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'ค้นหาด้วยชื่อ - นามสกุล หรือรหัสครู...',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: const TextStyle(fontSize: 14),
                  onChanged: (val) {
                    setState(() => _teacherSearchQuery = val);
                  },
                ),
              ),
              if (_teacherSearchQuery.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 18),
                  onPressed: () {
                    setState(() => _teacherSearchQuery = '');
                  },
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'แสดง ${filteredTeachers.length} จาก ${_teacherLeavesSummary.length} ท่าน',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 4. Teacher Leave Summary Table
        _buildTeacherLeavesTable(filteredTeachers, isDesktop),
        const SizedBox(height: 40),
      ],
    );
  }

  /// Teacher Leaves Summary Table
  Widget _buildTeacherLeavesTable(List<Map<String, dynamic>> teachers, bool isDesktop) {
    if (teachers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
        ),
        alignment: Alignment.center,
        child: Column(
          children: [
            Icon(Icons.search_off_rounded, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text(
              'ไม่พบข้อมูลครูตามคำค้นหา',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 950),
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(const Color(0xFFF8FAFC)),
              headingRowHeight: 48,
              dataRowMinHeight: 56,
              dataRowMaxHeight: 64,
              horizontalMargin: 20,
              columnSpacing: 24,
              columns: const [
                DataColumn(label: Text('ลำดับ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                DataColumn(label: Text('รหัส', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                DataColumn(label: Text('ชื่อ - นามสกุลครู', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                DataColumn(label: Center(child: Text('ลากิจ (ครั้ง/วัน)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFD97706))))),
                DataColumn(label: Center(child: Text('ลาป่วย (ครั้ง/วัน)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFDC2626))))),
                DataColumn(label: Center(child: Text('ขอเข้าสาย (ครั้ง)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF4F46E5))))),
                DataColumn(label: Center(child: Text('รวมวันลาสะสม (ครั้ง/วัน)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1B0B38))))),
                DataColumn(label: Center(child: Text('รายละเอียด & เหตุผล', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)))),
              ],
              rows: teachers.asMap().entries.map((entry) {
                final idx = entry.key + 1;
                final t = entry.value;
                final code = (t['teacher_code'] ?? '').toString();
                final name = (t['teacher_name'] ?? '').toString();
                final leaves = (t['leaves'] as List?)?.cast<Map<String, dynamic>>() ?? [];
                final kijLeaves = leaves.where((l) => l['leave_type'] == 'ลากิจ').toList();
                final puayLeaves = leaves.where((l) => l['leave_type'] == 'ลาป่วย').toList();
                final lateLeaves = leaves.where((l) => l['leave_type'] == 'ขอเข้าสาย').toList();

                final kijTimes = t['total_kij_times'] as int? ?? kijLeaves.length;
                final kijDays = t['total_kij_days'] as int? ?? kijLeaves.fold<int>(0, (sum, l) => sum + (l['days_count'] as int? ?? 1));

                final puayTimes = t['total_puay_times'] as int? ?? puayLeaves.length;
                final puayDays = t['total_puay_days'] as int? ?? puayLeaves.fold<int>(0, (sum, l) => sum + (l['days_count'] as int? ?? 1));

                final lateTimes = t['total_late_count'] as int? ?? (t['total_late_times'] as int? ?? lateLeaves.length);
                final totalLeaveTimes = kijTimes + puayTimes;
                final totalLeaveDays = kijDays + puayDays;

                return DataRow(
                  color: WidgetStateProperty.resolveWith<Color?>((states) {
                    if (states.contains(WidgetState.hovered)) return const Color(0xFFF1F5F9);
                    return entry.key.isEven ? Colors.white : const Color(0xFFFAFAFA);
                  }),
                  cells: [
                    DataCell(Text('$idx', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)))),
                    DataCell(
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Text(
                          code,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF334155)),
                        ),
                      ),
                    ),
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: AppColors.purpleContainer,
                            child: const Icon(Icons.person, size: 16, color: AppColors.purplePrimary),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B)),
                          ),
                        ],
                      ),
                    ),
                    DataCell(
                      Center(
                        child: kijTimes > 0
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFEF3C7),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
                                ),
                                child: Text(
                                  '$kijTimes ครั้ง ($kijDays วัน)',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Color(0xFFB45309)),
                                ),
                              )
                            : const Text('-', style: TextStyle(color: Color(0xFF94A3B8))),
                      ),
                    ),
                    DataCell(
                      Center(
                        child: puayTimes > 0
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFEE2E2),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.5)),
                                ),
                                child: Text(
                                  '$puayTimes ครั้ง ($puayDays วัน)',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Color(0xFFB91C1C)),
                                ),
                              )
                            : const Text('-', style: TextStyle(color: Color(0xFF94A3B8))),
                      ),
                    ),
                    DataCell(
                      Center(
                        child: lateTimes > 0
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE0E7FF),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.5)),
                                ),
                                child: Text(
                                  '$lateTimes ครั้ง',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Color(0xFF4338CA)),
                                ),
                              )
                            : const Text('-', style: TextStyle(color: Color(0xFF94A3B8))),
                      ),
                    ),
                    DataCell(
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: totalLeaveTimes > 0 ? const Color(0xFFF3E8FF) : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: totalLeaveTimes > 0
                                  ? const Color(0xFFA855F7).withValues(alpha: 0.5)
                                  : const Color(0xFFE2E8F0),
                            ),
                          ),
                          child: Text(
                            totalLeaveTimes > 0 ? '$totalLeaveTimes ครั้ง ($totalLeaveDays วัน)' : '0 ครั้ง (0 วัน)',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                              color: totalLeaveTimes > 0 ? const Color(0xFF7E22CE) : const Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ),
                    ),
                    DataCell(
                      Center(
                        child: ElevatedButton.icon(
                          onPressed: () => _showTeacherLeaveDetailDialog(t),
                          icon: const Icon(Icons.description_rounded, size: 15),
                          label: Text(leaves.isNotEmpty ? 'ดูประวัติ (${leaves.length})' : 'ดูข้อมูล'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: leaves.isNotEmpty ? AppColors.purplePrimary : const Color(0xFF475569),
                            foregroundColor: Colors.white,
                            elevation: 1,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
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
    );
  }

  /// Dialog showing leave records and reasons for a specific teacher
  void _showTeacherLeaveDetailDialog(Map<String, dynamic> teacher) {
    final code = (teacher['teacher_code'] ?? '').toString();
    final name = (teacher['teacher_name'] ?? '').toString();
    final leaves = (teacher['leaves'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final kijLeaves = leaves.where((l) => l['leave_type'] == 'ลากิจ').toList();
    final puayLeaves = leaves.where((l) => l['leave_type'] == 'ลาป่วย').toList();
    final lateLeaves = leaves.where((l) => l['leave_type'] == 'ขอเข้าสาย').toList();

    final kijTimes = teacher['total_kij_times'] as int? ?? kijLeaves.length;
    final kijDays = teacher['total_kij_days'] as int? ?? kijLeaves.fold<int>(0, (s, l) => s + (l['days_count'] as int? ?? 1));

    final puayTimes = teacher['total_puay_times'] as int? ?? puayLeaves.length;
    final puayDays = teacher['total_puay_days'] as int? ?? puayLeaves.fold<int>(0, (s, l) => s + (l['days_count'] as int? ?? 1));

    final lateTimes = teacher['total_late_count'] as int? ?? (teacher['total_late_times'] as int? ?? lateLeaves.length);
    final totalLeaveTimes = kijTimes + puayTimes;
    final totalLeaveDays = kijDays + puayDays;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (dialogCtx, setDialogState) {
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Container(
              width: 780,
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Dialog Header
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF3B1E54), Color(0xFF1B0B38)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.person_outline_rounded, color: Color(0xFFFFD95A), size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'รหัสประจำตัวครู: $code • ข้อมูลประวัติการลาและขอเข้าสาย',
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Mini Stats Summary
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceAround,
                      children: [
                        _buildDialogStatChip(label: 'ลากิจสะสม', value: '$kijTimes ครั้ง ($kijDays วัน)', color: const Color(0xFFD97706)),
                        _buildDialogStatChip(label: 'ลาป่วยสะสม', value: '$puayTimes ครั้ง ($puayDays วัน)', color: const Color(0xFFDC2626)),
                        _buildDialogStatChip(label: 'ขอเข้าสาย', value: '$lateTimes ครั้ง', color: const Color(0xFF4F46E5)),
                        _buildDialogStatChip(label: 'รวมวันลาสะสม', value: '$totalLeaveTimes ครั้ง ($totalLeaveDays วัน)', color: const Color(0xFF7E22CE)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  // Section Title
                  Row(
                    children: [
                      const Icon(Icons.history_rounded, size: 20, color: Color(0xFF475569)),
                      const SizedBox(width: 8),
                      Text(
                        'รายการขอลาและขอเข้าสาย (${leaves.length} รายการ)',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1E293B)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Leaves List
                  Expanded(
                    child: leaves.isEmpty
                        ? Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.all(40),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.sentiment_satisfied_alt_rounded, size: 54, color: Colors.green.shade400),
                                const SizedBox(height: 12),
                                const Text(
                                  'ไม่มีประวัติการลาหรือขอเข้าสาย',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'คุณครูท่านนี้ยังไม่เคยยื่นใบลากิจ ลาป่วย หรือขอเข้าสายในระบบ',
                                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: leaves.length,
                            separatorBuilder: (_, index) => const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final item = leaves[index];
                              final leaveId = item['id'] as int? ?? 0;
                              final type = item['leave_type']?.toString() ?? '-';
                              final startDate = item['start_date']?.toString() ?? '-';
                              final endDate = item['end_date']?.toString() ?? '-';
                              final days = item['days_count'] as int? ?? 1;
                              final reason = item['reason']?.toString() ?? '-';
                              final phone = item['phone']?.toString();
                              final lateTime = item['late_time']?.toString();
                              final status = item['status']?.toString() ?? 'pending';
                              final createdAt = item['created_at']?.toString() ?? '';

                              Color badgeColor;
                              Color badgeBg;
                              IconData badgeIcon;
                              if (type == 'ลากิจ') {
                                badgeColor = const Color(0xFFD97706);
                                badgeBg = const Color(0xFFFEF3C7);
                                badgeIcon = Icons.business_center_rounded;
                              } else if (type == 'ลาป่วย') {
                                badgeColor = const Color(0xFFDC2626);
                                badgeBg = const Color(0xFFFEE2E2);
                                badgeIcon = Icons.local_hospital_rounded;
                              } else {
                                badgeColor = const Color(0xFF4F46E5);
                                badgeBg = const Color(0xFFEEF2FF);
                                badgeIcon = Icons.access_time_rounded;
                              }

                              return Container(
                                padding: const EdgeInsets.all(16),
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
                                    // Header: Badges & Status
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: badgeBg,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(badgeIcon, size: 14, color: badgeColor),
                                              const SizedBox(width: 6),
                                              Text(
                                                type,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12.5,
                                                  color: badgeColor,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF1F5F9),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            type == 'ขอเข้าสาย' ? '1 ครั้ง' : '1 ครั้ง ($days วัน)',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                              color: Color(0xFF475569),
                                            ),
                                          ),
                                        ),
                                        const Spacer(),
                                        _buildStatusBadge(status),
                                      ],
                                    ),
                                    const SizedBox(height: 10),

                                    // Dates / Times
                                    Row(
                                      children: [
                                        Icon(Icons.calendar_month_rounded, size: 16, color: Colors.grey.shade600),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            type == 'ขอเข้าสาย'
                                                ? 'วันที่: ${_formatThaiDateStr(startDate)} (ขอเข้าสาย 1 ครั้ง)'
                                                : 'ช่วงวันที่: ${_formatLeaveDate(startDate, endDate)} (1 ครั้ง $days วัน)',
                                            style: const TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF1E293B),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),

                                    if (type == 'ขอเข้าสาย' && lateTime != null && lateTime.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Icon(Icons.alarm_rounded, size: 16, color: Colors.indigo.shade600),
                                          const SizedBox(width: 6),
                                          Text(
                                            'เวลาที่คาดว่าจะมาถึง: $lateTime น.',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.indigo.shade800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    const SizedBox(height: 8),

                                    // Reason Highlight Callout Box
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF8FAFC),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: const Color(0xFFE2E8F0)),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(Icons.format_quote_rounded, size: 16, color: Colors.grey.shade600),
                                              const SizedBox(width: 4),
                                              const Text(
                                                'เหตุผลในการขอลา / ขอเข้าสาย:',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFF475569),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            reason,
                                            style: const TextStyle(
                                              fontSize: 13.5,
                                              color: Color(0xFF1E293B),
                                              height: 1.4,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 8),

                                    // Contact & Metadata Row
                                    Wrap(
                                      spacing: 16,
                                      runSpacing: 4,
                                      children: [
                                        if (phone != null && phone.isNotEmpty)
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.phone_rounded, size: 14, color: Colors.grey.shade600),
                                              const SizedBox(width: 4),
                                              Text(
                                                'โทร: $phone',
                                                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                              ),
                                            ],
                                          ),
                                        if (createdAt.isNotEmpty)
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.access_time_rounded, size: 14, color: Colors.grey.shade600),
                                              const SizedBox(width: 4),
                                              Text(
                                                'ยื่นคำขอเมื่อ: $createdAt',
                                                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),

                                    // Action buttons for Director/Admin when status is pending
                                    if (status == 'pending') ...[
                                      const SizedBox(height: 12),
                                      const Divider(height: 1),
                                      const SizedBox(height: 8),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.end,
                                        children: [
                                          const Text(
                                            'การพิจารณาของผู้อำนวยการ:',
                                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
                                          ),
                                          const SizedBox(width: 12),
                                          OutlinedButton.icon(
                                            onPressed: () {
                                              _handleUpdateLeaveStatus(leaveId, 'rejected', () {
                                                Navigator.of(ctx).pop();
                                              });
                                            },
                                            icon: const Icon(Icons.cancel_outlined, size: 15),
                                            label: const Text('ไม่อนุมัติ'),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: Colors.red.shade700,
                                              side: BorderSide(color: Colors.red.shade300),
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          ElevatedButton.icon(
                                            onPressed: () {
                                              _handleUpdateLeaveStatus(leaveId, 'approved', () {
                                                Navigator.of(ctx).pop();
                                              });
                                            },
                                            icon: const Icon(Icons.check_circle_outline_rounded, size: 15),
                                            label: const Text('อนุมัติ'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.green.shade700,
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  Widget _buildDialogStatChip({required String label, required String value, required Color color}) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color),
        ),
      ],
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg),
          ),
        ],
      ),
    );
  }
}
