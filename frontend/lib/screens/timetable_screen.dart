import 'package:flutter/material.dart';

import 'package:file_picker/file_picker.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';

import '../models/semester_config.dart';
import '../models/logged_in_teacher.dart';
import '../utils/app_theme.dart';



class TimetableScreen extends StatefulWidget {

  final ApiService apiService;



  const TimetableScreen({

    super.key,

    required this.apiService,

  });



  @override

  State<TimetableScreen> createState() => _TimetableScreenState();

}



class _TimetableScreenState extends State<TimetableScreen> {

  bool _loading = true;

  List<SemesterConfigItem> _semesters = [];

  String _selectedTerm = '1';

  String _selectedYear = '2569';



  // View mode: 'teacher', 'class', or 'master'

  String _viewMode = 'teacher';

  // The top bar (title, semester, view buttons, Excel buttons) can be folded into one thin line, like Word's
  // "collapse the ribbon", so a phone screen has room for the timetable. Remembered per device.
  bool _headerCollapsed = false;
  static const String _headerCollapsedPrefKey = 'timetable_header_collapsed';
  // The same for the blue title banner and, in ตารางสอนรวม, the "เช็คครูว่าง / ครูสอนประจำห้อง" panel: on a phone the
  // two together are almost two screens tall before the table starts.
  bool _bannerCollapsed = false;
  bool _checkPanelCollapsed = false;
  static const String _bannerCollapsedPrefKey = 'timetable_banner_collapsed';
  static const String _checkPanelCollapsedPrefKey = 'timetable_checkpanel_collapsed';

  int _selectedMasterDay = 1;

  int _selectedMasterPeriod = 1;

  final ScrollController _masterHScrollController = ScrollController();

  String _selectedTeacher = '';

  bool _hasInitializedTeacherForUser = false;

  String? _lastUserCode;

  String _selectedClassLevel = 'ม.1';

  final List<String> _classLevels = ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'];



  List<String> _teachersWithTimetables = [];

  List<String> _allTeachers = [];

  // ตารางสอนรวม teacher roster (school_builtin_data for this school, the teachers in the database otherwise)
  List<Map<String, String>> _masterRoster = [];

  List<Map<String, dynamic>> _slots = [];



  bool get _canEditCurrentTimetable {

    final user = widget.apiService.currentUser;

    if (user == null || user.isGuest) return false;

    if (user.isAdmin) return true;

    if (_viewMode == 'teacher') {

      return user.canManageTimetable(_selectedTeacher);

    }

    return false;

  }



  final Map<int, String> _dayNames = {

    1: 'จันทร์',

    2: 'อังคาร',

    3: 'พุธ',

    4: 'พฤหัสบดี',

    5: 'ศุกร์',

  };



  final Map<int, Color> _dayColors = {

    1: const Color(0xFFFFF8E1), // Yellow tint for Monday

    2: const Color(0xFFFCE4EC), // Pink tint for Tuesday

    3: const Color(0xFFE8F5E9), // Green tint for Wednesday

    4: const Color(0xFFFFF3E0), // Orange tint for Thursday

    5: const Color(0xFFE3F2FD), // Blue tint for Friday

  };



  @override

  void initState() {

    super.initState();

    final def = widget.apiService.defaultSemester;

    if (def != null) {

      _selectedTerm = def.term;

      _selectedYear = def.year;

    }

    _syncDefaultTeacherWithCurrentUser();

    widget.apiService.currentUserNotifier.addListener(_onCurrentUserChanged);

    _initData();

    _loadHeaderCollapsed();

  }

