import '../utils/app_theme.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:url_launcher/url_launcher.dart';

import '../models/course.dart';

import '../models/semester_config.dart';

import '../services/api_service.dart';

import '../widgets/app_3d_button.dart';
import '../widgets/quiz_manager.dart';
import '../widgets/pp5_labels_dialog.dart';



class ScoresScreen extends StatefulWidget {
  final ApiService apiService;
  final Course? initialCourse;
  final bool isDialog;

  const ScoresScreen({
    super.key,
    required this.apiService,
    this.initialCourse,
    this.isDialog = false,
  });



  @override

  State<ScoresScreen> createState() => _ScoresScreenState();

}



typedef ScoreKeyNavHandler = KeyEventResult Function(int row, int col, KeyEvent event);



class _StudentScoreRowState {

  final int studentNo;

  final String studentId;

  final String fullName;

  final double attendancePct;

  final List<TextEditingController> unitCtrls; // 8 units (C..J)

  final TextEditingController midtermCtrl;     // Col L

  final TextEditingController centralExamCtrl; // Col N

  final TextEditingController finalExamCtrl;   // Col O

  final List<FocusNode> unitFocusNodes;

  final FocusNode midtermFocusNode;

  final FocusNode centralExamFocusNode;

  final FocusNode finalExamFocusNode;

  String remark; // '' (auto), 'ร', 'มส', 'มผ', 'ผ'
  final String autoRemark; // 'มส' from the server when attendance can no longer reach 80%
  // Quiz-linked columns: the text as loaded and the slots the teacher had already typed over (server "unit_manual")
  final List<String> loadedUnitText;
  final Set<int> loadedManual;



  _StudentScoreRowState({

    required this.studentNo,

    required this.studentId,

    required this.fullName,

    required this.attendancePct,

    required List<dynamic> units,

    dynamic midterm,

    dynamic centralExam,

    dynamic finalExam,

    required this.remark,
    this.autoRemark = '',
    List<dynamic>? unitManual,

    required int rowIndex,

    required ScoreKeyNavHandler onKeyNav,

  })  : loadedUnitText = List.generate(8, (i) => (i < units.length && units[i] != null) ? _fmtNum(units[i]) : ''),
        loadedManual = {for (final v in unitManual ?? const []) if (v is num && v >= 0 && v < 8) v.toInt()},
        unitCtrls = List.generate(

          8,

          (i) => TextEditingController(

            text: (i < units.length && units[i] != null) ? _fmtNum(units[i]) : '',

          ),

        ),

        unitFocusNodes = List.generate(

          8,

          (i) => FocusNode(

            debugLabel: 's_${rowIndex}_unit_$i',

            onKeyEvent: (node, event) => onKeyNav(rowIndex, i, event),

          ),

        ),

        midtermCtrl = TextEditingController(text: midterm != null ? _fmtNum(midterm) : ''),

        midtermFocusNode = FocusNode(

          debugLabel: 's_${rowIndex}_midterm',

          onKeyEvent: (node, event) => onKeyNav(rowIndex, 8, event),

        ),

        centralExamCtrl = TextEditingController(text: centralExam != null ? _fmtNum(centralExam) : ''),

        centralExamFocusNode = FocusNode(

          debugLabel: 's_${rowIndex}_central',

          onKeyEvent: (node, event) => onKeyNav(rowIndex, 9, event),

        ),

        finalExamCtrl = TextEditingController(text: finalExam != null ? _fmtNum(finalExam) : ''),

        finalExamFocusNode = FocusNode(

          debugLabel: 's_${rowIndex}_final',

          onKeyEvent: (node, event) => onKeyNav(rowIndex, 10, event),

        );



  static String _fmtNum(dynamic v) {

    if (v == null) return '';

    final d = double.tryParse(v.toString());

    if (d == null) return v.toString();

    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();

  }



  static double? _parseNum(String s) {

    final clean = s.trim();

    if (clean.isEmpty) return null;

    return double.tryParse(clean);

  }



  double get formativeTotal {

    double sum = 0;

    for (final c in unitCtrls) {

      final v = _parseNum(c.text);

      if (v != null) sum += v;

    }

    return sum;

  }



  double get betweenTermTotal {

    return formativeTotal + (_parseNum(midtermCtrl.text) ?? 0);

  }



  double get finalTotal {

    return (_parseNum(centralExamCtrl.text) ?? 0) + (_parseNum(finalExamCtrl.text) ?? 0);

  }



  double get totalScore {

    return betweenTermTotal + finalTotal;

  }



  String get calculatedGrade {

    final q = totalScore;

    if (q >= 80) return '4';

    if (q >= 75) return '3.5';

    if (q >= 70) return '3';

    if (q >= 65) return '2.5';

    if (q >= 60) return '2';

    if (q >= 55) return '1.5';

    if (q >= 50) return '1';

    return '0';

  }



  String get effectiveGrade {

    if (remark.trim().isNotEmpty) return remark.trim();
    if (autoRemark.isNotEmpty) return autoRemark;

    return calculatedGrade;

  }



  /// A quiz-linked cell the teacher typed over (kept by the server); an emptied cell goes back to the quiz score.
  bool isUnitManual(int i) {
    final t = unitCtrls[i].text.trim();
    if (t.isEmpty) return false;
    return loadedManual.contains(i) || t != loadedUnitText[i];
  }



  Map<String, dynamic> toJson({Set<int> quizLinked = const {}}) {

    return {

      'student_no': studentNo,

      'student_id': studentId,

      'full_name': fullName,

      'units': unitCtrls.map((c) => _parseNum(c.text)).toList(),
      'unit_manual': [for (int i = 0; i < 8; i++) if (quizLinked.contains(i) && isUnitManual(i)) i],

      'midterm': _parseNum(midtermCtrl.text),

      'central_exam': _parseNum(centralExamCtrl.text),

      'final': _parseNum(finalExamCtrl.text),

      'remark': remark.trim(),

    };

  }



  void dispose() {

    for (final c in unitCtrls) {

      c.dispose();

    }

    for (final f in unitFocusNodes) {

      f.dispose();

    }

    midtermCtrl.dispose();

    midtermFocusNode.dispose();

    centralExamCtrl.dispose();

    centralExamFocusNode.dispose();

    finalExamCtrl.dispose();

    finalExamFocusNode.dispose();

  }

}



class _ScoresScreenState extends State<ScoresScreen> {

  List<SemesterConfigItem> _semesters = [];

  List<Course> _allCourses = [];

  String _selectedSemesterKey = '1-2569';

  String _selectedTeacher = 'all';

  Course? _selectedCourse;
  /// ช่อง 1-8 ที่เชื่อมแบบทดสอบย่อย: "0".."7" -> {quizzes, full, points_max} (ระบบรวมให้ แก้มือไม่ได้)
  Map<String, dynamic> _quizSlots = {};
  // ตัวชี้วัด typed for slots 1-8 (ปพ.5 sheet 4, written upwards); edited in its own dialog, saved at once
  List<String> _indicatorLabels = List.filled(8, '');



  bool _loadingCourses = false;

  bool _loadingSheet = false;

  bool _saving = false;

  bool _hasUnsavedChanges = false;

  String? _error;



  // Header & Row 9 Max Score Controllers

  final TextEditingController _scoreRatioCtrl = TextEditingController(text: '70:30');

  final List<TextEditingController> _unitMaxCtrls = List.generate(8, (_) => TextEditingController());

  final TextEditingController _midtermMaxCtrl = TextEditingController();

  final TextEditingController _centralExamMaxCtrl = TextEditingController();

  final TextEditingController _schoolExamMaxCtrl = TextEditingController();



  // Max score FocusNodes for Row -1 keyboard navigation

  final List<FocusNode> _unitMaxFocusNodes = [];

  FocusNode? _midtermMaxFocusNode;

  FocusNode? _centralExamMaxFocusNode;

  FocusNode? _schoolExamMaxFocusNode;



  // Scroll controllers for Frozen Left Pane + Scrollable Right Pane

  final ScrollController _vLeftCtrl = ScrollController();

  final ScrollController _vRightCtrl = ScrollController();

  final ScrollController _hRightCtrl = ScrollController();

  bool _syncingScroll = false;



  List<_StudentScoreRowState> _studentRows = [];

  final List<bool> _fullScoreColumns = List<bool>.filled(8, false);

  TextEditingController _getMaxCtrlForColumn(int col) {
    if (col >= 0 && col < 8) return _unitMaxCtrls[col];
    if (col == 8) return _midtermMaxCtrl;
    if (col == 9) return _centralExamMaxCtrl;
    return _schoolExamMaxCtrl;
  }

  TextEditingController _getStudentCtrlForColumn(_StudentScoreRowState row, int col) {
    if (col >= 0 && col < 8) return row.unitCtrls[col];
    if (col == 8) return row.midtermCtrl;
    if (col == 9) return row.centralExamCtrl;
    return row.finalExamCtrl;
  }

