import 'dart:typed_data';



import 'package:flutter/material.dart';
import '../widgets/responsive_fields_row.dart';
import '../utils/app_theme.dart';
import '../widgets/app_3d_button.dart';



import 'package:file_picker/file_picker.dart';



import 'package:url_launcher/url_launcher.dart';



import '../services/api_service.dart';

import '../widgets/no_exam_right_dialog.dart';
import '../widgets/pp5_labels_dialog.dart';



import '../models/course.dart';



import '../models/student_grade.dart';



import '../models/process_result.dart';



import '../models/semester_config.dart';



import '../models/class_advisor.dart';

import '../models/logged_in_teacher.dart';
import 'scores_screen.dart';



import '../utils/format_utils.dart';







class ArchiveUploadPdfItem {



  final String name;



  final Uint8List bytes;



  final int size;



  String status; // 'pending', 'processing', 'success', 'error'



  String? error;



  ProcessResult? result;







  ArchiveUploadPdfItem({



    required this.name,



    required this.bytes,



    required this.size,



    this.status = 'pending',



    this.error,



    this.result,



  });



}







// Muted, ink-based semester tones (replaces the saturated Material rainbow).



// Each stays >= 4.5:1 against white so it can carry text and filled buttons.



const List<Color> _semesterPalette = [



  Color(0xFF2B4C7E), // Ink blue



  Color(0xFF2F6466), // Slate teal



  Color(0xFF8A4F2C), // Fired clay



  Color(0xFF5A4A78), // Dusk plum



  Color(0xFF4A6332), // Moss



  Color(0xFF3A4A5C), // Graphite



  Color(0xFF7D3F52), // Mulberry



  Color(0xFF6E5A24), // Ochre



];







/// Muted semantic accents shared by the archive screen.



Color _archiveSuccess(ThemeData t) =>



    t.brightness == Brightness.dark ? const Color(0xFF8CCFA6) : const Color(0xFF2E6B4A);



Color _archiveExcel(ThemeData t) =>



    t.brightness == Brightness.dark ? const Color(0xFF86C9A3) : const Color(0xFF1E6B45);



Color _archivePdf(ThemeData t) =>



    t.brightness == Brightness.dark ? const Color(0xFFF0A79C) : const Color(0xFFA8342A);







const List<String> _thaiMonthsAbbr = [



  '',



  'ม.ค.',



  'ก.พ.',



  'มี.ค.',



  'เม.ย.',



  'พ.ค.',



  'มิ.ย.',



  'ก.ค.',



  'ส.ค.',



  'ก.ย.',



  'ต.ค.',



  'พ.ย.',



  'ธ.ค.'



];







List<Map<String, dynamic>> _calculateScheduleWeeks(DateTime start) {



  final monday = start.subtract(Duration(days: start.weekday - 1));



  final List<Map<String, dynamic>> weeks = [];



  for (int w = 0; w < 20; w++) {



    final wMon = monday.add(Duration(days: w * 7));



    final wFri = wMon.add(const Duration(days: 4));

    final y1 = (wMon.year + 543) % 100;

    final y2 = (wFri.year + 543) % 100;

    final mStr1 = _thaiMonthsAbbr[wMon.month];

    final mStr2 = _thaiMonthsAbbr[wFri.month];

    final String monthYear;

    if (wMon.month == wFri.month && wMon.year == wFri.year) {

      monthYear = '$mStr1 ${y1.toString().padLeft(2, '0')}';

    } else {

      monthYear = '$mStr1 ${y1.toString().padLeft(2, '0')} - $mStr2 ${y2.toString().padLeft(2, '0')}';

    }







    final List<Map<String, dynamic>> days = [];



    for (int d = 0; d < 5; d++) {



      final curDay = wMon.add(Duration(days: d));



      days.add({



        'day_num': curDay.day,



        'month': curDay.month,



        'year_be': curDay.year + 543,



        'iso': '${curDay.year.toString().padLeft(4, '0')}-${curDay.month.toString().padLeft(2, '0')}-${curDay.day.toString().padLeft(2, '0')}',



      });



    }



    weeks.add({



      'week_num': w + 1,



      'month_year': monthYear,



      'days': days,



    });



  }



  return weeks;



}







class ArchiveScreen extends StatefulWidget {



  final ApiService apiService;



  final VoidCallback? onNavigateToUpload;







  const ArchiveScreen({



    super.key,



    required this.apiService,



    this.onNavigateToUpload,



  });







  @override



  State<ArchiveScreen> createState() => _ArchiveScreenState();



}







class _ArchiveScreenState extends State<ArchiveScreen> {



  List<Course> _allCourses = [];



  List<StudentGrade> _grades = [];



  Course? _selectedCourse;



  bool _loadingCourses = false;



  bool _loadingGrades = false;



  String? _error;



  String _searchQuery = '';



  List<SemesterConfigItem> _semesterConfigs = [];



  String _selectedSemesterKey = '1-2569';

  bool _userManuallySelectedSemester = false;



  List<ClassAdvisorItem> _classAdvisors = [];



  String _selectedTeacher = 'all';



  String _selectedCourseCode = 'all';



  List<String> _schoolTeachers = [];







  @override



  void initState() {



    super.initState();

    final def = widget.apiService.defaultSemester;
    if (def != null) {
      _selectedSemesterKey = '${def.term}-${def.year}';
    }



    _loadCourses();



    _loadSchoolTeachers();



  }







  Future<void> _loadSchoolTeachers() async {



    try {



      final list = await widget.apiService.getSchoolTeachers();



      if (mounted) {



        setState(() => _schoolTeachers = list);



      }



    } catch (_) {}



  }







  List<Course> get _coursesForSemester {



    if (_selectedSemesterKey == 'all') {



      return _allCourses;



    }



    final parts = _selectedSemesterKey.split('-');



    if (parts.length == 2) {



      return _allCourses.where((c) => c.term == parts[0] && c.year == parts[1]).toList();



    }



    return _allCourses;



  }







  List<String> get _availableTeachers {



    final teachers = <String>{};



    for (final c in _coursesForSemester) {



      final t = c.teacher?.trim();



      if (t != null && t.isNotEmpty && t != '-' && t != 'ไม่ระบุ') {



        teachers.add(t);



      }



    }



    final list = teachers.toList()..sort();



    return list;



  }







  List<Course> get _filteredCourses {



    final list = _coursesForSemester;



    if (_selectedTeacher == 'all') {



      return list;



    }



    return list.where((c) => c.teacher == _selectedTeacher).toList();



  }







  List<Course> get _displayedCourses {



    var list = _filteredCourses;



    if (_selectedCourseCode != 'all') {



      list = list.where((c) => c.courseCode == _selectedCourseCode).toList();



    }



    if (_searchQuery.trim().isNotEmpty) {



      final q = _searchQuery.trim().toLowerCase();



      list = list.where((c) {



        final codeMatch = c.courseCode.toLowerCase().contains(q);



        final nameMatch = c.courseName.toLowerCase().contains(q);



        final teacherMatch = (c.teacher ?? '').toLowerCase().contains(q);



        final levelMatch = _inferClassLevelFromCourse(c.courseCode).toLowerCase().contains(q);



        return codeMatch || nameMatch || teacherMatch || levelMatch;



      }).toList();



    }



    return list;



  }







  void _selectSemester(String semesterKey) {



    setState(() {



    _userManuallySelectedSemester = true;
      _selectedSemesterKey = semesterKey;



      _selectedCourseCode = 'all';



      final teachersInNew = _availableTeachers;



      final user = widget.apiService.currentUser;



      if (user != null && !user.isAdmin) {



        final myTeacher = teachersInNew.where((t) => LoggedInTeacher.normalize(t) == LoggedInTeacher.normalize(user.name)).firstOrNull;



        if (myTeacher != null) {



          _selectedTeacher = myTeacher;



        } else if (!teachersInNew.contains(_selectedTeacher)) {



          _selectedTeacher = 'all';



        }



      } else {



        if (_selectedTeacher != 'all' && !teachersInNew.contains(_selectedTeacher)) {



          _selectedTeacher = 'all';



        }



      }



      final filtered = _filteredCourses;



      if (filtered.isNotEmpty) {



        _selectedCourse = filtered.first;



      } else {



        _selectedCourse = null;



      }



    });



    _loadClassAdvisors();



  }







  void _selectTeacher(String teacher) {



    setState(() {



      _selectedTeacher = teacher;



      _selectedCourseCode = 'all';



      final filtered = _filteredCourses;



      if (filtered.isNotEmpty) {



        _selectedCourse = filtered.first;



      } else {



        _selectedCourse = null;



      }



    });



  }







  Future<void> _loadClassAdvisors() async {



    final curSem = _currentSemesterInfo;



    final term = curSem.term ?? '2';



    final year = curSem.year ?? '2568';



    try {



      final list = await widget.apiService.getClassAdvisors(term: term, year: year);



      if (mounted) {



        setState(() {



          _classAdvisors = list;



        });



      }



    } catch (_) {}



  }







  String _inferClassLevelFromCourse(String courseCode) {



    // Prefer class level stored in DB (from course/teacher import) over code inference



    for (final c in _allCourses) {



      if (c.courseCode == courseCode) {



        final lvl = c.classLevel?.trim() ?? '';



        if (RegExp(r'^ม\.[1-6]$').hasMatch(lvl)) return lvl;



      }



    }



    if (courseCode.length >= 3) {



      final match = RegExp(r'[ก-ฮa-zA-Z](\d)(\d)').firstMatch(courseCode);



      if (match != null) {



        final d1 = match.group(1);



        final d2 = match.group(2);



        if (d1 == '2') return 'ม.$d2';



        if (d1 == '3') {



          final n = int.tryParse(d2 ?? '0') ?? 0;



          if (n >= 1 && n <= 3) return 'ม.${n + 3}';



        }



      }



    }



    return '';



  }







  List<String> _getAdvisorsForCourse(Course course) {



    final lvl = _inferClassLevelFromCourse(course.courseCode);



    if (lvl.isEmpty) return [];



    final match = _classAdvisors.firstWhere(



      (a) => a.classLevel == lvl || a.classLevel.startsWith(lvl),



      orElse: () => ClassAdvisorItem(id: 0, term: '', year: '', classLevel: ''),



    );



    return match.nonNullAdvisors;



  }







  Future<void> _loadCourses() async {



    setState(() {



      _loadingCourses = true;



      _error = null;



    });



    try {



      final results = await Future.wait([



        widget.apiService.getCourses(),



        widget.apiService.getSemesterConfigs(),



      ]);



      final courses = results[0] as List<Course>;



      final configs = results[1] as List<SemesterConfigItem>;







      setState(() {



        _allCourses = courses;



        _semesterConfigs = configs;



        _loadingCourses = false;







        final user = widget.apiService.currentUser;



        if (user != null && !user.isAdmin) {



          final myTeacher = _availableTeachers.where((t) => LoggedInTeacher.normalize(t) == LoggedInTeacher.normalize(user.name)).firstOrNull;



          if (myTeacher != null) {



            _selectedTeacher = myTeacher;



          }



        }








        if (configs.isNotEmpty) {
          final defaultSem = configs.firstWhere(
            (c) => c.isDefault,
            orElse: () => configs.firstWhere((c) => c.isActive, orElse: () => configs.first),
          );
          if (!_userManuallySelectedSemester) {
            _selectedSemesterKey = '${defaultSem.term}-${defaultSem.year}';
          } else if (_selectedSemesterKey != 'all') {
            final exists = configs.any((c) => '${c.term}-${c.year}' == _selectedSemesterKey);
            if (!exists) {
              _selectedSemesterKey = '${defaultSem.term}-${defaultSem.year}';
            }
          }
        }







        final filtered = _filteredCourses;



        if (filtered.isNotEmpty) {



          _selectedCourse = filtered.first;



          _loadGrades();



        } else if (courses.isNotEmpty) {



          _selectedCourse = courses.first;



          _loadGrades();



        }



      });



      _loadClassAdvisors();



    } catch (e) {



      setState(() {



        _loadingCourses = false;



        _error = 'ไม่สามารถโหลดรายวิชาได้: $e';



      });



    }



  }







  Future<void> _loadGrades() async {



    if (_selectedCourse == null) return;



    setState(() {



      _loadingGrades = true;



      _error = null;



    });



    try {



      final grades = await widget.apiService.getGrades(



        term: _selectedCourse!.term,



        year: _selectedCourse!.year,



        courseCode: _selectedCourse!.courseCode,



      );



      setState(() {



        _grades = grades;



        _loadingGrades = false;



      });



    } catch (e) {



      setState(() {



        _loadingGrades = false;



        _error = 'ไม่สามารถโหลดข้อมูลผลการเรียนได้: $e';



      });



    }



  }







  bool _canManageCourse(Course course) {



    final user = widget.apiService.currentUser;



    if (user == null) return false;



    return user.canManageCourse(course);



  }







  Future<void> _downloadExcel(Course course) async {



    if (!_canManageCourse(course)) {



      ScaffoldMessenger.of(context).showSnackBar(



        const SnackBar(



          content: Text('ขออภัย ท่านสามารถดาวน์โหลดไฟล์ Excel ปพ.5 ได้เฉพาะรายวิชาที่ท่านสอนเท่านั้น'),



          backgroundColor: Colors.orange,



        ),



      );



      return;



    }



    final url = widget.apiService.getCourseFileUrl(



      course.courseCode,



      format: 'excel',



      term: course.term,



      year: course.year,



    );



    final uri = Uri.parse(url);



    try {



      if (await canLaunchUrl(uri)) {



        await launchUrl(uri, mode: LaunchMode.externalApplication);



      } else {



        if (mounted) {



          ScaffoldMessenger.of(context).showSnackBar(



            SnackBar(content: Text('ไม่สามารถเปิดลิงก์ดาวน์โหลด: $url')),



          );



        }



      }



    } catch (e) {



      if (mounted) {



        ScaffoldMessenger.of(context).showSnackBar(



          SnackBar(content: Text('ดาวน์โหลดไม่สำเร็จ: $e')),



        );



      }



    }



  }







  Future<void> _downloadPdf(Course course) async {



    if (!_canManageCourse(course)) {



      ScaffoldMessenger.of(context).showSnackBar(



        const SnackBar(



          content: Text('ขออภัย ท่านสามารถดาวน์โหลด/สั่งพิมพ์ไฟล์ PDF ปพ.5 ได้เฉพาะรายวิชาที่ท่านสอนเท่านั้น'),



          backgroundColor: Colors.orange,



        ),



      );



      return;



    }



    final url = widget.apiService.getCourseFileUrl(



      course.courseCode,



      format: 'pdf',



      term: course.term,



      year: course.year,



    );



    final uri = Uri.parse(url);



    try {



      if (await canLaunchUrl(uri)) {



        await launchUrl(uri, mode: LaunchMode.externalApplication);



      } else {



        if (mounted) {



          ScaffoldMessenger.of(context).showSnackBar(



            SnackBar(content: Text('ไม่สามารถเปิดลิงก์ดาวน์โหลด: $url')),



          );



        }



      }



    } catch (e) {



      if (mounted) {



        ScaffoldMessenger.of(context).showSnackBar(



          SnackBar(content: Text('ดาวน์โหลดไม่สำเร็จ: $e')),



        );



      }



    }



  }







