import 'dart:async';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:flutter/gestures.dart';

import '../services/api_service.dart';

import '../models/semester_config.dart';

import '../widgets/dmc_import_dialog.dart';
import '../widgets/dmc_export_dialog.dart';
import '../widgets/student_photo_upload_dialog.dart';
import '../widgets/student_photo_capture.dart';

import '../widgets/student_name_dialog.dart';



class AttendanceScreen extends StatefulWidget {

  final ApiService apiService;



  const AttendanceScreen({

    super.key,

    required this.apiService,

  });



  @override

  State<AttendanceScreen> createState() => _AttendanceScreenState();

}



class _AttendanceScreenState extends State<AttendanceScreen> {
  bool get isAdmin => widget.apiService.isAdmin;


  // -------------------------------------------------------------

  // SYSTEM CLOCK SEMESTER CALCULATION

  // -------------------------------------------------------------

  /// คำนวณภาคเรียนและปีการศึกษาจากเวลาเครื่อง:

  /// 1 เม.ย. - 10 ต.ค. เป็น ภาคเรียนที่ 1 ของปีนั้น

  /// 11 ต.ค. - 30 มี.ค. เป็น ภาคเรียนที่ 2 ของปีการศึกษานั้น

  static Map<String, String> computeCurrentSemesterFromClock() {

    final now = DateTime.now();

    final yearBE = now.year + 543;

    final month = now.month;

    final day = now.day;



    // 1 เม.ย. (เดือน 4 วันที่ 1) จนถึง 10 ต.ค. (เดือน 10 วันที่ 10)

    final bool isTerm1 = (month > 4 || (month == 4 && day >= 1)) &&

        (month < 10 || (month == 10 && day <= 10));



    if (isTerm1) {

      return {'term': '1', 'year': yearBE.toString()};

    } else {

      // 11 ต.ค. - 30 มี.ค. เป็น ภาคเรียนที่ 2 ของปีการศึกษานั้น

      // ถ้าเดือน ม.ค. - มี.ค. (ก่อน 1 เม.ย.) ปีการศึกษาคือปีที่แล้ว (yearBE - 1)

      if (month <= 3) {

        return {'term': '2', 'year': (yearBE - 1).toString()};

      } else {

        return {'term': '2', 'year': yearBE.toString()};

      }

    }

  }



  // -------------------------------------------------------------

  // STATE VARIABLES

  // -------------------------------------------------------------

  bool _loadingSemesters = true;

  List<SemesterConfigItem> _semesters = [];

  String _selectedTerm = '2';

  String _selectedYear = '2569';



  String _selectedClassLevel = 'ม.1';

  String _selectedRoom = 'all';

  List<String> _availableRooms = [];

  final List<String> _classLevels = ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'];

  Map<String, int> _classCounts = {};

  bool _loadingDailyGrid = false;

  bool _savingDailyGrid = false;



  DateTime _dailyStartDate = DateTime(2025, 5, 19);

  List<Map<String, dynamic>> _dailyComputedWeeks = [];

  List<Map<String, dynamic>> _allClassStudents = [];
  Timer? _dailyAutoSaveTimer;
  Future<void>? _inFlightDailySave;
  bool _isAutoSaving = false;
  bool _hasUnsavedDailyChanges = false;
  String _autoSaveStatus = '';
  List<Map<String, dynamic>> _dailyStudentList = [];

  final Set<int> _dailyHolidaySlots = {};

  final Set<int> _dailyLockedCountedSlots = {};

  String _dailyCurrentMode = 'present'; // 'present', 'leave', 'late', 'absent'

  int _dailySelectedWeekRange = 1; // 1=กลางภาค (สัปดาห์ 1-10), 2=หลังกลางภาค (สัปดาห์ 11-20), 0=ทั้งหมด (1-20)

  bool _dailyAllPresent = false;

  String _dailySearchQuery = '';



  final List<String> _dayLabels = ['จ.', 'อ.', 'พ.', 'พฤ.', 'ศ.'];

  final List<String> _dayFullNames = ['จันทร์', 'อังคาร', 'พุธ', 'พฤหัสบดี', 'ศุกร์'];



    // Scroll controllers for synchronized scrolling
  final ScrollController _headerHorizontalController = ScrollController();
  final ScrollController _gridHorizontalController = ScrollController();
  final ScrollController _footerHorizontalController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  bool _isSyncingHorizontal = false;

  void _syncHorizontalScroll(ScrollController source, List<ScrollController> targets) {
    if (_isSyncingHorizontal || !source.hasClients) return;
    _isSyncingHorizontal = true;
    try {
      final offset = source.offset;
      for (final target in targets) {
        if (target.hasClients && (target.offset - offset).abs() > 0.5) {
          target.jumpTo(offset.clamp(0.0, target.position.maxScrollExtent));
        }
      }
    } finally {
      _isSyncingHorizontal = false;
    }
  }