  Future<void> _loadHeaderCollapsed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final header = prefs.getBool(_headerCollapsedPrefKey);
      final banner = prefs.getBool(_bannerCollapsedPrefKey);
      final panel = prefs.getBool(_checkPanelCollapsedPrefKey);
      if (!mounted) return;
      setState(() {
        if (header != null) _headerCollapsed = header;
        if (banner != null) _bannerCollapsed = banner;
        if (panel != null) _checkPanelCollapsed = panel;
      });
    } catch (_) {
      // no saved choice (private window, blocked storage): keep everything open
    }
  }

  Future<void> _saveFoldPref(String key, bool collapsed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, collapsed);
    } catch (_) {}
  }

  Future<void> _setHeaderCollapsed(bool collapsed) async {
    setState(() => _headerCollapsed = collapsed);
    await _saveFoldPref(_headerCollapsedPrefKey, collapsed);
  }

  Future<void> _setBannerCollapsed(bool collapsed) async {
    setState(() => _bannerCollapsed = collapsed);
    await _saveFoldPref(_bannerCollapsedPrefKey, collapsed);
  }

  Future<void> _setCheckPanelCollapsed(bool collapsed) async {
    setState(() => _checkPanelCollapsed = collapsed);
    await _saveFoldPref(_checkPanelCollapsedPrefKey, collapsed);
  }

  /// Small "ย่อ ⌃" / "แสดง ⌄" button shared by the foldable sections.
  Widget _foldButton({
    required bool collapsed,
    required VoidCallback onPressed,
    required Color color,
    required String tooltip,
    Key? key,
  }) {
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        key: key,
        onPressed: onPressed,
        icon: Icon(collapsed ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded, size: 20),
        label: Text(collapsed ? 'แสดง' : 'ย่อ', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        style: TextButton.styleFrom(
          foregroundColor: color,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
        ),
      ),
    );
  }

  /// One line that says what is on screen while the top bar is folded away.
  String _headerSummary() {
    final term = 'ภาคเรียนที่ $_selectedTerm/$_selectedYear';
    switch (_viewMode) {
      case 'teacher':
        return 'ตารางสอน $_selectedTeacher · $term';
      case 'class':
        return 'ตารางเรียน $_selectedClassLevel · $term';
      default:
        return 'ตารางสอนรวม · $term';
    }
  }

  Widget _buildCollapsedHeader() {
    const navy = Color(0xFF1A237E);
    return InkWell(
      key: const ValueKey('timetable-header-collapsed'),
      onTap: () => _setHeaderCollapsed(false),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          const Icon(Icons.calendar_month_rounded, color: navy, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _headerSummary(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: navy),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'แสดงแถบด้านบน (ภาคเรียน, เลือกตาราง, ปุ่ม Excel)',
            child: TextButton.icon(
              onPressed: () => _setHeaderCollapsed(false),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
              label: const Text('แสดงแถบ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              style: TextButton.styleFrom(
                foregroundColor: navy,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderCollapseButton() {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: 'ซ่อนแถบด้านบน ให้เห็นตารางได้มากขึ้น',
        child: TextButton.icon(
          onPressed: () => _setHeaderCollapsed(true),
          icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
          label: const Text('ซ่อน', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
            foregroundColor: Colors.black54,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ),
    );
  }



  @override

  void dispose() {

    widget.apiService.currentUserNotifier.removeListener(_onCurrentUserChanged);

    _masterHScrollController.dispose();

    super.dispose();

  }



  void _syncDefaultTeacherWithCurrentUser() {

    final user = widget.apiService.currentUser;

    _lastUserCode = user?.code;

    if (user != null && !user.isGuest && !user.isDirector && user.baseName.isNotEmpty) {

      _selectedTeacher = 'ครู${user.baseName}';

      _hasInitializedTeacherForUser = false;

    }

  }



  void _onCurrentUserChanged() {

    final user = widget.apiService.currentUser;

    if (user?.code != _lastUserCode) {

      _syncDefaultTeacherWithCurrentUser();

      if (mounted) {

        _loadTimetableData();

      }

    }

  }



  Future<void> _initData() async {

    setState(() => _loading = true);

    try {

      final sems = await widget.apiService.getSemesterConfigs();

      if (sems.isNotEmpty) {

        _semesters = sems;

        final marked = sems.where((s) => s.isDefault).toList();

        if (marked.isNotEmpty) {

          _selectedTerm = marked.first.term;

          _selectedYear = marked.first.year;

        } else {

          final sem1_69 = sems.where((s) => s.term == '1' && s.year == '2569').toList();

          if (sem1_69.isNotEmpty) {

            _selectedTerm = '1';

            _selectedYear = '2569';

          } else {

            _selectedTerm = sems.first.term;

            _selectedYear = sems.first.year;

          }

        }

      }

      await _loadTimetableData();

    } catch (e) {

      if (mounted) {

        setState(() => _loading = false);

      }

    }

  }



  Future<void> _loadTimetableData() async {

    setState(() => _loading = true);

    try {

      String requestedTeacher = _selectedTeacher;

      final res = await widget.apiService.getTimetables(

        term: _selectedTerm,

        year: _selectedYear,

        teacherName: _viewMode == 'teacher' ? requestedTeacher : null,

        classLevel: _viewMode == 'class' ? _selectedClassLevel : null,

      );



      var roster = _masterRoster;
      try {
        roster = await widget.apiService.getMasterRoster(_selectedTerm, _selectedYear);
      } catch (_) {}

      final ttTeachers = List<String>.from(res['teachers_with_timetables'] ?? []);

      final schoolTeachers = List<String>.from(res['all_teachers'] ?? []);

      var slots = List<Map<String, dynamic>>.from(res['data'] ?? []);



      // Merge teacher list so teachers with timetables appear at the top

      final combinedTeachers = <String>[...ttTeachers];

      for (final st in schoolTeachers) {

        final cleanSt = st.replaceAll('นางสาว', '').replaceAll('นาย', '').replaceAll('นาง', '').trim();

        final alreadyExists = combinedTeachers.any((t) => t.contains(cleanSt));

        if (!alreadyExists) {

          combinedTeachers.add(st);

        }

      }



      String resolvedTeacher = _selectedTeacher;

      if (_viewMode == 'teacher' && combinedTeachers.isNotEmpty) {

        final user = widget.apiService.currentUser;

        if (!_hasInitializedTeacherForUser && user != null && !user.isGuest && !user.isDirector) {

          final myT = combinedTeachers.where((t) => user.canManageTimetable(t)).toList();

          if (myT.isNotEmpty) {

            resolvedTeacher = myT.first;

          }

          _hasInitializedTeacherForUser = true;

        }

        if (!combinedTeachers.contains(resolvedTeacher)) {

          final normTarget = LoggedInTeacher.normalize(resolvedTeacher);

          final matched = combinedTeachers.where((t) => LoggedInTeacher.normalize(t) == normTarget).toList();

          if (matched.isNotEmpty) {

            resolvedTeacher = matched.first;

          } else {

            resolvedTeacher = combinedTeachers.first;

          }

        }



        // If resolvedTeacher differs from what we just queried, fetch the exact slots for resolvedTeacher

        if (LoggedInTeacher.normalize(resolvedTeacher) != LoggedInTeacher.normalize(requestedTeacher)) {

          final retryRes = await widget.apiService.getTimetables(

            term: _selectedTerm,

            year: _selectedYear,

            teacherName: resolvedTeacher,

            classLevel: null,

          );

          slots = List<Map<String, dynamic>>.from(retryRes['data'] ?? []);

        }

      }



      if (mounted) {

        setState(() {

          _teachersWithTimetables = ttTeachers;

          _masterRoster = roster;

          _allTeachers = combinedTeachers;

          if (_viewMode == 'teacher') {

            _selectedTeacher = resolvedTeacher;

          }

          _slots = slots;

          _loading = false;

        });

      }

    } catch (e) {

      if (mounted) {

        setState(() => _loading = false);

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(content: Text('เกิดข้อผิดพลาด: $e'), backgroundColor: Colors.red),

        );

      }

    }

  }



  Map<String, dynamic>? _getSlot(int dayOfWeek, int periodNum) {

    Map<String, dynamic>? match;

    for (final s in _slots) {

      if (s['day_of_week'] == dayOfWeek && s['period_num'] == periodNum) {

        if (s['course_code'] == 'ลูกเสือ') {

          // Priority to Teacher Samarn as requested by user

          if (s['teacher_name'].toString().contains('สมาน')) {

            return s;

          }

          match ??= s;

        } else {

          return s;

        }

      }

    }

    return match;

  }



  String _inferClassLevelFromCourseCode(String code) {

    final clean = code.trim();

    if (clean == 'ลูกเสือ') return 'ม.1, ม.2, ม.3';

    if (clean == 'Personal Learning' || clean == 'ชุมนุม' || clean == 'คุณธรรม จริยธรรม') {

      return 'ม.1, ม.2, ม.3, ม.4, ม.5, ม.6';

    }

    if (clean.length < 3) return '';

    // Check 1st and 2nd digit after prefix letter(s)

    final match = RegExp(r'^[ก-ฮA-Za-z](\d)(\d)').firstMatch(clean);

    if (match != null) {

      final stage = match.group(1);

      final grade = match.group(2);

      if (stage == '2') {

        if (grade == '1') return 'ม.1';

        if (grade == '2') return 'ม.2';

        if (grade == '3') return 'ม.3';

      } else if (stage == '3') {

        if (grade == '1') return 'ม.4';

        if (grade == '2') return 'ม.5';

        if (grade == '3') return 'ม.6';

      }

    }

    return '';

  }



  void _snackTimetable(String msg, {bool error = false}) {

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(

      SnackBar(content: Text(msg), backgroundColor: error ? Colors.red.shade700 : Colors.green.shade800),

    );

  }



  Future<bool> _confirmTimetableClash(String message, String okLabel) async {

    final ok = await showDialog<bool>(

      context: context,

      builder: (c) => AlertDialog(

        title: const Text('เวลานี้มีคาบชนอยู่'),

        content: Text(message),

        actions: [

          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),

          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(okLabel)),

        ],

      ),

    );

    return ok == true;

  }



  /// บันทึกคาบ (และคาบที่สองถ้าเป็นคาบคู่) ส่ง force ต่อไปทั้งสองคาบเมื่อผู้ใช้ยืนยันแล้ว

  Future<void> _saveSlotPair({

    required String teacherName,

    required int dayOfWeek,

    required int periodNum,

    required bool isDoubleSpan,

    required String code,

    required String name,

    required String classLevel,

    required String room,

    required String note,

    required bool force,

  }) async {

    Map<String, dynamic> body(int p) => {

          'term': _selectedTerm,

          'year': _selectedYear,

          'teacher_name': teacherName,

          'day_of_week': dayOfWeek,

          'period_num': p,

          'period_span': isDoubleSpan ? 2 : 1,

          'course_code': code,

          'course_name': name,

          'class_level': classLevel,

          'room': room,

          'note': note,

          'force': force,

        };

    await widget.apiService.upsertTimetableSlot(body(periodNum));

    if (isDoubleSpan && periodNum < 8) {

      await widget.apiService.upsertTimetableSlot(body(periodNum + 1));

    }

  }



  /// ย้ายคาบนี้: เลือกวัน/คาบใหม่ ถ้าครูมีคาบชนจะไม่ให้ย้าย ถ้าชั้นนั้นมีคาบของครูอื่นจะถามยืนยันก่อน

  Future<bool> _moveSlot(Map<String, dynamic> slot, String code, int fromDay, int fromPeriod) async {

    int newDay = fromDay;

    int newPeriod = fromPeriod;

    final ok = await showDialog<bool>(

      context: context,

      builder: (c) => StatefulBuilder(

        builder: (c, setMove) => AlertDialog(

          title: Text('ย้ายคาบ $code'),

          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [

            Text('จาก วัน${_dayNames[fromDay]} คาบ $fromPeriod', style: TextStyle(color: Colors.grey.shade700)),

            const SizedBox(height: 12),

            Row(children: [

              Expanded(

                child: DropdownButtonFormField<int>(

                  initialValue: newDay,

                  decoration: const InputDecoration(labelText: 'ย้ายไปวัน', border: OutlineInputBorder(), isDense: true),

                  items: [for (var d = 1; d <= 5; d++) DropdownMenuItem(value: d, child: Text('วัน${_dayNames[d]}'))],

                  onChanged: (v) => setMove(() => newDay = v ?? newDay),

                ),

              ),

              const SizedBox(width: 12),

              Expanded(

                child: DropdownButtonFormField<int>(

                  initialValue: newPeriod,

                  decoration: const InputDecoration(labelText: 'คาบที่', border: OutlineInputBorder(), isDense: true),

                  items: [for (var p = 1; p <= 8; p++) DropdownMenuItem(value: p, child: Text('คาบ $p'))],

                  onChanged: (v) => setMove(() => newPeriod = v ?? newPeriod),

                ),

              ),

            ]),

            const SizedBox(height: 10),

            const Text('ตารางใหม่มีผลทั้งภาคเรียน ระบบปรับตารางเรียนของนักเรียน เวลาเรียน และ ปพ.5 ให้เอง',

                style: TextStyle(fontSize: 12)),

          ]),

          actions: [

            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),

            FilledButton.icon(

              icon: const Icon(Icons.open_with_rounded),

              label: const Text('ย้าย'),

              onPressed: () => Navigator.pop(c, true),

            ),

          ],

        ),

      ),

    );

    if (ok != true) return false;

    bool force = false;

    while (true) {

      try {

        final r = await widget.apiService.moveTimetableSlot(slot['id'] as int, dayOfWeek: newDay, periodNum: newPeriod, force: force);

        _snackTimetable('${r['message'] ?? 'ย้ายคาบแล้ว'}');

        break;

      } on TimetableClashException catch (e) {

        if (!e.needsConfirm || force) {

          _snackTimetable(e.message, error: true);

          return false;

        }

        if (!await _confirmTimetableClash(e.message, 'รวมเป็นคาบสอนรวม')) return false;

        force = true;

      } catch (e) {

        _snackTimetable(e.toString().replaceFirst('Exception: ', ''), error: true);

        return false;

      }

    }

    await _loadTimetableData();

    return true;

  }



  Future<void> _openEditSlotDialog({

    required int dayOfWeek,

    required int periodNum,

    Map<String, dynamic>? existingSlot,

  }) async {

    final teacherCtrl = TextEditingController(

      text: existingSlot?['teacher_name'] ??

          (_viewMode == 'teacher' ? _selectedTeacher : (_allTeachers.isNotEmpty ? _allTeachers.first : '')),

    );

    final codeCtrl = TextEditingController(text: existingSlot?['course_code'] ?? '');

    final nameCtrl = TextEditingController(text: existingSlot?['course_name'] ?? '');

    String classLevel = existingSlot?['class_level'] ?? (_viewMode == 'class' ? _selectedClassLevel : '');

    final roomCtrl = TextEditingController(text: existingSlot?['room'] ?? '');

    final noteCtrl = TextEditingController(text: existingSlot?['note'] ?? '');

    bool isDoubleSpan = (existingSlot?['period_span'] ?? 1) == 2;

    bool filterOnlyTeacherCourses = true;



    List<Map<String, dynamic>> teacherCourses = [];

    List<Map<String, dynamic>> catalogCourses = [];

    bool loadingCourses = true;

    // สอนรวมหลายชั้นในคาบเดียว เช่น ม.4 ค31102 + ม.5 ค32102 เก็บเป็นรหัส "ค31102, ค32102" กับชั้น "ม.4, ม.5" เรียงคู่กัน

    bool combineMode = false;

    final List<Map<String, String>> combo = [];

    final existingCodes = (existingSlot?['course_code'] ?? '').toString().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    final existingLevels = (existingSlot?['class_level'] ?? '').toString().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    if (existingCodes.length > 1 && existingCodes.length == existingLevels.length) {

      final names = (existingSlot?['course_name'] ?? '').toString().split(' / ');

      combineMode = true;

      for (var i = 0; i < existingCodes.length; i++) {

        combo.add({'code': existingCodes[i], 'name': i < names.length ? names[i].trim() : '', 'level': existingLevels[i]});

      }

    }

    void applyCombo() {

      codeCtrl.text = combo.map((c) => c['code']).join(', ');

      nameCtrl.text = combo.map((c) => c['name']).join(' / ');

      classLevel = combo.map((c) => c['level']).join(', ');

    }



    Future<void> fetchCoursesForTeacher(String tName, StateSetter setDialogState) async {

      setDialogState(() => loadingCourses = true);

      try {

        final res = await widget.apiService.getTeacherCoursesForTimetable(

          term: _selectedTerm,

          year: _selectedYear,

          teacherName: tName,

        );

        setDialogState(() {

          teacherCourses = List<Map<String, dynamic>>.from(res['teacher_courses'] ?? []);

          catalogCourses = List<Map<String, dynamic>>.from(res['catalog_courses'] ?? []);

          loadingCourses = false;

        });

      } catch (_) {

        setDialogState(() => loadingCourses = false);

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

              fetchCoursesForTeacher(teacherCtrl.text, setDialogState);

            }



            final displayedCourses = (filterOnlyTeacherCourses && teacherCourses.isNotEmpty)

                ? teacherCourses

                : catalogCourses;



            final quickActivities = [

              {'code': 'Personal Learning', 'name': 'Personal Learning'},

              {'code': 'ชุมนุม', 'name': 'กิจกรรมชุมนุม'},

              {'code': 'PLC ครู', 'name': 'PLC ครู'},

              {'code': 'ลูกเสือ', 'name': 'กิจกรรมลูกเสือ-เนตรนารี'},

              {'code': 'แนะแนว', 'name': 'แนะแนว'},

              {'code': 'มวยไทย', 'name': 'มวยไทย'},

              {'code': 'คุณธรรม จริยธรรม', 'name': 'คุณธรรม จริยธรรม'},

            ];



            return AlertDialog(

              title: Row(

                children: [

                  const Icon(Icons.edit_calendar_rounded, color: Color(0xFF1A237E)),

                  const SizedBox(width: 10),

                  Expanded(

                    child: Text(

                      'จัดการคาบสอน: วัน${_dayNames[dayOfWeek]} — คาบที่ $periodNum',

                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),

                    ),

                  ),

                ],

              ),

              content: SizedBox(

                width: 560,

                child: SingleChildScrollView(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    mainAxisSize: MainAxisSize.min,

                    children: [

                      // Teacher selector

                      Row(

                        children: [

                          Expanded(

                            child: DropdownButtonFormField<String>(

                              value: _allTeachers.contains(teacherCtrl.text) ? teacherCtrl.text : null,

                              decoration: const InputDecoration(

                                labelText: 'ครูผู้สอน',

                                border: OutlineInputBorder(),

                                isDense: true,

                                prefixIcon: Icon(Icons.person_outline),

                              ),

                              items: _allTeachers

                                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))

                                  .toList(),

                              onChanged: (val) {

                                if (val != null) {

                                  teacherCtrl.text = val;

                                  fetchCoursesForTeacher(val, setDialogState);

                                }

                              },

                            ),

                          ),

                          const SizedBox(width: 8),

                          IconButton(

                            tooltip: 'พิมพ์ชื่อครูใหม่',

                            icon: const Icon(Icons.person_add_alt_1_outlined),

                            onPressed: () async {

                              final newNameCtrl = TextEditingController(text: teacherCtrl.text);

                              final added = await showDialog<String>(

                                context: context,

                                builder: (c2) => AlertDialog(

                                  title: const Text('ระบุชื่อครูผู้สอน'),

                                  content: TextField(

                                    controller: newNameCtrl,

                                    decoration: const InputDecoration(

                                      labelText: 'ชื่อ-สกุล ครูผู้สอน',

                                      hintText: 'เช่น ครูสมชาย ใจดี',

                                      border: OutlineInputBorder(),

                                    ),

                                  ),

                                  actions: [

                                    TextButton(onPressed: () => Navigator.pop(c2), child: const Text('ยกเลิก')),

                                    FilledButton(

                                      onPressed: () => Navigator.pop(c2, newNameCtrl.text.trim()),

                                      child: const Text('ตกลง'),

                                    ),

                                  ],

                                ),

                              );

                              if (added != null && added.isNotEmpty) {

                                setDialogState(() {

                                  if (!_allTeachers.contains(added)) {

                                    _allTeachers.insert(0, added);

                                  }

                                  teacherCtrl.text = added;

                                });

                                fetchCoursesForTeacher(added, setDialogState);

                              }

                            },

                          ),

                        ],

                      ),

                      const SizedBox(height: 14),



                      // Filter courses by teacher checkbox

                      Container(

                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                        decoration: BoxDecoration(

                          color: const Color(0xFFE8EAF6),

                          borderRadius: BorderRadius.circular(8),

                        ),

                        child: Column(

                          crossAxisAlignment: CrossAxisAlignment.start,

                          children: [

                            Row(

                              children: [

                                const Icon(Icons.filter_list_rounded, size: 18, color: Color(0xFF1A237E)),

                                const SizedBox(width: 6),

                                const Expanded(

                                  child: Text(

                                    'เลือกรายวิชาจากฐานข้อมูล:',

                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),

                                  ),

                                ),

                                FilterChip(

                                  label: Text(

                                    'เฉพาะวิชาที่ครูสอน (${teacherCourses.length})',

                                    style: const TextStyle(fontSize: 12),

                                  ),

                                  selected: filterOnlyTeacherCourses,

                                  onSelected: (v) => setDialogState(() => filterOnlyTeacherCourses = v),

                                ),

                                const SizedBox(width: 6),

                                Tooltip(

                                  message: 'เปิดแล้วกดเลือกได้หลายวิชา เช่น ม.4 กับ ม.5 มาเรียนพร้อมกันในคาบนี้',

                                  child: FilterChip(

                                    avatar: const Icon(Icons.merge_type_rounded, size: 16),

                                    label: const Text('สอนรวมหลายชั้น', style: TextStyle(fontSize: 12)),

                                    selected: combineMode,

                                    onSelected: (v) => setDialogState(() {

                                      combineMode = v;

                                      if (v && combo.isEmpty && codeCtrl.text.trim().isNotEmpty && !codeCtrl.text.contains(',')) {

                                        combo.add({'code': codeCtrl.text.trim(), 'name': nameCtrl.text.trim(), 'level': classLevel});

                                      }

                                      if (!v && combo.isNotEmpty) {

                                        final first = combo.first;

                                        combo.clear();

                                        codeCtrl.text = first['code'] ?? '';

                                        nameCtrl.text = first['name'] ?? '';

                                        classLevel = first['level'] ?? '';

                                      }

                                    }),

                                  ),

                                ),

                              ],

                            ),

                            const SizedBox(height: 8),

                            if (loadingCourses)

                              const LinearProgressIndicator()

                            else if (displayedCourses.isEmpty)

                              const Text(

                                'ไม่พบวิชาที่ครูสอนในระบบ — กรุณากดปุ่มด้านขวาเพื่อเลือกจากคลังวิชามาตรฐานทั้งหมด หรือพิมพ์รหัสวิชาด้านล่าง',

                                style: TextStyle(fontSize: 12, color: Colors.black54),

                              )

                            else

                              Wrap(

                                spacing: 6,

                                runSpacing: 6,

                                children: displayedCourses.take(24).map((c) {

                                  final cCode = (c['course_code'] ?? '').toString();

                                  final cName = (c['course_name'] ?? '').toString();

                                  final cLvl = (c['class_level'] ?? '').toString().isNotEmpty

                                      ? c['class_level'].toString()

                                      : _inferClassLevelFromCourseCode(cCode);

                                  final isSelected = combineMode ? combo.any((x) => x['code'] == cCode) : codeCtrl.text == cCode;

                                  return ActionChip(

                                    backgroundColor: isSelected ? const Color(0xFF1A237E) : Colors.white,

                                    label: Text(

                                      '$cCode $cName ${cLvl.isNotEmpty ? "($cLvl)" : ""}',

                                      style: TextStyle(

                                        fontSize: 12,

                                        color: isSelected ? Colors.white : Colors.black87,

                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,

                                      ),

                                    ),

                                    onPressed: () {

                                      setDialogState(() {

                                        if (combineMode) {

                                          final at = combo.indexWhere((x) => x['code'] == cCode);

                                          if (at >= 0) {

                                            combo.removeAt(at);

                                          } else {

                                            combo.add({'code': cCode, 'name': cName, 'level': cLvl});

                                          }

                                          applyCombo();

                                          return;

                                        }

                                        codeCtrl.text = cCode;

                                        nameCtrl.text = cName;

                                        if (cLvl.isNotEmpty) {

                                          classLevel = cLvl;

                                        }

                                      });

                                    },

                                  );

                                }).toList(),

                              ),

                          ],

                        ),

                      ),

                      const SizedBox(height: 10),



                      // Quick Activity Chips

                      const Text(

                        'หรือเลือกกิจกรรมพัฒนาผู้เรียน / กิจกรรมโรงเรียน:',

                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black54),

                      ),

                      const SizedBox(height: 6),

                      Wrap(

                        spacing: 6,

                        runSpacing: 6,

                        children: quickActivities.map((act) {

                          final isSel = codeCtrl.text == act['code'];

                          return ActionChip(

                            visualDensity: VisualDensity.compact,

                            backgroundColor: isSel ? Colors.teal.shade700 : Colors.teal.shade50,

                            label: Text(

                              act['code']!,

                              style: TextStyle(

                                fontSize: 11,

                                color: isSel ? Colors.white : Colors.teal.shade900,

                              ),

                            ),

                            onPressed: () {

                              setDialogState(() {

                                codeCtrl.text = act['code']!;

                                nameCtrl.text = act['name']!;

                                if (act['code'] == 'ลูกเสือ') {

                                  classLevel = 'ม.1, ม.2, ม.3';

                                } else if (act['code'] == 'Personal Learning' ||

                                    act['code'] == 'ชุมนุม' ||

                                    act['code'] == 'คุณธรรม จริยธรรม') {

                                  classLevel = 'ม.1, ม.2, ม.3, ม.4, ม.5, ม.6';

                                }

                              });

                            },

                          );

                        }).toList(),

                      ),

                      const SizedBox(height: 14),



                      // Course Code & Course Name fields

                      Row(

                        children: [

                          Expanded(

                            flex: 2,

                            child: TextField(

                              controller: codeCtrl,

                              decoration: const InputDecoration(

                                labelText: 'รหัสวิชา / กิจกรรม *',

                                hintText: 'เช่น ท23101',

                                border: OutlineInputBorder(),

                                isDense: true,

                              ),

                              onChanged: (val) {

                                final inferredLvl = _inferClassLevelFromCourseCode(val);

                                // Look up in catalogCourses

                                final matched = catalogCourses

                                    .where((c) => c['course_code'].toString().toUpperCase() == val.trim().toUpperCase())

                                    .toList();

                                setDialogState(() {

                                  if (inferredLvl.isNotEmpty) {

                                    classLevel = inferredLvl;

                                  }

                                  if (matched.isNotEmpty) {

                                    nameCtrl.text = matched.first['course_name']?.toString() ?? '';

                                  }

                                });

                              },

                            ),

                          ),

                          const SizedBox(width: 10),

                          Expanded(

                            flex: 3,

                            child: TextField(

                              controller: nameCtrl,

                              decoration: const InputDecoration(

                                labelText: 'ชื่อรายวิชา',

                                hintText: 'เช่น ภาษาไทย 5',

                                border: OutlineInputBorder(),

                                isDense: true,

                              ),

                            ),

                          ),

                        ],

                      ),

                      const SizedBox(height: 14),



                      // Class Level & Period Span

                      Row(

                        children: [

                          if (combineMode && combo.length > 1)

                            Expanded(

                              child: Container(

                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),

                                decoration: BoxDecoration(

                                  color: const Color(0xFFEEF2FF),

                                  borderRadius: BorderRadius.circular(6),

                                  border: Border.all(color: const Color(0xFF6366F1)),

                                ),

                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

                                  Text('สอนรวม ${combo.length} ชั้นในคาบนี้', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),

                                  for (final c in combo)

                                    Text('${c['code']} ${c['name']} (${c['level']})', style: const TextStyle(fontSize: 12)),

                                ]),

                              ),

                            )

                          else

                          Expanded(

                            child: DropdownButtonFormField<String>(

                              value: _classLevels.contains(classLevel) ? classLevel : '',

                              decoration: const InputDecoration(

                                labelText: 'ชั้นเรียนที่สอน (ม.1 - ม.6)',

                                border: OutlineInputBorder(),

                                isDense: true,

                              ),

                              items: [

                                const DropdownMenuItem(value: '', child: Text('— ไม่ระบุชั้น / กิจกรรมรวม —')),

                                ..._classLevels.map((lvl) => DropdownMenuItem(value: lvl, child: Text('ชั้น $lvl'))),

                              ],

                              onChanged: (val) {

                                setDialogState(() => classLevel = val ?? '');

                              },

                            ),

                          ),

                          const SizedBox(width: 12),

                          Expanded(

                            child: CheckboxListTile(

                              contentPadding: EdgeInsets.zero,

                              dense: true,

                              title: const Text('คาบคู่ (2 คาบติดกัน)', style: TextStyle(fontSize: 13)),

                              subtitle: Text('คาบ $periodNum - ${periodNum + 1}', style: const TextStyle(fontSize: 11)),

                              value: isDoubleSpan,

                              onChanged: periodNum < 8

                                  ? (v) => setDialogState(() => isDoubleSpan = v ?? false)

                                  : null,

                            ),

                          ),

                        ],

                      ),

                    ],

                  ),

                ),

              ),

              actions: [

                if (existingSlot != null && existingSlot['id'] != null)

                  TextButton.icon(

                    icon: const Icon(Icons.open_with_rounded),

                    label: const Text('ย้ายคาบนี้'),

                    onPressed: () async {

                      final moved = await _moveSlot(existingSlot, codeCtrl.text.trim(), dayOfWeek, periodNum);

                      if (moved && ctx.mounted) Navigator.pop(ctx);

                    },

                  ),

                if (existingSlot != null && existingSlot['id'] != null)

                  TextButton.icon(

                    style: TextButton.styleFrom(foregroundColor: Colors.red),

                    icon: const Icon(Icons.delete_outline),

                    label: const Text('ลบคาบนี้'),

                    onPressed: () async {

                      try {

                        await widget.apiService.deleteTimetableSlot(existingSlot['id'] as int);

                        if (ctx.mounted) Navigator.pop(ctx);

                        _snackTimetable('ลบคาบสอนแล้ว ระบบปรับตารางเรียน เวลาเรียน และ ปพ.5 ให้แล้ว');

                      } catch (e) {

                        _snackTimetable(e.toString().replaceFirst('Exception: ', ''), error: true);

                      }

                      await _loadTimetableData();

                    },

                  ),

                TextButton(

                  onPressed: () => Navigator.pop(ctx),

                  child: const Text('ยกเลิก'),

                ),

                FilledButton.icon(

                  icon: const Icon(Icons.save_rounded),

                  label: const Text('บันทึกคาบสอน'),

                  onPressed: () async {

                    final code = codeCtrl.text.trim();

                    final tName = teacherCtrl.text.trim();

                    if (code.isEmpty || tName.isEmpty) {

                      ScaffoldMessenger.of(context).showSnackBar(

                        const SnackBar(content: Text('กรุณาระบุชื่อครูและรหัสวิชา')),

                      );

                      return;

                    }

                    if (combineMode && combo.length == 1) {

                      applyCombo();

                    }

                    bool force = false;

                    try {

                      while (true) {

                        try {

                          await _saveSlotPair(

                            teacherName: tName,

                            dayOfWeek: dayOfWeek,

                            periodNum: periodNum,

                            isDoubleSpan: isDoubleSpan,

                            code: codeCtrl.text.trim(),

                            name: nameCtrl.text.trim(),

                            classLevel: classLevel,

                            room: roomCtrl.text.trim(),

                            note: noteCtrl.text.trim(),

                            force: force,

                          );

                          break;

                        } on TimetableClashException catch (e) {

                          if (!e.needsConfirm || force) rethrow;

                          if (!await _confirmTimetableClash(e.message, 'ยืนยันบันทึก')) return;

                          force = true;

                        }

                      }

                    } catch (e) {

                      _snackTimetable(e.toString().replaceFirst('Exception: ', ''), error: true);

                      return;

                    }

                    if (ctx.mounted) Navigator.pop(ctx);

                    _snackTimetable('บันทึกคาบสอนแล้ว ระบบปรับตารางเรียน เวลาเรียน และ ปพ.5 ให้แล้ว');

                    await _loadTimetableData();

                  },

                ),

              ],

            );

          },

        );

      },

    );

  }



  Future<void> _handleUploadTimetable() async {

    try {

      final pickedFiles = await FilePicker.pickFiles(

        dialogTitle: 'เลือกไฟล์ตารางสอนครู (.xlsx)',

        type: FileType.custom,

        allowedExtensions: ['xlsx', 'xls'],

      );

      if (pickedFiles.isEmpty) return;



      final file = pickedFiles.first;

      final bytes = await file.readAsBytes();



      setState(() => _loading = true);

      final res = await widget.apiService.uploadTimetableFile(

        bytes: bytes,

        filename: file.name,

        term: _selectedTerm,

        year: _selectedYear,

        teacherName: _viewMode == 'teacher' ? _selectedTeacher : null,

      );



      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            content: Text(res['message'] ?? 'นำเข้าตารางสอนสำเร็จ'),

            backgroundColor: Colors.green.shade700,

          ),

        );

      }

      await _loadTimetableData();

    } catch (e) {

      if (mounted) {

        setState(() => _loading = false);

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(content: Text('อัพโหลดไม่สำเร็จ: $e'), backgroundColor: Colors.red),

        );

      }

    }

  }



  Future<void> _handleDownloadTemplate() async {

    final url = widget.apiService.getTimetableTemplateUrl(

      term: _selectedTerm,

      year: _selectedYear,

      teacherName: _viewMode == 'teacher' ? _selectedTeacher : null,

      classLevel: _viewMode == 'class' ? _selectedClassLevel : null,

    );

    final uri = Uri.parse(url);

    await launchUrl(uri, mode: LaunchMode.externalApplication);

  }



  Future<void> _handleSyncArchive() async {

    setState(() => _loading = true);

    try {

      final res = await widget.apiService.syncTimetablesToArchive(

        term: _selectedTerm,

        year: _selectedYear,

      );

      if (mounted) {

        final count = res['synced_courses_count'] ?? 0;

        final enrolled = res['total_students_enrolled'] ?? 0;

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            content: Text('เชื่อมโยงรายวิชาเข้าคลังข้อมูลสำเร็จ $count รายวิชา (ลงทะเบียนนักเรียน $enrolled รายการ)'),

            backgroundColor: Colors.green.shade700,

          ),

        );

      }

      await _loadTimetableData();

    } catch (e) {

      if (mounted) {

        setState(() => _loading = false);

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(content: Text('เกิดข้อผิดพลาดในการเชื่อมโยง: $e'), backgroundColor: Colors.red),

        );

      }

    }

  }



  @override

  Widget build(BuildContext context) {

    final theme = Theme.of(context);



    return Scaffold(

      backgroundColor: AppColors.background,

      body: Column(

        crossAxisAlignment: CrossAxisAlignment.stretch,

        children: [

          // Top Header & Controls Bar (foldable: see _headerCollapsed)

          Container(

            padding: _headerCollapsed
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
                : const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

            decoration: BoxDecoration(

              color: Colors.white,

              boxShadow: [

                BoxShadow(

                  color: Colors.black.withValues(alpha: 0.05),

                  blurRadius: 6,

                  offset: const Offset(0, 2),

                ),

              ],

            ),

            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _headerCollapsed
                  ? _buildCollapsedHeader()
                  : Row(
              key: const ValueKey('timetable-header-open'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Expanded(
            child: Wrap(

              spacing: 12,

              runSpacing: 10,

              crossAxisAlignment: WrapCrossAlignment.center,

              alignment: WrapAlignment.spaceBetween,

              children: [

                // Title & Subtitle

                Row(

                  mainAxisSize: MainAxisSize.min,

                  children: [

                    Container(

                      padding: const EdgeInsets.all(10),

                      decoration: BoxDecoration(

                        color: const Color(0xFF1A237E).withValues(alpha: 0.1),

                        borderRadius: BorderRadius.circular(10),

                      ),

                      child: const Icon(Icons.calendar_month_rounded, color: Color(0xFF1A237E), size: 26),

                    ),

                    const SizedBox(width: 12),

                    // Flexible: on a phone the title wraps instead of running under the "ซ่อน" button
                    Flexible(
                    child: Column(

                      crossAxisAlignment: CrossAxisAlignment.start,

                      children: [

                        Text(

                          'ตารางสอนครู & ตารางเรียนรายคาบ',

                          style: theme.textTheme.titleMedium?.copyWith(

                            fontWeight: FontWeight.bold,

                            color: const Color(0xFF1A237E),

                          ),

                        ),

                        const Text(

                          'เชื่อมรหัสวิชามาตรฐาน, ระบบเช็คชื่อมาสายรายคาบ และไฟล์ Excel ปพ.5 อัตโนมัติ',

                          style: TextStyle(fontSize: 12, color: Colors.black54),

                        ),

                      ],

                    ),
                    ),

                  ],

                ),



                // Controls: Semester, View Mode, Teacher/Class Selector, Upload/Download

                Wrap(

                  spacing: 10,

                  runSpacing: 8,

                  crossAxisAlignment: WrapCrossAlignment.center,

                  children: [

                    // Semester Dropdown

                    if (_semesters.isNotEmpty)

                      Container(

                        padding: const EdgeInsets.symmetric(horizontal: 10),

                        decoration: BoxDecoration(

                          border: Border.all(color: Colors.grey.shade300),

                          borderRadius: BorderRadius.circular(8),

                          color: Colors.grey.shade50,

                        ),

                        child: DropdownButtonHideUnderline(

                          child: DropdownButton<String>(

                            value: '$_selectedTerm/$_selectedYear',

                            isDense: true,

                            items: _semesters.map((s) {

                              final key = '${s.term}/${s.year}';

                              return DropdownMenuItem(

                                value: key,

                                child: Text(

                                  'ภาคเรียนที่ ${s.term}/${s.year}',

                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),

                                ),

                              );

                            }).toList(),

                            onChanged: (val) {

                              if (val != null) {

                                final parts = val.split('/');

                                setState(() {

                                  _selectedTerm = parts[0];

                                  _selectedYear = parts[1];

                                });

                                _loadTimetableData();

                              }

                            },

                          ),

                        ),

                      ),



                    // Mode Segmented Button

                    SegmentedButton<String>(

                      segments: const [

                        ButtonSegment(

                          value: 'teacher',

                          icon: Icon(Icons.person_search_rounded, size: 16),

                          label: Text('ตารางสอนครู', style: TextStyle(fontSize: 12)),

                        ),

                        ButtonSegment(

                          value: 'class',

                          icon: Icon(Icons.groups_rounded, size: 16),

                          label: Text('ตารางเรียนชั้น ม.1-6', style: TextStyle(fontSize: 12)),

                        ),

                        ButtonSegment(

                          value: 'master',

                          icon: Icon(Icons.table_chart_rounded, size: 16),

                          label: Text('ตารางสอนรวม', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),

                        ),

                      ],

                      selected: {_viewMode},

                      onSelectionChanged: (s) {

                        setState(() => _viewMode = s.first);

                        _loadTimetableData();

                      },

                      style: const ButtonStyle(visualDensity: VisualDensity.compact),

                    ),



                    // Teacher Selector or Class Selector

                    if (_viewMode == 'teacher')

                      Container(

                        padding: const EdgeInsets.symmetric(horizontal: 10),

                        decoration: BoxDecoration(

                          border: Border.all(color: const Color(0xFF1A237E).withValues(alpha: 0.4)),

                          borderRadius: BorderRadius.circular(8),

                          color: const Color(0xFFE8EAF6),

                        ),

                        child: DropdownButtonHideUnderline(

                          child: DropdownButton<String>(

                            value: _allTeachers.contains(_selectedTeacher)

                                ? _selectedTeacher

                                : (_allTeachers.isNotEmpty ? _allTeachers.first : null),

                            isDense: true,

                            hint: const Text('เลือกครูผู้สอน'),

                            items: _allTeachers.map((t) {

                              final hasData = _teachersWithTimetables.contains(t);

                              return DropdownMenuItem(

                                value: t,

                                child: Row(

                                  mainAxisSize: MainAxisSize.min,

                                  children: [

                                    Icon(

                                      hasData ? Icons.check_circle_rounded : Icons.person_outline,

                                      size: 15,

                                      color: hasData ? Colors.green.shade700 : Colors.grey,

                                    ),

                                    const SizedBox(width: 6),

                                    Text(

                                      t,

                                      style: TextStyle(

                                        fontSize: 13,

                                        fontWeight: hasData ? FontWeight.bold : FontWeight.normal,

                                      ),

                                    ),

                                  ],

                                ),

                              );

                            }).toList(),

                            onChanged: (val) {

                              if (val != null) {

                                setState(() => _selectedTeacher = val);

                                _loadTimetableData();

                              }

                            },

                          ),

                        ),

                      ),

                    // Permission indicator badge

                    Container(

                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),

                      decoration: BoxDecoration(

                        color: _canEditCurrentTimetable ? const Color(0xFFE8F5E9) : const Color(0xFFFFF8E1),

                        borderRadius: BorderRadius.circular(8),

                        border: Border.all(

                          color: _canEditCurrentTimetable ? const Color(0xFFA5D6A7) : const Color(0xFFFFE082),

                        ),

                      ),

                      child: Row(

                        mainAxisSize: MainAxisSize.min,

                        children: [

                          Icon(

                            _canEditCurrentTimetable ? Icons.edit_calendar_rounded : Icons.lock_outline_rounded,

                            size: 14,

                            color: _canEditCurrentTimetable ? const Color(0xFF2E7D32) : const Color(0xFFF57F17),

                          ),

                          const SizedBox(width: 5),

                          Text(

                            _canEditCurrentTimetable ? 'แก้ไขได้ (ตารางสอนของท่าน)' : 'ดูอย่างเดียว (แก้ไขไม่ได้)',

                            style: TextStyle(

                              fontSize: 12,

                              fontWeight: FontWeight.bold,

                              color: _canEditCurrentTimetable ? const Color(0xFF2E7D32) : const Color(0xFFF57F17),

                            ),

                          ),

                        ],

                      ),

                    ),

                    if (_viewMode == 'class')

                      Wrap(

                        spacing: 4,

                        children: _classLevels.map((lvl) {

                          final selected = _selectedClassLevel == lvl;

                          return ChoiceChip(

                            label: Text(lvl, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),

                            selected: selected,

                            selectedColor: const Color(0xFF1A237E),

                            labelStyle: TextStyle(color: selected ? Colors.white : Colors.black87),

                            onSelected: (_) {

                              setState(() => _selectedClassLevel = lvl);

                              _loadTimetableData();

                            },

                          );

                        }).toList(),

                      ),



                    // Template Download & Upload Buttons

                    OutlinedButton.icon(

                      icon: const Icon(Icons.download_rounded, size: 16),

                      label: const Text('ฟอร์ม Excel', style: TextStyle(fontSize: 12)),

                      onPressed: _handleDownloadTemplate,

                    ),

                    if (_canEditCurrentTimetable) ...[

                      FilledButton.icon(

                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),

                        icon: const Icon(Icons.upload_file_rounded, size: 16),

                        label: const Text('อัพโหลดตารางสอน', style: TextStyle(fontSize: 12)),

                        onPressed: _handleUploadTimetable,

                      ),

                      FilledButton.icon(

                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1565C0)),

                        icon: const Icon(Icons.sync_rounded, size: 16),

                        label: const Text('เชื่อมโยงเข้าคลังข้อมูล', style: TextStyle(fontSize: 12)),

                        onPressed: _handleSyncArchive,

                      ),

                    ],

                  ],

                ),

              ],

            ),
            ),
            _buildHeaderCollapseButton(),
              ],
            ),
            ),

          ),



          // Main Timetable Sheet

          Expanded(

            child: _loading

                ? const Center(child: CircularProgressIndicator())

                : SingleChildScrollView(

                    padding: const EdgeInsets.all(16),

                    child: Center(

                      child: ConstrainedBox(

                        constraints: const BoxConstraints(maxWidth: 1450),

                        child: Card(

                          elevation: 2,

                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),

                          color: Colors.white,

                          child: Padding(

                            padding: const EdgeInsets.all(20),

                            child: Column(

                              crossAxisAlignment: CrossAxisAlignment.stretch,

                              children: [

                                // Official Document Banner

                                _buildDocumentHeader(),

                                const SizedBox(height: 16),



                                // Quick Teacher Selector Pills (for teachers already in system)

                                if (_viewMode == 'teacher' && _teachersWithTimetables.isNotEmpty) ...[

                                  Wrap(

                                    spacing: 8,

                                    runSpacing: 6,

                                    crossAxisAlignment: WrapCrossAlignment.center,

                                    children: [

                                      const Text(

                                        'ครูที่ลงตารางสอนแล้ว:',

                                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54),

                                      ),

                                      ..._teachersWithTimetables.map((t) {

                                        final isSel = _selectedTeacher == t;

                                        return ChoiceChip(

                                          avatar: Icon(

                                            Icons.person,

                                            size: 15,

                                            color: isSel ? Colors.white : const Color(0xFF1A237E),

                                          ),

                                          label: Text(t, style: const TextStyle(fontSize: 12)),

                                          selected: isSel,

                                          selectedColor: const Color(0xFF1A237E),

                                          labelStyle: TextStyle(

                                            color: isSel ? Colors.white : Colors.black87,

                                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,

                                          ),

                                          onSelected: (_) {

                                            setState(() => _selectedTeacher = t);

                                            _loadTimetableData();

                                          },

                                        );

                                      }),

                                    ],

                                  ),

                                  const SizedBox(height: 12),

                                ],



                                // Timetable Grid

                                if (_viewMode == 'master') ...[

                                  _buildMasterTimetableView(),

                                ] else ...[

                                  SingleChildScrollView(

                                    scrollDirection: Axis.horizontal,

                                    child: _buildTimetableTable(),

                                  ),

                                  const SizedBox(height: 16),

                                  _buildCourseSummarySection(),

                                ],



                                const SizedBox(height: 14),

                                // Legend & Help Footer

                                Container(

                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),

                                  decoration: BoxDecoration(

                                    color: const Color(0xFFF8F9FA),

                                    borderRadius: BorderRadius.circular(8),

                                    border: Border.all(color: Colors.grey.shade200),

                                  ),

                                  child: Row(

                                    children: [

                                      const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFF1A237E)),

                                      const SizedBox(width: 8),

                                      Expanded(

                                        child: Text(

                                          _viewMode == 'master'

                                              ? 'คลิกที่ "ช่องว่าง" หรือช่องคาบเรียนใดก็ได้ในตารางสอนรวม เพื่อดูรายชื่อครูที่ว่าง และตรวจสอบว่าครูท่านใดกำลังสอนประจำห้อง ม.1–ม.6 ในคาบนั้น'

                                              : 'คลิกที่ช่องคาบเรียนใดก็ได้เพื่อ เพิ่ม / แก้ไข / ลบ รายวิชาและชั้นเรียน • ข้อมูลตารางสอนนี้จะเชื่อมกับหน้า "เช็คเวลาเรียน" อัตโนมัติ เมื่อเช็คชื่อนักเรียนมาสาย (เลือกคาบ 1–7) ระบบจะตัดขาดเรียนในวิชาของคาบก่อนหน้าให้ทันที',

                                          style: const TextStyle(fontSize: 12, color: Colors.black87),

                                        ),

                                      ),

                                    ],

                                  ),

                                ),

                              ],

                            ),

                          ),

                        ),

                      ),

                    ),

                  ),

          ),

        ],

      ),

    );

  }



  Widget _buildDocumentHeader() {
    final titleTarget = _viewMode == 'teacher'
        ? _selectedTeacher
        : _viewMode == 'class'
            ? 'ระดับชั้นมัธยมศึกษาปีที่ ${_selectedClassLevel.replaceAll("ม.", "")} ($_selectedClassLevel)'
            : 'ตารางสอนรวมครูทุกท่าน (เช็คครูประจำห้องเรียน & ครูว่างรายคาบ)';
    final title = _viewMode == 'teacher'
        ? 'ตารางสอนรายบุคคล: $titleTarget'
        : _viewMode == 'class'
            ? 'ตารางเรียนประจำชั้น: $titleTarget'
            : titleTarget;
    final decoration = BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF1A237E), Color(0xFF283593)],
      ),
      borderRadius: BorderRadius.circular(10),
    );

    if (_bannerCollapsed) {
      // one thin line: what is shown + the semester, tap anywhere to open it again
      final shortTitle = _viewMode == 'master' ? 'ตารางสอนรวมครูทุกท่าน' : title;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('timetable-banner-collapsed'),
          onTap: () => _setBannerCollapsed(false),
          borderRadius: BorderRadius.circular(10),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            decoration: decoration,
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: shortTitle,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        TextSpan(
                          text: '  •  ภาคเรียนที่ $_selectedTerm/$_selectedYear',
                          style: const TextStyle(color: Color(0xFFFFD54F), fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ),
                _foldButton(
                  collapsed: true,
                  onPressed: () => _setBannerCollapsed(false),
                  color: Colors.white,
                  tooltip: 'แสดงแถบหัวตารางเต็ม',
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: decoration,
      child: Stack(
        children: [
          Padding(
            // the same space on both sides keeps the text centred next to the fold button
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.apiService.schoolBannerLine,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'ภาคเรียนที่ $_selectedTerm ปีการศึกษา $_selectedYear   •   เริ่มใช้ ${_selectedTerm == "2" ? "28 ตุลาคม" : "15 พฤษภาคม"} $_selectedYear',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFFD54F),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: Tooltip(
              message: 'ย่อแถบหัวตาราง ให้เห็นตารางได้มากขึ้น',
              child: IconButton(
                key: const ValueKey('timetable-banner-fold'),
                onPressed: () => _setBannerCollapsed(true),
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
                color: Colors.white,
                iconSize: 22,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimetableTable() {

    // Define column widths starting directly from Period 1 (omitting Morning activities to prevent overflow)

    const double dayColW = 92;

    const double periodColW = 118;

    const double breakColW = 46;

    const double rowH = 82;



    return SingleChildScrollView(

      scrollDirection: Axis.horizontal,

      child: Container(

        decoration: BoxDecoration(

          border: Border.all(color: Colors.grey.shade400, width: 1.2),

          borderRadius: BorderRadius.circular(6),

        ),

        child: Column(

          children: [

            // Header Row (Starts directly from Period 1)

            Container(

              decoration: const BoxDecoration(

                color: Color(0xFF1A237E),

              ),

              child: Row(

                children: [

                  _buildHeaderCell('วัน / เวลา', 'จันทร์ - ศุกร์', dayColW),

                  _buildHeaderCell('คาบ 1', '08.30 - 09.20', periodColW),

                  _buildHeaderCell('คาบ 2', '09.20 - 10.10', periodColW),

                  _buildBreakHeaderCell('พัก', '10.10\n10.20', breakColW),

                  _buildHeaderCell('คาบ 3', '10.20 - 11.10', periodColW),

                  _buildHeaderCell('คาบ 4', '11.10 - 12.00', periodColW),

                  _buildBreakHeaderCell('พักเที่ยง', '12.00\n13.00', breakColW + 14),

                  _buildHeaderCell('คาบ 5', '13.00 - 13.50', periodColW),

                  _buildHeaderCell('คาบ 6', '13.50 - 14.40', periodColW),

                  _buildHeaderCell('คาบ 7', '14.40 - 15.30', periodColW),

                  _buildHeaderCell('คาบ 8', '15.30 - 16.00', periodColW),

                ],

              ),

            ),



            // 5 Weekday Rows

            for (int day = 1; day <= 5; day++)

              Container(

                decoration: BoxDecoration(

                  border: Border(top: BorderSide(color: Colors.grey.shade300, width: 1)),

                ),

                child: Row(

                  children: [

                    // Day Label

                    Container(

                      width: dayColW,

                      height: rowH,

                      alignment: Alignment.center,

                      decoration: BoxDecoration(

                        color: _dayColors[day],

                        border: Border(right: BorderSide(color: Colors.grey.shade300)),

                      ),

                      child: Text(

                        _dayNames[day]!,

                        style: const TextStyle(

                          fontWeight: FontWeight.bold,

                          fontSize: 15,

                          color: Color(0xFF1A237E),

                        ),

                      ),

                    ),



                    // Period 1 & 2 (check if double span on Period 1)

                    ..._buildPeriodPair(day, 1, 2, periodColW, rowH),



                    // Morning 10-min Break

                    _buildBreakCell('พัก\n10 นาที', breakColW, rowH),



                    // Period 3 & 4 (check if double span on Period 3)

                    ..._buildPeriodPair(day, 3, 4, periodColW, rowH),



                    // Lunch Break

                    _buildBreakCell('พัก\nกลางวัน', breakColW + 14, rowH),



                    // Periods 5, 6, 7 (merge consecutive double/triple periods such as คาบ 5-6, 6-7, 5-7)

                    ..._buildAfternoonPeriods(day, periodColW, rowH),

                    _buildPeriodSlotCell(day, 8, periodColW, rowH),

                  ],

                ),

              ),

          ],

        ),

      ),

    );

  }



  List<Widget> _buildPeriodPair(int day, int p1, int p2, double width, double height) {

    final slot1 = _getSlot(day, p1);

    final slot2 = _getSlot(day, p2);

    if (slot1 != null &&

        slot2 != null &&

        slot1['course_code'] == slot2['course_code'] &&

        (slot1['course_code'] ?? '').toString().isNotEmpty) {

      // Combined double period card!

      return [

        _buildPeriodSlotCell(day, p1, width * 2, height, isMergedDouble: true, mergedSpan: 2),

      ];

    }

    return [

      _buildPeriodSlotCell(day, p1, width, height),

      _buildPeriodSlotCell(day, p2, width, height),

    ];

  }

  List<Widget> _buildAfternoonPeriods(int day, double width, double height) {
    final slot5 = _getSlot(day, 5);
    final slot6 = _getSlot(day, 6);
    final slot7 = _getSlot(day, 7);

    final code5 = (slot5?['course_code'] ?? '').toString().trim();
    final code6 = (slot6?['course_code'] ?? '').toString().trim();
    final code7 = (slot7?['course_code'] ?? '').toString().trim();

    if (code5.isNotEmpty && code5 == code6 && code6 == code7) {
      return [
        _buildPeriodSlotCell(day, 5, width * 3, height, isMergedDouble: true, mergedSpan: 3),
      ];
    }
    if (code5.isNotEmpty && code5 == code6) {
      return [
        _buildPeriodSlotCell(day, 5, width * 2, height, isMergedDouble: true, mergedSpan: 2),
        _buildPeriodSlotCell(day, 7, width, height),
      ];
    }
    if (code6.isNotEmpty && code6 == code7) {
      return [
        _buildPeriodSlotCell(day, 5, width, height),
        _buildPeriodSlotCell(day, 6, width * 2, height, isMergedDouble: true, mergedSpan: 2),
      ];
    }
    return [
      _buildPeriodSlotCell(day, 5, width, height),
      _buildPeriodSlotCell(day, 6, width, height),
      _buildPeriodSlotCell(day, 7, width, height),
    ];
  }



  Widget _buildHeaderCell(String title, String time, double width, {String? sub}) {

    return Container(

      width: width,

      height: 62,

      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),

      decoration: BoxDecoration(

        border: Border(right: BorderSide(color: Colors.white.withValues(alpha: 0.2))),

      ),

      child: Column(

        mainAxisAlignment: MainAxisAlignment.center,

        children: [

          Text(

            title,

            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),

          ),

          const SizedBox(height: 2),

          Text(

            time,

            style: const TextStyle(color: Color(0xFFFFD54F), fontSize: 10.5, fontWeight: FontWeight.w500),

          ),

          if (sub != null)

            Text(

              sub,

              style: const TextStyle(color: Colors.white70, fontSize: 10),

              overflow: TextOverflow.ellipsis,

            ),

        ],

      ),

    );

  }



  Widget _buildBreakHeaderCell(String title, String time, double width) {

    return Container(

      width: width,

      height: 62,

      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),

      decoration: BoxDecoration(

        color: const Color(0xFF0D47A1),

        border: Border(right: BorderSide(color: Colors.white.withValues(alpha: 0.2))),

      ),

      child: Column(

        mainAxisAlignment: MainAxisAlignment.center,

        children: [

          Text(

            title,

            textAlign: TextAlign.center,

            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10.5),

          ),

          const SizedBox(height: 2),

          Text(

            time,

            textAlign: TextAlign.center,

            style: const TextStyle(color: Colors.white70, fontSize: 9.5),

          ),

        ],

      ),

    );

  }



  Widget _buildBreakCell(String label, double width, double height) {

    return Container(

      width: width,

      height: height,

      alignment: Alignment.center,

      decoration: BoxDecoration(

        color: const Color(0xFFECEFF1),

        border: Border(right: BorderSide(color: Colors.grey.shade300)),

      ),

      child: Text(

        label,

        textAlign: TextAlign.center,

        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.blueGrey.shade600),

      ),

    );

  }



  Widget _buildPeriodSlotCell(

    int day,

    int period,

    double width,

    double height, {

    bool isMergedDouble = false,

    int mergedSpan = 1,

  }) {

    final effectiveSpan = mergedSpan > 1 ? mergedSpan : (isMergedDouble ? 2 : 1);

    final slot = _getSlot(day, period);

    final hasCourse = slot != null && (slot['course_code'] ?? '').toString().isNotEmpty;

    final courseCode = hasCourse ? slot['course_code'].toString() : '';

    final courseName = hasCourse ? (slot['course_name'] ?? '').toString() : '';

    final classLevel = hasCourse ? (slot['class_level'] ?? '').toString() : '';

    final teacherName = hasCourse ? (slot['teacher_name'] ?? '').toString() : '';

    // คาบสอนรวมหลายชั้น: แสดงทีละคู่ "รหัส ชั้น" ให้เห็นว่าคาบนี้ซ้อนกันกี่ชั้น

    final comboCodes = courseCode.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    final comboLevels = classLevel.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    final comboPairs = comboCodes.length > 1 && comboCodes.length == comboLevels.length

        ? [for (var i = 0; i < comboCodes.length; i++) '${comboCodes[i]} ${comboLevels[i]}']

        : <String>[];

    // ตารางรายชั้น: ครูคนอื่นมีวิชาของชั้นนี้ในคาบเดียวกัน (ครูตกลงสอนพร้อมกัน) -> แสดงทุกวิชาในคาบนั้น

    if (comboPairs.isEmpty && hasCourse && _viewMode == 'class') {

      const shared = {'Personal Learning', 'ชุมนุม', 'PLC ครู', 'คุณธรรม จริยธรรม', 'ลูกเสือ'};

      final sameTime = _slots

          .where((s) =>

              s['day_of_week'] == day &&

              s['period_num'] == period &&

              (s['course_code'] ?? '').toString().isNotEmpty &&

              !shared.contains((s['course_code'] ?? '').toString()))

          .map((s) => (s['course_code'] ?? '').toString())

          .toSet()

          .toList();

      if (sameTime.length > 1) comboPairs.addAll(sameTime);

    }



    final bool isActivity = hasCourse &&

        (const {

          'Personal Learning',

          'ชุมนุม',

          'PLC ครู',

          'คุณธรรม จริยธรรม',

          'ลูกเสือ',

          'แนะแนว',

          'มวยไทย',

        }.contains(courseCode) ||
            courseCode.startsWith('ก2') ||
            courseCode.startsWith('ก3'));



    final canEdit = _canEditCurrentTimetable;



    return InkWell(

      onTap: canEdit

          ? () {

              _openEditSlotDialog(

                dayOfWeek: day,

                periodNum: period,

                existingSlot: slot,

              );

            }

          : null,

      child: Container(

        width: width,

        height: height,

        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),

        decoration: BoxDecoration(

          color: !hasCourse

              ? Colors.white

              : isActivity

                  ? const Color(0xFFE0F2F1)

                  : const Color(0xFFE8EAF6),

          border: Border(right: BorderSide(color: Colors.grey.shade300)),

        ),

        child: !hasCourse

            ? Center(

                child: canEdit

                    ? Icon(

                        Icons.add_circle_outline_rounded,

                        size: 18,

                        color: Colors.grey.shade300,

                      )

                    : const SizedBox.shrink(),

              )

            : Column(

                mainAxisAlignment: MainAxisAlignment.center,

                children: [

                  // Course Code Badge

                  Row(

                    mainAxisAlignment: MainAxisAlignment.center,

                    children: [

                      Flexible(

                        child: Text(

                          comboPairs.isNotEmpty ? comboPairs.join('\n') : courseCode,

                          textAlign: TextAlign.center,

                          maxLines: comboPairs.isNotEmpty ? comboPairs.length : 1,

                          overflow: TextOverflow.ellipsis,

                          style: TextStyle(

                            fontWeight: FontWeight.bold,

                            fontSize: comboPairs.isNotEmpty ? 12 : 13.5,

                            color: isActivity ? Colors.teal.shade900 : const Color(0xFF1A237E),

                          ),

                        ),

                      ),

                      if (effectiveSpan > 1) ...[

                        const SizedBox(width: 4),

                        Container(

                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),

                          decoration: BoxDecoration(

                            color: Colors.indigo.shade100,

                            borderRadius: BorderRadius.circular(4),

                          ),

                          child: Text(

                            'คาบ $period-${period + effectiveSpan - 1}',

                            style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF1A237E)),

                          ),

                        ),

                      ],

                    ],

                  ),



                  // Course Name (if different from code)

                  if (courseName.isNotEmpty && courseName != courseCode)

                    Padding(

                      padding: const EdgeInsets.only(top: 2),

                      child: Text(

                        courseName,

                        textAlign: TextAlign.center,

                        maxLines: 1,

                        overflow: TextOverflow.ellipsis,

                        style: const TextStyle(fontSize: 11, color: Colors.black87),

                      ),

                    ),



                  const SizedBox(height: 3),



                  // Class Level Pill (in Teacher View) or Teacher Name (in Class View)

                  if (_viewMode == 'teacher' && classLevel.isNotEmpty)

                    Container(

                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),

                      decoration: BoxDecoration(

                        color: const Color(0xFF1A237E),

                        borderRadius: BorderRadius.circular(10),

                      ),

                      child: Text(

                        classLevel.contains('ม.1, ม.2, ม.3, ม.4, ม.5, ม.6') ||

                                classLevel.contains('ม.1 - ม.6')

                            ? '(ม.1 - ม.6)'

                            : comboPairs.isNotEmpty

                                ? 'สอนรวม ${comboPairs.length} ชั้น'

                                : '($classLevel)',

                        style: const TextStyle(

                          color: Colors.white,

                          fontSize: 10.5,

                          fontWeight: FontWeight.bold,

                        ),

                      ),

                    )

                  else if (_viewMode == 'class')

                    if (courseCode == 'Personal Learning' ||

                        courseCode == 'ชุมนุม' ||

                        courseCode == 'ลูกเสือ' ||

                        courseCode.contains('คุณธรรม') ||

                        courseCode.contains('จริยธรรม') ||

                        courseCode == 'PLC ครู')

                      // คาบ ชุมนุม จริยธรรม personal ลูกเสือ ไม่ต้องขึ้นชื่อครู

                      const SizedBox.shrink()

                    else if (teacherName.isNotEmpty)

                      Text(

                        teacherName,

                        textAlign: TextAlign.center,

                        maxLines: 1,

                        overflow: TextOverflow.ellipsis,

                        style: TextStyle(

                          fontSize: 10.5,

                          fontWeight: FontWeight.w600,

                          color: Colors.indigo.shade700,

                        ),

                      ),

                ],

              ),

      ),

    );

  }



  Widget _buildCourseSummarySection() {

    if (_slots.isEmpty) return const SizedBox.shrink();



    final Map<String, Map<String, dynamic>> summaryMap = {};

    int totalSubjectPeriods = 0;

    int totalActivityPeriods = 0;



    const activitySet = {

      'Personal Learning',

      'ชุมนุม',

      'PLC ครู',

      'คุณธรรม จริยธรรม',

      'ลูกเสือ',

      'แนะแนว',

      'มวยไทย',

    };



    for (final s in _slots) {

      final code = (s['course_code'] ?? '').toString();

      if (code.isEmpty) continue;

      final isAct = activitySet.contains(code);

      if (isAct) {

        totalActivityPeriods++;

      } else {

        totalSubjectPeriods++;

      }



      final key = '$code|${s['class_level'] ?? ''}';

      if (!summaryMap.containsKey(key)) {

        summaryMap[key] = {

          'course_code': code,

          'course_name': (s['course_name'] ?? '').toString(),

          'class_level': (s['class_level'] ?? '').toString(),

          'teacher_name': (s['teacher_name'] ?? '').toString(),

          'periods': 1,

          'is_activity': isAct,

        };

      } else {

        summaryMap[key]!['periods'] = (summaryMap[key]!['periods'] as int) + 1;

      }

    }



    final items = summaryMap.values.toList();

    items.sort((a, b) {

      final actA = a['is_activity'] as bool;

      final actB = b['is_activity'] as bool;

      if (actA != actB) return actA ? 1 : -1;

      return a['course_code'].toString().compareTo(b['course_code'].toString());

    });



    return Container(

      padding: const EdgeInsets.all(14),

      decoration: BoxDecoration(

        color: const Color(0xFFF8F9FD),

        borderRadius: BorderRadius.circular(10),

        border: Border.all(color: Colors.indigo.shade100),

      ),

      child: Column(

        crossAxisAlignment: CrossAxisAlignment.start,

        children: [

          Row(

            children: [

              const Icon(Icons.analytics_outlined, size: 18, color: Color(0xFF1A237E)),

              const SizedBox(width: 8),

              Text(

                _viewMode == 'teacher'

                    ? 'สรุปรายวิชาและจำนวนคาบสอนของ $_selectedTeacher'

                    : 'สรุปรายวิชาในตารางเรียนชั้น $_selectedClassLevel',

                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: Color(0xFF1A237E)),

              ),

              const Spacer(),

              Container(

                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),

                decoration: BoxDecoration(

                  color: const Color(0xFF1A237E),

                  borderRadius: BorderRadius.circular(12),

                ),

                child: Text(

                  'วิชาเรียน $totalSubjectPeriods คาบ/สัปดาห์  •  กิจกรรม $totalActivityPeriods คาบ  •  รวมทั้งหมด ${totalSubjectPeriods + totalActivityPeriods} คาบ',

                  style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),

                ),

              ),

            ],

          ),

          const SizedBox(height: 10),

          Wrap(

            spacing: 8,

            runSpacing: 8,

            children: items.map((item) {

              final code = item['course_code'].toString();

              final name = item['course_name'].toString();

              final lvl = item['class_level'].toString();

              final tName = item['teacher_name'].toString();

              final pCount = item['periods'] as int;

              final isAct = item['is_activity'] as bool;



              return Container(

                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),

                decoration: BoxDecoration(

                  color: isAct ? Colors.teal.shade50 : Colors.white,

                  borderRadius: BorderRadius.circular(8),

                  border: Border.all(color: isAct ? Colors.teal.shade200 : Colors.indigo.shade100),

                ),

                child: Row(

                  mainAxisSize: MainAxisSize.min,

                  children: [

                    Text(

                      code,

                      style: TextStyle(

                        fontWeight: FontWeight.bold,

                        fontSize: 12.5,

                        color: isAct ? Colors.teal.shade900 : const Color(0xFF1A237E),

                      ),

                    ),

                    if (name.isNotEmpty && name != code) ...[

                      const SizedBox(width: 5),

                      Text(name, style: const TextStyle(fontSize: 12, color: Colors.black87)),

                    ],

                    if (_viewMode == 'teacher' && lvl.isNotEmpty) ...[

                      const SizedBox(width: 6),

                      Container(

                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),

                        decoration: BoxDecoration(

                          color: Colors.indigo.shade50,

                          borderRadius: BorderRadius.circular(6),

                        ),

                        child: Text(lvl, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1A237E))),

                      ),

                    ] else if (_viewMode == 'class' && tName.isNotEmpty && !isAct) ...[

                      const SizedBox(width: 6),

                      Text('($tName)', style: TextStyle(fontSize: 11, color: Colors.indigo.shade700)),

                    ],

                    const SizedBox(width: 6),

                    Text(

                      '• $pCount คาบ',

                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.grey.shade700),

                    ),

                  ],

                ),

              );

            }).toList(),

          ),

        ],

      ),

    );

  }

  // ===========================================================================
  // MASTER TIMETABLE VIEW (ตารางสอนรวมครูทุกท่าน & เช็คครูว่าง/ครูสอนประจำห้อง)
  // ===========================================================================

  List<Map<String, String>> _getMasterTeacherRoster() {
    // order, names and กลุ่มสาระ come from the server (GET /api/v1/timetables/master-roster)
    final baseRoster = _masterRoster.map((r) => Map<String, String>.from(r)).toList();

    for (final t in _teachersWithTimetables) {
      final exists = baseRoster.any((r) => t.contains(r['base']!));
      if (!exists) {
        baseRoster.add({
          'no': '${baseRoster.length + 1}',
          'key': t,
          'formal': t,
          'base': t.replaceAll('ครู', '').trim(),
          'code': '-',
          'dept': 'อื่นๆ',
        });
      }
    }
    return baseRoster;
  }

  List<Map<String, dynamic>> _getTeacherSlotsAt(Map<String, String> teacher, int day, int period) {
    final base = (teacher['base'] ?? '').trim();
    final key = (teacher['key'] ?? '').trim();
    final formal = (teacher['formal'] ?? '').trim();
    final normTarget = LoggedInTeacher.normalize(base.isNotEmpty ? base : key);

    return _slots.where((s) {
      final d = int.tryParse((s['day_of_week'] ?? 0).toString()) ?? 0;
      if (d != day) return false;
      final pNum = int.tryParse((s['period_num'] ?? s['period'] ?? 0).toString()) ?? 0;
      final pSpan = int.tryParse((s['period_span'] ?? 1).toString()) ?? 1;
      if (period < pNum || period >= pNum + pSpan) return false;

      final tName = (s['teacher_name'] ?? '').toString().trim();
      if (tName.isEmpty) return false;
      if (tName == key || tName == formal) return true;
      if (base.isNotEmpty && tName.contains(base)) return true;
      if (normTarget.isNotEmpty && LoggedInTeacher.normalize(tName) == normTarget) return true;
      return false;
    }).toList();
  }

  int _getPeriodsForDayInMaster(int day) {
    if (day == 5) return 8;
    final hasPeriod8 = _slots.any((s) {
      final d = int.tryParse((s['day_of_week'] ?? 0).toString()) ?? 0;
      final pNum = int.tryParse((s['period_num'] ?? s['period'] ?? 0).toString()) ?? 0;
      final pSpan = int.tryParse((s['period_span'] ?? 1).toString()) ?? 1;
      return d == day && (pNum + pSpan - 1) >= 8;
    });
    return hasPeriod8 ? 8 : 7;
  }

  int _countSlotTeachingLoad(List<Map<String, dynamic>> slots, {int? day, int? period}) {
    if (slots.isEmpty) return 0;
    final s = slots.first;
    final code = (s['course_code'] ?? '').toString().trim();
    final name = (s['course_name'] ?? '').toString().trim();
    // Friday P8 moral assembly (ธ) and PLC are displayed on grid but not counted as academic teaching load in official PDF
    if (code.contains('คุณธรรม') || name.contains('คุณธรรม') || code == 'PLC ครู') {
      return 0;
    }
    if (code == 'ลูกเสือ' ||
        name.contains('ลูกเสือ') ||
        code == 'ชุมนุม' ||
        name.contains('ชุมนุม') ||
        code == 'Personal Learning') {
      // On Wed (3) and Thu (4), P5-7 activity block counts as 1 unit at P7 in official Master Timetable summary
      if ((day == 3 || day == 4) && (period == 5 || period == 6)) {
        return 0;
      }
      return 1;
    }
    final rawLevels = slots
        .map((e) => (e['class_level'] ?? '').toString().trim())
        .where((e) => e.isNotEmpty)
        .join(', ');
    final nums = RegExp(r'[1-6]').allMatches(rawLevels).map((m) => m.group(0)!).toSet();
    return nums.isNotEmpty ? nums.length : 1;
  }

  Map<String, dynamic> _formatMasterSlotBadge(List<Map<String, dynamic>> slots) {
    if (slots.isEmpty) {
      return {
        'short': '',
        'sub': '',
        'tooltip': 'ว่าง (คลิกเพื่อดูรายชื่อครูว่างทั้งหมดในคาบนี้)',
        'bg': const Color(0xFFF1F8E9),
        'fg': const Color(0xFF2E7D32),
        'border': const Color(0xFFC5E1A5),
        'class_level': '',
        'course': '',
        'code': '',
      };
    }

    final s = slots.first;
    final code = (s['course_code'] ?? '').toString().trim();
    final name = (s['course_name'] ?? '').toString().trim();
    final rawLevels = slots
        .map((e) => (e['class_level'] ?? '').toString().trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .join(', ');

    String shortLabel = rawLevels;
    String subLabel = code;
    Color bg = const Color(0xFFE8EAF6);
    Color fg = const Color(0xFF1A237E);
    Color border = const Color(0xFF9FA8DA);

    final isIS = RegExp(r'^I\d').hasMatch(code) ||
        name.toUpperCase().contains('IS') ||
        name.contains('ค้นคว้าอิสระ') ||
        name.contains('การนำเสนอข้อมูล');

    if (name.contains('ลูกเสือ') || code.contains('ลูกเสือ')) {
      shortLabel = 'ลส';
      subLabel = 'ลูกเสือ';
      bg = const Color(0xFFFFF3E0);
      fg = const Color(0xFFE65100);
      border = const Color(0xFFFFCC80);
    } else if (name.contains('ชุมนุม') || code.contains('ชุมนุม')) {
      shortLabel = 'ก';
      subLabel = 'ชุมนุม';
      bg = const Color(0xFFF3E5F5);
      fg = const Color(0xFF6A1B9A);
      border = const Color(0xFFCE93D8);
    } else if (name.contains('คุณธรรม') || code.contains('คุณธรรม')) {
      shortLabel = 'ธ';
      subLabel = 'จริยธรรม';
      bg = const Color(0xFFE0F2F1);
      fg = const Color(0xFF00695C);
      border = const Color(0xFF80CBC4);
    } else if (code == 'Personal Learning' || name.contains('Personal Learning')) {
      shortLabel = 'PL';
      subLabel = 'Personal';
      bg = const Color(0xFFE0F7FA);
      fg = const Color(0xFF006064);
      border = const Color(0xFF80DEEA);
    } else if (name.contains('แนะแนว') || code.contains('แนะแนว') || RegExp(r'^ก[23]\d10[12]$').hasMatch(code)) {
      final numOnly = rawLevels.replaceAll(RegExp(r'[^0-9]'), '');
      shortLabel = numOnly.isNotEmpty ? 'น$numOnly' : 'น';
      subLabel = (code.isNotEmpty && code != 'แนะแนว') ? code : 'แนะแนว';
      bg = const Color(0xFFE1F5FE);
      fg = const Color(0xFF0277BD);
      border = const Color(0xFF81D4FA);
    } else if (isIS) {
      final numOnly = rawLevels.replaceAll(RegExp(r'[^0-9]'), '');
      shortLabel = numOnly.isNotEmpty ? 'IS$numOnly' : 'IS';
      subLabel = code;
      bg = const Color(0xFFFCE4EC);
      fg = const Color(0xFFAD1457);
      border = const Color(0xFFF48FB1);
    } else if (name.toUpperCase().contains('PLC') || code.toUpperCase().contains('PLC')) {
      shortLabel = 'PLC';
      subLabel = 'PLC ครู';
      bg = const Color(0xFFEDE7F6);
      fg = const Color(0xFF4527A0);
      border = const Color(0xFFB39DDB);
    } else {
      final nums = RegExp(r'[1-6]')
          .allMatches(rawLevels)
          .map((m) => m.group(0)!)
          .toSet()
          .toList()
        ..sort();
      if (nums.length == 1) {
        final g = nums.first;
        shortLabel = 'ม.$g';
        subLabel = code;
        switch (g) {
          case '1':
            bg = const Color(0xFFE3F2FD);
            fg = const Color(0xFF0D47A1);
            border = const Color(0xFF90CAF9);
            break;
          case '2':
            bg = const Color(0xFFE8EAF6);
            fg = const Color(0xFF1A237E);
            border = const Color(0xFF9FA8DA);
            break;
          case '3':
            bg = const Color(0xFFE0F2F1);
            fg = const Color(0xFF004D40);
            border = const Color(0xFF80CBC4);
            break;
          case '4':
            bg = const Color(0xFFFFF8E1);
            fg = const Color(0xFFE65100);
            border = const Color(0xFFFFE082);
            break;
          case '5':
            bg = const Color(0xFFF3E5F5);
            fg = const Color(0xFF4A148C);
            border = const Color(0xFFCE93D8);
            break;
          case '6':
            bg = const Color(0xFFFCE4EC);
            fg = const Color(0xFF880E4F);
            border = const Color(0xFFF48FB1);
            break;
        }
      } else if (nums.length > 1) {
        shortLabel = 'ม.${nums.join(",")}';
        subLabel = code;
        bg = const Color(0xFFEDE7F6);
        fg = const Color(0xFF311B92);
        border = const Color(0xFFB39DDB);
      } else if (shortLabel.isEmpty) {
        shortLabel = code.isNotEmpty ? code : name;
      }
    }

    final displayTitle = [
      if (code.isNotEmpty && code != 'กิจกรรม' && code != name) code,
      if (name.isNotEmpty) name,
    ].join(' ');
    final tooltip = [
      if (displayTitle.isNotEmpty) 'วิชา: $displayTitle',
      if (rawLevels.isNotEmpty) 'ชั้น: $rawLevels',
    ].join(' • ');

    return {
      'short': shortLabel,
      'sub': subLabel,
      'tooltip': tooltip,
      'bg': bg,
      'fg': fg,
      'border': border,
      'class_level': rawLevels,
      'course': displayTitle,
      'code': code,
    };
  }

  Map<String, List<Map<String, dynamic>>> _getClassRoomStatusAt(
    List<Map<String, String>> roster,
    int day,
    int period,
  ) {
    final map = <String, List<Map<String, dynamic>>>{
      for (final lvl in _classLevels) lvl: [],
    };
    for (final t in roster) {
      final tSlots = _getTeacherSlotsAt(t, day, period);
      if (tSlots.isEmpty) continue;
      final badge = _formatMasterSlotBadge(tSlots);
      final rawLvl = (badge['class_level'] ?? '').toString();
      for (final lvl in _classLevels) {
        final gradeDigit = lvl.replaceAll('ม.', '');
        if (RegExp(r'\b' + gradeDigit + r'\b').hasMatch(rawLvl) || rawLvl.contains(lvl)) {
          map[lvl]!.add({
            'teacher': t,
            'badge': badge,
            'slot': tSlots.first,
          });
        }
      }
    }
    return map;
  }

  void _showFreeTeachersDialog(int day, int period, {String? clickedTeacher}) {
    setState(() {
      _selectedMasterDay = day;
      _selectedMasterPeriod = period;
    });

    final roster = _getMasterTeacherRoster();
    final freeTeachers = <Map<String, String>>[];
    final busyTeachers = <Map<String, dynamic>>[];

    for (final t in roster) {
      final tSlots = _getTeacherSlotsAt(t, day, period);
      if (tSlots.isEmpty) {
        freeTeachers.add(t);
      } else {
        final badge = _formatMasterSlotBadge(tSlots);
        busyTeachers.add({
          'teacher': t,
          'badge': badge,
          'slots': tSlots,
        });
      }
    }

    final classStatus = _getClassRoomStatusAt(roster, day, period);

    final dayName = _dayNames[day] ?? '';
    final periodTimes = <int, String>{
      1: '08.30 - 09.20 น.',
      2: '09.20 - 10.10 น.',
      3: '10.20 - 11.10 น.',
      4: '11.10 - 12.00 น.',
      5: '13.00 - 13.50 น.',
      6: '13.50 - 14.40 น.',
      7: '14.50 - 15.40 น.',
      8: '15.40 - 16.30 น.',
    };

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: EdgeInsets.zero,
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF1A237E), Color(0xFF283593)]),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.fact_check_rounded, color: Color(0xFFFFD54F), size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ตรวจสอบครูว่าง & ครูประจำห้องเรียน • วัน$dayName คาบที่ $period',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'เวลาเรียน: ${periodTimes[period] ?? "-"}   •   ว่าง ${freeTeachers.length} ท่าน / กำลังสอน ${busyTeachers.length} ท่าน',
                        style: const TextStyle(color: Color(0xFFFFD54F), fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. Free Teachers Box
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFA5D6A7), width: 1.2),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.check_circle_rounded, color: Color(0xFF2E7D32), size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'รายชื่อครูที่ว่างในคาบนี้ (${freeTeachers.length} ท่าน)',
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1B5E20),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (freeTeachers.isEmpty)
                          const Text(
                            'ไม่มีครูว่างในคาบนี้ (ครูทุกท่านติดภารกิจการสอน/กิจกรรม)',
                            style: TextStyle(fontSize: 13, color: Colors.black54, fontStyle: FontStyle.italic),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: freeTeachers.map((t) {
                              final isClicked = clickedTeacher != null &&
                                  (t['key'] == clickedTeacher || t['formal'] == clickedTeacher);
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(
                                  color: isClicked ? const Color(0xFF2E7D32) : Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isClicked ? const Color(0xFF1B5E20) : const Color(0xFF81C784),
                                    width: isClicked ? 1.8 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.person_pin_circle_rounded,
                                      size: 16,
                                      color: isClicked ? Colors.white : const Color(0xFF2E7D32),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '${t['formal']} (${t['code']})',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: isClicked ? Colors.white : const Color(0xFF1B5E20),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: isClicked ? Colors.white24 : const Color(0xFFE8F5E9),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'ว่าง',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isClicked ? Colors.white : const Color(0xFF2E7D32),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 2. Classroom Status M.1 - M.6
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8EAF6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF9FA8DA)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.meeting_room_rounded, color: Color(0xFF1A237E), size: 20),
                            SizedBox(width: 8),
                            Text(
                              'สถานะห้องเรียน ม.1 – ม.6 ในคาบนี้ (ใครกำลังสอนห้องไหน)',
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A237E),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _classLevels.map((lvl) {
                            final entries = classStatus[lvl] ?? [];
                            return Container(
                              width: 215,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: entries.isNotEmpty ? const Color(0xFF7986CB) : Colors.grey.shade300,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1A237E),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          'ชั้น $lvl',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          entries.isEmpty
                                              ? 'คาบว่าง / พัฒนาผู้เรียน'
                                              : (entries.first['badge']['sub'] ?? '').toString(),
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                            color: entries.isEmpty ? Colors.grey.shade600 : const Color(0xFF1A237E),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  if (entries.isEmpty)
                                    const Text(
                                      'ไม่มีรายวิชาเรียนในคาบนี้',
                                      style: TextStyle(fontSize: 11, color: Colors.black54),
                                    )
                                  else
                                    ...entries.map((e) {
                                      final t = e['teacher'] as Map<String, String>;
                                      final b = e['badge'] as Map<String, dynamic>;
                                      return Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          '${t['key']} • ${b['course']}',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black87,
                                          ),
                                        ),
                                      );
                                    }),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 3. Busy Teachers List
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F7FA),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.indigo.shade100),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.school_rounded, color: Color(0xFF1A237E), size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'ครูที่กำลังสอน / ประจำห้องเรียนในคาบนี้ (${busyTeachers.length} ท่าน)',
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A237E),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (busyTeachers.isEmpty)
                          const Text(
                            'ไม่มีรายการสอนในคาบนี้',
                            style: TextStyle(fontSize: 13, color: Colors.black54),
                          )
                        else
                          Column(
                            children: busyTeachers.map((item) {
                              final t = item['teacher'] as Map<String, String>;
                              final badge = item['badge'] as Map<String, dynamic>;
                              final isClicked = clickedTeacher != null &&
                                  (t['key'] == clickedTeacher || t['formal'] == clickedTeacher);
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isClicked ? const Color(0xFFE8EAF6) : Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isClicked ? const Color(0xFF1A237E) : Colors.grey.shade300,
                                    width: isClicked ? 1.5 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      constraints: const BoxConstraints(minWidth: 52),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: badge['bg'] as Color,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: badge['border'] as Color),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        badge['short'].toString(),
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.bold,
                                          color: badge['fg'] as Color,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        '${t['formal']} (${t['code']})',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.black87,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 4,
                                      child: Text(
                                        '${badge['course']} ${badge['class_level'].toString().isNotEmpty ? "(${badge['class_level']})" : ""}',
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          color: Color(0xFF283593),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1A237E)),
              onPressed: () => Navigator.pop(ctx),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('รับทราบ / ปิดหน้าต่าง'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMasterTimetableView() {
    final roster = _getMasterTeacherRoster();
    final maxPeriodsSelectedDay = _getPeriodsForDayInMaster(_selectedMasterDay);
    if (_selectedMasterPeriod > maxPeriodsSelectedDay) {
      _selectedMasterPeriod = maxPeriodsSelectedDay;
    }

    final freeInSelected = <Map<String, String>>[];
    final busyInSelected = <Map<String, dynamic>>[];
    for (final t in roster) {
      final tSlots = _getTeacherSlotsAt(t, _selectedMasterDay, _selectedMasterPeriod);
      if (tSlots.isEmpty) {
        freeInSelected.add(t);
      } else {
        busyInSelected.add({
          'teacher': t,
          'badge': _formatMasterSlotBadge(tSlots),
        });
      }
    }

    final panelDecoration = BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFC5CAE9), width: 1.2),
    );
    final panelSummary =
        'วัน${_dayNames[_selectedMasterDay]} คาบ $_selectedMasterPeriod • ว่าง ${freeInSelected.length} ท่าน • สอน ${busyInSelected.length} ท่าน';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_checkPanelCollapsed)
          // folded: one line that still answers "who is free now" in numbers; tap to open the panel again
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('timetable-checkpanel-collapsed'),
              onTap: () => _setCheckPanelCollapsed(false),
              borderRadius: BorderRadius.circular(12),
              child: Ink(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                decoration: panelDecoration,
                child: Row(
                  children: [
                    const Icon(Icons.person_pin_circle_rounded, color: Color(0xFF1A237E), size: 20),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(
                              text: 'เช็คครูว่าง: ',
                              style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1A237E)),
                            ),
                            TextSpan(text: panelSummary, style: const TextStyle(color: Colors.black87)),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    _foldButton(
                      collapsed: true,
                      onPressed: () => _setCheckPanelCollapsed(false),
                      color: const Color(0xFF1A237E),
                      tooltip: 'แสดงช่องเช็คครูว่าง / ครูสอนประจำห้อง',
                    ),
                  ],
                ),
              ),
            ),
          )
        else
        Container(
          padding: const EdgeInsets.all(14),
          decoration: panelDecoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Expanded(
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_pin_circle_rounded, color: Color(0xFF1A237E), size: 20),
                      SizedBox(width: 6),
                      Text(
                        'เช็คครูว่าง / ครูสอนประจำห้อง:',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1A237E)),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 4,
                    children: [1, 2, 3, 4, 5].map((d) {
                      final sel = _selectedMasterDay == d;
                      return ChoiceChip(
                        label: Text('วัน${_dayNames[d]}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        selected: sel,
                        selectedColor: const Color(0xFF1A237E),
                        labelStyle: TextStyle(color: sel ? Colors.white : Colors.black87),
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) {
                          setState(() {
                            _selectedMasterDay = d;
                            final maxP = _getPeriodsForDayInMaster(d);
                            if (_selectedMasterPeriod > maxP) _selectedMasterPeriod = maxP;
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const Text('•', style: TextStyle(color: Colors.grey)),
                  Wrap(
                    spacing: 4,
                    children: List.generate(maxPeriodsSelectedDay, (i) => i + 1).map((p) {
                      final sel = _selectedMasterPeriod == p;
                      return ChoiceChip(
                        label: Text('คาบ $p', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        selected: sel,
                        selectedColor: const Color(0xFF2E7D32),
                        labelStyle: TextStyle(color: sel ? Colors.white : Colors.black87),
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) {
                          setState(() => _selectedMasterPeriod = p);
                        },
                      );
                    }).toList(),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: const Color(0xFF1A237E),
                    ),
                    onPressed: () => _showFreeTeachersDialog(_selectedMasterDay, _selectedMasterPeriod),
                    icon: const Icon(Icons.open_in_new_rounded, size: 15),
                    label: const Text('เปิดหน้าต่างสรุปรายคาบ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              ),
              _foldButton(
                key: const ValueKey('timetable-checkpanel-fold'),
                collapsed: false,
                onPressed: () => _setCheckPanelCollapsed(true),
                color: const Color(0xFF1A237E),
                tooltip: 'ย่อช่องเช็คครูว่าง ให้เห็นตารางได้มากขึ้น',
              ),
                ],
              ),
              const SizedBox(height: 12),
              Flex(
                // a phone has no room for the two lists side by side: one under the other there
                direction: MediaQuery.sizeOf(context).width < 700 ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: MediaQuery.sizeOf(context).width < 700 ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
                children: [
                  _flexOrPlain(
                    flex: 5,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F5E9),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFA5D6A7)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.check_circle_rounded, size: 16, color: Color(0xFF2E7D32)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'ครูที่ว่างในวัน${_dayNames[_selectedMasterDay]} คาบที่ $_selectedMasterPeriod (${freeInSelected.length} ท่าน)',
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (freeInSelected.isEmpty)
                            const Text(
                              'ไม่มีครูว่างในคาบนี้ (ครูทุกท่านมีคาบสอน/กิจกรรม)',
                              style: TextStyle(fontSize: 12, color: Colors.black54),
                            )
                          else
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: freeInSelected.map((t) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: const Color(0xFF81C784)),
                                  ),
                                  child: Text(
                                    '${t['key']} (${t['code']})',
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
                                  ),
                                );
                              }).toList(),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10, height: 10),
                  _flexOrPlain(
                    flex: 7,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.indigo.shade100),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.meeting_room_rounded, size: 16, color: Color(0xFF1A237E)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'ครูที่กำลังสอนประจำชั้นเรียนในวัน${_dayNames[_selectedMasterDay]} คาบที่ $_selectedMasterPeriod (${busyInSelected.length} ท่าน)',
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF1A237E)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (busyInSelected.isEmpty)
                            const Text('ไม่มีคาบสอน', style: TextStyle(fontSize: 12, color: Colors.black54))
                          else
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: busyInSelected.map((item) {
                                final t = item['teacher'] as Map<String, String>;
                                final b = item['badge'] as Map<String, dynamic>;
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: b['bg'] as Color,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: b['border'] as Color),
                                  ),
                                  child: Text(
                                    '${b['short']} : ${t['key']} (${b['sub']})',
                                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: b['fg'] as Color),
                                  ),
                                );
                              }).toList(),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _buildMasterMatrixTable(roster),
      ],
    );
  }

  /// Side by side (wide screen): share the row by [flex]. Stacked (phone): full width, own height.
  Widget _flexOrPlain({required int flex, required Widget child}) {
    return MediaQuery.sizeOf(context).width < 700 ? child : Expanded(flex: flex, child: child);
  }

  Widget _buildMasterMatrixTable(List<Map<String, String>> roster) {
    const double noW = 32;
    const double nameW = 180;
    const double codeW = 46;
    const double fixedLeftW = noW + nameW + codeW;
    const double cellW = 42;
    const double lunchW = 18;
    const double totalW = 64;
    const double rowH = 42;
    const double deptRowH = 26;

    final dayHeaderColors = <int, Color>{
      1: const Color(0xFFFFF59D),
      2: const Color(0xFFF8BBD0),
      3: const Color(0xFFC8E6C9),
      4: const Color(0xFFFFE0B2),
      5: const Color(0xFFBBDEFB),
    };

    final days = [1, 2, 3, 4, 5];
    final periodsByDay = {for (final d in days) d: _getPeriodsForDayInMaster(d)};
    final scrollableRightW =
        days.fold<double>(0, (sum, d) => sum + cellW * periodsByDay[d]! + lunchW) + totalW;

    final leftFixedRows = <Widget>[];
    final rightScrollableRows = <Widget>[];

    // 1. Top Header Row (Pinned Left vs Scrollable Right)
    leftFixedRows.add(
      Container(
        width: fixedLeftW,
        height: 56,
        decoration: const BoxDecoration(
          color: Color(0xFF1A237E),
          borderRadius: BorderRadius.only(topLeft: Radius.circular(6)),
        ),
        child: Row(
          children: [
            _buildMasterTopHeaderCell('ที่', noW, 56),
            _buildMasterTopHeaderCell('ชื่อ - สกุล', nameW, 56),
            _buildMasterTopHeaderCell('รหัส 📌', codeW, 56),
          ],
        ),
      ),
    );

    rightScrollableRows.add(
      Container(
        width: scrollableRightW,
        height: 56,
        decoration: const BoxDecoration(
          color: Color(0xFF1A237E),
          borderRadius: BorderRadius.only(topRight: Radius.circular(6)),
        ),
        child: Row(
          children: [
            for (final d in days)
              Column(
                children: [
                  Container(
                    width: cellW * periodsByDay[d]! + lunchW,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: dayHeaderColors[d],
                      border: Border(
                        right: BorderSide(color: Colors.grey.shade700, width: 1.4),
                        bottom: BorderSide(color: Colors.grey.shade500, width: 0.8),
                      ),
                    ),
                    child: Text(
                      'วัน${_dayNames[d]}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A237E),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (int p = 1; p <= periodsByDay[d]!; p++) ...[
                        InkWell(
                          onTap: () => _showFreeTeachersDialog(d, p),
                          child: Tooltip(
                            message: 'คลิกเพื่อดูครูว่าง / ครูสอนในวัน${_dayNames[d]} คาบที่ $p',
                            child: Container(
                              width: cellW,
                              height: 28,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: (_selectedMasterDay == d && _selectedMasterPeriod == p)
                                    ? const Color(0xFF2E7D32)
                                    : dayHeaderColors[d]!.withValues(alpha: 0.65),
                                border: Border(
                                  right: BorderSide(
                                    color: p == periodsByDay[d] ? Colors.grey.shade700 : Colors.grey.shade400,
                                    width: p == periodsByDay[d] ? 1.4 : 0.6,
                                  ),
                                ),
                              ),
                              child: Text(
                                '$p',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: (_selectedMasterDay == d && _selectedMasterPeriod == p)
                                      ? Colors.white
                                      : Colors.black87,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (p == 4)
                          Container(
                            width: lunchW,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              border: Border(
                                right: BorderSide(color: Colors.grey.shade400, width: 0.6),
                              ),
                            ),
                            child: const Text(
                              'พ',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            _buildMasterTopHeaderCell('รวม / จริง\n(คาบ)', totalW, 56),
          ],
        ),
      ),
    );

    // 2. Teacher & Department Rows
    String lastDept = '';
    for (int idx = 0; idx < roster.length; idx++) {
      final t = roster[idx];
      final dept = t['dept'] ?? '';
      if (dept.isNotEmpty && dept != lastDept) {
        lastDept = dept;
        leftFixedRows.add(
          Container(
            width: fixedLeftW,
            height: deptRowH,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: const Color(0xFFE8EAF6),
              border: Border(
                top: BorderSide(color: Colors.grey.shade400, width: 0.8),
                bottom: BorderSide(color: Colors.grey.shade400, width: 0.8),
              ),
            ),
            child: Text(
              dept,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A237E),
              ),
            ),
          ),
        );
        rightScrollableRows.add(
          Container(
            width: scrollableRightW,
            height: deptRowH,
            decoration: BoxDecoration(
              color: const Color(0xFFE8EAF6),
              border: Border(
                top: BorderSide(color: Colors.grey.shade400, width: 0.8),
                bottom: BorderSide(color: Colors.grey.shade400, width: 0.8),
              ),
            ),
          ),
        );
      }

      int totalTeacherPeriods = 0;
      final dayCells = <Widget>[];

      for (final d in days) {
        final maxP = periodsByDay[d]!;
        for (int p = 1; p <= maxP; p++) {
          final tSlots = _getTeacherSlotsAt(t, d, p);
          final isBusy = tSlots.isNotEmpty;
          if (isBusy) {
            totalTeacherPeriods += _countSlotTeachingLoad(tSlots, day: d, period: p);
          }
          final badge = _formatMasterSlotBadge(tSlots);
          final isSelectedCol = (_selectedMasterDay == d && _selectedMasterPeriod == p);
          final subCode = (badge['sub'] ?? '').toString();

          dayCells.add(
            InkWell(
              onTap: () => _showFreeTeachersDialog(d, p, clickedTeacher: t['key']),
              child: Tooltip(
                message: isBusy
                    ? '${t['formal']} • วัน${_dayNames[d]} คาบ $p\n${badge['tooltip']}\n(คลิกเพื่อดูภาพรวมคาบนี้)'
                    : '${t['formal']} • ว่างในวัน${_dayNames[d]} คาบ $p\n(คลิกเพื่อดูรายชื่อครูว่างทั้งหมดในคาบนี้)',
                child: Container(
                  width: cellW,
                  height: rowH,
                  padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isBusy
                        ? (badge['bg'] as Color)
                        : isSelectedCol
                            ? const Color(0xFFC8E6C9)
                            : const Color(0xFFF9FBE7).withValues(alpha: 0.55),
                    border: Border(
                      right: BorderSide(
                        color: p == maxP ? Colors.grey.shade700 : Colors.grey.shade300,
                        width: p == maxP ? 1.4 : 0.6,
                      ),
                      bottom: BorderSide(color: Colors.grey.shade300, width: 0.6),
                    ),
                  ),
                  child: isBusy
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              badge['short'].toString(),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                height: 1.05,
                                color: badge['fg'] as Color,
                              ),
                            ),
                            if (subCode.isNotEmpty && subCode != badge['short'].toString())
                              Text(
                                subCode,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w600,
                                  height: 1.05,
                                  color: (badge['fg'] as Color).withValues(alpha: 0.85),
                                ),
                              ),
                          ],
                        )
                      : Text(
                          'ว่าง',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: isSelectedCol ? FontWeight.bold : FontWeight.w500,
                            color: isSelectedCol
                                ? const Color(0xFF1B5E20)
                                : const Color(0xFF689F38).withValues(alpha: 0.75),
                          ),
                        ),
                ),
              ),
            ),
          );

          if (p == 4) {
            dayCells.add(
              Container(
                width: lunchW,
                height: rowH,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  border: Border(
                    right: BorderSide(color: Colors.grey.shade300, width: 0.6),
                    bottom: BorderSide(color: Colors.grey.shade300, width: 0.6),
                  ),
                ),
              ),
            );
          }
        }
      }

      leftFixedRows.add(
        Row(
          children: [
            Container(
              width: noW,
              height: rowH,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                border: Border(
                  right: BorderSide(color: Colors.grey.shade400, width: 0.8),
                  bottom: BorderSide(color: Colors.grey.shade300, width: 0.6),
                ),
              ),
              child: Text(
                t['no'] ?? '',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
            ),
            InkWell(
              onTap: () {
                setState(() {
                  _selectedTeacher = t['key']!;
                  _viewMode = 'teacher';
                });
                _loadTimetableData();
              },
              child: Tooltip(
                message: 'คลิกเพื่อดูตารางสอนรายบุคคลของ ${t['formal']}',
                child: Container(
                  width: nameW,
                  height: rowH,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      right: BorderSide(color: Colors.grey.shade400, width: 0.8),
                      bottom: BorderSide(color: Colors.grey.shade300, width: 0.6),
                    ),
                  ),
                  child: Text(
                    t['formal'] ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A237E),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              width: codeW,
              height: rowH,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                border: Border(
                  bottom: BorderSide(color: Colors.grey.shade300, width: 0.6),
                ),
              ),
              child: Text(
                t['code'] ?? '',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.black54),
              ),
            ),
          ],
        ),
      );

      rightScrollableRows.add(
        Row(
          children: [
            ...dayCells,
            Container(
              width: totalW,
              height: rowH,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFE8EAF6),
                border: Border(
                  bottom: BorderSide(color: Colors.grey.shade300, width: 0.6),
                ),
              ),
              child: Text(
                '$totalTeacherPeriods | $totalTeacherPeriods',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A237E),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 3. Bottom Free Teacher Count Summary Row
    final freeCountCells = <Widget>[];
    for (final d in days) {
      final maxP = periodsByDay[d]!;
      for (int p = 1; p <= maxP; p++) {
        int freeCnt = 0;
        for (final t in roster) {
          if (_getTeacherSlotsAt(t, d, p).isEmpty) freeCnt++;
        }
        final isSelectedCol = (_selectedMasterDay == d && _selectedMasterPeriod == p);
        freeCountCells.add(
          InkWell(
            onTap: () => _showFreeTeachersDialog(d, p),
            child: Tooltip(
              message: 'วัน${_dayNames[d]} คาบที่ $p มีครูว่าง $freeCnt ท่าน (คลิกเพื่อดูรายชื่อ)',
              child: Container(
                width: cellW,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelectedCol ? const Color(0xFF2E7D32) : const Color(0xFFE8F5E9),
                  border: Border(
                    top: const BorderSide(color: Color(0xFF2E7D32), width: 1.2),
                    right: BorderSide(
                      color: p == maxP ? Colors.grey.shade700 : const Color(0xFFA5D6A7),
                      width: p == maxP ? 1.4 : 0.6,
                    ),
                  ),
                ),
                child: Text(
                  '$freeCnt',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isSelectedCol ? Colors.white : const Color(0xFF1B5E20),
                  ),
                ),
              ),
            ),
          ),
        );
        if (p == 4) {
          freeCountCells.add(
            Container(
              width: lunchW,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                border: Border(
                  top: const BorderSide(color: Color(0xFF2E7D32), width: 1.2),
                  right: BorderSide(color: Colors.grey.shade400, width: 0.6),
                ),
              ),
            ),
          );
        }
      }
    }

    leftFixedRows.add(
      Container(
        width: fixedLeftW,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerRight,
        decoration: const BoxDecoration(
          color: Color(0xFFE8F5E9),
          borderRadius: BorderRadius.only(bottomLeft: Radius.circular(6)),
          border: Border(
            top: BorderSide(color: Color(0xFF2E7D32), width: 1.2),
          ),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(Icons.people_alt_rounded, size: 15, color: Color(0xFF1B5E20)),
            SizedBox(width: 6),
            Text(
              'จำนวนครูว่างรายคาบ (คลิกดูชื่อ):',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1B5E20),
              ),
            ),
          ],
        ),
      ),
    );

    rightScrollableRows.add(
      Row(
        children: [
          ...freeCountCells,
          Container(
            width: totalW,
            height: 34,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFFE8F5E9),
              borderRadius: BorderRadius.only(bottomRight: Radius.circular(6)),
              border: Border(
                top: BorderSide(color: Color(0xFF2E7D32), width: 1.2),
              ),
            ),
            child: const Text(
              'ท่าน',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
            ),
          ),
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade500, width: 1.2),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pinned / Frozen Left Columns: ที่ | ชื่อ - สกุล | รหัส
          Container(
            width: fixedLeftW + 2,
            decoration: BoxDecoration(
              color: Colors.white,
              border: const Border(
                right: BorderSide(color: Color(0xFF1A237E), width: 2.0),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 6,
                  offset: const Offset(3, 0),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: leftFixedRows,
            ),
          ),
          // Horizontally Scrollable Right Columns: วันจันทร์ - วันศุกร์ | รวม / จริง
          Expanded(
            child: Scrollbar(
              controller: _masterHScrollController,
              thumbVisibility: true,
              trackVisibility: true,
              child: SingleChildScrollView(
                controller: _masterHScrollController,
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rightScrollableRows,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMasterTopHeaderCell(String label, double width, double height) {
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF1A237E),
        border: Border(
          right: BorderSide(color: Colors.white.withValues(alpha: 0.25), width: 1),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          height: 1.2,
        ),
      ),
    );
  }
}