    Future<void> _openScoresDialog(Course course) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 1400,
          height: 900,
          child: ScoresScreen(
            apiService: widget.apiService,
            initialCourse: course,
            isDialog: true,
          ),
        ),
      ),
    );
  }

  Future<void> _openFileVerifyAndPrintDialog(Course course, String initialFormat) async {
    if (initialFormat == 'preview') {
      await _openScoresDialog(course);
      return;
    }




    final canManage = _canManageCourse(course);



    await showDialog(



      context: context,



      barrierDismissible: true,



      builder: (dialogCtx) {



        return _CourseVerifyAndPrintDialog(



          course: course,



          initialFormat: initialFormat,



          apiService: widget.apiService,



          classAdvisors: _classAdvisors,



          canManage: canManage,



          onTeacherUpdated: (newTeacher) {



            setState(() {



              final idx = _allCourses.indexWhere(



                (c) => c.courseCode == course.courseCode && c.term == course.term && c.year == course.year,



              );



              if (idx != -1) {



                _allCourses[idx] = _allCourses[idx].copyWith(teacher: newTeacher);



              }



              if (_selectedCourse?.courseCode == course.courseCode) {



                _selectedCourse = _selectedCourse?.copyWith(teacher: newTeacher);



              }



            });



          },



          onOpenAdvisorsDialog: _openAdvisorsManagementDialog,



          onDownloadExcel: () => _downloadExcel(course),



          onDownloadPdf: () => _downloadPdf(course),



        );



      },



    );



  }







  Future<void> _openCourseDescriptionDialog(Course course) async {



    if (!_canManageCourse(course)) return;



    final canManage = _canManageCourse(course);



    String currentDesc = course.courseDescription ?? '';



    try {



      final res = await widget.apiService.getCourseDescription(course.courseCode);



      if (res['description'] != null && (res['description'] as String).isNotEmpty) {



        currentDesc = res['description'] as String;



      }



    } catch (_) {}







    if (!mounted) return;







    final controller = TextEditingController(text: currentDesc);



    bool saving = false;







    await showDialog(



      context: context,



      barrierDismissible: false,



      builder: (ctx) {



        return StatefulBuilder(



          builder: (dialogCtx, setDialogState) {



            final text = controller.text;



            final estLines = calculateEstimatedLines(text);



            final fontSize = calculateRecommendedFontSize(text);



            final charCount = text.length;







            return AlertDialog(



              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



              title: Row(



                children: [



                  Icon(Icons.edit_note_rounded, color: Theme.of(context).colorScheme.primary, size: 28),



                  const SizedBox(width: 10),



                  Expanded(



                    child: Text(



                      'คำอธิบายรายวิชาและตัวชี้วัด: ${course.courseCode} ${course.courseName}',



                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),



                    ),



                  ),



                ],



              ),



              content: SizedBox(



                width: 680,



                child: SingleChildScrollView(



                  child: Column(



                    mainAxisSize: MainAxisSize.min,



                    crossAxisAlignment: CrossAxisAlignment.start,



                    children: [



                      Container(



                        padding: const EdgeInsets.all(12),



                        decoration: BoxDecoration(



                          color: Colors.blue.shade50,



                          borderRadius: BorderRadius.circular(8),



                          border: Border.all(color: Colors.blue.shade200),



                        ),



                        child: Row(



                          children: [



                            Icon(Icons.auto_awesome, color: Colors.blue.shade700, size: 20),



                            const SizedBox(width: 8),



                            Expanded(



                              child: Text(



                                'ระบบจะคำนวณปรับขนาดฟอนต์ TH SarabunPSK (11 - 16 pt) ให้อัตโนมัติ เพื่อให้พอดีกับกรอบเส้นแผ่น (6) ตัวชี้วัด หน้าเดียวพอดี ทั้งไฟล์ Excel และ PDF',



                                style: TextStyle(fontSize: 13, color: Colors.blue.shade900),



                              ),



                            ),



                          ],



                        ),



                      ),



                      const SizedBox(height: 14),



                      TextField(



                        controller: controller,



                        readOnly: !canManage,



                        maxLines: 12,



                        decoration: const InputDecoration(



                          hintText: 'วางหรือพิมพ์คำอธิบายรายวิชา และตัวชี้วัด / ผลการเรียนรู้ ที่นี่...',



                          border: OutlineInputBorder(),



                          contentPadding: EdgeInsets.all(12),



                        ),



                        onChanged: (val) {



                          setDialogState(() {});



                        },



                      ),



                      const SizedBox(height: 12),



                      Container(



                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),



                        decoration: BoxDecoration(



                          color: Colors.grey.shade100,



                          borderRadius: BorderRadius.circular(6),



                        ),



                        child: Row(



                          children: [



                            Icon(Icons.straighten, size: 18, color: Colors.grey.shade700),



                            const SizedBox(width: 8),



                            Text(



                              'ความยาว: $charCount ตัวอักษร (~$estLines บรรทัด)',



                              style: const TextStyle(fontSize: 13),



                            ),



                            const Spacer(),



                            Container(



                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),



                              decoration: BoxDecoration(



                                color: Colors.teal.shade50,



                                border: Border.all(color: Colors.teal.shade400),



                                borderRadius: BorderRadius.circular(4),



                              ),



                              child: Text(



                                'ขนาดฟอนต์ที่คำนวณได้: $fontSize pt',



                                style: TextStyle(



                                  fontSize: 13,



                                  fontWeight: FontWeight.bold,



                                  color: Colors.teal.shade800,



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



                  onPressed: saving ? null : () => Navigator.of(ctx).pop(),



                  child: Text(canManage ? 'ยกเลิก' : 'ปิด'),



                ),



                if (canManage)



                  FilledButton.icon(



                  onPressed: saving



                      ? null



                      : () async {



                          setDialogState(() => saving = true);



                          try {



                            final res = await widget.apiService.saveCourseDescription(



                              course.courseCode,



                              controller.text,



                            );



                            if (mounted) {



                              Navigator.of(ctx).pop();



                              ScaffoldMessenger.of(context).showSnackBar(



                                SnackBar(



                                  backgroundColor: Colors.teal.shade700,



                                  content: Text(



                                    'บันทึกคำอธิบายรายวิชาและอัปเดตไฟล์ ปพ.5 (${res['font_size']} pt) เรียบร้อยแล้ว',



                                  ),



                                ),



                              );



                              _loadCourses();



                            }



                          } catch (e) {



                            setDialogState(() => saving = false);



                            if (mounted) {



                              ScaffoldMessenger.of(context).showSnackBar(



                                SnackBar(



                                  backgroundColor: Colors.red.shade700,



                                  content: Text('บันทึกไม่สำเร็จ: $e'),



                                ),



                              );



                            }



                          }



                        },



                  icon: saving



                      ? const SizedBox(



                          width: 16,



                          height: 16,



                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),



                        )



                      : const Icon(Icons.save_rounded, size: 18),



                  label: Text(saving ? 'กำลังบันทึกและอัปเดต...' : 'บันทึกและอัปเดตไฟล์'),



                ),



              ],



            );



          },



        );



      },



    );



  }







  Future<void> _openAttendanceDialog(Course course) async {



    if (!_canManageCourse(course)) return;



    final canManage = _canManageCourse(course);



    // Show loading dialog



    showDialog(



      context: context,



      barrierDismissible: false,



      builder: (_) => const Center(child: CircularProgressIndicator()),



    );







    Map<String, dynamic> attData;



    try {



      attData = await widget.apiService.getAttendance(



        course.courseCode,



        term: course.term,



        year: course.year,



      );



    } catch (e) {



      if (mounted) {



        Navigator.of(context).pop();



        ScaffoldMessenger.of(context).showSnackBar(



          SnackBar(



            backgroundColor: Colors.red.shade700,



            content: Text('ไม่สามารถโหลดข้อมูลเวลาเรียนได้: $e'),



          ),



        );



      }



      return;



    }







    if (!mounted) return;



    Navigator.of(context).pop(); // dismiss loading







    final studentsRaw = (attData['students'] as List? ?? []);



    if (studentsRaw.isEmpty) {



      ScaffoldMessenger.of(context).showSnackBar(



        const SnackBar(content: Text('ไม่พบรายชื่อนักเรียนในวิชานี้')),



      );



      return;



    }







    final dayKeys = ['mon', 'tue', 'wed', 'thu', 'fri'];



    final dayLabels = ['จ.', 'อ.', 'พ.', 'พฤ.', 'ศ.'];



    final dayFullNames = ['จันทร์', 'อังคาร', 'พุธ', 'พฤหัสบดี', 'ศุกร์'];







    final Map<String, int> courseSchedule = {
      'mon': 0,
      'tue': 0,
      'wed': 0,
      'thu': 0,
      'fri': 0,
    };

    final rawSchedule = attData['schedule'];
    if (rawSchedule is Map) {
      courseSchedule['mon'] = (rawSchedule['mon'] as num?)?.toInt() ?? 0;
      courseSchedule['tue'] = (rawSchedule['tue'] as num?)?.toInt() ?? 0;
      courseSchedule['wed'] = (rawSchedule['wed'] as num?)?.toInt() ?? 0;
      courseSchedule['thu'] = (rawSchedule['thu'] as num?)?.toInt() ?? 0;
      courseSchedule['fri'] = (rawSchedule['fri'] as num?)?.toInt() ?? 0;
    } else if (rawSchedule is List) {
      for (final item in rawSchedule) {
        if (item is Map) {
          final day = (item['day'] as num?)?.toInt();
          final span = (item['span'] as num?)?.toInt() ?? 1;
          if (day == 1) courseSchedule['mon'] = (courseSchedule['mon'] ?? 0) + span;
          if (day == 2) courseSchedule['tue'] = (courseSchedule['tue'] ?? 0) + span;
          if (day == 3) courseSchedule['wed'] = (courseSchedule['wed'] ?? 0) + span;
          if (day == 4) courseSchedule['thu'] = (courseSchedule['thu'] ?? 0) + span;
          if (day == 5) courseSchedule['fri'] = (courseSchedule['fri'] ?? 0) + span;
        }
      }
    }

    if (courseSchedule.values.fold<int>(0, (a, b) => a + b) == 0) {
      courseSchedule['mon'] = 1;
      courseSchedule['tue'] = 1;
    }

    final rawHolidays = (rawSchedule is Map ? rawSchedule['holidays'] : null) as List? ??
        attData['holidays'] as List? ?? [];
    final Set<int> holidaySlots = Set<int>.from(rawHolidays.map((e) => (e as num).toInt()));

    final rawLockedCounted = (rawSchedule is Map ? rawSchedule['locked_counted'] : null) as List? ??
        attData['locked_counted'] as List? ?? [];
    final Set<int> lockedCountedSlots = Set<int>.from(rawLockedCounted.map((e) => (e as num).toInt()));







    int getSlotLockState(int slotIdx) {



      if (lockedCountedSlots.contains(slotIdx)) return 1;



      if (holidaySlots.contains(slotIdx)) return 2;



      return 0;



    }







    // Hours one daily check is worth (row 8 "ชั่วโมงที่" of the ปพ.5): 0 on holidays, else periods taught that weekday
    int slotHours(int slotIdx) {
      if (holidaySlots.contains(slotIdx)) return 0;
      return courseSchedule[dayKeys[slotIdx % 5]] ?? 0;
    }

    // Day-slots up to today (server clock, new day at midnight): ขาด and ร้อยละ count only these
    final int elapsedSlots = ((attData['elapsed_slots'] as num?)?.toInt() ?? 100).clamp(0, 100);
    int computeElapsedPeriods() {
      int count = 0;
      for (int i = 0; i < elapsedSlots; i++) {
        count += slotHours(i);
      }
      return count;
    }

    int computeTotalActualPeriods() {



      int count = 0;



      for (int w = 0; w < 20; w++) {



        for (int d = 0; d < 5; d++) {



          final slotIdx = w * 5 + d;



          if (holidaySlots.contains(slotIdx)) {



            continue; // State 2: ล็อก แบบไม่นับเวลาเรียน



          } else if (lockedCountedSlots.contains(slotIdx)) {



            final p = courseSchedule[dayKeys[d]] ?? 0;



            count += p; // State 1: ล็อก แต่นับเวลาเรียน (ชั่วโมงตามตารางสอนของวันนั้น)



          } else {



            count += (courseSchedule[dayKeys[d]] ?? 0); // State 0: สอนปกติ



          }



        }



      }



      return count > 0 ? count : 40;



    }







    final int initialTotalPeriods = computeTotalActualPeriods();







    DateTime selectedStartDate;



    final rawStartDate = attData['start_date']?.toString();



    if (rawStartDate != null && rawStartDate.isNotEmpty) {



      selectedStartDate = DateTime.tryParse(rawStartDate) ??



          (course.term == '2' ? DateTime(2025, 11, 3) : DateTime(2025, 5, 12));



    } else {



      selectedStartDate = course.term == '2' ? DateTime(2025, 11, 3) : DateTime(2025, 5, 12);



    }



    // Snap to Monday of the week



    selectedStartDate = selectedStartDate.subtract(Duration(days: selectedStartDate.weekday - 1));







    List<Map<String, dynamic>> computedWeeks = _calculateScheduleWeeks(selectedStartDate);







    // Prepare local mutable state for each student with 100-slot attendance grid



    final studentList = studentsRaw.map((s) {



      final pCount = (s['present_count'] as num?)?.toInt() ?? initialTotalPeriods;



      final rawStatus = (s['status_list'] as List?)?.map((e) => e.toString()).toList() ?? [];







      final List<String> statusList = List<String>.filled(100, '');



      if (rawStatus.length == 100 && rawStatus.any((m) => m.isNotEmpty)) {



        for (int i = 0; i < 100; i++) {



          statusList[i] = rawStatus[i];



        }



      } else if (rawStatus.length == 40) {



        for (int w = 0; w < 20; w++) {



          statusList[w * 5 + 0] = rawStatus[w * 2 + 0];



          statusList[w * 5 + 1] = rawStatus[w * 2 + 1];



        }



      } else {



        // Default allocation according to course schedule



        int allocated = 0;



        for (int w = 0; w < 20 && allocated < pCount; w++) {



          for (int d = 0; d < 5 && allocated < pCount; d++) {



            final slotIdx = w * 5 + d;



            if ((courseSchedule[dayKeys[d]] ?? 0) > 0 && !holidaySlots.contains(slotIdx)) {



              statusList[slotIdx] = '/';



              allocated++;



            }



          }



        }



      }







      // Clear holidays and non-teaching, mark locked_counted as present



      for (int w = 0; w < 20; w++) {



        for (int d = 0; d < 5; d++) {



          final slotIdx = w * 5 + d;



          if (holidaySlots.contains(slotIdx)) {



            statusList[slotIdx] = '';



          } else if (lockedCountedSlots.contains(slotIdx)) {



            statusList[slotIdx] = '/';



          } else if ((courseSchedule[dayKeys[d]] ?? 0) == 0) {



            statusList[slotIdx] = '';



          }



        }



      }







      // ขาด / ร้อยละ: hours taught up to today only (same rule as the server and the ปพ.5)



      int actualP = 0, actualLt = 0, actualL = 0;



      for (int i = 0; i < elapsedSlots; i++) {



        final h = slotHours(i);



        if (h == 0) continue;



        final mk = statusList[i];



        if (lockedCountedSlots.contains(i) || mk == '/' || mk == 'ส') actualP += h;



        if (mk == 'ส') actualLt += h;



        if (mk == 'ล' && !lockedCountedSlots.contains(i)) actualL += h;



      }



      final int elapsedHours = computeElapsedPeriods();



      final int actualA = (elapsedHours - actualP - actualL).clamp(0, elapsedHours);



      final double actualPct = elapsedHours > 0



          ? double.parse(((actualP / elapsedHours) * 100).toStringAsFixed(1))



          : 100.0;







      return {



        'student_id': s['student_id'].toString(),



        'student_no': (s['student_no'] as num?)?.toInt() ?? 1,



        'full_name': s['full_name'].toString(),



        'present_count': actualP,



        'absent_count': actualA,



        'leave_count': actualL,



        'late_count': actualLt,



        'percentage': actualPct,



        'status_list': statusList,



      };



    }).toList();







    bool allPresent = studentList.every((s) => (s['present_count'] as int) == initialTotalPeriods);



    bool saving = false;



    String currentMode = 'present'; // 'present' (/), 'leave' (ล), 'absent' (blank)



    int selectedWeekRange = 0; // 0: All 20 weeks, 1: 1-5, 2: 6-10, 3: 11-15, 4: 16-20







    await showDialog(



      context: context,



      barrierDismissible: false,



      builder: (dialogCtx) {



        return StatefulBuilder(



          builder: (ctx, setDialogState) {



            final totalActualPeriods = computeTotalActualPeriods();



            final totalPresent = studentList.fold<int>(0, (sum, s) => sum + (s['present_count'] as int));



            final totalLate = studentList.fold<int>(0, (sum, s) => sum + ((s['late_count'] as int?) ?? 0));



            final totalAbsent = studentList.fold<int>(0, (sum, s) => sum + (s['absent_count'] as int));



            final totalLeave = studentList.fold<int>(0, (sum, s) => sum + (s['leave_count'] as int));







            List<int> visibleWeeks;



            if (selectedWeekRange == 1) {



              visibleWeeks = [1, 2, 3, 4, 5];



            } else if (selectedWeekRange == 2) {



              visibleWeeks = [6, 7, 8, 9, 10];



            } else if (selectedWeekRange == 3) {



              visibleWeeks = [11, 12, 13, 14, 15];



            } else if (selectedWeekRange == 4) {



              visibleWeeks = [16, 17, 18, 19, 20];



            } else {



              visibleWeeks = List<int>.generate(20, (i) => i + 1);



            }







            void recalculate(Map<String, dynamic> st) {



              final list = List<String>.from(st['status_list'] as List);



              final int totHours = computeElapsedPeriods(); // ขาด / ร้อยละ นับถึงวันปัจจุบัน



              int p = 0;



              int l = 0;



              int lt = 0;



              for (int i = 0; i < elapsedSlots; i++) {



                if (holidaySlots.contains(i)) {



                  continue;



                } else if (lockedCountedSlots.contains(i)) {



                  p += slotHours(i);



                } else {



                  if (list[i] == '/') {



                    p += slotHours(i);



                  } else if (list[i] == 'ส') {



                    p += slotHours(i); // จากตารางเรียนรวมและวิชา สายให้นับเป็นมาในคาบนั้น



                    lt += slotHours(i);



                  } else if (list[i] == 'ล') {



                    l += slotHours(i);



                  }



                }



              }



              final int a = (totHours - p - l).clamp(0, totHours);



              final double pct = totHours > 0



                  ? double.parse(((p / totHours) * 100).toStringAsFixed(1))



                  : 100.0;



              st['present_count'] = p;



              st['late_count'] = lt;



              st['leave_count'] = l;



              st['absent_count'] = a;



              st['percentage'] = pct;



            }







            void cleanNonTeachingSlots() {



              for (var st in studentList) {



                final list = List<String>.from(st['status_list'] as List);



                for (int w = 0; w < 20; w++) {



                  for (int d = 0; d < 5; d++) {



                    final slotIdx = w * 5 + d;



                    final isTeaching = (courseSchedule[dayKeys[d]] ?? 0) > 0;



                    if (holidaySlots.contains(slotIdx)) {



                      list[slotIdx] = '';



                    } else if (lockedCountedSlots.contains(slotIdx)) {



                      list[slotIdx] = '/';



                    } else if (!isTeaching) {



                      list[slotIdx] = '';



                    }



                  }



                }



                st['status_list'] = list;



                recalculate(st);



              }



              final totHours = computeElapsedPeriods();



              allPresent = studentList.every((s) => (s['present_count'] as int) == totHours);



            }







            void setAllStudentsPresent(bool checked) {



              allPresent = checked;



              for (var st in studentList) {



                final list = List<String>.filled(100, '');



                if (checked) {



                  for (int w = 0; w < 20; w++) {



                    for (int d = 0; d < 5; d++) {



                      final slotIdx = w * 5 + d;



                      final isTeaching = (courseSchedule[dayKeys[d]] ?? 0) > 0;



                      if (holidaySlots.contains(slotIdx)) {



                        list[slotIdx] = '';



                      } else if (lockedCountedSlots.contains(slotIdx) || isTeaching) {



                        list[slotIdx] = '/';



                      }



                    }



                  }



                }



                st['status_list'] = list;



                recalculate(st);



              }



            }







            void setVisibleWeeksPresent(List<int> weeks) {



              for (var st in studentList) {



                final list = List<String>.from(st['status_list'] as List);



                for (int w in weeks) {



                  for (int d = 0; d < 5; d++) {



                    final slotIdx = (w - 1) * 5 + d;



                    final isTeaching = (courseSchedule[dayKeys[d]] ?? 0) > 0;



                    if (holidaySlots.contains(slotIdx)) {



                      list[slotIdx] = '';



                    } else if (lockedCountedSlots.contains(slotIdx) || isTeaching) {



                      list[slotIdx] = '/';



                    } else {



                      list[slotIdx] = '';



                    }



                  }



                }



                st['status_list'] = list;



                recalculate(st);



              }



              final totHours = computeElapsedPeriods();



              allPresent = studentList.every((s) => (s['present_count'] as int) == totHours);



            }







            void cycleSlotLock(int slotIdx) {



              if (saving) return;



              final currentState = getSlotLockState(slotIdx);



              if (currentState == 0) {



                // กด 1 ครั้ง: ล็อก แต่นับเวลาเรียน



                lockedCountedSlots.add(slotIdx);



                holidaySlots.remove(slotIdx);



                for (var st in studentList) {



                  final list = List<String>.from(st['status_list'] as List);



                  list[slotIdx] = '/';



                  st['status_list'] = list;



                }



              } else if (currentState == 1) {



                // กด 2 ครั้ง: ล็อก แบบไม่นับเวลาเรียน



                lockedCountedSlots.remove(slotIdx);



                holidaySlots.add(slotIdx);



                for (var st in studentList) {



                  final list = List<String>.from(st['status_list'] as List);



                  list[slotIdx] = '';



                  st['status_list'] = list;



                }



              } else {



                // กดครั้งที่ 3: ปลดล็อก กลับสู่สถานะปกติ



                lockedCountedSlots.remove(slotIdx);



                holidaySlots.remove(slotIdx);



                final d = slotIdx % 5;



                final isTeaching = (courseSchedule[dayKeys[d]] ?? 0) > 0;



                for (var st in studentList) {



                  final list = List<String>.from(st['status_list'] as List);



                  list[slotIdx] = isTeaching && allPresent ? '/' : '';



                  st['status_list'] = list;



                }



              }







              for (var st in studentList) {



                recalculate(st);



              }



              final totHours = computeElapsedPeriods();



              allPresent = studentList.every((s) => (s['present_count'] as int) == totHours);



            }







            void toggleCell(Map<String, dynamic> st, int slotIndex) {



              if (saving) return;



              final lockState = getSlotLockState(slotIndex);



              if (lockState != 0) return; // Locked! State 1 and State 2 cannot be edited manually



              final d = slotIndex % 5;



              final isTeaching = (courseSchedule[dayKeys[d]] ?? 0) > 0;



              if (!isTeaching) return;







              final list = List<String>.from(st['status_list'] as List);



              final curr = list[slotIndex];



              if (currentMode == 'leave') {



                list[slotIndex] = (curr == 'ล') ? '' : 'ล';



              } else if (currentMode == 'late') {



                list[slotIndex] = (curr == 'ส') ? '' : 'ส';



              } else if (currentMode == 'absent') {



                list[slotIndex] = '';



              } else {



                list[slotIndex] = (curr == '/') ? '' : '/';



              }



              st['status_list'] = list;



              recalculate(st);



              final totHours = computeElapsedPeriods();



              allPresent = studentList.every((s) => (s['present_count'] as int) == totHours);



            }







            final totalPeriodsWeek = courseSchedule.values.fold<int>(0, (a, b) => a + b);







            return Dialog(



              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),



              child: ConstrainedBox(



                constraints: const BoxConstraints(maxWidth: 1360, maxHeight: 880),



                child: Padding(



                  padding: const EdgeInsets.all(18),



                  child: _scrollIfCompact(MediaQuery.sizeOf(context).width < 700, Column(



                    crossAxisAlignment: CrossAxisAlignment.stretch,



                    children: [



                      // Header



                      Row(



                        children: [



                          Icon(Icons.table_chart_rounded, color: AppColors.purplePrimary, size: 28),



                          const SizedBox(width: 12),



                          Expanded(



                            child: Column(



                              crossAxisAlignment: CrossAxisAlignment.start,



                              children: [



                                Text(



                                  'ตารางสำรวจและเช็คเวลาเรียน ปพ.5: ${course.courseCode} ${course.courseName}',



                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),



                                ),



                                const SizedBox(height: 2),



                                Text(



                                  '${course.displaySemester} | ครูผู้สอน: ${course.teacher ?? "-"} | 20 สัปดาห์ สัปดาห์ละ 5 ช่อง (100 คาบ) | เกณฑ์เวลาเรียน $totalActualPeriods คาบ${lockedCountedSlots.isNotEmpty ? " (ล็อกนับ ${lockedCountedSlots.length} วัน)" : ""}${holidaySlots.isNotEmpty ? " (ไม่นับ ${holidaySlots.length} วัน)" : ""}',



                                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),



                                ),



                              ],



                            ),



                          ),



                          IconButton(



                            onPressed: saving ? null : () => Navigator.of(ctx).pop(),



                            icon: const Icon(Icons.close),



                          ),



                        ],



                      ),



                      const SizedBox(height: 10),







                      // Schedule & Start Date Config Toolbar



                      Container(



                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),



                        decoration: BoxDecoration(



                          color: Colors.white,



                          borderRadius: BorderRadius.circular(10),



                          border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),



                          boxShadow: [



                            BoxShadow(



                              color: Colors.black.withValues(alpha: 0.03),



                              blurRadius: 4,



                              offset: const Offset(0, 2),



                            ),



                          ],



                        ),



                        child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [



                            // 1. Start Date Selector



                            Icon(Icons.event_note_rounded, size: 20, color: AppColors.purplePrimary),



                            const SizedBox(width: 8),



                            Column(



                              crossAxisAlignment: CrossAxisAlignment.start,



                              children: [



                                const Text('วันเริ่มภาคเรียน (ช่องแรก):', style: TextStyle(fontSize: 11, color: Colors.grey)),



                                Text(



                                  '${selectedStartDate.day} ${_thaiMonthsAbbr[selectedStartDate.month]} ${selectedStartDate.year + 543}',



                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.purpleDark),



                                ),



                              ],



                            ),



                            const SizedBox(width: 8),



                            OutlinedButton.icon(



                              icon: const Icon(Icons.edit_calendar_rounded, size: 15),



                              label: const Text('เลือกวันที่', style: TextStyle(fontSize: 11)),



                              style: OutlinedButton.styleFrom(



                                visualDensity: VisualDensity.compact,



                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),



                              ),



                              onPressed: saving ? null : () async {



                                final picked = await showDatePicker(



                                  context: ctx,



                                  initialDate: selectedStartDate,



                                  firstDate: DateTime(2020),



                                  lastDate: DateTime(2035),



                                  helpText: 'เลือกวันเริ่มต้นภาคเรียน (ตำแหน่งวันที่ช่องแรก)',



                                );



                                if (picked != null) {



                                  setDialogState(() {



                                    selectedStartDate = picked.subtract(Duration(days: picked.weekday - 1));



                                    computedWeeks = _calculateScheduleWeeks(selectedStartDate);



                                  });



                                }



                              },



                            ),



                            const SizedBox(width: 16),



                            const SizedBox(width: 4),



                            const SizedBox(width: 16),







                            // 2. Teaching Days & Periods Config



                            Icon(Icons.access_time_rounded, size: 20, color: AppColors.purplePrimary),



                            const SizedBox(width: 8),



                            Column(



                              crossAxisAlignment: CrossAxisAlignment.start,



                              children: [



                                const Text('เลือกวันสอน & คาบ/วัน (คลิกเพื่อเปลี่ยน):', style: TextStyle(fontSize: 11, color: Colors.grey)),



                                const SizedBox(height: 2),



                                Row(



                                  children: List.generate(5, (d) {



                                    final key = dayKeys[d];



                                    final count = courseSchedule[key] ?? 0;



                                    final isSelected = count > 0;



                                    return Padding(



                                      padding: const EdgeInsets.only(right: 6),



                                      child: InkWell(



                                        borderRadius: BorderRadius.circular(6),



                                        onTap: saving ? null : () {



                                          setDialogState(() {



                                            // Cycle: 0 -> 1 -> 2 -> 0



                                            courseSchedule[key] = (count + 1) % 3;



                                            cleanNonTeachingSlots();



                                          });



                                        },



                                        child: AnimatedContainer(



                                          duration: const Duration(milliseconds: 150),



                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),



                                          decoration: BoxDecoration(



                                            color: isSelected ? Colors.green.shade600 : Colors.grey.shade100,



                                            borderRadius: BorderRadius.circular(6),



                                            border: Border.all(



                                              color: isSelected ? Colors.green.shade800 : Colors.grey.shade300,



                                              width: isSelected ? 1.5 : 1.0,



                                            ),



                                            boxShadow: isSelected



                                                ? [



                                                    BoxShadow(



                                                      color: Colors.green.withValues(alpha: 0.25),



                                                      blurRadius: 4,



                                                      offset: const Offset(0, 2),



                                                    ),



                                                  ]



                                                : null,



                                          ),



                                          child: Row(



                                            mainAxisSize: MainAxisSize.min,



                                            children: [



                                              if (isSelected) ...[



                                                const Icon(Icons.check_circle, size: 14, color: Colors.white),



                                                const SizedBox(width: 4),



                                              ],



                                              Text(



                                                '${dayLabels[d]} ${isSelected ? "$count คาบ" : "-"}',



                                                style: TextStyle(



                                                  fontSize: 12,



                                                  fontWeight: FontWeight.bold,



                                                  color: isSelected ? Colors.white : Colors.grey.shade600,



                                                ),



                                              ),



                                            ],



                                          ),



                                        ),



                                      ),



                                    );



                                  }),



                                ),



                              ],



                            ),



                            const SizedBox(width: 12),



                            Container(



                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),



                              decoration: BoxDecoration(



                                color: Colors.green.shade50,



                                borderRadius: BorderRadius.circular(6),



                                border: Border.all(color: Colors.green.shade300),



                              ),



                              child: Row(



                                mainAxisSize: MainAxisSize.min,



                                children: [



                                  Icon(Icons.check_circle_outline, size: 16, color: Colors.green.shade800),



                                  const SizedBox(width: 6),



                                  Text(



                                    'สอนสัปดาห์ละ $totalPeriodsWeek คาบ (${totalPeriodsWeek * 20} คาบ/เทอม)',



                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green.shade900),



                                  ),



                                ],



                              ),



                            ),



                          ],



                        ),



                      ),



                      const SizedBox(height: 8),







                      // Control Toolbar (Special Checkbox + Modes + Week Selector + Counters)



                      Container(



                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),



                        decoration: BoxDecoration(



                          color: AppColors.purpleContainer,



                          borderRadius: BorderRadius.circular(10),



                          border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),



                        ),



                        child: Column(



                          children: [



                            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [



                                // Special Checkbox: มาทุกคน



                                InkWell(



                                  borderRadius: BorderRadius.circular(6),



                                  onTap: saving



                                      ? null



                                      : () => setDialogState(() => setAllStudentsPresent(!allPresent)),



                                  child: Padding(



                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),



                                    child: Row(



                                      mainAxisSize: MainAxisSize.min,



                                      children: [



                                        Checkbox(



                                          value: allPresent,



                                          activeColor: AppColors.purplePrimary,



                                          onChanged: saving



                                              ? null



                                              : (val) => setDialogState(() => setAllStudentsPresent(val ?? false)),



                                        ),



                                        const Text(



                                          'เช็กบ็อกพิเศษ: มาเรียนทุกคน (100%)',



                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),



                                        ),



                                      ],



                                    ),



                                  ),



                                ),



                                const SizedBox(width: 8),



                                OutlinedButton.icon(



                                  style: OutlinedButton.styleFrom(



                                    backgroundColor: Colors.white,



                                    visualDensity: VisualDensity.compact,



                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),



                                  ),



                                  icon: const Icon(Icons.done_all, size: 16),



                                  label: Text(



                                    selectedWeekRange == 0 ? 'ทุกสัปดาห์มาทุกคน' : 'สัปดาห์นี้มาทุกคน',



                                    style: const TextStyle(fontSize: 12),



                                  ),



                                  onPressed: saving



                                      ? null



                                      : () => setDialogState(() => setVisibleWeeksPresent(visibleWeeks)),



                                ),



                                const SizedBox(width: 12),



                                // Summary Badges



                                Wrap(



                                  spacing: 8,



                                  children: [



                                    Chip(



                                      avatar: const Icon(Icons.check, size: 14, color: Colors.green),



                                      label: Text('รวมมา: $totalPresent คาบ', style: const TextStyle(fontSize: 12)),



                                      backgroundColor: Colors.white,



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    Chip(



                                      avatar: const Icon(Icons.schedule, size: 14, color: Colors.blue),



                                      label: Text('รวมสาย (ส): $totalLate คาบ', style: const TextStyle(fontSize: 12)),



                                      backgroundColor: Colors.white,



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    Chip(



                                      avatar: const Icon(Icons.close, size: 14, color: Colors.red),



                                      label: Text('รวมขาด (ว่าง): $totalAbsent คาบ', style: const TextStyle(fontSize: 12)),



                                      backgroundColor: Colors.white,



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    Chip(



                                      avatar: const Icon(Icons.event_busy, size: 14, color: Colors.orange),



                                      label: Text('รวมลา (ล): $totalLeave คาบ', style: const TextStyle(fontSize: 12)),



                                      backgroundColor: Colors.white,



                                      visualDensity: VisualDensity.compact,



                                    ),



                                  ],



                                ),



                              ],



                            ),



                            const Divider(height: 10),



                            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [



                                // Click Mode Selector



                                const Text(



                                  'โหมดคลิกช่อง: ',



                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),



                                ),



                                const SizedBox(width: 6),



                                SingleChildScrollView(scrollDirection: Axis.horizontal, child: SegmentedButton<String>(



                                  segments: const [



                                    ButtonSegment(



                                      value: 'present',



                                      label: Text('✓ มาเรียน (/)'),



                                      icon: Icon(Icons.check_circle_outline, size: 16, color: Colors.green),



                                    ),



                                    ButtonSegment(



                                      value: 'late',



                                      label: Text('ส สาย (จิตพิสัย)'),



                                      icon: Icon(Icons.schedule, size: 16, color: Colors.blue),



                                      tooltip: 'เช็คมาสาย (ส) — นับเป็นเวลาเรียน แต่ทำเครื่องหมาย ส เพื่อให้ครูพิจารณาคะแนนจิตพิสัย',



                                    ),



                                    ButtonSegment(



                                      value: 'leave',



                                      label: Text('ล ลา (ล)'),



                                      icon: Icon(Icons.pause_circle_outline, size: 16, color: Colors.orange),



                                    ),



                                    ButtonSegment(



                                      value: 'absent',



                                      label: Text('✕ ขาด (ว่าง)'),



                                      icon: Icon(Icons.highlight_off, size: 16, color: Colors.red),



                                    ),



                                  ],



                                  selected: {currentMode},



                                  onSelectionChanged: (val) => setDialogState(() => currentMode = val.first),



                                  style: const ButtonStyle(



                                    visualDensity: VisualDensity.compact,



                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,



                                  ),



                                )),



                                const SizedBox(width: 16),



                                // Week Filter Tabs



                                const Text(



                                  'ช่วงสัปดาห์: ',



                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),



                                ),



                                const SizedBox(width: 6),



                                Wrap(



                                  spacing: 4,



                                  children: [



                                    ChoiceChip(



                                      label: const Text('ทั้งหมด (1 - 20)', style: TextStyle(fontSize: 11)),



                                      selected: selectedWeekRange == 0,



                                      onSelected: (_) => setDialogState(() => selectedWeekRange = 0),



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    ChoiceChip(



                                      label: const Text('สัปดาห์ 1 - 5', style: TextStyle(fontSize: 11)),



                                      selected: selectedWeekRange == 1,



                                      onSelected: (_) => setDialogState(() => selectedWeekRange = 1),



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    ChoiceChip(



                                      label: const Text('สัปดาห์ 6 - 10', style: TextStyle(fontSize: 11)),



                                      selected: selectedWeekRange == 2,



                                      onSelected: (_) => setDialogState(() => selectedWeekRange = 2),



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    ChoiceChip(



                                      label: const Text('สัปดาห์ 11 - 15', style: TextStyle(fontSize: 11)),



                                      selected: selectedWeekRange == 3,



                                      onSelected: (_) => setDialogState(() => selectedWeekRange = 3),



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    ChoiceChip(



                                      label: const Text('สัปดาห์ 16 - 20', style: TextStyle(fontSize: 11)),



                                      selected: selectedWeekRange == 4,



                                      onSelected: (_) => setDialogState(() => selectedWeekRange = 4),



                                      visualDensity: VisualDensity.compact,



                                    ),



                                  ],



                                ),



                              ],



                            ),



                          ],



                        ),



                      ),



                      const SizedBox(height: 6),







                      // Instructions Note



                      Container(



                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),



                        decoration: BoxDecoration(



                          color: Colors.amber.shade50,



                          borderRadius: BorderRadius.circular(6),



                          border: Border.all(color: Colors.amber.shade200),



                        ),



                        child: Row(



                          children: [



                            Icon(Icons.info_outline, size: 14, color: Colors.amber.shade900),



                            const SizedBox(width: 6),



                            Expanded(



                              child: Text(



                                '💡 คลิกที่หัววันที่: กด 1 ครั้ง = "ล็อก แต่นับเวลาเรียน" (สีฟ้า 🔒 นับเวลา) | กด 2 ครั้ง = "ล็อก แบบไม่นับเวลาเรียน" (สีส้ม 🔒 ไม่นับ) | กด 3 ครั้ง = ปลดล็อก | ข้อมูลส่งออกตรง ปพ.5',



                                style: TextStyle(fontSize: 11, color: Colors.amber.shade900),



                              ),



                            ),



                          ],



                        ),



                      ),



                      const SizedBox(height: 6),







                      // Excel-Style Interactive Table with 4-Tier Header (Week, Month/Year, Day/Date, Period)



                      _fillOrFixed(MediaQuery.sizeOf(context).width < 700, 



                        child: Card(



                          clipBehavior: Clip.antiAlias,



                          margin: EdgeInsets.zero,



                          shape: RoundedRectangleBorder(



                            borderRadius: BorderRadius.circular(8),



                            side: BorderSide(color: Colors.grey.shade300),



                          ),



                          child: LayoutBuilder(builder: (context, gridConstraints) {
                            // Student names (290 px) always stay pinned on the left so the teacher sees whose row is
                            // being filled. When the remaining width is too small (phones), the summary (260 px) joins
                            // the check-in cells in the sideways scroll instead of squeezing them to nothing.
                            final bool narrowGrid = gridConstraints.maxWidth - 290 - 260 < 340;
                            Widget centerGrid() => Column(



                                      crossAxisAlignment: CrossAxisAlignment.start,



                                      children: [



                                        // Header Row 1: Week group titles (height 22)



                                        Row(



                                          children: visibleWeeks.map((w) {



                                            return Container(



                                              width: 34.0 * 5,



                                              height: 22,



                                              alignment: Alignment.center,



                                              decoration: BoxDecoration(



                                                color: AppColors.purpleContainer,



                                                border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                              ),



                                              child: Text(



                                                'สัปดาห์ที่ $w',



                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),



                                              ),



                                            );



                                          }).toList(),



                                        ),



                                        // Header Row 2: Month / Year Thai Abbr (height 22)



                                        Row(



                                          children: visibleWeeks.map((w) {



                                            final wData = (w - 1 < computedWeeks.length) ? computedWeeks[w - 1] : null;



                                            final mYear = wData?['month_year'] ?? '-';



                                            return Container(



                                              width: 34.0 * 5,



                                              height: 22,



                                              alignment: Alignment.center,



                                              decoration: BoxDecoration(



                                                color: AppColors.purpleBorder.withValues(alpha: 0.5),



                                                border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                              ),



                                              child: Text(



                                                mYear,



                                                style: TextStyle(



                                                  fontWeight: FontWeight.bold,



                                                  fontSize: 11,



                                                  color: AppColors.purpleDark,



                                                ),



                                              ),



                                            );



                                          }).toList(),



                                        ),



                                        // Header Row 3: Day Name & Date Number (height 26)



                                        Row(



                                          children: visibleWeeks.expand((w) {



                                            final wData = (w - 1 < computedWeeks.length) ? computedWeeks[w - 1] : null;



                                            final daysList = wData?['days'] as List? ?? [];



                                            return List.generate(5, (d) {



                                              final curDay = (d < daysList.length) ? daysList[d] : null;



                                              final dayNum = curDay?['day_num']?.toString() ?? '';



                                              final isTeaching = (courseSchedule[dayKeys[d]] ?? 0) > 0;



                                              final slotIdx = (w - 1) * 5 + d;



                                              final lockState = getSlotLockState(slotIdx);







                                              Color headerBg;



                                              Color headerBorder;



                                              Color headerTextColor;



                                              String tooltipMsg;



                                              Widget cellHeaderContent;







                                              if (lockState == 1) {



                                                // กด 1 ครั้ง: ล็อก แต่นับเวลาเรียน



                                                headerBg = Colors.blue.shade100;



                                                headerBorder = Colors.blue.shade500;



                                                headerTextColor = Colors.blue.shade900;



                                                tooltipMsg = 'สัปดาห์ที่ $w (${dayFullNames[d]} $dayNum): ล็อก แต่นับเวลาเรียน (คลิกอีกครั้งเพื่อเปลี่ยนเป็น "ล็อก ไม่นับเวลาเรียน")';



                                                cellHeaderContent = Column(



                                                  mainAxisAlignment: MainAxisAlignment.center,



                                                  children: [



                                                    Row(



                                                      mainAxisAlignment: MainAxisAlignment.center,



                                                      mainAxisSize: MainAxisSize.min,



                                                      children: [



                                                        Icon(Icons.lock, size: 9, color: Colors.blue.shade900),



                                                        Text(



                                                          '${dayLabels[d]}$dayNum',



                                                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: headerTextColor),



                                                        ),



                                                      ],



                                                    ),



                                                    Text('นับเวลา', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.blue.shade800)),



                                                  ],



                                                );



                                              } else if (lockState == 2) {



                                                // กด 2 ครั้ง: ล็อก แบบไม่นับเวลาเรียน



                                                headerBg = Colors.amber.shade100;



                                                headerBorder = Colors.orange.shade500;



                                                headerTextColor = Colors.deepOrange.shade900;



                                                tooltipMsg = 'สัปดาห์ที่ $w (${dayFullNames[d]} $dayNum): ล็อก ไม่นับเวลาเรียน (คลิกอีกครั้งเพื่อปลดล็อกกลับสู่ปกติ)';



                                                cellHeaderContent = Column(



                                                  mainAxisAlignment: MainAxisAlignment.center,



                                                  children: [



                                                    Row(



                                                      mainAxisAlignment: MainAxisAlignment.center,



                                                      mainAxisSize: MainAxisSize.min,



                                                      children: [



                                                        Icon(Icons.lock, size: 9, color: Colors.deepOrange.shade800),



                                                        Text(



                                                          '${dayLabels[d]}$dayNum',



                                                          style: TextStyle(



                                                            fontSize: 9,



                                                            fontWeight: FontWeight.bold,



                                                            color: headerTextColor,



                                                            decoration: TextDecoration.lineThrough,



                                                          ),



                                                        ),



                                                      ],



                                                    ),



                                                    Text('ไม่นับ', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.deepOrange.shade800)),



                                                  ],



                                                );



                                              } else if (!isTeaching) {



                                                headerBg = Colors.grey.shade200;



                                                headerBorder = Colors.grey.shade300;



                                                headerTextColor = Colors.grey.shade500;



                                                tooltipMsg = 'สัปดาห์ที่ $w (${dayFullNames[d]} $dayNum): ไม่มีคาบสอนตามตาราง (คลิกเพื่อตั้งค่าล็อก)';



                                                cellHeaderContent = Text(



                                                  '${dayLabels[d]}$dayNum',



                                                  style: TextStyle(fontSize: 10, color: headerTextColor),



                                                );



                                              } else {



                                                headerBg = Colors.green.shade100;



                                                headerBorder = Colors.green.shade400;



                                                headerTextColor = Colors.green.shade900;



                                                tooltipMsg = 'สัปดาห์ที่ $w (${dayFullNames[d]} $dayNum): สอนปกติ (คลิก 1 ครั้ง: ล็อกแต่นับ / คลิก 2 ครั้ง: ล็อกไม่นับ)';



                                                cellHeaderContent = Text(



                                                  '${dayLabels[d]}$dayNum',



                                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: headerTextColor),



                                                );



                                              }







                                              return Tooltip(



                                                message: tooltipMsg,



                                                child: InkWell(



                                                  onTap: saving ? null : () => setDialogState(() => cycleSlotLock(slotIdx)),



                                                  child: Container(



                                                    width: 34,



                                                    height: 26,



                                                    alignment: Alignment.center,



                                                    decoration: BoxDecoration(



                                                      color: headerBg,



                                                      border: Border.all(



                                                        color: headerBorder,



                                                        width: lockState > 0 || isTeaching ? 0.8 : 0.5,



                                                      ),



                                                    ),



                                                    child: cellHeaderContent,



                                                  ),



                                                ),



                                              );



                                            });



                                          }).toList(),



                                        ),



                                        // Header Row 4: Period Number (ชั่วโมงที่) (height 22)



                                        Row(



                                          children: visibleWeeks.expand((w) {



                                            return List.generate(5, (d) {



                                              final slotIdx = (w - 1) * 5 + d;



                                              final lockState = getSlotLockState(slotIdx);



                                              final periods = courseSchedule[dayKeys[d]] ?? 0;







                                              Color row4Bg;



                                              Color row4Border;



                                              String row4Text;



                                              Color row4TextColor;







                                              if (lockState == 1) {



                                                // ล็อก แต่นับเวลาเรียน



                                                row4Bg = Colors.blue.shade50;



                                                row4Border = Colors.blue.shade300;



                                                row4Text = '${periods > 0 ? periods : 1}';



                                                row4TextColor = Colors.blue.shade900;



                                              } else if (lockState == 2) {



                                                // ล็อก แบบไม่นับเวลาเรียน



                                                row4Bg = Colors.amber.shade50;



                                                row4Border = Colors.orange.shade200;



                                                row4Text = 'ไม่นับ';



                                                row4TextColor = Colors.deepOrange.shade800;



                                              } else if (periods > 0) {



                                                row4Bg = Colors.green.shade50;



                                                row4Border = Colors.green.shade300;



                                                row4Text = '$periods';



                                                row4TextColor = Colors.green.shade900;



                                              } else {



                                                row4Bg = Colors.grey.shade100;



                                                row4Border = Colors.grey.shade300;



                                                row4Text = '-';



                                                row4TextColor = Colors.grey.shade400;



                                              }







                                              return Container(



                                                width: 34,



                                                height: 22,



                                                alignment: Alignment.center,



                                                decoration: BoxDecoration(



                                                  color: row4Bg,



                                                  border: Border.all(



                                                    color: row4Border,



                                                    width: 0.7,



                                                  ),



                                                ),



                                                child: Text(



                                                  row4Text,



                                                  style: TextStyle(



                                                    fontSize: lockState == 2 ? 8 : 10,



                                                    fontWeight: lockState == 1 || periods > 0 ? FontWeight.bold : FontWeight.normal,



                                                    color: row4TextColor,



                                                  ),



                                                ),



                                              );



                                            });



                                          }).toList(),



                                        ),



                                        // Student data rows (Checkboxes/Marks with Highlighted Teaching Days)



                                        ...studentList.asMap().entries.map((entry) {



                                          final rowIdx = entry.key;



                                          final st = entry.value;



                                          final isEven = rowIdx % 2 == 0;



                                          final statusList = st['status_list'] as List<String>;







                                          return Container(



                                            height: 36,



                                            color: isEven ? Colors.white : Colors.grey.shade50,



                                            child: Row(



                                              children: visibleWeeks.expand((w) {



                                                final wData = (w - 1 < computedWeeks.length) ? computedWeeks[w - 1] : null;



                                                final daysList = wData?['days'] as List? ?? [];







                                                return List.generate(5, (d) {



                                                  final slotIdx = (w - 1) * 5 + d;



                                                  final val = (slotIdx < statusList.length) ? statusList[slotIdx] : '';



                                                  final curDay = (d < daysList.length) ? daysList[d] : null;



                                                  final lockState = getSlotLockState(slotIdx);



                                                  final isTeachingDay = (courseSchedule[dayKeys[d]] ?? 0) > 0;







                                                  final dayDateStr = curDay != null



                                                      ? '${curDay['day_num']} ${wData?['month_year'] ?? ""}'



                                                      : '';







                                                  if (lockState == 1) {



                                                    // 1: ล็อก แต่นับเวลาเรียน -> ทุกคนได้เครื่องหมายเช็คถูก สีฟ้า ล็อคไม่ให้แก้



                                                    return Tooltip(



                                                      message: 'สัปดาห์ที่ $w (${dayFullNames[d]} $dayDateStr): ล็อกแต่นับเวลาเรียน (มาเรียนปกติ)',



                                                      child: MouseRegion(



                                                        cursor: SystemMouseCursors.forbidden,



                                                        child: Container(



                                                          width: 34,



                                                          height: 36,



                                                          alignment: Alignment.center,



                                                          decoration: BoxDecoration(



                                                            color: Colors.blue.shade50.withValues(alpha: 0.6),



                                                            border: Border.all(color: Colors.blue.shade300, width: 0.6),



                                                          ),



                                                          child: Row(



                                                            mainAxisAlignment: MainAxisAlignment.center,



                                                            mainAxisSize: MainAxisSize.min,



                                                            children: [



                                                              Icon(Icons.check, size: 14, color: Colors.blue.shade700),



                                                              Icon(Icons.lock_outline, size: 9, color: Colors.blue.shade400),



                                                            ],



                                                          ),



                                                        ),



                                                      ),



                                                    );



                                                  } else if (lockState == 2) {



                                                    // 2: ล็อก แบบไม่นับเวลาเรียน -> ช่องว่างสีส้มอ่อน ล็อค ไม่นับเป็นขาดเรียน



                                                    return Tooltip(



                                                      message: 'สัปดาห์ที่ $w (${dayFullNames[d]} $dayDateStr): ล็อกไม่นับเวลาเรียน (ไม่นับเป็นขาดเรียน)',



                                                      child: MouseRegion(



                                                        cursor: SystemMouseCursors.forbidden,



                                                        child: Container(



                                                          width: 34,



                                                          height: 36,



                                                          alignment: Alignment.center,



                                                          decoration: BoxDecoration(



                                                            color: Colors.amber.shade50.withValues(alpha: 0.5),



                                                            border: Border.all(color: Colors.amber.shade200, width: 0.5),



                                                          ),



                                                          child: Icon(Icons.lock_outline, size: 12, color: Colors.orange.shade700),



                                                        ),



                                                      ),



                                                    );



                                                  } else if (!isTeachingDay) {



                                                    // ไม่มีคาบสอนตามตาราง



                                                    return Tooltip(



                                                      message: 'สัปดาห์ที่ $w (${dayFullNames[d]} $dayDateStr): ไม่มีคาบสอนตามตาราง (ช่องถูกล็อก)',



                                                      child: MouseRegion(



                                                        cursor: SystemMouseCursors.forbidden,



                                                        child: Container(



                                                          width: 34,



                                                          height: 36,



                                                          alignment: Alignment.center,



                                                          decoration: BoxDecoration(



                                                            color: isEven ? Colors.grey.shade200.withValues(alpha: 0.8) : Colors.grey.shade200,



                                                            border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                          ),



                                                          child: Icon(Icons.lock_outline, size: 12, color: Colors.grey.shade400),



                                                        ),



                                                      ),



                                                    );



                                                  }







                                                  Color cellBg;



                                                  Border cellBorder;



                                                  Widget cellContent;







                                                  if (val == '/') {



                                                    cellBg = Colors.green.shade100;



                                                    cellBorder = Border.all(color: Colors.green.shade400, width: 0.7);



                                                    cellContent = const Icon(Icons.check, size: 16, color: Colors.green);



                                                  } else if (val == 'ส') {



                                                    cellBg = Colors.blue.shade100;



                                                    cellBorder = Border.all(color: Colors.blue.shade400, width: 0.7);



                                                    cellContent = const Text(



                                                      'ส',



                                                      style: TextStyle(



                                                        fontSize: 13,



                                                        fontWeight: FontWeight.bold,



                                                        color: Colors.blue,



                                                      ),



                                                    );



                                                  } else if (val == 'ล') {



                                                    cellBg = Colors.orange.shade50;



                                                    cellBorder = Border.all(color: Colors.orange.shade300, width: 0.7);



                                                    cellContent = Text(



                                                      'ล',



                                                      style: TextStyle(



                                                        fontSize: 12,



                                                        fontWeight: FontWeight.bold,



                                                        color: Colors.orange.shade900,



                                                      ),



                                                    );



                                                  } else {



                                                    // Teaching day without mark (absent/blank): Highlighted in Green



                                                    cellBg = isEven



                                                        ? Colors.green.shade50.withValues(alpha: 0.45)



                                                        : Colors.green.shade50.withValues(alpha: 0.25);



                                                    cellBorder = Border.all(color: Colors.green.shade200, width: 0.5);



                                                    cellContent = const SizedBox.shrink();



                                                  }







                                                  return Tooltip(



                                                    message: 'สัปดาห์ที่ $w (${dayFullNames[d]} $dayDateStr): '



                                                        '${val == "/" ? "มาเรียน (/)" : val == "ส" ? "มาสาย (ส) — ครูพิจารณาจิตพิสัย" : val == "ล" ? "ลา (ล)" : "ขาด (ว่าง)"}',



                                                    child: InkWell(



                                                      onTap: () => setDialogState(() => toggleCell(st, slotIdx)),



                                                      child: Container(



                                                        width: 34,



                                                        height: 36,



                                                        alignment: Alignment.center,



                                                        decoration: BoxDecoration(



                                                          color: cellBg,



                                                          border: cellBorder,



                                                        ),



                                                        child: cellContent,



                                                      ),



                                                    ),



                                                  );



                                                });



                                              }).toList(),



                                            ),



                                          );



                                        }),



                                      ],



                                    );
                            Widget summaryColumn() => SizedBox(



                                  width: 260,



                                  child: Column(



                                    children: [



                                      // Header Row 1 (height 22)



                                      Container(



                                        height: 22,



                                        alignment: Alignment.center,



                                        decoration: BoxDecoration(



                                          color: Colors.grey.shade200,



                                          border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                        ),



                                        child: const Text(



                                          'สรุปเวลาเรียน',



                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),



                                        ),



                                      ),



                                      // Header Row 2 (height 22)



                                      Container(



                                        height: 22,



                                        alignment: Alignment.center,



                                        decoration: BoxDecoration(



                                          color: Colors.grey.shade100,



                                          border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                        ),



                                        child: Text(



                                          (holidaySlots.isEmpty && lockedCountedSlots.isEmpty)



                                              ? 'ถึงวันนี้ ${computeElapsedPeriods()} / เกณฑ์ $totalActualPeriods คาบ'



                                              : 'ถึงวันนี้ ${computeElapsedPeriods()} / เกณฑ์ $totalActualPeriods คาบ${lockedCountedSlots.isNotEmpty ? " (ล็อกนับ ${lockedCountedSlots.length} วัน)" : ""}${holidaySlots.isNotEmpty ? " (ไม่นับ ${holidaySlots.length} วัน)" : ""}',



                                          style: TextStyle(



                                            fontWeight: FontWeight.bold,



                                            fontSize: 9,



                                            color: (holidaySlots.isNotEmpty || lockedCountedSlots.isNotEmpty) ? Colors.deepOrange.shade800 : AppColors.purplePrimary,



                                          ),



                                        ),



                                      ),



                                      // Header Row 3 (height 26)



                                      Row(



                                        children: [



                                          Container(



                                            width: 45,



                                            height: 26,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('มา (/)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.green)),



                                          ),



                                          Container(



                                            width: 45,



                                            height: 26,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('สาย (ส)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.blue)),



                                          ),



                                          Container(



                                            width: 45,



                                            height: 26,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('ขาด', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.red)),



                                          ),



                                          Container(



                                            width: 45,



                                            height: 26,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('ลา (ล)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.orange)),



                                          ),



                                          Container(



                                            width: 80,



                                            height: 26,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('ร้อยละ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: AppColors.purplePrimary)),



                                          ),



                                        ],



                                      ),



                                      // Header Row 4: Units (height 22)



                                      Row(



                                        children: [



                                          Container(



                                            width: 45,



                                            height: 22,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('คาบ', style: TextStyle(fontSize: 10, color: Colors.grey)),



                                          ),



                                          Container(



                                            width: 45,



                                            height: 22,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('คาบ', style: TextStyle(fontSize: 10, color: Colors.grey)),



                                          ),



                                          Container(



                                            width: 45,



                                            height: 22,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('คาบ', style: TextStyle(fontSize: 10, color: Colors.grey)),



                                          ),



                                          Container(



                                            width: 45,



                                            height: 22,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('คาบ', style: TextStyle(fontSize: 10, color: Colors.grey)),



                                          ),



                                          Container(



                                            width: 80,



                                            height: 22,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('%', style: TextStyle(fontSize: 10, color: Colors.grey)),



                                          ),



                                        ],



                                      ),



                                      // Student rows summary counts



                                      ...studentList.asMap().entries.map((entry) {



                                        final rowIdx = entry.key;



                                        final st = entry.value;



                                        final isEven = rowIdx % 2 == 0;



                                        final pCount = st['present_count'] as int;



                                        final ltCount = (st['late_count'] as int?) ?? 0;



                                        final aCount = st['absent_count'] as int;



                                        final lCount = st['leave_count'] as int;



                                        final pct = (st['percentage'] as num).toDouble();







                                        return Container(



                                          height: 36,



                                          color: isEven ? Colors.white : Colors.grey.shade50,



                                          child: Row(



                                            children: [



                                              Container(



                                                width: 45,



                                                height: 36,



                                                alignment: Alignment.center,



                                                decoration: BoxDecoration(



                                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                ),



                                                child: Text(



                                                  '$pCount',



                                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green),



                                                ),



                                              ),



                                              Container(



                                                width: 45,



                                                height: 36,



                                                alignment: Alignment.center,



                                                decoration: BoxDecoration(



                                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                ),



                                                child: Text(



                                                  '$ltCount',



                                                  style: TextStyle(



                                                    fontSize: 11,



                                                    fontWeight: FontWeight.bold,



                                                    color: ltCount > 0 ? Colors.blue.shade800 : Colors.grey,



                                                  ),



                                                ),



                                              ),



                                              Container(



                                                width: 45,



                                                height: 36,



                                                alignment: Alignment.center,



                                                decoration: BoxDecoration(



                                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                ),



                                                child: Text(



                                                  '$aCount',



                                                  style: TextStyle(



                                                    fontSize: 11,



                                                    fontWeight: FontWeight.bold,



                                                    color: aCount > 0 ? Colors.red.shade700 : Colors.grey,



                                                  ),



                                                ),



                                              ),



                                              Container(



                                                width: 45,



                                                height: 36,



                                                alignment: Alignment.center,



                                                decoration: BoxDecoration(



                                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                ),



                                                child: Text(



                                                  '$lCount',



                                                  style: TextStyle(



                                                    fontSize: 11,



                                                    fontWeight: FontWeight.bold,



                                                    color: lCount > 0 ? Colors.orange.shade800 : Colors.grey,



                                                  ),



                                                ),



                                              ),



                                              Container(



                                                width: 80,



                                                height: 36,



                                                alignment: Alignment.center,



                                                decoration: BoxDecoration(



                                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                ),



                                                child: Text(



                                                  '${pct.toStringAsFixed(1)}%',



                                                  style: TextStyle(



                                                    fontSize: 11,



                                                    fontWeight: FontWeight.bold,



                                                    color: AppColors.purplePrimary,



                                                  ),



                                                ),



                                              ),



                                            ],



                                          ),



                                        );



                                      }),



                                    ],



                                  ),



                                );
                            return SingleChildScrollView(



                            scrollDirection: Axis.vertical,



                            child: Row(



                              crossAxisAlignment: CrossAxisAlignment.start,



                              children: [



                                // 1. Fixed Left: Student Info Header & Rows



                                SizedBox(



                                  width: 290,



                                  child: Column(



                                    children: [



                                      // Header Row 1: Title (height 22)



                                      Container(



                                        height: 22,



                                        alignment: Alignment.center,



                                        decoration: BoxDecoration(



                                          color: Colors.grey.shade200,



                                          border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                        ),



                                        child: const Text(



                                          'รายชื่อนักเรียน',



                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),



                                        ),



                                      ),



                                      // Header Row 2: Month/Year Label (height 22)



                                      Container(



                                        height: 22,



                                        alignment: Alignment.center,



                                        decoration: BoxDecoration(



                                          color: Colors.grey.shade100,



                                          border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                        ),



                                        child: const Text(



                                          'เดือน / ปี',



                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: AppColors.purplePrimary),



                                        ),



                                      ),



                                      // Header Row 3: Column Titles (height 26)



                                      Row(



                                        children: [



                                          Container(



                                            width: 44,



                                            height: 26,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('ที่', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),



                                          ),



                                          Container(



                                            width: 86,



                                            height: 26,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('รหัสประจำตัว', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),



                                          ),



                                          Container(



                                            width: 160,



                                            height: 26,



                                            alignment: Alignment.center,



                                            decoration: BoxDecoration(



                                              color: Colors.grey.shade100,



                                              border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                            ),



                                            child: const Text('ชื่อ - นามสกุล', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),



                                          ),



                                        ],



                                      ),



                                      // Header Row 4: Period Label (height 22)



                                      Container(



                                        height: 22,



                                        alignment: Alignment.center,



                                        decoration: BoxDecoration(



                                          color: Colors.grey.shade100,



                                          border: Border.all(color: Colors.grey.shade400, width: 0.5),



                                        ),



                                        child: const Text(



                                          'ชั่วโมงที่ / คาบที่',



                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: AppColors.purplePrimary),



                                        ),



                                      ),



                                      // Student rows



                                      ...studentList.asMap().entries.map((entry) {



                                        final rowIdx = entry.key;



                                        final st = entry.value;



                                        final isEven = rowIdx % 2 == 0;



                                        return Container(



                                          height: 36,



                                          color: isEven ? Colors.white : Colors.grey.shade50,



                                          child: Row(



                                            children: [



                                              Container(



                                                width: 44,



                                                height: 36,



                                                alignment: Alignment.center,



                                                decoration: BoxDecoration(



                                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                ),



                                                child: Text('${st['student_no']}', style: const TextStyle(fontSize: 11)),



                                              ),



                                              Container(



                                                width: 86,



                                                height: 36,



                                                alignment: Alignment.center,



                                                decoration: BoxDecoration(



                                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                ),



                                                child: Text('${st['student_id']}', style: const TextStyle(fontSize: 11)),



                                              ),



                                              Container(



                                                width: 160,



                                                height: 36,



                                                alignment: Alignment.centerLeft,



                                                padding: const EdgeInsets.symmetric(horizontal: 8),



                                                decoration: BoxDecoration(



                                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),



                                                ),



                                                child: Text(



                                                  '${st['full_name']}',



                                                  overflow: TextOverflow.ellipsis,



                                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),



                                                ),



                                              ),



                                            ],



                                          ),



                                        );



                                      }),



                                    ],



                                  ),



                                ),







                                // 2. Scrollable Center: Weeks & Days (4-tier Header: Week, Month/Year, Day/Date, Period)



                                Expanded(



                                  child: SingleChildScrollView(



                                    scrollDirection: Axis.horizontal,



                                    child: narrowGrid
                                        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [centerGrid(), summaryColumn()])
                                        : centerGrid(),



                                  ),



                                ),











                                // 3. Fixed Right: Summary Columns (scrolls with the cells on narrow screens)
                                if (!narrowGrid) summaryColumn(),



                              ],



                            ),



                          );
                          }),



                        ),



                      ),



                      const SizedBox(height: 12),







                      // Actions



                      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [



                          OutlinedButton.icon(



                            icon: const Icon(Icons.sync_alt, size: 18),



                            label: const Text('นำเข้า/ซิงค์จากเช็คชื่อประจำวัน'),



                            style: OutlinedButton.styleFrom(



                              foregroundColor: Colors.teal.shade800,



                              side: BorderSide(color: Colors.teal.shade300),



                            ),



                            onPressed: saving



                                ? null



                                : () async {



                                    setDialogState(() => saving = true);



                                    try {



                                      final fresh = await widget.apiService.getAttendance(



                                        course.courseCode,



                                        term: course.term,



                                        year: course.year,



                                        syncFromDaily: true,



                                      );



                                      final freshStudents = List<Map<String, dynamic>>.from(fresh['students'] ?? []);



                                      if (freshStudents.isNotEmpty) {



                                        for (var fs in freshStudents) {



                                          final idx = studentList.indexWhere((s) => s['student_id'] == fs['student_id']);



                                          if (idx != -1) {



                                            studentList[idx]['status_list'] = List<String>.from(fs['status_list'] ?? []);



                                            studentList[idx]['present_count'] = fs['present_count'] ?? 0;



                                            studentList[idx]['absent_count'] = fs['absent_count'] ?? 0;



                                            studentList[idx]['leave_count'] = fs['leave_count'] ?? 0;



                                            studentList[idx]['percentage'] = fs['percentage'] ?? 100.0;



                                          }



                                        }



                                        for (var st in studentList) {



                                          recalculate(st);



                                        }



                                        final totHours = computeElapsedPeriods();



                                        allPresent = studentList.every((s) => (s['present_count'] as int) == totHours);



                                        if (mounted) {



                                          ScaffoldMessenger.of(context).showSnackBar(



                                            const SnackBar(



                                              backgroundColor: Colors.teal,



                                              content: Text('ซิงค์ข้อมูลจากตารางเช็คเวลาเรียนประจำวันเรียบร้อยแล้ว ครูสามารถปรับแก้ตามดุลยพินิจได้'),



                                            ),



                                          );



                                        }



                                      }



                                    } catch (e) {



                                      if (mounted) {



                                        ScaffoldMessenger.of(context).showSnackBar(



                                          SnackBar(



                                            backgroundColor: Colors.red.shade700,



                                            content: Text('ซิงค์ข้อมูลไม่สำเร็จ: '),



                                          ),



                                        );



                                      }



                                    } finally {



                                      setDialogState(() => saving = false);



                                    }



                                  },



                          ),



                          Row(mainAxisSize: MainAxisSize.min, 



                            children: [



                              TextButton(



                                onPressed: saving ? null : () => Navigator.of(ctx).pop(),



                                child: const Text('ยกเลิก'),



                              ),



                              const SizedBox(width: 8),



                              if (canManage)



                                FilledButton.icon(



                            onPressed: saving



                                ? null



                                : () async {



                                    setDialogState(() => saving = true);



                                    try {



                                      final payloadStudents = studentList.map((st) {



                                        return {



                                          'student_id': st['student_id'],



                                          'student_no': st['student_no'],



                                          'full_name': st['full_name'],



                                          'present_count': st['present_count'],



                                          'absent_count': st['absent_count'],



                                          'leave_count': st['leave_count'],



                                          'percentage': st['percentage'],



                                          'status_list': st['status_list'],



                                        };



                                      }).toList();







                                      final isoStart = '${selectedStartDate.year.toString().padLeft(4, '0')}-${selectedStartDate.month.toString().padLeft(2, '0')}-${selectedStartDate.day.toString().padLeft(2, '0')}';







                                      final schedulePayload = Map<String, dynamic>.from(courseSchedule);



                                      schedulePayload['holidays'] = holidaySlots.toList();



                                      schedulePayload['locked_counted'] = lockedCountedSlots.toList();







                                      final res = await widget.apiService.saveAttendance(



                                        courseCode: course.courseCode,



                                        term: course.term,



                                        year: course.year,



                                        startDate: isoStart,



                                        schedule: schedulePayload,



                                        students: payloadStudents,



                                      );







                                      if (mounted) {



                                        Navigator.of(ctx).pop();



                                        ScaffoldMessenger.of(context).showSnackBar(



                                          SnackBar(



                                            backgroundColor: Colors.teal.shade700,



                                            content: Text(



                                              'บันทึกเวลาเรียนลง ปพ.5 (${res['db_updated']} คน) และอัปเดตไฟล์ Excel & PDF สำเร็จแล้ว',



                                            ),



                                          ),



                                        );



                                        _loadGrades();



                                      }



                                    } catch (e) {



                                      setDialogState(() => saving = false);



                                      if (mounted) {



                                        ScaffoldMessenger.of(context).showSnackBar(



                                          SnackBar(



                                            backgroundColor: Colors.red.shade700,



                                            content: Text('บันทึกเวลาเรียนไม่สำเร็จ: $e'),



                                          ),



                                        );



                                      }



                                    }



                                  },



                            icon: saving



                                ? const SizedBox(



                                    width: 16,



                                    height: 16,



                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),



                                  )



                                : const Icon(Icons.save_rounded, size: 18),



                            label: Text(saving ? 'กำลังบันทึกและอัปเดตไฟล์...' : 'บันทึกเวลาเรียนลง ปพ.5'),



                            style: FilledButton.styleFrom(



                              backgroundColor: AppColors.purplePrimary,



                              foregroundColor: Colors.white,



                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),



                            ),



                          )



                              else



                                Container(



                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),



                                  decoration: BoxDecoration(



                                    color: const Color(0xFFFFF8E1),



                                    borderRadius: BorderRadius.circular(8),



                                    border: Border.all(color: const Color(0xFFFFE082)),



                                  ),



                                  child: const Row(



                                    mainAxisSize: MainAxisSize.min,



                                    children: [



                                      Icon(Icons.lock_outline_rounded, size: 16, color: Color(0xFFE65100)),



                                      SizedBox(width: 6),



                                      Text(



                                        'โหมดดูเวลาเรียนอย่างเดียว (แก้ไขได้เฉพาะวิชาที่ท่านสอน)',



                                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFE65100)),



                                      ),



                                    ],



                                  ),



                                ),



                        ],



                      ),



                        ],



                      ),



                    ],



                  )),



                ),



              ),



            );



          },



        );



      },



    );



  }







  ({String? term, String? year, String name, Color color}) get _currentSemesterInfo {



    final theme = Theme.of(context);



    if (_selectedSemesterKey == 'all') {



      return (term: null, year: null, name: 'ทุกภาคเรียน', color: theme.colorScheme.secondary);



    }



    final parts = _selectedSemesterKey.split('-');



    if (parts.length == 2) {



      final t = parts[0];



      final y = parts[1];



      final index = _semesterConfigs.indexWhere((c) => c.term == t && c.year == y);



      final color = index >= 0 ? _semesterPalette[index % _semesterPalette.length] : theme.colorScheme.primary;



      if (index >= 0) {



        return (term: t, year: y, name: _semesterConfigs[index].title, color: color);



      }



      return (term: t, year: y, name: 'ปีการศึกษา $y ภาคเรียนที่ $t', color: color);



    }



    return (term: null, year: null, name: 'ทุกภาคเรียน', color: theme.colorScheme.secondary);



  }







  Future<void> _openImportExcelDialog() async {



    int activeTab = 0; // 0: Select Files, 1: Scan Folder



    final List<({String name, Uint8List bytes, int size})> selectedFiles = [];



    final folderController = TextEditingController(



      text: '',



    );



    final teacherController = TextEditingController();



    final curSem = _currentSemesterInfo;



    String selectedTerm = curSem.term ?? 'auto'; // 'auto', '1', '2'



    String selectedYear = curSem.year ?? 'auto'; // 'auto', '2568', '2569', '2567'



    bool isProcessing = false;



    String? statusMessage;



    String? errorMessage;



    Map<String, dynamic>? completionResult;







    await showDialog(



      context: context,



      barrierDismissible: false,



      builder: (dialogCtx) {



        return StatefulBuilder(



          builder: (ctx, setDialogState) {



            Future<void> pickExcelFiles() async {



              try {



                final pickedFiles = await FilePicker.pickFiles(



                  dialogTitle: 'เลือกไฟล์ Excel (.xlsx, .xls) ได้หลายไฟล์พร้อมกัน',



                  type: FileType.custom,



                  allowedExtensions: ['xlsx', 'xls'],



                );



                if (pickedFiles.isEmpty) return;







                final List<({String name, Uint8List bytes, int size})> newItems = [];



                for (final picked in pickedFiles) {



                  if (selectedFiles.any((f) => f.name == picked.name)) continue;



                  final bytes = await picked.readAsBytes();



                  newItems.add((



                    name: picked.name,



                    bytes: bytes,



                    size: picked.lengthSync() ?? bytes.length,



                  ));



                }







                setDialogState(() {



                  selectedFiles.addAll(newItems);



                  errorMessage = null;



                });



              } catch (e) {



                setDialogState(() => errorMessage = 'เลือกไฟล์ไม่สำเร็จ: $e');



              }



            }







            Future<void> startImportFiles() async {



              if (selectedFiles.isEmpty) return;



              setDialogState(() {



                isProcessing = true;



                statusMessage = 'กำลังอ่านและนำเข้าไฟล์ Excel ${selectedFiles.length} ไฟล์ สู่คลังข้อมูล...';



                errorMessage = null;



                completionResult = null;



              });







              try {



                final teacherVal = teacherController.text.trim();



                final res = await widget.apiService.importExcelFiles(



                  files: selectedFiles.map((f) => (bytes: f.bytes, filename: f.name)).toList(),



                  term: selectedTerm != 'auto' ? selectedTerm : null,



                  year: selectedYear != 'auto' ? selectedYear : null,



                  teacher: teacherVal.isNotEmpty ? teacherVal : null,



                );







                setDialogState(() {



                  isProcessing = false;



                  completionResult = res;



                });







                await _loadCourses();



                if (mounted && _allCourses.isNotEmpty) {



                  final availableInSemester = _filteredCourses;



                  if (availableInSemester.isNotEmpty) {



                    setState(() {



                      _selectedCourse = availableInSemester.first;



                    });



                    _loadGrades();



                  }



                }



              } catch (e) {



                setDialogState(() {



                  isProcessing = false;



                  errorMessage = 'เกิดข้อผิดพลาดในการนำเข้า: $e';



                });



              }



            }







            Future<void> startImportFolder() async {



              final path = folderController.text.trim();



              if (path.isEmpty) {



                setDialogState(() => errorMessage = 'กรุณาระบุที่อยู่โฟลเดอร์');



                return;



              }







              setDialogState(() {



                isProcessing = true;



                statusMessage = 'กำลังสแกนและนำเข้าไฟล์ Excel จากโฟลเดอร์... กรุณารอสักครู่';



                errorMessage = null;



                completionResult = null;



              });







              try {



                final teacherVal = teacherController.text.trim();



                final res = await widget.apiService.importExcelFolder(



                  folderPath: path,



                  term: selectedTerm != 'auto' ? selectedTerm : null,



                  year: selectedYear != 'auto' ? selectedYear : null,



                  teacher: teacherVal.isNotEmpty ? teacherVal : null,



                );







                setDialogState(() {



                  isProcessing = false;



                  completionResult = res;



                });







                await _loadCourses();



                if (mounted && _allCourses.isNotEmpty) {



                  final availableInSemester = _filteredCourses;



                  if (availableInSemester.isNotEmpty) {



                    setState(() {



                      _selectedCourse = availableInSemester.first;



                    });



                    _loadGrades();



                  }



                }



              } catch (e) {



                setDialogState(() {



                  isProcessing = false;



                  errorMessage = 'เกิดข้อผิดพลาดในการสแกนโฟลเดอร์: $e';



                });



              }



            }







            return Dialog(



              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



              child: ConstrainedBox(



                constraints: const BoxConstraints(maxWidth: 820, maxHeight: 750),



                child: Padding(



                  padding: const EdgeInsets.all(22),



                  child: Column(



                    crossAxisAlignment: CrossAxisAlignment.stretch,



                    children: [



                      // Header



                      Row(



                        children: [



                          Container(



                            padding: const EdgeInsets.all(8),



                            decoration: BoxDecoration(



                              color: Colors.teal.shade50,



                              borderRadius: BorderRadius.circular(10),



                            ),



                            child: Icon(Icons.table_view_rounded, size: 28, color: Colors.teal.shade700),



                          ),



                          const SizedBox(width: 12),



                          Expanded(



                            child: Column(



                              crossAxisAlignment: CrossAxisAlignment.start,



                              children: [



                                const Text(



                                  'นำเข้าข้อมูลจากไฟล์ Excel (.xlsx) สู่คลังข้อมูล',



                                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),



                                ),



                                const SizedBox(height: 2),



                                Text(



                                  'รองรับการอ่านรายวิชา รายชื่อนักเรียน ผลการเรียน และตารางเวลาเรียนจาก ปพ.5',



                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),



                                ),



                              ],



                            ),



                          ),



                          IconButton(



                            icon: const Icon(Icons.close),



                            onPressed: isProcessing ? null : () => Navigator.of(ctx).pop(),



                          ),



                        ],



                      ),



                      const Divider(height: 24),







                      // Semester Destination Banner



                      if (curSem.term != null)



                        Container(



                          margin: const EdgeInsets.only(bottom: 12),



                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),



                          decoration: BoxDecoration(



                            color: curSem.color.withValues(alpha: 0.1),



                            borderRadius: BorderRadius.circular(8),



                            border: Border.all(color: curSem.color.withValues(alpha: 0.35)),



                          ),



                          child: Row(



                            children: [



                              Icon(Icons.bookmark_added_rounded, size: 20, color: curSem.color),



                              const SizedBox(width: 10),



                              Expanded(



                                child: Text(



                                  'คลังข้อมูลเป้าหมาย: ${curSem.name} (ตั้งค่าให้ตรงกับคลังนี้อัตโนมัติ)',



                                  style: TextStyle(



                                    fontSize: 13,



                                    fontWeight: FontWeight.bold,



                                    color: curSem.color,



                                  ),



                                ),



                              ),



                            ],



                          ),



                        ),







                      // Override controls: Term & Year



                      Container(



                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),



                        decoration: BoxDecoration(



                          color: Colors.grey.shade50,



                          borderRadius: BorderRadius.circular(8),



                          border: Border.all(color: Colors.grey.shade200),



                        ),



                        child: Row(



                          children: [



                            const Icon(Icons.tune_rounded, size: 18, color: Colors.grey),



                            const SizedBox(width: 8),



                            const Text(



                              'กำหนดภาคเรียน/ปีการศึกษา:',



                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),



                            ),



                            const SizedBox(width: 12),



                            // Term dropdown



                            DropdownButton<String>(



                              value: selectedTerm,



                              isDense: true,



                              underline: const SizedBox.shrink(),



                              items: const [



                                DropdownMenuItem(value: 'auto', child: Text('ภาคเรียน: อัตโนมัติจากไฟล์', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '1', child: Text('ภาคเรียนที่ 1', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '2', child: Text('ภาคเรียนที่ 2', style: TextStyle(fontSize: 12))),



                              ],



                              onChanged: isProcessing ? null : (val) {



                                if (val != null) setDialogState(() => selectedTerm = val);



                              },



                            ),



                            const SizedBox(width: 16),



                            // Year dropdown



                            DropdownButton<String>(



                              value: selectedYear,



                              isDense: true,



                              underline: const SizedBox.shrink(),



                              items: const [



                                DropdownMenuItem(value: 'auto', child: Text('ปีการศึกษา: อัตโนมัติจากไฟล์', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '2568', child: Text('ปีการศึกษา 2568', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '2569', child: Text('ปีการศึกษา 2569', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '2567', child: Text('ปีการศึกษา 2567', style: TextStyle(fontSize: 12))),



                              ],



                              onChanged: isProcessing ? null : (val) {



                                if (val != null) setDialogState(() => selectedYear = val);



                              },



                            ),



                          ],



                        ),



                      ),



                      const SizedBox(height: 10),



                      TextField(



                        controller: teacherController,



                        enabled: !isProcessing,



                        decoration: const InputDecoration(



                          labelText: 'ชื่อครูผู้สอน (เว้นว่างไว้เพื่อดึงชื่อครูอัตโนมัติตามโฟลเดอร์/หน้าปกของแต่ละท่าน)',



                          hintText: 'เว้นว่างไว้เพื่อตรวจจับอัตโนมัติ หรือระบุชื่อครูหากเป็นไฟล์ของครูคนเดียว',



                          prefixIcon: Icon(Icons.person_outline, size: 20),



                          border: OutlineInputBorder(),



                          isDense: true,



                        ),



                      ),



                      const SizedBox(height: 14),







                      // Tab selector



                      SegmentedButton<int>(



                        segments: const [



                          ButtonSegment(



                            value: 0,



                            label: Text('เลือกไฟล์จากเครื่อง (Upload Files)'),



                            icon: Icon(Icons.file_present_rounded, size: 18),



                          ),



                          ButtonSegment(



                            value: 1,



                            label: Text('สแกนจากโฟลเดอร์ / OneDrive (Scan Folder)'),



                            icon: Icon(Icons.folder_open_rounded, size: 18),



                          ),



                        ],



                        selected: {activeTab},



                        onSelectionChanged: isProcessing



                            ? null



                            : (val) => setDialogState(() {



                                activeTab = val.first;



                                errorMessage = null;



                                completionResult = null;



                              }),



                        style: const ButtonStyle(



                          visualDensity: VisualDensity.compact,



                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,



                        ),



                      ),



                      const SizedBox(height: 16),







                      // Content Body



                      Expanded(



                        child: SingleChildScrollView(



                          child: Column(



                            crossAxisAlignment: CrossAxisAlignment.stretch,



                            children: [



                              if (activeTab == 0) ...[



                                // TAB 0: File Upload



                                Row(



                                  children: [



                                    ElevatedButton.icon(



                                      style: ElevatedButton.styleFrom(



                                        backgroundColor: Colors.teal.shade50,



                                        foregroundColor: Colors.teal.shade900,



                                        elevation: 0,



                                        side: BorderSide(color: Colors.teal.shade300),



                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),



                                      ),



                                      icon: const Icon(Icons.file_upload_outlined, size: 18),



                                      label: const Text('เลือกไฟล์ Excel (.xlsx, .xls)'),



                                      onPressed: isProcessing ? null : pickExcelFiles,



                                    ),



                                    const SizedBox(width: 12),



                                    if (selectedFiles.isNotEmpty) ...[



                                      Chip(



                                        avatar: const Icon(Icons.check, size: 14, color: Colors.teal),



                                        label: Text('เลือกแล้ว ${selectedFiles.length} ไฟล์', style: const TextStyle(fontSize: 12)),



                                        backgroundColor: Colors.teal.shade50,



                                      ),



                                      const Spacer(),



                                      TextButton.icon(



                                        icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),



                                        label: const Text('ล้างทั้งหมด', style: TextStyle(color: Colors.red, fontSize: 12)),



                                        onPressed: isProcessing ? null : () => setDialogState(() => selectedFiles.clear()),



                                      ),



                                    ],



                                  ],



                                ),



                                const SizedBox(height: 12),







                                if (selectedFiles.isEmpty)



                                  Container(



                                    height: 160,



                                    decoration: BoxDecoration(



                                      color: Colors.grey.shade50,



                                      borderRadius: BorderRadius.circular(12),



                                      border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),



                                    ),



                                    alignment: Alignment.center,



                                    child: Column(



                                      mainAxisAlignment: MainAxisAlignment.center,



                                      children: [



                                        Icon(Icons.table_chart_outlined, size: 48, color: Colors.teal.shade300),



                                        const SizedBox(height: 10),



                                        const Text(



                                          'ยังไม่ได้เลือกไฟล์',



                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),



                                        ),



                                        const SizedBox(height: 4),



                                        Text(



                                          'คลิกปุ่ม "เลือกไฟล์ Excel" ด้านบน เพื่อเลือกไฟล์ ปพ.5 (เลือกได้หลายไฟล์พร้อมกัน)',



                                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),



                                        ),



                                      ],



                                    ),



                                  )



                                else



                                  Container(



                                    constraints: const BoxConstraints(maxHeight: 200),



                                    decoration: BoxDecoration(



                                      border: Border.all(color: Colors.grey.shade300),



                                      borderRadius: BorderRadius.circular(8),



                                    ),



                                    child: ListView.separated(



                                      shrinkWrap: true,



                                      itemCount: selectedFiles.length,



                                      separatorBuilder: (c, i) => const Divider(height: 1),



                                      itemBuilder: (ctx, idx) {



                                        final f = selectedFiles[idx];



                                        final sizeKb = (f.size / 1024).toStringAsFixed(1);



                                        return ListTile(



                                          dense: true,



                                          leading: const Icon(Icons.description, color: Colors.green, size: 22),



                                          title: Text(f.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),



                                          subtitle: Text('$sizeKb KB', style: const TextStyle(fontSize: 11)),



                                          trailing: IconButton(



                                            icon: const Icon(Icons.close, size: 16),



                                            onPressed: isProcessing



                                                ? null



                                                : () => setDialogState(() => selectedFiles.removeAt(idx)),



                                          ),



                                        );



                                      },



                                    ),



                                  ),



                              ] else ...[



                                // TAB 1: Folder Scan



                                const Text(



                                  'พาธโฟลเดอร์ในเครื่อง หรือ OneDrive:',



                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),



                                ),



                                const SizedBox(height: 6),



                                TextField(



                                  controller: folderController,



                                  enabled: !isProcessing,



                                  decoration: const InputDecoration(



                                    hintText: r'เช่น C:\Users\ครู\OneDrive\งานวิชาการ\ปพ5',



                                    prefixIcon: Icon(Icons.folder),



                                    border: OutlineInputBorder(),



                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),



                                  ),



                                ),



                                const SizedBox(height: 12),



                                Container(



                                  padding: const EdgeInsets.all(12),



                                  decoration: BoxDecoration(



                                    color: Colors.blue.shade50,



                                    borderRadius: BorderRadius.circular(8),



                                    border: Border.all(color: Colors.blue.shade200),



                                  ),



                                  child: Row(



                                    crossAxisAlignment: CrossAxisAlignment.start,



                                    children: [



                                      Icon(Icons.info_outline, color: Colors.blue.shade700, size: 18),



                                      const SizedBox(width: 8),



                                      Expanded(



                                        child: Text(



                                          'ระบบจะค้นหาไฟล์ .xlsx ทุกไฟล์ในโฟลเดอร์และโฟลเดอร์ย่อยทั้งหมด ดึงรายวิชา นักเรียน ผลการเรียน และตารางเวลาเรียนเข้าสู่คลังข้อมูลอัตโนมัติ',



                                          style: TextStyle(fontSize: 12, color: Colors.blue.shade900),



                                        ),



                                      ),



                                    ],



                                  ),



                                ),



                              ],







                              const SizedBox(height: 14),







                              // Loading progress indicator



                              if (isProcessing) ...[



                                Container(



                                  padding: const EdgeInsets.all(16),



                                  decoration: BoxDecoration(



                                    color: Colors.teal.shade50,



                                    borderRadius: BorderRadius.circular(10),



                                    border: Border.all(color: Colors.teal.shade300),



                                  ),



                                  child: Row(



                                    children: [



                                      const SizedBox(



                                        width: 22,



                                        height: 22,



                                        child: CircularProgressIndicator(strokeWidth: 2.5),



                                      ),



                                      const SizedBox(width: 14),



                                      Expanded(



                                        child: Text(



                                          statusMessage ?? 'กำลังประมวลผล...',



                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.teal.shade900),



                                        ),



                                      ),



                                    ],



                                  ),



                                ),



                                const SizedBox(height: 14),



                              ],







                              // Error alert



                              if (errorMessage != null) ...[



                                Container(



                                  padding: const EdgeInsets.all(12),



                                  decoration: BoxDecoration(



                                    color: Colors.red.shade50,



                                    borderRadius: BorderRadius.circular(8),



                                    border: Border.all(color: Colors.red.shade300),



                                  ),



                                  child: Row(



                                    children: [



                                      Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),



                                      const SizedBox(width: 8),



                                      Expanded(



                                        child: Text(



                                          errorMessage!,



                                          style: TextStyle(fontSize: 12, color: Colors.red.shade900),



                                        ),



                                      ),



                                    ],



                                  ),



                                ),



                                const SizedBox(height: 14),



                              ],







                              // Completion results card



                              if (completionResult != null) ...[



                                Container(



                                  padding: const EdgeInsets.all(14),



                                  decoration: BoxDecoration(



                                    color: Colors.green.shade50,



                                    borderRadius: BorderRadius.circular(10),



                                    border: Border.all(color: Colors.green.shade400),



                                  ),



                                  child: Column(



                                    crossAxisAlignment: CrossAxisAlignment.start,



                                    children: [



                                      Row(



                                        children: [



                                          const Icon(Icons.check_circle, color: Colors.green, size: 20),



                                          const SizedBox(width: 8),



                                          Expanded(



                                            child: Text(



                                              completionResult!['message'] ?? 'นำเข้าข้อมูลสำเร็จ!',



                                              style: TextStyle(



                                                fontSize: 13,



                                                fontWeight: FontWeight.bold,



                                                color: Colors.green.shade900,



                                              ),



                                            ),



                                          ),



                                        ],



                                      ),



                                    ],



                                  ),



                                ),



                                const SizedBox(height: 14),



                              ],



                            ],



                          ),



                        ),



                      ),







                      const Divider(height: 20),







                      // Actions



                      Row(



                        mainAxisAlignment: MainAxisAlignment.end,



                        children: [



                          TextButton(



                            onPressed: isProcessing ? null : () => Navigator.of(ctx).pop(),



                            child: const Text('ปิด'),



                          ),



                          const SizedBox(width: 10),



                          if (activeTab == 0)



                            FilledButton.icon(



                              style: FilledButton.styleFrom(



                                backgroundColor: Colors.teal.shade700,



                                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),



                              ),



                              icon: const Icon(Icons.cloud_upload_rounded, size: 18),



                              label: Text('นำเข้า ${selectedFiles.length} ไฟล์สู่คลัง'),



                              onPressed: isProcessing || selectedFiles.isEmpty ? null : startImportFiles,



                            )



                          else



                            FilledButton.icon(



                              style: FilledButton.styleFrom(



                                backgroundColor: Colors.teal.shade700,



                                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),



                              ),



                              icon: const Icon(Icons.sync_rounded, size: 18),



                              label: const Text('สแกนและนำเข้าทั้งหมด'),



                              onPressed: isProcessing ? null : startImportFolder,



                            ),



                        ],



                      ),



                    ],



                  ),



                ),



              ),



            );



          },



        );



      },



    );



  }







  Future<void> _openUploadPdfDialog() async {



    final curSem = _currentSemesterInfo;



    String selectedTerm = curSem.term ?? 'auto';



    String selectedYear = curSem.year ?? 'auto';



    final List<ArchiveUploadPdfItem> selectedFiles = [];



    final TextEditingController descController = TextEditingController();



    final TextEditingController teacherController = TextEditingController();



    bool isProcessing = false;



    int currentIndex = 0;



    String? statusMessage;



    String? errorMessage;



    bool isDone = false;



    int successCount = 0;







    await showDialog(



      context: context,



      barrierDismissible: false,



      builder: (dialogCtx) {



        return StatefulBuilder(



          builder: (ctx, setDialogState) {



            Future<void> pickPdfFiles() async {



              try {



                final pickedFiles = await FilePicker.pickFiles(



                  dialogTitle: 'เลือกไฟล์ SGS PDF ได้หลายไฟล์พร้อมกัน',



                  type: FileType.custom,



                  allowedExtensions: ['pdf'],



                );



                if (pickedFiles.isEmpty) return;







                final List<ArchiveUploadPdfItem> newItems = [];



                for (final picked in pickedFiles) {



                  if (selectedFiles.any((f) => f.name == picked.name)) continue;



                  final bytes = await picked.readAsBytes();



                  newItems.add(ArchiveUploadPdfItem(



                    name: picked.name,



                    bytes: bytes,



                    size: picked.lengthSync() ?? bytes.length,



                  ));



                }







                setDialogState(() {



                  selectedFiles.addAll(newItems);



                  errorMessage = null;



                });



              } catch (e) {



                setDialogState(() => errorMessage = 'เลือกไฟล์ไม่สำเร็จ: $e');



              }



            }







            Future<void> startUploadAndProcess() async {



              if (selectedFiles.isEmpty) return;







              setDialogState(() {



                isProcessing = true;



                isDone = false;



                errorMessage = null;



                currentIndex = 0;



                successCount = 0;



              });







              final desc = descController.text.trim();



              final teacherVal = teacherController.text.trim();



              final termArg = selectedTerm != 'auto' ? selectedTerm : null;



              final yearArg = selectedYear != 'auto' ? selectedYear : null;







              for (int i = 0; i < selectedFiles.length; i++) {



                final fileItem = selectedFiles[i];



                if (fileItem.status == 'success') continue;







                setDialogState(() {



                  currentIndex = i;



                  fileItem.status = 'processing';



                  statusMessage = 'กำลังประมวลผล [${i + 1}/${selectedFiles.length}]: ${fileItem.name} ...';



                });







                try {



                  final res = await widget.apiService.uploadAndProcessPdf(



                    fileItem.bytes,



                    fileItem.name,



                    description: desc.isNotEmpty ? desc : null,



                    term: termArg,



                    year: yearArg,



                    teacher: teacherVal.isNotEmpty ? teacherVal : null,



                  );



                  setDialogState(() {



                    fileItem.status = 'success';



                    fileItem.result = res;



                    successCount++;



                  });



                } catch (e) {



                  setDialogState(() {



                    fileItem.status = 'error';



                    fileItem.error = e.toString().replaceFirst('Exception: ', '');



                  });



                }



              }







              setDialogState(() {



                isProcessing = false;



                isDone = true;



                statusMessage = 'ประมวลผลเสร็จสิ้น สำเร็จ $successCount จาก ${selectedFiles.length} ไฟล์';



              });







              await _loadCourses();



              if (mounted && _allCourses.isNotEmpty) {



                final availableInSemester = _filteredCourses;



                if (availableInSemester.isNotEmpty) {



                  setState(() {



                    _selectedCourse = availableInSemester.first;



                  });



                  _loadGrades();



                }



              }



            }







            return Dialog(



              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



              child: ConstrainedBox(



                constraints: const BoxConstraints(maxWidth: 820, maxHeight: 780),



                child: Padding(



                  padding: const EdgeInsets.all(22),



                  child: Column(



                    crossAxisAlignment: CrossAxisAlignment.stretch,



                    children: [



                      // Header



                      Row(



                        children: [



                          Container(



                            padding: const EdgeInsets.all(8),



                            decoration: BoxDecoration(



                              color: curSem.color.withValues(alpha: 0.1),



                              borderRadius: BorderRadius.circular(10),



                            ),



                            child: Icon(Icons.picture_as_pdf_rounded, size: 28, color: curSem.color),



                          ),



                          const SizedBox(width: 12),



                          Expanded(



                            child: Column(



                              crossAxisAlignment: CrossAxisAlignment.start,



                              children: [



                                Text(



                                  curSem.term != null



                                      ? 'อัปโหลดไฟล์ SGS (PDF) เข้าสู่ ${curSem.name}'



                                      : 'อัปโหลดไฟล์ SGS (PDF) สู่คลังข้อมูล',



                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),



                                ),



                                const SizedBox(height: 2),



                                Text(



                                  'ระบบจะแปลงเป็น ปพ.5 อัตโนมัติ และบันทึกผลการเรียนลงคลังของภาคเรียนนี้ทันที',



                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),



                                ),



                              ],



                            ),



                          ),



                          IconButton(



                            icon: const Icon(Icons.close),



                            onPressed: isProcessing ? null : () => Navigator.of(ctx).pop(),



                          ),



                        ],



                      ),



                      const Divider(height: 20),







                      // Semester info & target selector banner



                      Container(



                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),



                        decoration: BoxDecoration(



                          color: curSem.color.withValues(alpha: 0.08),



                          borderRadius: BorderRadius.circular(8),



                          border: Border.all(color: curSem.color.withValues(alpha: 0.3)),



                        ),



                        child: Row(



                          children: [



                            Icon(Icons.bookmark_added_rounded, size: 20, color: curSem.color),



                            const SizedBox(width: 8),



                            Expanded(



                              child: Text(



                                'คลังข้อมูลปลายทาง: ${curSem.name}',



                                style: TextStyle(



                                  fontSize: 13,



                                  fontWeight: FontWeight.bold,



                                  color: curSem.color,



                                ),



                              ),



                            ),



                            const Text('ระบุเทอม/ปี:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),



                            const SizedBox(width: 8),



                            DropdownButton<String>(



                              value: selectedTerm,



                              isDense: true,



                              underline: const SizedBox.shrink(),



                              items: const [



                                DropdownMenuItem(value: 'auto', child: Text('เทอม: จากไฟล์', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '1', child: Text('ภาคเรียนที่ 1', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '2', child: Text('ภาคเรียนที่ 2', style: TextStyle(fontSize: 12))),



                              ],



                              onChanged: isProcessing ? null : (v) {



                                if (v != null) setDialogState(() => selectedTerm = v);



                              },



                            ),



                            const SizedBox(width: 10),



                            DropdownButton<String>(



                              value: selectedYear,



                              isDense: true,



                              underline: const SizedBox.shrink(),



                              items: const [



                                DropdownMenuItem(value: 'auto', child: Text('ปี: จากไฟล์', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '2568', child: Text('2568', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '2569', child: Text('2569', style: TextStyle(fontSize: 12))),



                                DropdownMenuItem(value: '2567', child: Text('2567', style: TextStyle(fontSize: 12))),



                              ],



                              onChanged: isProcessing ? null : (v) {



                                if (v != null) setDialogState(() => selectedYear = v);



                              },



                            ),



                          ],



                        ),



                      ),



                      const SizedBox(height: 14),







                      // Optional Course Description



                      TextField(



                        controller: descController,



                        enabled: !isProcessing,



                        maxLines: 2,



                        decoration: const InputDecoration(



                          labelText: 'คำอธิบายรายวิชา (ทางเลือก - ใส่ลงใน ปพ.5 อัตโนมัติ)',



                          hintText: 'หากมีคำอธิบายรายวิชา สามารถพิมพ์หรือวางที่นี่เพื่อใส่ลงใน ปพ.5 ให้พอดีเส้นตาราง',



                          border: OutlineInputBorder(),



                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),



                        ),



                      ),



                      const SizedBox(height: 10),







                      // Optional Teacher Name



                      TextField(



                        controller: teacherController,



                        enabled: !isProcessing,



                        decoration: const InputDecoration(



                          labelText: 'ชื่อครูผู้สอน (ทางเลือก - เว้นว่างไว้เพื่อตรวจจับอัตโนมัติตามหน้าปก ปพ.5)',



                          hintText: 'เช่น นายสมชาย ใจดี หรือเว้นว่างไว้',



                          prefixIcon: Icon(Icons.person_outline, size: 20),



                          border: OutlineInputBorder(),



                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),



                          isDense: true,



                        ),



                      ),



                      const SizedBox(height: 14),







                      // Pick files bar



                      Row(



                        children: [



                          ElevatedButton.icon(



                            style: ElevatedButton.styleFrom(



                              backgroundColor: curSem.color.withValues(alpha: 0.1),



                              foregroundColor: curSem.color,



                              elevation: 0,



                              side: BorderSide(color: curSem.color.withValues(alpha: 0.4)),



                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),



                            ),



                            icon: const Icon(Icons.file_upload_outlined, size: 18),



                            label: const Text('เลือกไฟล์ SGS PDF (ได้หลายไฟล์พร้อมกัน)'),



                            onPressed: isProcessing ? null : pickPdfFiles,



                          ),



                          const SizedBox(width: 12),



                          if (selectedFiles.isNotEmpty) ...[



                            Chip(



                              avatar: const Icon(Icons.check, size: 14, color: Colors.green),



                              label: Text('เลือกแล้ว ${selectedFiles.length} ไฟล์', style: const TextStyle(fontSize: 12)),



                              backgroundColor: Colors.green.shade50,



                            ),



                            const Spacer(),



                            if (!isProcessing)



                              TextButton.icon(



                                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),



                                label: const Text('ล้างทั้งหมด', style: TextStyle(color: Colors.red, fontSize: 12)),



                                onPressed: () => setDialogState(() => selectedFiles.clear()),



                              ),



                          ],



                        ],



                      ),



                      const SizedBox(height: 12),







                      // Files list or empty placeholder



                      Expanded(



                        child: selectedFiles.isEmpty



                            ? Container(



                                decoration: BoxDecoration(



                                  color: Colors.grey.shade50,



                                  borderRadius: BorderRadius.circular(12),



                                  border: Border.all(color: Colors.grey.shade300),



                                ),



                                alignment: Alignment.center,



                                child: Column(



                                  mainAxisAlignment: MainAxisAlignment.center,



                                  children: [



                                    Icon(Icons.picture_as_pdf_outlined, size: 48, color: curSem.color.withValues(alpha: 0.5)),



                                    const SizedBox(height: 10),



                                    const Text('ยังไม่ได้เลือกไฟล์ PDF', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),



                                    const SizedBox(height: 4),



                                    Text('คลิกปุ่ม "เลือกไฟล์ SGS PDF" ด้านบน เพื่อเลือกไฟล์ผลการเรียนจาก SGS', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),



                                  ],



                                ),



                              )



                            : Container(



                                decoration: BoxDecoration(



                                  border: Border.all(color: Colors.grey.shade300),



                                  borderRadius: BorderRadius.circular(8),



                                ),



                                child: ListView.separated(



                                  itemCount: selectedFiles.length,



                                  separatorBuilder: (context, index) => const Divider(height: 1),



                                  itemBuilder: (c, idx) {



                                    final f = selectedFiles[idx];



                                    final sizeKb = (f.size / 1024).toStringAsFixed(1);



                                    return ListTile(



                                      dense: true,



                                      leading: Icon(



                                        Icons.picture_as_pdf,



                                        color: f.status == 'success'



                                            ? Colors.green



                                            : f.status == 'error'



                                                ? Colors.red



                                                : f.status == 'processing'



                                                    ? Colors.amber.shade700



                                                    : curSem.color,



                                        size: 24,



                                      ),



                                      title: Text(f.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),



                                      subtitle: Text(



                                        f.status == 'success'



                                            ? 'บันทึกสำเร็จ (${f.result?.courseCode ?? "-"})'



                                            : f.status == 'error'



                                                ? 'ข้อผิดพลาด: ${f.error}'



                                                : f.status == 'processing'



                                                    ? 'กำลังประมวลผล...'



                                                    : '$sizeKb KB (รอประมวลผล)',



                                        style: TextStyle(



                                          fontSize: 11,



                                          color: f.status == 'success'



                                              ? Colors.green.shade700



                                              : f.status == 'error'



                                                  ? Colors.red.shade700



                                                  : Colors.grey.shade600,



                                        ),



                                      ),



                                      trailing: f.status == 'processing'



                                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))



                                          : f.status == 'success'



                                              ? const Icon(Icons.check_circle, color: Colors.green, size: 20)



                                              : f.status == 'error'



                                                  ? const Icon(Icons.error, color: Colors.red, size: 20)



                                                  : IconButton(



                                                      icon: const Icon(Icons.close, size: 16),



                                                      onPressed: isProcessing ? null : () => setDialogState(() => selectedFiles.removeAt(idx)),



                                                    ),



                                    );



                                  },



                                ),



                              ),



                      ),



                      const SizedBox(height: 14),







                      // Error banner



                      if (errorMessage != null) ...[



                        Container(



                          padding: const EdgeInsets.all(12),



                          decoration: BoxDecoration(



                            color: Colors.red.shade50,



                            borderRadius: BorderRadius.circular(8),



                            border: Border.all(color: Colors.red.shade300),



                          ),



                          child: Row(



                            children: [



                              Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),



                              const SizedBox(width: 8),



                              Expanded(



                                child: Text(



                                  errorMessage!,



                                  style: TextStyle(fontSize: 12, color: Colors.red.shade900),



                                ),



                              ),



                            ],



                          ),



                        ),



                        const SizedBox(height: 10),



                      ],







                      // Progress / Status indicator



                      if (isProcessing) ...[



                        LinearProgressIndicator(



                          value: selectedFiles.isEmpty ? 0 : (currentIndex + 1) / selectedFiles.length,



                          backgroundColor: Colors.grey.shade200,



                          color: curSem.color,



                        ),



                        const SizedBox(height: 8),



                        Text(



                          statusMessage ?? 'กำลังประมวลผล...',



                          style: TextStyle(fontSize: 12, color: curSem.color, fontWeight: FontWeight.w600),



                          textAlign: TextAlign.center,



                        ),



                        const SizedBox(height: 10),



                      ] else if (isDone) ...[



                        Container(



                          padding: const EdgeInsets.all(12),



                          decoration: BoxDecoration(



                            color: Colors.green.shade50,



                            borderRadius: BorderRadius.circular(8),



                            border: Border.all(color: Colors.green.shade300),



                          ),



                          child: Row(



                            children: [



                              const Icon(Icons.check_circle, color: Colors.green, size: 20),



                              const SizedBox(width: 8),



                              Expanded(



                                child: Text(



                                  statusMessage ?? 'ประมวลผลเสร็จสิ้น!',



                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.green.shade900),



                                ),



                              ),



                            ],



                          ),



                        ),



                        const SizedBox(height: 10),



                      ],







                      // Actions



                      Row(



                        mainAxisAlignment: MainAxisAlignment.end,



                        children: [



                          TextButton(



                            onPressed: isProcessing ? null : () => Navigator.of(ctx).pop(),



                            child: Text(isDone ? 'ปิดหน้าต่าง' : 'ยกเลิก'),



                          ),



                          const SizedBox(width: 12),



                          FilledButton.icon(



                            style: FilledButton.styleFrom(



                              backgroundColor: curSem.color,



                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),



                            ),



                            icon: const Icon(Icons.cloud_upload_rounded, size: 18),



                            label: Text(



                              isDone



                                  ? 'อัปโหลดเพิ่ม'



                                  : 'เริ่มประมวลผล ${selectedFiles.length} ไฟล์ เข้าสู่คลัง',



                              style: const TextStyle(fontWeight: FontWeight.bold),



                            ),



                            onPressed: isProcessing || selectedFiles.isEmpty



                                ? null



                                : (isDone ? () => setDialogState(() { isDone = false; selectedFiles.clear(); }) : startUploadAndProcess),



                          ),



                        ],



                      ),



                    ],



                  ),



                ),



              ),



            );



          },



        );



      },



    );



  }







  Future<void> _openAdvisorsManagementDialog() async {



    final curSem = _currentSemesterInfo;



    String dialogSemesterKey = curSem.term != null && curSem.year != null



        ? '${curSem.term}-${curSem.year}'



        : (_semesterConfigs.isNotEmpty



            ? '${_semesterConfigs.first.term}-${_semesterConfigs.first.year}'



            : '2-2568');







    List<ClassAdvisorItem> dialogAdvisors = [];



    List<String> schoolTeachers = List.from(_schoolTeachers);



    bool dialogLoading = true;







    await showDialog(



      context: context,



      barrierDismissible: true,



      builder: (dialogCtx) {



        return StatefulBuilder(



          builder: (ctx, setDialogState) {



            final parts = dialogSemesterKey.split('-');



            final currentTerm = parts[0];



            final currentYear = parts.length > 1 ? parts[1] : '2568';







            Future<void> fetchAdvisorsForDialog() async {



              setDialogState(() => dialogLoading = true);



              try {



                final list = await widget.apiService.getClassAdvisors(



                  term: currentTerm,



                  year: currentYear,



                );



                setDialogState(() {



                  dialogAdvisors = list;



                  dialogLoading = false;



                });



                _loadClassAdvisors();



              } catch (_) {



                setDialogState(() => dialogLoading = false);



              }



            }







            Future<void> fetchSchoolTeachersForDialog() async {



              try {



                final list = await widget.apiService.getSchoolTeachers();



                setDialogState(() {



                  schoolTeachers = list;



                });



                setState(() => _schoolTeachers = list);



              } catch (_) {}



            }







            if (dialogLoading && dialogAdvisors.isEmpty) {



              fetchAdvisorsForDialog();



              fetchSchoolTeachersForDialog();



            }







            Future<void> openTeacherRosterSubDialog() async {



              String teacherFilter = '';



              final addSingleController = TextEditingController();



              final bulkController = TextEditingController();







              await showDialog(



                context: ctx,



                builder: (rosterCtx) {



                  return StatefulBuilder(



                    builder: (subCtx, setSubState) {



                      final filteredTeachers = schoolTeachers.where((t) {



                        if (teacherFilter.isEmpty) return true;



                        return t.toLowerCase().contains(teacherFilter.toLowerCase());



                      }).toList();







                      return AlertDialog(



                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



                        title: Row(



                          children: [



                            Container(



                              padding: const EdgeInsets.all(8),



                              decoration: BoxDecoration(



                                color: Colors.deepPurple.shade50,



                                borderRadius: BorderRadius.circular(8),



                              ),



                              child: Icon(Icons.people_alt_rounded, color: Colors.deepPurple.shade700, size: 24),



                            ),



                            const SizedBox(width: 10),



                            Expanded(



                              child: Column(



                                crossAxisAlignment: CrossAxisAlignment.start,



                                children: [



                                  const Text('จัดการรายชื่อครูทั้งหมด (Master Teacher Roster)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),



                                  Text(



                                    'รายชื่อทั้งหมด ${schoolTeachers.length} ท่าน • เชื่อมโยงเป็นตัวเลือกให้แต่ละห้องเรียนทันที',



                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),



                                  ),



                                ],



                              ),



                            ),



                            IconButton(



                              icon: const Icon(Icons.close),



                              onPressed: () => Navigator.of(subCtx).pop(),



                            ),



                          ],



                        ),



                        content: ConstrainedBox(



                          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 520),



                          child: Column(



                            children: [



                              // Action Toolbar: Quick search, Add single, Bulk import, Auto-sync



                              Row(



                                children: [



                                  Expanded(



                                    child: TextField(



                                      decoration: InputDecoration(



                                        prefixIcon: const Icon(Icons.search, size: 18),



                                        hintText: 'ค้นหาชื่อครู...',



                                        isDense: true,



                                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),



                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),



                                      ),



                                      onChanged: (val) => setSubState(() => teacherFilter = val),



                                    ),



                                  ),



                                  const SizedBox(width: 8),



                                  FilledButton.icon(



                                    style: FilledButton.styleFrom(



                                      backgroundColor: AppColors.purplePrimary,



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    icon: const Icon(Icons.add_rounded, size: 16),



                                    label: const Text('+ เพิ่มครู'),



                                    onPressed: () async {



                                      addSingleController.clear();



                                      final name = await showDialog<String>(



                                        context: subCtx,



                                        builder: (nameCtx) => AlertDialog(



                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



                                          title: const Row(



                                            children: [



                                              Icon(Icons.person_add_rounded, color: AppColors.purplePrimary),



                                              SizedBox(width: 8),



                                              Text('เพิ่มรายชื่อครูท่านใหม่'),



                                            ],



                                          ),



                                          content: SizedBox(



                                            width: 400,



                                            child: TextField(



                                              controller: addSingleController,



                                              autofocus: true,



                                              decoration: const InputDecoration(



                                                labelText: 'ชื่อ-นามสกุลครู',



                                                hintText: 'เช่น นายสมชาย ใจดี หรือ นางสาว...',



                                                border: OutlineInputBorder(),



                                                prefixIcon: Icon(Icons.person_add_rounded),



                                              ),



                                            ),



                                          ),



                                          actions: [



                                            TextButton(onPressed: () => Navigator.of(nameCtx).pop(), child: const Text('ยกเลิก')),



                                            FilledButton(



                                              onPressed: () => Navigator.of(nameCtx).pop(addSingleController.text.trim()),



                                              child: const Text('บันทึก'),



                                            ),



                                          ],



                                        ),



                                      );



                                      if (name != null && name.isNotEmpty) {



                                        try {



                                          final updated = await widget.apiService.addSchoolTeacher(name);



                                          setSubState(() => schoolTeachers = updated);



                                          setDialogState(() => schoolTeachers = updated);



                                          setState(() => _schoolTeachers = updated);



                                        } catch (e) {



                                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));



                                        }



                                      }



                                    },



                                  ),



                                  const SizedBox(width: 6),



                                  FilledButton.icon(



                                    style: FilledButton.styleFrom(



                                      backgroundColor: Colors.teal.shade700,



                                      visualDensity: VisualDensity.compact,



                                    ),



                                    icon: const Icon(Icons.file_upload_outlined, size: 16),



                                    label: const Text('นำเข้าหลายท่าน'),



                                    onPressed: () async {



                                      bulkController.clear();



                                      final ok = await showDialog<bool>(



                                        context: subCtx,



                                        builder: (bulkCtx) => AlertDialog(



                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



                                          title: const Row(



                                            children: [



                                              Icon(Icons.upload_file_rounded, color: Colors.teal),



                                              SizedBox(width: 8),



                                              Text('นำเข้ารายชื่อครูหลายท่านพร้อมกัน'),



                                            ],



                                          ),



                                          content: SizedBox(



                                            width: 480,



                                            child: Column(



                                              mainAxisSize: MainAxisSize.min,



                                              crossAxisAlignment: CrossAxisAlignment.start,



                                              children: [



                                                const Text('วางรายชื่อครูจาก Excel หรือ Word (1 บรรทัด ต่อ 1 ท่าน):', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),



                                                const SizedBox(height: 8),



                                                TextField(



                                                  controller: bulkController,



                                                  maxLines: 10,



                                                  decoration: const InputDecoration(



                                                    border: OutlineInputBorder(),



                                                    hintText: 'นายสมศักดิ์ สุขใจ\nนางสาวดวงใจ มีสุข\nนายมานพ ทองดี...',



                                                  ),



                                                ),



                                              ],



                                            ),



                                          ),



                                          actions: [



                                            TextButton(onPressed: () => Navigator.of(bulkCtx).pop(false), child: const Text('ยกเลิก')),



                                            FilledButton(



                                              style: FilledButton.styleFrom(backgroundColor: Colors.teal.shade700),



                                              onPressed: () => Navigator.of(bulkCtx).pop(true),



                                              child: const Text('นำเข้าทั้งหมด'),



                                            ),



                                          ],



                                        ),



                                      );



                                      if (ok == true) {



                                        final lines = bulkController.text



                                            .split('\n')



                                            .map((s) => s.trim())



                                            .where((s) => s.isNotEmpty && s != '-')



                                            .toList();



                                        if (lines.isNotEmpty) {



                                          try {



                                            final updated = await widget.apiService.bulkAddSchoolTeachers(lines);



                                            setSubState(() => schoolTeachers = updated);



                                            setDialogState(() => schoolTeachers = updated);



                                            setState(() => _schoolTeachers = updated);



                                            if (mounted) {



                                              ScaffoldMessenger.of(context).showSnackBar(



                                                SnackBar(backgroundColor: Colors.green.shade800, content: Text('นำเข้ารายชื่อครูสำเร็จ ${lines.length} ท่าน')),



                                              );



                                            }



                                          } catch (e) {



                                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));



                                          }



                                        }



                                      }



                                    },



                                  ),



                                  const SizedBox(width: 6),



                                  OutlinedButton.icon(



                                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),



                                    icon: const Icon(Icons.sync_rounded, size: 16),



                                    label: const Text('ดึงจากวิชา'),



                                    onPressed: () async {



                                      try {



                                        final updated = await widget.apiService.syncSchoolTeachers();



                                        setSubState(() => schoolTeachers = updated);



                                        setDialogState(() => schoolTeachers = updated);



                                        setState(() => _schoolTeachers = updated);



                                        if (mounted) {



                                          ScaffoldMessenger.of(context).showSnackBar(



                                            SnackBar(backgroundColor: Colors.green.shade800, content: Text('ดึงข้อมูลครูจากระบบเรียบร้อย รวม ${updated.length} ท่าน')),



                                          );



                                        }



                                      } catch (e) {



                                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));



                                      }



                                    },



                                  ),



                                ],



                              ),



                              const SizedBox(height: 12),



                              const Divider(height: 1),



                              const SizedBox(height: 8),







                              // Teachers List with Delete button



                              Expanded(



                                child: filteredTeachers.isEmpty



                                    ? Center(



                                        child: Text(



                                          teacherFilter.isEmpty ? 'ยังไม่มีรายชื่อครูในระบบ' : 'ไม่พบชื่อครูที่ตรงกับ "$teacherFilter"',



                                          style: TextStyle(color: Colors.grey.shade600),



                                        ),



                                      )



                                    : ListView.separated(



                                        itemCount: filteredTeachers.length,



                                        separatorBuilder: (context, index) => const Divider(height: 1),



                                        itemBuilder: (listCtx, i) {



                                          final name = filteredTeachers[i];



                                          // Check which rooms this teacher advises



                                          final roomsAdvised = dialogAdvisors



                                              .where((a) => a.nonNullAdvisors.contains(name))



                                              .map((a) => a.classLevel)



                                              .toList();







                                          return ListTile(



                                            dense: true,



                                            leading: CircleAvatar(



                                              radius: 14,



                                              backgroundColor: Colors.deepPurple.shade100,



                                              child: Text(



                                                name.isNotEmpty ? name.characters.first : '?',



                                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.deepPurple.shade900),



                                              ),



                                            ),



                                            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),



                                            subtitle: roomsAdvised.isNotEmpty



                                                ? Text('ประจำชั้น: ${roomsAdvised.join(", ")}', style: TextStyle(fontSize: 11, color: Colors.green.shade800, fontWeight: FontWeight.bold))



                                                : null,



                                            trailing: IconButton(



                                              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),



                                              tooltip: 'ลบรายชื่อ $name (-)',



                                              onPressed: () async {



                                                final confirm = await showDialog<bool>(



                                                  context: subCtx,



                                                  builder: (delCtx) => AlertDialog(



                                                    title: const Text('ยืนยันการลบครู'),



                                                    content: Text('ต้องการลบ "$name" ออกจากรายชื่อครูทั้งหมดหรือไม่?'),



                                                    actions: [



                                                      TextButton(onPressed: () => Navigator.of(delCtx).pop(false), child: const Text('ยกเลิก')),



                                                      FilledButton(



                                                        style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),



                                                        onPressed: () => Navigator.of(delCtx).pop(true),



                                                        child: const Text('ลบ'),



                                                      ),



                                                    ],



                                                  ),



                                                );



                                                if (confirm == true) {



                                                  try {



                                                    final updated = await widget.apiService.deleteSchoolTeacher(name);



                                                    setSubState(() => schoolTeachers = updated);



                                                    setDialogState(() => schoolTeachers = updated);



                                                    setState(() => _schoolTeachers = updated);



                                                  } catch (e) {



                                                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));



                                                  }



                                                }



                                              },



                                            ),



                                          );



                                        },



                                      ),



                              ),



                            ],



                          ),



                        ),



                        actions: [



                          FilledButton(



                            onPressed: () => Navigator.of(subCtx).pop(),



                            child: const Text('เสร็จสิ้น'),



                          ),



                        ],



                      );



                    },



                  );



                },



              );



            }







            Future<void> openEditAdvisorSubDialog([ClassAdvisorItem? existing]) async {



              final levelController = TextEditingController(text: existing?.classLevel ?? 'ม.1');



              String selAdv1 = existing?.advisor1?.trim() ?? '';



              String selAdv2 = existing?.advisor2?.trim() ?? '';



              String selAdv3 = existing?.advisor3?.trim() ?? '';







              await showDialog(



                context: ctx,



                builder: (subCtx) => StatefulBuilder(



                  builder: (formCtx, setFormState) {



                    final options = <String>{...schoolTeachers};



                    if (selAdv1.isNotEmpty) options.add(selAdv1);



                    if (selAdv2.isNotEmpty) options.add(selAdv2);



                    if (selAdv3.isNotEmpty) options.add(selAdv3);



                    final sortedOptions = options.toList()..sort();







                    Future<void> quickAddNewTeacher(int slot) async {



                      final quickController = TextEditingController();



                      final newName = await showDialog<String>(



                        context: formCtx,



                        builder: (qCtx) => AlertDialog(



                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



                          title: const Row(



                            children: [



                              Icon(Icons.person_add_rounded, color: AppColors.purplePrimary),



                              SizedBox(width: 8),



                              Text('เพิ่มครูท่านใหม่เข้าสู่ระบบ'),



                            ],



                          ),



                          content: SizedBox(



                            width: 400,



                            child: TextField(



                              controller: quickController,



                              autofocus: true,



                              decoration: const InputDecoration(



                                labelText: 'ชื่อ-นามสกุล ครู',



                                hintText: 'เช่น นาย... หรือ นางสาว...',



                                border: OutlineInputBorder(),



                                prefixIcon: Icon(Icons.person_outline),



                              ),



                            ),



                          ),



                          actions: [



                            TextButton(onPressed: () => Navigator.of(qCtx).pop(), child: const Text('ยกเลิก')),



                            FilledButton(



                              onPressed: () => Navigator.of(qCtx).pop(quickController.text.trim()),



                              child: const Text('บันทึกและเลือก'),



                            ),



                          ],



                        ),



                      );



                      if (newName != null && newName.isNotEmpty) {



                        try {



                          final updated = await widget.apiService.addSchoolTeacher(newName);



                          setDialogState(() => schoolTeachers = updated);



                          setState(() => _schoolTeachers = updated);



                          setFormState(() {



                            schoolTeachers = updated;



                            if (slot == 1) selAdv1 = newName;



                            if (slot == 2) selAdv2 = newName;



                            if (slot == 3) selAdv3 = newName;



                          });



                        } catch (e) {



                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));



                        }



                      }



                    }







                    Widget buildAdvisorDropdown({



                      required int slot,



                      required String label,



                      required String currentValue,



                      required Function(String) onSelected,



                    }) {



                      final isValueInOptions = currentValue.isEmpty || sortedOptions.contains(currentValue);



                      final safeValue = isValueInOptions ? currentValue : '';







                      return Column(



                        crossAxisAlignment: CrossAxisAlignment.start,



                        children: [



                          Row(



                            crossAxisAlignment: CrossAxisAlignment.center,



                            children: [



                              Expanded(



                                child: DropdownButtonFormField<String>(



                                  initialValue: safeValue,



                                  isExpanded: true,



                                  decoration: InputDecoration(



                                    labelText: label,



                                    border: const OutlineInputBorder(),



                                    prefixIcon: Icon(



                                      slot == 1 ? Icons.person_rounded : (slot == 2 ? Icons.person_outline_rounded : Icons.person_add_alt_1_rounded),



                                      color: slot == 1 ? AppColors.purplePrimary : Colors.grey.shade700,



                                    ),



                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),



                                  ),



                                  items: [



                                    const DropdownMenuItem<String>(



                                      value: '',



                                      child: Text('(ไม่ระบุ / ว่าง)', style: TextStyle(color: Colors.grey)),



                                    ),



                                    ...sortedOptions.map((t) => DropdownMenuItem<String>(



                                      value: t,



                                      child: Text(t, overflow: TextOverflow.ellipsis),



                                    )),



                                  ],



                                  onChanged: (val) {



                                    setFormState(() => onSelected(val ?? ''));



                                  },



                                ),



                              ),



                              const SizedBox(width: 8),



                              IconButton.filledTonal(



                                icon: const Icon(Icons.person_add_rounded, size: 20),



                                tooltip: 'เพิ่มชื่อครูท่านใหม่เข้าสู่รายการ',



                                onPressed: () => quickAddNewTeacher(slot),



                              ),



                            ],



                          ),



                          const SizedBox(height: 14),



                        ],



                      );



                    }







                    return AlertDialog(



                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



                      title: Row(



                        children: [



                          Icon(



                            existing != null ? Icons.edit_note_rounded : Icons.person_add_rounded,



                            color: AppColors.purplePrimary,



                          ),



                          const SizedBox(width: 10),



                          Text(existing != null ? 'แก้ไขครูที่ปรึกษา ${existing.classLevel}' : 'เพิ่มระดับชั้นและครูที่ปรึกษา'),



                        ],



                      ),



                      content: ConstrainedBox(



                        constraints: const BoxConstraints(maxWidth: 520),



                        child: SingleChildScrollView(



                          child: Column(



                            mainAxisSize: MainAxisSize.min,



                            crossAxisAlignment: CrossAxisAlignment.start,



                            children: [



                              Container(



                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),



                                decoration: BoxDecoration(



                                  color: Colors.teal.shade50,



                                  borderRadius: BorderRadius.circular(6),



                                  border: Border.all(color: Colors.teal.shade200),



                                ),



                                child: Row(



                                  children: [



                                    Icon(Icons.check_circle_outline, size: 16, color: Colors.teal.shade800),



                                    const SizedBox(width: 6),



                                    Expanded(



                                      child: Text(



                                        'ภาคเรียนที่ $currentTerm/$currentYear • เลือกรายชื่อครูจากรายการโดยไม่ต้องพิมพ์',



                                        style: TextStyle(fontSize: 12, color: Colors.teal.shade900, fontWeight: FontWeight.bold),



                                      ),



                                    ),



                                  ],



                                ),



                              ),



                              const SizedBox(height: 16),



                              TextField(



                                controller: levelController,



                                decoration: const InputDecoration(



                                  labelText: 'ระดับชั้น (เช่น ม.1, ม.2, ม.3 หรือ ม.1/1)',



                                  border: OutlineInputBorder(),



                                  prefixIcon: Icon(Icons.school_rounded),



                                ),



                              ),



                              const SizedBox(height: 16),



                              buildAdvisorDropdown(



                                slot: 1,



                                label: 'ครูที่ปรึกษาคนที่ 1 (เลือกจากรายชื่อครู)',



                                currentValue: selAdv1,



                                onSelected: (v) => selAdv1 = v,



                              ),



                              buildAdvisorDropdown(



                                slot: 2,



                                label: 'ครูที่ปรึกษาคนที่ 2 (ถ้ามี)',



                                currentValue: selAdv2,



                                onSelected: (v) => selAdv2 = v,



                              ),



                              buildAdvisorDropdown(



                                slot: 3,



                                label: 'ครูที่ปรึกษาคนที่ 3 (ถ้ามี)',



                                currentValue: selAdv3,



                                onSelected: (v) => selAdv3 = v,



                              ),



                            ],



                          ),



                        ),



                      ),



                      actions: [



                        TextButton(onPressed: () => Navigator.of(formCtx).pop(), child: const Text('ยกเลิก')),



                        FilledButton(



                          style: FilledButton.styleFrom(backgroundColor: AppColors.purplePrimary),



                          onPressed: () async {



                            final lvl = levelController.text.trim();



                            if (lvl.isEmpty) return;



                            Navigator.of(formCtx).pop();



                            try {



                              await widget.apiService.upsertClassAdvisor(



                                ClassAdvisorItem(



                                  id: existing?.id ?? 0,



                                  term: currentTerm,



                                  year: currentYear,



                                  classLevel: lvl,



                                  advisor1: selAdv1,



                                  advisor2: selAdv2,



                                  advisor3: selAdv3,



                                ),



                              );



                              await fetchAdvisorsForDialog();



                              if (mounted) {



                                ScaffoldMessenger.of(context).showSnackBar(



                                  SnackBar(



                                    backgroundColor: Colors.green.shade800,



                                    content: Text('บันทึกครูที่ปรึกษา $lvl เรียบร้อยแล้ว'),



                                  ),



                                );



                              }



                            } catch (e) {



                              if (mounted) {



                                ScaffoldMessenger.of(context).showSnackBar(



                                  SnackBar(backgroundColor: Colors.red.shade800, content: Text('บันทึกไม่สำเร็จ: $e')),



                                );



                              }



                            }



                          },



                          child: const Text('บันทึกข้อมูล'),



                        ),



                      ],



                    );



                  },



                ),



              );



            }







            Future<void> confirmDeleteAdvisor(ClassAdvisorItem item) async {



              final ok = await showDialog<bool>(



                context: ctx,



                builder: (subCtx) => AlertDialog(



                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



                  title: const Text('ยืนยันการลบ'),



                  content: Text('ต้องการลบข้อมูลครูที่ปรึกษาของระดับชั้น "${item.classLevel}" หรือไม่?'),



                  actions: [



                    TextButton(onPressed: () => Navigator.of(subCtx).pop(false), child: const Text('ยกเลิก')),



                    FilledButton(



                      style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),



                      onPressed: () => Navigator.of(subCtx).pop(true),



                      child: const Text('ลบข้อมูล'),



                    ),



                  ],



                ),



              );



              if (ok == true) {



                try {



                  await widget.apiService.deleteClassAdvisor(item.id);



                  await fetchAdvisorsForDialog();



                  if (mounted) {



                    ScaffoldMessenger.of(context).showSnackBar(



                      SnackBar(content: Text('ลบข้อมูลครูที่ปรึกษา ${item.classLevel} เรียบร้อยแล้ว')),



                    );



                  }



                } catch (e) {



                  if (mounted) {



                    ScaffoldMessenger.of(context).showSnackBar(



                      SnackBar(backgroundColor: Colors.red.shade800, content: Text('ลบไม่สำเร็จ: $e')),



                    );



                  }



                }



              }



            }







            Future<void> openCopyAdvisorsSubDialog() async {



              final otherConfigs = _semesterConfigs.where(



                (c) => !(c.term == currentTerm && c.year == currentYear),



              ).toList();







              if (otherConfigs.isEmpty) {



                ScaffoldMessenger.of(context).showSnackBar(



                  const SnackBar(content: Text('ไม่มีภาคเรียนอื่นให้คัดลอกข้อมูล')),



                );



                return;



              }







              String selectedSource = '${otherConfigs.first.term}-${otherConfigs.first.year}';







              await showDialog(



                context: ctx,



                builder: (copyCtx) => StatefulBuilder(



                  builder: (dCtx, setDCtxState) => AlertDialog(



                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



                    title: const Row(



                      children: [



                        Icon(Icons.copy_rounded, color: AppColors.purplePrimary),



                        SizedBox(width: 10),



                        Text('คัดลอกรายชื่อครูที่ปรึกษา'),



                      ],



                    ),



                    content: Column(



                      mainAxisSize: MainAxisSize.min,



                      crossAxisAlignment: CrossAxisAlignment.start,



                      children: [



                        Text('คัดลอกข้อมูลครูที่ปรึกษาทุกระดับชั้นมาใส่ใน: ภาคเรียนที่ $currentTerm/$currentYear'),



                        const SizedBox(height: 16),



                        DropdownButtonFormField<String>(



                          initialValue: selectedSource,



                          decoration: const InputDecoration(



                            labelText: 'เลือกภาคเรียนต้นทาง',



                            border: OutlineInputBorder(),



                            prefixIcon: Icon(Icons.source_rounded),



                          ),



                          items: otherConfigs.map((c) {



                            return DropdownMenuItem(



                              value: '${c.term}-${c.year}',



                              child: Text(c.title),



                            );



                          }).toList(),



                          onChanged: (val) {



                            if (val != null) setDCtxState(() => selectedSource = val);



                          },



                        ),



                      ],



                    ),



                    actions: [



                      TextButton(onPressed: () => Navigator.of(copyCtx).pop(), child: const Text('ยกเลิก')),



                      FilledButton(



                        style: FilledButton.styleFrom(backgroundColor: AppColors.purplePrimary),



                        onPressed: () async {



                          Navigator.of(copyCtx).pop();



                          final srcParts = selectedSource.split('-');



                          try {



                            final res = await widget.apiService.copyClassAdvisors(



                              fromTerm: srcParts[0],



                              fromYear: srcParts[1],



                              toTerm: currentTerm,



                              toYear: currentYear,



                            );



                            await fetchAdvisorsForDialog();



                            if (mounted) {



                              ScaffoldMessenger.of(context).showSnackBar(



                                SnackBar(



                                  backgroundColor: Colors.green.shade800,



                                  content: Text(res['message'] ?? 'คัดลอกข้อมูลเรียบร้อยแล้ว'),



                                ),



                              );



                            }



                          } catch (e) {



                            if (mounted) {



                              ScaffoldMessenger.of(context).showSnackBar(



                                SnackBar(backgroundColor: Colors.red.shade800, content: Text('คัดลอกไม่สำเร็จ: $e')),



                              );



                            }



                          }



                        },



                        child: const Text('เริ่มการคัดลอก'),



                      ),



                    ],



                  ),



                ),



              );



            }







            Future<void> openUploadAdvisorsSubDialog() async {



              final pickedFiles = await FilePicker.pickFiles(



                type: FileType.custom,



                allowedExtensions: ['xlsx', 'xls', 'csv'],



              );



              if (pickedFiles.isEmpty) return;



              final picked = pickedFiles.first;



              final bytes = await picked.readAsBytes();



              final size = picked.lengthSync() ?? bytes.length;







              if (!mounted) return;



              final confirm = await showDialog<bool>(



                context: ctx,



                builder: (uCtx) => AlertDialog(



                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



                  title: const Text('ยืนยันการนำเข้าไฟล์ครูที่ปรึกษา'),



                  content: Column(



                    mainAxisSize: MainAxisSize.min,



                    crossAxisAlignment: CrossAxisAlignment.start,



                    children: [



                      Text('ไฟล์: ${picked.name} (${(size / 1024).toStringAsFixed(1)} KB)'),



                      const SizedBox(height: 8),



                      Text('เข้าสู่: ภาคเรียนที่ $currentTerm/$currentYear', style: const TextStyle(fontWeight: FontWeight.bold)),



                      const SizedBox(height: 12),



                      const Text(



                        'ระบบจะอ่านระดับชั้นและรายชื่อครูที่ปรึกษา (สูงสุด 3 คนต่อห้อง) แล้วบันทึกลงในระบบอัตโนมัติ',



                        style: TextStyle(fontSize: 12, color: Colors.grey),



                      ),



                    ],



                  ),



                  actions: [



                    TextButton(onPressed: () => Navigator.of(uCtx).pop(false), child: const Text('ยกเลิก')),



                    FilledButton(



                      style: FilledButton.styleFrom(backgroundColor: AppColors.purplePrimary),



                      onPressed: () => Navigator.of(uCtx).pop(true),



                      child: const Text('ยืนยันนำเข้า'),



                    ),



                  ],



                ),



              );







              if (confirm == true) {



                try {



                  final res = await widget.apiService.uploadClassAdvisorsFile(



                    bytes,



                    picked.name,



                    term: currentTerm,



                    year: currentYear,



                  );



                  await fetchAdvisorsForDialog();



                  if (mounted) {



                    ScaffoldMessenger.of(context).showSnackBar(



                      SnackBar(



                        backgroundColor: Colors.green.shade800,



                        content: Text(res['message'] ?? 'นำเข้าข้อมูลสำเร็จ'),



                      ),



                    );



                  }



                } catch (e) {



                  if (mounted) {



                    ScaffoldMessenger.of(context).showSnackBar(



                      SnackBar(backgroundColor: Colors.red.shade800, content: Text('นำเข้าไม่สำเร็จ: $e')),



                    );



                  }



                }



              }



            }







            Future<void> downloadTemplate() async {



              final url = widget.apiService.getClassAdvisorsTemplateUrl();



              final uri = Uri.parse(url);



              try {



                if (await canLaunchUrl(uri)) {



                  await launchUrl(uri, mode: LaunchMode.externalApplication);



                }



              } catch (_) {}



            }







            return Dialog(



              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



              child: ConstrainedBox(



                constraints: const BoxConstraints(maxWidth: 860, maxHeight: 720),



                child: Padding(



                  padding: const EdgeInsets.all(22),



                  child: Column(



                    crossAxisAlignment: CrossAxisAlignment.stretch,



                    children: [



                      Row(



                        children: [



                          Container(



                            padding: const EdgeInsets.all(8),



                            decoration: BoxDecoration(



                              color: AppColors.purpleContainer,



                              borderRadius: BorderRadius.circular(10),



                            ),



                            child: Icon(Icons.people_alt_rounded, size: 28, color: AppColors.purplePrimary),



                          ),



                          const SizedBox(width: 12),



                          Expanded(



                            child: Column(



                              crossAxisAlignment: CrossAxisAlignment.start,



                              children: [



                                const Text(



                                  'จัดการครูที่ปรึกษา / ครูประจำชั้น',



                                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),



                                ),



                                const SizedBox(height: 2),



                                Text(



                                  'กำหนดรายชื่อครูที่ปรึกษา (สูงสุด 3 ท่านต่อระดับชั้น) เพื่อเชื่อมต่อไปยังหน้าปก ปพ.5 ช่อง E12, E13 อัตโนมัติ',



                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),



                                ),



                              ],



                            ),



                          ),



                          IconButton(



                            icon: const Icon(Icons.close),



                            onPressed: () => Navigator.of(ctx).pop(),



                          ),



                        ],



                      ),



                      const Divider(height: 24),



                      Wrap(



                        spacing: 10,



                        runSpacing: 10,



                        alignment: WrapAlignment.spaceBetween,



                        crossAxisAlignment: WrapCrossAlignment.center,



                        children: [



                          Row(



                            mainAxisSize: MainAxisSize.min,



                            children: [



                              const Text('ภาคเรียน: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),



                              const SizedBox(width: 8),



                              DropdownButton<String>(



                                value: dialogSemesterKey,



                                underline: Container(height: 1.5, color: AppColors.purplePrimary),



                                items: _semesterConfigs.map((c) {



                                  return DropdownMenuItem(



                                    value: '${c.term}-${c.year}',



                                    child: Text(c.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),



                                  );



                                }).toList(),



                                onChanged: (val) {



                                  if (val != null) {



                                    setDialogState(() {



                                      dialogSemesterKey = val;



                                      dialogAdvisors.clear();



                                      dialogLoading = true;



                                    });



                                    fetchAdvisorsForDialog();



                                  }



                                },



                              ),



                            ],



                          ),



                          Wrap(



                            spacing: 8,



                            runSpacing: 8,



                            children: [



                              FilledButton.icon(



                                style: FilledButton.styleFrom(



                                  backgroundColor: Colors.deepPurple.shade700,



                                  foregroundColor: Colors.white,



                                  visualDensity: VisualDensity.compact,



                                ),



                                icon: const Icon(Icons.people_alt_rounded, size: 16),



                                label: Text('จัดการรายชื่อครู (${schoolTeachers.length} ท่าน)'),



                                onPressed: openTeacherRosterSubDialog,



                              ),



                              OutlinedButton.icon(



                                style: OutlinedButton.styleFrom(



                                  foregroundColor: Colors.teal.shade800,



                                  side: BorderSide(color: Colors.teal.shade300),



                                  visualDensity: VisualDensity.compact,



                                ),



                                icon: const Icon(Icons.download_rounded, size: 16),



                                label: const Text('แม่แบบ Excel'),



                                onPressed: downloadTemplate,



                              ),



                              OutlinedButton.icon(



                                style: OutlinedButton.styleFrom(



                                  foregroundColor: AppColors.purplePrimary,



                                  side: BorderSide(color: AppColors.purpleBorder),



                                  visualDensity: VisualDensity.compact,



                                ),



                                icon: const Icon(Icons.copy_rounded, size: 16),



                                label: const Text('คัดลอกจากเทอมอื่น'),



                                onPressed: openCopyAdvisorsSubDialog,



                              ),



                              FilledButton.icon(



                                style: FilledButton.styleFrom(



                                  backgroundColor: Colors.teal.shade700,



                                  foregroundColor: Colors.white,



                                  visualDensity: VisualDensity.compact,



                                ),



                                icon: const Icon(Icons.upload_file_rounded, size: 16),



                                label: const Text('อัปโหลดไฟล์รวม'),



                                onPressed: openUploadAdvisorsSubDialog,



                              ),



                              FilledButton.icon(



                                style: FilledButton.styleFrom(



                                  backgroundColor: AppColors.purplePrimary,



                                  foregroundColor: Colors.white,



                                  visualDensity: VisualDensity.compact,



                                ),



                                icon: const Icon(Icons.add_rounded, size: 16),



                                label: const Text('เพิ่มระดับชั้น'),



                                onPressed: () => openEditAdvisorSubDialog(),



                              ),



                            ],



                          ),



                        ],



                      ),



                      const SizedBox(height: 16),



                      Expanded(



                        child: dialogLoading



                            ? const Center(child: CircularProgressIndicator())



                            : dialogAdvisors.isEmpty



                                ? Center(



                                    child: Column(



                                      mainAxisSize: MainAxisSize.min,



                                      children: [



                                        Icon(Icons.person_off_outlined, size: 48, color: Colors.grey.shade400),



                                        const SizedBox(height: 12),



                                        Text(



                                          'ยังไม่มีรายชื่อครูที่ปรึกษาในภาคเรียนที่ $currentTerm/$currentYear',



                                          style: TextStyle(color: Colors.grey.shade600),



                                        ),



                                        const SizedBox(height: 12),



                                        ElevatedButton.icon(



                                          icon: const Icon(Icons.copy_rounded, size: 16),



                                          label: const Text('คัดลอกจากภาคเรียนอื่น'),



                                          onPressed: openCopyAdvisorsSubDialog,



                                        ),



                                      ],



                                    ),



                                  )



                                : Container(



                                    decoration: BoxDecoration(



                                      border: Border.all(color: Colors.grey.shade300),



                                      borderRadius: BorderRadius.circular(10),



                                    ),



                                    child: ClipRRect(



                                      borderRadius: BorderRadius.circular(10),



                                      child: SingleChildScrollView(



                                        child: DataTable(



                                          headingRowColor: WidgetStateProperty.all(AppColors.purpleContainer),



                                          columns: const [



                                            DataColumn(label: Text('ระดับชั้น', style: TextStyle(fontWeight: FontWeight.bold))),



                                            DataColumn(label: Text('ครูที่ปรึกษา (สูงสุด 3 คน)', style: TextStyle(fontWeight: FontWeight.bold))),



                                            DataColumn(label: Text('จัดการ', style: TextStyle(fontWeight: FontWeight.bold))),



                                          ],



                                          rows: dialogAdvisors.map((item) {



                                            return DataRow(



                                              cells: [



                                                DataCell(



                                                  Container(



                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),



                                                    decoration: BoxDecoration(



                                                      color: AppColors.purpleBorder,



                                                      borderRadius: BorderRadius.circular(6),



                                                    ),



                                                    child: Text(



                                                      item.classLevel,



                                                      style: TextStyle(



                                                        fontWeight: FontWeight.bold,



                                                        color: AppColors.purpleDark,



                                                      ),



                                                    ),



                                                  ),



                                                ),



                                                DataCell(



                                                  Wrap(



                                                    spacing: 6,



                                                    runSpacing: 4,



                                                    children: [



                                                      if (item.advisor1 != null && item.advisor1!.trim().isNotEmpty)



                                                        Chip(



                                                          avatar: CircleAvatar(



                                                            radius: 10,



                                                            backgroundColor: Colors.teal.shade100,



                                                            child: Text('1', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal.shade900)),



                                                          ),



                                                          label: Text(item.advisor1!, style: const TextStyle(fontSize: 12)),



                                                          visualDensity: VisualDensity.compact,



                                                        ),



                                                      if (item.advisor2 != null && item.advisor2!.trim().isNotEmpty)



                                                        Chip(



                                                          avatar: CircleAvatar(



                                                            radius: 10,



                                                            backgroundColor: Colors.teal.shade100,



                                                            child: Text('2', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal.shade900)),



                                                          ),



                                                          label: Text(item.advisor2!, style: const TextStyle(fontSize: 12)),



                                                          visualDensity: VisualDensity.compact,



                                                        ),



                                                      if (item.advisor3 != null && item.advisor3!.trim().isNotEmpty)



                                                        Chip(



                                                          avatar: CircleAvatar(



                                                            radius: 10,



                                                            backgroundColor: Colors.teal.shade100,



                                                            child: Text('3', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal.shade900)),



                                                          ),



                                                          label: Text(item.advisor3!, style: const TextStyle(fontSize: 12)),



                                                          visualDensity: VisualDensity.compact,



                                                        ),



                                                      if (item.nonNullAdvisors.isEmpty)



                                                        const Text('ยังไม่ระบุ', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),



                                                    ],



                                                  ),



                                                ),



                                                DataCell(



                                                  Row(



                                                    mainAxisSize: MainAxisSize.min,



                                                    children: [



                                                      IconButton(



                                                        icon: const Icon(Icons.edit, size: 18, color: Colors.blue),



                                                        tooltip: 'แก้ไข',



                                                        onPressed: () => openEditAdvisorSubDialog(item),



                                                      ),



                                                      IconButton(



                                                        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),



                                                        tooltip: 'ลบ',



                                                        onPressed: () => confirmDeleteAdvisor(item),



                                                      ),



                                                    ],



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



                      const SizedBox(height: 12),



                      Row(



                        mainAxisAlignment: MainAxisAlignment.end,



                        children: [



                          FilledButton(



                            style: FilledButton.styleFrom(



                              backgroundColor: AppColors.purplePrimary,



                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),



                            ),



                            onPressed: () => Navigator.of(ctx).pop(),



                            child: const Text('ปิดหน้าต่าง'),



                          ),



                        ],



                      ),



                    ],



                  ),



                ),



              ),



            );



          },



        );



      },



    );



  }







  List<StudentGrade> get _filteredGrades {



    if (_searchQuery.isEmpty) return _grades;



    final q = _searchQuery.toLowerCase();



    return _grades.where((g) =>



        g.fullName.toLowerCase().contains(q) ||



        g.studentId.toLowerCase().contains(q)).toList();



  }







  /// Phones / narrow windows: the page scrolls as a whole (see _fillOrFixed).
  Widget _scrollIfCompact(bool compact, Widget page) => compact ? SingleChildScrollView(child: page) : page;

  /// Fills the remaining height on wide screens; a fixed 85% of the screen when the page scrolls.
  Widget _fillOrFixed(bool compact, {required Widget child}) => compact
      ? SizedBox(height: MediaQuery.sizeOf(context).height * 0.85, child: child)
      : Expanded(child: child);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coursesForFilter = _filteredCourses;
    final compact = MediaQuery.sizeOf(context).width < 700;
    return _scrollIfCompact(compact, Padding(
      padding: EdgeInsets.all(compact ? 12 : 24),



      child: Column(



        crossAxisAlignment: CrossAxisAlignment.start,



        children: [



          // Title & Description + Import Excel Action Button



          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 780;
              final headerTexts = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'คลังข้อมูลผลการเรียน (ปพ.5 Archive)',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'ค้นหา ตรวจสอบ นำเข้า และดาวน์โหลดไฟล์ ปพ.5 ที่บันทึกไว้ในฐานข้อมูล',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              );

              final actionButtons = widget.apiService.isAdmin
                  ? Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _currentSemesterInfo.term != null
                                ? _currentSemesterInfo.color
                                : theme.colorScheme.primary,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                          label: Text(
                            _currentSemesterInfo.term != null
                                ? 'อัปโหลด SGS (PDF) เข้าเทอมนี้'
                                : 'อัปโหลดไฟล์ SGS (PDF)',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                          ),
                          onPressed: _openUploadPdfDialog,
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface,
                            side: BorderSide(color: theme.colorScheme.outline),
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: Icon(Icons.table_view_outlined, size: 18, color: _archiveExcel(theme)),
                          label: Text(
                            _currentSemesterInfo.term != null
                                ? 'นำเข้า Excel (.xlsx) เข้าเทอมนี้'
                                : 'นำเข้าข้อมูลจาก Excel (.xlsx)',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                          ),
                          onPressed: _openImportExcelDialog,
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface,
                            side: BorderSide(color: theme.colorScheme.outline),
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: Icon(Icons.people_alt_outlined, size: 18, color: theme.colorScheme.primary),
                          label: const Text(
                            'ครูประจำชั้น / ที่ปรึกษา',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                          ),
                          onPressed: _openAdvisorsManagementDialog,
                        ),
                      ],
                    )
                  : const SizedBox.shrink();

              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    headerTexts,
                    if (widget.apiService.isAdmin) ...[
                      const SizedBox(height: 14),
                      actionButtons,
                    ],
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: headerTexts),
                  const SizedBox(width: 16),
                  actionButtons,
                ],
              );
            },
          ),



          const SizedBox(height: 16),







          // ===================================================================



          // Dedicated Semester Action Buttons



          // ===================================================================



          Wrap(



            spacing: 12,



            runSpacing: 10,



            children: [



              ..._semesterConfigs.asMap().entries.map((entry) {



                final idx = entry.key;



                final conf = entry.value;



                final key = '${conf.term}-${conf.year}';



                final count = _allCourses.where((c) => c.term == conf.term && c.year == conf.year).length;



                final color = _semesterPalette[idx % _semesterPalette.length];



                return _buildSemesterButton(



                  semesterKey: key,



                  title: conf.title,



                  badgeText: count > 0 ? '$count รายวิชา' : 'ยังไม่มีฐานข้อมูล (รออัปโหลด)',



                  icon: count > 0 ? Icons.check_circle_rounded : Icons.cloud_upload_outlined,



                  activeColor: color,



                  badgeColor: count > 0 ? _archiveSuccess(theme) : color,



                );



              }),



              _buildSemesterButton(



                semesterKey: 'all',



                title: 'ทุกภาคเรียน',



                badgeText: 'รวม ${_allCourses.length} วิชา',



                icon: Icons.folder_copy_outlined,



                activeColor: theme.colorScheme.secondary,



                badgeColor: theme.colorScheme.secondary,



              ),



            ],



          ),



          const SizedBox(height: 16),







          // When any specific semester is selected and empty, show placeholder with upload prompt



          if (_selectedSemesterKey != 'all' && _coursesForSemester.isEmpty) ...[



            _fillOrFixed(compact, 



              child: Center(



                child: Card(



                  elevation: 0,



                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),



                  shape: RoundedRectangleBorder(



                    borderRadius: BorderRadius.circular(16),



                    side: BorderSide(color: theme.colorScheme.outlineVariant),



                  ),



                  child: Padding(



                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),



                    child: Column(



                      mainAxisSize: MainAxisSize.min,



                      children: [



                        Icon(



                          Icons.cloud_upload_outlined,



                          size: 72,



                          color: _currentSemesterInfo.color,



                        ),



                        const SizedBox(height: 16),



                        Text(



                          _currentSemesterInfo.name,



                          style: theme.textTheme.headlineSmall?.copyWith(



                            fontWeight: FontWeight.bold,



                          ),



                        ),



                        const SizedBox(height: 8),



                        Text(



                          'ยังไม่มีฐานข้อมูลสำหรับชุดนี้\nเมื่อมีไฟล์ ปพ.5 (Excel) หรือ SGS (PDF) สามารถนำเข้าสู่ระบบได้ทันที',



                          textAlign: TextAlign.center,



                          style: theme.textTheme.bodyMedium?.copyWith(



                            color: theme.colorScheme.onSurfaceVariant,



                            height: 1.5,



                          ),



                        ),



                        if (widget.apiService.isAdmin) ...[



                          const SizedBox(height: 24),



                          Wrap(



                            spacing: 12,



                            runSpacing: 10,



                            alignment: WrapAlignment.center,



                            children: [



                              FilledButton.icon(



                                onPressed: _openUploadPdfDialog,



                                icon: const Icon(Icons.picture_as_pdf_rounded),



                                label: Text('อัปโหลดไฟล์ SGS (PDF) เข้าสู่ ${_currentSemesterInfo.name}'),



                                style: FilledButton.styleFrom(



                                  backgroundColor: _currentSemesterInfo.color,



                                  foregroundColor: Colors.white,



                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),



                                ),



                              ),



                              FilledButton.icon(



                                onPressed: _openImportExcelDialog,



                                icon: const Icon(Icons.table_view_rounded),



                                label: Text('นำเข้าจากไฟล์ Excel (.xlsx) เข้าสู่ ${_currentSemesterInfo.name}'),



                                style: FilledButton.styleFrom(



                                  backgroundColor: Colors.teal.shade700,



                                  foregroundColor: Colors.white,



                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),



                                ),



                              ),



                            ],



                          ),



                        ] else ...[



                          const SizedBox(height: 16),



                          Container(



                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),



                            decoration: BoxDecoration(



                              color: Colors.amber.shade50,



                              borderRadius: BorderRadius.circular(8),



                              border: Border.all(color: Colors.amber.shade200),



                            ),



                            child: const Row(



                              mainAxisSize: MainAxisSize.min,



                              children: [



                                Icon(Icons.info_outline, size: 16, color: Colors.black54),



                                SizedBox(width: 8),



                                Text(



                                  'ยังไม่มีข้อมูลรายวิชาในภาคเรียนนี้ กรุณารอผู้ดูแลระบบนำเข้าข้อมูล',



                                  style: TextStyle(fontSize: 12, color: Colors.black87),



                                ),



                              ],



                            ),



                          ),



                        ],



                      ],



                    ),



                  ),



                ),



              ),



            ),



          ] else ...[



            // ===================================================================



            // Row 1: Filter Dropdowns (Teacher, Course Code) & Search Input



            // ===================================================================



            ResponsiveFieldsRow(
              flexes: const [3, 3, 2],
              children: [
// 1. Teacher Selector Dropdown
DropdownButtonFormField<String>(



                    initialValue: _availableTeachers.contains(_selectedTeacher) ? _selectedTeacher : 'all',



                    decoration: const InputDecoration(



                      labelText: 'เลือกครูผู้สอน',



                      border: OutlineInputBorder(),



                      prefixIcon: Icon(Icons.person_pin_rounded),



                      isDense: true,



                    ),



                    items: [



                      DropdownMenuItem(



                        value: 'all',



                        child: Text(



                          'ครูผู้สอนทั้งหมด (${_availableTeachers.length} ท่าน - รวม ${_coursesForSemester.length} รายวิชา)',



                          overflow: TextOverflow.ellipsis,



                        ),



                      ),



                      ..._availableTeachers.map((t) {



                        final cnt = _coursesForSemester.where((c) => c.teacher == t).length;



                        return DropdownMenuItem(



                          value: t,



                          child: Text('$t ($cnt รายวิชา)', overflow: TextOverflow.ellipsis),



                        );



                      }),



                    ],



                    onChanged: (val) {



                      if (val != null) _selectTeacher(val);



                    },



                  ),
// 2. Course Code Selector Dropdown (Filtered by Teacher)
DropdownButtonFormField<String>(



                    initialValue: _filteredCourses.any((c) => c.courseCode == _selectedCourseCode) ? _selectedCourseCode : 'all',



                    decoration: const InputDecoration(



                      labelText: 'เลือกรหัสวิชา / ระดับชั้น',



                      border: OutlineInputBorder(),



                      prefixIcon: Icon(Icons.class_outlined),



                      isDense: true,



                    ),



                    items: [



                      DropdownMenuItem(



                        value: 'all',



                        child: Text(



                          _selectedTeacher == 'all'



                              ? 'ทุกรายวิชา (${_filteredCourses.length} รายวิชา)'



                              : 'ทุกรายวิชาของครูท่านนี้ (${_filteredCourses.length} รายวิชา)',



                          overflow: TextOverflow.ellipsis,



                        ),



                      ),



                      ..._filteredCourses.map((c) {



                        final lvl = _inferClassLevelFromCourse(c.courseCode);



                        return DropdownMenuItem(



                          value: c.courseCode,



                          child: Text(



                            '${c.courseCode} ${c.courseName} ${lvl.isNotEmpty ? "($lvl)" : ""}',



                            overflow: TextOverflow.ellipsis,



                          ),



                        );



                      }),



                    ],



                    onChanged: (val) {



                      if (val != null) setState(() => _selectedCourseCode = val);



                    },



                  ),
// 3. Search Field (Course Code, Name, Teacher, Level)
TextField(



                    decoration: InputDecoration(



                      labelText: 'ค้นหารายวิชาหรือครู',



                      border: const OutlineInputBorder(),



                      prefixIcon: const Icon(Icons.search),



                      hintText: 'พิมพ์รหัสวิชา, ชื่อวิชา หรือชื่อครู',



                      isDense: true,



                      suffixIcon: _searchQuery.isNotEmpty



                          ? IconButton(



                              icon: const Icon(Icons.clear, size: 18),



                              onPressed: () => setState(() => _searchQuery = ''),



                            )



                          : null,



                    ),



                    onChanged: (val) => setState(() => _searchQuery = val),



                  ),
              ],
            ),



            const SizedBox(height: 12),







            // ===================================================================



            // Row 2: Teacher Quick Filter Chips



            // ===================================================================



            if (_availableTeachers.isNotEmpty)



              Wrap(
                runSpacing: 6,
                children: [



                    ChoiceChip(



                      label: Text('ทั้งหมด (${_coursesForSemester.length})'),



                      selected: _selectedTeacher == 'all',



                      onSelected: (sel) {



                        if (sel) _selectTeacher('all');



                      },



                    ),



                    const SizedBox(width: 8),



                    ..._availableTeachers.map((t) {



                      final cnt = _coursesForSemester.where((c) => c.teacher == t).length;



                      return Padding(



                        padding: const EdgeInsets.only(right: 8),



                        child: ChoiceChip(



                          avatar: CircleAvatar(



                            backgroundColor: theme.colorScheme.secondaryContainer,



                            child: Text(



                              () {



                                final clean = t.replaceFirst(RegExp(r'^(นาย|นางสาว|นาง|ครู)\s*'), '');



                                return clean.isNotEmpty ? clean.characters.first : (t.isNotEmpty ? t.characters.first : '?');



                              }(),



                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: theme.colorScheme.onSecondaryContainer),



                            ),



                          ),



                          label: Text('$t ($cnt)'),



                          selected: _selectedTeacher == t,



                          onSelected: (sel) {



                            if (sel) _selectTeacher(t);



                          },



                        ),



                      );



                    }),



                  ],
              ),



            const SizedBox(height: 12),







            // ===================================================================



            // Row 3: Teacher Profile Summary & Tip Banner



            // ===================================================================



            Container(



              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),



              decoration: BoxDecoration(



                color: theme.colorScheme.surfaceContainerLow,



                borderRadius: BorderRadius.circular(10),



                border: Border.all(color: theme.colorScheme.outlineVariant),



              ),



              child: Row(



                children: [



                  Icon(



                    _selectedTeacher == 'all' ? Icons.folder_open_outlined : Icons.person_outline_rounded,



                    color: theme.colorScheme.primary,



                    size: 20,



                  ),



                  const SizedBox(width: 10),



                  Expanded(



                    child: Text(



                      _selectedTeacher == 'all'



                          ? 'รายวิชาทั้งหมดในภาคเรียนนี้ (รวม ${_displayedCourses.length} รายวิชา)'



                          : 'ครูผู้สอน: $_selectedTeacher • รวม ${_displayedCourses.length} รายวิชา',



                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.4),



                      overflow: TextOverflow.ellipsis,



                    ),



                  ),



                  Icon(Icons.info_outline_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),



                  const SizedBox(width: 6),



                  Flexible(



                    child: Text(



                      'คอลัมน์ ลำดับ–ระดับชั้น ถูกตรึงไว้ เลื่อนซ้าย-ขวาเพื่อดูส่วนที่เหลือ',



                      style: TextStyle(fontSize: 12.5, height: 1.4, color: theme.colorScheme.onSurfaceVariant),



                      overflow: TextOverflow.ellipsis,



                    ),



                  ),



                  if (_selectedTeacher != 'all' || _selectedCourseCode != 'all' || _searchQuery.isNotEmpty) ...[



                    const SizedBox(width: 8),



                    TextButton.icon(



                      onPressed: () {



                        setState(() {



                          _selectedTeacher = 'all';



                          _selectedCourseCode = 'all';



                          _searchQuery = '';



                        });



                      },



                      icon: const Icon(Icons.refresh, size: 16),



                      label: const Text('ล้างตัวกรองทั้งหมด'),



                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),



                    ),



                  ],



                ],



              ),



            ),



            const SizedBox(height: 12),







            // ===================================================================



            // Row 4: Main Table (Teacher's Courses Table)



            // ===================================================================



            _fillOrFixed(compact, 



              child: _displayedCourses.isEmpty



                  ? Center(



                      child: Column(



                        mainAxisAlignment: MainAxisAlignment.center,



                        children: [



                          Icon(Icons.inbox_outlined, size: 64, color: theme.colorScheme.outlineVariant),



                          const SizedBox(height: 16),



                          Text(



                            _coursesForSemester.isEmpty



                                ? 'ยังไม่มีข้อมูลรายวิชาในภาคเรียนนี้\nกรุณาอัปโหลดไฟล์ ปพ.5 หรือ SGS PDF'



                                : 'ไม่พบรายวิชาที่ตรงกับเงื่อนไขการค้นหา',



                            textAlign: TextAlign.center,



                            style: theme.textTheme.bodyLarge?.copyWith(



                              color: theme.colorScheme.onSurfaceVariant,



                            ),



                          ),



                          if (_selectedTeacher != 'all' || _selectedCourseCode != 'all' || _searchQuery.isNotEmpty) ...[



                            const SizedBox(height: 16),



                            FilledButton.icon(



                              onPressed: () {



                                setState(() {



                                  _selectedTeacher = 'all';



                                  _selectedCourseCode = 'all';



                                  _searchQuery = '';



                                });



                              },



                              icon: const Icon(Icons.clear_all_rounded),



                              label: const Text('แสดงรายวิชาทั้งหมด'),



                            ),



                          ],



                        ],



                      ),



                    )



                  : Container(



                      decoration: BoxDecoration(



                        color: theme.colorScheme.surface,



                        borderRadius: BorderRadius.circular(12),



                        border: Border.all(color: theme.colorScheme.outlineVariant),



                      ),



                      clipBehavior: Clip.antiAlias,



                      child: _CourseArchiveTable(



                        courses: _displayedCourses,



                        inferLevel: _inferClassLevelFromCourse,



                        advisorsFor: _getAdvisorsForCourse,



                        canManageCourse: _canManageCourse,



                        onEditDescription: _openCourseDescriptionDialog,



                        onAttendance: _openAttendanceDialog,



                        onOpenFile: _openFileVerifyAndPrintDialog,



                        apiService: widget.apiService,



                      ),



                    ),



            ),



          ],



        ],



      ),



    ));



  }







  Widget _buildSemesterButton({



    required String semesterKey,



    required String title,



    required String badgeText,



    required IconData icon,



    required Color activeColor,



    required Color badgeColor,



  }) {



    final isSelected = _selectedSemesterKey == semesterKey;



    final theme = Theme.of(context);







    return InkWell(



      onTap: () => _selectSemester(semesterKey),



      borderRadius: BorderRadius.circular(12),



      child: AnimatedContainer(



        duration: const Duration(milliseconds: 200),



        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),



        decoration: BoxDecoration(



          color: isSelected



              ? activeColor.withValues(alpha: 0.12)



              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),



          border: Border.all(



            color: isSelected ? activeColor : theme.colorScheme.outlineVariant,



            width: isSelected ? 2.0 : 1.0,



          ),



          borderRadius: BorderRadius.circular(12),



        ),



        child: Row(



          mainAxisSize: MainAxisSize.min,



          children: [



            Icon(



              icon,



              size: 20,



              color: isSelected ? activeColor : theme.colorScheme.onSurfaceVariant,



            ),



            const SizedBox(width: 10),



            Column(



              crossAxisAlignment: CrossAxisAlignment.start,



              mainAxisSize: MainAxisSize.min,



              children: [



                Text(



                  title,



                  style: theme.textTheme.bodyMedium?.copyWith(



                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,



                    color: isSelected ? activeColor : theme.colorScheme.onSurface,



                  ),



                ),



                const SizedBox(height: 2),



                Text(



                  badgeText,



                  style: theme.textTheme.labelSmall?.copyWith(



                    color: badgeColor,



                    fontWeight: FontWeight.w600,



                  ),



                ),



              ],



            ),



          ],



        ),



      ),



    );



  }







  Color _gradeColor(String grade, ThemeData theme) {



    return switch (grade) {



      '4' || '4.0' => Colors.green.shade100,



      '3.5' || '3' || '3.0' => Colors.lightGreen.shade100,



      '2.5' || '2' || '2.0' => Colors.amber.shade100,



      '1.5' || '1' || '1.0' => Colors.orange.shade100,



      '0' || '0.0' || 'ร' || 'มส' || 'มผ' => Colors.red.shade100,



      'ผ' => Colors.green.shade100,



      _ => theme.colorScheme.surfaceContainerHighest,



    };



  }



}