  void _scrollGridBy(double delta) {
    if (!_gridHorizontalController.hasClients) return;
    final maxExtent = _gridHorizontalController.position.maxScrollExtent;
    final newOffset = (_gridHorizontalController.offset + delta).clamp(0.0, maxExtent);
    _gridHorizontalController.animateTo(
      newOffset,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  void _scrollToOffset(double target) {
    if (!_gridHorizontalController.hasClients) return;
    final maxExtent = _gridHorizontalController.position.maxScrollExtent;
    final newOffset = target.clamp(0.0, maxExtent);
    _gridHorizontalController.animateTo(
      newOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }



  @override

  void initState() {

    super.initState();

    final def = widget.apiService.defaultSemester;

    if (def != null) {

      _selectedTerm = def.term;

      _selectedYear = def.year;

    } else {

      final clockSem = computeCurrentSemesterFromClock();

      _selectedTerm = clockSem['term']!;

      _selectedYear = clockSem['year']!;

    }



        // Link horizontal controllers for 3-way synchronization (Header, Grid, and Footer Scrollbar)
    _gridHorizontalController.addListener(() {
      _syncHorizontalScroll(_gridHorizontalController, [_headerHorizontalController, _footerHorizontalController]);
    });
    _headerHorizontalController.addListener(() {
      _syncHorizontalScroll(_headerHorizontalController, [_gridHorizontalController, _footerHorizontalController]);
    });
    _footerHorizontalController.addListener(() {
      _syncHorizontalScroll(_footerHorizontalController, [_gridHorizontalController, _headerHorizontalController]);
    });



    _loadSemesters();

  }



  @override

  void dispose() {
    _dailyAutoSaveTimer?.cancel();
    _headerHorizontalController.dispose();
    _gridHorizontalController.dispose();
    _footerHorizontalController.dispose();
    _verticalScrollController.dispose();

    super.dispose();

  }



  // -------------------------------------------------------------

  // SEMESTERS & INITIALIZATION

  // -------------------------------------------------------------

  Future<void> _loadSemesters() async {
    setState(() => _loadingSemesters = true);
    try {
      final list = await widget.apiService.getSemesterConfigs();
      if (list.isNotEmpty) {
        final defSem = list.firstWhere(
          (s) => s.isDefault,
          orElse: () => list.firstWhere((s) => s.isActive, orElse: () => list.first),
        );
        _selectedTerm = defSem.term;
        _selectedYear = defSem.year;
      }



      setState(() {

        _semesters = list;

      });



      await Future.wait([

        _loadLevelSummaries(),

        _loadDailyAttendanceGrid(),

      ]);

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(content: Text('โหลดข้อมูลภาคเรียนไม่สำเร็จ: $e')),

        );

      }

    } finally {

      if (mounted) setState(() => _loadingSemesters = false);

    }

  }



  Future<void> _onSemesterChanged(String term, String year) async {
    await _flushPendingDailySave();
    setState(() {
      _selectedTerm = term;
      _selectedYear = year;
      _allClassStudents.clear();
      _dailyStudentList.clear();
    });

    await Future.wait([

      _loadLevelSummaries(),

      _loadDailyAttendanceGrid(),

    ]);

  }



  Future<void> _loadLevelSummaries() async {

    try {

      final list = await widget.apiService.getAllLevelsAttendanceSummary(

        term: _selectedTerm,

        year: _selectedYear,

      );

      final Map<String, int> counts = {};

      for (final item in list) {

        final lvl = item['class_level']?.toString() ?? '';

        final c = (item['student_count'] as num?)?.toInt() ?? 0;

        if (lvl.isNotEmpty) counts[lvl] = c;

      }

      if (mounted) {

        setState(() {

          _classCounts = counts;

        });

      }

    } catch (_) {}

  }



  // -------------------------------------------------------------

  // CRITERION & STUDENT STATS CALCULATION

  // -------------------------------------------------------------

  /// Day-slots (Mon-Fri, slot 0 = first day of week 1) on or before today on this computer:

  /// ขาด / ร้อยละ count only these, e.g. on day 1 a student who came is 1*100/1 = 100%.

  int get _dailyElapsedSlots {

    final now = DateTime.now();

    final today = DateTime(now.year, now.month, now.day);

    int n = 0;

    for (int i = 0; i < 100; i++) {

      final d = _dailyStartDate.add(Duration(days: (i ~/ 5) * 7 + i % 5));

      if (!DateTime(d.year, d.month, d.day).isAfter(today)) n = i + 1;

    }

    return n;

  }


  int _computeCriterionForRange(int startSlot, int endSlot) {

    int total = 0;

    final int upper = endSlot.clamp(0, _dailyElapsedSlots); // up to today only

    for (int i = startSlot.clamp(0, 100); i < upper; i++) {

      if (!_dailyHolidaySlots.contains(i)) {

        total++;

      }

    }

    return total;

  }



  int _computeDailyTotalCriterion() {

    return _computeCriterionForRange(0, 100);

  }



  Map<String, dynamic> _computeStudentStatsForRange(Map<String, dynamic> st, int startSlot, int endSlot) {

    final statusList = (st['status_list'] as List?)?.map((e) => e.toString()).toList() ?? [];

    int p = 0;

    int a = 0;

    int l = 0;

    int lt = 0;

    int crit = 0;



    final int upper = endSlot.clamp(0, _dailyElapsedSlots); // up to today only

    for (int i = startSlot.clamp(0, 100); i < upper; i++) {

      if (_dailyHolidaySlots.contains(i)) {

        continue;

      }

      crit++;

      if (_dailyLockedCountedSlots.contains(i)) {

        p++;

        continue;

      }

      final val = (i < statusList.length) ? statusList[i] : '';

      if (val == '/') {

        p++;

      } else if (val == 'ส') {

        p++; // จากตารางเรียนรวม สาย ให้นับ เป็น มา ในวันนั้น

        lt++;

      } else if (val == 'ล') {

        l++;

      } else {

        a++;

      }

    }



    final double pct = crit > 0 ? double.parse((p / crit * 100).toStringAsFixed(1)) : 100.0;

    return {

      'present': p,

      'absent': a,

      'leave': l,

      'late': lt,

      'criterion': crit,

      'percentage': pct,

    };

  }



  void _recalculateDailyStudent(Map<String, dynamic> st) {

    final totalStats = _computeStudentStatsForRange(st, 0, 100);

    st['present_count'] = totalStats['present'];

    st['absent_count'] = totalStats['absent'];

    st['leave_count'] = totalStats['leave'];

    st['late_count'] = totalStats['late'];

    st['percentage'] = totalStats['percentage'];

  }



  // -------------------------------------------------------------

  // GRID DATA LOADING & SAVING

  // -------------------------------------------------------------

  Future<void> _loadDailyAttendanceGrid() async {
    setState(() => _loadingDailyGrid = true);
    try {
      final res = await widget.apiService.getDailyAttendanceGrid(
        term: _selectedTerm,
        year: _selectedYear,
        classLevel: _selectedClassLevel,
        room: null,
      );

      final rawRooms = res['available_rooms'] as List? ?? [];
      _availableRooms = rawRooms.map((e) => e.toString()).toList();

      final rawHolidays = res['holidays'] as List? ?? [];
      final rawLocked = res['locked_counted'] as List? ?? [];
      _dailyHolidaySlots.clear();
      _dailyHolidaySlots.addAll(rawHolidays.map((e) => (e as num).toInt()));
      _dailyLockedCountedSlots.clear();
      _dailyLockedCountedSlots.addAll(rawLocked.map((e) => (e as num).toInt()));

      if (res['start_date'] != null && res['start_date'].toString().isNotEmpty) {
        try {
          _dailyStartDate = DateTime.parse(res['start_date'].toString());
        } catch (_) {}
      } else {
        final int y = int.tryParse(_selectedYear) ?? 2568;
        final int gregorianYear = (y > 2500) ? y - 543 : y;
        _dailyStartDate = (_selectedTerm == '2')
            ? DateTime(gregorianYear, 11, 3)
            : DateTime(gregorianYear, 5, 19);
      }
      _dailyStartDate = _dailyStartDate.subtract(Duration(days: _dailyStartDate.weekday - 1));
      _dailyComputedWeeks = _calculateScheduleWeeks(_dailyStartDate);

      final studentsRaw = res['students'] as List? ?? [];
      final initialTot = _computeDailyTotalCriterion();

      final mappedStudents = studentsRaw.map((s) {
        final rawStatus = (s['status_list'] as List?)?.map((e) => e.toString()).toList() ?? [];
        final List<String> statusList = List<String>.filled(100, '');
        if (rawStatus.length == 100) {
          for (int i = 0; i < 100; i++) {
            statusList[i] = rawStatus[i];
          }
        } else if (rawStatus.isNotEmpty) {
          for (int i = 0; i < rawStatus.length && i < 100; i++) {
            statusList[i] = rawStatus[i];
          }
        }

        final stMap = {
          'student_id': s['student_id']?.toString() ?? '',
          'student_no': (s['student_no'] as num?)?.toInt() ?? 1,
          'full_name': s['full_name']?.toString() ?? '',
          'room': s['room']?.toString() ?? '1',
          'is_locked': s['is_locked'] == true,
          'note': s['note']?.toString() ?? '',
          'present_count': (s['present_count'] as num?)?.toInt() ?? initialTot,
          'absent_count': (s['absent_count'] as num?)?.toInt() ?? 0,
          'leave_count': (s['leave_count'] as num?)?.toInt() ?? 0,
          'late_count': (s['late_count'] as num?)?.toInt() ?? 0,
          'percentage': (s['percentage'] as num?)?.toDouble() ?? 100.0,
          'status_list': statusList,
        };
        _recalculateDailyStudent(stMap);
        return stMap;
      }).toList();

      setState(() {
        _allClassStudents = mappedStudents;
        _filterDailyStudentListInternal();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('โหลดข้อมูลตารางเวลาเรียนประจำวันไม่สำเร็จ: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingDailyGrid = false);
    }
  }

  void _filterDailyStudentListInternal() {
    if (_selectedRoom == 'all') {
      _dailyStudentList = List<Map<String, dynamic>>.from(_allClassStudents);
    } else {
      _dailyStudentList = _allClassStudents
          .where((s) => (s['room']?.toString() ?? '1') == _selectedRoom)
          .toList();
    }
    _recalcDailyAllPresentState();
  }

  void _filterDailyStudentList() {
    setState(() {
      _filterDailyStudentListInternal();
    });
  }

  void _recalcDailyAllPresentState() {
    final totDays = _computeDailyTotalCriterion();
    final active = _dailyStudentList.where((s) => s['is_locked'] != true).toList();
    _dailyAllPresent = active.isNotEmpty &&
        active.every((s) => (s['present_count'] as int) == totDays);
  }

  void _triggerDebouncedSave() {
    _hasUnsavedDailyChanges = true;
    setState(() {
      _autoSaveStatus = 'รอการบันทึก...';
    });
    _dailyAutoSaveTimer?.cancel();
    _dailyAutoSaveTimer = Timer(const Duration(milliseconds: 700), () {
      _saveDailyAttendanceSilently();
    });
  }

  Future<void> _saveDailyAttendanceSilently({String? targetClassLevel}) async {
    _dailyAutoSaveTimer?.cancel();
    final saveLevel = targetClassLevel ?? _selectedClassLevel;
    final studentsToSave = List<Map<String, dynamic>>.from(
      _allClassStudents.isNotEmpty ? _allClassStudents : _dailyStudentList,
    );
    if (studentsToSave.isEmpty) {
      _hasUnsavedDailyChanges = false;
      return;
    }

    setState(() {
      _isAutoSaving = true;
      _autoSaveStatus = 'กำลังบันทึกอัตโนมัติ...';
    });

    final currentFuture = () async {
      try {
        final startDateStr = '${_dailyStartDate.year.toString().padLeft(4, '0')}-${_dailyStartDate.month.toString().padLeft(2, '0')}-${_dailyStartDate.day.toString().padLeft(2, '0')}';
        await widget.apiService.saveDailyAttendanceGrid(
          term: _selectedTerm,
          year: _selectedYear,
          classLevel: saveLevel,
          startDate: startDateStr,
          holidays: _dailyHolidaySlots.toList(),
          lockedCounted: _dailyLockedCountedSlots.toList(),
          students: studentsToSave,
        );
        _hasUnsavedDailyChanges = false;
        if (mounted) {
          setState(() {
            _isAutoSaving = false;
            _autoSaveStatus = 'บันทึกอัตโนมัติแล้ว';
          });
        }
        _loadLevelSummaries();
      } catch (e) {
        if (mounted) {
          setState(() {
            _isAutoSaving = false;
            _autoSaveStatus = 'บันทึกไม่สำเร็จ: $e';
          });
        }
      }
    }();

    _inFlightDailySave = currentFuture;
    await currentFuture;
    if (_inFlightDailySave == currentFuture) {
      _inFlightDailySave = null;
    }
  }

  Future<void> _flushPendingDailySave() async {
    if (_dailyAutoSaveTimer?.isActive ?? false) {
      _dailyAutoSaveTimer?.cancel();
    }
    if (_inFlightDailySave != null) {
      await _inFlightDailySave;
    }
    if (_hasUnsavedDailyChanges) {
      await _saveDailyAttendanceSilently();
    }
  }



  Future<void> _toggleStudentLock(Map<String, dynamic> st) async {

    final bool newLockedState = !(st['is_locked'] == true);

    final String studentName = st['full_name']?.toString() ?? '';

    final String studentId = st['student_id']?.toString() ?? '';



    setState(() {

      st['is_locked'] = newLockedState;

    });



    try {

      await widget.apiService.toggleStudentLock(

        term: _selectedTerm,

        year: _selectedYear,

        classLevel: _selectedClassLevel,

        studentId: studentId,

        locked: newLockedState,

      );



      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            duration: const Duration(seconds: 2),

            backgroundColor: newLockedState ? Colors.amber.shade900 : Colors.teal.shade700,

            content: Row(

              children: [

                Icon(

                  newLockedState ? Icons.lock_rounded : Icons.lock_open_rounded,

                  color: Colors.white,

                  size: 18,

                ),

                const SizedBox(width: 8),

                Expanded(

                  child: Text(

                    newLockedState

                        ? 'ล็อก $studentName แล้ว (ไม่นำมาคิดและไม่แสดงใน ปพ.5)'

                        : 'ปลดล็อก $studentName แล้ว (นำกลับมาคิดและแสดงผลตามปกติ)',

                    style: const TextStyle(fontWeight: FontWeight.bold),

                  ),

                ),

              ],

            ),

          ),

        );

      }

    } catch (e) {

      setState(() {

        st['is_locked'] = !newLockedState;

      });

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.red.shade700,

            content: Text('บันทึกสถานะล็อกไม่สำเร็จ: $e'),

          ),

        );

      }

    }

  }



  void _toggleDailyCell(Map<String, dynamic> st, int slotIdx) {
    if (st['is_locked'] == true) return;
    if (_dailyHolidaySlots.contains(slotIdx)) return;

    final list = st['status_list'] as List<String>;
    final curVal = list[slotIdx];

    if (_dailyCurrentMode == 'late') {
      _openSmartLatePeriodDialog(st, slotIdx);
      return;
    }

    String nextVal;
    if (_dailyCurrentMode == 'present') {
      nextVal = curVal == '/' ? '' : '/';
    } else if (_dailyCurrentMode == 'leave') {
      nextVal = curVal == 'ล' ? '' : 'ล';
    } else {
      nextVal = '';
    }

    setState(() {
      list[slotIdx] = nextVal;
      _recalculateDailyStudent(st);
      _recalcDailyAllPresentState();
    });
    _triggerDebouncedSave();
  }



  Future<void> _openSmartLatePeriodDialog(Map<String, dynamic> st, int slotIdx) async {

    final int weekIdx = slotIdx ~/ 5;

    final int dayIdx = slotIdx % 5;

    final int dayOfWeek = dayIdx + 1;

    String dateStr = DateTime.now().toIso8601String().substring(0, 10);

    if (weekIdx < _dailyComputedWeeks.length) {

      final days = _dailyComputedWeeks[weekIdx]['days'] as List?;

      if (days != null && dayIdx < days.length) {

        dateStr = days[dayIdx]['date_str']?.toString() ?? dateStr;

      }

    }



    int selectedPeriod = 2; // Default arrived at Period 2 (missed Period 1)

    Map<String, dynamic>? previewData;

    bool loadingPreview = true;

    bool savingCascade = false;



    final Map<int, String> periodTimes = {

      1: '08.30 - 09.20',

      2: '09.20 - 10.10',

      3: '10.20 - 11.10',

      4: '11.10 - 12.00',

      5: '13.00 - 13.50',

      6: '13.50 - 14.40',

      7: '14.40 - 15.30',

    };



    Future<void> fetchPreview(int period, StateSetter setDialogState) async {

      setDialogState(() => loadingPreview = true);

      try {

        final data = await widget.apiService.previewLateCascade(

          term: _selectedTerm,

          year: _selectedYear,

          classLevel: _selectedClassLevel,

          dayOfWeek: dayOfWeek,

          arrivedPeriod: period,

        );

        setDialogState(() {

          previewData = data;

          loadingPreview = false;

        });

      } catch (_) {

        setDialogState(() => loadingPreview = false);

      }

    }



    await showDialog(

      context: context,

      builder: (ctx) {

        bool initialized = false;

        return StatefulBuilder(

          builder: (context, setDialogState) {

            if (!initialized) {

              initialized = true;

              fetchPreview(selectedPeriod, setDialogState);

            }



            final arrivedCourse = previewData?['arrived_course'] as Map<String, dynamic>?;

            final missedList = List<Map<String, dynamic>>.from(previewData?['missed_periods_detail'] ?? []);

            final list = st['status_list'] as List<String>;

            final alreadyLate = list[slotIdx] == 'ส';



            return AlertDialog(

              title: Row(

                children: [

                  const Icon(Icons.schedule_rounded, color: Color(0xFF1A237E), size: 26),

                  const SizedBox(width: 10),

                  Expanded(

                    child: Column(

                      crossAxisAlignment: CrossAxisAlignment.start,

                      children: [

                        const Text(

                          'เช็คชื่อนักเรียนมาสาย — เลือกคาบที่มาเรียน (1–7)',

                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),

                        ),

                        Text(

                          '${st['student_id']} ${st['full_name']} • ชั้น $_selectedClassLevel • วัน${_dayFullNames[dayIdx]} (สัปดาห์ที่ ${weekIdx + 1})',

                          style: const TextStyle(fontSize: 12.5, color: Colors.black54, fontWeight: FontWeight.normal),

                        ),

                      ],

                    ),

                  ),

                ],

              ),

              content: SizedBox(

                width: 580,

                child: SingleChildScrollView(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    mainAxisSize: MainAxisSize.min,

                    children: [

                      const Text(

                        '1. เลือกคาบที่นักเรียนมาถึงโรงเรียน (คาบ 1 - 7):',

                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),

                      ),

                      const SizedBox(height: 8),

                      Wrap(

                        spacing: 8,

                        runSpacing: 8,

                        children: List.generate(7, (idx) {

                          final p = idx + 1;

                          final isSel = selectedPeriod == p;

                          return ChoiceChip(

                            selectedColor: const Color(0xFF1A237E),

                            backgroundColor: Colors.grey.shade100,

                            label: Column(

                              mainAxisSize: MainAxisSize.min,

                              children: [

                                Text(

                                  'มาคาบ $p',

                                  style: TextStyle(

                                    fontWeight: FontWeight.bold,

                                    fontSize: 13,

                                    color: isSel ? Colors.white : Colors.black87,

                                  ),

                                ),

                                Text(

                                  periodTimes[p]!,

                                  style: TextStyle(

                                    fontSize: 10,

                                    color: isSel ? Colors.amber.shade200 : Colors.black54,

                                  ),

                                ),

                              ],

                            ),

                            selected: isSel,

                            onSelected: (_) {

                              setDialogState(() => selectedPeriod = p);

                              fetchPreview(p, setDialogState);

                            },

                          );

                        }),

                      ),

                      const SizedBox(height: 16),



                      if (loadingPreview)

                        const Padding(

                          padding: EdgeInsets.symmetric(vertical: 20),

                          child: Center(child: CircularProgressIndicator()),

                        )

                      else ...[

                        // Arrived Period Info Box

                        Container(

                          padding: const EdgeInsets.all(12),

                          decoration: BoxDecoration(

                            color: Colors.blue.shade50,

                            borderRadius: BorderRadius.circular(8),

                            border: Border.all(color: Colors.blue.shade200),

                          ),

                          child: Row(

                            children: [

                              const Icon(Icons.login_rounded, color: Colors.blue),

                              const SizedBox(width: 10),

                              Expanded(

                                child: Column(

                                  crossAxisAlignment: CrossAxisAlignment.start,

                                  children: [

                                    Text(

                                      'คาบที่มาเรียน: คาบที่ $selectedPeriod (${periodTimes[selectedPeriod]})',

                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0D47A1)),

                                    ),

                                    const SizedBox(height: 2),

                                    if (arrivedCourse != null && (arrivedCourse['course_code'] ?? '').toString().isNotEmpty) ...[

                                      Text(

                                        'ตรงกับวิชา: ${arrivedCourse['course_code']} ${arrivedCourse['course_name']}  •  ผู้สอน: ${arrivedCourse['teacher_name']}',

                                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),

                                      ),

                                      const SizedBox(height: 4),

                                      Row(

                                        children: [

                                          Container(

                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),

                                            decoration: BoxDecoration(

                                              color: Colors.blue.shade100,

                                              borderRadius: BorderRadius.circular(4),

                                            ),

                                            child: const Text(

                                              'เช็คมาเรียน (ส)',

                                              style: TextStyle(

                                                fontSize: 11,

                                                fontWeight: FontWeight.bold,

                                                color: Color(0xFF0D47A1),

                                              ),

                                            ),

                                          ),

                                          const SizedBox(width: 8),

                                          const Expanded(

                                            child: Text(

                                              '* นับเวลาเรียนให้ และแสดงเครื่องหมาย "ส" ใน ปพ.5 เพื่อให้ครูพิจารณาคะแนนจิตพิสัย',

                                              style: TextStyle(fontSize: 11, color: Colors.black54),

                                            ),

                                          ),

                                        ],

                                      ),

                                    ] else

                                      const Text(

                                        'ยังไม่ได้ลงตารางสอนของชั้นนี้ในคาบนี้ (สามารถเพิ่มได้ที่เมนู ตารางสอนครู)',

                                        style: TextStyle(fontSize: 12, color: Colors.black54),

                                      ),

                                  ],

                                ),

                              ),

                            ],

                          ),

                        ),

                        const SizedBox(height: 12),



                        // Missed Earlier Periods Info Box

                        Container(

                          padding: const EdgeInsets.all(12),

                          decoration: BoxDecoration(

                            color: selectedPeriod == 1 ? Colors.green.shade50 : Colors.orange.shade50,

                            borderRadius: BorderRadius.circular(8),

                            border: Border.all(

                              color: selectedPeriod == 1 ? Colors.green.shade200 : Colors.orange.shade300,

                            ),

                          ),

                          child: Column(

                            crossAxisAlignment: CrossAxisAlignment.start,

                            children: [

                              Row(

                                children: [

                                  Icon(

                                    selectedPeriod == 1 ? Icons.check_circle_outline : Icons.warning_amber_rounded,

                                    color: selectedPeriod == 1 ? Colors.green.shade700 : Colors.deepOrange,

                                    size: 20,

                                  ),

                                  const SizedBox(width: 8),

                                  Expanded(

                                    child: Text(

                                      selectedPeriod == 1

                                          ? 'มาสายในคาบที่ 1 (ไม่มีคาบเรียนก่อนหน้าที่ต้องตัดขาด)'

                                          : 'คาบเรียนก่อนหน้า (คาบ 1 ถึง คาบ ${selectedPeriod - 1}) ที่จะเชื่อมเป็น "ขาดเรียน (ข)" อัตโนมัติ:',

                                      style: TextStyle(

                                        fontWeight: FontWeight.bold,

                                        fontSize: 13,

                                        color: selectedPeriod == 1 ? Colors.green.shade900 : Colors.deepOrange.shade900,

                                      ),

                                    ),

                                  ),

                                ],

                              ),

                              if (selectedPeriod > 1) ...[

                                const SizedBox(height: 8),

                                ...missedList.map((m) {

                                  final pNum = m['period_num'];

                                  final cCode = (m['course_code'] ?? '').toString();

                                  final cName = (m['course_name'] ?? '').toString();

                                  final tName = (m['teacher_name'] ?? '').toString();

                                  final willAbsent = m['will_mark_absent'] == true;

                                  return Padding(

                                    padding: const EdgeInsets.symmetric(vertical: 3),

                                    child: Row(

                                      children: [

                                        Container(

                                          width: 54,

                                          padding: const EdgeInsets.symmetric(vertical: 2),

                                          alignment: Alignment.center,

                                          decoration: BoxDecoration(

                                            color: willAbsent ? Colors.red.shade700 : Colors.grey.shade400,

                                            borderRadius: BorderRadius.circular(4),

                                          ),

                                          child: Text(

                                            'คาบ $pNum',

                                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),

                                          ),

                                        ),

                                        const SizedBox(width: 8),

                                        Expanded(

                                          child: Text(

                                            cCode.isNotEmpty

                                                ? '$cCode $cName (${tName.isNotEmpty ? tName : "ไม่ระบุครู"})'

                                                : 'ยังไม่มีข้อมูลวิชาในตารางสอน',

                                            style: TextStyle(

                                              fontSize: 12.5,

                                              fontWeight: willAbsent ? FontWeight.bold : FontWeight.normal,

                                              color: cCode.isNotEmpty ? Colors.black87 : Colors.black45,

                                            ),

                                          ),

                                        ),

                                        if (willAbsent)

                                          Container(

                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),

                                            decoration: BoxDecoration(

                                              color: Colors.red.shade100,

                                              borderRadius: BorderRadius.circular(4),

                                            ),

                                            child: Text(

                                              'ตัดเป็น ขาด (ข)',

                                              style: TextStyle(

                                                fontSize: 11,

                                                fontWeight: FontWeight.bold,

                                                color: Colors.red.shade900,

                                              ),

                                            ),

                                          ),

                                      ],

                                    ),

                                  );

                                }),

                                const Divider(height: 16),

                                const Text(

                                  '* ระบบจะบันทึก "ขาด" ลงในฐานข้อมูลและไฟล์ Excel ปพ.5 ของรายวิชาข้างต้นโดยอัตโนมัติ (ครูประจำวิชาสามารถแก้ไขภายหลังได้)',

                                  style: TextStyle(fontSize: 11.5, color: Colors.black54),

                                ),

                              ],

                            ],

                          ),

                        ),

                      ],

                    ],

                  ),

                ),

              ),

              actions: [

                if (alreadyLate)

                  TextButton.icon(

                    style: TextButton.styleFrom(foregroundColor: Colors.red),

                    icon: const Icon(Icons.clear_rounded, size: 18),

                    label: const Text('ยกเลิกสถานะสาย (ล้างช่อง)'),

                    onPressed: () {

                      setState(() {

                        list[slotIdx] = '';

                        _recalculateDailyStudent(st);

                      });

                      Navigator.pop(ctx);

                    },

                  ),

                TextButton(

                  onPressed: () => Navigator.pop(ctx),

                  child: const Text('ปิด'),

                ),

                FilledButton.icon(

                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1A237E)),

                  icon: savingCascade

                      ? const SizedBox(

                          width: 16,

                          height: 16,

                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),

                        )

                      : const Icon(Icons.check_circle_rounded, size: 18),

                  label: Text('ยืนยันมาสาย (คาบ $selectedPeriod) & เชื่อมข้อมูลวิชา'),

                  onPressed: savingCascade

                      ? null

                      : () async {

                          setDialogState(() => savingCascade = true);

                          try {

                            setState(() {

                              list[slotIdx] = 'ส';

                              _recalculateDailyStudent(st);

                            });



                            final res = await widget.apiService.cascadeLateStudent({

                              'term': _selectedTerm,

                              'year': _selectedYear,

                              'class_level': _selectedClassLevel,

                              'student_id': st['student_id'].toString(),

                              'date': dateStr,

                              'arrived_period': selectedPeriod,

                              'slot_idx': slotIdx,

                              'day_of_week': dayOfWeek,

                            });



                            if (ctx.mounted) Navigator.pop(ctx);

                            if (mounted) {

                              ScaffoldMessenger.of(context).showSnackBar(

                                SnackBar(

                                  backgroundColor: Colors.indigo.shade800,

                                  content: Text(res['message']?.toString() ?? 'บันทึกข้อมูลมาสายเรียบร้อยแล้ว'),

                                ),

                              );

                            }

                          } catch (e) {

                            setDialogState(() => savingCascade = false);

                            if (mounted) {

                              ScaffoldMessenger.of(context).showSnackBar(

                                SnackBar(content: Text('เกิดข้อผิดพลาด: $e'), backgroundColor: Colors.red),

                              );

                            }

                          }

                        },

                ),

              ],

            );

          },

        );

      },

    );

  }



  void _setDailyAllPresent(bool value) {
    setState(() {
      _dailyAllPresent = value;
      // มีผลเฉพาะห้องที่กำลังเลือก (ถ้าเลือก "ห้อง 1" มีผลเฉพาะห้อง 1, ถ้าเลือก "ทุกห้อง" มีผลทุกห้องในชั้นนี้)
      // ไม่กระทบห้องอื่น และไม่กระทบระดับชั้นอื่น
      for (final st in _dailyStudentList) {
        if (st['is_locked'] == true) continue;
        final list = st['status_list'] as List<String>;
        for (int i = 0; i < 100; i++) {
          if (_dailyHolidaySlots.contains(i)) {
            list[i] = '';
          } else {
            list[i] = value ? '/' : '';
          }
        }
        _recalculateDailyStudent(st);
      }
      _recalcDailyAllPresentState();
    });
    _triggerDebouncedSave();
  }



  int _getDailySlotLockState(int slotIdx) {

    if (_dailyHolidaySlots.contains(slotIdx)) return 2; // ไม่นับ

    if (_dailyLockedCountedSlots.contains(slotIdx)) return 1; // ล็อกนับ

    return 0; // ปกติ

  }



  void _cycleDailySlotLock(int slotIdx) {
    setState(() {
      final cur = _getDailySlotLockState(slotIdx);
      if (cur == 0) {
        _dailyLockedCountedSlots.add(slotIdx);
        _dailyHolidaySlots.remove(slotIdx);
      } else if (cur == 1) {
        _dailyLockedCountedSlots.remove(slotIdx);
        _dailyHolidaySlots.add(slotIdx);
        for (final st in (_allClassStudents.isNotEmpty ? _allClassStudents : _dailyStudentList)) {
          final list = st['status_list'] as List<String>;
          list[slotIdx] = '';
        }
      } else {
        _dailyHolidaySlots.remove(slotIdx);
        _dailyLockedCountedSlots.remove(slotIdx);
      }

      for (final st in (_allClassStudents.isNotEmpty ? _allClassStudents : _dailyStudentList)) {
        _recalculateDailyStudent(st);
      }
      _recalcDailyAllPresentState();
    });
    _triggerDebouncedSave();
  }



  Future<void> _saveDailyAttendance() async {
    _dailyAutoSaveTimer?.cancel();
    setState(() => _savingDailyGrid = true);
    try {
      final startDateStr = '${_dailyStartDate.year.toString().padLeft(4, '0')}-${_dailyStartDate.month.toString().padLeft(2, '0')}-${_dailyStartDate.day.toString().padLeft(2, '0')}';
      final studentsToSave = _allClassStudents.isNotEmpty ? _allClassStudents : _dailyStudentList;
      await widget.apiService.saveDailyAttendanceGrid(
        term: _selectedTerm,
        year: _selectedYear,
        classLevel: _selectedClassLevel,
        startDate: startDateStr,
        holidays: _dailyHolidaySlots.toList(),
        lockedCounted: _dailyLockedCountedSlots.toList(),
        students: studentsToSave,
      );
      _hasUnsavedDailyChanges = false;
      if (mounted) {
        setState(() {
          _autoSaveStatus = 'บันทึกเรียบร้อยแล้ว';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.green.shade700,
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Text('บันทึกเวลาเรียน 20 สัปดาห์ชั้น $_selectedClassLevel เรียบร้อยแล้ว (อัปเดตทุกรายวิชา)'),
              ],
            ),
          ),
        );
      }
      _loadLevelSummaries();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('บันทึกข้อมูลไม่สำเร็จ: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingDailyGrid = false);
    }
  }



  List<Map<String, dynamic>> _calculateScheduleWeeks(DateTime startDate) {

    final List<Map<String, dynamic>> weeks = [];

    final thaiMonths = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];



    DateTime current = startDate;

    for (int w = 1; w <= 20; w++) {

      final List<Map<String, dynamic>> days = [];

      for (int d = 0; d < 5; d++) {

        final dayDate = current.add(Duration(days: d));

        days.add({

          'day_num': dayDate.day,

          'month': dayDate.month,

          'year': dayDate.year + 543,

          'date_str': dayDate.toIso8601String().substring(0, 10),

        });

      }

      final firstDay = current;

      final lastDay = current.add(const Duration(days: 4));

      final shortYear1 = (firstDay.year + 543).toString().substring(2);

      final shortYear2 = (lastDay.year + 543).toString().substring(2);

      final String monthYearLabel;

      if (firstDay.month == lastDay.month && firstDay.year == lastDay.year) {

        monthYearLabel = '${thaiMonths[firstDay.month]} $shortYear1';

      } else {

        monthYearLabel = '${thaiMonths[firstDay.month]} $shortYear1 - ${thaiMonths[lastDay.month]} $shortYear2';

      }

      weeks.add({

        'week_num': w,

        'month_year': monthYearLabel,

        'days': days,

      });

      current = current.add(const Duration(days: 7));

    }

    return weeks;

  }



  String _formatDateThai(DateTime d) {

    final months = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];

    return '${d.day} ${months[d.month]} ${d.year + 543}';

  }



    Future<void> _openResetAttendanceDialog() async {
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ต้องเป็นผู้ดูแลระบบ (Admin) เท่านั้น')),
      );
      return;
    }

    String selectedScope = 'all_levels'; // 'all_levels' or 'current_level'
    String selectedMode = 'empty'; // 'empty' or 'all_present'
    bool isResetting = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.deepOrange.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.history_rounded, color: Colors.deepOrange.shade700, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'รีเซ็ตเวลาเรียน',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'ภาคเรียนที่ $_selectedTerm/$_selectedYear',
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.shade200),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'คำเตือน: การรีเซ็ตจะเขียนทับการเช็คชื่อเดิม และเชื่อมโยงอัปเดตไปยังทุกรายวิชาของครูผู้สอนในระบบทันที',
                                style: TextStyle(fontSize: 12, color: Colors.amber.shade900, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      const Text('1. เลือกระดับชั้นที่ต้องการรีเซ็ต:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      RadioListTile<String>(
                        title: const Text('ทุกระดับชั้น (ม.1 ถึง ม.6 รวม 6 ระดับชั้น)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: Text('รีเซ็ตนักเรียนทั้งหมดในภาคเรียนที่ $_selectedTerm/$_selectedYear', style: const TextStyle(fontSize: 11)),
                        value: 'all_levels',
                        groupValue: selectedScope,
                        dense: true,
                        activeColor: Colors.deepOrange.shade700,
                        onChanged: isResetting ? null : (v) => setDialogState(() => selectedScope = v!),
                      ),
                      RadioListTile<String>(
                        title: Text('เฉพาะระดับชั้นนี้ (ชั้น $_selectedClassLevel)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: Text('รีเซ็ตเฉพาะนักเรียนในชั้น $_selectedClassLevel เท่านั้น', style: const TextStyle(fontSize: 11)),
                        value: 'current_level',
                        groupValue: selectedScope,
                        dense: true,
                        activeColor: Colors.deepOrange.shade700,
                        onChanged: isResetting ? null : (v) => setDialogState(() => selectedScope = v!),
                      ),

                      const Divider(height: 20),

                      const Text('2. เลือกรูปแบบผลลัพธ์หลังรีเซ็ต:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      RadioListTile<String>(
                        title: const Text('ล้างข้อมูลเป็นช่องว่างทั้งหมด (ว่างทุกช่อง เสมือนเริ่มใหม่)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: const Text('นักเรียนทุกคนจะมีสถานะช่องว่าง (0 วัน) เพื่อรอการเช็คชื่อใหม่', style: TextStyle(fontSize: 11)),
                        value: 'empty',
                        groupValue: selectedMode,
                        dense: true,
                        activeColor: Colors.deepOrange.shade700,
                        onChanged: isResetting ? null : (v) => setDialogState(() => selectedMode = v!),
                      ),
                      RadioListTile<String>(
                        title: const Text('ตั้งค่าเป็นมาเรียนทุกคน (100% ทุกคน)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: const Text('นักเรียนทุกคนจะมีเครื่องหมาย "/" ครบทุกวันเรียน (ยกเว้นวันหยุด)', style: TextStyle(fontSize: 11)),
                        value: 'all_present',
                        groupValue: selectedMode,
                        dense: true,
                        activeColor: Colors.deepOrange.shade700,
                        onChanged: isResetting ? null : (v) => setDialogState(() => selectedMode = v!),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isResetting ? null : () => Navigator.pop(ctx),
                  child: const Text('ยกเลิก'),
                ),
                FilledButton.icon(
                  icon: isResetting
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.check_circle_rounded, size: 16),
                  label: Text(
                    isResetting ? 'กำลังรีเซ็ต...' : 'ยืนยันการรีเซ็ต',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.deepOrange.shade800,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: isResetting
                      ? null
                      : () async {
                          setDialogState(() => isResetting = true);
                          try {
                            if (selectedScope == 'all_levels') {
                              await widget.apiService.resetAllDailyAttendance(
                                term: _selectedTerm,
                                year: _selectedYear,
                                mode: selectedMode,
                              );
                            } else {
                              await widget.apiService.resetAllDailyAttendance(
                                term: _selectedTerm,
                                year: _selectedYear,
                                mode: selectedMode,
                                classLevels: [_selectedClassLevel],
                              );
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                            await _loadDailyAttendanceGrid();
                            await _loadLevelSummaries();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: Colors.green.shade700,
                                  content: Row(
                                    children: [
                                      const Icon(Icons.check_circle, color: Colors.white),
                                      const SizedBox(width: 8),
                                      Text(
                                        selectedScope == 'all_levels'
                                            ? 'รีเซ็ตเวลาเรียนทุกระดับชั้น (ม.1 - ม.6) เรียบร้อยแล้ว'
                                            : 'รีเซ็ตเวลาเรียนชั้น $_selectedClassLevel เรียบร้อยแล้ว',
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            setDialogState(() => isResetting = false);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: Colors.red.shade700,
                                  content: Text('รีเซ็ตเวลาเรียนไม่สำเร็จ: $e'),
                                ),
                              );
                            }
                          }
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

Future<void> _openDatePickerDialog() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dailyStartDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      helpText: 'เลือกวันเริ่มต้นภาคเรียน (วันจันทร์ สัปดาห์แรก)',
      confirmText: 'ตกลง',
      cancelText: 'ยกเลิก',
    );
    if (picked != null) {
      final monday = picked.subtract(Duration(days: picked.weekday - 1));
      final startDateStr = '${monday.year.toString().padLeft(4, '0')}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}';
      setState(() {
        _dailyStartDate = monday;
        _dailyComputedWeeks = _calculateScheduleWeeks(monday);
      });
      try {
        await widget.apiService.updateDailyAttendanceStartDate(
          term: _selectedTerm,
          year: _selectedYear,
          startDate: startDateStr,
        );
        _triggerDebouncedSave();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.indigo.shade700,
              content: Row(
                children: [
                  const Icon(Icons.calendar_month, color: Colors.white),
                  const SizedBox(width: 8),
                  Text('กำหนดวันเปิดภาคเรียน $startDateStr ตรงกันทุกระดับชั้นในภาคเรียน $_selectedTerm/$_selectedYear เรียบร้อยแล้ว'),
                ],
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.red.shade700,
              content: Text('อัปเดตวันเริ่มภาคเรียนไม่สำเร็จ: $e'),
            ),
          );
        }
      }
    }
  }



  // -------------------------------------------------------------

  // STUDENT MANAGEMENT DIALOGS

  // -------------------------------------------------------------



  Future<void> _openAddStudentDialog() async {
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.red,
          content: Text('สิทธิ์เฉพาะผู้ดูแลระบบ (Admin) เท่านั้นที่สามารถเพิ่มนักเรียนได้'),
        ),
      );
      return;
    }

    final formKey = GlobalKey<FormState>();

    final idCtrl = TextEditingController();

    final nameCtrl = TextEditingController();

    final noCtrl = TextEditingController(text: '${_dailyStudentList.length + 1}');

    final noteCtrl = TextEditingController(text: 'ย้ายเข้า');



    final result = await showDialog<bool>(

      context: context,

      builder: (ctx) {

        return AlertDialog(

          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

          title: Row(

            children: [

              Icon(Icons.person_add_rounded, color: Colors.indigo.shade700),

              const SizedBox(width: 10),

              Text(

                'เพิ่มนักเรียน / ย้ายเข้า: ชั้น $_selectedClassLevel',

                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),

              ),

            ],

          ),

          content: Form(

            key: formKey,

            child: SizedBox(

              width: 440,

              child: SingleChildScrollView(

                child: Column(

                  mainAxisSize: MainAxisSize.min,

                  children: [

                    TextFormField(

                      controller: noCtrl,

                      decoration: const InputDecoration(

                        labelText: 'เลขที่ (ลำดับ)',

                        border: OutlineInputBorder(),

                        isDense: true,

                      ),

                      keyboardType: TextInputType.number,

                      validator: (val) => (val == null || val.trim().isEmpty) ? 'กรุณาระบุเลขที่' : null,

                    ),

                    const SizedBox(height: 12),

                    TextFormField(

                      controller: idCtrl,

                      decoration: const InputDecoration(

                        labelText: 'รหัสประจำตัวนักเรียน',

                        hintText: 'เช่น 01234',

                        border: OutlineInputBorder(),

                        isDense: true,

                      ),

                      validator: (val) => (val == null || val.trim().isEmpty) ? 'กรุณาระบุรหัสนักเรียน' : null,

                    ),

                    const SizedBox(height: 12),

                    TextFormField(

                      controller: nameCtrl,

                      decoration: const InputDecoration(

                        labelText: 'คำนำหน้า ชื่อ - สกุล',

                        hintText: 'เช่น เด็กชายวิชาญ มั่นคง',

                        border: OutlineInputBorder(),

                        isDense: true,

                      ),

                      validator: (val) => (val == null || val.trim().isEmpty) ? 'กรุณาระบุชื่อ-สกุล' : null,

                    ),

                    const SizedBox(height: 12),

                    TextFormField(

                      controller: noteCtrl,

                      decoration: const InputDecoration(

                        labelText: 'หมายเหตุการย้ายเข้า',

                        hintText: 'เช่น ย้ายเข้าเมื่อวันที่...',

                        border: OutlineInputBorder(),

                        isDense: true,

                      ),

                    ),

                  ],

                ),

              ),

            ),

          ),

          actions: [

            TextButton(

              onPressed: () => Navigator.of(ctx).pop(false),

              child: const Text('ยกเลิก'),

            ),

            FilledButton.icon(

              icon: const Icon(Icons.check, size: 18),

              label: const Text('บันทึกเพิ่มนักเรียน'),

              onPressed: () async {

                if (formKey.currentState?.validate() ?? false) {

                  Navigator.of(ctx).pop(true);

                }

              },

            ),

          ],

        );

      },

    );



    if (result == true) {

      setState(() => _loadingDailyGrid = true);

      try {

        final res = await widget.apiService.addDailyClassStudent(

          term: _selectedTerm,

          year: _selectedYear,

          classLevel: _selectedClassLevel,

          studentId: idCtrl.text.trim(),

          fullName: nameCtrl.text.trim(),

          studentNo: int.tryParse(noCtrl.text.trim()),

          note: noteCtrl.text.trim(),

        );



        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(

              backgroundColor: Colors.teal.shade700,

              content: Text(res['message'] ?? 'เพิ่มนักเรียนสำเร็จ'),

            ),

          );

          await _loadDailyAttendanceGrid();

          await _loadLevelSummaries();

        }

      } catch (e) {

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(backgroundColor: Colors.red.shade700, content: Text('เพิ่มนักเรียนไม่สำเร็จ: $e')),

          );

        }

      } finally {

        if (mounted) setState(() => _loadingDailyGrid = false);

      }

    }

  }



  Future<void> _confirmRemoveStudent(Map<String, dynamic> st) async {
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.red,
          content: Text('สิทธิ์เฉพาะผู้ดูแลระบบ (Admin) เท่านั้นที่สามารถลบหรือย้ายออกนักเรียนได้'),
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(

      context: context,

      builder: (ctx) {

        return AlertDialog(

          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

          title: Row(

            children: [

              Icon(Icons.person_remove_rounded, color: Colors.red.shade700),

              const SizedBox(width: 10),

              const Text('ยืนยันลบ / ย้ายออกนักเรียน', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),

            ],

          ),

          content: Column(

            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              Text('คุณต้องการลบหรือย้ายออกนักเรียนคนนี้จากชั้น $_selectedClassLevel หรือไม่?'),

              const SizedBox(height: 12),

              Container(

                padding: const EdgeInsets.all(12),

                decoration: BoxDecoration(

                  color: Colors.red.shade50,

                  borderRadius: BorderRadius.circular(8),

                  border: Border.all(color: Colors.red.shade200),

                ),

                child: Column(

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Text('เลขที่: ${st['student_no']} | รหัส: ${st['student_id']}', style: const TextStyle(fontWeight: FontWeight.bold)),

                    const SizedBox(height: 4),

                    Text('ชื่อ-สกุล: ${st['full_name']}', style: const TextStyle(fontSize: 14)),

                  ],

                ),

              ),

              const SizedBox(height: 8),

              Text(

                '* หมายเหตุ: ข้อมูลจะถูกตั้งสถานะย้ายออก และนำออกจากตารางเช็คเวลาเรียนของชั้นนี้',

                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),

              ),

            ],

          ),

          actions: [

            TextButton(

              onPressed: () => Navigator.of(ctx).pop(false),

              child: const Text('ยกเลิก'),

            ),

            FilledButton.icon(

              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),

              icon: const Icon(Icons.delete_forever_rounded, size: 18),

              label: const Text('ยืนยันลบ / ย้ายออก'),

              onPressed: () => Navigator.of(ctx).pop(true),

            ),

          ],

        );

      },

    );



    if (confirm == true) {

      setState(() => _loadingDailyGrid = true);

      try {

        final res = await widget.apiService.removeDailyClassStudent(

          term: _selectedTerm,

          year: _selectedYear,

          classLevel: _selectedClassLevel,

          studentId: st['student_id'].toString(),

        );



        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(

              backgroundColor: Colors.teal.shade700,

              content: Text(res['message'] ?? 'ลบนักเรียนสำเร็จ'),

            ),

          );

          await _loadDailyAttendanceGrid();

          await _loadLevelSummaries();

        }

      } catch (e) {

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(backgroundColor: Colors.red.shade700, content: Text('ลบนักเรียนไม่สำเร็จ: $e')),

          );

        }

      } finally {

        if (mounted) setState(() => _loadingDailyGrid = false);

      }

    }

  }



  // -------------------------------------------------------------

  // IMPORT STUDENTS FROM DMC EXCEL/CSV DIALOG

  // -------------------------------------------------------------

  /// แก้ชื่อนักเรียนจากช่องชื่อในตารางเช็คชื่อ แล้วโหลดรายชื่อใหม่ให้เห็นผลทันที

  Future<void> _editStudentName(Map<String, dynamic> st) async {

    final sid = '${st['student_id']}';

    final full = await StudentNameDialog.show(context, widget.apiService, sid);

    if (full == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('เปลี่ยนชื่อเป็น $full แล้ว (อัปเดตทุกหน้าและ ปพ.5 ให้ทันที)')));

    await _loadDailyAttendanceGrid();

  }

  /// แก้ไขรูปนักเรียนจากปุ่มดินสอ: มีรูปแล้ว = เมนู ถ่ายใหม่ / เลือกใหม่ / จัดตำแหน่ง / ลบ, ยังไม่มี = เลือกถ่ายหรือเลือกรูป
  /// สิทธิ์เดียวกับการอัปโหลดรูป (ผู้ดูแลระบบ หรือครูประจำชั้นของนักเรียนคนนั้น); เซิร์ฟเวอร์เป็นผู้ตัดสิน
  Future<void> _editStudentPhoto(Map<String, dynamic> st) async {
    final sid = '${st['student_id']}';
    final name = '${st['full_name']}';
    final messenger = ScaffoldMessenger.of(context);
    try {
      final profile = await widget.apiService.getStudentProfile(sid, term: _selectedTerm, year: _selectedYear);
      if (!mounted) return;
      if (profile['can_edit_photo'] != true) {
        messenger.showSnackBar(const SnackBar(
          backgroundColor: Colors.red,
          content: Text('แก้ไขรูปได้เฉพาะครูประจำชั้นของนักเรียนคนนี้ หรือผู้ดูแลระบบ'),
        ));
        return;
      }
      final photo = Map<String, dynamic>.from((profile['photo'] as Map?) ?? {});
      if (photo['exists'] == true) {
        await editStudentPhoto(
          context,
          apiService: widget.apiService,
          studentId: sid,
          studentName: name,
          term: _selectedTerm,
          year: _selectedYear,
          version: photo['version'],
        );
      } else {
        await pickAndUploadStudentPhoto(
          context,
          apiService: widget.apiService,
          studentId: sid,
          studentName: name,
          term: _selectedTerm,
          year: _selectedYear,
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red,
        content: Text(e.toString().replaceFirst('Exception: ', '')),
      ));
    }
  }



  void _openExportDmcDialog() {
    DmcExportDialog.show(
      context,
      apiService: widget.apiService,
      initialTerm: _selectedTerm,
      initialYear: _selectedYear,
      initialClassLevel: _selectedClassLevel,
      initialRoom: 'all',
      students: _dailyStudentList,
    );
  }

  Future<void> _openStudentPhotoDialog() async {
    final message = await StudentPhotoUploadDialog.show(
      context,
      apiService: widget.apiService,
      term: _selectedTerm,
      year: _selectedYear,
    );
    if (message != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.teal.shade700, content: Text(message)),
      );
    }
  }

  Future<void> _openImportDmcDialog() async {
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.red,
          content: Text('สิทธิ์เฉพาะผู้ดูแลระบบ (Admin) เท่านั้นที่สามารถนำเข้าข้อมูลนักเรียนได้'),
        ),
      );
      return;
    }

    final result = await DmcImportDialog.show(

      context,

      apiService: widget.apiService,

      initialTerm: _selectedTerm,

      initialYear: _selectedYear,

      semesters: _semesters,

    );

    if (result != null && mounted) {

      ScaffoldMessenger.of(context).showSnackBar(

        SnackBar(

          backgroundColor: Colors.teal.shade700,

          content: Text(result['message'] ?? 'นำเข้าข้อมูลนักเรียนจากระบบ DMC สำเร็จ'),

        ),

      );

      setState(() => _selectedRoom = 'all');

      await Future.wait([

        _loadLevelSummaries(),

        _loadDailyAttendanceGrid(),

      ]);

    }

  }



  // -------------------------------------------------------------

  // IMPORT STUDENTS FROM OTHER SEMESTER DIALOG

  // -------------------------------------------------------------

  Future<void> _openImportStudentsDialog() async {
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.red,
          content: Text('สิทธิ์เฉพาะผู้ดูแลระบบ (Admin) เท่านั้นที่สามารถนำเข้านักเรียนจากเทอมอื่นได้'),
        ),
      );
      return;
    }

    // Collect available source semesters

    List<Map<String, String>> semesterOptions = [];

    for (var s in _semesters) {

      if (s.term != _selectedTerm || s.year != _selectedYear) {

        semesterOptions.add({

          'term': s.term,

          'year': s.year,

          'label': s.title.isNotEmpty ? s.title : 'ภาคเรียนที่ ${s.term}/${s.year}',

        });

      }

    }



    if (semesterOptions.isEmpty) {

      final curY = int.tryParse(_selectedYear) ?? 2568;

      if (_selectedTerm == '2') {

        semesterOptions.add({

          'term': '1',

          'year': _selectedYear,

          'label': 'ภาคเรียนที่ 1/$_selectedYear',

        });

      } else {

        semesterOptions.add({

          'term': '2',

          'year': '${curY - 1}',

          'label': 'ภาคเรียนที่ 2/${curY - 1}',

        });

        semesterOptions.add({

          'term': '1',

          'year': '${curY - 1}',

          'label': 'ภาคเรียนที่ 1/${curY - 1}',

        });

      }

    }



    String sourceTerm = semesterOptions.first['term']!;

    String sourceYear = semesterOptions.first['year']!;

    String sourceClassLevel = _selectedClassLevel;

    bool allLevels = false;

    bool overwrite = false;

    int previewCount = -1;

    bool loadingPreview = false;



    await showDialog(

      context: context,

      builder: (ctx) {

        return StatefulBuilder(

          builder: (context, setDialogState) {

            void fetchPreview() async {

              setDialogState(() => loadingPreview = true);

              try {

                if (allLevels) {

                  final summaries = await widget.apiService.getAllLevelsAttendanceSummary(

                    term: sourceTerm,

                    year: sourceYear,

                  );

                  final tot = summaries.fold<int>(0, (a, b) => a + ((b['student_count'] as num?)?.toInt() ?? 0));

                  setDialogState(() {

                    previewCount = tot;

                    loadingPreview = false;

                  });

                } else {

                  final students = await widget.apiService.getClassStudents(

                    term: sourceTerm,

                    year: sourceYear,

                    classLevel: sourceClassLevel,

                  );

                  setDialogState(() {

                    previewCount = students.length;

                    loadingPreview = false;

                  });

                }

              } catch (_) {

                setDialogState(() {

                  previewCount = 0;

                  loadingPreview = false;

                });

              }

            }



            if (previewCount == -1 && !loadingPreview) {

              fetchPreview();

            }



            return AlertDialog(

              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

              title: Row(

                children: [

                  Container(

                    padding: const EdgeInsets.all(8),

                    decoration: BoxDecoration(

                      color: Colors.indigo.shade50,

                      borderRadius: BorderRadius.circular(8),

                    ),

                    child: Icon(Icons.file_download_rounded, color: Colors.indigo.shade700, size: 22),

                  ),

                  const SizedBox(width: 12),

                  const Text(

                    'นำเข้ารายชื่อนักเรียนจากภาคเรียนอื่น',

                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),

                  ),

                ],

              ),

              content: SizedBox(

                width: 480,

                child: SingleChildScrollView(

                  child: Column(

                    mainAxisSize: MainAxisSize.min,

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      // Destination Banner

                      Container(

                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),

                        decoration: BoxDecoration(

                          color: Colors.blue.shade50,

                          borderRadius: BorderRadius.circular(10),

                          border: Border.all(color: Colors.blue.shade200),

                        ),

                        child: Row(

                          children: [

                            Icon(Icons.input_rounded, size: 18, color: Colors.blue.shade800),

                            const SizedBox(width: 8),

                            Expanded(

                              child: Text(

                                'นำเข้าสู่: ภาคเรียนที่ $_selectedTerm/$_selectedYear • ระดับชั้น $_selectedClassLevel',

                                style: TextStyle(

                                  fontWeight: FontWeight.bold,

                                  fontSize: 12,

                                  color: Colors.blue.shade900,

                                ),

                              ),

                            ),

                          ],

                        ),

                      ),

                      const SizedBox(height: 16),



                      // Source Semester Picker

                      const Text(

                        '1. เลือกภาคเรียนต้นทาง:',

                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),

                      ),

                      const SizedBox(height: 6),

                      DropdownButtonFormField<String>(

                        initialValue: '$sourceTerm-$sourceYear',

                        decoration: const InputDecoration(

                          border: OutlineInputBorder(),

                          isDense: true,

                          prefixIcon: Icon(Icons.history_edu_rounded, size: 20),

                        ),

                        items: semesterOptions.map((opt) {

                          return DropdownMenuItem<String>(

                            value: '${opt['term']}-${opt['year']}',

                            child: Text(opt['label']!, style: const TextStyle(fontSize: 13)),

                          );

                        }).toList(),

                        onChanged: (val) {

                          if (val != null) {

                            final parts = val.split('-');

                            setDialogState(() {

                              sourceTerm = parts[0];

                              sourceYear = parts[1];

                              previewCount = -1;

                            });

                            fetchPreview();

                          }

                        },

                      ),

                      const SizedBox(height: 16),



                      // Scope Selection

                      const Text(

                        '2. ขอบเขตระดับชั้นที่ต้องการนำเข้า:',

                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),

                      ),

                      const SizedBox(height: 6),

                      RadioListTile<bool>(

                        contentPadding: EdgeInsets.zero,

                        dense: true,

                        title: Text('เฉพาะระดับชั้นนี้ (นำเข้าสู่ชั้น $_selectedClassLevel)', style: const TextStyle(fontSize: 13)),

                        value: false,

                        groupValue: allLevels,

                        onChanged: (val) {

                          setDialogState(() {

                            allLevels = false;

                            previewCount = -1;

                          });

                          fetchPreview();

                        },

                      ),

                      if (!allLevels)

                        Padding(

                          padding: const EdgeInsets.only(left: 32, bottom: 8),

                          child: Row(

                            children: [

                              const Text('ดึงจากระดับชั้นต้นทาง: ', style: TextStyle(fontSize: 12, color: Colors.grey)),

                              const SizedBox(width: 8),

                              DropdownButton<String>(

                                value: sourceClassLevel,

                                isDense: true,

                                items: _classLevels.map((lvl) {

                                  return DropdownMenuItem(value: lvl, child: Text(lvl, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)));

                                }).toList(),

                                onChanged: (val) {

                                  if (val != null) {

                                    setDialogState(() {

                                      sourceClassLevel = val;

                                      previewCount = -1;

                                    });

                                    fetchPreview();

                                  }

                                },

                              ),

                            ],

                          ),

                        ),

                      RadioListTile<bool>(

                        contentPadding: EdgeInsets.zero,

                        dense: true,

                        title: const Text('นำเข้าครบทุกชั้น (ม.1 – ม.6) พร้อมกัน', style: TextStyle(fontSize: 13)),

                        value: true,

                        groupValue: allLevels,

                        onChanged: (val) {

                          setDialogState(() {

                            allLevels = true;

                            previewCount = -1;

                          });

                          fetchPreview();

                        },

                      ),

                      const Divider(height: 24),



                      // Mode: Overwrite vs Append

                      const Text(

                        '3. รูปแบบการนำเข้า:',

                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),

                      ),

                      CheckboxListTile(

                        contentPadding: EdgeInsets.zero,

                        dense: true,

                        title: const Text('เขียนทับรายชื่อเดิมทั้งหมด (แทนที่รายชื่อเดิม)', style: TextStyle(fontSize: 13)),

                        subtitle: const Text('หากไม่เลือก จะเป็นการเพิ่มต่อท้ายและไม่เพิ่มชื่อที่ซ้ำกัน', style: TextStyle(fontSize: 11, color: Colors.grey)),

                        value: overwrite,

                        activeColor: Colors.red.shade700,

                        onChanged: (v) => setDialogState(() => overwrite = v ?? false),

                      ),

                      const SizedBox(height: 10),



                      // Preview Card

                      Container(

                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                        decoration: BoxDecoration(

                          color: previewCount > 0 ? Colors.green.shade50 : Colors.amber.shade50,

                          borderRadius: BorderRadius.circular(8),

                          border: Border.all(color: previewCount > 0 ? Colors.green.shade300 : Colors.amber.shade300),

                        ),

                        child: Row(

                          children: [

                            Icon(

                              previewCount > 0 ? Icons.check_circle_outline : Icons.info_outline,

                              size: 18,

                              color: previewCount > 0 ? Colors.green.shade800 : Colors.amber.shade900,

                            ),

                            const SizedBox(width: 8),

                            Expanded(

                              child: loadingPreview

                                  ? const Text('กำลังตรวจสอบจำนวนนักเรียนต้นทาง...', style: TextStyle(fontSize: 12))

                                  : Text(

                                      previewCount > 0

                                          ? 'พบรายชื่อในต้นทาง: $previewCount คน พร้อมนำเข้า'

                                          : 'ไม่พบรายชื่อนักเรียนในภาคเรียน/ระดับชั้นต้นทางที่เลือก',

                                      style: TextStyle(

                                        fontSize: 12,

                                        fontWeight: FontWeight.bold,

                                        color: previewCount > 0 ? Colors.green.shade900 : Colors.amber.shade900,

                                      ),

                                    ),

                            ),

                          ],

                        ),

                      ),

                    ],

                  ),

                ),

              ),

              actions: [

                TextButton(

                  onPressed: () => Navigator.of(ctx).pop(),

                  child: const Text('ยกเลิก'),

                ),

                FilledButton.icon(

                  icon: const Icon(Icons.download_rounded, size: 18),

                  label: const Text('ยืนยันนำเข้าข้อมูลนักเรียน'),

                  style: FilledButton.styleFrom(backgroundColor: Colors.indigo.shade700),

                  onPressed: previewCount <= 0

                      ? null

                      : () async {

                          Navigator.of(ctx).pop();

                          setState(() => _loadingDailyGrid = true);

                          try {

                            final res = await widget.apiService.importClassStudents(

                              fromTerm: sourceTerm,

                              fromYear: sourceYear,

                              toTerm: _selectedTerm,

                              toYear: _selectedYear,

                              fromClassLevel: allLevels ? null : sourceClassLevel,

                              toClassLevel: allLevels ? null : _selectedClassLevel,

                              allLevels: allLevels,

                              overwrite: overwrite,

                            );

                            if (mounted) {

                              ScaffoldMessenger.of(context).showSnackBar(

                                SnackBar(

                                  backgroundColor: Colors.teal.shade700,

                                  content: Text(res['message'] ?? 'นำเข้านักเรียนสำเร็จ'),

                                ),

                              );

                              await _loadDailyAttendanceGrid();

                              await _loadLevelSummaries();

                            }

                          } catch (e) {

                            if (mounted) {

                              ScaffoldMessenger.of(context).showSnackBar(

                                SnackBar(

                                  backgroundColor: Colors.red.shade700,

                                  content: Text('นำเข้านักเรียนไม่สำเร็จ: $e'),

                                ),

                              );

                            }

                          } finally {

                            if (mounted) setState(() => _loadingDailyGrid = false);

                          }

                        },

                ),

              ],

            );

          },

        );

      },

    );

  }







  // -------------------------------------------------------------

  // BUILD METHOD (PAGES & UI)

  // -------------------------------------------------------------

  @override

  Widget build(BuildContext context) {

    return Scaffold(

      // No AppBar: its fixed 56 px height clipped the title and buttons once they wrap.
      // The header (_dailyHeader) sits at the top of the page and grows with its content.
      body: _loadingSemesters
          ? const Center(child: CircularProgressIndicator())
          : (_isCompactDaily(context)
              ? _buildCompactDailyPage(context)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _dailyHeader(context),
                    Expanded(child: _buildDailyAttendanceBody()),
                  ],
                )),

    );

  }



  /// Phones and narrow windows: no AppBar, the whole page scrolls (see _buildCompactDailyPage).
  bool _isCompactDaily(BuildContext context) => MediaQuery.sizeOf(context).width < 700;

  Widget _dailyTitleBar(BuildContext context) => Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [

            const Icon(Icons.fact_check_rounded, color: Colors.indigo, size: 24),

            const SizedBox(width: 8),

            const Text(

              'ระบบเช็คเวลาเรียน รวม 20 สัปดาห์ (ครบ 6 ระดับชั้น ม.1 - ม.6)',

              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),

            ),

            const SizedBox(width: 12),

            // Auto-save status badge
            if (_isAutoSaving || _autoSaveStatus.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _isAutoSaving
                      ? Colors.amber.shade50
                      : (_hasUnsavedDailyChanges ? Colors.orange.shade50 : Colors.green.shade50),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isAutoSaving
                        ? Colors.amber.shade300
                        : (_hasUnsavedDailyChanges ? Colors.orange.shade300 : Colors.green.shade300),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isAutoSaving)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.amber.shade800,
                        ),
                      )
                    else
                      Icon(
                        _hasUnsavedDailyChanges ? Icons.sync : Icons.check_circle,
                        size: 13,
                        color: _hasUnsavedDailyChanges ? Colors.orange.shade800 : Colors.green.shade700,
                      ),
                    const SizedBox(width: 6),
                    Text(
                      _autoSaveStatus,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _isAutoSaving
                            ? Colors.amber.shade900
                            : (_hasUnsavedDailyChanges ? Colors.orange.shade900 : Colors.green.shade900),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],

            // ปุ่มบันทึกเวลาเรียน 20 สัปดาห์ & ปุ่มรีเซ็ตวันหยุด (บนสุดตรงกลาง ตามคำขอ)

            FilledButton.icon(

              icon: _savingDailyGrid

                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))

                  : const Icon(Icons.save_rounded, size: 16),

              label: const Text('บันทึกเวลาเรียน 20 สัปดาห์', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),

              style: FilledButton.styleFrom(

                backgroundColor: Colors.indigo.shade800,

                foregroundColor: Colors.white,

                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),

                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),

              ),

              onPressed: (_loadingDailyGrid || _savingDailyGrid) ? null : _saveDailyAttendance,

            ),

            const SizedBox(width: 8),

            Tooltip(
              message: 'ล้างวันหยุดและวันล็อกนับทั้งหมด',
              child: OutlinedButton.icon(
                icon: const Icon(Icons.restart_alt_rounded, size: 15),
                label: const Text('รีเซ็ตวันหยุด', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.indigo.shade800,
                  side: BorderSide(color: Colors.indigo.shade200),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  setState(() {
                    _dailyHolidaySlots.clear();
                    _dailyLockedCountedSlots.clear();
                    final targetList = _allClassStudents.isNotEmpty ? _allClassStudents : _dailyStudentList;
                    for (final st in targetList) {
                      _recalculateDailyStudent(st);
                    }
                  });
                  _triggerDebouncedSave();
                },
              ),
            ),

            const SizedBox(width: 8),

            Tooltip(
              message: 'รีเซ็ตเวลาเรียนทุกระดับชั้น (ม.1 - ม.6) หรือเฉพาะระดับชั้นนี้',
              child: OutlinedButton.icon(
                icon: const Icon(Icons.history_rounded, size: 15),
                label: const Text('รีเซ็ตเวลาเรียนทุกชั้น', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.deepOrange.shade800,
                  side: BorderSide(color: Colors.deepOrange.shade300),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: isAdmin ? _openResetAttendanceDialog : null,
              ),
            ),

            const SizedBox(width: 12),

          ],

        );

  List<Widget> _dailyActions(BuildContext context) => [

          // Refresh Button (กลับสู่เทอมล่าสุดตามเวลาเครื่อง)

          IconButton(

            tooltip: 'รีเฟรชข้อมูล (กลับสู่ภาคเรียนล่าสุดตามเวลาเครื่อง)',

            icon: const Icon(Icons.refresh_rounded, color: Colors.indigo),

            onPressed: () {

              _loadSemesters();

            },

          ),

          const SizedBox(width: 4),



          // Semester selector dropdown in header

          if (_semesters.isNotEmpty)

            Padding(

              padding: const EdgeInsets.only(right: 16),

              child: Center(widthFactor: 1, heightFactor: 1, child: Container(

                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),

                  decoration: BoxDecoration(

                    color: Colors.indigo.shade50,

                    borderRadius: BorderRadius.circular(8),

                    border: Border.all(color: Colors.indigo.shade200),

                  ),

                  child: DropdownButtonHideUnderline(

                    child: DropdownButton<String>(

                      value: '$_selectedTerm/$_selectedYear',

                      isDense: true,

                      icon: const Icon(Icons.arrow_drop_down, color: Colors.indigo),

                      style: TextStyle(

                        fontWeight: FontWeight.bold,

                        color: Colors.indigo.shade900,

                        fontSize: 13,

                        fontFamily: 'Sarabun',

                      ),

                      items: _semesters.map((s) {

                        return DropdownMenuItem<String>(

                          value: '${s.term}/${s.year}',

                          child: Text(

                            s.title.isNotEmpty ? s.title : 'ปีการศึกษา ${s.year} ภาคเรียนที่ ${s.term}',

                          ),

                        );

                      }).toList(),

                      onChanged: (val) {

                        if (val != null) {

                          final parts = val.split('/');

                          _onSemesterChanged(parts[0], parts[1]);

                        }

                      },

                    ),

                  ),

                ),

              ),

            ),

        ];

  /// Title, save/reset buttons, refresh and semester picker; wraps onto more lines when narrow.
  Widget _dailyHeader(BuildContext context) => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [_dailyTitleBar(context), Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: _dailyActions(context))],
        ),
      );

  Widget _buildCompactDailyPage(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dailyHeader(context),
          _buildDailyAttendanceBody(compact: true),
        ],
      ),
    );
  }

  Widget _buildDailyAttendanceBody({bool compact = false}) {

    final activeStudents = _dailyStudentList.where((s) => s['is_locked'] != true).toList();

    final int lockedCount = _dailyStudentList.length - activeStudents.length;



    final int midtermCriterion = _computeCriterionForRange(0, 50);

    final int postmidCriterion = _computeCriterionForRange(50, 100);

    final int totalCriterion = _computeCriterionForRange(0, 100);



    // Visible weeks division per user requirement

    List<int> visibleWeeks;

    String summaryHeaderTitle;

    String summaryCriterionLabel;

    int viewCriterion;



    if (_dailySelectedWeekRange == 1) {

      // 1. กลางภาค (สัปดาห์ 1 - 10)

      visibleWeeks = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

      summaryHeaderTitle = 'สรุป 10 สัปดาห์ (กลางภาค)';

      summaryCriterionLabel = '(เปิดเรียนแล้ว $midtermCriterion วัน)';

      viewCriterion = midtermCriterion;

    } else if (_dailySelectedWeekRange == 2) {

      // 2. หลังกลางภาค (สัปดาห์ 11 - 20) -> สรุป 10 สัปดาห์หลังกลางภาคตามคำขอ

      visibleWeeks = [11, 12, 13, 14, 15, 16, 17, 18, 19, 20];

      summaryHeaderTitle = 'สรุป 10 สัปดาห์ (หลังกลางภาค)';

      summaryCriterionLabel = '(เปิดเรียนแล้ว $postmidCriterion วัน)';

      viewCriterion = postmidCriterion;

    } else {

      // 3. ทั้งหมด 20 สัปดาห์ (1 - 20)

      visibleWeeks = List.generate(20, (i) => i + 1);

      summaryHeaderTitle = 'สรุปรวมทั้งหมด 20 สัปดาห์';

      summaryCriterionLabel = '(เปิดเรียนแล้ว $totalCriterion วัน)';

      viewCriterion = totalCriterion;

    }



    // Dynamic stats calculation for active students based on current view

    int totalPresent = 0;

    int totalAbsent = 0;

    int totalLeave = 0;

    int totalLate = 0;



    for (final s in activeStudents) {

      final Map<String, dynamic> stats = (_dailySelectedWeekRange == 1)

          ? _computeStudentStatsForRange(s, 0, 50)

          : (_dailySelectedWeekRange == 2)

              ? _computeStudentStatsForRange(s, 50, 100)

              : _computeStudentStatsForRange(s, 0, 100);

      totalPresent += (stats['present'] as int);

      totalAbsent += (stats['absent'] as int);

      totalLeave += (stats['leave'] as int);

      totalLate += (stats['late'] as int);

    }



    final filteredStudents = _dailyStudentList.where((s) {

      if (_dailySearchQuery.isEmpty) return true;

      final q = _dailySearchQuery.toLowerCase();

      final name = (s['full_name'] ?? '').toString().toLowerCase();

      final id = (s['student_id'] ?? '').toString().toLowerCase();

      return name.contains(q) || id.contains(q);

    }).toList();



    Widget dailyTable() => Container(

              decoration: BoxDecoration(

                color: Colors.white,

                borderRadius: BorderRadius.circular(10),

                border: Border.all(color: Colors.grey.shade400, width: 0.8),

              ),

              child: _loadingDailyGrid

                  ? const Center(child: CircularProgressIndicator())

                  : filteredStudents.isEmpty

                      ? Center(

                          child: Column(

                            mainAxisAlignment: MainAxisAlignment.center,

                            children: [

                              Icon(Icons.people_outline, size: 56, color: Colors.grey.shade400),

                              const SizedBox(height: 12),

                              Text(

                                'ยังไม่มีรายชื่อนักเรียนในระดับชั้น $_selectedClassLevel สำหรับภาคเรียนนี้',

                                style: TextStyle(color: Colors.grey.shade600, fontSize: 14),

                              ),

                              const SizedBox(height: 12),

                              if (isAdmin)
                                Wrap(

                                spacing: 10,

                                runSpacing: 8,

                                alignment: WrapAlignment.center,

                                children: [

                                  FilledButton.tonalIcon(

                                    icon: const Icon(Icons.table_view_rounded, size: 18),

                                    label: const Text('นำเข้าไฟล์ DMC (Excel)', style: TextStyle(fontSize: 12)),

                                    onPressed: _openImportDmcDialog,

                                  ),
                                   if (widget.apiService.currentUser?.canDownload ?? true)

                                     FilledButton.tonalIcon(

                                       icon: const Icon(Icons.file_download_outlined, size: 18),

                                       label: const Text('นำออกรายชื่อ (DMC)', style: TextStyle(fontSize: 12)),

                                       onPressed: _openExportDmcDialog,

                                     ),

                                  FilledButton.icon(

                                    icon: const Icon(Icons.person_add_rounded, size: 18),

                                    label: const Text('เพิ่มนักเรียน (+)', style: TextStyle(fontSize: 12)),

                                    onPressed: _openAddStudentDialog,

                                  ),

                                  OutlinedButton.icon(

                                    icon: const Icon(Icons.file_download_outlined, size: 18),

                                    label: const Text('นำเข้าจากเทอมอื่น', style: TextStyle(fontSize: 12)),

                                    onPressed: _openImportStudentsDialog,

                                  ),

                                ],

                              ),

                            ],

                          ),

                        )

                      : LayoutBuilder(builder: (context, gridConstraints) {
                          // Student names (250 px) always stay pinned on the left so the teacher sees whose row is
                          // being filled. When the remaining width is too small (phones), the summary (212 px) joins
                          // the check-in cells in the synchronised sideways scroll instead of squeezing them to nothing.
                          final bool narrowGrid = gridConstraints.maxWidth - 250 - 212 < 340;
                          Widget headerCenter() => SizedBox(

                                        width: visibleWeeks.length * 5 * 34.0,

                                        child: Column(

                                          children: [

                                            // Row 1: Week group titles

                                            Row(

                                              children: visibleWeeks.map((w) {

                                                return Container(

                                                  width: 34.0 * 5,

                                                  height: 22,

                                                  alignment: Alignment.center,

                                                  decoration: BoxDecoration(

                                                    color: Colors.indigo.shade50,

                                                    border: Border.all(color: Colors.grey.shade400, width: 0.5),

                                                  ),

                                                  child: Text('สัปดาห์ที่ $w', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),

                                                );

                                              }).toList(),

                                            ),

                                            // Row 2: Month / Year Thai Abbr

                                            Row(

                                              children: visibleWeeks.map((w) {

                                                final wData = (w - 1 < _dailyComputedWeeks.length) ? _dailyComputedWeeks[w - 1] : null;

                                                final mYear = wData?['month_year'] ?? '-';

                                                return Container(

                                                  width: 34.0 * 5,

                                                  height: 22,

                                                  alignment: Alignment.center,

                                                  decoration: BoxDecoration(

                                                    color: Colors.indigo.shade100.withValues(alpha: 0.5),

                                                    border: Border.all(color: Colors.grey.shade400, width: 0.5),

                                                  ),

                                                  child: Text(mYear, style: TextStyle(fontWeight: FontWeight.bold, fontSize: mYear.contains('-') ? 10.0 : 11, color: Colors.indigo.shade900)),

                                                );

                                              }).toList(),

                                            ),

                                            // Row 3: Day Name & Date Number (Clickable to Lock/Holiday)

                                            Row(

                                              children: visibleWeeks.expand((w) {

                                                final wData = (w - 1 < _dailyComputedWeeks.length) ? _dailyComputedWeeks[w - 1] : null;

                                                final daysList = wData?['days'] as List? ?? [];

                                                return List.generate(5, (d) {

                                                  final curDay = (d < daysList.length) ? daysList[d] : null;

                                                  final dayNum = curDay?['day_num']?.toString() ?? '';

                                                  final slotIdx = (w - 1) * 5 + d;

                                                  final lockState = _getDailySlotLockState(slotIdx);



                                                  Color headerBg;

                                                  Color headerTextColor;

                                                  if (lockState == 1) {

                                                    headerBg = Colors.blue.shade100;

                                                    headerTextColor = Colors.blue.shade900;

                                                  } else if (lockState == 2) {

                                                    headerBg = Colors.amber.shade200;

                                                    headerTextColor = Colors.amber.shade900;

                                                  } else {

                                                    headerBg = Colors.green.shade50;

                                                    headerTextColor = Colors.green.shade900;

                                                  }



                                                  return Tooltip(

                                                    message: 'สัปดาห์ที่ $w (${_dayFullNames[d]} $dayNum ${wData?['month_year'] ?? ""}): คลิกเพื่อสลับล็อกนับ/วันหยุด',

                                                    child: InkWell(

                                                      onTap: isAdmin ? () => _cycleDailySlotLock(slotIdx) : null,

                                                      child: Container(

                                                        width: 34,

                                                        height: 26,

                                                        alignment: Alignment.center,

                                                        decoration: BoxDecoration(

                                                          color: headerBg,

                                                          border: Border.all(color: Colors.grey.shade400, width: 0.5),

                                                        ),

                                                        child: Text(

                                                          '${_dayLabels[d]}$dayNum',

                                                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: headerTextColor),

                                                        ),

                                                      ),

                                                    ),

                                                  );

                                                });

                                              }).toList(),

                                            ),

                                            // Row 4: Status description

                                            Row(

                                              children: visibleWeeks.expand((w) {

                                                return List.generate(5, (d) {

                                                  final slotIdx = (w - 1) * 5 + d;

                                                  final lockState = _getDailySlotLockState(slotIdx);

                                                  String row4Text;

                                                  Color row4Bg;

                                                  Color row4TextColor;

                                                  if (lockState == 1) {

                                                    row4Text = 'ล็อกนับ';

                                                    row4Bg = Colors.blue.shade100;

                                                    row4TextColor = Colors.blue.shade900;

                                                  } else if (lockState == 2) {

                                                    row4Text = 'ไม่นับ';

                                                    row4Bg = Colors.amber.shade200;

                                                    row4TextColor = Colors.amber.shade900;

                                                  } else {

                                                    row4Text = 'ปกติ';

                                                    row4Bg = Colors.green.shade50;

                                                    row4TextColor = Colors.green.shade900;

                                                  }



                                                  return Container(

                                                    width: 34,

                                                    height: 26,

                                                    alignment: Alignment.center,

                                                    decoration: BoxDecoration(

                                                      color: row4Bg,

                                                      border: Border.all(color: Colors.grey.shade400, width: 0.5),

                                                    ),

                                                    child: Text(

                                                      row4Text,

                                                      style: TextStyle(

                                                        fontSize: lockState == 2 ? 8 : 9,

                                                        fontWeight: FontWeight.bold,

                                                        color: row4TextColor,

                                                      ),

                                                    ),

                                                  );

                                                });

                                              }).toList(),

                                            ),

                                          ],

                                        ),

                                      );
                          Widget headerRight() => Container(

                                    width: 212,

                                    decoration: BoxDecoration(

                                      color: Colors.indigo.shade50,

                                      border: Border(

                                        bottom: BorderSide(color: Colors.grey.shade400, width: 1),

                                        left: BorderSide(color: Colors.grey.shade400, width: 1),

                                      ),

                                    ),

                                    child: Column(

                                      children: [

                                        Container(

                                          height: 44,

                                          alignment: Alignment.center,

                                          padding: const EdgeInsets.symmetric(horizontal: 4),

                                          child: Column(

                                            mainAxisAlignment: MainAxisAlignment.center,

                                            children: [

                                              Text(

                                                summaryHeaderTitle,

                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, height: 1.2),

                                                textAlign: TextAlign.center,

                                              ),

                                              Text(

                                                summaryCriterionLabel,

                                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.indigo.shade800, height: 1.2),

                                                textAlign: TextAlign.center,

                                              ),

                                            ],

                                          ),

                                        ),

                                        Row(

                                          children: [

                                            Container(width: 36, height: 50, alignment: Alignment.center, child: const Text('มา', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.green))),

                                            Container(width: 36, height: 50, alignment: Alignment.center, child: const Text('ขาด', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.red))),

                                            Container(width: 36, height: 50, alignment: Alignment.center, child: const Text('ลา', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.orange))),

                                            Container(width: 36, height: 50, alignment: Alignment.center, child: const Text('สาย', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.blue))),

                                            Container(width: 56, height: 50, alignment: Alignment.center, child: const Text('%', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.teal))),

                                          ],

                                        ),

                                      ],

                                    ),

                                  );
                          Widget bodyCenter() => SizedBox(

                                          width: visibleWeeks.length * 5 * 34.0,

                                          child: Column(

                                            children: filteredStudents.asMap().entries.map((entry) {

                                              final rowIdx = entry.key;

                                              final st = entry.value;

                                              final isEven = rowIdx % 2 == 0;

                                              final statusList = st['status_list'] as List<String>;



                                              return Container(

                                                height: 36,

                                                color: isEven ? Colors.white : Colors.grey.shade50,

                                                child: Row(

                                                  children: visibleWeeks.expand((w) {

                                                    return List.generate(5, (d) {

                                                      final slotIdx = (w - 1) * 5 + d;

                                                      final val = (slotIdx < statusList.length) ? statusList[slotIdx] : '';

                                                      final lockState = _getDailySlotLockState(slotIdx);



                                                      if (st['is_locked'] == true) {

                                                        return Container(

                                                          width: 34,

                                                          height: 36,

                                                          alignment: Alignment.center,

                                                          decoration: BoxDecoration(

                                                            color: Colors.grey.shade100.withValues(alpha: 0.8),

                                                            border: Border.all(color: Colors.grey.shade300, width: 0.5),

                                                          ),

                                                          child: Text('-', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),

                                                        );

                                                      }



                                                      if (lockState == 1) {

                                                        return Container(

                                                          width: 34,

                                                          height: 36,

                                                          alignment: Alignment.center,

                                                          decoration: BoxDecoration(

                                                            color: Colors.blue.shade50.withValues(alpha: 0.6),

                                                            border: Border.all(color: Colors.blue.shade200, width: 0.5),

                                                          ),

                                                          child: Icon(Icons.check, size: 14, color: Colors.blue.shade700),

                                                        );

                                                      } else if (lockState == 2) {

                                                        return Container(

                                                          width: 34,

                                                          height: 36,

                                                          alignment: Alignment.center,

                                                          decoration: BoxDecoration(

                                                            color: Colors.amber.shade50.withValues(alpha: 0.5),

                                                            border: Border.all(color: Colors.amber.shade200, width: 0.5),

                                                          ),

                                                          child: Icon(Icons.lock_outline, size: 12, color: Colors.orange.shade700),

                                                        );

                                                      }



                                                      // Normal day cell

                                                      Color cellBg;

                                                      Widget cellContent;

                                                      if (val == '/') {

                                                        cellBg = Colors.green.shade50.withValues(alpha: 0.4);

                                                        cellContent = const Icon(Icons.check, size: 16, color: Colors.green);

                                                      } else if (val == 'ล') {

                                                        cellBg = Colors.orange.shade50.withValues(alpha: 0.4);

                                                        cellContent = const Text('ล', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.orange));

                                                      } else if (val == 'ส') {

                                                        cellBg = Colors.blue.shade50.withValues(alpha: 0.4);

                                                        cellContent = const Text('ส', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blue));

                                                      } else {

                                                        cellBg = Colors.white;

                                                        cellContent = const SizedBox();

                                                      }



                                                      return InkWell(

                                                        onTap: isAdmin ? () => _toggleDailyCell(st, slotIdx) : null,

                                                        onLongPress: isAdmin ? () => _openSmartLatePeriodDialog(st, slotIdx) : null,

                                                        onSecondaryTap: isAdmin ? () => _openSmartLatePeriodDialog(st, slotIdx) : null,

                                                        child: Container(

                                                          width: 34,

                                                          height: 36,

                                                          alignment: Alignment.center,

                                                          decoration: BoxDecoration(

                                                            color: cellBg,

                                                            border: Border.all(color: Colors.grey.shade300, width: 0.5),

                                                          ),

                                                          child: cellContent,

                                                        ),

                                                      );

                                                    });

                                                  }).toList(),

                                                ),

                                              );

                                            }).toList(),

                                          ),

                                        );
                          Widget bodyRight() => SizedBox(

                                      width: 212,

                                      child: Column(

                                        children: filteredStudents.asMap().entries.map((entry) {

                                          final rowIdx = entry.key;

                                          final st = entry.value;

                                          final isEven = rowIdx % 2 == 0;



                                          final stats = (_dailySelectedWeekRange == 1)

                                              ? _computeStudentStatsForRange(st, 0, 50)

                                              : (_dailySelectedWeekRange == 2)

                                                  ? _computeStudentStatsForRange(st, 50, 100)

                                                  : _computeStudentStatsForRange(st, 0, 100);



                                          final pCount = stats['present'] as int;

                                          final aCount = stats['absent'] as int;

                                          final lCount = stats['leave'] as int;

                                          final ltCount = stats['late'] as int;

                                          final pct = (stats['percentage'] as num).toDouble();



                                          if (st['is_locked'] == true) {

                                            return Container(

                                              height: 36,

                                              decoration: BoxDecoration(

                                                color: Colors.amber.shade50.withValues(alpha: 0.4),

                                                border: Border(

                                                  bottom: BorderSide(color: Colors.grey.shade300, width: 0.5),

                                                  left: BorderSide(color: Colors.grey.shade400, width: 1),

                                                ),

                                              ),

                                              child: Center(

                                                child: Row(

                                                  mainAxisAlignment: MainAxisAlignment.center,

                                                  mainAxisSize: MainAxisSize.min,

                                                  children: [

                                                    Icon(Icons.lock_rounded, size: 11, color: Colors.amber.shade900),

                                                    const SizedBox(width: 3),

                                                    Text(

                                                      'ล็อก (ไม่คิด / ไม่แสดง ปพ.5)',

                                                      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.amber.shade900),

                                                    ),

                                                  ],

                                                ),

                                              ),

                                            );

                                          }



                                          return Container(

                                            height: 36,

                                            decoration: BoxDecoration(

                                              color: isEven ? Colors.white : Colors.grey.shade50,

                                              border: Border(

                                                bottom: BorderSide(color: Colors.grey.shade300, width: 0.5),

                                                left: BorderSide(color: Colors.grey.shade400, width: 1),

                                              ),

                                            ),

                                            child: Row(

                                              children: [

                                                Container(width: 36, alignment: Alignment.center, child: Text('$pCount', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green))),

                                                Container(width: 36, alignment: Alignment.center, child: Text('$aCount', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: aCount > 0 ? Colors.red : Colors.grey))),

                                                Container(width: 36, alignment: Alignment.center, child: Text('$lCount', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: lCount > 0 ? Colors.orange : Colors.grey))),

                                                Container(width: 36, alignment: Alignment.center, child: Text('$ltCount', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: ltCount > 0 ? Colors.blue : Colors.grey))),

                                                Builder(

                                                  builder: (context) {

                                                    Color pctTextColor;

                                                    Color? pctBgColor;

                                                    Border? pctBorder;

                                                    if (pct >= 80) {

                                                      pctTextColor = Colors.teal.shade800;

                                                      pctBgColor = null;

                                                      pctBorder = null;

                                                    } else if (pct >= 60) {

                                                      pctTextColor = Colors.orange.shade900;

                                                      pctBgColor = Colors.orange.shade50;

                                                      pctBorder = Border.all(color: Colors.orange.shade300, width: 0.8);

                                                    } else {

                                                      pctTextColor = Colors.red.shade800;

                                                      pctBgColor = Colors.red.shade50;

                                                      pctBorder = Border.all(color: Colors.red.shade300, width: 0.8);

                                                    }

                                                    return Container(

                                                      width: 56,

                                                      alignment: Alignment.center,

                                                      padding: const EdgeInsets.symmetric(horizontal: 2),

                                                      child: Container(

                                                        padding: EdgeInsets.symmetric(

                                                          horizontal: pctBgColor != null ? 5 : 0,

                                                          vertical: pctBgColor != null ? 2 : 0,

                                                        ),

                                                        decoration: pctBgColor != null

                                                            ? BoxDecoration(

                                                                color: pctBgColor,

                                                                borderRadius: BorderRadius.circular(4),

                                                                border: pctBorder,

                                                              )

                                                            : null,

                                                        child: Text(

                                                          '${pct % 1 == 0 ? pct.toInt() : pct}%',

                                                          style: TextStyle(

                                                            fontSize: 11,

                                                            fontWeight: FontWeight.bold,

                                                            color: pctTextColor,

                                                          ),

                                                        ),

                                                      ),

                                                    );

                                                  },

                                                ),

                                              ],

                                            ),

                                          );

                                        }).toList(),

                                      ),

                                    );
                          return Column(

                          children: [

                            // --------------------------------------------------

                            // FIXED PINNED HEADER (Height 96)

                            // --------------------------------------------------

                            SizedBox(

                              height: 96,

                              child: Row(

                                children: [

                                  // Left Header (Width 250)

                                  Container(

                                    width: 250,

                                    decoration: BoxDecoration(

                                      color: Colors.indigo.shade50,

                                      border: Border(

                                        bottom: BorderSide(color: Colors.grey.shade400, width: 1),

                                        right: BorderSide(color: Colors.grey.shade400, width: 1),

                                      ),

                                    ),

                                    child: Row(

                                      children: [

                                        const SizedBox(width: 26, child: Center(child: Text('ที่', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)))),

                                        const SizedBox(width: 50, child: Center(child: Text('รหัส', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)))),

                                        const Expanded(

                                          child: Center(

                                            child: Tooltip(

                                              message: 'คลิกที่ชื่อนักเรียนเพื่อล็อก/ปลดล็อก (ไม่นำมาคิดและไม่แสดงใน ปพ.5)',

                                              child: Row(

                                                mainAxisAlignment: MainAxisAlignment.center,

                                                children: [

                                                  Text('ชื่อ - นามสกุล', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),

                                                  SizedBox(width: 4),

                                                  Icon(Icons.touch_app_outlined, size: 13, color: Colors.grey),

                                                ],

                                              ),

                                            ),

                                          ),

                                        ),

                                        SizedBox(
                                          width: 30,
                                          child: isAdmin
                                              ? IconButton(
                                                  tooltip: 'เพิ่มนักเรียน (+)',
                                                  icon: const Icon(Icons.add_circle, color: Colors.teal, size: 18),
                                                  padding: EdgeInsets.zero,
                                                  onPressed: _openAddStudentDialog,
                                                )
                                              : const SizedBox.shrink(),
                                        ),

                                      ],

                                    ),

                                  ),



                                  // Center Grid Header (Horizontally scrollable with mouse drag)
                                  Expanded(
                                    child: ScrollConfiguration(
                                      behavior: const MaterialScrollBehavior().copyWith(
                                        dragDevices: {
                                          PointerDeviceKind.touch,
                                          PointerDeviceKind.mouse,
                                          PointerDeviceKind.trackpad,
                                          PointerDeviceKind.stylus,
                                        },
                                      ),
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        controller: _headerHorizontalController,

                                      child: narrowGrid ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [headerCenter(), headerRight()]) : headerCenter(),
                                      ),
                                    ),
                                  ),

                                  // Right Header (Width 212 - Fully Fitted, No Overflow)

                                  if (!narrowGrid) headerRight(),

                                ],

                              ),

                            ),



                            // --------------------------------------------------

                            // SCROLLABLE TABLE BODY (Single Vertical Scroll, Synchronized)

                            // --------------------------------------------------

                            Expanded(

                              child: SingleChildScrollView(

                                controller: _verticalScrollController,

                                child: Row(

                                  crossAxisAlignment: CrossAxisAlignment.start,

                                  children: [

                                    // Left Column: Student Info (Width 250)

                                    SizedBox(

                                      width: 250,

                                      child: Column(

                                        children: filteredStudents.asMap().entries.map((entry) {

                                          final rowIdx = entry.key;

                                          final st = entry.value;

                                          final isEven = rowIdx % 2 == 0;

                                          return Container(

                                            height: 36,

                                            decoration: BoxDecoration(

                                              color: isEven ? Colors.white : Colors.grey.shade50,

                                              border: Border(

                                                bottom: BorderSide(color: Colors.grey.shade300, width: 0.5),

                                                right: BorderSide(color: Colors.grey.shade400, width: 1),

                                              ),

                                            ),

                                            child: Row(

                                              children: [

                                                SizedBox(

                                                  width: 26,

                                                  child: Center(

                                                    child: Text(

                                                      '${st['student_no'] ?? rowIdx + 1}',

                                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),

                                                    ),

                                                  ),

                                                ),

                                                SizedBox(

                                                  width: 50,

                                                  child: Center(

                                                    child: Text(

                                                      '${st['student_id']}',

                                                      style: TextStyle(fontSize: 10.5, color: Colors.grey.shade800),

                                                    ),

                                                  ),

                                                ),

                                                Expanded(

                                                  child: Padding(

                                                    padding: const EdgeInsets.symmetric(horizontal: 4),

                                                    child: Row(

                                                      children: [

                                                        Expanded(

                                                          child: Tooltip(

                                                            message: st['is_locked'] == true

                                                                ? 'คลิกเพื่อปลดล็อก (นำกลับมาคิดและแสดงใน ปพ.5)'

                                                                : 'คลิกเพื่อล็อก (ไม่นำมาคิดและไม่แสดงใน ปพ.5)',

                                                            child: InkWell(

                                                              onTap: isAdmin ? () => _toggleStudentLock(st) : null,

                                                              borderRadius: BorderRadius.circular(4),

                                                              child: Padding(

                                                                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),

                                                                child: Row(

                                                                  children: [

                                                                    if (st['is_locked'] == true) ...[

                                                                      Icon(Icons.lock_rounded, size: 12, color: Colors.amber.shade900),

                                                                      const SizedBox(width: 2),

                                                                    ],

                                                                    Expanded(

                                                                      child: Text(

                                                                        '${st['full_name']}',

                                                                        overflow: TextOverflow.ellipsis,

                                                                        style: TextStyle(

                                                                          fontSize: 11,

                                                                          fontWeight: FontWeight.w500,

                                                                          color: st['is_locked'] == true ? Colors.grey.shade500 : Colors.black87,

                                                                          decoration: st['is_locked'] == true ? TextDecoration.lineThrough : null,

                                                                        ),

                                                                      ),

                                                                    ),

                                                                    if (widget.apiService.currentUser?.canEditData ?? false)

                                                                      PopupMenuButton<String>(

                                                                        tooltip: 'แก้ไข (ชื่อ / รูป)',

                                                                        padding: EdgeInsets.zero,

                                                                        position: PopupMenuPosition.under,

                                                                        onSelected: (choice) {
                                                                          if (choice == 'name') _editStudentName(st);
                                                                          if (choice == 'photo') _editStudentPhoto(st);
                                                                        },

                                                                        itemBuilder: (_) => const [
                                                                          PopupMenuItem<String>(
                                                                            value: 'name',
                                                                            height: 40,
                                                                            child: Row(children: [
                                                                              Icon(Icons.badge_outlined, size: 18),
                                                                              SizedBox(width: 10),
                                                                              Text('แก้ไขชื่อ'),
                                                                            ]),
                                                                          ),
                                                                          PopupMenuItem<String>(
                                                                            value: 'photo',
                                                                            height: 40,
                                                                            child: Row(children: [
                                                                              Icon(Icons.photo_camera_outlined, size: 18),
                                                                              SizedBox(width: 10),
                                                                              Text('แก้ไขรูป'),
                                                                            ]),
                                                                          ),
                                                                        ],

                                                                        child: Padding(

                                                                          padding: const EdgeInsets.symmetric(horizontal: 2),

                                                                          child: Icon(Icons.edit_outlined, size: 12, color: Colors.grey.shade600),

                                                                        ),

                                                                      ),

                                                                    if (st['is_locked'] == true) ...[

                                                                      const SizedBox(width: 2),

                                                                      Container(

                                                                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),

                                                                        decoration: BoxDecoration(

                                                                          color: Colors.amber.shade100,

                                                                          borderRadius: BorderRadius.circular(4),

                                                                          border: Border.all(color: Colors.amber.shade400, width: 0.5),

                                                                        ),

                                                                        child: Text(

                                                                          'ล็อก',

                                                                          style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Colors.amber.shade900),

                                                                        ),

                                                                      ),

                                                                    ],

                                                                  ],

                                                                ),

                                                              ),

                                                            ),

                                                          ),

                                                        ),

                                                        if (st['room'] != null && _availableRooms.length > 1) ...[

                                                          const SizedBox(width: 2),

                                                          Container(

                                                            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),

                                                            decoration: BoxDecoration(

                                                              color: Colors.teal.shade50,

                                                              borderRadius: BorderRadius.circular(4),

                                                              border: Border.all(color: Colors.teal.shade200, width: 0.5),

                                                            ),

                                                            child: Text(

                                                              '/${st['room']}',

                                                              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.teal.shade800),

                                                            ),

                                                          ),

                                                        ],

                                                      ],

                                                    ),

                                                  ),

                                                ),

                                                SizedBox(
                                                  width: 30,
                                                  child: isAdmin
                                                      ? IconButton(
                                                          tooltip: 'ลบ/ย้ายออก (-)',
                                                          visualDensity: VisualDensity.compact,
                                                          padding: EdgeInsets.zero,
                                                          icon: Icon(Icons.remove_circle_outline, color: Colors.red.shade400, size: 15),
                                                          onPressed: () => _confirmRemoveStudent(st),
                                                        )
                                                      : const SizedBox.shrink(),
                                                ),

                                              ],

                                            ),

                                          );

                                        }).toList(),

                                      ),

                                    ),



                                    // Center Column: Daily Checkmark Cells (Scrollable horizontally with mouse drag)
                                    Expanded(
                                      child: ScrollConfiguration(
                                        behavior: const MaterialScrollBehavior().copyWith(
                                          dragDevices: {
                                            PointerDeviceKind.touch,
                                            PointerDeviceKind.mouse,
                                            PointerDeviceKind.trackpad,
                                            PointerDeviceKind.stylus,
                                          },
                                        ),
                                        child: Listener(
                                          onPointerSignal: (pointerSignal) {
                                            if (pointerSignal is PointerScrollEvent && pointerSignal.scrollDelta.dx != 0) {
                                              if (_gridHorizontalController.hasClients) {
                                                final newOffset = (_gridHorizontalController.offset + pointerSignal.scrollDelta.dx)
                                                    .clamp(0.0, _gridHorizontalController.position.maxScrollExtent);
                                                _gridHorizontalController.jumpTo(newOffset);
                                              }
                                            }
                                          },
                                          child: SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            controller: _gridHorizontalController,

                                        child: narrowGrid ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [bodyCenter(), bodyRight()]) : bodyCenter(),
                                            ),
                                          ),
                                        ),
                                      ),

                                    // Right Column: Summary (Width 212 - Perfectly Fitted, No Cutoff)

                                    if (!narrowGrid) bodyRight(),

                                                                    ],
                                ),
                              ),
                            ),

                            // --------------------------------------------------
                            // 5. PINNED BOTTOM NAVIGATION & HORIZONTAL SCROLLBAR BAR
                            // --------------------------------------------------
                            Container(
                              height: 42,
                              decoration: BoxDecoration(
                                color: Colors.indigo.shade50.withValues(alpha: 0.5),
                                border: Border(top: BorderSide(color: Colors.grey.shade300, width: 1)),
                                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(9)),
                              ),
                              child: Row(
                                children: [
                                  // Left Section (Width 250 - Aligned with Student Names)
                                  SizedBox(
                                    width: 250,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                      child: Row(
                                        children: [
                                          Icon(Icons.swap_horiz_rounded, size: 16, color: Colors.indigo.shade800),
                                          const SizedBox(width: 4),
                                          Text(
                                            'เลื่อนสัปดาห์:',
                                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.indigo.shade900),
                                          ),
                                          const Spacer(),
                                          IconButton(
                                            tooltip: 'ไปสัปดาห์แรกสุด',
                                            icon: const Icon(Icons.first_page_rounded, size: 20),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                            onPressed: () => _scrollToOffset(0),
                                          ),
                                          IconButton(
                                            tooltip: 'เลื่อนซ้าย 1 สัปดาห์ (5 วัน)',
                                            icon: const Icon(Icons.chevron_left_rounded, size: 22),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                            onPressed: () => _scrollGridBy(-170),
                                          ),
                                          IconButton(
                                            tooltip: 'เลื่อนขวา 1 สัปดาห์ (5 วัน)',
                                            icon: const Icon(Icons.chevron_right_rounded, size: 22),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                            onPressed: () => _scrollGridBy(170),
                                          ),
                                          IconButton(
                                            tooltip: 'ไปสัปดาห์ท้ายสุด',
                                            icon: const Icon(Icons.last_page_rounded, size: 20),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                            onPressed: () {
                                              if (_gridHorizontalController.hasClients) {
                                                _scrollToOffset(_gridHorizontalController.position.maxScrollExtent);
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // Center Section (Expanded - Real Synchronized Scrollbar)
                                  Expanded(
                                    child: ScrollConfiguration(
                                      behavior: const MaterialScrollBehavior().copyWith(
                                        dragDevices: {
                                          PointerDeviceKind.touch,
                                          PointerDeviceKind.mouse,
                                          PointerDeviceKind.trackpad,
                                          PointerDeviceKind.stylus,
                                        },
                                      ),
                                      child: Scrollbar(
                                        controller: _footerHorizontalController,
                                        thumbVisibility: true,
                                        trackVisibility: true,
                                        thickness: 8,
                                        radius: const Radius.circular(4),
                                        child: SingleChildScrollView(
                                          controller: _footerHorizontalController,
                                          scrollDirection: Axis.horizontal,
                                          child: Container(
                                            width: visibleWeeks.length * 5 * 34.0 + (narrowGrid ? 212 : 0),
                                            height: 40,
                                            alignment: Alignment.center,
                                            padding: const EdgeInsets.only(bottom: 10),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Icon(Icons.touch_app_outlined, size: 13, color: Colors.indigo.shade600),
                                                const SizedBox(width: 5),
                                                Text(
                                                  '↔ เลื่อนแถบนี้ หรือคลิกลากตาราง เพื่อดูสัปดาห์ที่เหลือ (แสดง ${visibleWeeks.length} สัปดาห์ • ${visibleWeeks.length * 5} วัน)',
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.indigo.shade800,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Right Section (Width 212 - Aligned with Summary)
                                  if (!narrowGrid) Container(
                                    width: 212,
                                    decoration: BoxDecoration(
                                      border: Border(left: BorderSide(color: Colors.grey.shade400, width: 1)),
                                    ),
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    alignment: Alignment.center,
                                    child: Text(
                                      'เกณฑ์ประเมิน $viewCriterion วัน',
                                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.indigo.shade900),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                        }),

            );

    return Padding(

      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),

      child: Column(

        crossAxisAlignment: CrossAxisAlignment.stretch,

        children: [

          // 1. All 6 Classes Selector Bar (หน้าเดียว ครบ 6 ชั้น)

          Container(

            padding: const EdgeInsets.all(8),

            decoration: BoxDecoration(

              color: Colors.white,

              borderRadius: BorderRadius.circular(10),

              border: Border.all(color: Colors.grey.shade300),

            ),

            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [

                const Row(mainAxisSize: MainAxisSize.min, 

                  children: [

                    Icon(Icons.school_rounded, size: 20, color: Colors.indigo),

                    SizedBox(width: 6),

                    Text('เลือกระดับชั้น:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),

                  ],

                ),

                const SizedBox(width: 8),



                // 6 Class Level Buttons

                Wrap(

                  spacing: 4,

                  children: _classLevels.map((lvl) {

                    final isSel = _selectedClassLevel == lvl;

                    final cnt = _classCounts[lvl] ?? 0;

                    return FilterChip(

                      selected: isSel,

                      label: Text('$lvl ($cnt)'),

                      labelStyle: TextStyle(

                        fontSize: 12,

                        fontWeight: isSel ? FontWeight.bold : FontWeight.normal,

                        color: isSel ? Colors.indigo.shade900 : Colors.black87,

                      ),

                      selectedColor: Colors.indigo.shade100,

                      backgroundColor: Colors.grey.shade100,

                      visualDensity: VisualDensity.compact,

                      onSelected: (_) async {
                        await _flushPendingDailySave();
                        setState(() {
                          _selectedClassLevel = lvl;
                          _selectedRoom = 'all';
                        });
                        _loadDailyAttendanceGrid();
                      },

                    );

                  }).toList(),

                ),







                const SizedBox(width: 12),



                // Action Buttons
                // รูปนักเรียน: ผู้ดูแลระบบทุกชั้น / ครูประจำชั้นเฉพาะชั้นของตน (เซิร์ฟเวอร์ตรวจสิทธิ์)
                if (!widget.apiService.isDirector && !widget.apiService.isGuest) ...[
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.photo_library_rounded, size: 16),
                    label: const Text('อัปโหลดรูปนักเรียน', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Colors.purple.shade50,
                      foregroundColor: Colors.purple.shade800,
                    ),
                    onPressed: _openStudentPhotoDialog,
                  ),
                  const SizedBox(width: 6),
                ],

                    if (isAdmin) ...[

                FilledButton.tonalIcon(

                  icon: const Icon(Icons.person_add_rounded, size: 16),

                  label: const Text('เพิ่มนักเรียน (+)', style: TextStyle(fontSize: 12)),

                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),

                  onPressed: _openAddStudentDialog,

                ),

                const SizedBox(width: 6),

                FilledButton.tonalIcon(

                  icon: const Icon(Icons.table_view_rounded, size: 16),

                  label: const Text('นำเข้า DMC (Excel)', style: TextStyle(fontSize: 12)),

                  style: FilledButton.styleFrom(

                    visualDensity: VisualDensity.compact,

                    backgroundColor: Colors.teal.shade50,

                    foregroundColor: Colors.teal.shade800,

                  ),

                  onPressed: _openImportDmcDialog,

                ),
                const SizedBox(width: 6),
                if (widget.apiService.currentUser?.canDownload ?? true)

                  FilledButton.tonalIcon(

                    icon: const Icon(Icons.file_download_outlined, size: 16),

                    label: const Text('นำออกรายชื่อ (DMC)', style: TextStyle(fontSize: 12)),

                    style: FilledButton.styleFrom(

                      visualDensity: VisualDensity.compact,

                      backgroundColor: Colors.indigo.shade50,

                      foregroundColor: Colors.indigo.shade800,

                    ),

                    onPressed: _openExportDmcDialog,

                  ),

                const SizedBox(width: 6),

                OutlinedButton.icon(

                  icon: const Icon(Icons.file_download_outlined, size: 16),

                  label: const Text('นำเข้าจากเทอมอื่น', style: TextStyle(fontSize: 12)),

                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),

                  onPressed: _openImportStudentsDialog,

                ),
                    ],



              ],

            ),

          ),

          const SizedBox(height: 8),



          // 2. Control Toolbar (Start Date, All-Present Checkbox, Mode, Week Division Selector, Search)

          Container(

            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),

            decoration: BoxDecoration(

              color: Colors.white,

              borderRadius: BorderRadius.circular(10),

              border: Border.all(color: Colors.grey.shade300),

            ),

            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [

                // Start Date Picker

                InkWell(

                  onTap: _openDatePickerDialog,

                  child: Row(mainAxisSize: MainAxisSize.min, 

                    children: [

                      const Icon(Icons.calendar_month_outlined, size: 18, color: Colors.indigo),

                      const SizedBox(width: 6),

                      Column(

                        crossAxisAlignment: CrossAxisAlignment.start,

                        children: [

                          Text('วันเริ่มภาคเรียน (ช่องแรก):', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),

                          Text(_formatDateThai(_dailyStartDate), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),

                        ],

                      ),

                      const SizedBox(width: 4),

                      Icon(Icons.edit_calendar_outlined, size: 15, color: Colors.indigo.shade400),

                    ],

                  ),

                ),

                const SizedBox(width: 12),

                const SizedBox(width: 4),

                const SizedBox(width: 12),



                // All Present Checkbox (มีผลเฉพาะห้องที่กำลังเลือก)
                Tooltip(
                  message: _dailyAllPresent
                      ? 'คลิกเพื่อล้างเวลาเรียนให้ว่างทุกช่องเสมือนรีเซ็ต (เฉพาะ${_selectedRoom == 'all' ? 'ทุกห้องในชั้นนี้' : 'ห้อง $_selectedRoom'})'
                      : 'คลิกเพื่อตั้งค่าให้มาเรียนทุกคน 100% (เฉพาะ${_selectedRoom == 'all' ? 'ทุกห้องในชั้นนี้' : 'ห้อง $_selectedRoom'})',
                  child: Row(mainAxisSize: MainAxisSize.min, 
                    children: [
                      Checkbox(
                        value: _dailyAllPresent,
                        onChanged: isAdmin ? (v) => _setDailyAllPresent(v ?? false) : null,
                        visualDensity: VisualDensity.compact,
                      ),
                      Text(
                        _selectedRoom == 'all'
                            ? 'มาเรียนทุกคน (100% ทุกห้อง)'
                            : 'มาเรียนทุกคน (100% ห้อง $_selectedRoom)',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 12),

                const SizedBox(width: 4),

                const SizedBox(width: 12),



                // Multi-room selector if class has rooms (ขยับมาไว้แถวนี้แทนโหมดคลิกเดิม เพื่อไม่ให้ปุ่มหลุดกรอบ)

                if (_availableRooms.length > 1) ...[

                  Icon(Icons.meeting_room_outlined, size: 16, color: Colors.teal.shade800),

                  const SizedBox(width: 4),

                  Wrap(

                    spacing: 4,

                    children: [

                      FilterChip(
                        selected: _selectedRoom == 'all',
                        label: const Text('ทุกห้อง', style: TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) async {
                          await _flushPendingDailySave();
                          setState(() => _selectedRoom = 'all');
                          _filterDailyStudentList();
                        },
                      ),

                      ..._availableRooms.map((rm) {

                        final isSel = _selectedRoom == rm;

                        return FilterChip(
                          selected: isSel,
                          label: Text('ห้อง $rm', style: const TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) async {
                            await _flushPendingDailySave();
                            setState(() => _selectedRoom = rm);
                            _filterDailyStudentList();
                          },
                        );

                      }),

                    ],

                  ),

                  const SizedBox(width: 12),

                  Container(height: 24, width: 1, color: Colors.grey.shade300),

                  const SizedBox(width: 12),

                ],



                // Prominent Week Division Selector (กลางภาค สัปดาห์ 1-10 vs หลังกลางภาค สัปดาห์ 11-20 vs ทั้งหมด)

                Container(

                  decoration: BoxDecoration(

                    color: Colors.indigo.shade50.withValues(alpha: 0.6),

                    borderRadius: BorderRadius.circular(8),

                    border: Border.all(color: Colors.indigo.shade200),

                  ),

                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),

                  child: DropdownButtonHideUnderline(

                    child: DropdownButton<int>(

                      value: _dailySelectedWeekRange,

                      isDense: true,

                      icon: const Icon(Icons.arrow_drop_down, color: Colors.indigo),

                      style: TextStyle(

                        fontWeight: FontWeight.bold,

                        color: Colors.indigo.shade900,

                        fontSize: 12,

                        fontFamily: 'Sarabun',

                      ),

                      items: const [

                        DropdownMenuItem(

                          value: 1,

                          child: Row(

                            mainAxisSize: MainAxisSize.min,

                            children: [

                              Icon(Icons.looks_one_rounded, size: 16, color: Colors.indigo),

                              SizedBox(width: 6),

                              Text('กลางภาค (สัปดาห์ที่ 1 - 10) • สรุป 10 สัปดาห์'),

                            ],

                          ),

                        ),

                        DropdownMenuItem(

                          value: 2,

                          child: Row(

                            mainAxisSize: MainAxisSize.min,

                            children: [

                              Icon(Icons.looks_two_rounded, size: 16, color: Colors.indigo),

                              SizedBox(width: 6),

                              Text('หลังกลางภาค (สัปดาห์ที่ 11 - 20) • สรุป 10 สัปดาห์ (หลังกลางภาค)'),

                            ],

                          ),

                        ),

                        DropdownMenuItem(

                          value: 0,

                          child: Row(

                            mainAxisSize: MainAxisSize.min,

                            children: [

                              Icon(Icons.view_week_rounded, size: 16, color: Colors.indigo),

                              SizedBox(width: 6),

                              Text('ทั้งหมด 20 สัปดาห์ (1 - 20) • สรุปรวม 20 สัปดาห์'),

                            ],

                          ),

                        ),

                      ],

                      onChanged: (v) {
                        setState(() => _dailySelectedWeekRange = v ?? 1);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _scrollToOffset(0);
                        });
                      },

                                        ),
                  ),
                ),
                const SizedBox(width: 8),

                // Quick Week Navigation Buttons in Toolbar
                Container(
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: 'เลื่อนซ้าย 1 สัปดาห์ (5 วัน)',
                        child: InkWell(
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                          onTap: () => _scrollGridBy(-170),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.chevron_left_rounded, size: 18, color: Colors.indigo.shade800),
                                Text('เลื่อนซ้าย', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.indigo.shade800)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Container(width: 1, height: 18, color: Colors.grey.shade300),
                      Tooltip(
                        message: 'เลื่อนขวา 1 สัปดาห์ (5 วัน)',
                        child: InkWell(
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                          onTap: () => _scrollGridBy(170),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('เลื่อนขวา', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.indigo.shade800)),
                                Icon(Icons.chevron_right_rounded, size: 18, color: Colors.indigo.shade800),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),

                // Quick Jump Block Chips (e.g., ส. 1-5, ส. 6-10, ส. 11-15, ส. 16-20)
                if (_dailySelectedWeekRange == 0) ...[
                  ...[
                    {'label': 'ส. 1-5', 'offset': 0.0},
                    {'label': 'ส. 6-10', 'offset': 5 * 170.0},
                    {'label': 'ส. 11-15', 'offset': 10 * 170.0},
                    {'label': 'ส. 16-20', 'offset': 15 * 170.0},
                  ].map((b) => Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      label: Text(b['label'] as String, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      onPressed: () => _scrollToOffset(b['offset'] as double),
                      backgroundColor: Colors.indigo.shade50.withValues(alpha: 0.5),
                    ),
                  )),
                ] else if (_dailySelectedWeekRange == 1) ...[
                  ...[
                    {'label': 'ส. 1-5', 'offset': 0.0},
                    {'label': 'ส. 6-10', 'offset': 5 * 170.0},
                  ].map((b) => Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      label: Text(b['label'] as String, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      onPressed: () => _scrollToOffset(b['offset'] as double),
                      backgroundColor: Colors.indigo.shade50.withValues(alpha: 0.5),
                    ),
                  )),
                ] else if (_dailySelectedWeekRange == 2) ...[
                  ...[
                    {'label': 'ส. 11-15', 'offset': 0.0},
                    {'label': 'ส. 16-20', 'offset': 5 * 170.0},
                  ].map((b) => Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      label: Text(b['label'] as String, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      onPressed: () => _scrollToOffset(b['offset'] as double),
                      backgroundColor: Colors.indigo.shade50.withValues(alpha: 0.5),
                    ),
                  )),
                ],

                const SizedBox(width: 12),



                // Search Box

                SizedBox(

                  width: 180,

                  height: 32,

                  child: TextField(

                    decoration: InputDecoration(

                      hintText: 'ค้นหาชื่อ/รหัส...',

                      hintStyle: const TextStyle(fontSize: 11),

                      prefixIcon: const Icon(Icons.search, size: 16),

                      isDense: true,

                      contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),

                      border: OutlineInputBorder(

                        borderRadius: BorderRadius.circular(6),

                        borderSide: BorderSide(color: Colors.grey.shade300),

                      ),

                    ),

                    onChanged: (val) => setState(() => _dailySearchQuery = val),

                  ),

                ),



              ],

            ),

          ),

          const SizedBox(height: 8),



          // 3. Stats Summary Badges

          Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [

              Text(

                'นักเรียนชั้น $_selectedClassLevel (${_dailyStudentList.length} คน${lockedCount > 0 ? " • ล็อก $lockedCount คน" : ""})',

                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),

              ),

              if (lockedCount > 0)

                Container(

                  margin: const EdgeInsets.only(left: 6),

                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),

                  decoration: BoxDecoration(

                    color: Colors.amber.shade100,

                    borderRadius: BorderRadius.circular(10),

                    border: Border.all(color: Colors.amber.shade400, width: 0.5),

                  ),

                  child: Row(

                    mainAxisSize: MainAxisSize.min,

                    children: [

                      Icon(Icons.lock_rounded, size: 12, color: Colors.amber.shade900),

                      const SizedBox(width: 3),

                      Text(

                        'ไม่นำมาคิด $lockedCount คน',

                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber.shade900),

                      ),

                    ],

                  ),

                ),

              const SizedBox(width: 8),

              if (_dailyLockedCountedSlots.isNotEmpty)

                Text(

                  '• ล็อกนับ ${_dailyLockedCountedSlots.length} วัน',

                  style: TextStyle(fontSize: 11, color: Colors.blue.shade800, fontWeight: FontWeight.bold),

                ),

              if (_dailyHolidaySlots.isNotEmpty)

                Padding(

                  padding: const EdgeInsets.only(left: 6),

                  child: Text(

                    '• ล็อกไม่นับวันหยุด ${_dailyHolidaySlots.length} วัน',

                    style: TextStyle(fontSize: 11, color: Colors.orange.shade800, fontWeight: FontWeight.bold),

                  ),

                ),



              if (isAdmin) ...[
                // โหมดคลิก (ขยับมาไว้ระหว่างชั้นเรียนกับเกณฑ์วัน ตามคำขอ)
                const SizedBox(width: 14),
                Container(height: 20, width: 1, color: Colors.grey.shade300),
                const SizedBox(width: 14),
                Text(
                  'โหมดคลิก:',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 6),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'present', label: Text('✓ มา', style: TextStyle(fontSize: 11))),
                    ButtonSegment(value: 'leave', label: Text('ล ลา', style: TextStyle(fontSize: 11))),
                    ButtonSegment(
                      value: 'late',
                      tooltip: 'คลิกช่องวันของนักเรียนเพื่อเลือกคาบที่มาสาย (1-7) และตัดขาดวิชาคาบก่อนหน้าอัตโนมัติ',
                      label: Text('ส สาย (เลือกคาบ 1-7)', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(value: 'absent', label: Text('✕ ขาด (ว่าง)', style: TextStyle(fontSize: 11))),
                  ],
                  selected: {_dailyCurrentMode},
                  onSelectionChanged: (set) => setState(() => _dailyCurrentMode = set.first),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],



              const SizedBox(width: 12),

              Chip(

                avatar: const Icon(Icons.calendar_today_outlined, size: 12, color: Colors.indigo),

                label: Text('เกณฑ์: $viewCriterion วัน', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),

                backgroundColor: Colors.indigo.shade50,

                visualDensity: VisualDensity.compact,

              ),

              const SizedBox(width: 4),

              Chip(

                avatar: const Icon(Icons.check, size: 12, color: Colors.green),

                label: Text('รวมมา: $totalPresent', style: const TextStyle(fontSize: 11)),

                backgroundColor: Colors.white,

                visualDensity: VisualDensity.compact,

              ),

              const SizedBox(width: 4),

              Chip(

                avatar: const Icon(Icons.close, size: 12, color: Colors.red),

                label: Text('รวมขาด: $totalAbsent', style: const TextStyle(fontSize: 11)),

                backgroundColor: Colors.white,

                visualDensity: VisualDensity.compact,

              ),

              const SizedBox(width: 4),

              Chip(

                avatar: const Icon(Icons.event_busy, size: 12, color: Colors.orange),

                label: Text('รวมลา: $totalLeave', style: const TextStyle(fontSize: 11)),

                backgroundColor: Colors.white,

                visualDensity: VisualDensity.compact,

              ),

              const SizedBox(width: 4),

              Chip(

                avatar: const Icon(Icons.schedule, size: 12, color: Colors.blue),

                label: Text('รวมสาย: $totalLate', style: const TextStyle(fontSize: 11)),

                backgroundColor: Colors.white,

                visualDensity: VisualDensity.compact,

              ),

            ],

          ),

          const SizedBox(height: 8),



          // 4. Main Table Container (Unified Synchronized Scrolling, Zero-Overflow)

          if (compact)
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.8, child: dailyTable())
          else
            Expanded(child: dailyTable()),

        ],

      ),

    );

  }

}