  void _syncFullScoreColumnFlagsFromData() {
    for (int col = 0; col < 8; col++) {
      final maxVal = _parseNum(_getMaxCtrlForColumn(col).text);
      if (maxVal == null || maxVal <= 0 || _studentRows.isEmpty) {
        _fullScoreColumns[col] = false;
        continue;
      }
      bool allFull = true;
      for (final r in _studentRows) {
        final sVal = _parseNum(_getStudentCtrlForColumn(r, col).text);
        if (sVal == null || (sVal - maxVal).abs() > 0.001) {
          allFull = false;
          break;
        }
      }
      _fullScoreColumns[col] = allFull;
    }
  }

  void _toggleFullScoreColumn(int col, bool checked) {
    if (col < 0 || col >= 8) return;
    setState(() {
      _fullScoreColumns[col] = checked;
      if (checked) {
        final maxVal = _parseNum(_getMaxCtrlForColumn(col).text);
        if (maxVal != null && maxVal > 0) {
          final formatted = _fmtNum(maxVal);
          for (final r in _studentRows) {
            _getStudentCtrlForColumn(r, col).text = formatted;
          }
          _hasUnsavedChanges = true;
        }
      }
    });
  }

  void _onMaxScoreChanged(int col) {
    if (col >= 0 && col < 8 && _fullScoreColumns[col]) {
      final maxVal = _parseNum(_getMaxCtrlForColumn(col).text);
      final formatted = (maxVal != null && maxVal > 0) ? _fmtNum(maxVal) : '0';
      for (final r in _studentRows) {
        _getStudentCtrlForColumn(r, col).text = formatted;
      }
    }
    _onAnyFieldChanged();
  }

  void _onStudentScoreChanged(int col) {
    if (col >= 0 && col < 8 && _fullScoreColumns[col]) {
      final maxVal = _parseNum(_getMaxCtrlForColumn(col).text);
      if (maxVal == null || maxVal <= 0) {
        _fullScoreColumns[col] = false;
      } else {
        for (final r in _studentRows) {
          final sVal = _parseNum(_getStudentCtrlForColumn(r, col).text);
          if (sVal == null || (sVal - maxVal).abs() > 0.001) {
            _fullScoreColumns[col] = false;
            break;
          }
        }
      }
    }
    _onAnyFieldChanged();
  }



  @override
  void initState() {
    super.initState();
    if (widget.initialCourse != null) {
      _selectedSemesterKey = '${widget.initialCourse!.term}-${widget.initialCourse!.year}';
    } else {
      final def = widget.apiService.defaultSemester;
      if (def != null) {
        _selectedSemesterKey = '${def.term}-${def.year}';
      }
    }

    _initMaxScoreFocusNodes();

    _vLeftCtrl.addListener(() => _syncVertical(_vLeftCtrl, _vRightCtrl));

    _vRightCtrl.addListener(() => _syncVertical(_vRightCtrl, _vLeftCtrl));

    _loadInitialData();

  }



  void _initMaxScoreFocusNodes() {

    _disposeMaxScoreFocusNodes();

    for (int i = 0; i < 8; i++) {

      _unitMaxFocusNodes.add(FocusNode(

        debugLabel: 'max_unit_$i',

        onKeyEvent: (node, event) => _handleCellKeyNav(-1, i, event),

      ));

    }

    _midtermMaxFocusNode = FocusNode(

      debugLabel: 'max_midterm',

      onKeyEvent: (node, event) => _handleCellKeyNav(-1, 8, event),

    );

    _centralExamMaxFocusNode = FocusNode(

      debugLabel: 'max_central',

      onKeyEvent: (node, event) => _handleCellKeyNav(-1, 9, event),

    );

    _schoolExamMaxFocusNode = FocusNode(

      debugLabel: 'max_school',

      onKeyEvent: (node, event) => _handleCellKeyNav(-1, 10, event),

    );

  }



  void _disposeMaxScoreFocusNodes() {

    for (final f in _unitMaxFocusNodes) {

      f.dispose();

    }

    _unitMaxFocusNodes.clear();

    _midtermMaxFocusNode?.dispose();

    _midtermMaxFocusNode = null;

    _centralExamMaxFocusNode?.dispose();

    _centralExamMaxFocusNode = null;

    _schoolExamMaxFocusNode?.dispose();

    _schoolExamMaxFocusNode = null;

  }



  bool _isColumnEnabled(int col) {
    if (col >= 0 && col < 8) {
      if (col >= _unitMaxCtrls.length) return false;
      final val = _parseNum(_unitMaxCtrls[col].text);
      return val != null && val > 0;
    } else if (col == 8) {
      final val = _parseNum(_midtermMaxCtrl.text);
      return val != null && val > 0;
    } else if (col == 9) {
      final val = _parseNum(_centralExamMaxCtrl.text);
      return val != null && val > 0;
    } else if (col == 10) {
      final val = _parseNum(_schoolExamMaxCtrl.text);
      return val != null && val > 0;
    }
    return false;
  }