class _CourseVerifyAndPrintDialog extends StatefulWidget {



  final Course course;



  final String initialFormat;



  final ApiService apiService;



  final List<ClassAdvisorItem> classAdvisors;



  final bool canManage;



  final Function(String) onTeacherUpdated;



  final VoidCallback onOpenAdvisorsDialog;



  final VoidCallback onDownloadExcel;



  final VoidCallback onDownloadPdf;







  const _CourseVerifyAndPrintDialog({



    required this.course,



    required this.initialFormat,



    required this.apiService,



    required this.classAdvisors,



    this.canManage = true,



    required this.onTeacherUpdated,



    required this.onOpenAdvisorsDialog,



    required this.onDownloadExcel,



    required this.onDownloadPdf,



  });







  @override



  State<_CourseVerifyAndPrintDialog> createState() => _CourseVerifyAndPrintDialogState();



}







class _CourseVerifyAndPrintDialogState extends State<_CourseVerifyAndPrintDialog> {

  late String _viewMode; // 'pdf', 'excel', or 'scores'

  Map<String, dynamic>? _preview;
  bool _loading = true;
  String? _error;
  String? _teacher;

  // Real PDF State
  Map<String, dynamic>? _pdfData;
  bool _loadingPdf = false;
  String? _pdfError;
  int _selectedPageIndex = 0;
  bool _continuousScroll = true;
  double _zoomScale = 1.0;
  bool _regeneratingPdf = false;
  int _imageBuster = 0;
  final ScrollController _pdfScrollController = ScrollController();
  final List<GlobalKey> _pageKeys = [];

