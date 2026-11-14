import 'package:flutter/material.dart';
import '../services/api_service.dart';

class CourseCatalogCard extends StatefulWidget {
  final ApiService apiService;
  final VoidCallback? onCatalogChanged;

  const CourseCatalogCard({
    super.key,
    required this.apiService,
    this.onCatalogChanged,
  });

  @override
  State<CourseCatalogCard> createState() => _CourseCatalogCardState();
}

class _CourseCatalogCardState extends State<CourseCatalogCard> {
  List<Map<String, dynamic>> _allCourses = [];
  bool _loading = true;
  String? _error;

  // Filter states
  String _selectedTerm = 'all'; // 'all', '1', '2'
  String _selectedStage = 'all'; // 'all', '2', '3'
  String _selectedCourseType = 'all'; // 'all', 'พื้นฐาน', 'เพิ่มเติม', 'กิจกรรม'
  String _selectedPrefix = 'all'; // 'all', 'ท', 'ค', 'ว', 'ส', 'พ', 'ศ', 'ง', 'อ', 'จ', 'ก', 'I'
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  static const Map<String, String> kPrefixDepartments = {
    'ท': 'ภาษาไทย (ท)',
    'ค': 'คณิตศาสตร์ (ค)',
    'ว': 'วิทยาศาสตร์และเทคโนโลยี (ว)',
    'ส': 'สังคมศึกษา ศาสนา และวัฒนธรรม (ส)',
    'พ': 'สุขศึกษาและพลศึกษา (พ)',
    'ศ': 'ศิลปะศึกษาและดนตรีนาฏศิลป์ (ศ)',
    'ง': 'การงานอาชีพ (ง)',
    'อ': 'ภาษาต่างประเทศ - ภาษาอังกฤษ (อ)',
    'จ': 'ภาษาต่างประเทศ - ภาษาจีน (จ)',
    'ก': 'กิจกรรมพัฒนาผู้เรียน (ก)',
    'I': 'การศึกษาค้นคว้าอิสระ IS (I)',
  };

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.apiService.getCourseCatalog();
      if (mounted) {
        setState(() {
          _allCourses = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  /// Decode Thai MOE course code locally for instant UI preview
  static Map<String, String> decodeCourseCodeLocal(String rawCode) {
    final code = rawCode.trim();
    if (code.isEmpty) {
      return {
        'subject_prefix': '',
        'department': '-',
        'stage': '2',
        'class_level': 'ม.1',
        'course_type': 'พื้นฐาน',
        'term': '1',
      };
    }

    final firstChar = code[0].toUpperCase();
    const deptByPrefix = {
      'ท': 'ภาษาไทย',
      'ค': 'คณิตศาสตร์',
      'ว': 'วิทยาศาสตร์และเทคโนโลยี',
      'ส': 'สังคมศึกษา ศาสนา และวัฒนธรรม',
      'พ': 'สุขศึกษาและพลศึกษา',
      'ศ': 'ศิลปะศึกษาและดนตรีนาฏศิลป์',
      'ง': 'การงานอาชีพ',
      'อ': 'ภาษาต่างประเทศ (ภาษาอังกฤษ)',
      'จ': 'ภาษาต่างประเทศ (ภาษาจีน)',
      'ก': 'กิจกรรมพัฒนาผู้เรียน',
      'I': 'การศึกษาค้นคว้าอิสระ (IS)',
    };
    final dept = deptByPrefix[firstChar] ?? '-';

    final match = RegExp(r'^([ก-ฮA-Za-z])\s*(\d)(\d)(\d)(\d)(\d)').firstMatch(code);
    if (match == null) {
      return {
        'subject_prefix': firstChar,
        'department': dept,
        'stage': '2',
        'class_level': 'ม.1',
        'course_type': firstChar == 'ก' ? 'กิจกรรม' : 'พื้นฐาน',
        'term': '1',
      };
    }

    final d1 = match.group(2)!;
    final d2 = match.group(3)!;
    final d3 = match.group(4)!;
    final d5 = match.group(6)!;

    final stage = d1 == '3' ? '3' : '2';
    String classLevel = 'ม.1';
    if (d1 == '2') {
      if (d2 == '1') {
        classLevel = 'ม.1';
      } else if (d2 == '2' || d2 == '0') {
        classLevel = 'ม.2';
      } else if (d2 == '3') {
        classLevel = 'ม.3';
      }
    } else if (d1 == '3') {
      if (d2 == '1') {
        classLevel = 'ม.4';
      } else if (d2 == '2' || d2 == '0') {
        classLevel = 'ม.5';
      } else if (d2 == '3') {
        classLevel = 'ม.6';
      }
    }

    String courseType;
    if (firstChar == 'ก') {
      courseType = 'กิจกรรม';
    } else if (d3 == '2') {
      courseType = 'เพิ่มเติม';
    } else {
      courseType = 'พื้นฐาน';
    }

    final digit5 = int.tryParse(d5) ?? 1;
    final term = (digit5 % 2 == 1) ? '1' : '2';

    return {
      'subject_prefix': firstChar,
      'department': dept,
      'stage': stage,
      'class_level': classLevel,
      'course_type': courseType,
      'term': term,
    };
  }

  List<Map<String, dynamic>> get _filteredCourses {
    return _allCourses.where((c) {
      if (_selectedTerm != 'all' && (c['term']?.toString() ?? '') != _selectedTerm) {
        return false;
      }
      if (_selectedStage != 'all' && (c['stage']?.toString() ?? '') != _selectedStage) {
        return false;
      }
      if (_selectedCourseType != 'all' && (c['course_type']?.toString() ?? '') != _selectedCourseType) {
        return false;
      }
      if (_selectedPrefix != 'all' && (c['subject_prefix']?.toString() ?? '') != _selectedPrefix) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final code = (c['course_code']?.toString() ?? '').toLowerCase();
        final name = (c['course_name']?.toString() ?? '').toLowerCase();
        final dept = (c['department']?.toString() ?? '').toLowerCase();
        final lvl = (c['class_level']?.toString() ?? '').toLowerCase();
        if (!code.contains(q) && !name.contains(q) && !dept.contains(q) && !lvl.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Future<void> _openAddOrEditCourseDialog([Map<String, dynamic>? existing]) async {
    final isEditing = existing != null;
    final oldCode = existing?['course_code']?.toString();

    final codeCtrl = TextEditingController(text: existing?['course_code']?.toString() ?? '');
    final nameCtrl = TextEditingController(text: existing?['course_name']?.toString() ?? '');
    final creditsCtrl = TextEditingController(text: (existing?['credits'] ?? 1.0).toString());
    final ratioCtrl = TextEditingController(text: existing?['score_ratio']?.toString() ?? '70:30');
    final descCtrl = TextEditingController(text: existing?['course_description']?.toString() ?? '');

    var decoded = decodeCourseCodeLocal(codeCtrl.text);
    String term = existing?['term']?.toString() ?? (_selectedTerm != 'all' ? _selectedTerm : decoded['term']!);
    String stage = existing?['stage']?.toString() ?? decoded['stage']!;
    String classLevel = existing?['class_level']?.toString() ?? decoded['class_level']!;
    String courseType = existing?['course_type']?.toString() ?? decoded['course_type']!;
    String department = existing?['department']?.toString() ?? decoded['department']!;
    String subjectPrefix = existing?['subject_prefix']?.toString() ?? decoded['subject_prefix']!;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setModalState) {
            void onCodeChanged(String val) {
              final d = decodeCourseCodeLocal(val);
              setModalState(() {
                subjectPrefix = d['subject_prefix']!;
                department = d['department']!;
                stage = d['stage']!;
                classLevel = d['class_level']!;
                courseType = d['course_type']!;
                term = d['term']!;
              });
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(
                    isEditing ? Icons.edit_note_rounded : Icons.library_add_rounded,
                    color: const Color(0xFF1E3A8A),
                    size: 26,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isEditing
                          ? 'แก้ไขวิชาในคลังมาตรฐาน: ${existing['course_code']}'
                          : 'เพิ่มรายวิชาใหม่ในคลังมาตรฐาน',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 620,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Rule explanation banner
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFBFDBFE)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.auto_fix_high_rounded, size: 16, color: Color(0xFF1D4ED8)),
                                SizedBox(width: 6),
                                Text(
                                  'ระบบถอดรหัสวิชาอัตโนมัติตามหลักเกณฑ์:',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF1E3A8A)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '• ตัวอักษรหน้า = กลุ่มสาระ (ท, ค, ว, ส, พ, ศ, ง, อ, จ, ก) • หลักที่ 1 = ช่วงชั้น (2=ม.ต้น, 3=ม.ปลาย)\n'
                              '• หลักที่ 2 = ระดับชั้น (1=ม.1/ม.4, 2=ม.2/ม.5, 3=ม.3/ม.6) • หลักที่ 3 = ประเภท (1=พื้นฐาน, 2=เพิ่มเติม)\n'
                              '• หลักที่ 5 = ภาคเรียน (เลขคี่ 1,3,5=เทอม 1 / เลขคู่ 2,4,6=เทอม 2)',
                              style: TextStyle(fontSize: 11.5, color: Colors.blueGrey.shade800, height: 1.45),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Row 1: Course Code + Course Name
                      Row(
                        children: [
                          SizedBox(
                            width: 170,
                            child: TextField(
                              controller: codeCtrl,
                              decoration: const InputDecoration(
                                labelText: 'รหัสวิชา *',
                                hintText: 'เช่น ว33101',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: onCodeChanged,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: nameCtrl,
                              decoration: const InputDecoration(
                                labelText: 'ชื่อรายวิชามาตรฐาน * (ใช้อ้างอิงแทนข้อความเพี้ยนจาก SGS)',
                                hintText: 'เช่น โลกดาราศาสตร์พื้นฐาน',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Decoded badges preview + selectors
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          // Term selector
                          SizedBox(
                            width: 140,
                            child: DropdownButtonFormField<String>(
                              value: ['1', '2'].contains(term) ? term : '1',
                              decoration: const InputDecoration(
                                labelText: 'ภาคเรียน',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(value: '1', child: Text('ภาคเรียนที่ 1')),
                                DropdownMenuItem(value: '2', child: Text('ภาคเรียนที่ 2')),
                              ],
                              onChanged: (v) {
                                if (v != null) setModalState(() => term = v);
                              },
                            ),
                          ),
                          // Stage selector
                          SizedBox(
                            width: 175,
                            child: DropdownButtonFormField<String>(
                              value: ['2', '3'].contains(stage) ? stage : '2',
                              decoration: const InputDecoration(
                                labelText: 'ช่วงชั้น',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(value: '2', child: Text('ช่วงชั้นที่ 2 (ม.ต้น)')),
                                DropdownMenuItem(value: '3', child: Text('ช่วงชั้นที่ 3 (ม.ปลาย)')),
                              ],
                              onChanged: (v) {
                                if (v != null) setModalState(() => stage = v);
                              },
                            ),
                          ),
                          // Class Level selector
                          SizedBox(
                            width: 120,
                            child: DropdownButtonFormField<String>(
                              value: ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'].contains(classLevel)
                                  ? classLevel
                                  : 'ม.1',
                              decoration: const InputDecoration(
                                labelText: 'ระดับชั้น',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6']
                                  .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setModalState(() => classLevel = v);
                              },
                            ),
                          ),
                          // Course Type selector
                          SizedBox(
                            width: 145,
                            child: DropdownButtonFormField<String>(
                              value: ['พื้นฐาน', 'เพิ่มเติม', 'กิจกรรม'].contains(courseType)
                                  ? courseType
                                  : 'พื้นฐาน',
                              decoration: const InputDecoration(
                                labelText: 'ประเภทวิชา',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(value: 'พื้นฐาน', child: Text('วิชาพื้นฐาน')),
                                DropdownMenuItem(value: 'เพิ่มเติม', child: Text('วิชาเพิ่มเติม')),
                                DropdownMenuItem(value: 'กิจกรรม', child: Text('กิจกรรม')),
                              ],
                              onChanged: (v) {
                                if (v != null) setModalState(() => courseType = v);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Row 3: Department, Credits, Score Ratio
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'กลุ่มสาระการเรียนรู้ (จากตัวอักษรหน้า)',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              child: Text(
                                subjectPrefix == 'ก'
                                    ? 'กิจกรรมพัฒนาผู้เรียน (ไม่มีชื่อกลุ่มสาระนำหน้า)'
                                    : '$department ($subjectPrefix)',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 1,
                            child: TextField(
                              controller: creditsCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(
                                labelText: 'หน่วยกิต',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 1,
                            child: TextField(
                              controller: ratioCtrl,
                              decoration: const InputDecoration(
                                labelText: 'สัดส่วนคะแนน',
                                hintText: '70:30',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Course Description (คำอธิบายรายวิชา / ตัวชี้วัด)
                      const Text(
                        'คำอธิบายรายวิชา และ ตัวชี้วัด/ผลการเรียนรู้ (บันทึกไว้ใช้ซ้ำทุกปีการศึกษา แก้ไขได้ตลอดเวลา):',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: descCtrl,
                        maxLines: 7,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                        decoration: const InputDecoration(
                          hintText: 'วางหรือพิมพ์คำอธิบายรายวิชา และตัวชี้วัด/ผลการเรียนรู้สำหรับวิชานี้...\nเมื่อครูอัปโหลดไฟล์ SGS รหัสวิชานี้ ระบบจะดึงคำอธิบายรายวิชานี้ไปใส่ในแผ่นงาน (6) ตัวชี้วัด ให้อัตโนมัติ',
                          border: OutlineInputBorder(),
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
                if (widget.apiService.isAdmin)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1E3A8A),
                    ),
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: const Text('บันทึกลงคลังรายวิชามาตรฐาน'),
                    onPressed: () async {
                    final code = codeCtrl.text.trim();
                    final name = nameCtrl.text.trim();
                    if (code.isEmpty || name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('กรุณากรอกรหัสวิชาและชื่อรายวิชา')),
                      );
                      return;
                    }
                    Navigator.of(ctx).pop();
                    try {
                      final res = await widget.apiService.saveCatalogCourse({
                        'course_code': code,
                        'course_name': name,
                        'term': term,
                        'stage': stage,
                        'class_level': classLevel,
                        'course_type': courseType,
                        'department': department,
                        'subject_prefix': subjectPrefix,
                        'credits': double.tryParse(creditsCtrl.text.trim()) ?? 1.0,
                        'score_ratio': ratioCtrl.text.trim().isEmpty ? '70:30' : ratioCtrl.text.trim(),
                        'course_description': descCtrl.text.trim(),
                        if (isEditing && oldCode != null) 'old_course_code': oldCode,
                      });
                      await _loadCatalog();
                      widget.onCatalogChanged?.call();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: Colors.green.shade800,
                            content: Text(res['message'] ?? 'บันทึกรายวิชาเรียบร้อยแล้ว'),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: Colors.red.shade800,
                            content: Text('บันทึกไม่สำเร็จ: $e'),
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

  Future<void> _confirmDeleteCourse(Map<String, dynamic> course) async {
    final code = course['course_code']?.toString() ?? '';
    final name = course['course_name']?.toString() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text('ยืนยันการลบรายวิชาจากคลังมาตรฐาน'),
          ],
        ),
        content: Text('คุณต้องการลบวิชา "$code $name" ออกจากคลังรายวิชามาตรฐานใช่หรือไม่?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ลบรายวิชา'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final res = await widget.apiService.deleteCatalogCourse(code);
        await _loadCatalog();
        widget.onCatalogChanged?.call();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.green.shade800,
              content: Text(res['message'] ?? 'ลบรายวิชาเรียบร้อยแล้ว'),
            ),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filteredCourses;
    final term1Count = _allCourses.where((c) => c['term']?.toString() == '1').length;
    final term2Count = _allCourses.where((c) => c['term']?.toString() == '2').length;

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDBEAFE),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.menu_book_rounded, color: Color(0xFF1E3A8A), size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'คลังรายชื่อวิชามาตรฐาน (ภาคเรียนที่ 1 และ ภาคเรียนที่ 2)',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF0F172A),
                              ),
                            ),
                          ),
                          if (widget.apiService.isAdmin)
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF1E3A8A),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              ),
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: const Text('เพิ่มรายวิชาในคลัง (+)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                              onPressed: () => _openAddOrEditCourseDialog(),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ใช้เป็นฐานข้อมูลกลางอ้างอิงชื่อวิชาที่ถูกต้องเมื่อรหัสวิชาตรงกัน (ป้องกันสระ/วรรณยุกต์เพี้ยนจากไฟล์ SGS PDF) และเก็บคำอธิบายรายวิชาไว้ใช้ซ้ำทุกปีการศึกษา',
                        style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant, height: 1.45),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Summary chips & Filter bar
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: Term quick tabs + Search box
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('ภาคเรียน:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      _buildFilterChip(
                        label: 'รวมทั้งหมด (${_allCourses.length})',
                        selected: _selectedTerm == 'all',
                        onTap: () => setState(() => _selectedTerm = 'all'),
                      ),
                      _buildFilterChip(
                        label: 'รายชื่อวิชา ภาคเรียนที่ 1 ($term1Count)',
                        selected: _selectedTerm == '1',
                        onTap: () => setState(() => _selectedTerm = '1'),
                      ),
                      _buildFilterChip(
                        label: 'รายชื่อวิชา ภาคเรียนที่ 2 ($term2Count)',
                        selected: _selectedTerm == '2',
                        onTap: () => setState(() => _selectedTerm = '2'),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 250,
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: InputDecoration(
                            hintText: 'ค้นหารหัสวิชา หรือ ชื่อวิชา...',
                            prefixIcon: const Icon(Icons.search_rounded, size: 18),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear_rounded, size: 16),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _searchQuery = '');
                                    },
                                  )
                                : null,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          style: const TextStyle(fontSize: 13),
                          onChanged: (val) => setState(() => _searchQuery = val.trim()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Second row: Dropdown filters (กลุ่มสาระการเรียนรู้, วิชาพื้นฐาน/เพิ่มเติม, ช่วงชั้นที่ 2/3)
                  Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // 1. กลุ่มสาระการเรียนรู้
                      SizedBox(
                        width: 265,
                        child: DropdownButtonFormField<String>(
                          value: _selectedPrefix,
                          decoration: InputDecoration(
                            labelText: 'กลุ่มสาระการเรียนรู้',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          style: const TextStyle(fontSize: 12.5, color: Color(0xFF0F172A)),
                          items: [
                            const DropdownMenuItem(value: 'all', child: Text('ทุกกลุ่มสาระการเรียนรู้')),
                            ...kPrefixDepartments.entries.map(
                              (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                            ),
                          ],
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedPrefix = val);
                          },
                        ),
                      ),

                      // 2. ประเภทวิชา (พื้นฐาน / เพิ่มเติม / กิจกรรม)
                      SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<String>(
                          value: _selectedCourseType,
                          decoration: InputDecoration(
                            labelText: 'ประเภทวิชา',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          style: const TextStyle(fontSize: 12.5, color: Color(0xFF0F172A)),
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('ทุกประเภทวิชา')),
                            DropdownMenuItem(value: 'พื้นฐาน', child: Text('วิชาพื้นฐาน (หลักที่ 3 = 1)')),
                            DropdownMenuItem(value: 'เพิ่มเติม', child: Text('วิชาเพิ่มเติม (หลักที่ 3 = 2)')),
                            DropdownMenuItem(value: 'กิจกรรม', child: Text('กิจกรรมพัฒนาผู้เรียน (ก)')),
                          ],
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedCourseType = val);
                          },
                        ),
                      ),

                      // 3. ช่วงชั้น (ช่วงชั้นที่ 2 ม.ต้น / ช่วงชั้นที่ 3 ม.ปลาย)
                      SizedBox(
                        width: 220,
                        child: DropdownButtonFormField<String>(
                          value: _selectedStage,
                          decoration: InputDecoration(
                            labelText: 'ช่วงชั้น',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          style: const TextStyle(fontSize: 12.5, color: Color(0xFF0F172A)),
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('ทุกช่วงชั้น (ม.1–ม.6)')),
                            DropdownMenuItem(value: '2', child: Text('ช่วงชั้นที่ 2 (ม.ต้น ม.1–ม.3)')),
                            DropdownMenuItem(value: '3', child: Text('ช่วงชั้นที่ 3 (ม.ปลาย ม.4–ม.6)')),
                          ],
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedStage = val);
                          },
                        ),
                      ),

                      if (_selectedTerm != 'all' ||
                          _selectedStage != 'all' ||
                          _selectedCourseType != 'all' ||
                          _selectedPrefix != 'all' ||
                          _searchQuery.isNotEmpty)
                        TextButton.icon(
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() {
                              _selectedTerm = 'all';
                              _selectedStage = 'all';
                              _selectedCourseType = 'all';
                              _selectedPrefix = 'all';
                              _searchQuery = '';
                            });
                          },
                          icon: const Icon(Icons.filter_alt_off_rounded, size: 16),
                          label: const Text('ล้างตัวกรอง', style: TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Status count bar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'แสดง ${filtered.length} รายวิชา (จากทั้งหมด ${_allCourses.length} รายวิชาในคลัง)',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                ),
                TextButton.icon(
                  onPressed: _loadCatalog,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('รีเฟรชข้อมูล', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Course list table
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Text('เกิดข้อผิดพลาด: $_error', style: TextStyle(color: Colors.red.shade900)),
              )
            else if (filtered.isEmpty)
              Container(
                padding: const EdgeInsets.all(28),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: const Text('ไม่พบรายวิชาที่ตรงกับตัวกรอง'),
              )
            else
              Container(
                constraints: const BoxConstraints(maxHeight: 460),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFCBD5E1)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Column(
                    children: [
                      // Table Header
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        color: const Color(0xFFF1F5F9),
                        child: const Row(
                          children: [
                            SizedBox(width: 85, child: Text('รหัสวิชา', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            Expanded(flex: 3, child: Text('ชื่อรายวิชามาตรฐาน', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            SizedBox(width: 65, child: Text('เทอม', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            SizedBox(width: 65, child: Text('ชั้น', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            SizedBox(width: 85, child: Text('ประเภท', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            Expanded(flex: 2, child: Text('กลุ่มสาระการเรียนรู้', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            SizedBox(width: 120, child: Text('คำอธิบายรายวิชา', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            SizedBox(width: 88, child: Text('จัดการ', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: Color(0xFFCBD5E1)),
                      Expanded(
                        child: ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFE2E8F0)),
                          itemBuilder: (ctx, idx) {
                            final item = filtered[idx];
                            final code = item['course_code']?.toString() ?? '';
                            final name = item['course_name']?.toString() ?? '';
                            final term = item['term']?.toString() ?? '1';
                            final level = item['class_level']?.toString() ?? '';
                            final cType = item['course_type']?.toString() ?? 'พื้นฐาน';
                            final prefix = item['subject_prefix']?.toString() ?? '';
                            final dept = prefix == 'ก' ? '-' : (item['department']?.toString() ?? '-');
                            final desc = (item['course_description']?.toString() ?? '').trim();
                            final hasDesc = desc.isNotEmpty;

                            return InkWell(
                              onTap: () => _openAddOrEditCourseDialog(item),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                child: Row(
                                  children: [
                                    // Course Code
                                    SizedBox(
                                      width: 85,
                                      child: Text(
                                        code,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: Color(0xFF1E3A8A),
                                        ),
                                      ),
                                    ),
                                    // Course Name
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: Color(0xFF0F172A),
                                        ),
                                      ),
                                    ),
                                    // Term badge
                                    SizedBox(
                                      width: 65,
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: term == '1' ? const Color(0xFFDBEAFE) : const Color(0xFFFEF3C7),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            'เทอม $term',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: term == '1' ? const Color(0xFF1E40AF) : const Color(0xFF92400E),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Class Level
                                    SizedBox(
                                      width: 65,
                                      child: Text(
                                        level,
                                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    // Course Type badge
                                    SizedBox(
                                      width: 85,
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: cType == 'พื้นฐาน'
                                                ? const Color(0xFFDCFCE7)
                                                : cType == 'เพิ่มเติม'
                                                    ? const Color(0xFFF3E8FF)
                                                    : const Color(0xFFE0F2FE),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            cType,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: cType == 'พื้นฐาน'
                                                  ? const Color(0xFF166534)
                                                  : cType == 'เพิ่มเติม'
                                                      ? const Color(0xFF6B21A8)
                                                      : const Color(0xFF0369A1),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Department
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        dept,
                                        style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    // Course Description status
                                    SizedBox(
                                      width: 120,
                                      child: InkWell(
                                        onTap: () => _openAddOrEditCourseDialog(item),
                                        borderRadius: BorderRadius.circular(6),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: hasDesc ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(
                                              color: hasDesc ? const Color(0xFF6EE7B7) : const Color(0xFFCBD5E1),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                hasDesc ? Icons.check_circle_rounded : Icons.note_add_outlined,
                                                size: 13,
                                                color: hasDesc ? const Color(0xFF059669) : const Color(0xFF64748B),
                                              ),
                                              const SizedBox(width: 4),
                                              Flexible(
                                                child: Text(
                                                  hasDesc ? 'มีคำอธิบายแล้ว' : '+ เพิ่มคำอธิบาย',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: hasDesc ? FontWeight.w600 : FontWeight.normal,
                                                    color: hasDesc ? const Color(0xFF065F46) : const Color(0xFF64748B),
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Actions: Edit & Delete (Admin only)
                                    if (widget.apiService.isAdmin)
                                      SizedBox(
                                        width: 88,
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.end,
                                          children: [
                                            IconButton(
                                              icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF1E3A8A)),
                                              tooltip: 'แก้ไขชื่อวิชา / คำอธิบายรายวิชา',
                                              visualDensity: VisualDensity.compact,
                                              onPressed: () => _openAddOrEditCourseDialog(item),
                                            ),
                                            IconButton(
                                              icon: Icon(Icons.remove_circle_outline_rounded, size: 18, color: Colors.red.shade600),
                                              tooltip: 'ลบรายวิชาออกจากคลัง (-)',
                                              visualDensity: VisualDensity.compact,
                                              onPressed: () => _confirmDeleteCourse(item),
                                            ),
                                          ],
                                        ),
                                      )
                                    else
                                      const SizedBox(width: 8),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1E3A8A) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF1E3A8A) : const Color(0xFFCBD5E1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF334155),
          ),
        ),
      ),
    );
  }
}