  KeyEventResult _handleCellKeyNav(int row, int col, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _focusCell(row + 1, col);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _focusCell(row - 1, col);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        int targetCol = col - 1;
        if (row >= 0) {
          while (targetCol >= 0 && !_isColumnEnabled(targetCol)) {
            targetCol--;
          }
        }
        if (targetCol >= 0) {
          _focusCell(row, targetCol);
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        int targetCol = col + 1;
        if (row >= 0) {
          while (targetCol <= 10 && !_isColumnEnabled(targetCol)) {
            targetCol++;
          }
        }
        if (targetCol <= 10) {
          _focusCell(row, targetCol);
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        _focusCell(row + 1, col);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        final shift = HardwareKeyboard.instance.isShiftPressed;
        if (shift) {
          int targetCol = col - 1;
          if (row >= 0) {
            while (targetCol >= 0 && !_isColumnEnabled(targetCol)) {
              targetCol--;
            }
          }
          if (targetCol >= 0) {
            _focusCell(row, targetCol);
          }
        } else {
          int targetCol = col + 1;
          if (row >= 0) {
            while (targetCol <= 10 && !_isColumnEnabled(targetCol)) {
              targetCol++;
            }
          }
          if (targetCol <= 10) {
            _focusCell(row, targetCol);
          }
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }



  void _focusCell(int row, int col) {

    if (col < 0) col = 0;
    if (col > 10) col = 10;
    if (row >= 0 && !_isColumnEnabled(col)) return;



    if (_studentRows.isEmpty) {

      if (row != -1) return;

    } else {

      if (row < -1) row = -1;

      if (row >= _studentRows.length) row = _studentRows.length - 1;

    }



    // Auto-scroll vertical to bring row into view

    if (row >= 0 && _vRightCtrl.hasClients) {

      const double rowHeight = 42.0;

      final double targetTop = row * rowHeight;

      final double targetBottom = targetTop + rowHeight;

      final double currentTop = _vRightCtrl.offset;

      final double viewportHeight = _vRightCtrl.position.viewportDimension;

      final double currentBottom = currentTop + viewportHeight;



      if (targetTop < currentTop) {

        _vRightCtrl.jumpTo(targetTop);

      } else if (targetBottom > currentBottom) {

        _vRightCtrl.jumpTo(targetBottom - viewportHeight);

      }

    }



    // Auto-scroll horizontal to bring cell column into view

    if (_hRightCtrl.hasClients) {

      double cellLeft = 0;

      double cellWidth = 60;

      if (col < 8) {

        cellLeft = col * 60.0;

        cellWidth = 60.0;

      } else if (col == 8) {

        cellLeft = 480.0 + 66.0;

        cellWidth = 66.0;

      } else if (col == 9) {

        cellLeft = 480.0 + 66.0 + 66.0 + 66.0;

        cellWidth = 70.0;

      } else if (col == 10) {

        cellLeft = 480.0 + 66.0 + 66.0 + 66.0 + 70.0;

        cellWidth = 70.0;

      }



      final double hCurrentLeft = _hRightCtrl.offset;

      final double hViewportWidth = _hRightCtrl.position.viewportDimension;

      final double hCurrentRight = hCurrentLeft + hViewportWidth;



      if (cellLeft < hCurrentLeft) {

        _hRightCtrl.jumpTo(cellLeft);

      } else if (cellLeft + cellWidth > hCurrentRight) {

        _hRightCtrl.jumpTo((cellLeft + cellWidth) - hViewportWidth);

      }

    }



    FocusNode? targetFocusNode;

    TextEditingController? targetCtrl;



    if (row == -1) {

      if (col < 8 && col < _unitMaxFocusNodes.length) {

        targetFocusNode = _unitMaxFocusNodes[col];

        targetCtrl = _unitMaxCtrls[col];

      } else if (col == 8) {

        targetFocusNode = _midtermMaxFocusNode;

        targetCtrl = _midtermMaxCtrl;

      } else if (col == 9) {

        targetFocusNode = _centralExamMaxFocusNode;

        targetCtrl = _centralExamMaxCtrl;

      } else if (col == 10) {

        targetFocusNode = _schoolExamMaxFocusNode;

        targetCtrl = _schoolExamMaxCtrl;

      }

    } else if (row >= 0 && row < _studentRows.length) {

      final sRow = _studentRows[row];

      if (col < 8 && col < sRow.unitFocusNodes.length) {

        targetFocusNode = sRow.unitFocusNodes[col];

        targetCtrl = sRow.unitCtrls[col];

      } else if (col == 8) {

        targetFocusNode = sRow.midtermFocusNode;

        targetCtrl = sRow.midtermCtrl;

      } else if (col == 9) {

        targetFocusNode = sRow.centralExamFocusNode;

        targetCtrl = sRow.centralExamCtrl;

      } else if (col == 10) {

        targetFocusNode = sRow.finalExamFocusNode;

        targetCtrl = sRow.finalExamCtrl;

      }

    }



    if (targetFocusNode != null && targetCtrl != null) {
      final node = targetFocusNode;
      final ctrl = targetCtrl;

      void applyFocus() {

        if (node.canRequestFocus) {

          node.requestFocus();

          ctrl.selection = TextSelection(

            baseOffset: 0,

            extentOffset: ctrl.text.length,

          );

        }

      }



      applyFocus();

      WidgetsBinding.instance.addPostFrameCallback((_) => applyFocus());

    }

  }



  void _syncVertical(ScrollController from, ScrollController to) {

    if (_syncingScroll || !from.hasClients || !to.hasClients) return;

    if ((to.offset - from.offset).abs() < 0.5) return;

    _syncingScroll = true;

    to.jumpTo(from.offset.clamp(0.0, to.position.maxScrollExtent));

    _syncingScroll = false;

  }



  @override

  void dispose() {
    _disposeMaxScoreFocusNodes();

    _vLeftCtrl.dispose();

    _vRightCtrl.dispose();

    _hRightCtrl.dispose();

    _scoreRatioCtrl.dispose();

    for (final c in _unitMaxCtrls) {

      c.dispose();

    }

    _midtermMaxCtrl.dispose();

    _centralExamMaxCtrl.dispose();

    _schoolExamMaxCtrl.dispose();

    for (final r in _studentRows) {

      r.dispose();

    }

    super.dispose();

  }



  static double? _parseNum(String s) {

    final clean = s.trim();

    if (clean.isEmpty) return null;

    return double.tryParse(clean);

  }



  static String _fmtNum(num v) {

    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  }



  double get _formativeMax {

    double sum = 0;

    for (final c in _unitMaxCtrls) {

      final v = _parseNum(c.text);

      if (v != null) sum += v;

    }

    return sum;

  }



  double get _betweenTermMax => _formativeMax + (_parseNum(_midtermMaxCtrl.text) ?? 0);

  double get _finalMax => (_parseNum(_centralExamMaxCtrl.text) ?? 0) + (_parseNum(_schoolExamMaxCtrl.text) ?? 0);

  double get _totalMax => _betweenTermMax + _finalMax;



  Future<void> _loadInitialData() async {

    setState(() {

      _loadingCourses = true;

      _error = null;

    });

    try {

      final results = await Future.wait([

        widget.apiService.getSemesterConfigs(),

        widget.apiService.getCourses(),

      ]);

      final sems = results[0] as List<SemesterConfigItem>;

      final courses = results[1] as List<Course>;



      String initialSem = _selectedSemesterKey;
      if (widget.initialCourse != null) {
        initialSem = '${widget.initialCourse!.term}-${widget.initialCourse!.year}';
      } else if (sems.isNotEmpty) {
        final defSem = sems.firstWhere(
          (s) => s.isDefault,
          orElse: () => sems.firstWhere((s) => s.isActive, orElse: () => sems.first),
        );
        initialSem = '${defSem.term}-${defSem.year}';
      }



      if (mounted) {

        setState(() {

          _semesters = sems;

          _allCourses = courses;

          _selectedSemesterKey = initialSem;

          _loadingCourses = false;

        });

        _pickDefaultCourse();

      }

    } catch (e) {

      if (mounted) {

        setState(() {

          _error = e.toString();

          _loadingCourses = false;

        });

      }

    }

  }



  List<Course> get _coursesInSemester {

    final parts = _selectedSemesterKey.split('-');

    List<Course> list = _allCourses;

    if (parts.length == 2) {

      list = list.where((c) => c.term == parts[0] && c.year == parts[1]).toList();

    }

    final user = widget.apiService.currentUser;

    if (user != null && !user.isAdmin) {

      list = list.where((c) => user.canManageCourse(c)).toList();

    }

    return list;

  }



  List<String> get _teachersInSemester {

    final set = <String>{};

    for (final c in _coursesInSemester) {

      final t = (c.teacher ?? '').trim();

      if (t.isNotEmpty) set.add(t);

    }

    final list = set.toList()..sort();

    return list;

  }



  List<Course> get _filteredCourses {

    final base = _coursesInSemester;

    if (_selectedTeacher == 'all') return base;

    return base.where((c) => (c.teacher ?? '').trim() == _selectedTeacher).toList();

  }



  void _pickDefaultCourse() {
    if (widget.initialCourse != null) {
      final match = _allCourses.firstWhere(
        (c) =>
            c.courseCode == widget.initialCourse!.courseCode &&
            c.term == widget.initialCourse!.term &&
            c.year == widget.initialCourse!.year,
        orElse: () => widget.initialCourse!,
      );
      _selectCourse(match);
      return;
    }
    final list = _filteredCourses;

    if (list.isEmpty) {

      setState(() {

        _selectedCourse = null;

        _clearStudentRows();

      });

      return;

    }

    if (_selectedCourse == null ||

        !list.any((c) =>

            c.courseCode == _selectedCourse!.courseCode &&

            c.term == _selectedCourse!.term &&

            c.year == _selectedCourse!.year)) {

      _selectCourse(list.first);

    }

  }



  void _clearStudentRows() {

    for (final r in _studentRows) {

      r.dispose();

    }

    _studentRows = [];

    _hasUnsavedChanges = false;

  }



  Future<void> _selectCourse(Course course) async {

    setState(() {

      _selectedCourse = course;

      _loadingSheet = true;

      _error = null;

    });

    try {

      final data = await widget.apiService.getCourseScoresSheet(

        courseCode: course.courseCode,

        term: course.term,

        year: course.year,

      );

      final courseInfo = (data['course'] as Map<String, dynamic>?) ?? {};

      final cfg = (data['score_config'] as Map<String, dynamic>?) ?? {};

      final studentsList = (data['students'] as List?) ?? [];



      _scoreRatioCtrl.text = (courseInfo['score_ratio'] ?? '70:30').toString();



      final uMax = (cfg['unit_max'] as List?) ?? [];

      for (int i = 0; i < 8; i++) {

        final v = i < uMax.length ? uMax[i] : null;

        _unitMaxCtrls[i].text = v != null ? _StudentScoreRowState._fmtNum(v) : '';

      }

      _midtermMaxCtrl.text = cfg['midterm_max'] != null ? _StudentScoreRowState._fmtNum(cfg['midterm_max']) : '';

      _centralExamMaxCtrl.text =

          cfg['central_exam_max'] != null ? _StudentScoreRowState._fmtNum(cfg['central_exam_max']) : '';

      _schoolExamMaxCtrl.text =

          cfg['school_exam_max'] != null ? _StudentScoreRowState._fmtNum(cfg['school_exam_max']) : '';



      _clearStudentRows();

      final rows = <_StudentScoreRowState>[];

      for (final raw in studentsList) {

        final m = raw as Map<String, dynamic>;

        rows.add(

          _StudentScoreRowState(

            studentNo: (m['student_no'] as num?)?.toInt() ?? (rows.length + 1),

            studentId: (m['student_id'] ?? '').toString(),

            fullName: (m['full_name'] ?? '').toString(),

            attendancePct: (m['attendance_pct'] as num?)?.toDouble() ?? 100.0,

            units: (m['units'] as List?) ?? [],
            unitManual: m['unit_manual'] as List?,

            midterm: m['midterm'],

            centralExam: m['central_exam'],

            finalExam: m['final'],

            remark: (m['remark'] ?? '').toString(),
            autoRemark: (m['auto_remark'] ?? '').toString(),

            rowIndex: rows.length,

            onKeyNav: _handleCellKeyNav,

          ),

        );

      }



      Map<String, dynamic> quizSlots = {};
      try {
        quizSlots = await widget.apiService.getQuizLinkedSlots(course.courseCode, course.term, course.year);
      } catch (_) {}
      if (mounted) {

        setState(() {

          _quizSlots = quizSlots;
          _indicatorLabels = List.generate(8, (i) {
            final l = (data['indicator_labels'] as List?) ?? const [];
            return i < l.length ? (l[i]?.toString() ?? '') : '';
          });
          _studentRows = rows;

          _syncFullScoreColumnFlagsFromData();

          _loadingSheet = false;

          _hasUnsavedChanges = false;

        });

      }

    } catch (e) {

      if (mounted) {

        setState(() {

          _error = e.toString();

          _loadingSheet = false;

        });

      }

    }

  }



  Future<void> _saveScores() async {

    final course = _selectedCourse;

    if (course == null) return;



    setState(() {

      _saving = true;

      _error = null;

    });



    try {

      final scoreConfig = {

        'unit_max': _unitMaxCtrls.map((c) => _parseNum(c.text)).toList(),

        'midterm_max': _parseNum(_midtermMaxCtrl.text),

        'central_exam_max': _parseNum(_centralExamMaxCtrl.text),

        'school_exam_max': _parseNum(_schoolExamMaxCtrl.text),

      };
      final quizLinked = {for (final k in _quizSlots.keys) if (int.tryParse(k) != null) int.parse(k)};



      final res = await widget.apiService.saveCourseScoresSheet(

        courseCode: course.courseCode,

        term: course.term,

        year: course.year,

        scoreRatio: _scoreRatioCtrl.text.trim(),

        scoreConfig: scoreConfig,

        students: _studentRows.map((r) => r.toJson(quizLinked: quizLinked)).toList(),

      );



      if (mounted) {

        setState(() {

          _saving = false;

          _hasUnsavedChanges = false;

        });

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: const Color(0xFF1E6B45),

            content: Text(res['message']?.toString() ?? 'บันทึกคะแนนและอัปเดตไฟล์ ปพ.5 เรียบร้อยแล้ว'),

          ),

        );
        // Quiz-linked columns: an emptied cell is filled again from the quizzes on the server -> show what was saved
        if (quizLinked.isNotEmpty && _selectedCourse == course) _selectCourse(course);

      }

    } catch (e) {

      if (mounted) {

        setState(() {

          _saving = false;

        });

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.red.shade700,

            content: Text('เกิดข้อผิดพลาด: $e'),

          ),

        );

      }

    }

  }



  Future<void> _downloadExcel() async {

    final course = _selectedCourse;

    if (course == null) return;

    if (_hasUnsavedChanges) {

      await _saveScores();

    }

    final url = widget.apiService.getCourseFileUrl(

      course.courseCode,

      format: 'excel',

      term: course.term,

      year: course.year,

    );

    final uri = Uri.parse(url);

    await launchUrl(uri, mode: LaunchMode.externalApplication);

  }



  void _onAnyFieldChanged() {

    setState(() {

      _hasUnsavedChanges = true;

    });

  }



  Color _gradeTextColor(String grade, ThemeData theme) {

    switch (grade) {

      case '4':

      case '3.5':

      case 'ผ':

        return const Color(0xFF1E6B45);

      case '3':

      case '2.5':

        return const Color(0xFF1A237E);

      case '2':

      case '1.5':

      case '1':

        return const Color(0xFF8A4F2C);

      case '0':

      case 'ร':

      case 'มส':

      case 'มผ':

        return const Color(0xFFB71C1C);

      default:

        return theme.colorScheme.onSurface;

    }

  }



  @override

  Widget build(BuildContext context) {

    final theme = Theme.of(context);

    final cs = theme.colorScheme;

    final user = widget.apiService.currentUser;
    if (user != null && !user.canAccessScores) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.gold, width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.gold, width: 2),
                ),
                child: const Icon(Icons.lock_rounded, size: 52, color: Color(0xFFB45309)),
              ),
              const SizedBox(height: 20),
              const Text(
                'ล็อกการเข้าถึงหน้าบันทึกคะแนน',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Sarabun',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF78350F),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                user.isDirector
                    ? 'หน้าบันทึกคะแนนสงวนสิทธิ์เฉพาะครูผู้สอนประจำวิชาเท่านั้น สำหรับท่านผู้อำนวยการสามารถดูผลการเรียนและสถิติภาพรวมได้จากหน้าแดชบอร์ดและคลังข้อมูล'
                    : 'หน้านี้สงวนสิทธิ์เฉพาะคุณครูผู้สอนประจำวิชาเท่านั้น สำหรับบุคคลทั่วไปสามารถดูข้อมูลภาพรวมได้จากหน้าแดชบอร์ด',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Sarabun',
                  fontSize: 14.5,
                  color: Colors.grey.shade700,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 750;
        final isMobile = constraints.maxWidth < 500;
        final hPad = isMobile ? 12.0 : (isNarrow ? 16.0 : 24.0);
        final vPad = isMobile ? 12.0 : (isNarrow ? 16.0 : 24.0);

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.isDialog) ...[
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.fact_check_rounded, color: cs.primary, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'บันทึกและตรวจคะแนน: ${_selectedCourse?.courseName ?? widget.initialCourse?.courseName ?? ""} (${_selectedCourse?.courseCode ?? widget.initialCourse?.courseCode ?? ""})',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'ระดับชั้น: ${_selectedCourse?.classLevel ?? widget.initialCourse?.classLevel ?? "-"} | ภาคเรียนที่ ${_selectedCourse?.term ?? widget.initialCourse?.term ?? ""}/${_selectedCourse?.year ?? widget.initialCourse?.year ?? ""} | ครูผู้สอน: ${_selectedCourse?.teacher ?? widget.initialCourse?.teacher ?? "-"}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'ปิดหน้าต่าง',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(height: 24),
          ],
          // ===================================================================
          // Header & Primary Actions (Responsive Layout)
          // ===================================================================
          Builder(
            builder: (context) {
              final titleBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'บันทึกคะแนนตามตัวชี้วัด / ผลการเรียนรู้ (ปพ.5 แผ่นที่ 4)',
                    style: (isMobile
                            ? theme.textTheme.titleMedium
                            : (isNarrow ? theme.textTheme.titleLarge : theme.textTheme.headlineSmall))
                        ?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'แสดงและแก้ไขคะแนนจาก SGS หรือกรอกคะแนนใหม่ พร้อมเชื่อมสถานะเวลาเรียน (<80% สีส้มอ่อน, <60% สีแดงอ่อน)',
                    style: (isMobile ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              );

              final actionButtons = Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  App3DButton.secondary(
                    onPressed: _selectedCourse == null || _saving ? null : _openQuizLinks,
                    icon: Icons.assignment_outlined,
                    label: _quizSlots.isEmpty ? 'คะแนนแบบทดสอบย่อย' : 'คะแนนแบบทดสอบย่อย (${_quizSlots.length} ช่อง)',
                    depth: 3.0,
                  ),
                  App3DButton.secondary(
                    onPressed: _selectedCourse == null || _saving ? null : _downloadExcel,
                    icon: Icons.table_view_outlined,
                    label: 'ดาวน์โหลด Excel ปพ.5',
                    depth: 3.0,
                  ),
                  _hasUnsavedChanges
                      ? App3DButton.success(
                          onPressed: _selectedCourse == null || _saving ? null : _saveScores,
                          icon: Icons.save_outlined,
                          label: _saving ? 'กำลังบันทึก...' : 'บันทึกคะแนน & อัปเดตไฟล์ ปพ.5 *',
                          isLoading: _saving,
                          depth: 3.5,
                        )
                      : App3DButton.primary(
                          onPressed: _selectedCourse == null || _saving ? null : _saveScores,
                          icon: Icons.save_outlined,
                          label: _saving ? 'กำลังบันทึก...' : 'บันทึกคะแนน & อัปเดตไฟล์ ปพ.5',
                          isLoading: _saving,
                          depth: 3.5,
                        ),
                ],
              );

              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titleBlock,
                    const SizedBox(height: 12),
                    actionButtons,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: titleBlock),
                  const SizedBox(width: 16),
                  actionButtons,
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          // ===================================================================

          // Filter Bar: Semester -> Teacher -> Course -> Score Ratio

          // ===================================================================

          Container(

            padding: const EdgeInsets.all(14),

            decoration: BoxDecoration(

              color: cs.surfaceContainerLow,

              borderRadius: BorderRadius.circular(12),

              border: Border.all(color: cs.outlineVariant),

            ),

            child: Wrap(

              spacing: 12,

              runSpacing: 12,

              crossAxisAlignment: WrapCrossAlignment.center,

              children: [

                // 1. Semester Dropdown

                SizedBox(

                  width: isNarrow ? (constraints.maxWidth - (hPad * 2) - (isMobile ? 20 : 28)).clamp(180.0, 500.0) : 240,

                  child: DropdownButtonFormField<String>(

                    value: _semesters.any((s) => '${s.term}-${s.year}' == _selectedSemesterKey)

                        ? _selectedSemesterKey

                        : null,

                    isExpanded: true,

                    decoration: const InputDecoration(

                      labelText: 'ภาคเรียน / ปีการศึกษา',

                      border: OutlineInputBorder(),

                      isDense: true,

                      prefixIcon: Icon(Icons.calendar_today_outlined, size: 18),

                    ),

                    items: _semesters.map((s) {

                      final key = '${s.term}-${s.year}';

                      return DropdownMenuItem(

                        value: key,

                        child: Text(s.title, overflow: TextOverflow.ellipsis),

                      );

                    }).toList(),

                    onChanged: (val) {

                      if (val != null) {

                        setState(() {

                          _selectedSemesterKey = val;

                          _selectedTeacher = 'all';

                          _selectedCourse = null;

                        });

                        _pickDefaultCourse();

                      }

                    },

                  ),

                ),



                // 2. Teacher Dropdown

                SizedBox(

                  width: isNarrow ? (constraints.maxWidth - (hPad * 2) - (isMobile ? 20 : 28)).clamp(180.0, 500.0) : 250,

                  child: DropdownButtonFormField<String>(

                    value: _teachersInSemester.contains(_selectedTeacher) ? _selectedTeacher : 'all',

                    isExpanded: true,

                    decoration: const InputDecoration(

                      labelText: 'ครูผู้สอน',

                      border: OutlineInputBorder(),

                      isDense: true,

                      prefixIcon: Icon(Icons.person_outline, size: 18),

                    ),

                    items: [

                      DropdownMenuItem(

                        value: 'all',

                        child: Text('ครูทั้งหมด (${_coursesInSemester.length} วิชา)'),

                      ),

                      ..._teachersInSemester.map((t) {

                        final cnt = _coursesInSemester.where((c) => (c.teacher ?? '').trim() == t).length;

                        return DropdownMenuItem(

                          value: t,

                          child: Text('$t ($cnt วิชา)', overflow: TextOverflow.ellipsis),

                        );

                      }),

                    ],

                    onChanged: (val) {

                      if (val != null) {

                        setState(() {

                          _selectedTeacher = val;

                          _selectedCourse = null;

                        });

                        _pickDefaultCourse();

                      }

                    },

                  ),

                ),



                // 3. Course Dropdown

                SizedBox(

                  width: isNarrow ? (constraints.maxWidth - (hPad * 2) - (isMobile ? 20 : 28)).clamp(180.0, 500.0) : 340,

                  child: DropdownButtonFormField<String>(

                    value: _selectedCourse != null &&

                            _filteredCourses.any((c) => c.courseCode == _selectedCourse!.courseCode)

                        ? _selectedCourse!.courseCode

                        : null,

                    isExpanded: true,

                    decoration: const InputDecoration(

                      labelText: 'เลือกรายวิชาที่ต้องการกรอกคะแนน',

                      border: OutlineInputBorder(),

                      isDense: true,

                      prefixIcon: Icon(Icons.menu_book_outlined, size: 18),

                    ),

                    items: _filteredCourses.map((c) {

                      final lvl = (c.classLevel ?? '').isNotEmpty ? ' (${c.classLevel})' : '';

                      return DropdownMenuItem(

                        value: c.courseCode,

                        child: Text(

                          '${c.courseCode} ${c.courseName}$lvl',

                          overflow: TextOverflow.ellipsis,

                        ),

                      );

                    }).toList(),

                    onChanged: (code) {

                      if (code != null) {

                        final found = _filteredCourses.firstWhere((c) => c.courseCode == code);

                        _selectCourse(found);

                      }

                    },

                  ),

                ),



                // 4. Score Ratio Input (e.g. 70:30, 80:20)

                SizedBox(

                  width: 145,

                  child: TextField(

                    controller: _scoreRatioCtrl,

                    onChanged: (_) => _onAnyFieldChanged(),

                    decoration: const InputDecoration(

                      labelText: 'อัตราส่วนคะแนน',

                      hintText: 'เช่น 70:30, 80:20',

                      border: OutlineInputBorder(),

                      isDense: true,

                    ),

                  ),

                ),



                // 5. Total Max Indicator Badge

                Container(

                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                  decoration: BoxDecoration(

                    color: _totalMax == 100

                        ? const Color(0xFF1E6B45).withValues(alpha: 0.1)

                        : const Color(0xFFA8342A).withValues(alpha: 0.1),

                    borderRadius: BorderRadius.circular(8),

                    border: Border.all(

                      color: _totalMax == 100 ? const Color(0xFF1E6B45) : const Color(0xFFA8342A),

                    ),

                  ),

                  child: Row(

                    mainAxisSize: MainAxisSize.min,

                    children: [

                      Icon(

                        _totalMax == 100 ? Icons.check_circle_outline : Icons.warning_amber_rounded,

                        size: 18,

                        color: _totalMax == 100 ? const Color(0xFF1E6B45) : const Color(0xFFA8342A),

                      ),

                      const SizedBox(width: 6),

                      Text(

                        'คะแนนเต็มรวม: ${_fmtNum(_totalMax)} / 100',

                        style: TextStyle(

                          fontWeight: FontWeight.w700,

                          fontSize: 13,

                          color: _totalMax == 100 ? const Color(0xFF1E6B45) : const Color(0xFFA8342A),

                        ),

                      ),

                    ],

                  ),

                ),

              ],

            ),

          ),

          const SizedBox(height: 14),



          // ===================================================================

          // Main Score Grid (Frozen Left Columns + Scrollable Right Columns)

          // ===================================================================

          Expanded(

            child: _loadingCourses || _loadingSheet

                ? const Center(child: CircularProgressIndicator())

                : _error != null

                    ? Center(

                        child: Column(

                          mainAxisSize: MainAxisSize.min,

                          children: [

                            Icon(Icons.error_outline, size: 48, color: cs.error),

                            const SizedBox(height: 12),

                            Text(_error!, style: TextStyle(color: cs.error)),

                            const SizedBox(height: 12),

                            FilledButton.icon(

                              onPressed: _selectedCourse != null

                                  ? () => _selectCourse(_selectedCourse!)

                                  : _loadInitialData,

                              icon: const Icon(Icons.refresh),

                              label: const Text('ลองใหม่'),

                            ),

                          ],

                        ),

                      )

                    : _selectedCourse == null

                        ? Center(

                            child: Column(

                              mainAxisSize: MainAxisSize.min,

                              children: [

                                Icon(

                                  Icons.menu_book_outlined,

                                  size: 48,

                                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),

                                ),

                                const SizedBox(height: 12),

                                Text(

                                  _coursesInSemester.isEmpty

                                      ? 'ไม่พบรายวิชาที่ท่านสอนในภาคเรียนนี้'

                                      : 'กรุณาเลือกรายวิชาเพื่อบันทึกคะแนน',

                                  style: TextStyle(

                                    color: theme.colorScheme.onSurfaceVariant,

                                    fontSize: 16,

                                  ),

                                ),

                              ],

                            ),

                          )

                        : _buildExcelScoreSheet(theme),

          ),

        ],

      ),

    );
      },
    );

  }



  Widget _buildExcelScoreSheet(ThemeData theme) {

    final cs = theme.colorScheme;

    final headerBg = cs.surfaceContainerHighest;

    final formulaBg = cs.surfaceContainerLow;

    final borderColor = cs.outlineVariant;

    final maxRowBg = cs.primaryContainer.withValues(alpha: 0.35);



    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 750;
    final double colNo = isCompact ? 38 : 52;
    final double colId = isCompact ? 68 : 80;
    final double colName = isCompact ? 150 : 220;
    final double frozenWidth = colNo + colId + colName;

    const double rightWidth = 480 + 198 + 206 + 68 + 96; // 1048px

    const double rowHeight = 42;



    return Container(

      decoration: BoxDecoration(

        color: cs.surface,

        borderRadius: BorderRadius.circular(12),

        border: Border.all(color: borderColor),

      ),

      clipBehavior: Clip.antiAlias,

      child: Row(

        crossAxisAlignment: CrossAxisAlignment.stretch,

        children: [

          // ===================================================================

          // FROZEN LEFT PANE: เลขที่ | รหัส | ชื่อ - สกุล

          // ===================================================================

          SizedBox(

            width: frozenWidth,

            child: Column(

              children: [

                Container(

                  decoration: BoxDecoration(

                    color: headerBg,

                    border: Border(bottom: BorderSide(color: borderColor, width: 1.2)),

                  ),

                  child: Column(

                    children: [

                      SizedBox(

                        height: 36,

                        child: Row(

                          children: [

                            _headerCell('เลขที่', colNo, borderColor),

                            _headerCell('รหัส', colId, borderColor),

                            _headerCell('ชื่อ - สกุล', colName, borderColor, isLast: true),

                          ],

                        ),

                      ),

                      Divider(height: 1, thickness: 1, color: borderColor),

                      SizedBox(

                        height: 36,

                        child: Row(

                          children: [

                            _headerCell('', colNo, borderColor),

                            _headerCell('นักเรียน', colId, borderColor),

                            _headerCell(isCompact ? '(ล็อกชื่อ)' : '(ล็อกชื่อ-สกุลขณะเลื่อนกรอกคะแนน)', colName, borderColor, isLast: true),

                          ],

                        ),

                      ),

                      Divider(height: 1, thickness: 1, color: borderColor),

                      Container(

                        height: 42,

                        color: maxRowBg,

                        child: Row(

                          children: [

                            _headerCell('-', colNo, borderColor),

                            _headerCell('-', colId, borderColor),

                            _headerCell(isCompact ? 'คะแนนเต็ม' : 'คะแนนเต็ม (แก้ไขได้)', colName, borderColor, alignLeft: true, isLast: true),

                          ],

                        ),

                      ),

                      Divider(height: 1, thickness: 1, color: borderColor),

                      Container(

                        height: 36,

                        color: const Color(0xFFE8F5E9),

                        child: Row(

                          children: [

                            _headerCell('-', colNo, borderColor),

                            _headerCell('-', colId, borderColor),

                            _headerCell(isCompact ? 'คะแนนเต็มรวม' : 'คะแนนเต็มทั้งหมด (ติ๊กรายช่อง)', colName, borderColor, alignLeft: true, isLast: true),

                          ],

                        ),

                      ),

                    ],

                  ),

                ),

                Expanded(

                  child: _studentRows.isEmpty

                      ? const Center(child: Text('ไม่มีรายชื่อ'))

                      : ScrollConfiguration(

                          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),

                          child: ListView.builder(

                            controller: _vLeftCtrl,

                            itemCount: _studentRows.length,

                            itemExtent: rowHeight,

                            itemBuilder: (ctx, idx) {

                              final row = _studentRows[idx];

                              final rowBg = idx.isOdd

                                  ? cs.onSurface.withValues(alpha: 0.02)

                                  : Colors.transparent;

                              return Container(

                                decoration: BoxDecoration(

                                  color: rowBg,

                                  border: Border(bottom: BorderSide(color: borderColor.withValues(alpha: 0.6))),

                                ),

                                child: Row(

                                  children: [

                                    _staticTextCell('${row.studentNo}', colNo, borderColor, alignCenter: true),

                                    _staticTextCell(row.studentId, colId, borderColor, alignCenter: true),

                                    _staticTextCell(row.fullName, colName, borderColor, bold: true, isLast: true),

                                  ],

                                ),

                              );

                            },

                          ),

                        ),

                ),

              ],

            ),

          ),



          // Pinned vertical divider separating frozen student names from scrollable scores

          Container(width: 1.5, color: cs.primary.withValues(alpha: 0.25)),



          // ===================================================================

          // SCROLLABLE RIGHT PANE: ตัวชี้วัด 1–8 | ระหว่างภาค | ปลายภาค | ทั้งหมด | ผลการประเมิน

          // ===================================================================

          Expanded(

            child: Scrollbar(

              controller: _hRightCtrl,

              thumbVisibility: true,

              child: SingleChildScrollView(

                controller: _hRightCtrl,

                scrollDirection: Axis.horizontal,

                child: SizedBox(

                  width: rightWidth,

                  child: Column(

                    children: [

                      // Right Top Headers

                      Container(

                        decoration: BoxDecoration(

                          color: headerBg,

                          border: Border(bottom: BorderSide(color: borderColor, width: 1.2)),

                        ),

                        child: Column(

                          children: [

                            // Row A: Major Group Headers

                            SizedBox(

                              height: 36,

                              child: Row(

                                children: [

                                  _headerCell('ตัวชี้วัด / ผลการเรียนรู้ (ช่องที่ 1 – 8)', 480, borderColor),

                                  _headerCell('ระหว่างภาค', 198, borderColor),

                                  _headerCell('ปลายภาค', 206, borderColor),

                                  _headerCell('ทั้งหมด', 68, borderColor),

                                  _headerCell('ผลการประเมิน', 96, borderColor, isLast: true),

                                ],

                              ),

                            ),

                            Divider(height: 1, thickness: 1, color: borderColor),

                            // Row B: Sub-Column Headers

                            SizedBox(

                              height: 36,

                              child: Row(

                                children: [

                                  for (int i = 1; i <= 8; i++) _slotHeaderCell(i, borderColor),

                                  _headerCell('รายข้อ', 66, borderColor, isFormula: true),

                                  _headerCell('กลางภาค', 66, borderColor),

                                  _headerCell('รวม', 66, borderColor, isFormula: true),

                                  _headerCell('ข้อสอบกลาง', 70, borderColor),

                                  _headerCell('ข้อสอบ รร.', 70, borderColor),

                                  _headerCell('รวม', 66, borderColor, isFormula: true),

                                  _headerCell('รวม 100', 68, borderColor, isFormula: true),

                                  _headerCell('', 96, borderColor, isLast: true),

                                ],

                              ),

                            ),

                            Divider(height: 1, thickness: 1, color: borderColor),

                            // Row C: Row 9 Max Scores Row

                            Container(

                              height: 42,

                              color: maxRowBg,

                              child: Row(

                                children: [

                                  for (int i = 0; i < 8; i++)

                                    _editableMaxCell(_unitMaxCtrls[i], i < _unitMaxFocusNodes.length ? _unitMaxFocusNodes[i] : null, 60, borderColor, colIndex: i),

                                  _formulaCell(_fmtNum(_formativeMax), 66, borderColor, bold: true),

                                  _editableMaxCell(_midtermMaxCtrl, _midtermMaxFocusNode, 66, borderColor, colIndex: 8),

                                  _formulaCell(_fmtNum(_betweenTermMax), 66, borderColor, bold: true),

                                  _editableMaxCell(_centralExamMaxCtrl, _centralExamMaxFocusNode, 70, borderColor, colIndex: 9),

                                  _editableMaxCell(_schoolExamMaxCtrl, _schoolExamMaxFocusNode, 70, borderColor, colIndex: 10),

                                  _formulaCell(_fmtNum(_finalMax), 66, borderColor, bold: true),

                                  _formulaCell(_fmtNum(_totalMax), 68, borderColor, bold: true, highlightTotal: true),

                                  _headerCell('', 96, borderColor, isLast: true),

                                ],

                              ),

                            ),

                            Divider(height: 1, thickness: 1, color: borderColor),

                            // Row D: Per-Column Full Score Checkboxes Row

                            Container(

                              height: 36,

                              color: const Color(0xFFE8F5E9),

                              child: Row(

                                children: [

                                  for (int i = 0; i < 8; i++)

                                    _fullScoreCheckCell(i, 60, borderColor),

                                  _formulaCell('', 66, borderColor),

                                  _formulaCell('', 66, borderColor),

                                  _formulaCell('', 66, borderColor),

                                  _formulaCell('', 70, borderColor),

                                  _formulaCell('', 70, borderColor),

                                  _formulaCell('', 66, borderColor),

                                  _formulaCell('', 68, borderColor),

                                  _headerCell('', 96, borderColor, isLast: true),

                                ],

                              ),

                            ),

                          ],

                        ),

                      ),



                      // Right Student Score Rows

                      Expanded(

                        child: _studentRows.isEmpty

                            ? const Center(

                                child: Text('ยังไม่มีรายชื่อนักเรียนในระดับชั้นนี้'),

                              )

                            : Scrollbar(

                                controller: _vRightCtrl,

                                thumbVisibility: true,

                                child: ListView.builder(

                                  controller: _vRightCtrl,

                                  itemCount: _studentRows.length,

                                  itemExtent: rowHeight,

                                  itemBuilder: (ctx, idx) {

                                    final row = _studentRows[idx];

                                    final rowBg = idx.isOdd

                                        ? cs.onSurface.withValues(alpha: 0.02)

                                        : Colors.transparent;



                                    return Container(

                                      decoration: BoxDecoration(

                                        color: rowBg,

                                        border: Border(bottom: BorderSide(color: borderColor.withValues(alpha: 0.6))),

                                      ),

                                      child: Row(

                                        children: [

                                          // 8 Unit score inputs (Cols C..J)

                                          // A quiz-linked column is filled automatically but stays editable:
                                          // a typed cell is kept by the server (unit_manual), an emptied one is automatic again
                                          for (int i = 0; i < 8; i++)
                                            _editableScoreCell(
                                              row.unitCtrls[i],
                                              i < row.unitFocusNodes.length ? row.unitFocusNodes[i] : null,
                                              60,
                                              borderColor,
                                              maxVal: _parseNum(_unitMaxCtrls[i].text),
                                              isEnabled: _isColumnEnabled(i),
                                              colIndex: i,
                                              quizSlot: _quizSlots.containsKey('$i'),
                                              quizManual: _quizSlots.containsKey('$i') && row.isUnitManual(i),
                                            ),

                                          // Col K: รายข้อ = SUM(C..J)

                                          _formulaCell(

                                            _fmtNum(row.formativeTotal),

                                            66,

                                            borderColor,

                                            bgColor: formulaBg,

                                          ),

                                          // Col L: กลางภาค

                                          _editableScoreCell(
                                            row.midtermCtrl,
                                            row.midtermFocusNode,
                                            66,
                                            borderColor,
                                            maxVal: _parseNum(_midtermMaxCtrl.text),
                                            isEnabled: _isColumnEnabled(8),
                                            colIndex: 8,
                                          ),

                                          // Col M: รวมระหว่างภาค = K + L

                                          _formulaCell(

                                            _fmtNum(row.betweenTermTotal),

                                            66,

                                            borderColor,

                                            bgColor: formulaBg,

                                            bold: true,

                                          ),

                                          // Col N: ข้อสอบกลาง

                                          _editableScoreCell(
                                            row.centralExamCtrl,
                                            row.centralExamFocusNode,
                                            70,
                                            borderColor,
                                            maxVal: _parseNum(_centralExamMaxCtrl.text),
                                            isEnabled: _isColumnEnabled(9),
                                            colIndex: 9,
                                          ),

                                          // Col O: ข้อสอบ รร.

                                          _editableScoreCell(
                                            row.finalExamCtrl,
                                            row.finalExamFocusNode,
                                            70,
                                            borderColor,
                                            maxVal: _parseNum(_schoolExamMaxCtrl.text),
                                            isEnabled: _isColumnEnabled(10),
                                            colIndex: 10,
                                          ),

                                          // Col P: รวมปลายภาค = N + O

                                          _formulaCell(

                                            _fmtNum(row.finalTotal),

                                            66,

                                            borderColor,

                                            bgColor: formulaBg,

                                            bold: true,

                                          ),

                                          // Col Q: รวมทั้งหมด = M + P

                                          _formulaCell(

                                            _fmtNum(row.totalScore),

                                            68,

                                            borderColor,

                                            bgColor: formulaBg,

                                            bold: true,

                                            highlightTotal: true,

                                          ),

                                          // Col R & S: ผลการประเมิน (Outer cell colored by attendance <80% light orange, <60% light red)

                                          _buildEvaluationCell(row, theme, borderColor),

                                        ],

                                      ),

                                    );

                                  },

                                ),

                              ),

                      ),

                    ],

                  ),

                ),

              ),

            ),

          ),

        ],

      ),

    );

  }



  Widget _buildEvaluationCell(

    _StudentScoreRowState row,

    ThemeData theme,

    Color borderColor,

  ) {

    final grade = row.effectiveGrade;

    final calcGrade = row.calculatedGrade;

    final attPct = row.attendancePct;



    // Outer rectangle background based on attendance percentage:

    // < 60% -> Light Red (สีแดงอ่อน)

    // < 80% -> Light Orange (สีส้มอ่อน)

    Color? outerBgColor;

    Color outerBorderColor = borderColor.withValues(alpha: 0.7);

    String attTooltip = 'เวลาเรียน: ${attPct.toStringAsFixed(1)}%';



    if (attPct < 60.0) {

      outerBgColor = const Color(0xFFFFD6D6); // Light red

      outerBorderColor = const Color(0xFFD32F2F);

      attTooltip = 'เวลาเรียน: ${attPct.toStringAsFixed(1)}% (ต่ำกว่า 60%)';

    } else if (attPct < 80.0) {

      outerBgColor = const Color(0xFFFFE5B4); // Light orange

      outerBorderColor = const Color(0xFFEF6C00);

      attTooltip = 'เวลาเรียน: ${attPct.toStringAsFixed(1)}% (ต่ำกว่า 80%)';

    }



    return Tooltip(

      message: row.autoRemark.isNotEmpty
          ? '$attTooltip\nมส* อัตโนมัติ: เวลาเรียนไม่ถึง 80% ของเวลาเต็มแล้ว\nยกเลิกได้โดยแก้เวลาเรียนในรายวิชา (ระบบคิดใหม่ให้เอง)'
          : attTooltip,

      child: Container(

        width: 96,

        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),

        decoration: BoxDecoration(

          color: outerBgColor,

          border: attPct < 80.0

              ? Border.all(color: outerBorderColor, width: 1.2)

              : null,

        ),

        child: DropdownButtonHideUnderline(

          child: Container(

            padding: const EdgeInsets.symmetric(horizontal: 8),

            decoration: BoxDecoration(

              color: theme.colorScheme.surface,

              borderRadius: BorderRadius.circular(6),

              border: Border.all(

                color: _gradeTextColor(grade, theme).withValues(alpha: 0.45),

              ),

            ),

            child: DropdownButton<String>(

              value: const ['', 'ร', 'มส', 'มผ', 'ผ'].contains(row.remark)

                  ? row.remark

                  : '',

              isDense: true,

              isExpanded: true,

              alignment: Alignment.center,

              style: TextStyle(

                fontWeight: FontWeight.w700,

                fontSize: 13.5,

                color: _gradeTextColor(grade, theme),

                fontFamily: 'Sarabun',

              ),

              items: [

                DropdownMenuItem(

                  value: '',

                  alignment: Alignment.center,

                  child: Text(row.autoRemark.isNotEmpty ? '${row.autoRemark}*' : calcGrade),

                ),

                const DropdownMenuItem(

                  value: 'ร',

                  alignment: Alignment.center,

                  child: Text('ร'),

                ),

                const DropdownMenuItem(

                  value: 'มส',

                  alignment: Alignment.center,

                  child: Text('มส'),

                ),

                const DropdownMenuItem(

                  value: 'มผ',

                  alignment: Alignment.center,

                  child: Text('มผ'),

                ),

                const DropdownMenuItem(

                  value: 'ผ',

                  alignment: Alignment.center,

                  child: Text('ผ'),

                ),

              ],

              onChanged: (val) {

                if (val != null) {

                  row.remark = val;

                  _onAnyFieldChanged();

                }

              },

            ),

          ),

        ),

      ),

    );

  }



  Widget _headerCell(

    String text,

    double width,

    Color borderColor, {

    bool isFormula = false,

    bool isLast = false,

    bool alignLeft = false,

  }) {

    return Container(

      width: width,

      padding: const EdgeInsets.symmetric(horizontal: 6),

      alignment: alignLeft ? Alignment.centerLeft : Alignment.center,

      decoration: BoxDecoration(

        border: isLast ? null : Border(right: BorderSide(color: borderColor)),

      ),

      child: Text(

        text,

        maxLines: 1,

        overflow: TextOverflow.ellipsis,

        style: TextStyle(

          fontWeight: FontWeight.w700,

          fontSize: 12.5,

          height: 1.4,

          color: isFormula ? const Color(0xFF1A237E) : null,

        ),

      ),

    );

  }



  Widget _staticTextCell(

    String text,

    double width,

    Color borderColor, {

    bool alignCenter = false,

    bool bold = false,

    bool isLast = false,

  }) {

    return Container(

      width: width,

      padding: const EdgeInsets.symmetric(horizontal: 8),

      alignment: alignCenter ? Alignment.center : Alignment.centerLeft,

      decoration: BoxDecoration(

        border: isLast ? null : Border(right: BorderSide(color: borderColor.withValues(alpha: 0.7))),

      ),

      child: Text(

        text,

        maxLines: 1,

        overflow: TextOverflow.ellipsis,

        style: TextStyle(

          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,

          fontSize: 13,

          height: 1.4,

          fontFeatures: const [FontFeature.tabularFigures()],

        ),

      ),

    );

  }



  Widget _formulaCell(

    String text,

    double width,

    Color borderColor, {

    Color? bgColor,

    bool bold = false,

    bool highlightTotal = false,

  }) {

    return Container(

      width: width,

      alignment: Alignment.center,

      decoration: BoxDecoration(

        color: bgColor,

        border: Border(right: BorderSide(color: borderColor.withValues(alpha: 0.7))),

      ),

      child: Text(

        text,

        style: TextStyle(

          fontWeight: bold ? FontWeight.w700 : FontWeight.w600,

          fontSize: highlightTotal ? 13.5 : 13,

          color: highlightTotal ? const Color(0xFF1A237E) : null,

          fontFeatures: const [FontFeature.tabularFigures()],

        ),

      ),

    );

  }



  Widget _fullScoreCheckCell(int colIndex, double width, Color borderColor) {
    final bool isEnabled = _isColumnEnabled(colIndex);
    final bool isChecked = colIndex >= 0 && colIndex < _fullScoreColumns.length && _fullScoreColumns[colIndex];
    final double? maxVal = _parseNum(_getMaxCtrlForColumn(colIndex).text);

    return Container(
      width: width,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: borderColor)),
        color: isChecked ? const Color(0xFFC8E6C9) : const Color(0xFFE8F5E9),
      ),
      child: Tooltip(
        message: isEnabled
            ? 'ติ๊กเพื่อให้คะแนนเต็ม (${_fmtNum(maxVal!)}) ทุกคนในช่องนี้'
            : 'ติ๊กไว้ล่วงหน้าได้ เมื่อกรอกคะแนนเต็มระบบจะใส่คะแนนเต็มให้ทุกคนอัตโนมัติ',
        child: InkWell(
          onTap: () => _toggleFullScoreColumn(colIndex, !isChecked),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Checkbox(
                  value: isChecked,
                  activeColor: const Color(0xFF1E6B45),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => _toggleFullScoreColumn(colIndex, v ?? false),
                ),
              ),
              const SizedBox(width: 2),
              Text(
                'เต็ม',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: isChecked ? FontWeight.w800 : FontWeight.w600,
                  color: isChecked ? const Color(0xFF1B5E20) : const Color(0xFF2E7D32),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editableMaxCell(

    TextEditingController ctrl,
    FocusNode? focusNode,

    double width,

    Color borderColor, {
    int colIndex = -1,
  }) {

    return Container(

      width: width,

      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),

      decoration: BoxDecoration(

        border: Border(right: BorderSide(color: borderColor)),

      ),

      child: TextField(
          focusNode: focusNode,
          onTap: () {
            ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
          },

        controller: ctrl,

        onChanged: (_) => _onMaxScoreChanged(colIndex),

        textAlign: TextAlign.center,

        keyboardType: const TextInputType.numberWithOptions(decimal: true),

        inputFormatters: [

          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),

        ],

        style: const TextStyle(

          fontWeight: FontWeight.w700,

          fontSize: 13,

          color: Color(0xFF1A237E),

          fontFeatures: [FontFeature.tabularFigures()],

        ),

        decoration: InputDecoration(

          isDense: true,

          filled: true,

          fillColor: Colors.white,

          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),

          border: OutlineInputBorder(

            borderRadius: BorderRadius.circular(6),

            borderSide: BorderSide(color: borderColor),

          ),

        ),

      ),

    );

  }



  /// Header of score slot [i] (1-8): "ช่อง i" and, under it, the ตัวชี้วัด typed for it. Tap to type the ตัวชี้วัด.
  Widget _slotHeaderCell(int i, Color borderColor) {
    final slot = i - 1;
    final quiz = _quizSlots.containsKey('$slot');
    final label = slot < _indicatorLabels.length ? _indicatorLabels[slot] : '';
    final tips = [
      if (label.isNotEmpty) 'ตัวชี้วัด: $label',
      if (quiz) _quizSlotTip(slot),
      'แตะเพื่อ${label.isEmpty ? 'ใส่' : 'แก้'}ตัวชี้วัดของช่องนี้ (แสดงเป็นแนวตั้งใน ปพ.5 แผ่นที่ 4)',
    ];
    return Tooltip(
      message: tips.join('\n'),
      child: InkWell(
        key: ValueKey('slot-header-$i'),
        onTap: () => _editIndicatorLabels(slot),
        child: Container(
          width: 60,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: label.isNotEmpty ? const Color(0xFFFFFDE7) : null,
            border: Border(right: BorderSide(color: borderColor)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'ช่อง $i',
                maxLines: 1,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  height: 1.2,
                  color: quiz ? const Color(0xFF1A237E) : null,
                ),
              ),
              Text(
                label.isNotEmpty ? label : '+ ตัวชี้วัด',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.5,
                  height: 1.2,
                  color: label.isNotEmpty ? Colors.brown.shade700 : Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editIndicatorLabels(int slot) async {
    final course = _selectedCourse;
    if (course == null) return;
    final saved = await showPp5LabelsDialog(
      context,
      api: widget.apiService,
      courseCode: course.courseCode,
      term: course.term,
      year: course.year,
      sheet5: false,
      focusIndex: slot,
      unitMax: _unitMaxCtrls.map((c) => c.text.trim().isEmpty ? null : c.text.trim()).toList(),
    );
    if (saved == null || !mounted) return;
    // only the labels change: unsaved scores on screen stay as typed
    setState(() => _indicatorLabels = List.generate(8, (i) => i < saved['indicators']!.length ? saved['indicators']![i] : ''));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: const Text('บันทึกตัวชี้วัดลง ปพ.5 แล้ว'), backgroundColor: Colors.green.shade700),
    );
  }

  String _quizSlotTip(int slot) {
    final s = _quizSlots['$slot'] as Map?;
    if (s == null) return '';
    final qs = ((s['quizzes'] as List?) ?? []).cast<Map>();
    return 'เติมอัตโนมัติจากแบบทดสอบย่อย: ${qs.map((q) => '${q['title']} (${_StudentScoreRowState._fmtNum(q['points'])})').join(' + ')}'
        ' = ${_StudentScoreRowState._fmtNum(s['points_max'])} คะแนน → เทียบเต็ม ${_StudentScoreRowState._fmtNum(s['full'])}'
        '\nเปลี่ยนการเชื่อมได้ที่ปุ่ม "คะแนนแบบทดสอบย่อย"';
  }

  /// Tooltip of one cell in a quiz-linked column: automatic, or typed over by the teacher
  String _quizCellTip(int slot, bool manual) {
    if (manual) {
      return 'ครูแก้คะแนนช่องนี้เอง — ระบบจะไม่เขียนทับด้วยคะแนนแบบทดสอบย่อย'
          '\nลบตัวเลขให้ว่างแล้วกดบันทึก เพื่อกลับไปใช้คะแนนอัตโนมัติจากแบบทดสอบ';
    }
    return '${_quizSlotTip(slot)}\nแก้ตัวเลขได้ (เช่น ปรับเพิ่มคะแนน) — ค่าที่ครูแก้จะคงอยู่ ไม่ถูกคะแนนแบบทดสอบเขียนทับ';
  }

  Future<void> _openQuizLinks() async {
    final c = _selectedCourse;
    if (c == null) return;
    if (_hasUnsavedChanges) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('มีคะแนนที่ยังไม่บันทึก — กด "บันทึกคะแนน" ก่อน แล้วค่อยเชื่อมแบบทดสอบย่อย')));
      return;
    }
    final changed = await QuizLinksDialog.show(
        context, widget.apiService, {'course_code': c.courseCode, 'course_name': c.courseName, 'class_level': c.classLevel}, c.term, c.year);
    if (changed == true && mounted && _selectedCourse == c) _selectCourse(c);
  }

  Widget _editableScoreCell(
    TextEditingController ctrl,
    FocusNode? focusNode,
    double width,
    Color borderColor, {
    double? maxVal,
    bool isEnabled = true,
    int colIndex = -1,
    bool quizSlot = false,   // column filled from quizzes (purple)
    bool quizManual = false, // ...but this cell was typed over by the teacher (amber)
  }) {
    if (!isEnabled) {
      return Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: borderColor.withValues(alpha: 0.7))),
          color: const Color(0xFFF8FAFC),
        ),
        child: Tooltip(
          message: 'ช่องนี้ถูกล็อกเนื่องจากไม่ได้กำหนดคะแนนเต็ม',
          child: TextField(
            controller: ctrl,
            enabled: false,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF94A3B8),
            ),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF1F5F9),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(5),
                borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(5),
                borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
              ),
              hintText: '-',
              hintStyle: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
            ),
          ),
        ),
      );
    }
    final val = _parseNum(ctrl.text);
    final isOverMax = val != null && maxVal != null && val > maxVal;
    final Color? quizBg = !quizSlot ? null : (quizManual ? const Color(0xFFFFF7ED) : const Color(0xFFF5F3FF));
    final Color? quizText = !quizSlot ? null : (quizManual ? const Color(0xFFB45309) : const Color(0xFF5B21B6));



    return Container(

      width: width,

      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),

      decoration: BoxDecoration(

        color: quizBg,
        border: Border(right: BorderSide(color: borderColor.withValues(alpha: 0.7))),

      ),

      child: Tooltip(

        message: isOverMax
            ? 'คะแนนเกินคะแนนเต็ม (${_fmtNum(maxVal)})'
            : (quizSlot && colIndex >= 0 ? _quizCellTip(colIndex, quizManual) : ''),

        child: TextField(
          focusNode: focusNode,
          onTap: () {
            ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
          },

          controller: ctrl,

          onChanged: (_) => _onStudentScoreChanged(colIndex),

          textAlign: TextAlign.center,

          keyboardType: const TextInputType.numberWithOptions(decimal: true),

          inputFormatters: [

            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),

          ],

          style: TextStyle(

            fontWeight: FontWeight.w600,

            fontSize: 13,

            color: isOverMax ? const Color(0xFFA8342A) : quizText,

            fontFeatures: const [FontFeature.tabularFigures()],

          ),

          decoration: InputDecoration(

            isDense: true,

            filled: isOverMax,

            fillColor: isOverMax ? const Color(0xFFA8342A).withValues(alpha: 0.1) : null,

            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),

            border: OutlineInputBorder(

              borderRadius: BorderRadius.circular(5),

              borderSide: BorderSide(

                color: isOverMax ? const Color(0xFFA8342A) : borderColor.withValues(alpha: 0.6),

              ),

            ),

            enabledBorder: OutlineInputBorder(

              borderRadius: BorderRadius.circular(5),

              borderSide: BorderSide(

                color: isOverMax ? const Color(0xFFA8342A) : borderColor.withValues(alpha: 0.5),

              ),

            ),

          ),

        ),

      ),

    );

  }

}