  // Real Excel Sheets State
  Map<String, dynamic>? _excelData;
  bool _loadingExcel = false;
  String? _excelError;
  int _selectedExcelSheetIndex = 0;
  String? _selectedCellCoord;
  String? _selectedCellValue;
  final ScrollController _excelHScrollController = ScrollController();
  final ScrollController _excelVScrollController = ScrollController();
  // the teacher of this course (or an admin) may type the vertical ตัวชี้วัด / คุณลักษณะ headers (pp5_labels)
  bool _pp5CanEdit = false;

  @override
  void initState() {
    super.initState();
    _teacher = widget.course.teacher;
    if (widget.initialFormat == 'pdf') {
      _viewMode = 'pdf';
    } else if (widget.initialFormat == 'excel') {
      _viewMode = 'excel';
    } else {
      _viewMode = 'scores';
    }
    _fetchPreview();
    if (_viewMode == 'pdf') {
      _fetchPdfPages();
    } else if (_viewMode == 'excel') {
      _fetchExcelSheets();
    }
  }

  @override
  void dispose() {
    _pdfScrollController.dispose();
    _excelHScrollController.dispose();
    _excelVScrollController.dispose();
    super.dispose();
  }

  /// [keepSheet]: reload quietly after an edit, staying on the same sheet (no spinner, no jump back to sheet 1).
  Future<void> _fetchExcelSheets({bool keepSheet = false}) async {
    if (!keepSheet) {
      setState(() {
        _loadingExcel = true;
        _excelError = null;
      });
    }
    try {
      final res = await widget.apiService.getCourseExcelSheets(
        widget.course.courseCode,
        term: widget.course.term,
        year: widget.course.year,
      );
      var canEdit = false;
      try {
        final labels = await widget.apiService.getPp5Labels(
          courseCode: widget.course.courseCode,
          term: widget.course.term,
          year: widget.course.year,
        );
        canEdit = labels['can_edit'] == true;
      } catch (_) {
        // not signed in as a teacher: the sheets stay read-only
      }
      if (mounted) {
        setState(() {
          _excelData = res;
          _pp5CanEdit = canEdit;
          _loadingExcel = false;
          if (!keepSheet) {
            _selectedExcelSheetIndex = 0;
            _selectedCellCoord = null;
            _selectedCellValue = null;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingExcel = false;
          _excelError = 'ไม่สามารถดึงข้อมูลแผ่นงาน Excel ได้: $e';
        });
      }
    }
  }

  /// Grid row height: taller when the row holds text written upwards (the ตัวชี้วัด / คุณลักษณะ headers).
  double _excelRowHeight(List rowData) {
    var h = 26.0;
    for (final cell in rowData) {
      if (cell is! Map || cell['rot'] != 90) continue;
      final v = cell['v']?.toString() ?? '';
      if (v.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: v,
          // the app's own font, so the measured length matches what the cell draws
          style: DefaultTextStyle.of(context).style.copyWith(
                fontSize: 11,
                fontWeight: cell['b'] == true ? FontWeight.bold : FontWeight.normal,
              ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (tp.width + 24 > h) h = tp.width + 24;
    }
    return h > 360 ? 360 : h;
  }

  /// lab = "<group>:<index>" from the server (indicators = sheet 4, attributes / reading = sheet 5)
  Future<void> _editPp5Label(String lab) async {
    final parts = lab.split(':');
    final group = parts.first;
    final index = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final saved = await showPp5LabelsDialog(
      context,
      api: widget.apiService,
      courseCode: widget.course.courseCode,
      term: widget.course.term,
      year: widget.course.year,
      sheet5: group != 'indicators',
      focusGroup: group,
      focusIndex: index,
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(group == 'indicators' ? 'บันทึกตัวชี้วัดลง ปพ.5 แล้ว' : 'บันทึกหัวข้อคุณลักษณะลง ปพ.5 แล้ว'),
        backgroundColor: Colors.green.shade700,
      ),
    );
    setState(() {
      _pdfData = null; // the PDF tab renders the new headers the next time it opens
      _selectedCellCoord = null; // the formula bar would still show the old text
      _selectedCellValue = null;
    });
    await _fetchExcelSheets(keepSheet: true);
  }

  Future<void> _openExcelFullScreen() async {
    final url = widget.apiService.getCourseExcelViewUrl(
      widget.course.courseCode,
      term: widget.course.term,
      year: widget.course.year,
    );
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('ไม่สามารถเปิดหน้าต่าง Excel: $url')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('เกิดข้อผิดพลาดในการเปิด Excel: $e')),
        );
      }
    }
  }

  String _colLetter(int colIdx) {
    String res = '';
    while (colIdx > 0) {
      int rem = (colIdx - 1) % 26;
      colIdx = (colIdx - 1) ~/ 26;
      res = String.fromCharCode(65 + rem) + res;
    }
    return res;
  }

  Future<void> _fetchPreview() async {



    setState(() {



      _loading = true;



      _error = null;



    });



    try {



      final res = await widget.apiService.getCoursePreview(



        widget.course.courseCode,



        term: widget.course.term,



        year: widget.course.year,



      );



      if (mounted) {



        setState(() {



          _preview = res;



          _teacher = res['teacher'] ?? widget.course.teacher;



          _loading = false;



        });



      }



    } catch (e) {



      if (mounted) {



        setState(() {



          _loading = false;



          _error = 'ไม่สามารถดึงข้อมูลตรวจสอบรายวิชาได้: $e';



        });



      }



    }



  }







  Future<void> _fetchPdfPages({bool force = false}) async {



    setState(() {



      _loadingPdf = true;



      _pdfError = null;



      if (force) _regeneratingPdf = true;



    });



    try {



      final res = await widget.apiService.getCoursePdfPages(



        widget.course.courseCode,



        term: widget.course.term,



        year: widget.course.year,



        force: force,



      );



      if (mounted) {



        final pages = (res['pages'] as List?) ?? [];



        _pageKeys.clear();



        for (int i = 0; i < pages.length; i++) {



          _pageKeys.add(GlobalKey());



        }



        setState(() {



          _pdfData = res;



          _loadingPdf = false;



          _regeneratingPdf = false;



          if (force) {



            _imageBuster = DateTime.now().millisecondsSinceEpoch;



          }



        });



        if (force) {



          ScaffoldMessenger.of(context).showSnackBar(



            const SnackBar(content: Text('สร้างและอัปเดตไฟล์ PDF ใหม่จาก Excel สำเร็จแล้ว')),



          );



        }



      }



    } catch (e) {



      if (mounted) {



        setState(() {



          _loadingPdf = false;



          _regeneratingPdf = false;



          _pdfError = 'ไม่สามารถดึงข้อมูลหน้าเอกสาร PDF ได้: $e';



        });



      }



    }



  }







  Future<void> _editTeacherName() async {



    final controller = TextEditingController(text: _teacher ?? '');



    final confirmed = await showDialog<bool>(



      context: context,



      builder: (ctx) {



        return AlertDialog(



          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



          title: const Row(



            children: [



              Icon(Icons.edit_note_rounded, color: Colors.blue, size: 28),



              SizedBox(width: 8),



              Text('แก้ไข/เปลี่ยนชื่อครูผู้สอน'),



            ],



          ),



          content: SizedBox(



            width: 450,



            child: Column(



              mainAxisSize: MainAxisSize.min,



              crossAxisAlignment: CrossAxisAlignment.start,



              children: [



                Text(



                  'วิชา: ${widget.course.courseCode} ${widget.course.courseName}',



                  style: const TextStyle(fontWeight: FontWeight.bold),



                ),



                const SizedBox(height: 6),



                const Text(



                  'ชื่อครูนี้จะถูกบันทึกลงฐานข้อมูล และพิมพ์ลงในช่อง E11 ของหน้าปก ปพ.5',



                  style: TextStyle(fontSize: 12, color: Colors.grey),



                ),



                const SizedBox(height: 16),



                TextField(



                  controller: controller,



                  autofocus: true,



                  decoration: const InputDecoration(



                    labelText: 'ชื่อ-นามสกุล ครูผู้สอน',



                    hintText: 'เช่น นายสมชาย ใจดี หรือ นางสาวสมหญิง รักเรียน',



                    border: OutlineInputBorder(),



                    prefixIcon: Icon(Icons.person_outline),



                  ),



                ),



              ],



            ),



          ),



          actions: [



            TextButton(



              onPressed: () => Navigator.of(ctx).pop(false),



              child: const Text('ยกเลิก'),



            ),



            FilledButton.icon(



              onPressed: () => Navigator.of(ctx).pop(true),



              icon: const Icon(Icons.check, size: 18),



              label: const Text('บันทึก'),



            ),



          ],



        );



      },



    );







    if (confirmed == true && controller.text.trim().isNotEmpty) {



      final newT = controller.text.trim();



      try {



        await widget.apiService.updateCourseTeacher(



          courseCode: widget.course.courseCode,



          teacher: newT,



          term: widget.course.term,



          year: widget.course.year,



        );



        widget.onTeacherUpdated(newT);



        await _fetchPreview();



        // Also re-render PDF if loaded



        if (_pdfData != null || _viewMode == 'pdf') {



          await _fetchPdfPages(force: true);



        }



        if (mounted) {



          ScaffoldMessenger.of(context).showSnackBar(



            SnackBar(content: Text('อัปเดตชื่อครูผู้สอนเป็น "$newT" เรียบร้อยแล้ว')),



          );



        }



      } catch (e) {



        if (mounted) {



          ScaffoldMessenger.of(context).showSnackBar(



            SnackBar(content: Text('บันทึกชื่อครูไม่สำเร็จ: $e')),



          );



        }



      }



    }



  }







  Future<void> _triggerPrint() async {



    if (!widget.canManage) {



      if (mounted) {



        ScaffoldMessenger.of(context).showSnackBar(



          const SnackBar(content: Text('ท่านสามารถสั่งพิมพ์เอกสารได้เฉพาะวิชาที่ท่านสอนเท่านั้น')),



        );



      }



      return;



    }



    final printUrl = widget.apiService.getPrintPdfUrl(



      widget.course.courseCode,



      term: widget.course.term,



      year: widget.course.year,



    );



    final uri = Uri.parse(printUrl);



    try {



      if (await canLaunchUrl(uri)) {



        await launchUrl(uri, mode: LaunchMode.externalApplication);



      } else {



        if (mounted) {



          ScaffoldMessenger.of(context).showSnackBar(



            SnackBar(content: Text('ไม่สามารถเปิดหน้าต่างพิมพ์: $printUrl')),



          );



        }



      }



    } catch (e) {



      if (mounted) {



        ScaffoldMessenger.of(context).showSnackBar(



          SnackBar(content: Text('เกิดข้อผิดพลาดในการพิมพ์: $e')),



        );



      }



    }



  }







  String _shortPageTitle(int index, String fullTitle) {



    if (fullTitle.contains('ปก')) return 'หน้าปก';



    if (fullTitle.contains('เวลาเรียน 1')) return 'เวลาเรียน 1';



    if (fullTitle.contains('เวลาเรียน 2')) return 'เวลาเรียน 2';



    if (fullTitle.contains('รวมคะแนน')) return 'รวมคะแนน';



    if (fullTitle.contains('คุณลักษณะ')) return 'คุณลักษณะ';



    if (fullTitle.contains('ตัวชี้วัด')) return 'ตัวชี้วัด';



    if (fullTitle.contains('คำชี้แจง')) return 'คำชี้แจง';



    return 'หน้า ${index + 1}';



  }







  void _scrollToPage(int index) {



    if (index >= 0 && index < _pageKeys.length) {



      final keyContext = _pageKeys[index].currentContext;



      if (keyContext != null) {



        Scrollable.ensureVisible(



          keyContext,



          duration: const Duration(milliseconds: 300),



          curve: Curves.easeInOut,



        );



      }



    }



  }







  Widget _buildGradeBadge(String grade, int count, Color color) {



    return Container(



      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),



      decoration: BoxDecoration(



        color: color.withValues(alpha: 0.12),



        borderRadius: BorderRadius.circular(8),



        border: Border.all(color: color.withValues(alpha: 0.35)),



      ),



      child: Column(



        mainAxisSize: MainAxisSize.min,



        children: [



          Text(



            'เกรด $grade',



            style: TextStyle(



              fontSize: 12,



              fontWeight: FontWeight.bold,



              color: color,



            ),



          ),



          const SizedBox(height: 2),



          Text(



            '$count คน',



            style: TextStyle(



              fontSize: 13,



              fontWeight: FontWeight.w700,



              color: color,



            ),



          ),



        ],



      ),



    );



  }







  Widget _buildSinglePageCard(BuildContext ctx, Map<String, dynamic> page, int index, int totalPages) {



    final title = page['title']?.toString() ?? 'หน้า ${index + 1}';



    final isLandscape = page['is_landscape'] == true;



    final pageWidth = page['width'] is num ? (page['width'] as num).toDouble() : (isLandscape ? 842.0 : 595.0);



    final pageHeight = page['height'] is num ? (page['height'] as num).toDouble() : (isLandscape ? 595.0 : 842.0);







    var rawUrl = page['image_url'] as String? ?? '';



    if (!rawUrl.startsWith('http')) {



      rawUrl = '${widget.apiService.baseUrl}$rawUrl';



    }



    if (_imageBuster > 0) {



      rawUrl += rawUrl.contains('?') ? '&_b=$_imageBuster' : '?_b=$_imageBuster';



    }







    final baseWidth = isLandscape ? 880.0 : 660.0;



    final displayWidth = baseWidth * _zoomScale;



    final aspectRatio = pageWidth / pageHeight;



    final key = (index < _pageKeys.length) ? _pageKeys[index] : null;







    return Center(



      key: key,



      child: Container(



        width: displayWidth,



        margin: const EdgeInsets.only(bottom: 12),



        decoration: BoxDecoration(



          color: Colors.white,



          borderRadius: BorderRadius.circular(8),



          boxShadow: [



            BoxShadow(



              color: Colors.black.withValues(alpha: 0.14),



              blurRadius: 12,



              offset: const Offset(0, 4),



            ),



          ],



        ),



        child: Column(



          crossAxisAlignment: CrossAxisAlignment.stretch,



          children: [



            // Page Header Ribbon



            Container(



              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),



              decoration: BoxDecoration(



                color: AppColors.purpleContainer,



                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),



                border: Border(bottom: BorderSide(color: AppColors.purpleBorder)),



              ),



              child: Row(



                children: [



                  Container(



                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),



                    decoration: BoxDecoration(



                      color: AppColors.purplePrimary,



                      borderRadius: BorderRadius.circular(4),



                    ),



                    child: Text(



                      'หน้า ${index + 1} / $totalPages',



                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),



                    ),



                  ),



                  const SizedBox(width: 10),



                  Expanded(



                    child: Text(



                      title,



                      style: TextStyle(



                        fontSize: 13,



                        fontWeight: FontWeight.bold,



                        color: AppColors.purpleDark,



                      ),



                      overflow: TextOverflow.ellipsis,



                    ),



                  ),



                  Container(



                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),



                    decoration: BoxDecoration(



                      color: Colors.green.shade100,



                      borderRadius: BorderRadius.circular(4),



                      border: Border.all(color: Colors.green.shade300),



                    ),



                    child: Row(



                      mainAxisSize: MainAxisSize.min,



                      children: [



                        Icon(Icons.check_circle_rounded, size: 13, color: Colors.green.shade800),



                        const SizedBox(width: 4),



                        Text(



                          'ตรงกับชีท Excel',



                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green.shade900),



                        ),



                      ],



                    ),



                  ),



                  const SizedBox(width: 8),



                  Text(



                    isLandscape ? 'แนวนอน A4' : 'แนวตั้ง A4',



                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),



                  ),



                ],



              ),



            ),







            // Page Rendered Image



            AspectRatio(



              aspectRatio: aspectRatio,



              child: Image.network(



                rawUrl,



                fit: BoxFit.contain,



                loadingBuilder: (context, child, loadingProgress) {



                  if (loadingProgress == null) return child;



                  final total = loadingProgress.expectedTotalBytes;



                  final loaded = loadingProgress.cumulativeBytesLoaded;



                  final progress = (total != null && total > 0) ? (loaded / total) : null;



                  return Center(



                    child: Column(



                      mainAxisSize: MainAxisSize.min,



                      children: [



                        CircularProgressIndicator(value: progress),



                        const SizedBox(height: 10),



                        Text('กำลังเรนเดอร์หน้า ${index + 1}...', style: const TextStyle(fontSize: 12, color: Colors.grey)),



                      ],



                    ),



                  );



                },



                errorBuilder: (context, error, stackTrace) {



                  return Container(



                    padding: const EdgeInsets.all(24),



                    alignment: Alignment.center,



                    child: Column(



                      mainAxisSize: MainAxisSize.min,



                      children: [



                        const Icon(Icons.broken_image_rounded, size: 40, color: Colors.red),



                        const SizedBox(height: 8),



                        Text('ไม่สามารถโหลดภาพหน้า ${index + 1} ได้: $error', style: const TextStyle(fontSize: 12, color: Colors.red)),



                        const SizedBox(height: 10),



                        OutlinedButton.icon(



                          onPressed: () => _fetchPdfPages(force: true),



                          icon: const Icon(Icons.refresh, size: 14),



                          label: const Text('ลองใหม่'),



                        ),



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



  }







  Widget _buildPdfView(ThemeData theme) {



    if (_loadingPdf) {



      return Center(



        child: Column(



          mainAxisSize: MainAxisSize.min,



          children: [



            const CircularProgressIndicator(),



            const SizedBox(height: 16),



            Text(



              _regeneratingPdf



                  ? 'กำลังแปลงข้อมูลจากชีท Excel ออกมาเป็นหน้า PDF จริง...'



                  : 'กำลังเรนเดอร์หน้าเอกสาร PDF จริง...',



              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),



            ),



            const SizedBox(height: 6),



            Text(



              'วิชา: ${widget.course.courseCode} ${widget.course.courseName} (${widget.course.term}/${widget.course.year})',



              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),



            ),



          ],



        ),



      );



    }







    if (_pdfError != null) {



      return Center(



        child: Column(



          mainAxisSize: MainAxisSize.min,



          children: [



            const Icon(Icons.error_outline, size: 48, color: Colors.red),



            const SizedBox(height: 12),



            Padding(



              padding: const EdgeInsets.symmetric(horizontal: 24),



              child: Text(_pdfError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),



            ),



            const SizedBox(height: 16),



            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(



              onPressed: () => _fetchPdfPages(force: true),



              icon: const Icon(Icons.refresh),



              label: const Text('ลองสร้าง PDF ใหม่อีกครั้ง'),



            ),
                FilledButton.tonalIcon(
                  onPressed: () => setState(() => _viewMode = 'scores'),
                  icon: const Icon(Icons.table_chart_outlined),
                  label: const Text('ดูข้อมูลผลการเรียนจาก Excel แทน'),
                ),
              ],
            )



          ],



        ),



      );



    }







    final pages = (_pdfData?['pages'] as List?)?.cast<Map<String, dynamic>>() ?? [];



    if (pages.isEmpty) {



      return const Center(child: Text('ไม่พบหน้าเอกสารในไฟล์ PDF'));



    }







    final totalPages = pages.length;







    return Column(



      children: [



        // Top Toolbar inside PDF View



        Container(



          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),



          decoration: BoxDecoration(



            color: Colors.grey.shade100,



            borderRadius: BorderRadius.circular(10),



            border: Border.all(color: Colors.grey.shade300),



          ),



          child: Row(



            children: [



              // Continuous / Single mode



              SegmentedButton<bool>(



                segments: const [



                  ButtonSegment<bool>(



                    value: true,



                    icon: Icon(Icons.view_agenda_rounded, size: 16),



                    label: Text('เลื่อนต่อเนื่อง', style: TextStyle(fontSize: 12)),



                  ),



                  ButtonSegment<bool>(



                    value: false,



                    icon: Icon(Icons.single_bed_rounded, size: 16),



                    label: Text('ดูทีละหน้า', style: TextStyle(fontSize: 12)),



                  ),



                ],



                selected: {_continuousScroll},



                onSelectionChanged: (set) {



                  setState(() => _continuousScroll = set.first);



                },



                style: SegmentedButton.styleFrom(



                  visualDensity: VisualDensity.compact,



                ),



              ),



              const SizedBox(width: 12),







              // Page selector chips (quick jump)



              Expanded(



                child: Wrap(
  runSpacing: 6,
  children: List.generate(totalPages, (i) {



                      final p = pages[i];



                      final isSelected = _selectedPageIndex == i;



                      final title = p['title']?.toString() ?? '';



                      final short = '${i + 1}. ${_shortPageTitle(i, title)}';







                      return Padding(



                        padding: const EdgeInsets.only(right: 6),



                        child: ChoiceChip(



                          label: Text(



                            short,



                            style: TextStyle(



                              fontSize: 11,



                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,



                              color: isSelected ? Colors.red.shade900 : Colors.grey.shade800,



                            ),



                          ),



                          selected: isSelected,



                          selectedColor: Colors.red.shade100,



                          backgroundColor: Colors.white,



                          side: BorderSide(



                            color: isSelected ? Colors.red.shade400 : Colors.grey.shade300,



                            width: isSelected ? 1.5 : 1,



                          ),



                          visualDensity: VisualDensity.compact,



                          onSelected: (val) {



                            if (val) {



                              setState(() => _selectedPageIndex = i);



                              if (_continuousScroll) {



                                _scrollToPage(i);



                              }



                            }



                          },



                        ),



                      );



                    }),
),



              ),



              const SizedBox(width: 8),







              // Zoom controls



              IconButton(



                onPressed: _zoomScale > 0.6



                    ? () => setState(() => _zoomScale = (_zoomScale - 0.15).clamp(0.6, 2.0))



                    : null,



                icon: const Icon(Icons.zoom_out, size: 20),



                tooltip: 'ย่อขนาด',



                visualDensity: VisualDensity.compact,



              ),



              InkWell(



                onTap: () => setState(() => _zoomScale = 1.0),



                child: Container(



                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),



                  decoration: BoxDecoration(



                    color: Colors.white,



                    borderRadius: BorderRadius.circular(4),



                    border: Border.all(color: Colors.grey.shade300),



                  ),



                  child: Text(



                    '${(_zoomScale * 100).toInt()}%',



                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),



                  ),



                ),



              ),



              IconButton(



                onPressed: _zoomScale < 2.0



                    ? () => setState(() => _zoomScale = (_zoomScale + 0.15).clamp(0.6, 2.0))



                    : null,



                icon: const Icon(Icons.zoom_in, size: 20),



                tooltip: 'ขยายขนาด',



                visualDensity: VisualDensity.compact,



              ),



              const SizedBox(width: 6),







              // Re-export PDF from Excel button



              OutlinedButton.icon(



                onPressed: _loadingPdf ? null : () => _fetchPdfPages(force: true),



                icon: const Icon(Icons.sync_rounded, size: 16),



                label: const Text('อัปเดตจาก Excel', style: TextStyle(fontSize: 11)),



                style: OutlinedButton.styleFrom(



                  visualDensity: VisualDensity.compact,



                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),



                ),



              ),



            ],



          ),



        ),



        const SizedBox(height: 10),







        // Main Page Display Area



        Expanded(



          child: Container(



            decoration: BoxDecoration(



              color: Colors.grey.shade200,



              borderRadius: BorderRadius.circular(10),



              border: Border.all(color: Colors.grey.shade300),



            ),



            child: _continuousScroll



                ? ListView.separated(



                    controller: _pdfScrollController,



                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),



                    itemCount: totalPages,



                    separatorBuilder: (context, index) => const SizedBox(height: 20),



                    itemBuilder: (ctx, i) {



                      return _buildSinglePageCard(ctx, pages[i], i, totalPages);



                    },



                  )



                : Column(



                    children: [



                      // Single page navigation bar



                      Container(



                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),



                        color: Colors.grey.shade100,



                        child: Row(



                          mainAxisAlignment: MainAxisAlignment.center,



                          children: [



                            IconButton(



                              onPressed: _selectedPageIndex > 0



                                  ? () => setState(() => _selectedPageIndex--)



                                  : null,



                              icon: const Icon(Icons.chevron_left_rounded),



                              tooltip: 'หน้าก่อนหน้า',



                            ),



                            const SizedBox(width: 8),



                            Text(



                              'หน้า ${_selectedPageIndex + 1} จาก $totalPages: ${pages[_selectedPageIndex]['title']}',



                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),



                            ),



                            const SizedBox(width: 8),



                            IconButton(



                              onPressed: _selectedPageIndex < totalPages - 1



                                  ? () => setState(() => _selectedPageIndex++)



                                  : null,



                              icon: const Icon(Icons.chevron_right_rounded),



                              tooltip: 'หน้าถัดไป',



                            ),



                          ],



                        ),



                      ),



                      const Divider(height: 1),



                      Expanded(



                        child: SingleChildScrollView(



                          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),



                          child: _buildSinglePageCard(



                            context,



                            pages[_selectedPageIndex],



                            _selectedPageIndex,



                            totalPages,



                          ),



                        ),



                      ),



                    ],



                  ),



          ),



        ),



      ],



    );



  }







  
  Widget _buildExcelView(ThemeData theme) {
    if (_loadingExcel) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF107C41)),
            const SizedBox(height: 16),
            const Text(
              'กำลังโหลดและอ่านข้อมูลแผ่นงาน Excel จริง (ครบทุก 7 ชีท)...',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              'วิชา: ${widget.course.courseCode} ${widget.course.courseName} (${widget.course.term}/${widget.course.year})',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }

    if (_excelError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_excelError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _fetchExcelSheets,
              icon: const Icon(Icons.refresh),
              label: const Text('ลองใหม่อีกครั้ง'),
            ),
          ],
        ),
      );
    }

    final sheets = (_excelData?['sheets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (sheets.isEmpty) {
      return const Center(child: Text('ไม่พบข้อมูลแผ่นงานในไฟล์ Excel'));
    }

    final currentSheet = sheets[_selectedExcelSheetIndex.clamp(0, sheets.length - 1)];
    final maxRows = (currentSheet['max_row'] as num?)?.toInt() ?? 0;
    final maxCols = (currentSheet['max_col'] as num?)?.toInt() ?? 0;
    final rowsList = (currentSheet['rows'] as List?) ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top Toolbar inside Excel View
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFA5D6A7)),
          ),
          child: Row(
            children: [
              Icon(_pp5CanEdit ? Icons.edit_note_rounded : Icons.lock_rounded, size: 18, color: const Color(0xFF1B5E20)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _pp5CanEdit
                      ? 'ตรวจสอบข้อมูลจากไฟล์ Excel จริง • แตะช่องสีเหลืองเพื่อพิมพ์ตัวชี้วัด (แผ่น 4) และหัวข้อคุณลักษณะ (แผ่น 5)'
                      : 'ตรวจสอบข้อมูลจากไฟล์ Excel จริง (อ่านอย่างเดียว • ตรวจสอบได้ครบทุกชีท แต่แก้ไขไม่ได้)',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: _openExcelFullScreen,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('เปิด Excel เต็มจอ'),
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: widget.onDownloadExcel,
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('ดาวน์โหลด Excel'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF107C41),
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _fetchExcelSheets,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'รีเฟรชข้อมูลแผ่นงาน',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // Sheet Selector Chips
        Wrap(
  runSpacing: 6,
  children: sheets.map((s) {
              final idx = s['index'] as int? ?? 0;
              final shortName = s['short_name']?.toString() ?? 'ชีท ${idx + 1}';
              final isSel = idx == _selectedExcelSheetIndex;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('${idx + 1}. $shortName'),
                  selected: isSel,
                  selectedColor: const Color(0xFFC8E6C9),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                    color: isSel ? const Color(0xFF1B5E20) : Colors.grey.shade800,
                  ),
                  avatar: isSel ? const Icon(Icons.check_circle_rounded, size: 16, color: Color(0xFF1B5E20)) : null,
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedExcelSheetIndex = idx;
                        _selectedCellCoord = null;
                        _selectedCellValue = null;
                      });
                    }
                  },
                ),
              );
            }).toList(),
),

        const SizedBox(height: 6),

        // Formula / Cell Inspector Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade400),
                ),
                child: Text(
                  _selectedCellCoord ?? 'A1',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace', fontSize: 12, color: Color(0xFF107C41)),
                ),
              ),
              const SizedBox(width: 8),
              const Text('fx', style: TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Text(
                    _selectedCellValue ?? '(คลิกที่เซลล์ในตารางเพื่อตรวจสอบค่า)',
                    style: TextStyle(fontSize: 12, color: _selectedCellValue != null ? Colors.black87 : Colors.grey.shade500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${currentSheet['sheet_name']} • $maxRows แถว × $maxCols คอลัมน์',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        // Spreadsheet Grid Viewer
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Scrollbar(
                controller: _excelVScrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _excelVScrollController,
                  scrollDirection: Axis.vertical,
                  child: Scrollbar(
                    controller: _excelHScrollController,
                    notificationPredicate: (notif) => notif.depth == 1,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _excelHScrollController,
                      scrollDirection: Axis.horizontal,
                      child: _buildExcelGridTable(currentSheet, maxRows, maxCols, rowsList),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExcelGridTable(Map<String, dynamic> sheet, int maxRows, int maxCols, List rowsList) {
    // Header Row with column letters
    final headerCells = <Widget>[
      Container(
        width: 44,
        height: 26,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.grid_on_rounded, size: 12, color: Colors.grey),
      ),
    ];

    for (int c = 1; c <= maxCols; c++) {
      headerCells.add(
        Container(
          width: 85,
          height: 26,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            border: Border(
              right: BorderSide(color: Colors.grey.shade300),
              bottom: BorderSide(color: Colors.grey.shade400, width: 1.5),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            _colLetter(c),
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
          ),
        ),
      );
    }

    final tableRows = <Widget>[
      Row(children: headerCells),
    ];

    for (int r = 0; r < rowsList.length && r < maxRows; r++) {
      final rowData = (rowsList[r] as List?) ?? [];
      final isLogoRow = _selectedExcelSheetIndex == 0 && r == 1;
      final rowH = isLogoRow ? 72.0 : _excelRowHeight(rowData);
      final rowCells = <Widget>[
        Container(
          width: 44,
          height: rowH,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            border: Border(
              right: BorderSide(color: Colors.grey.shade400, width: 1.5),
              bottom: BorderSide(color: Colors.grey.shade300),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '${r + 1}',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey.shade700),
          ),
        ),
      ];

      for (int c = 0; c < maxCols; c++) {
        final cell = (c < rowData.length) ? (rowData[c] as Map<String, dynamic>?) : null;
        if (cell != null && cell['c'] == true) {
          continue; // Covered by merge
        }

        final isLogo = cell?['is_logo'] == true;
        final val = cell?['v']?.toString() ?? '';
        final cs = (cell?['cs'] as num?)?.toInt() ?? 1;
        final rs = (cell?['rs'] as num?)?.toInt() ?? 1;
        final isBold = cell?['b'] == true;
        final alignStr = cell?['a']?.toString() ?? 'left';
        final textAlign = alignStr == 'center' ? TextAlign.center : (alignStr == 'right' ? TextAlign.right : TextAlign.left);
        final alignment = alignStr == 'center' ? Alignment.center : (alignStr == 'right' ? Alignment.centerRight : Alignment.centerLeft);

        final cellCoord = '${_colLetter(c + 1)}${r + 1}';
        final isSelected = _selectedCellCoord == cellCoord;
        final rotated = cell?['rot'] == 90 && val.isNotEmpty;
        // ตัวชี้วัด (sheet 4) / คุณลักษณะ item names (sheet 5): yellow cells the teacher of the course can type into
        final String? lab = _pp5CanEdit ? (cell?['lab']?.toString()) : null;
        final textStyle = TextStyle(
          fontSize: 11,
          fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? const Color(0xFF107C41) : Colors.black87,
        );

        rowCells.add(
          InkWell(
            onTap: () {
              setState(() {
                _selectedCellCoord = cellCoord;
                _selectedCellValue = isLogo ? '[ตราโรงเรียน]' : val;
              });
              if (lab != null) _editPp5Label(lab);
            },
            child: Container(
              width: 85.0 * cs,
              height: rowH,
              padding: isLogo ? const EdgeInsets.all(4) : const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFFE8F5E9)
                    : (lab != null ? const Color(0xFFFFF9C4) : (r % 2 == 1 ? Colors.grey.shade50 : Colors.white)),
                border: Border(
                  right: BorderSide(color: isSelected ? const Color(0xFF107C41) : Colors.grey.shade300, width: isSelected ? 1.5 : 1),
                  bottom: BorderSide(color: isSelected ? const Color(0xFF107C41) : Colors.grey.shade300, width: isSelected ? 1.5 : 1),
                  top: isSelected ? const BorderSide(color: Color(0xFF107C41), width: 1.5) : BorderSide.none,
                  left: isSelected ? const BorderSide(color: Color(0xFF107C41), width: 1.5) : BorderSide.none,
                ),
              ),
              alignment: isLogo || rotated || lab != null ? Alignment.center : alignment,
              child: isLogo
                  ? Image.network(
                      widget.apiService.getSchoolLogoUrl(),
                      height: 64,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox(),
                    )
                  : rotated
                      // written upwards, as in the Excel file and the PDF
                      ? RotatedBox(
                          quarterTurns: 3,
                          child: Text(val, maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle),
                        )
                      : (lab != null && val.isEmpty)
                          ? Tooltip(
                              message: 'แตะเพื่อพิมพ์ตัวชี้วัด',
                              child: Icon(Icons.edit_note_rounded, size: 18, color: Colors.brown.shade300),
                            )
                          : Text(
                              val,
                              textAlign: textAlign,
                              maxLines: rs,
                              overflow: TextOverflow.ellipsis,
                              style: textStyle,
                            ),
            ),
          ),
        );
      }

      tableRows.add(Row(children: rowCells));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: tableRows,
    );
  }


  Widget _buildScoresView(ThemeData theme) {



    if (_loading) {



      return const Center(



        child: Column(



          mainAxisSize: MainAxisSize.min,



          children: [



            CircularProgressIndicator(),



            SizedBox(height: 16),



            Text('กำลังตรวจสอบข้อมูลหน้าปกและผลการเรียน ปพ.5...'),



          ],



        ),



      );



    }







    if (_error != null) {



      return Center(



        child: Column(



          mainAxisSize: MainAxisSize.min,



          children: [



            const Icon(Icons.error_outline, size: 48, color: Colors.red),



            const SizedBox(height: 12),



            Text(_error!, style: const TextStyle(color: Colors.red)),



            const SizedBox(height: 16),



            FilledButton.icon(



              onPressed: _fetchPreview,



              icon: const Icon(Icons.refresh),



              label: const Text('ลองใหม่อีกครั้ง'),



            ),



          ],



        ),



      );



    }







    final data = _preview;



    final students = (data?['students'] as List?) ?? [];



    final gradeDist = (data?['grade_distribution'] as Map<String, dynamic>?) ?? {};



    final advisors = (data?['advisors'] as List?)?.map((e) => e.toString()).toList() ?? [];



    final classLevel = data?['class_level'] ?? '';



    final totalStudents = data?['total_students'] ?? students.length;







    return SingleChildScrollView(



      child: Column(



        crossAxisAlignment: CrossAxisAlignment.start,



        children: [



          // Card 1: Cover Sheet Verification



          Card(



            elevation: 0,



            color: Colors.blue.shade50.withValues(alpha: 0.5),



            shape: RoundedRectangleBorder(



              borderRadius: BorderRadius.circular(12),



              side: BorderSide(color: Colors.blue.shade200),



            ),



            child: Padding(



              padding: const EdgeInsets.all(14),



              child: Column(



                crossAxisAlignment: CrossAxisAlignment.start,



                children: [



                  Row(



                    children: [



                      Icon(Icons.assignment_rounded, color: Colors.blue.shade800, size: 20),



                      const SizedBox(width: 8),



                      Text(



                        'ข้อมูลหน้าปก ปพ.5 ที่จะพิมพ์และบันทึก',



                        style: TextStyle(



                          fontWeight: FontWeight.bold,



                          fontSize: 14,



                          color: Colors.blue.shade900,



                        ),



                      ),



                      const Spacer(),



                      Container(



                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),



                        decoration: BoxDecoration(



                          color: Colors.blue.shade700,



                          borderRadius: BorderRadius.circular(6),



                        ),



                        child: Text(



                          'ระดับชั้น: ${classLevel.isNotEmpty ? classLevel : "-"}',



                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),



                        ),



                      ),



                    ],



                  ),



                  const Divider(height: 18),



                  // Teacher Row



                  Row(



                    children: [



                      const Icon(Icons.person, size: 18, color: AppColors.purplePrimary),



                      const SizedBox(width: 8),



                      const Text('ครูผู้สอน (ช่อง E11): ', style: TextStyle(fontWeight: FontWeight.w600)),



                      Expanded(



                        child: Text(



                          _teacher != null && _teacher!.isNotEmpty ? _teacher! : 'ยังไม่ระบุ',



                          style: TextStyle(



                            fontWeight: FontWeight.bold,



                            fontSize: 14,



                            color: AppColors.purpleDark,



                          ),



                        ),



                      ),



                      if (widget.apiService.isAdmin)



                        OutlinedButton.icon(



                          onPressed: _editTeacherName,



                        icon: const Icon(Icons.edit, size: 14),



                        label: const Text('เปลี่ยนชื่อครู'),



                        style: OutlinedButton.styleFrom(



                          visualDensity: VisualDensity.compact,



                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),



                        ),



                      ),



                    ],



                  ),



                  const SizedBox(height: 8),



                  // Advisors Row



                  Row(



                    children: [



                      const Icon(Icons.people_alt, size: 18, color: Colors.deepPurple),



                      const SizedBox(width: 8),



                      const Text(



                        'ครูที่ปรึกษา/ประจำชั้น (ช่อง E12/E13): ',



                        style: TextStyle(fontWeight: FontWeight.w600),



                      ),



                      Expanded(



                        child: Text(



                          advisors.isNotEmpty ? advisors.join(', ') : 'ยังไม่ระบุครูที่ปรึกษา',



                          style: TextStyle(



                            fontWeight: FontWeight.bold,



                            fontSize: 13,



                            color: advisors.isNotEmpty ? Colors.deepPurple.shade900 : Colors.amber.shade900,



                          ),



                        ),



                      ),



                      OutlinedButton.icon(



                        onPressed: () {



                          widget.onOpenAdvisorsDialog();



                          Navigator.of(context).pop();



                        },



                        icon: const Icon(Icons.edit, size: 14),



                        label: const Text('แก้ไขครูที่ปรึกษา'),



                        style: OutlinedButton.styleFrom(



                          visualDensity: VisualDensity.compact,



                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),



                        ),



                      ),



                    ],



                  ),



                ],



              ),



            ),



          ),



          const SizedBox(height: 14),







          // Card 2: Grade Distribution Badges



          Text(



            'สรุปการประเมินผลการเรียน (ทั้งหมด $totalStudents คน):',



            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),



          ),



          const SizedBox(height: 8),



          Wrap(



            spacing: 8,



            runSpacing: 8,



            children: [



              _buildGradeBadge('4', gradeDist['4'] ?? 0, Colors.green.shade800),



              _buildGradeBadge('3.5', gradeDist['3.5'] ?? 0, Colors.green.shade700),



              _buildGradeBadge('3', gradeDist['3'] ?? 0, Colors.teal.shade700),



              _buildGradeBadge('2.5', gradeDist['2.5'] ?? 0, Colors.blue.shade700),



              _buildGradeBadge('2', gradeDist['2'] ?? 0, Colors.amber.shade800),



              _buildGradeBadge('1.5', gradeDist['1.5'] ?? 0, Colors.orange.shade700),



              _buildGradeBadge('1', gradeDist['1'] ?? 0, Colors.orange.shade900),



              _buildGradeBadge('0', gradeDist['0'] ?? 0, Colors.red.shade700),



              _buildGradeBadge('ร', gradeDist['ร'] ?? 0, Colors.purple.shade700),



              _buildGradeBadge('มส', gradeDist['มส'] ?? 0, Colors.deepOrange.shade900),



            ],



          ),



          const SizedBox(height: 16),







          // Card 3: Student Roster Inspection Table



          Row(



            children: [



              const Icon(Icons.people_alt_outlined, size: 18),



              const SizedBox(width: 8),



              Text(



                'รายชื่อนักเรียนและคะแนน ($totalStudents คน)',



                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),



              ),



              const Spacer(),



              Text(



                'ตรวจสอบคะแนนและเกรดก่อนพิมพ์',



                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),



              ),



            ],



          ),



          const SizedBox(height: 8),



          Container(



            constraints: const BoxConstraints(maxHeight: 250),



            decoration: BoxDecoration(



              border: Border.all(color: Colors.grey.shade300),



              borderRadius: BorderRadius.circular(8),



            ),



            child: SingleChildScrollView(



              scrollDirection: Axis.vertical,



              child: SingleChildScrollView(



                scrollDirection: Axis.horizontal,



                child: DataTable(



                  headingRowHeight: 38,



                  dataRowMinHeight: 34,



                  dataRowMaxHeight: 36,



                  headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),



                  columns: const [



                    DataColumn(label: Text('ที่', style: TextStyle(fontWeight: FontWeight.bold))),



                    DataColumn(label: Text('รหัสนักเรียน', style: TextStyle(fontWeight: FontWeight.bold))),



                    DataColumn(label: Text('ชื่อ - นามสกุล', style: TextStyle(fontWeight: FontWeight.bold))),



                    DataColumn(label: Text('คะแนนรวม', style: TextStyle(fontWeight: FontWeight.bold))),



                    DataColumn(label: Text('เกรด', style: TextStyle(fontWeight: FontWeight.bold))),



                    DataColumn(label: Text('เวลาเรียน (%)', style: TextStyle(fontWeight: FontWeight.bold))),



                  ],



                  rows: students.map((s) {



                    final no = s['student_no'] ?? '-';



                    final id = s['student_id'] ?? '-';



                    final name = s['full_name'] ?? '-';



                    final total = s['total_score'] ?? '-';



                    final grade = s['final_grade'] ?? '-';



                    final attPct = s['attendance_percentage'];



                    final attStr = attPct != null ? '$attPct%' : '-';







                    return DataRow(



                      cells: [



                        DataCell(Text('$no')),



                        DataCell(Text('$id')),



                        DataCell(Text('$name')),



                        DataCell(Text('$total', style: const TextStyle(fontWeight: FontWeight.bold))),



                        DataCell(



                          Container(



                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),



                            decoration: BoxDecoration(



                              color: grade == '0' || grade == 'ร' || grade == 'มส'



                                  ? Colors.red.shade100



                                  : Colors.green.shade100,



                              borderRadius: BorderRadius.circular(4),



                            ),



                            child: Text(



                              '$grade',



                              style: TextStyle(



                                fontWeight: FontWeight.bold,



                                color: grade == '0' || grade == 'ร' || grade == 'มส'



                                    ? Colors.red.shade900



                                    : Colors.green.shade900,



                              ),



                            ),



                          ),



                        ),



                        DataCell(Text(attStr)),



                      ],



                    );



                  }).toList(),



                ),



              ),



            ),



          ),



        ],



      ),



    );



  }







  @override



  Widget build(BuildContext context) {



    final theme = Theme.of(context);



    final screenSize = MediaQuery.of(context).size;



    final dialogWidth = (screenSize.width * 0.94).clamp(950.0, 1220.0);



    final dialogHeight = (screenSize.height * 0.90).clamp(650.0, 880.0);



    final totalPdfPages = _pdfData?['total_pages'] ?? 7;







    return AlertDialog(



      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 16),



      titlePadding: const EdgeInsets.fromLTRB(24, 18, 16, 0),



      title: Column(



        crossAxisAlignment: CrossAxisAlignment.start,



        children: [



          Row(



            children: [



              Container(



                padding: const EdgeInsets.all(8),



                decoration: BoxDecoration(



                  color: (_viewMode == 'pdf' ? Colors.red : theme.colorScheme.primary).withValues(alpha: 0.1),



                  borderRadius: BorderRadius.circular(10),



                ),



                child: Icon(



                  _viewMode == 'pdf' ? Icons.picture_as_pdf_rounded : Icons.fact_check_rounded,



                  color: _viewMode == 'pdf' ? Colors.red.shade700 : theme.colorScheme.primary,



                  size: 26,



                ),



              ),



              const SizedBox(width: 12),



              Expanded(



                child: Column(



                  crossAxisAlignment: CrossAxisAlignment.start,



                  children: [



                    Text(



                      'ตรวจสอบความถูกต้อง ปพ.5: ${widget.course.courseCode} ${widget.course.courseName}',



                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),



                    ),



                    Text(



                      'ภาคเรียนที่ ${widget.course.term}/${widget.course.year} • ตรวจสอบหน้าเอกสาร PDF จริง ($totalPdfPages หน้า) ตรงกับ Excel',



                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),



                    ),



                  ],



                ),



              ),



              IconButton(



                onPressed: () => Navigator.of(context).pop(),



                icon: const Icon(Icons.close),



                tooltip: 'ปิด',



              ),



            ],



          ),



          const SizedBox(height: 12),



          // View Switcher Tabs



          Row(



            children: [



              SegmentedButton<String>(
                segments: [
                  ButtonSegment<String>(
                    value: 'pdf',
                    icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
                    label: Text(MediaQuery.sizeOf(context).width < 700 ? 'PDF ($totalPdfPages หน้า)' : 'หน้าเอกสาร PDF จริง (ครบทุก $totalPdfPages หน้า)'),
                  ),
                  ButtonSegment<String>(
                    value: 'excel',
                    icon: const Icon(Icons.table_view_rounded, size: 18),
                    label: Text(MediaQuery.sizeOf(context).width < 700 ? 'Excel (${_excelData?['total_sheets'] ?? 7} ชีท)' : 'หน้าเอกสาร Excel จริง (ครบทุก ${_excelData?['total_sheets'] ?? 7} ชีท)'),
                  ),
                  const ButtonSegment<String>(
                    value: 'scores',
                    icon: Icon(Icons.fact_check_rounded, size: 18),
                    label: Text('สรุปข้อมูล & รายชื่อนักเรียน'),
                  ),
                ],
                selected: {_viewMode},
                onSelectionChanged: (set) {
                  setState(() {
                    _viewMode = set.first;
                    if (_viewMode == 'pdf' && _pdfData == null && !_loadingPdf) {
                      _fetchPdfPages();
                    } else if (_viewMode == 'excel' && _excelData == null && !_loadingExcel) {
                      _fetchExcelSheets();
                    }
                  });
                },
              ),



            ],



          ),



        ],



      ),



      content: SizedBox(



        width: dialogWidth,



        height: dialogHeight,



        child: _viewMode == 'pdf' ? _buildPdfView(theme) : (_viewMode == 'excel' ? _buildExcelView(theme) : _buildScoresView(theme)),



      ),



      actionsPadding: const EdgeInsets.fromLTRB(20, 10, 20, 16),



      actions: [



        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [



            OutlinedButton(



              onPressed: () => Navigator.of(context).pop(),



              child: const Text('ปิดหน้าต่าง'),



            ),



            const SizedBox(width: 12),



            if (!widget.canManage)



              Container(



                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),



                decoration: BoxDecoration(



                  color: const Color(0xFFFFF8E1),



                  borderRadius: BorderRadius.circular(8),



                  border: Border.all(color: const Color(0xFFFFE082)),



                ),



                child: const Row(



                  mainAxisSize: MainAxisSize.min,



                  children: [



                    Icon(Icons.lock_outline_rounded, size: 16, color: Color(0xFFE65100)),



                    SizedBox(width: 6),



                    Text(



                      'โหมดดูตัวอย่าง (ท่านสามารถดาวน์โหลด/สั่งพิมพ์ได้เฉพาะวิชาที่ท่านสอน)',



                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFE65100)),



                    ),



                  ],



                ),



              )



            else ...[



              // Print PDF Button



              FilledButton.icon(



                onPressed: _triggerPrint,



                icon: const Icon(Icons.print_rounded, size: 20),



                label: const Text('🖨️ สั่งพิมพ์เอกสาร (Print ปพ.5)'),



                style: FilledButton.styleFrom(



                  backgroundColor: AppColors.purplePrimary,



                  foregroundColor: Colors.white,



                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),



                ),



              ),



              const SizedBox(width: 10),



              // Download PDF Button



              FilledButton.icon(



                onPressed: widget.onDownloadPdf,



                icon: const Icon(Icons.picture_as_pdf_rounded, size: 20),



                label: const Text('⬇️ ดาวน์โหลด PDF'),



                style: FilledButton.styleFrom(



                  backgroundColor: Colors.red.shade700,



                  foregroundColor: Colors.white,



                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),



                ),



              ),



              const SizedBox(width: 10),



              // Download Excel Button



              FilledButton.icon(



                onPressed: widget.onDownloadExcel,



                icon: const Icon(Icons.table_view_rounded, size: 20),



                label: const Text('⬇️ ดาวน์โหลด Excel'),



                style: FilledButton.styleFrom(



                  backgroundColor: Colors.teal.shade700,



                  foregroundColor: Colors.white,



                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),



                ),



              ),



            ],



          ],



        ),



      ],



    );



  }



}







// ===========================================================================



// Course archive table with frozen identity columns.



//



// ลำดับ / รหัสวิชา / ชื่อวิชา / ระดับชั้น stay pinned on the left so the user



// always knows which class a row belongs to while the remaining columns



// scroll horizontally. The header row stays pinned vertically. When the



// viewport is wide enough, every column fits on one page and the extra



// width is shared by the text-heavy columns instead of leaving dead space.



// ===========================================================================







class _ArchiveColumn {



  final String label;



  final double width;



  final double flex; // share of any surplus width



  final Alignment align;







  const _ArchiveColumn(



    this.label,



    this.width, {



    this.flex = 0,



    this.align = Alignment.centerLeft,



  });



}







class _CourseArchiveTable extends StatefulWidget {



  final List<Course> courses;



  final String Function(String courseCode) inferLevel;



  final List<String> Function(Course course) advisorsFor;



  final bool Function(Course course)? canManageCourse;



  final void Function(Course course) onEditDescription;



  final void Function(Course course) onAttendance;



  final void Function(Course course, String format) onOpenFile;



  final ApiService? apiService; // for the ไม่มีสิทธิ์สอบ (มส.) column



  const _CourseArchiveTable({



    required this.courses,



    required this.inferLevel,



    required this.advisorsFor,



    this.canManageCourse,



    required this.onEditDescription,



    required this.onAttendance,



    required this.onOpenFile,



    this.apiService,



  });



  @override



  State<_CourseArchiveTable> createState() => _CourseArchiveTableState();



}







class _CourseArchiveTableState extends State<_CourseArchiveTable> {



  static const double _rowHeight = 56;



  static const double _headerHeight = 44;



  static const double _cellPadding = 12;







  static const List<_ArchiveColumn> _frozenCols = [



    _ArchiveColumn('ลำดับ', 56, align: Alignment.center),



    _ArchiveColumn('รหัสวิชา', 92),



    _ArchiveColumn('ชื่อวิชา', 196, flex: 0.3),



    _ArchiveColumn('ระดับชั้น', 84, align: Alignment.center),



  ];







  static const List<_ArchiveColumn> _scrollCols = [



    _ArchiveColumn('ครูผู้สอน', 172, flex: 0.3),



    _ArchiveColumn('ครูที่ปรึกษา', 212, flex: 0.4),



    _ArchiveColumn('นักเรียน', 80, align: Alignment.centerRight),



    _ArchiveColumn('ไม่มีสิทธิ์สอบ', 118, align: Alignment.center),



    _ArchiveColumn('ตัวชี้วัด / เวลาเรียน', 132, align: Alignment.center),



    _ArchiveColumn('ดาวน์โหลด / สั่งพิมพ์ ปพ.5', 300),



  ];







  final ScrollController _hCtrl = ScrollController();



  final ScrollController _vLeft = ScrollController();



  final ScrollController _vRight = ScrollController();



  final ValueNotifier<int?> _hoveredRow = ValueNotifier<int?>(null);



  bool _syncing = false;



  // "term|year|course_code" -> {count, allowed}: students ติด มส. per course and how many the teacher let sit



  final Map<String, Map<String, dynamic>> _ms = {};



  @override



  void initState() {



    super.initState();



    _vLeft.addListener(() => _syncVertical(_vLeft, _vRight));



    _vRight.addListener(() => _syncVertical(_vRight, _vLeft));



    _loadMs();



  }



  @override



  void didUpdateWidget(covariant _CourseArchiveTable oldWidget) {



    super.didUpdateWidget(oldWidget);



    if (oldWidget.courses != widget.courses) _loadMs();



  }



  /// One request per semester shown (normally one), never per row.



  Future<void> _loadMs() async {



    final api = widget.apiService;



    if (api == null || api.currentUser == null || api.currentUser!.isGuest) return;



    final semesters = {for (final c in widget.courses) '${c.term}|${c.year}'};



    for (final s in semesters) {



      final parts = s.split('|');



      try {



        final counts = await api.getNoExamRightCounts(parts[0], parts[1]);



        if (!mounted) return;



        setState(() {



          _ms.removeWhere((k, _) => k.startsWith('$s|'));



          for (final e in counts.entries) {



            _ms['$s|${e.key}'] = Map<String, dynamic>.from(e.value as Map);



          }



          _ms['$s|'] = const {}; // loaded



        });



      } catch (_) {}



    }



  }



  Widget _msCell(Course c) {



    final api = widget.apiService;



    final key = '${c.term}|${c.year}';



    if (api == null || !_ms.containsKey('$key|')) return const Text('-');



    final m = _ms['$key|${c.courseCode}'];



    final count = (m?['count'] as num?)?.toInt() ?? 0;



    final allowed = (m?['allowed'] as num?)?.toInt() ?? 0;



    final color = count == 0 ? Colors.grey.shade600 : const Color(0xFFB91C1C);



    return Tooltip(



      message: count == 0 ? 'ทุกคนมีสิทธิ์สอบ' : 'ติด มส. $count คน • ครูอนุญาตให้สอบ $allowed คน — กดเพื่อดู / ติ๊กอนุญาต',



      child: InkWell(



        borderRadius: BorderRadius.circular(8),



        onTap: () async {



          await NoExamRightDialog.show(context, api, c.courseCode, c.term, c.year);



          _loadMs();



        },



        child: Container(



          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),



          decoration: BoxDecoration(



            color: color.withValues(alpha: count == 0 ? 0.0 : 0.08),



            borderRadius: BorderRadius.circular(8),



            border: Border.all(color: color.withValues(alpha: 0.4)),



          ),



          child: Text(



            count == 0 ? '0 คน' : '$count คน${allowed > 0 ? ' (สอบได้ $allowed)' : ''}',



            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color),



          ),



        ),



      ),



    );



  }







  void _syncVertical(ScrollController from, ScrollController to) {



    if (_syncing || !from.hasClients || !to.hasClients) return;



    if ((to.offset - from.offset).abs() < 0.5) return;



    _syncing = true;



    to.jumpTo(from.offset.clamp(0.0, to.position.maxScrollExtent));



    _syncing = false;



  }







  @override



  void dispose() {



    _hCtrl.dispose();



    _vLeft.dispose();



    _vRight.dispose();



    _hoveredRow.dispose();



    super.dispose();



  }







  static double _sum(Iterable<double> xs) => xs.fold(0.0, (a, b) => a + b);







  @override



  Widget build(BuildContext context) {



    final theme = Theme.of(context);



    final cs = theme.colorScheme;







    return LayoutBuilder(builder: (context, box) {



      // Phones: slimmer pinned columns (course name still pinned) so the scrolling part keeps room
      final compactCols = box.maxWidth < 700;
      const compactFrozen = [28.0, 76.0, 92.0, 68.0];
      final frozenBase = compactCols ? compactFrozen : _frozenCols.map((c) => c.width).toList();
      final frozenMin = _sum(frozenBase);



      final scrollMin = _sum(_scrollCols.map((c) => c.width));



      final surplus = (box.maxWidth - frozenMin - scrollMin).clamp(0.0, double.infinity);



      final overflows = box.maxWidth < frozenMin + scrollMin;







      final frozenWidths = [for (int i = 0; i < _frozenCols.length; i++) frozenBase[i] + surplus * _frozenCols[i].flex];



      final scrollWidths = _scrollCols.map((c) => c.width + surplus * c.flex).toList();



      final frozenWidth = _sum(frozenWidths);



      final scrollWidth = _sum(scrollWidths);



      // Reserve room under the last row for the horizontal scrollbar thumb.



      final listPadding = EdgeInsets.only(bottom: overflows ? 14 : 0);







      return ScrollConfiguration(



        // Explicit scrollbars below; suppress the automatic per-list ones.



        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),



        child: Scrollbar(



          controller: _vRight,



          thumbVisibility: true,



          notificationPredicate: (n) => n.metrics.axis == Axis.vertical,



          child: Row(



            crossAxisAlignment: CrossAxisAlignment.stretch,



            children: [



              // ---------------- Frozen identity columns ----------------



              SizedBox(



                width: frozenWidth,



                child: Column(



                  children: [



                    _buildHeader(theme, _frozenCols, frozenWidths),



                    Expanded(



                      child: ListView.builder(



                        controller: _vLeft,



                        padding: listPadding,



                        itemExtent: _rowHeight,



                        itemCount: widget.courses.length,



                        itemBuilder: (ctx, i) => _buildRow(



                          theme,



                          i,



                          _frozenCols,



                          frozenWidths,



                          _frozenCells(theme, widget.courses[i], i),



                        ),



                      ),



                    ),



                  ],



                ),



              ),



              // Pinned-edge divider: a hairline at rest, a soft shadow once



              // content has scrolled underneath the frozen columns.



              Container(width: 1, color: cs.outlineVariant),



              // ---------------- Horizontally scrolling columns ----------------



              Expanded(



                child: Stack(



                  children: [



                    Positioned.fill(



                      child: Scrollbar(



                        controller: _hCtrl,



                        thumbVisibility: overflows,



                        child: SingleChildScrollView(



                          controller: _hCtrl,



                          scrollDirection: Axis.horizontal,



                          child: SizedBox(



                            width: scrollWidth,



                            child: Column(



                              children: [



                                _buildHeader(theme, _scrollCols, scrollWidths),



                                Expanded(



                                  child: ListView.builder(



                                    controller: _vRight,



                                    padding: listPadding,



                                    itemExtent: _rowHeight,



                                    itemCount: widget.courses.length,



                                    itemBuilder: (ctx, i) => _buildRow(



                                      theme,



                                      i,



                                      _scrollCols,



                                      scrollWidths,



                                      _scrollCells(theme, widget.courses[i]),



                                    ),



                                  ),



                                ),



                              ],



                            ),



                          ),



                        ),



                      ),



                    ),



                    Positioned(



                      left: 0,



                      top: 0,



                      bottom: 0,



                      width: 10,



                      child: IgnorePointer(



                        child: AnimatedBuilder(



                          animation: _hCtrl,



                          builder: (ctx, _) {



                            final scrolled = _hCtrl.hasClients && _hCtrl.offset > 1;



                            return AnimatedOpacity(



                              opacity: scrolled ? 1 : 0,



                              duration: const Duration(milliseconds: 150),



                              child: DecoratedBox(



                                decoration: BoxDecoration(



                                  gradient: LinearGradient(



                                    colors: [



                                      cs.shadow.withValues(alpha: 0.12),



                                      cs.shadow.withValues(alpha: 0.0),



                                    ],



                                  ),



                                ),



                              ),



                            );



                          },



                        ),



                      ),



                    ),



                  ],



                ),



              ),



            ],



          ),



        ),



      );



    });



  }







  Widget _buildHeader(ThemeData theme, List<_ArchiveColumn> cols, List<double> widths) {



    final cs = theme.colorScheme;



    return Container(



      height: _headerHeight,



      decoration: BoxDecoration(



        color: cs.surfaceContainerHigh,



        border: Border(bottom: BorderSide(color: cs.outlineVariant)),



      ),



      child: Row(



        children: [



          for (int k = 0; k < cols.length; k++)



            SizedBox(



              width: widths[k],



              child: Padding(



                padding: const EdgeInsets.symmetric(horizontal: _cellPadding),



                child: Align(



                  alignment: cols[k].align,



                  child: Text(



                    cols[k].label,



                    maxLines: 1,



                    overflow: TextOverflow.ellipsis,



                    style: theme.textTheme.labelLarge?.copyWith(



                      fontWeight: FontWeight.w700,



                      color: cs.onSurfaceVariant,



                      height: 1.4,



                    ),



                  ),



                ),



              ),



            ),



        ],



      ),



    );



  }







  Widget _buildRow(



    ThemeData theme,



    int index,



    List<_ArchiveColumn> cols,



    List<double> widths,



    List<Widget> cells,



  ) {



    final cs = theme.colorScheme;



    return MouseRegion(



      // onHover (not only onEnter) keeps the highlight correct when the



      // pointer crosses from the frozen half into the scrolling half.



      onHover: (_) {



        if (_hoveredRow.value != index) _hoveredRow.value = index;



      },



      onExit: (_) {



        if (_hoveredRow.value == index) _hoveredRow.value = null;



      },



      child: ValueListenableBuilder<int?>(



        valueListenable: _hoveredRow,



        builder: (ctx, hovered, child) {



          final Color bg;



          if (hovered == index) {



            bg = cs.primary.withValues(alpha: 0.07);



          } else if (index.isOdd) {



            bg = cs.onSurface.withValues(alpha: 0.025);



          } else {



            bg = Colors.transparent;



          }



          return DecoratedBox(



            decoration: BoxDecoration(



              color: bg,



              border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6))),



            ),



            child: child,



          );



        },



        child: Row(



          children: [



            for (int k = 0; k < cols.length; k++)



              SizedBox(



                width: widths[k],



                child: Padding(



                  padding: const EdgeInsets.symmetric(horizontal: _cellPadding),



                  child: Align(alignment: cols[k].align, child: cells[k]),



                ),



              ),



          ],



        ),



      ),



    );



  }







  List<Widget> _frozenCells(ThemeData theme, Course c, int index) {



    final cs = theme.colorScheme;



    final lvl = widget.inferLevel(c.courseCode);



    const tabular = [FontFeature.tabularFigures()];



    return [



      Text(



        '${index + 1}',



        style: TextStyle(color: cs.onSurfaceVariant, fontFeatures: tabular, height: 1.4),



      ),



      Text(



        c.courseCode,



        maxLines: 1,



        overflow: TextOverflow.ellipsis,



        style: TextStyle(



          fontWeight: FontWeight.w700,



          color: cs.primary,



          fontFeatures: tabular,



          height: 1.4,



        ),



      ),



      Tooltip(



        message: c.courseName,



        waitDuration: const Duration(milliseconds: 500),



        child: Text(



          c.courseName,



          maxLines: 2,



          overflow: TextOverflow.ellipsis,



          style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface, height: 1.4),



        ),



      ),



      Container(



        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),



        decoration: BoxDecoration(



          color: cs.secondaryContainer,



          borderRadius: BorderRadius.circular(6),



        ),



        child: Text(



          lvl.isNotEmpty ? lvl : '-',



          style: TextStyle(



            fontSize: 12.5,



            fontWeight: FontWeight.w700,



            color: cs.onSecondaryContainer,



            height: 1.5,



          ),



        ),



      ),



    ];



  }







  List<Widget> _scrollCells(ThemeData theme, Course c) {



    final cs = theme.colorScheme;



    final advisors = widget.advisorsFor(c);



    final hasDesc = c.courseDescription != null && c.courseDescription!.trim().isNotEmpty;



    final teacher = (c.teacher != null && c.teacher!.isNotEmpty) ? c.teacher! : '-';



    final advisorText = advisors.isNotEmpty ? advisors.join(', ') : '-';



    final canManage = widget.canManageCourse?.call(c) ?? true;







    return [



      Text(



        teacher,



        maxLines: 2,



        overflow: TextOverflow.ellipsis,



        style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface, height: 1.4),



      ),



      Tooltip(



        message: advisorText,



        waitDuration: const Duration(milliseconds: 500),



        child: Text(



          advisorText,



          maxLines: 2,



          overflow: TextOverflow.ellipsis,



          style: TextStyle(



            fontSize: 12.5,



            height: 1.4,



            color: advisors.isNotEmpty ? cs.onSurfaceVariant : cs.outline,



          ),



        ),



      ),



      Text(



        c.studentCount > 0 ? '${c.studentCount} คน' : '-',



        style: TextStyle(



          fontWeight: FontWeight.w700,



          color: cs.onSurface,



          fontFeatures: const [FontFeature.tabularFigures()],



          height: 1.4,



        ),



      ),



      _msCell(c),



      Row(



        mainAxisSize: MainAxisSize.min,



        children: [



          IconButton(



            onPressed: canManage ? () => widget.onEditDescription(c) : null,



            tooltip: canManage



                ? (hasDesc ? 'แก้ไขตัวชี้วัด (ใส่แล้ว)' : 'เพิ่มคำอธิบายรายวิชา/ตัวชี้วัด')



                : 'ล็อกการใช้งาน (เฉพาะผู้สอน  หรือผู้ดูแลระบบเท่านั้น)',



            icon: Icon(



              hasDesc ? Icons.check_circle_outline_rounded : Icons.edit_note_rounded,



              size: 20,



              color: canManage



                  ? (hasDesc ? _archiveSuccess(theme) : cs.onSurfaceVariant)



                  : cs.outline.withValues(alpha: 0.35),



            ),



          ),



          IconButton(



            onPressed: canManage ? () => widget.onAttendance(c) : null,



            tooltip: canManage



                ? 'สำรวจและแก้ไขเวลาเรียน'



                : 'ล็อกการใช้งาน (เฉพาะผู้สอน  หรือผู้ดูแลระบบเท่านั้น)',



            icon: Icon(



              Icons.how_to_reg_outlined,



              size: 20,



              color: canManage ? cs.primary : cs.outline.withValues(alpha: 0.35),



            ),



          ),



        ],



      ),



      Row(



        mainAxisSize: MainAxisSize.min,



        children: [



          _fileButton(



            theme,



            icon: Icons.table_view_outlined,



            iconColor: canManage ? _archiveExcel(theme) : cs.outline.withValues(alpha: 0.35),



            label: 'Excel',



            tooltip: canManage ? 'เปิด/ตรวจสอบไฟล์ Excel ปพ.5' : 'ล็อกการดาวน์โหลด (เฉพาะผู้สอน  หรือผู้ดูแลระบบเท่านั้น)',



            onPressed: canManage ? () => widget.onOpenFile(c, 'excel') : null,



          ),



          const SizedBox(width: 6),



          _fileButton(



            theme,



            icon: Icons.picture_as_pdf_outlined,



            iconColor: canManage ? _archivePdf(theme) : cs.outline.withValues(alpha: 0.35),



            label: 'PDF',



            tooltip: canManage ? 'เปิด/สั่งพิมพ์ไฟล์ PDF ปพ.5' : 'ล็อกการดาวน์โหลด (เฉพาะผู้สอน  หรือผู้ดูแลระบบเท่านั้น)',



            onPressed: canManage ? () => widget.onOpenFile(c, 'pdf') : null,



          ),



          const SizedBox(width: 6),



          _fileButton(



            theme,



            icon: Icons.fact_check_outlined,



            iconColor: cs.primary,



            label: 'ตรวจคะแนน',



            tooltip: 'ตรวจสอบคะแนนรายบุคคล',



            onPressed: () => widget.onOpenFile(c, 'preview'),



          ),



        ],



      ),



    ];



  }







  Widget _fileButton(
    ThemeData theme, {
    required IconData icon,
    required Color iconColor,
    required String label,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final bool disabled = onPressed == null;
    final bool isScoreCheck = label.contains('ตรวจคะแนน');

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: App3DButton(
        onPressed: onPressed,
        variant: disabled
            ? App3DButtonVariant.secondary
            : (isScoreCheck ? App3DButtonVariant.gold : App3DButtonVariant.secondary),
        depth: 2.5,
        borderRadius: 8,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: disabled
                  ? Colors.grey.shade400
                  : (isScoreCheck ? const Color(0xFF78350F) : iconColor),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Sarabun',
                fontSize: 12,
                fontWeight: FontWeight.bold,
                height: 1.3,
                color: disabled
                    ? Colors.grey.shade400
                    : (isScoreCheck ? const Color(0xFF451A03) : AppColors.purplePrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }

}
