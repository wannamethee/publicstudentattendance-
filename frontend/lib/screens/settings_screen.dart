import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';

import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

import '../models/semester_config.dart';

import '../models/class_advisor.dart';

import '../widgets/teacher_courses_dialog.dart';

import '../widgets/course_catalog_card.dart';



import '../widgets/school_import_card.dart';
import '../widgets/archive_backup_card.dart';
import '../widgets/public_api_card.dart';
import '../models/school_theme_config.dart';

import '../widgets/app_3d_button.dart';
import '../utils/app_theme.dart';



class SettingsScreen extends StatefulWidget {

  final ApiService apiService;

  final VoidCallback? onSettingsChanged;



  const SettingsScreen({

    super.key,

    required this.apiService,

    this.onSettingsChanged,

  });



  @override

  State<SettingsScreen> createState() => _SettingsScreenState();

}



class _SettingsScreenState extends State<SettingsScreen> {

  late TextEditingController _urlController;

  bool _isConnected = false;

  bool _checking = false;



  List<SemesterConfigItem> _semesterConfigs = [];

  bool _loadingSemesters = true;

  String? _semestersError;



  List<ClassAdvisorItem> _classAdvisors = [];

  bool _loadingAdvisors = false;

  String? _advisorsError;

  String _selectedAdvisorSemesterKey = '2-2568';



  // ===========================================================================

  // SCHOOL SIGNATORIES STATE

  // ===========================================================================

  String _selectedSignatoryYear = '2569';

  List<String> _availableSignatoryYears = ['2570', '2569', '2568', '2567'];

  bool _loadingSignatories = false;

  bool _savingSignatories = false;

  String? _signatoriesError;

  bool _syncExistingSignatoryFiles = true;

  bool _expandDeptHeads = false;

  bool _hasSchoolLogo = false;

  bool _uploadingLogo = false;
  bool _hasCustomPp5Logo = false;
  bool _uploadingPp5Logo = false;

  bool _savingSchoolName = false;
  bool _savingWebTitle = false;

  // School Theme & Appearance State
  SchoolThemeConfig _customThemeConfig = SchoolThemeConfig.defaultTheme;
  bool _isLoadingTheme = false;
  bool _isSavingTheme = false;
  final TextEditingController _menuColorHexCtrl = TextEditingController(text: '#24114F');
  final TextEditingController _bodyColorHexCtrl = TextEditingController(text: '#F7ECC2');
  final TextEditingController _primaryColorHexCtrl = TextEditingController(text: '#351C75');
  final TextEditingController _secondaryColorHexCtrl = TextEditingController(text: '#D4AF37');

  final TextEditingController _webTitleCtrl = TextEditingController(text: '');



  final TextEditingController _schoolNameCtrl = TextEditingController(text: '');

  final TextEditingController _sidebarFooterTitleCtrl = TextEditingController(text: 'ระบบงาน ปพ.5 & ทะเบียนวัดผล');

  final TextEditingController _sidebarFooterSubtitleCtrl = TextEditingController(text: '');

  final TextEditingController _directorNameCtrl = TextEditingController();

  final TextEditingController _directorTitleCtrl = TextEditingController(text: '');

  final TextEditingController _academicNameCtrl = TextEditingController();

  final TextEditingController _academicTitleCtrl = TextEditingController(text: 'หัวหน้างานวิชาการ');

  final TextEditingController _registrarNameCtrl = TextEditingController();

  final TextEditingController _registrarTitleCtrl = TextEditingController(text: 'งานทะเบียน-วัดผล');

  final TextEditingController _deptHeadDefaultCtrl = TextEditingController();

  final Map<String, TextEditingController> _deptHeadsCtrls = {};

  List<String> _schoolTeachersList = [];

  List<Map<String, dynamic>> _teachersWithCode = [];

  bool _loadingTeachers = false;

  String _teacherSearchQuery = '';



  // System Admins State (max 3)

  List<Map<String, dynamic>> _systemAdmins = [];

  bool _loadingAdmins = false;



  // Course Import state

  String _importTerm = '2';

  String _importYear = '2569';

  bool _importGenerateExcel = true;

  bool _importingCourses = false;

  Map<String, dynamic>? _lastCourseImportResult;



  static const List<String> kStandardDepartments = [

    'ภาษาไทย',

    'คณิตศาสตร์',

    'วิทยาศาสตร์และเทคโนโลยี',

    'สังคมศึกษา ศาสนา และวัฒนธรรม',

    'สุขศึกษาและพลศึกษา',

    'ศิลปะ',

    'การงานอาชีพ',

    'ภาษาต่างประเทศ',

    'กิจกรรมพัฒนาผู้เรียน',

  ];



  @override

  void initState() {

    super.initState();

    for (final dept in kStandardDepartments) {

      _deptHeadsCtrls[dept] = TextEditingController();

    }

    _urlController = TextEditingController(text: widget.apiService.baseUrl);

    _checkConnection();

    _loadSemesterConfigs();

    _loadSignatories(year: _selectedSignatoryYear);

    _loadSchoolTeachers();

    _loadSchoolLogoInfo();

    _loadSystemAdmins();
    _loadBackups();
    _loadSchoolThemeConfig();

  }



  @override

  void dispose() {

    _urlController.dispose();

    _schoolNameCtrl.dispose();
    _webTitleCtrl.dispose();
    _menuColorHexCtrl.dispose();
    _bodyColorHexCtrl.dispose();
    _primaryColorHexCtrl.dispose();
    _secondaryColorHexCtrl.dispose();

    _sidebarFooterTitleCtrl.dispose();

    _sidebarFooterSubtitleCtrl.dispose();

    _directorNameCtrl.dispose();

    _directorTitleCtrl.dispose();

    _academicNameCtrl.dispose();

    _academicTitleCtrl.dispose();

    _registrarNameCtrl.dispose();

    _registrarTitleCtrl.dispose();

    _deptHeadDefaultCtrl.dispose();

    for (final ctrl in _deptHeadsCtrls.values) {

      ctrl.dispose();

    }

    super.dispose();

  }



  Future<void> _checkConnection() async {

    setState(() => _checking = true);

    final connected = await widget.apiService.checkHealth();

    if (mounted) {

      setState(() {

        _isConnected = connected;

        _checking = false;

      });

    }

  }



  void _updateUrl() {

    final newUrl = _urlController.text.trim();

    if (newUrl.isNotEmpty) {

      widget.apiService.baseUrl = newUrl;

      _checkConnection();

      _loadSemesterConfigs();

    }

  }



  Future<void> _loadSemesterConfigs() async {

    setState(() {

      _loadingSemesters = true;

      _semestersError = null;

    });



    try {

      final list = await widget.apiService.getSemesterConfigs();

      if (mounted) {

        setState(() {

          _semesterConfigs = list;

          _loadingSemesters = false;



          if (list.isNotEmpty && !list.any((c) => '${c.term}-${c.year}' == _selectedAdvisorSemesterKey)) {

            _selectedAdvisorSemesterKey = '${list.first.term}-${list.first.year}';

          }

        });

        _loadClassAdvisors();

      }

    } catch (e) {

      if (mounted) {

        setState(() {

          _semestersError = e.toString().replaceFirst('Exception: ', '');

          _loadingSemesters = false;

        });

      }

    }

  }



  Future<void> _loadClassAdvisors() async {

    final parts = _selectedAdvisorSemesterKey.split('-');

    if (parts.length != 2) return;

    setState(() {

      _loadingAdvisors = true;

      _advisorsError = null;

    });

    try {

      final list = await widget.apiService.getClassAdvisors(

        term: parts[0],

        year: parts[1],

      );

      if (mounted) {

        setState(() {

          _classAdvisors = list;

          _loadingAdvisors = false;

        });

      }

    } catch (e) {

      if (mounted) {

        setState(() {

          _advisorsError = e.toString().replaceFirst('Exception: ', '');

          _loadingAdvisors = false;

        });

      }

    }

  }



  Future<void> _openAdvisorEditDialog([ClassAdvisorItem? existing]) async {

    final parts = _selectedAdvisorSemesterKey.split('-');

    final currentTerm = parts[0];

    final currentYear = parts.length > 1 ? parts[1] : '2568';



    final isEditing = existing != null;

    final levelController = TextEditingController(text: existing?.classLevel ?? 'ม.1');

    final adv1Controller = TextEditingController(text: existing?.advisor1 ?? '');

    final adv2Controller = TextEditingController(text: existing?.advisor2 ?? '');

    final adv3Controller = TextEditingController(text: existing?.advisor3 ?? '');



    await showDialog(

      context: context,

      builder: (ctx) => AlertDialog(

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: Row(

          children: [

            Icon(

              isEditing ? Icons.edit_note_rounded : Icons.person_add_alt_1_rounded,

              color: Colors.teal.shade700,

            ),

            const SizedBox(width: 10),

            Text(

              isEditing ? 'แก้ไขครูที่ปรึกษา ${existing.classLevel}' : 'เพิ่มระดับชั้นและครูที่ปรึกษา',

              style: const TextStyle(fontWeight: FontWeight.bold),

            ),

          ],

        ),

        content: SingleChildScrollView(

          child: ConstrainedBox(

            constraints: const BoxConstraints(maxWidth: 450),

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

                  child: Text(

                    'ปีการศึกษา $currentYear ภาคเรียนที่ $currentTerm',

                    style: TextStyle(fontSize: 12, color: Colors.teal.shade900, fontWeight: FontWeight.bold),

                  ),

                ),

                const SizedBox(height: 14),

                TextField(

                  controller: levelController,

                  decoration: const InputDecoration(

                    labelText: 'ระดับชั้น (เช่น ม.1, ม.2, ม.3 หรือ ม.1/1)',

                    hintText: 'ม.1',

                    border: OutlineInputBorder(),

                    prefixIcon: Icon(Icons.school_rounded),

                  ),

                ),

                const SizedBox(height: 14),

                TextField(

                  controller: adv1Controller,

                  decoration: const InputDecoration(

                    labelText: 'ครูที่ปรึกษาคนที่ 1 (ระบุคำนำหน้าชื่อ-สกุล)',

                    hintText: 'นาย... หรือ นางสาว...',

                    border: OutlineInputBorder(),

                    prefixIcon: Icon(Icons.person_rounded),

                  ),

                ),

                const SizedBox(height: 14),

                TextField(

                  controller: adv2Controller,

                  decoration: const InputDecoration(

                    labelText: 'ครูที่ปรึกษาคนที่ 2 (ถ้ามี)',

                    border: OutlineInputBorder(),

                    prefixIcon: Icon(Icons.person_outline_rounded),

                  ),

                ),

                const SizedBox(height: 14),

                TextField(

                  controller: adv3Controller,

                  decoration: const InputDecoration(

                    labelText: 'ครูที่ปรึกษาคนที่ 3 (ถ้ามี)',

                    border: OutlineInputBorder(),

                    prefixIcon: Icon(Icons.person_add_alt_1_rounded),

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

          FilledButton(

            style: FilledButton.styleFrom(backgroundColor: Colors.teal.shade700),

            onPressed: () async {

              final lvl = levelController.text.trim();

              if (lvl.isEmpty) return;

              Navigator.of(ctx).pop();

              try {

                await widget.apiService.upsertClassAdvisor(

                  ClassAdvisorItem(

                    id: existing?.id ?? 0,

                    term: currentTerm,

                    year: currentYear,

                    classLevel: lvl,

                    advisor1: adv1Controller.text.trim(),

                    advisor2: adv2Controller.text.trim(),

                    advisor3: adv3Controller.text.trim(),

                  ),

                );

                _loadClassAdvisors();

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

      ),

    );

  }



  Future<void> _confirmDeleteAdvisor(ClassAdvisorItem item) async {

    final ok = await showDialog<bool>(

      context: context,

      builder: (ctx) => AlertDialog(

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: const Text('ยืนยันการลบ'),

        content: Text('ต้องการลบข้อมูลครูที่ปรึกษาของระดับชั้น "${item.classLevel}" หรือไม่?'),

        actions: [

          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('ยกเลิก')),

          FilledButton(

            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),

            onPressed: () => Navigator.of(ctx).pop(true),

            child: const Text('ลบข้อมูล'),

          ),

        ],

      ),

    );

    if (ok == true) {

      try {

        await widget.apiService.deleteClassAdvisor(item.id);

        _loadClassAdvisors();

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



  Future<void> _openCopyAdvisorsDialog() async {

    final parts = _selectedAdvisorSemesterKey.split('-');

    final currentTerm = parts[0];

    final currentYear = parts.length > 1 ? parts[1] : '2568';



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

      context: context,

      builder: (ctx) => StatefulBuilder(

        builder: (dCtx, setDState) => AlertDialog(

          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

          title: const Row(

            children: [

              Icon(Icons.copy_rounded, color: Colors.indigo),

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

                  if (val != null) setDState(() => selectedSource = val);

                },

              ),

            ],

          ),

          actions: [

            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('ยกเลิก')),

            FilledButton(

              style: FilledButton.styleFrom(backgroundColor: Colors.indigo.shade700),

              onPressed: () async {

                Navigator.of(ctx).pop();

                final srcParts = selectedSource.split('-');

                try {

                  final res = await widget.apiService.copyClassAdvisors(

                    fromTerm: srcParts[0],

                    fromYear: srcParts[1],

                    toTerm: currentTerm,

                    toYear: currentYear,

                  );

                  _loadClassAdvisors();

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



  Future<void> _openUploadAdvisorsDialog() async {

    final parts = _selectedAdvisorSemesterKey.split('-');

    final currentTerm = parts[0];

    final currentYear = parts.length > 1 ? parts[1] : '2568';



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

      context: context,

      builder: (ctx) => AlertDialog(

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: const Row(

          children: [

            Icon(Icons.upload_file_rounded, color: Colors.teal),

            SizedBox(width: 10),

            Text('ยืนยันการนำเข้าไฟล์รายชื่อรวม'),

          ],

        ),

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

          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('ยกเลิก')),

          FilledButton(

            style: FilledButton.styleFrom(backgroundColor: Colors.teal.shade700),

            onPressed: () => Navigator.of(ctx).pop(true),

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

        _loadClassAdvisors();

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



  Future<void> _downloadAdvisorsTemplate() async {

    final url = widget.apiService.getClassAdvisorsTemplateUrl();

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

          SnackBar(content: Text('ดาวน์โหลดแม่แบบไม่สำเร็จ: $e')),

        );

      }

    }

  }



  String _computeAutoSemesterTitle(String term, String year) {
    final y = year.trim();
    final termStr = term == '3' ? 'ภาคเรียนฤดูร้อน (3)' : 'ภาคเรียนที่ $term';
    return y.isNotEmpty ? 'ปีการศึกษา $y $termStr' : '';
  }

  Future<void> _openSemesterEditDialog([SemesterConfigItem? existing]) async {
    final isEditing = existing != null;
    String selectedTerm = existing?.term ?? '1';
    final initialYear = existing?.year ?? '2570';
    final yearController = TextEditingController(text: initialYear);
    final titleController = TextEditingController(
      text: existing?.title ?? _computeAutoSemesterTitle(selectedTerm, initialYear),
    );

    final orderController = TextEditingController(

      text: existing?.displayOrder.toString() ?? (_semesterConfigs.length + 1).toString(),

    );



    await showDialog(

      context: context,

      builder: (ctx) {

        return StatefulBuilder(

          builder: (dialogCtx, setModalState) {

            return AlertDialog(

              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

              title: Row(

                children: [

                  Icon(

                    isEditing ? Icons.edit_note_rounded : Icons.add_circle_outline_rounded,

                    color: Theme.of(context).colorScheme.primary,

                  ),

                  const SizedBox(width: 10),

                  Text(

                    isEditing ? 'แก้ไขปุ่มภาคเรียน' : 'เพิ่มปุ่มภาคเรียนใหม่',

                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),

                  ),

                ],

              ),

              content: ConstrainedBox(

                constraints: const BoxConstraints(maxWidth: 480),

                child: SingleChildScrollView(

                  child: Column(

                    mainAxisSize: MainAxisSize.min,

                    crossAxisAlignment: CrossAxisAlignment.stretch,

                    children: [

                      const Text(

                        'กำหนดข้อมูลสำหรับปุ่มภาคเรียนที่จะแสดงในหน้าคลังข้อมูล (Archive)',

                        style: TextStyle(fontSize: 12, color: Colors.grey),

                      ),

                      const SizedBox(height: 16),

                      TextField(
                        controller: titleController,
                        readOnly: true,
                        decoration: InputDecoration(
                          labelText: 'ชื่อปุ่มที่ต้องการให้แสดง (สร้างให้อัตโนมัติ)',
                          hintText: 'ปีการศึกษา ... ภาคเรียนที่ ...',
                          border: const OutlineInputBorder(),
                          filled: true,
                          fillColor: Colors.grey.shade100,
                          prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                          helperText: 'ระบบกำหนดรูปแบบมาตรฐานเดียวกันอัตโนมัติจากปีการศึกษาและภาคเรียน',
                          helperStyle: const TextStyle(fontSize: 11, color: Colors.indigo),
                        ),
                      ),

                      const SizedBox(height: 14),

                      Row(

                        children: [

                          Expanded(

                            child: DropdownButtonFormField<String>(

                              initialValue: selectedTerm,

                              decoration: const InputDecoration(

                                labelText: 'ภาคเรียน (เทอม)',

                                border: OutlineInputBorder(),

                                prefixIcon: Icon(Icons.school_rounded),

                              ),

                              items: const [

                                DropdownMenuItem(value: '1', child: Text('ภาคเรียนที่ 1')),

                                DropdownMenuItem(value: '2', child: Text('ภาคเรียนที่ 2')),

                                DropdownMenuItem(value: '3', child: Text('ภาคเรียนฤดูร้อน (3)')),

                              ],

                              onChanged: (val) {
                                if (val != null) {
                                  setModalState(() {
                                    selectedTerm = val;
                                    titleController.text = _computeAutoSemesterTitle(selectedTerm, yearController.text);
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: yearController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'ปีการศึกษา',
                                hintText: 'เช่น 2570',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.calendar_today_rounded),
                              ),
                              onChanged: (val) {
                                setModalState(() {
                                  titleController.text = _computeAutoSemesterTitle(selectedTerm, val);
                                });
                              },
                            ),
                          ),

                        ],

                      ),

                      const SizedBox(height: 14),

                      TextField(
                        controller: orderController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'ลำดับการแสดงผล (น้อยไปมาก)',
                          hintText: '1, 2, 3...',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.sort_rounded),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FDF4),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF86EFAC)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.inventory_2_outlined, size: 18, color: Color(0xFF166534)),
                                const SizedBox(width: 8),
                                const Text(
                                  'นำเข้าข้อมูลเดิม (คลังเก็บข้อมูลต่อเนื่อง 10 ปี)',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF166534)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'เลือกไฟล์สำรองข้อมูลเดิมที่เคยจัดเก็บไว้ (เช่น ปีการศึกษา 2566 ภาคเรียนที่ 1) เพื่อนำเข้าสู่ปุ่มภาคเรียนนี้',
                              style: TextStyle(fontSize: 11.5, color: Color(0xFF15803D)),
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF166534),
                                side: const BorderSide(color: Color(0xFF166534)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              ),
                              icon: const Icon(Icons.folder_open_rounded, size: 18),
                              label: const Text('เลือกไฟล์ที่เก็บไว้เพื่อนำเข้าข้อมูล...'),
                              onPressed: () {
                                _showImportBackupForSemesterModal(
                                  parentCtx: dialogCtx,
                                  targetTerm: selectedTerm,
                                  targetYear: yearController.text.trim(),
                                );
                              },
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

                  icon: const Icon(Icons.save_rounded, size: 18),

                  label: const Text('บันทึก'),

                  onPressed: () async {

                    final title = titleController.text.trim();

                    final year = yearController.text.trim();

                    final order = int.tryParse(orderController.text.trim()) ?? 0;



                    if (title.isEmpty || year.isEmpty) {

                      ScaffoldMessenger.of(context).showSnackBar(

                        const SnackBar(content: Text('กรุณากรอกชื่อปุ่มและปีการศึกษาให้ครบถ้วน')),

                      );

                      return;

                    }



                    Navigator.of(ctx).pop();



                    try {

                      final item = SemesterConfigItem(

                        id: existing?.id,

                        term: selectedTerm,

                        year: year,

                        title: title,

                        displayOrder: order,

                        isActive: true,

                      );

                      await widget.apiService.saveSemesterConfig(item);

                      _loadSemesterConfigs();

                      widget.onSettingsChanged?.call();

                      if (mounted) {

                        ScaffoldMessenger.of(context).showSnackBar(

                          SnackBar(

                            backgroundColor: Colors.green.shade700,

                            content: Text('บันทึกปุ่ม "$title" สำเร็จ'),

                          ),

                        );

                      }

                    } catch (e) {

                      if (mounted) {

                        ScaffoldMessenger.of(context).showSnackBar(

                          SnackBar(

                            backgroundColor: Colors.red.shade700,

                            content: Text('เกิดข้อผิดพลาดในการบันทึก: $e'),

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



  Future<void> _confirmDeleteSemesterConfig(SemesterConfigItem item) async {

    final confirmed = await showDialog<bool>(

      context: context,

      builder: (ctx) => AlertDialog(

        title: const Row(

          children: [

            Icon(Icons.warning_amber_rounded, color: Colors.red),

            SizedBox(width: 10),

            Text('ยืนยันการลบปุ่มภาคเรียน'),

          ],

        ),

        content: Text(

          'คุณต้องการลบปุ่ม "${item.title}" ออกจากการแสดงผลหรือไม่?\n\n'

          '(หมายเหตุ: การลบปุ่มนี้จะไม่ลบข้อมูลผลการเรียนที่บันทึกไว้ในฐานข้อมูล)',

        ),

        actions: [

          TextButton(

            onPressed: () => Navigator.of(ctx).pop(false),

            child: const Text('ยกเลิก'),

          ),

          FilledButton(

            style: FilledButton.styleFrom(backgroundColor: Colors.red),

            onPressed: () => Navigator.of(ctx).pop(true),

            child: const Text('ยืนยันลบ'),

          ),

        ],

      ),

    );



    if (confirmed == true && item.id != null) {

      try {

        await widget.apiService.deleteSemesterConfig(item.id!);

        _loadSemesterConfigs();

        widget.onSettingsChanged?.call();

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(

              backgroundColor: Colors.green.shade700,

              content: Text('ลบปุ่ม "${item.title}" เรียบร้อยแล้ว'),

            ),

          );

        }

      } catch (e) {

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(backgroundColor: Colors.red.shade700, content: Text('ลบปุ่มไม่สำเร็จ: $e')),

          );

        }

      }

    }

  }



  Future<void> _confirmResetSemesterConfigsToDefaults() async {

    final confirmed = await showDialog<bool>(

      context: context,

      builder: (ctx) => AlertDialog(

        title: const Text('คืนค่าปุ่มภาคเรียนเริ่มต้น'),

        content: const Text(

          'คุณต้องการรีเซ็ตปุ่มภาคเรียนกลับเป็นค่าเริ่มต้นมาตรฐาน 4 ภาคเรียน:\n'

          '• ปีการศึกษา 2568 ภาคเรียนที่ 1\n'

          '• ปีการศึกษา 2568 ภาคเรียนที่ 2\n'

          '• ปีการศึกษา 2569 ภาคเรียนที่ 1\n'

          '• ปีการศึกษา 2569 ภาคเรียนที่ 2\n\n'

          'หรือไม่?',

        ),

        actions: [

          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('ยกเลิก')),

          FilledButton(

            onPressed: () => Navigator.of(ctx).pop(true),

            child: const Text('ยืนยันคืนค่าเริ่มต้น'),

          ),

        ],

      ),

    );



    if (confirmed == true) {

      try {

        await widget.apiService.resetSemesterConfigsToDefaults();

        _loadSemesterConfigs();

        widget.onSettingsChanged?.call();

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            const SnackBar(

              backgroundColor: Colors.green,

              content: Text('คืนค่าปุ่มภาคเรียนเริ่มต้นเรียบร้อยแล้ว'),

            ),

          );

        }

      } catch (e) {

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(backgroundColor: Colors.red, content: Text('คืนค่าเริ่มต้นไม่สำเร็จ: $e')),

          );

        }

      }

    }

  }



  Future<void> _openResetSemesterDataDialog(SemesterConfigItem item) async {
    bool deleteFiles = false;
    bool backupFirst = true;



    await showDialog(

      context: context,

      builder: (ctx) {

        return StatefulBuilder(

          builder: (dialogCtx, setModalState) {

            return AlertDialog(

              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

              title: const Row(

                children: [

                  Icon(Icons.delete_forever_rounded, color: Colors.red, size: 28),

                  SizedBox(width: 10),

                  Text('ล้างข้อมูลรายภาคเรียน', style: TextStyle(fontWeight: FontWeight.bold)),

                ],

              ),

              content: ConstrainedBox(

                constraints: const BoxConstraints(maxWidth: 480),

                child: Column(

                  mainAxisSize: MainAxisSize.min,

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Container(

                      padding: const EdgeInsets.all(12),

                      decoration: BoxDecoration(

                        color: Colors.red.shade50,

                        borderRadius: BorderRadius.circular(8),

                        border: Border.all(color: Colors.red.shade200),

                      ),

                      child: Row(

                        children: [

                          Icon(Icons.warning_rounded, color: Colors.red.shade700, size: 22),

                          const SizedBox(width: 10),

                          Expanded(

                            child: Text(

                              'คุณกำลังจะลบข้อมูลของ: ${item.title}',

                              style: TextStyle(

                                fontWeight: FontWeight.bold,

                                color: Colors.red.shade900,

                                fontSize: 13,

                              ),

                            ),

                          ),

                        ],

                      ),

                    ),

                    const SizedBox(height: 14),

                    Text(

                      'ข้อมูลที่จะถูกลบออกจากฐานข้อมูล:\n'

                      '• รายวิชาทั้งหมดในเทอมนี้ (${item.courseCount} รายวิชา)\n'

                      '• ผลการเรียนและประวัติเวลาเรียน (${item.gradeCount} รายการ)\n'

                      '• ข้อมูลนักเรียนที่ไม่มีผลการเรียนในเทอมอื่นจะถูกล้างออกด้วย',

                      style: const TextStyle(fontSize: 13, height: 1.5),

                    ),

                    const SizedBox(height: 14),

                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFBFDBFE)),
                      ),
                      child: CheckboxListTile(
                        value: backupFirst,
                        contentPadding: EdgeInsets.zero,
                        activeColor: const Color(0xFF1D4ED8),
                        title: const Text(
                          'จัดเก็บ/สำรองข้อมูลภาคเรียนนี้ไว้ก่อนล้าง (แนะนำ)',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                        ),
                        subtitle: const Text(
                          'บันทึกข้อมูลผลการเรียนและรายวิชาของเทอมนี้เข้าสู่คลังจัดเก็บข้อมูล สามารถนำกลับมาใช้ใหม่ได้ตลอดเวลา',
                          style: TextStyle(fontSize: 11, color: Color(0xFF1E40AF)),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (val) => setModalState(() => backupFirst = val ?? true),
                      ),
                    ),
                    CheckboxListTile(
                      value: deleteFiles,
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'ลบไฟล์เอกสาร ปพ.5 (Excel และ PDF) ที่สร้างขึ้นของเทอมนี้ด้วย',
                        style: TextStyle(fontSize: 12),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (val) {
                        setModalState(() => deleteFiles = val ?? false);
                      },
                    ),

                  ],

                ),

              ),

              actions: [

                TextButton(

                  onPressed: () => Navigator.of(ctx).pop(),

                  child: const Text('ยกเลิก'),

                ),

                FilledButton.icon(

                  style: FilledButton.styleFrom(

                    backgroundColor: Colors.red.shade700,

                    foregroundColor: Colors.white,

                  ),

                  icon: const Icon(Icons.delete_forever_rounded, size: 18),

                  label: const Text('ยืนยันการล้างข้อมูลเทอมนี้'),

                  onPressed: () async {

                    Navigator.of(ctx).pop();

                    try {

                      final res = await widget.apiService.deleteSemesterData(
                        term: item.term,
                        year: item.year,
                        deleteFiles: deleteFiles,
                        backupFirst: backupFirst,
                      );
                      _loadBackups();
    _loadSchoolThemeConfig();

                      _loadSemesterConfigs();

                      widget.onSettingsChanged?.call();

                      if (mounted) {

                        ScaffoldMessenger.of(context).showSnackBar(

                          SnackBar(

                            backgroundColor: Colors.green.shade800,

                            content: Text(res['message'] ?? 'ล้างข้อมูลสำเร็จ'),

                          ),

                        );

                      }

                    } catch (e) {

                      if (mounted) {

                        ScaffoldMessenger.of(context).showSnackBar(

                          SnackBar(

                            backgroundColor: Colors.red.shade800,

                            content: Text('ลบข้อมูลไม่สำเร็จ: $e'),

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



  Future<void> _openResetAllDataDialog() async {
    bool deleteFiles = false;
    bool backupFirst = true;

    final confirmController = TextEditingController();



    await showDialog(

      context: context,

      builder: (ctx) {

        return StatefulBuilder(

          builder: (dialogCtx, setModalState) {

            final canConfirm = confirmController.text.trim() == 'RESET';



            return AlertDialog(

              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

              title: const Row(

                children: [

                  Icon(Icons.dangerous_rounded, color: Colors.red, size: 30),

                  SizedBox(width: 10),

                  Text('รีเซ็ตข้อมูลทั้งหมดในระบบ', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),

                ],

              ),

              content: ConstrainedBox(

                constraints: const BoxConstraints(maxWidth: 480),

                child: Column(

                  mainAxisSize: MainAxisSize.min,

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    const Text(

                      'คำเตือนขั้นสูงสุด: การกระทำนี้จะล้างข้อมูลทุกภาคเรียน ทุกรายวิชา และนักเรียนทุกคนออกจากคลังข้อมูลอย่างถาวร!',

                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red, fontSize: 13),

                    ),

                    const SizedBox(height: 14),

                    const Text(

                      'เหมาะสำหรับกรณีต้องการเริ่มปีการศึกษาใหม่ทั้งหมด หรือล้างข้อมูลตัวอย่างออกจากระบบ',

                      style: TextStyle(fontSize: 12, color: Colors.grey),

                    ),

                    const SizedBox(height: 12),

                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFBFDBFE)),
                      ),
                      child: CheckboxListTile(
                        value: backupFirst,
                        contentPadding: EdgeInsets.zero,
                        activeColor: const Color(0xFF1D4ED8),
                        title: const Text(
                          'จัดเก็บ/สำรองข้อมูลทั้งหมดไว้ในคลังข้อมูลก่อนรีเซ็ต (แนะนำอย่างยิ่ง)',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                        ),
                        subtitle: const Text(
                          'ระบบจะสร้างไฟล์สำรองข้อมูลทุกอย่างเก็บไว้ในหัวข้อ "จัดเก็บข้อมูล" ด้านล่างโดยอัตโนมัติก่อนล้างข้อมูล',
                          style: TextStyle(fontSize: 11, color: Color(0xFF1E40AF)),
                        ),
                        onChanged: (val) => setModalState(() => backupFirst = val ?? true),
                      ),
                    ),
                    CheckboxListTile(
                      value: deleteFiles,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('ลบไฟล์เอกสารที่สร้างขึ้นทั้งหมดใน outputs/ ด้วย', style: TextStyle(fontSize: 12)),
                      onChanged: (val) => setModalState(() => deleteFiles = val ?? false),
                    ),

                    const SizedBox(height: 12),

                    const Text(

                      'กรุณาพิมพ์คำว่า "RESET" เพื่อยืนยัน:',

                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),

                    ),

                    const SizedBox(height: 6),

                    TextField(

                      controller: confirmController,

                      decoration: const InputDecoration(

                        hintText: 'พิมพ์ RESET ที่นี่',

                        border: OutlineInputBorder(),

                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),

                      ),

                      onChanged: (_) => setModalState(() {}),

                    ),

                  ],

                ),

              ),

              actions: [

                TextButton(

                  onPressed: () => Navigator.of(ctx).pop(),

                  child: const Text('ยกเลิก'),

                ),

                FilledButton(

                  style: FilledButton.styleFrom(backgroundColor: Colors.red.shade900),

                  onPressed: !canConfirm

                      ? null

                      : () async {

                          Navigator.of(ctx).pop();

                          try {

                            final res = await widget.apiService.resetAllData(
                              deleteFiles: deleteFiles,
                              backupFirst: backupFirst,
                            );
                            _loadBackups();
    _loadSchoolThemeConfig();

                            _loadSemesterConfigs();

                            widget.onSettingsChanged?.call();

                            if (mounted) {

                              ScaffoldMessenger.of(context).showSnackBar(

                                SnackBar(

                                  backgroundColor: Colors.green.shade800,

                                  content: Text(res['message'] ?? 'รีเซ็ตข้อมูลทั้งหมดเรียบร้อยแล้ว'),

                                ),

                              );

                            }

                          } catch (e) {

                            if (mounted) {

                              ScaffoldMessenger.of(context).showSnackBar(

                                SnackBar(backgroundColor: Colors.red.shade800, content: Text('รีเซ็ตไม่สำเร็จ: $e')),

                              );

                            }

                          }

                        },

                  child: const Text('ยืนยันการล้างข้อมูลทั้งหมด'),

                ),

              ],

            );

          },

        );

      },

    );

  }



  // ===========================================================================

  // SCHOOL SIGNATORIES LOGIC METHODS

  // ===========================================================================



  Future<void> _loadSchoolTeachers() async {

    setState(() => _loadingTeachers = true);

    try {

      final list = await widget.apiService.getSchoolTeachers();

      final withCode = await widget.apiService.getSchoolTeachersWithCode();

      if (mounted) {

        setState(() {

          _schoolTeachersList = list;

          _teachersWithCode = withCode;

          _loadingTeachers = false;

        });

      }

    } catch (_) {

      if (mounted) setState(() => _loadingTeachers = false);

    }

  }



  Future<void> _loadSignatories({String? year}) async {

    final targetYear = year ?? _selectedSignatoryYear;

    setState(() {

      _loadingSignatories = true;

      _signatoriesError = null;

    });

    try {

      final data = await widget.apiService.getSignatories(year: targetYear);

      if (mounted) {

        final availYears = (data['available_years'] as List?)?.map((e) => e.toString()).toList() ?? [];

        if (availYears.isNotEmpty) {

          _availableSignatoryYears = availYears;

          if (!availYears.contains(targetYear)) {

            _availableSignatoryYears.add(targetYear);

            _availableSignatoryYears.sort((a, b) => b.compareTo(a));

          }

        }



        _selectedSignatoryYear = data['year']?.toString() ?? targetYear;
        String raw = data['school_name']?.toString() ?? '';
        raw = raw.replaceFirst(RegExp(r'^โรงเรียน\s*'), '').trim();
        _schoolNameCtrl.text = raw;
        widget.apiService.schoolNameNotifier.value = 'โรงเรียน${_schoolNameCtrl.text}';

        _directorNameCtrl.text = data['director_name']?.toString() ?? '';

        _directorTitleCtrl.text = data['director_title']?.toString() ?? '';

        _academicNameCtrl.text = data['academic_head_name']?.toString() ?? '';

        _academicTitleCtrl.text = data['academic_head_title']?.toString() ?? 'หัวหน้างานวิชาการ';

        _registrarNameCtrl.text = data['registrar_name']?.toString() ?? '';

        _registrarTitleCtrl.text = data['registrar_title']?.toString() ?? 'งานทะเบียน-วัดผล';

        _deptHeadDefaultCtrl.text = data['dept_head_default']?.toString() ?? '';



        final deptHeads = (data['dept_heads'] as Map<String, dynamic>?) ?? {};

        for (final dept in kStandardDepartments) {

          _deptHeadsCtrls[dept]?.text = deptHeads[dept]?.toString() ?? '';

        }



        setState(() {

          _loadingSignatories = false;

        });

      }

    } catch (e) {

      if (mounted) {

        setState(() {

          _signatoriesError = e.toString().replaceFirst('Exception: ', '');

          _loadingSignatories = false;

        });

      }

    }

  }



  Future<void> _saveSignatories() async {

    setState(() => _savingSignatories = true);

    try {

      final deptHeads = <String, String>{};

      for (final entry in _deptHeadsCtrls.entries) {

        final v = entry.value.text.trim();

        if (v.isNotEmpty) {

          deptHeads[entry.key] = v;

        }

      }



      final payload = {

        'year': _selectedSignatoryYear.trim(),

        'school_name': _schoolNameCtrl.text.replaceFirst(RegExp(r'^โรงเรียน\s*'), '').trim(),

        'director_name': _directorNameCtrl.text.trim(),

        'director_title': _directorTitleCtrl.text.trim(),

        'academic_head_name': _academicNameCtrl.text.trim(),

        'academic_head_title': _academicTitleCtrl.text.trim(),

        'registrar_name': _registrarNameCtrl.text.trim(),

        'registrar_title': _registrarTitleCtrl.text.trim(),

        'dept_head_default': _deptHeadDefaultCtrl.text.trim(),

        'dept_heads': deptHeads,

        'sync_existing_files': _syncExistingSignatoryFiles,

      };



      final res = await widget.apiService.saveSignatories(payload);

      if (mounted) {

        setState(() => _savingSignatories = false);

        _loadSchoolTeachers();

        widget.apiService.schoolNameNotifier.value = _schoolNameCtrl.text.trim();

        final msg = res['message'] ?? 'บันทึกข้อมูลผู้ลงนามเรียบร้อยแล้ว';

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.green.shade800,

            content: Text(msg),

          ),

        );

      }

    } catch (e) {

      if (mounted) {

        setState(() => _savingSignatories = false);

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.red.shade800,

            content: Text('เกิดข้อผิดพลาดในการบันทึก: ${e.toString().replaceFirst('Exception: ', '')}'),

          ),

        );

      }

    }

  }



  Future<void> _openCopySignatoriesDialog() async {

    final otherYears = _availableSignatoryYears.where((y) => y != _selectedSignatoryYear).toList();

    if (otherYears.isEmpty) {

      ScaffoldMessenger.of(context).showSnackBar(

        const SnackBar(content: Text('ไม่มีปีการศึกษาอื่นให้คัดลอกข้อมูล')),

      );

      return;

    }



    String sourceYear = otherYears.first;

    bool syncFiles = true;



    await showDialog(

      context: context,

      builder: (ctx) => StatefulBuilder(

        builder: (dCtx, setDState) => AlertDialog(

          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

          title: Row(

            children: [

              Icon(Icons.content_copy_rounded, color: Theme.of(context).colorScheme.primary),

              const SizedBox(width: 8),

              const Text('คัดลอกข้อมูลผู้ลงนามข้ามปี'),

            ],

          ),

          content: Column(

            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              Text(

                'คัดลอกข้อมูลผู้บริหารและผู้ลงนามหน้าปก ปพ.5 จากปีการศึกษาต้นทางมาใส่ในปี $_selectedSignatoryYear:',

                style: const TextStyle(fontSize: 13),

              ),

              const SizedBox(height: 14),

              DropdownButtonFormField<String>(

                value: sourceYear,

                decoration: const InputDecoration(

                  labelText: 'ปีการศึกษาต้นทาง',

                  border: OutlineInputBorder(),

                  prefixIcon: Icon(Icons.history_edu_rounded),

                ),

                items: otherYears.map((y) => DropdownMenuItem(value: y, child: Text('ปีการศึกษา $y'))).toList(),

                onChanged: (val) {

                  if (val != null) setDState(() => sourceYear = val);

                },

              ),

              const SizedBox(height: 10),

              CheckboxListTile(

                contentPadding: EdgeInsets.zero,

                dense: true,

                title: const Text('อัปเดตไฟล์ Excel และ PDF ปพ.5 ของปีนี้ทันที', style: TextStyle(fontSize: 12)),

                value: syncFiles,

                onChanged: (val) => setDState(() => syncFiles = val ?? true),

              ),

            ],

          ),

          actions: [

            TextButton(

              onPressed: () => Navigator.of(ctx).pop(),

              child: const Text('ยกเลิก'),

            ),

            FilledButton.icon(

              icon: const Icon(Icons.copy_rounded, size: 16),

              label: const Text('คัดลอกข้อมูล'),

              onPressed: () async {

                Navigator.of(ctx).pop();

                try {

                  await widget.apiService.copySignatories(

                    sourceYear,

                    _selectedSignatoryYear,

                    syncExistingFiles: syncFiles,

                  );

                  _loadSignatories(year: _selectedSignatoryYear);

                  if (mounted) {

                    ScaffoldMessenger.of(context).showSnackBar(

                      SnackBar(

                        backgroundColor: Colors.green.shade800,

                        content: Text('คัดลอกข้อมูลจากปี $sourceYear สำเร็จแล้ว'),

                      ),

                    );

                  }

                } catch (e) {

                  if (mounted) {

                    ScaffoldMessenger.of(context).showSnackBar(

                      SnackBar(

                        backgroundColor: Colors.red.shade800,

                        content: Text('คัดลอกข้อมูลไม่สำเร็จ: $e'),

                      ),

                    );

                  }

                }

              },

            ),

          ],

        ),

      ),

    );

  }



  Future<void> _openAddNewSignatoryYearDialog() async {

    final ctrl = TextEditingController(text: (int.tryParse(_selectedSignatoryYear) != null ? (int.parse(_selectedSignatoryYear) + 1).toString() : ''));

    await showDialog(

      context: context,

      builder: (ctx) => AlertDialog(

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: Row(

          children: [

            Icon(Icons.calendar_today_rounded, color: Theme.of(context).colorScheme.primary),

            const SizedBox(width: 8),

            const Text('เพิ่มปีการศึกษาใหม่'),

          ],

        ),

        content: Column(

          mainAxisSize: MainAxisSize.min,

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            const Text('กรอกปีการศึกษา พ.ศ. (เช่น 2570, 2571):', style: TextStyle(fontSize: 13)),

            const SizedBox(height: 12),

            TextField(

              controller: ctrl,

              keyboardType: TextInputType.number,

              decoration: const InputDecoration(

                labelText: 'ปีการศึกษา (พ.ศ.)',

                hintText: '2570',

                border: OutlineInputBorder(),

                prefixIcon: Icon(Icons.date_range_rounded),

              ),

            ),

          ],

        ),

        actions: [

          TextButton(

            onPressed: () => Navigator.of(ctx).pop(),

            child: const Text('ยกเลิก'),

          ),

          FilledButton(

            onPressed: () {

              final newY = ctrl.text.trim();

              if (newY.isNotEmpty && newY.length == 4) {

                Navigator.of(ctx).pop();

                setState(() {

                  if (!_availableSignatoryYears.contains(newY)) {

                    _availableSignatoryYears.add(newY);

                    _availableSignatoryYears.sort((a, b) => b.compareTo(a));

                  }

                  _selectedSignatoryYear = newY;

                });

                _loadSignatories(year: newY);

              }

            },

            child: const Text('ตกลง'),

          ),

        ],

      ),

    );

  }



  Future<void> _pickTeacherForController(TextEditingController controller, String label) async {

    if (_schoolTeachersList.isEmpty) {

      try {

        _schoolTeachersList = await widget.apiService.getSchoolTeachers();

      } catch (_) {}

    }

    if (!mounted) return;



    String search = '';

    await showDialog(

      context: context,

      builder: (ctx) => StatefulBuilder(

        builder: (dCtx, setDState) {

          final filtered = _schoolTeachersList.where((t) => t.toLowerCase().contains(search.toLowerCase())).toList();

          return AlertDialog(

            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

            title: Row(

              children: [

                Icon(Icons.person_search_rounded, color: Theme.of(context).colorScheme.primary),

                const SizedBox(width: 8),

                Expanded(

                  child: Text('เลือกคุณครูสำหรับ: $label', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),

                ),

              ],

            ),

            content: SizedBox(

              width: 420,

              height: 420,

              child: Column(

                children: [

                  TextField(

                    decoration: const InputDecoration(

                      prefixIcon: Icon(Icons.search),

                      hintText: 'ค้นหาชื่อครู...',

                      border: OutlineInputBorder(),

                      isDense: true,

                    ),

                    onChanged: (val) => setDState(() => search = val),

                  ),

                  const SizedBox(height: 12),

                  Expanded(

                    child: filtered.isEmpty

                        ? const Center(child: Text('ไม่พบรายชื่อคุณครูในทำเนียบ'))

                        : ListView.separated(

                            itemCount: filtered.length,

                            separatorBuilder: (_, i) => const Divider(height: 1),

                            itemBuilder: (_, idx) {

                              final name = filtered[idx];

                              return ListTile(

                                dense: true,

                                leading: const CircleAvatar(radius: 14, child: Icon(Icons.person, size: 16)),

                                title: Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),

                                trailing: const Icon(Icons.check, size: 16),

                                onTap: () {

                                  controller.text = name;

                                  Navigator.of(ctx).pop();

                                },

                              );

                            },

                          ),

                  ),

                ],

              ),

            ),

            actions: [

              TextButton(

                onPressed: () => Navigator.of(ctx).pop(),

                child: const Text('ปิด'),

              ),

            ],

          );

        },

      ),

    );

  }



  @override

  Widget build(BuildContext context) {

    final theme = Theme.of(context);

    final isAdmin = widget.apiService.isAdmin;

    final user = widget.apiService.currentUser;
    if (user != null && !user.canAccessSettings) {
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
                child: const Icon(Icons.admin_panel_settings_rounded, size: 52, color: Color(0xFFB45309)),
              ),
              const SizedBox(height: 20),
              const Text(
                'ล็อกการเข้าถึงการตั้งค่าระบบ',
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
                'หน้าตั้งค่าสงวนสิทธิ์เฉพาะคณะครูและผู้ดูแลระบบโรงเรียนเท่านั้น สำหรับบุคคลทั่วไปสามารถเข้าดูข้อมูลในส่วนอื่น ๆ ได้',
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

    return SingleChildScrollView(

      padding: const EdgeInsets.all(24),

      child: Center(

        child: ConstrainedBox(

          constraints: const BoxConstraints(maxWidth: 780),

          child: Column(

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              Text(

                'การตั้งค่าระบบ (System Settings)',

                style: theme.textTheme.headlineMedium?.copyWith(

                  fontWeight: FontWeight.bold,

                ),

              ),

              const SizedBox(height: 6),

              Text(

                'จัดการปุ่มเลือกภาคเรียน แก้ไขชื่อ เพิ่มปีการศึกษาถัดไป และรีเซ็ตข้อมูลรายภาคเรียน',

                style: theme.textTheme.bodyMedium?.copyWith(

                  color: theme.colorScheme.onSurfaceVariant,

                ),

              ),

              const SizedBox(height: 24),



              if (!isAdmin) ...[

                Container(

                  margin: const EdgeInsets.only(bottom: 20),

                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),

                  decoration: BoxDecoration(

                    color: Colors.amber.shade50,

                    borderRadius: BorderRadius.circular(12),

                    border: Border.all(color: Colors.amber.shade300),

                  ),

                  child: Row(

                    children: [

                      Icon(Icons.lock_rounded, color: Colors.amber.shade900, size: 24),

                      const SizedBox(width: 12),

                      Expanded(

                        child: Column(

                          crossAxisAlignment: CrossAxisAlignment.start,

                          children: [

                            Text(

                              'โหมดดูข้อมูลอย่างเดียว (Read-Only Mode)',

                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber.shade900, fontSize: 13.5),

                            ),

                            const SizedBox(height: 2),

                            Text(

                              'สำหรับผู้ใช้งานทั่วไป (คุณครู) หน้าตั้งค่าระบบนี้เปิดสำหรับดูข้อมูลอ้างอิงเท่านั้น การแก้ไข ลบ หรือเพิ่มข้อมูลในระบบสงวนสิทธิ์เฉพาะผู้ดูแลระบบ (Admin) เท่านั้น',

                              style: TextStyle(fontSize: 12, color: Colors.amber.shade900),

                            ),

                          ],

                        ),

                      ),

                    ],

                  ),

                ),

              ],



              // ===============================================================

              // SECTION 1: Manage Semester Buttons

              // ===============================================================

              Card(

                elevation: 1,

                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

                child: Padding(

                  padding: const EdgeInsets.all(22),

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Row(

                        children: [

                          Container(

                            padding: const EdgeInsets.all(8),

                            decoration: BoxDecoration(

                              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),

                              borderRadius: BorderRadius.circular(10),

                            ),

                            child: Icon(Icons.dashboard_customize_rounded, color: theme.colorScheme.primary, size: 24),

                          ),

                          const SizedBox(width: 12),

                          Expanded(

                            child: Column(

                              crossAxisAlignment: CrossAxisAlignment.start,

                              children: [

                                Text(

                                  'การจัดการปุ่มภาคเรียนและปีการศึกษา',

                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),

                                ),

                                const SizedBox(height: 2),

                                Text(

                                  'สร้างหรือแก้ไขชื่อปุ่มสำหรับใช้ในปีการศึกษาต่อๆ ไป (เช่น 2570, 2571...)',

                                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                                ),

                              ],

                            ),

                          ),

                          if (isAdmin)

                            Wrap(

                              spacing: 8,

                              children: [

                                OutlinedButton.icon(

                                  style: OutlinedButton.styleFrom(

                                    visualDensity: VisualDensity.compact,

                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                                  ),

                                  icon: const Icon(Icons.restart_alt_rounded, size: 16),

                                  label: const Text('คืนค่าเริ่มต้น', style: TextStyle(fontSize: 12)),

                                  onPressed: _confirmResetSemesterConfigsToDefaults,

                                ),

                                FilledButton.icon(

                                  style: FilledButton.styleFrom(

                                    visualDensity: VisualDensity.compact,

                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),

                                  ),

                                  icon: const Icon(Icons.add, size: 16),

                                  label: const Text('เพิ่มปุ่มภาคเรียนใหม่', style: TextStyle(fontSize: 12)),

                                  onPressed: () => _openSemesterEditDialog(),

                                ),

                              ],

                            ),

                        ],

                      ),

                      const Divider(height: 28),



                      if (_loadingSemesters)

                        const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))

                      else if (_semestersError != null)

                        Container(

                          padding: const EdgeInsets.all(12),

                          decoration: BoxDecoration(

                            color: Colors.red.shade50,

                            borderRadius: BorderRadius.circular(8),

                            border: Border.all(color: Colors.red.shade200),

                          ),

                          child: Row(

                            children: [

                              Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),

                              const SizedBox(width: 8),

                              Expanded(child: Text('เกิดข้อผิดพลาด: $_semestersError')),

                              TextButton(onPressed: _loadSemesterConfigs, child: const Text('ลองใหม่')),

                            ],

                          ),

                        )

                      else if (_semesterConfigs.isEmpty)

                        const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('ยังไม่มีการตั้งค่าปุ่มภาคเรียน')))

                      else

                        ListView.separated(

                          shrinkWrap: true,

                          physics: const NeverScrollableScrollPhysics(),

                          itemCount: _semesterConfigs.length,

                          separatorBuilder: (_, i) => const Divider(height: 12),

                          itemBuilder: (ctx, idx) {

                            final item = _semesterConfigs[idx];

                            final hasData = item.courseCount > 0;



                            return Container(

                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),

                              decoration: BoxDecoration(

                                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),

                                borderRadius: BorderRadius.circular(10),

                                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),

                              ),

                              child: Row(

                                children: [

                                  CircleAvatar(

                                    radius: 16,

                                    backgroundColor: hasData ? Colors.green.shade100 : Colors.grey.shade200,

                                    child: Text(

                                      '${idx + 1}',

                                      style: TextStyle(

                                        fontSize: 12,

                                        fontWeight: FontWeight.bold,

                                        color: hasData ? Colors.green.shade800 : Colors.grey.shade700,

                                      ),

                                    ),

                                  ),

                                  const SizedBox(width: 14),

                                  Expanded(

                                    child: Column(

                                      crossAxisAlignment: CrossAxisAlignment.start,

                                      children: [

                                        Text(

                                          item.title,

                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),

                                        ),

                                        const SizedBox(height: 3),

                                        Wrap(

                                          spacing: 8,

                                          crossAxisAlignment: WrapCrossAlignment.center,

                                          children: [

                                            Container(

                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),

                                              decoration: BoxDecoration(

                                                color: Colors.blue.shade50,

                                                borderRadius: BorderRadius.circular(4),

                                                border: Border.all(color: Colors.blue.shade200),

                                              ),

                                              child: Text(

                                                'เทอม ${item.term} / ${item.year}',

                                                style: TextStyle(fontSize: 11, color: Colors.blue.shade900, fontWeight: FontWeight.w600),

                                              ),

                                            ),

                                            Text(

                                              hasData

                                                  ? '${item.courseCount} รายวิชา (${item.gradeCount} ผลการเรียน)'

                                                  : 'ยังไม่มีข้อมูลในคลัง',

                                              style: TextStyle(

                                                fontSize: 12,

                                                color: hasData ? Colors.green.shade700 : Colors.grey.shade600,

                                                fontWeight: hasData ? FontWeight.w600 : FontWeight.normal,

                                              ),

                                            ),

                                          ],

                                        ),

                                      ],

                                    ),

                                  ),

                                  if (isAdmin) ...[

                                    IconButton(

                                      icon: const Icon(Icons.edit_outlined, size: 20),

                                      tooltip: 'แก้ไขปุ่ม',

                                      onPressed: () => _openSemesterEditDialog(item),

                                    ),

                                    IconButton(

                                      icon: Icon(Icons.delete_outline, size: 20, color: Colors.red.shade400),

                                      tooltip: 'ลบปุ่ม',

                                      onPressed: () => _confirmDeleteSemesterConfig(item),

                                    ),

                                  ],

                                ],

                              ),

                            );

                          },

                        ),

                    ],

                  ),

                ),

              ),

              const SizedBox(height: 24),



              // ===============================================================

              // SECTION 2: Manage Class Advisors (ครูที่ปรึกษา / ครูประจำชั้น)

              // ===============================================================

              Card(

                elevation: 1,

                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

                child: Padding(

                  padding: const EdgeInsets.all(22),

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Row(

                        crossAxisAlignment: CrossAxisAlignment.start,

                        children: [

                          Container(

                            padding: const EdgeInsets.all(8),

                            decoration: BoxDecoration(

                              color: Colors.teal.shade100.withValues(alpha: 0.6),

                              borderRadius: BorderRadius.circular(10),

                            ),

                            child: Icon(Icons.people_alt_rounded, color: Colors.teal.shade800, size: 24),

                          ),

                          const SizedBox(width: 12),

                          Expanded(

                            child: Column(

                              crossAxisAlignment: CrossAxisAlignment.start,

                              children: [

                                Text(

                                  'ครูที่ปรึกษา / ครูประจำชั้น แต่ละระดับชั้น (Class Advisors)',

                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),

                                ),

                                const SizedBox(height: 2),

                                Text(

                                  'กำหนดครูที่ปรึกษาได้สูงสุด 3 คนต่อห้อง/ระดับชั้น เพื่อเชื่อมโยงลงหน้าปก ปพ.5 อัตโนมัติในแต่ละปีการศึกษา',

                                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                                ),

                              ],

                            ),

                          ),

                        ],

                      ),

                      const SizedBox(height: 18),



                      // Semester selector + Actions bar

                      Container(

                        padding: const EdgeInsets.all(12),

                        decoration: BoxDecoration(

                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),

                          borderRadius: BorderRadius.circular(12),

                          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),

                        ),

                        child: Wrap(

                          spacing: 10,

                          runSpacing: 10,

                          alignment: WrapAlignment.spaceBetween,

                          crossAxisAlignment: WrapCrossAlignment.center,

                          children: [

                            // Semester dropdown

                            Row(

                              mainAxisSize: MainAxisSize.min,

                              children: [

                                const Text('ภาคเรียน: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),

                                const SizedBox(width: 6),

                                if (_semesterConfigs.isNotEmpty)

                                  DropdownButton<String>(

                                    value: _selectedAdvisorSemesterKey,

                                    underline: const SizedBox(),

                                    borderRadius: BorderRadius.circular(10),

                                    items: _semesterConfigs.map((c) {

                                      return DropdownMenuItem(

                                        value: '${c.term}-${c.year}',

                                        child: Text(

                                          c.title,

                                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),

                                        ),

                                      );

                                    }).toList(),

                                    onChanged: (val) {

                                      if (val != null) {

                                        setState(() => _selectedAdvisorSemesterKey = val);

                                        _loadClassAdvisors();

                                      }

                                    },

                                  )

                                else

                                  const Text('กำลังโหลดภาคเรียน...'),

                              ],

                            ),



                            // Action buttons

                            Wrap(

                              spacing: 8,

                              runSpacing: 8,

                              children: [

                                OutlinedButton.icon(

                                  style: OutlinedButton.styleFrom(

                                    visualDensity: VisualDensity.compact,

                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),

                                  ),

                                  icon: const Icon(Icons.download_rounded, size: 16),

                                  label: const Text('แม่แบบ Excel', style: TextStyle(fontSize: 12)),

                                  onPressed: _downloadAdvisorsTemplate,

                                ),

                                if (isAdmin) ...[

                                  OutlinedButton.icon(

                                    style: OutlinedButton.styleFrom(

                                      visualDensity: VisualDensity.compact,

                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),

                                    ),

                                    icon: const Icon(Icons.copy_rounded, size: 16),

                                    label: const Text('คัดลอกจากเทอมอื่น', style: TextStyle(fontSize: 12)),

                                    onPressed: _openCopyAdvisorsDialog,

                                  ),

                                  FilledButton.icon(

                                    style: FilledButton.styleFrom(

                                      backgroundColor: Colors.teal.shade800,

                                      visualDensity: VisualDensity.compact,

                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                                    ),

                                    icon: const Icon(Icons.cloud_upload_outlined, size: 16),

                                    label: const Text('อัปโหลดไฟล์รวม', style: TextStyle(fontSize: 12)),

                                    onPressed: _openUploadAdvisorsDialog,

                                  ),

                                  FilledButton.icon(

                                    style: FilledButton.styleFrom(

                                      visualDensity: VisualDensity.compact,

                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                                    ),

                                    icon: const Icon(Icons.add, size: 16),

                                    label: const Text('เพิ่มระดับชั้น', style: TextStyle(fontSize: 12)),

                                    onPressed: () => _openAdvisorEditDialog(),

                                  ),

                                ],

                              ],

                            ),

                          ],

                        ),

                      ),

                      const SizedBox(height: 16),



                      // Advisors list

                      if (_loadingAdvisors)

                        const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))

                      else if (_advisorsError != null)

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

                                child: Text(_advisorsError!, style: TextStyle(fontSize: 12, color: Colors.red.shade900)),

                              ),

                            ],

                          ),

                        )

                      else if (_classAdvisors.isEmpty)

                        Container(

                          padding: const EdgeInsets.all(24),

                          alignment: Alignment.center,

                          decoration: BoxDecoration(

                            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),

                            borderRadius: BorderRadius.circular(12),

                            border: Border.all(color: theme.colorScheme.outlineVariant),

                          ),

                          child: Column(

                            children: [

                              Icon(Icons.person_off_outlined, size: 40, color: theme.colorScheme.onSurfaceVariant),

                              const SizedBox(height: 8),

                              const Text('ยังไม่มีข้อมูลครูที่ปรึกษาในภาคเรียนนี้', style: TextStyle(fontWeight: FontWeight.w600)),

                              const SizedBox(height: 4),

                              Text(

                                'สามารถกด "+ เพิ่มระดับชั้น", "คัดลอกจากเทอมอื่น" หรือ "อัปโหลดไฟล์รวม" ได้ทันที',

                                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                              ),

                            ],

                          ),

                        )

                      else

                        ListView.separated(

                          shrinkWrap: true,

                          physics: const NeverScrollableScrollPhysics(),

                          itemCount: _classAdvisors.length,

                          separatorBuilder: (_, i) => const Divider(height: 12),

                          itemBuilder: (ctx, idx) {

                            final item = _classAdvisors[idx];

                            return Container(

                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),

                              decoration: BoxDecoration(

                                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),

                                borderRadius: BorderRadius.circular(10),

                                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),

                              ),

                              child: Row(

                                children: [

                                  // Class Badge

                                  Container(

                                    constraints: const BoxConstraints(minWidth: 54),

                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),

                                    decoration: BoxDecoration(

                                      color: Colors.teal.shade700,

                                      borderRadius: BorderRadius.circular(8),

                                    ),

                                    child: Center(

                                      child: Text(

                                        item.classLevel,

                                        style: const TextStyle(

                                          color: Colors.white,

                                          fontWeight: FontWeight.bold,

                                          fontSize: 13,

                                        ),

                                      ),

                                    ),

                                  ),

                                  const SizedBox(width: 14),



                                  // 3 Advisor Chips

                                  Expanded(

                                    child: Wrap(

                                      spacing: 8,

                                      runSpacing: 6,

                                      children: [

                                        _buildAdvisorChip(

                                          label: (item.advisor1 != null && item.advisor1!.trim().isNotEmpty)

                                              ? '1. ${item.advisor1!.trim()}'

                                              : '1. (ยังไม่ระบุ)',

                                          isAssigned: item.advisor1 != null && item.advisor1!.trim().isNotEmpty,

                                          theme: theme,

                                        ),

                                        _buildAdvisorChip(

                                          label: (item.advisor2 != null && item.advisor2!.trim().isNotEmpty)

                                              ? '2. ${item.advisor2!.trim()}'

                                              : '2. (ยังไม่ระบุ)',

                                          isAssigned: item.advisor2 != null && item.advisor2!.trim().isNotEmpty,

                                          theme: theme,

                                        ),

                                        _buildAdvisorChip(

                                          label: (item.advisor3 != null && item.advisor3!.trim().isNotEmpty)

                                              ? '3. ${item.advisor3!.trim()}'

                                              : '3. (ยังไม่ระบุ)',

                                          isAssigned: item.advisor3 != null && item.advisor3!.trim().isNotEmpty,

                                          theme: theme,

                                        ),

                                      ],

                                    ),

                                  ),



                                  // Edit & Delete Buttons

                                  if (isAdmin) ...[

                                    IconButton(

                                      icon: const Icon(Icons.edit_outlined, size: 20),

                                      tooltip: 'แก้ไขครูที่ปรึกษา',

                                      onPressed: () => _openAdvisorEditDialog(item),

                                    ),

                                    IconButton(

                                      icon: Icon(Icons.delete_outline, size: 20, color: Colors.red.shade400),

                                      tooltip: 'ลบระดับชั้นนี้',

                                      onPressed: () => _confirmDeleteAdvisor(item),

                                    ),

                                  ],

                                ],

                              ),

                            );

                          },

                        ),

                    ],

                  ),

                ),

              ),

              const SizedBox(height: 24),



              // ===============================================================

              // SECTION 3: School Identity & Logo (ข้อมูลและโลโก้โรงเรียน)

              // ===============================================================

              _buildSchoolLogoSection(theme),

              const SizedBox(height: 24),

              // ===============================================================
              // SECTION 3.5: School Theme, Colors & Fonts (Branding & Appearance)
              // ===============================================================
              _buildSchoolThemeSection(theme),

              const SizedBox(height: 24),



              // ===============================================================

              // SECTION 4: Manage School Signatories (ข้อมูลผู้ลงนามและผู้บริหาร หน้าปก ปพ.5)

              // ===============================================================

              _buildSignatoriesSection(theme),

              const SizedBox(height: 24),



              // SECTION 5: Teacher Directory & Codes (รายชื่อและรหัสครูผู้สอน)

              // ===============================================================

              _buildTeacherDirectorySection(theme),

              const SizedBox(height: 24),



              // SECTION 5.2: System Administrators (Admin - สูงสุด 3 ท่าน)

              // ===============================================================

              _buildAdminManagementSection(theme),

              const SizedBox(height: 24),



              // SECTION 5.5: Master Course Catalog (คลังรายชื่อวิชามาตรฐาน เทอม 1 และ เทอม 2)

              // ===============================================================

              CourseCatalogCard(

                apiService: widget.apiService,

                onCatalogChanged: () => widget.onSettingsChanged?.call(),

              ),

              const SizedBox(height: 24),



              // SECTION 6: Course Structure & Automated PorPor 5 Generation

              // ===============================================================

              _buildCourseImportSection(theme),



              const SizedBox(height: 24),



              // SECTION 6.5: ฟอร์มนำเข้าข้อมูลโรงเรียน (หลายห้อง/หลายโปรแกรม) — admin



              if (isAdmin) ...[



                SchoolImportCard(apiService: widget.apiService),



                const SizedBox(height: 24),



                ArchiveBackupCard(apiService: widget.apiService),



                const SizedBox(height: 24),

                PublicApiCard(apiService: widget.apiService),

                const SizedBox(height: 24),



                _buildStudentNameMaintenanceCard(theme),



                const SizedBox(height: 24),



              ],

              // ===============================================================
              // SECTION: Data Storage & Multi-Year Archive (จัดเก็บข้อมูล)
              // ===============================================================
              if (isAdmin) ...[
                _buildDataStorageSection(theme),
                const SizedBox(height: 24),
              ],



              // ===============================================================

              // SECTION 4: Reset & Delete Semester Data (Admin Only)

              // ===============================================================

              if (isAdmin) ...[

              Card(

                elevation: 1,

                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

                child: Padding(

                  padding: const EdgeInsets.all(22),

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Row(

                        children: [

                          Container(

                            padding: const EdgeInsets.all(8),

                            decoration: BoxDecoration(

                              color: Colors.orange.shade50,

                              borderRadius: BorderRadius.circular(10),

                            ),

                            child: Icon(Icons.cleaning_services_rounded, color: Colors.orange.shade800, size: 24),

                          ),

                          const SizedBox(width: 12),

                          Expanded(

                            child: Column(

                              crossAxisAlignment: CrossAxisAlignment.start,

                              children: [

                                Text(

                                  'การรีเซ็ตและลบข้อมูลแต่ละเทอม',

                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),

                                ),

                                const SizedBox(height: 2),

                                Text(

                                  'ล้างข้อมูลผลการเรียนและรายวิชา เพื่อเตรียมนำเข้าข้อมูลใหม่ของปีอื่นๆ ได้อย่างสะอาดหมดจด',

                                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                                ),

                              ],

                            ),

                          ),

                        ],

                      ),

                      const Divider(height: 28),



                      if (_semesterConfigs.isEmpty)

                        const Text('ไม่มีภาคเรียนที่สามารถจัดการได้')

                      else

                        ListView.separated(

                          shrinkWrap: true,

                          physics: const NeverScrollableScrollPhysics(),

                          itemCount: _semesterConfigs.length,

                          separatorBuilder: (_, i) => const SizedBox(height: 8),

                          itemBuilder: (ctx, idx) {

                            final item = _semesterConfigs[idx];

                            final hasData = item.courseCount > 0;



                            return Container(

                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),

                              decoration: BoxDecoration(

                                color: hasData ? Colors.white : Colors.grey.shade50,

                                borderRadius: BorderRadius.circular(10),

                                border: Border.all(

                                  color: hasData ? Colors.orange.shade200 : Colors.grey.shade200,

                                ),

                              ),

                              child: Row(

                                children: [

                                  Icon(

                                    hasData ? Icons.folder_shared_rounded : Icons.folder_off_outlined,

                                    color: hasData ? Colors.orange.shade700 : Colors.grey.shade400,

                                    size: 26,

                                  ),

                                  const SizedBox(width: 12),

                                  Expanded(

                                    child: Column(

                                      crossAxisAlignment: CrossAxisAlignment.start,

                                      children: [

                                        Text(

                                          item.title,

                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),

                                        ),

                                        Text(

                                          hasData

                                              ? 'ข้อมูลปัจจุบัน: ${item.courseCount} รายวิชา (${item.gradeCount} ผลการเรียน)'

                                              : 'ไม่มีข้อมูลบันทึกในเทอมนี้',

                                          style: TextStyle(

                                            fontSize: 11,

                                            color: hasData ? Colors.orange.shade900 : Colors.grey.shade600,

                                          ),

                                        ),

                                      ],

                                    ),

                                  ),

                                  OutlinedButton.icon(

                                    style: OutlinedButton.styleFrom(

                                      foregroundColor: hasData ? Colors.red.shade700 : Colors.grey,

                                      side: BorderSide(color: hasData ? Colors.red.shade300 : Colors.grey.shade300),

                                      visualDensity: VisualDensity.compact,

                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),

                                    ),

                                    icon: const Icon(Icons.delete_sweep_rounded, size: 16),

                                    label: const Text('ล้างข้อมูลเทอมนี้', style: TextStyle(fontSize: 12)),

                                    onPressed: !hasData ? null : () => _openResetSemesterDataDialog(item),

                                  ),

                                ],

                              ),

                            );

                          },

                        ),



                      const SizedBox(height: 20),

                      // Factory Reset Section

                      Container(

                        padding: const EdgeInsets.all(16),

                        decoration: BoxDecoration(

                          color: Colors.red.shade50,

                          borderRadius: BorderRadius.circular(12),

                          border: Border.all(color: Colors.red.shade200),

                        ),

                        child: Row(

                          children: [

                            Icon(Icons.warning_rounded, color: Colors.red.shade800, size: 28),

                            const SizedBox(width: 14),

                            Expanded(

                              child: Column(

                                crossAxisAlignment: CrossAxisAlignment.start,

                                children: [

                                  Text(

                                    'พื้นที่อันตราย: รีเซ็ตข้อมูลทั้งหมดในระบบ',

                                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.shade900, fontSize: 13),

                                  ),

                                  const SizedBox(height: 2),

                                  Text(

                                    'ลบผลการเรียน รายวิชา และข้อมูลนักเรียนทั้งหมดในคลังข้อมูล (Factory Reset)',

                                    style: TextStyle(fontSize: 11, color: Colors.red.shade700),

                                  ),

                                ],

                              ),

                            ),

                            FilledButton.icon(

                              style: FilledButton.styleFrom(

                                backgroundColor: Colors.red.shade800,

                                foregroundColor: Colors.white,

                                visualDensity: VisualDensity.compact,

                              ),

                              icon: const Icon(Icons.dangerous_rounded, size: 16),

                              label: const Text('รีเซ็ตทั้งหมด', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),

                              onPressed: _openResetAllDataDialog,

                            ),

                          ],

                        ),

                      ),

                    ],

                  ),

                ),

              ),

              const SizedBox(height: 24),

              ],



              // ===============================================================

              // SECTION 3: Backend Connection Card

              // ===============================================================

              Card(

                elevation: 1,

                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

                child: Padding(

                  padding: const EdgeInsets.all(22),

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Row(

                        children: [

                          Icon(Icons.dns_outlined, color: theme.colorScheme.primary),

                          const SizedBox(width: 12),

                          Text(

                            'เซิร์ฟเวอร์ Backend (FastAPI)',

                            style: theme.textTheme.titleMedium?.copyWith(

                              fontWeight: FontWeight.bold,

                            ),

                          ),

                        ],

                      ),

                      const SizedBox(height: 16),



                      // Status indicator

                      Row(

                        children: [

                          Container(

                            width: 12,

                            height: 12,

                            decoration: BoxDecoration(

                              shape: BoxShape.circle,

                              color: _checking

                                  ? Colors.amber

                                  : _isConnected

                                      ? Colors.green

                                      : Colors.red,

                            ),

                          ),

                          const SizedBox(width: 8),

                          Text(

                            _checking

                                ? 'กำลังตรวจสอบ...'

                                : _isConnected

                                    ? 'เชื่อมต่อสำเร็จ (Online)'

                                    : 'ไม่สามารถเชื่อมต่อได้ (Offline)',

                            style: theme.textTheme.bodyLarge?.copyWith(

                              fontWeight: FontWeight.w600,

                              color: _checking

                                  ? Colors.amber.shade800

                                  : _isConnected

                                      ? Colors.green.shade700

                                      : Colors.red.shade700,

                            ),

                          ),

                        ],

                      ),

                      const SizedBox(height: 16),



                      // URL Input

                      TextField(

                        controller: _urlController,

                        decoration: const InputDecoration(

                          labelText: 'Backend API URL',

                          border: OutlineInputBorder(),

                          prefixIcon: Icon(Icons.link),

                          hintText: 'http://localhost:8000',

                        ),

                        onSubmitted: (_) => _updateUrl(),

                      ),

                      const SizedBox(height: 14),



                      Row(

                        children: [

                          FilledButton.icon(

                            onPressed: _updateUrl,

                            icon: const Icon(Icons.save),

                            label: const Text('บันทึก'),

                          ),

                          const SizedBox(width: 12),

                          OutlinedButton.icon(

                            onPressed: _checking ? null : _checkConnection,

                            icon: _checking

                                ? const SizedBox(

                                    width: 16,

                                    height: 16,

                                    child: CircularProgressIndicator(strokeWidth: 2),

                                  )

                                : const Icon(Icons.refresh),

                            label: const Text('ทดสอบการเชื่อมต่อ'),

                          ),

                        ],

                      ),

                    ],

                  ),

                ),

              ),

              const SizedBox(height: 24),



              // ===============================================================

              // SECTION 4: About Card

              // ===============================================================

              Card(

                elevation: 1,

                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

                child: Padding(

                  padding: const EdgeInsets.all(22),

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Row(

                        children: [

                          Icon(Icons.info_outline, color: theme.colorScheme.primary),

                          const SizedBox(width: 12),

                          Text(

                            'เกี่ยวกับระบบ',

                            style: theme.textTheme.titleMedium?.copyWith(

                              fontWeight: FontWeight.bold,

                            ),

                          ),

                        ],

                      ),

                      const SizedBox(height: 16),

                      _infoRow('ระบบ', 'SGS to ปพ.5 Management System'),

                      _infoRow('เวอร์ชัน', '2.0.0 (Multi-Year Dynamic Archive)'),

                      _infoRow('Frontend', 'Flutter (Windows Desktop / Web Material 3)'),

                      _infoRow('Backend', 'Python FastAPI + SQLite (school_archive.db)'),

                      _infoRow('Core Engine', 'pdfplumber + openpyxl + win32com'),

                    ],

                  ),

                ),

              ),

            ],

          ),

        ),

      ),

    );

  }



  Widget _infoRow(String label, String value) {

    return Padding(

      padding: const EdgeInsets.symmetric(vertical: 4),

      child: Row(

        crossAxisAlignment: CrossAxisAlignment.start,

        children: [

          SizedBox(

            width: 120,

            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),

          ),

          Expanded(child: Text(value)),

        ],

      ),

    );

  }



  Widget _buildAdvisorChip({

    required String label,

    required bool isAssigned,

    required ThemeData theme,

  }) {

    return Container(

      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),

      decoration: BoxDecoration(

        color: isAssigned

            ? Colors.teal.shade50

            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),

        borderRadius: BorderRadius.circular(6),

        border: Border.all(

          color: isAssigned ? Colors.teal.shade200 : theme.colorScheme.outlineVariant,

        ),

      ),

      child: Row(

        mainAxisSize: MainAxisSize.min,

        children: [

          Icon(

            isAssigned ? Icons.person_rounded : Icons.person_outline_rounded,

            size: 14,

            color: isAssigned ? Colors.teal.shade800 : Colors.grey,

          ),

          const SizedBox(width: 4),

          Text(

            label,

            style: TextStyle(

              fontSize: 12,

              fontWeight: isAssigned ? FontWeight.w600 : FontWeight.normal,

              color: isAssigned ? Colors.teal.shade900 : Colors.grey.shade600,

            ),

          ),

        ],

      ),

    );

  }



  // ===========================================================================

  // SCHOOL LOGO & IDENTITY METHODS

  // ===========================================================================

  Future<void> _loadSchoolLogoInfo() async {

    try {

      final info = await widget.apiService.getSchoolLogoInfo();
      Map<String, dynamic> pp5Info = {};
      try {
        pp5Info = await widget.apiService.getPp5LogoInfo();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _hasSchoolLogo = info['has_logo'] == true;
          _hasCustomPp5Logo = pp5Info['has_custom_pp5_logo'] == true;
          if (info['school_name'] != null) {
            String raw = info['school_name'].toString();
            raw = raw.replaceFirst(RegExp(r'^โรงเรียน\s*'), '').trim();
            _schoolNameCtrl.text = raw;
          }
          if (info['sidebar_footer_title'] != null) {
            final ft = info['sidebar_footer_title'].toString().trim();
            _sidebarFooterTitleCtrl.text = ft.isEmpty ? 'ระบบงาน ปพ.5 & ทะเบียนวัดผล' : ft;
          }
          if (info['sidebar_footer_subtitle'] != null) {
            final fs = info['sidebar_footer_subtitle'].toString().trim();
            _sidebarFooterSubtitleCtrl.text = fs.isEmpty ? 'โรงเรียน${_schoolNameCtrl.text}' : fs;
          } else {
            _sidebarFooterSubtitleCtrl.text = 'โรงเรียน${_schoolNameCtrl.text}';
          }
          if (info['web_title'] != null && info['web_title'].toString().trim().isNotEmpty) {
            _webTitleCtrl.text = info['web_title'].toString().trim();
          } else {
            _webTitleCtrl.text = 'SGS ปพ.5 Manager - โรงเรียน${_schoolNameCtrl.text.trim()}';
          }
        });
      }

    } catch (_) {}

  }



  Future<void> _pickAndUploadSchoolLogo() async {

    try {

      final pickedFiles = await FilePicker.pickFiles(

        dialogTitle: 'เลือกรูปภาพตราสัญลักษณ์ / โลโก้โรงเรียน',

        type: FileType.custom,

        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'svg'],

      );

      if (pickedFiles.isEmpty) return;

      final file = pickedFiles.first;

      final bytes = await file.readAsBytes();

      setState(() => _uploadingLogo = true);

      final res = await widget.apiService.uploadSchoolLogo(bytes, file.name);

      await _loadSchoolLogoInfo();

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.teal.shade700,

            content: Text(res['message'] ?? 'อัปโหลดโลโก้โรงเรียนสำเร็จ'),

          ),

        );

      }

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.red.shade700,

            content: Text('อัปโหลดโลโก้ไม่สำเร็จ: $e'),

          ),

        );

      }

    } finally {

      if (mounted) setState(() => _uploadingLogo = false);

    }

  }



  Future<void> _confirmDeleteSchoolLogo() async {

    final confirm = await showDialog<bool>(

      context: context,

      builder: (ctx) => AlertDialog(

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: const Row(

          children: [

            Icon(Icons.delete_outline_rounded, color: Colors.red),

            SizedBox(width: 10),

            Text('ยืนยันลบโลโก้โรงเรียน', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),

          ],

        ),

        content: const Text('คุณต้องการลบโลโก้โรงเรียนและกลับไปใช้ไอคอนเริ่มต้นหรือไม่?'),

        actions: [

          TextButton(

            onPressed: () => Navigator.of(ctx).pop(false),

            child: const Text('ยกเลิก'),

          ),

          FilledButton(

            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),

            onPressed: () => Navigator.of(ctx).pop(true),

            child: const Text('ลบโลโก้'),

          ),

        ],

      ),

    );

    if (confirm != true) return;

    try {

      final res = await widget.apiService.deleteSchoolLogo();

      await _loadSchoolLogoInfo();

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.teal.shade700,

            content: Text(res['message'] ?? 'ลบโลโก้โรงเรียนเรียบร้อยแล้ว'),

          ),

        );

      }

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.red.shade700,

            content: Text('ลบโลโก้ไม่สำเร็จ: $e'),

          ),

        );

      }

    }

  }



  Future<void> _saveSchoolNameOnly() async {
    final rawName = _schoolNameCtrl.text.replaceFirst(RegExp(r'^โรงเรียน\s*'), '').trim();
    if (rawName.isEmpty) return;
    _schoolNameCtrl.text = rawName;
    final footerTitle = _sidebarFooterTitleCtrl.text.trim().isEmpty
        ? 'ระบบงาน ปพ.5 & ทะเบียนวัดผล'
        : _sidebarFooterTitleCtrl.text.trim();
    final footerSubtitle = _sidebarFooterSubtitleCtrl.text.trim().isEmpty
        ? 'โรงเรียน$rawName'
        : _sidebarFooterSubtitleCtrl.text.trim();
    _sidebarFooterTitleCtrl.text = footerTitle;
    _sidebarFooterSubtitleCtrl.text = footerSubtitle;
    setState(() => _savingSchoolName = true);
    try {
      await widget.apiService.updateSchoolName(
        rawName,
        sidebarFooterTitle: footerTitle,
        sidebarFooterSubtitle: footerSubtitle,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.teal.shade700,
            content: Text('บันทึกชื่อสถานศึกษาและข้อความส่วนท้ายเมนูเรียบร้อยแล้ว ("$footerTitle" / "$footerSubtitle")'),
          ),
        );

      }

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.red.shade700,

            content: Text('บันทึกชื่อไม่สำเร็จ: $e'),

          ),

        );

      }

    } finally {

      if (mounted) setState(() => _savingSchoolName = false);

    }

  }



  Future<void> _saveWebTitleOnly() async {
    final title = _webTitleCtrl.text.trim();
    setState(() => _savingWebTitle = true);
    try {
      final saved = await widget.apiService.updateWebTitle(title);
      if (mounted) {
        setState(() {
          _webTitleCtrl.text = saved;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.teal.shade700,
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('บันทึกชื่อหน้าเว็บ (Browser Tab Title) เรียบร้อยแล้ว: "$saved"'),
                ),
              ],
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('บันทึกชื่อหน้าเว็บไม่สำเร็จ: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingWebTitle = false);
    }
  }

  Future<void> _loadSchoolThemeConfig() async {
    setState(() => _isLoadingTheme = true);
    try {
      final config = await widget.apiService.getSchoolTheme();
      if (mounted) {
        setState(() {
          _customThemeConfig = config;
          _menuColorHexCtrl.text = colorToHex(config.menuColor);
          _bodyColorHexCtrl.text = colorToHex(config.bodyColor);
          _primaryColorHexCtrl.text = colorToHex(config.primaryColor);
          _secondaryColorHexCtrl.text = colorToHex(config.secondaryColor);
          _isLoadingTheme = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingTheme = false);
    }
  }

  Future<void> _saveSchoolThemeConfig() async {
    final isAdmin = widget.apiService.isAdmin;
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.red,
          content: Text('สงวนสิทธิ์เฉพาะผู้ดูแลระบบ (Admin) เท่านั้นในการเปลี่ยนสีและฟอนต์ประจำโรงเรียน'),
        ),
      );
      return;
    }
    setState(() => _isSavingTheme = true);
    try {
      final saved = await widget.apiService.updateSchoolTheme(_customThemeConfig);
      if (mounted) {
        setState(() {
          _customThemeConfig = saved;
          _isSavingTheme = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF15803D),
            content: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.white),
                SizedBox(width: 8),
                Expanded(
                  child: Text('บันทึกสีและฟอนต์ประจำโรงเรียนเรียบร้อยแล้ว ทุกอุปกรณ์จะแสดงผลทันที'),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSavingTheme = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade800,
            content: Text('เกิดข้อผิดพลาดในการบันทึก: $e'),
          ),
        );
      }
    }
  }

  Future<void> _resetSchoolThemeConfig() async {
    final isAdmin = widget.apiService.isAdmin;
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.red,
          content: Text('สงวนสิทธิ์เฉพาะผู้ดูแลระบบ (Admin) เท่านั้น'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.restore_rounded, color: Color(0xFFD97706)),
            SizedBox(width: 8),
            Text('คืนค่าสีและฟอนต์เริ่มต้น?'),
          ],
        ),
        content: const Text(
          'ต้องการคืนค่าสีและฟอนต์กลับเป็นค่ามาตรฐาน (ม่วง-ทอง, Sarabun) หรือไม่?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ยืนยันรีเซ็ต'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSavingTheme = true);
    try {
      final resetConfig = await widget.apiService.resetSchoolTheme();
      if (mounted) {
        setState(() {
          _customThemeConfig = resetConfig;
          _menuColorHexCtrl.text = colorToHex(resetConfig.menuColor);
          _bodyColorHexCtrl.text = colorToHex(resetConfig.bodyColor);
          _primaryColorHexCtrl.text = colorToHex(resetConfig.primaryColor);
          _secondaryColorHexCtrl.text = colorToHex(resetConfig.secondaryColor);
          _isSavingTheme = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF15803D),
            content: Text('คืนค่าสีและฟอนต์มาตรฐานเรียบร้อยแล้ว'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSavingTheme = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade800,
            content: Text('เกิดข้อผิดพลาดในการรีเซ็ต: $e'),
          ),
        );
      }
    }
  }

  Future<void> _pickAndUploadPp5Logo() async {
    try {
      final pickedFiles = await FilePicker.pickFiles(
        dialogTitle: 'เลือกรูปภาพตราสัญลักษณ์สำหรับหน้าปก ปพ.5',
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'svg'],
      );
      if (pickedFiles.isEmpty) return;
      final file = pickedFiles.first;
      final bytes = await file.readAsBytes();
      setState(() => _uploadingPp5Logo = true);
      final res = await widget.apiService.uploadPp5Logo(bytes, file.name);
      await _loadSchoolLogoInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.teal.shade700,
            content: Text(res['message'] ?? 'อัปโหลดตรา ปพ.5 และอัปเดตแบบฟอร์มเอกสารเรียบร้อยแล้ว'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('อัปโหลดตรา ปพ.5 ไม่สำเร็จ: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingPp5Logo = false);
    }
  }

  Future<void> _confirmResetPp5Logo() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.refresh_rounded, color: Colors.indigo),
            SizedBox(width: 10),
            Text('คืนค่าตรา ปพ.5 เป็นค่าเริ่มต้น', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text('คุณต้องการยกเลิกตราเฉพาะ ปพ.5 และกลับไปใช้ตราตามโลโก้โรงเรียนบนหน้าปกเอกสาร ปพ.5 หรือไม่?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade700, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ยืนยันคืนค่าเริ่มต้น'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      setState(() => _uploadingPp5Logo = true);
      final res = await widget.apiService.resetPp5LogoToDefault();
      await _loadSchoolLogoInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.teal.shade700,
            content: Text(res['message'] ?? 'คืนค่าเริ่มต้นตรา ปพ.5 เรียบร้อยแล้ว'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('เกิดข้อผิดพลาด: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingPp5Logo = false);
    }
  }



  Widget _buildSchoolLogoSection(ThemeData theme) {

    final isAdmin = widget.apiService.isAdmin;

    return Card(

      elevation: 1,

      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

      child: Padding(

        padding: const EdgeInsets.all(22),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Row(

              children: [

                Container(

                  padding: const EdgeInsets.all(8),

                  decoration: BoxDecoration(

                    color: Colors.indigo.shade50,

                    borderRadius: BorderRadius.circular(10),

                  ),

                  child: Icon(Icons.school_rounded, color: Colors.indigo.shade800, size: 24),

                ),

                const SizedBox(width: 12),

                Expanded(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Text(

                        'ข้อมูลและโลโก้โรงเรียน (School Identity & Logo)',

                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),

                      ),

                      const SizedBox(height: 2),

                      Text(

                        'อัปโหลดตราสัญลักษณ์/โลโก้โรงเรียน เพื่อแสดงที่มุมบนซ้ายของระบบ และใช้เป็นชื่อสถานศึกษาหลัก',

                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                      ),

                    ],

                  ),

                ),

              ],

            ),

            const SizedBox(height: 18),

            Container(

              padding: const EdgeInsets.all(16),

              decoration: BoxDecoration(

                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),

                borderRadius: BorderRadius.circular(12),

                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),

              ),

              child: Row(

                crossAxisAlignment: CrossAxisAlignment.center,

                children: [

                  // Logo Preview Box

                  ValueListenableBuilder<int>(

                    valueListenable: widget.apiService.schoolLogoNotifier,

                    builder: (context, logoVer, _) {

                      return Container(

                        width: 80,

                        height: 80,

                        decoration: BoxDecoration(

                          color: Colors.white,

                          borderRadius: BorderRadius.circular(14),

                          border: Border.all(color: Colors.indigo.shade200, width: 1.5),

                          boxShadow: [

                            BoxShadow(

                              color: Colors.black.withValues(alpha: 0.05),

                              blurRadius: 6,

                              offset: const Offset(0, 2),

                            ),

                          ],

                        ),

                        clipBehavior: Clip.antiAlias,

                        child: _uploadingLogo

                            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))

                            : Image.network(

                                widget.apiService.getSchoolLogoUrl(),

                                fit: BoxFit.contain,

                                errorBuilder: (ctx, err, stack) {

                                  return Center(

                                    child: Icon(

                                      Icons.school_rounded,

                                      size: 44,

                                      color: Colors.indigo.shade300,

                                    ),

                                  );

                                },

                              ),

                      );

                    },

                  ),

                  const SizedBox(width: 18),

                  Expanded(

                    child: Column(

                      crossAxisAlignment: CrossAxisAlignment.start,

                      children: [

                        Text(

                          'ตราสัญลักษณ์ / โลโก้สถานศึกษา',

                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo.shade900),

                        ),

                        const SizedBox(height: 4),

                        Text(

                          'รองรับไฟล์รูปภาพ PNG, JPG, JPEG, WEBP หรือ SVG\nโลโก้นี้จะปรากฏที่แถบเมนูด้านบนซ้ายของทุกหน้าจอโดยอัตโนมัติ',

                          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700, height: 1.35),

                        ),

                        const SizedBox(height: 10),

                        if (isAdmin)

                          Wrap(

                            spacing: 8,

                            runSpacing: 8,

                            children: [

                                                            App3DButton.gold(
                                icon: Icons.upload_file_rounded,
                                label: _hasSchoolLogo ? 'เปลี่ยนรูปโลโก้' : 'อัปโหลดโลโก้โรงเรียน',
                                isLoading: _uploadingLogo,
                                depth: 3.0,
                                onPressed: _uploadingLogo ? null : _pickAndUploadSchoolLogo,
                              ),
                              if (_hasSchoolLogo) ...[
                                const SizedBox(width: 4),
                                App3DButton.danger(
                                  icon: Icons.delete_outline_rounded,
                                  label: 'ลบโลโก้',
                                  depth: 3.0,
                                  onPressed: _uploadingLogo ? null : _confirmDeleteSchoolLogo,
                                ),
                              ],

                            ],

                          ),

                      ],

                    ),

                  ),

                ],

              ),

            ),

            const SizedBox(height: 14),

            // PP5 Official Document Cover Emblem Section
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _hasCustomPp5Logo
                    ? Colors.blue.shade50.withValues(alpha: 0.5)
                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _hasCustomPp5Logo
                      ? Colors.blue.shade200
                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  width: _hasCustomPp5Logo ? 1.5 : 1.0,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // PP5 Emblem Preview Box
                  ValueListenableBuilder<int>(
                    valueListenable: widget.apiService.pp5LogoNotifier,
                    builder: (context, pp5Ver, _) {
                      return ValueListenableBuilder<int>(
                        valueListenable: widget.apiService.schoolLogoNotifier,
                        builder: (context, schoolVer, _) {
                          return Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: _hasCustomPp5Logo ? Colors.blue.shade300 : Colors.indigo.shade200,
                                width: 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: _uploadingPp5Logo
                                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                                : Image.network(
                                    widget.apiService.getPp5LogoUrl(),
                                    fit: BoxFit.contain,
                                    errorBuilder: (ctx, err, stack) {
                                      return Center(
                                        child: Icon(
                                          Icons.menu_book_rounded,
                                          size: 40,
                                          color: Colors.blue.shade300,
                                        ),
                                      );
                                    },
                                  ),
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'ตราสัญลักษณ์สำหรับหน้าปก ปพ.5 (Excel & PDF)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: _hasCustomPp5Logo ? Colors.blue.shade900 : Colors.indigo.shade900,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: _hasCustomPp5Logo ? Colors.blue.shade100 : Colors.teal.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: _hasCustomPp5Logo ? Colors.blue.shade300 : Colors.teal.shade200,
                                ),
                              ),
                              child: Text(
                                _hasCustomPp5Logo ? 'ตราเฉพาะ ปพ.5' : 'ใช้ตราโรงเรียน (ค่าเริ่มต้น)',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: _hasCustomPp5Logo ? Colors.blue.shade900 : Colors.teal.shade800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _hasCustomPp5Logo
                              ? 'กำลังใช้ตราเฉพาะนี้ประทับบนหน้าปก (1) ปกปพ. ในไฟล์ Excel และ PDF ทั้งหมด\nสามารถกด "คืนค่าเริ่มต้น" ได้ตลอดเวลาเพื่อให้กลับไปใช้ตราตามโลโก้โรงเรียน'
                              : 'ระบบดึงโลโก้โรงเรียนด้านบนมาใช้เป็นตราประทับบนหน้าปก (1) ปกปพ. ของไฟล์ Excel โดยอัตโนมัติ\nหากต้องการใช้ตราเฉพาะที่แตกต่างจากตราหน้าเว็บ (เช่น ตรา สพฐ., ตราครุฑ, ตราขาวดำ) สามารถอัปโหลดได้ที่นี่',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700, height: 1.35),
                        ),
                        const SizedBox(height: 10),
                        if (isAdmin)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              App3DButton.gold(
                                icon: Icons.upload_file_rounded,
                                label: _hasCustomPp5Logo ? 'เปลี่ยนตรา ปพ.5' : 'อัปโหลดตราเฉพาะ ปพ.5',
                                isLoading: _uploadingPp5Logo,
                                depth: 3.0,
                                onPressed: _uploadingPp5Logo ? null : _pickAndUploadPp5Logo,
                              ),
                              if (_hasCustomPp5Logo) ...[
                                const SizedBox(width: 4),
                                App3DButton.secondary(
                                  icon: Icons.refresh_rounded,
                                  label: 'คืนค่าเริ่มต้น (ใช้ตราโรงเรียน)',
                                  depth: 3.0,
                                  onPressed: _uploadingPp5Logo ? null : _confirmResetPp5Logo,
                                ),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // School Name Field with Save Button

            Row(

              crossAxisAlignment: CrossAxisAlignment.start,

              children: [

                Expanded(

                  child: TextFormField(
                    controller: _schoolNameCtrl,
                    enabled: isAdmin,
                    decoration: InputDecoration(
                      labelText: 'ชื่อสถานศึกษา (School Name)',
                      hintText: 'เช่น บ้านตัวอย่างวิทยา',
                      prefixIcon: const Icon(Icons.account_balance_rounded, size: 20),
                      prefixText: 'โรงเรียน ',
                      prefixStyle: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: theme.colorScheme.primary,
                      ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      filled: true,
                      fillColor: theme.colorScheme.surface,
                      helperText: 'ระบบจะนำเฉพาะส่วนที่กรอก (เช่น "บ้านตัวอย่างวิทยา") ไปใช้บนหน้าปก ปพ.5 (แสดงเป็น "โรงเรียน [ชื่อ]") และแสดงชื่อเต็ม "โรงเรียน[ชื่อ]" ที่มุมบนซ้ายของโปรแกรม',
                      helperStyle: const TextStyle(fontSize: 11),
                    ),

                    onFieldSubmitted: (_) => _saveSchoolNameOnly(),

                  ),

                ),

                if (isAdmin) ...[

                  const SizedBox(width: 10),

                  App3DButton.primary(
                    icon: Icons.save_rounded,
                    label: 'บันทึกชื่อโรงเรียน',
                    isLoading: _savingSchoolName,
                    depth: 3.5,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    onPressed: _savingSchoolName ? null : _saveSchoolNameOnly,
                  ),

                ],

              ],

            ),

            const SizedBox(height: 18),

            // Sidebar Footer Title & Subtitle Section ("ระบบงาน ปพ.5 & ทะเบียนวัดผล" / "โรงเรียน...")
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.indigo.shade100, width: 1.2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.branding_watermark_rounded, size: 20, color: Color(0xFF2D124D)),
                      const SizedBox(width: 8),
                      Text(
                        'ข้อความส่วนท้ายแถบเมนูด้านซ้าย (Sidebar Footer Text)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                          color: Colors.indigo.shade900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'กำหนดข้อความ 2 บรรทัดที่แสดงบริเวณมุมล่างซ้ายของแถบเมนูหลัก',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Live Dark Purple Sidebar Footer Preview
                      Container(
                        width: 220,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: AppColors.purpleDark,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.gold.withValues(alpha: 0.5), width: 1.2),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'ตัวอย่างการแสดงผลมุมล่างซ้าย',
                              style: TextStyle(
                                fontSize: 9.5,
                                color: Colors.white.withValues(alpha: 0.45),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: AppColors.gold.withValues(alpha: 0.25),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _sidebarFooterTitleCtrl.text.trim().isEmpty
                                  ? 'ระบบงาน ปพ.5 & ทะเบียนวัดผล'
                                  : _sidebarFooterTitleCtrl.text.trim(),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: 'Sarabun',
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.gold.withValues(alpha: 0.85),
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _sidebarFooterSubtitleCtrl.text.trim().isEmpty
                                  ? 'โรงเรียน${_schoolNameCtrl.text.trim()}'
                                  : _sidebarFooterSubtitleCtrl.text.trim(),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: 'Sarabun',
                                fontSize: 10,
                                color: Colors.white.withValues(alpha: 0.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      // Input Fields for Line 1 & Line 2
                      Expanded(
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _sidebarFooterTitleCtrl,
                              enabled: isAdmin,
                              decoration: InputDecoration(
                                labelText: 'ข้อความบรรทัดที่ 1 (ตัวอักษรสีทอง)',
                                hintText: 'ระบบงาน ปพ.5 & ทะเบียนวัดผล',
                                prefixIcon: const Icon(Icons.title_rounded, size: 18),
                                border: const OutlineInputBorder(),
                                isDense: true,
                                filled: true,
                                fillColor: theme.colorScheme.surface,
                              ),
                              onChanged: (_) => setState(() {}),
                              onFieldSubmitted: (_) => _saveSchoolNameOnly(),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _sidebarFooterSubtitleCtrl,
                                    enabled: isAdmin,
                                    decoration: InputDecoration(
                                      labelText: 'ข้อความบรรทัดที่ 2 (ชื่อโรงเรียน/หน่วยงานด้านล่าง)',
                                      hintText: 'เช่น โรงเรียนบ้านตัวอย่างวิทยา',
                                      prefixIcon: const Icon(Icons.subtitles_outlined, size: 18),
                                      border: const OutlineInputBorder(),
                                      isDense: true,
                                      filled: true,
                                      fillColor: theme.colorScheme.surface,
                                    ),
                                    onChanged: (_) => setState(() {}),
                                    onFieldSubmitted: (_) => _saveSchoolNameOnly(),
                                  ),
                                ),
                                if (isAdmin) ...[
                                  const SizedBox(width: 10),
                                  App3DButton.gold(
                                    icon: Icons.save_rounded,
                                    label: 'บันทึกข้อความส่วนท้าย',
                                    isLoading: _savingSchoolName,
                                    depth: 3.0,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                                    onPressed: _savingSchoolName ? null : _saveSchoolNameOnly,
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // Browser Tab / Web Title Section ("ชื่อหน้าเว็บ / ข้อความบนแท็บบราวเซอร์")
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blueGrey.shade100, width: 1.2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.indigo.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.tab_rounded, size: 20, color: Colors.indigo.shade800),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ชื่อหน้าเว็บ / ข้อความบนแท็บบราวเซอร์ (Browser Tab Title)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13.5,
                                color: Colors.indigo.shade900,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'กำหนดชื่อหรือข้อความที่ปรากฏบนแท็บของ Web Browser (Title Bar) ขณะเปิดใช้งานระบบ',
                              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isNarrow = constraints.maxWidth < 650;

                      // Browser Tab Preview Box
                      final previewBox = Container(
                        width: isNarrow ? double.infinity : 260,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.blueGrey.shade200, width: 1.2),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle)),
                                const SizedBox(width: 4),
                                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle)),
                                const SizedBox(width: 4),
                                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle)),
                                const SizedBox(width: 10),
                                Text(
                                  'ตัวอย่างแท็บเบราว์เซอร์',
                                  style: TextStyle(fontSize: 10, color: Colors.blueGrey.shade600),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 1)),
                                ],
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.public, size: 14, color: Colors.indigo.shade700),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _webTitleCtrl.text.trim().isEmpty
                                          ? 'SGS ปพ.5 Manager - โรงเรียน${_schoolNameCtrl.text.trim()}'
                                          : _webTitleCtrl.text.trim(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: 'Sarabun',
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.close_rounded, size: 12, color: Colors.grey.shade500),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );

                      // Input and Buttons
                      final inputFields = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFormField(
                            controller: _webTitleCtrl,
                            enabled: isAdmin,
                            decoration: InputDecoration(
                              labelText: 'ชื่อหน้าเว็บ (Web Page Title)',
                              hintText: 'เช่น โรงเรียนบ้านตัวอย่างวิทยา ระบบบันทึกเวลาเรียน',
                              prefixIcon: const Icon(Icons.language_rounded, size: 18),
                              border: const OutlineInputBorder(),
                              isDense: true,
                              filled: true,
                              fillColor: theme.colorScheme.surface,
                              helperText: 'ระบบจะนำข้อความนี้ไปตั้งเป็น Document Title บนเบราว์เซอร์ทันที และบันทึกไว้ใช้งานถาวร',
                              helperStyle: const TextStyle(fontSize: 11),
                            ),
                            onChanged: (_) => setState(() {}),
                            onFieldSubmitted: (_) => _saveWebTitleOnly(),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (isAdmin) ...[
                                App3DButton.primary(
                                  icon: Icons.save_rounded,
                                  label: 'บันทึกชื่อหน้าเว็บ',
                                  isLoading: _savingWebTitle,
                                  depth: 3.0,
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                                  onPressed: _savingWebTitle ? null : _saveWebTitleOnly,
                                ),
                                App3DButton.secondary(
                                  icon: Icons.restart_alt_rounded,
                                  label: 'คืนค่าตามชื่อโรงเรียน',
                                  depth: 2.5,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                                  onPressed: _savingWebTitle
                                      ? null
                                      : () {
                                          setState(() {
                                            _webTitleCtrl.text = 'SGS ปพ.5 Manager - โรงเรียน${_schoolNameCtrl.text.trim()}';
                                          });
                                          _saveWebTitleOnly();
                                        },
                                ),
                              ],
                            ],
                          ),
                        ],
                      );

                      if (isNarrow) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            previewBox,
                            const SizedBox(height: 12),
                            inputFields,
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          previewBox,
                          const SizedBox(width: 16),
                          Expanded(child: inputFields),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],

        ),

      ),

    );

  }



  // ===============================================================
  // SECTION 3.5: School Theme, Colors & Fonts (Branding & Appearance)
  // ===============================================================
  Widget _buildSchoolThemeSection(ThemeData theme) {
    final isAdmin = widget.apiService.isAdmin;
    final font = _customThemeConfig.fontFamily;
    final primary = _customThemeConfig.primaryColor;
    final secondary = _customThemeConfig.secondaryColor;

    if (_isLoadingTheme) {
      return Card(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: primary),
                ),
                const SizedBox(width: 12),
                Text('กำลังโหลดการตั้งค่าสีและฟอนต์...', style: TextStyle(fontFamily: font, fontSize: 13)),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: secondary.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with Icon, Title, and Reset Button
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: secondary, width: 1.2),
                  ),
                  child: Icon(Icons.palette_rounded, color: primary, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ปรับแต่งธีม สีประจำโรงเรียน & รูปแบบฟอนต์ (Branding & Appearance)',
                        style: TextStyle(
                          fontFamily: font,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ปรับแต่งสีแถบเมนู สีพื้นหลังบอดี้ สีหลัก และสีรอง พร้อมเลือกฟอนต์ภาษาไทย 6 สไตล์ ให้ตรงตามอัตลักษณ์โรงเรียนของคุณ ทุกอุปกรณ์จะแสดงผลตามที่ตั้งค่าไว้อัตโนมัติ',
                        style: TextStyle(
                          fontFamily: font,
                          fontSize: 13,
                          color: Colors.grey.shade700,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isAdmin) ...[
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _isSavingTheme ? null : _resetSchoolThemeConfig,
                    icon: const Icon(Icons.restore_rounded, size: 16),
                    label: Text(
                      'คืนค่าเริ่มต้น',
                      style: TextStyle(fontFamily: font, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFB45309),
                      side: const BorderSide(color: Color(0xFFD97706), width: 1.2),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 20),
            Divider(height: 1, thickness: 1, color: secondary.withValues(alpha: 0.25)),
            const SizedBox(height: 20),

            // Live Sandbox Mockup Preview
            _buildThemeLivePreview(_customThemeConfig),

            const SizedBox(height: 26),

            // Section 1: Popular School Presets
            Text(
              '1. หรือเลือกจาก 8 ชุดสีคู่ประจำโรงเรียนยอดนิยม',
              style: TextStyle(
                fontFamily: font,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'คลิกเลือกชุดสีเพื่อนำไปใช้งานทันที หรือนำไปเป็นต้นแบบแล้วปรับแต่งเฉดสีเพิ่มเติมด้านล่าง',
              style: TextStyle(fontFamily: font, fontSize: 12.5, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            _buildPresetPaletteCards(_customThemeConfig),

            const SizedBox(height: 26),

            // Section 2: Detailed Color Pickers with Scale Swatches
            Text(
              '2. กำหนดสีและสเกลเฉดสีอย่างละเอียด (Color Scales)',
              style: TextStyle(
                fontFamily: font,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'เลือกสีแถบเมนู พื้นหลังบอดี้ สีหลัก และสีรอง โดยคลิกเลือกเฉดสีจากสเกล 10 ระดับ หรือพิมพ์รหัสสี HEX ตามต้องการ',
              style: TextStyle(fontFamily: font, fontSize: 12.5, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 14),

            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 900;
                final pickers = [
                  _buildColorScalePicker(
                    title: 'สีแถบเมนู (Sidebar Menu)',
                    subtitle: 'สีพื้นหลังของแถบเมนูด้านข้าง และ AppBar บนมือถือ',
                    currentColor: _customThemeConfig.menuColor,
                    hexCtrl: _menuColorHexCtrl,
                    swatches: SchoolThemeConfig.menuScaleSwatches,
                    onColorChanged: (c) {
                      setState(() {
                        _customThemeConfig = _customThemeConfig.copyWith(menuColor: c);
                        _menuColorHexCtrl.text = colorToHex(c);
                      });
                    },
                    fontFamily: font,
                  ),
                  _buildColorScalePicker(
                    title: 'สีพื้นหลังบอดี้ (Body Canvas)',
                    subtitle: 'สีพื้นหลังหลักของหน้าเว็บและแอปพลิเคชัน',
                    currentColor: _customThemeConfig.bodyColor,
                    hexCtrl: _bodyColorHexCtrl,
                    swatches: SchoolThemeConfig.bodyScaleSwatches,
                    onColorChanged: (c) {
                      setState(() {
                        _customThemeConfig = _customThemeConfig.copyWith(bodyColor: c);
                        _bodyColorHexCtrl.text = colorToHex(c);
                      });
                    },
                    fontFamily: font,
                  ),
                  _buildColorScalePicker(
                    title: 'สีหลัก / ปุ่มกด (Primary Accent)',
                    subtitle: 'สีของปุ่มกดหลัก เมนูที่เลือก และหัวข้อสำคัญ',
                    currentColor: _customThemeConfig.primaryColor,
                    hexCtrl: _primaryColorHexCtrl,
                    swatches: SchoolThemeConfig.primaryScaleSwatches,
                    onColorChanged: (c) {
                      setState(() {
                        _customThemeConfig = _customThemeConfig.copyWith(primaryColor: c);
                        _primaryColorHexCtrl.text = colorToHex(c);
                      });
                    },
                    fontFamily: font,
                  ),
                  _buildColorScalePicker(
                    title: 'สีรอง / ขอบ & ไฮไลต์ (Secondary Trim)',
                    subtitle: 'สีตัดขอบทอง สัญลักษณ์ตรา และไฮไลต์ปุ่ม',
                    currentColor: _customThemeConfig.secondaryColor,
                    hexCtrl: _secondaryColorHexCtrl,
                    swatches: SchoolThemeConfig.secondaryScaleSwatches,
                    onColorChanged: (c) {
                      setState(() {
                        _customThemeConfig = _customThemeConfig.copyWith(secondaryColor: c);
                        _secondaryColorHexCtrl.text = colorToHex(c);
                      });
                    },
                    fontFamily: font,
                  ),
                ];

                if (isWide) {
                  return Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: pickers[0]),
                          const SizedBox(width: 16),
                          Expanded(child: pickers[1]),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: pickers[2]),
                          const SizedBox(width: 16),
                          Expanded(child: pickers[3]),
                        ],
                      ),
                    ],
                  );
                } else {
                  return Column(
                    children: pickers
                        .map((p) => Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: p,
                            ))
                        .toList(),
                  );
                }
              },
            ),

            const SizedBox(height: 26),

            // Section 3: 6 Thai Google Fonts Selector
            Text(
              '3. เลือกรูปแบบตัวอักษรภาษาไทย (6 ฟอนต์ Google Fonts มาตรฐาน)',
              style: TextStyle(
                fontFamily: font,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'ฟอนต์รองรับภาษาไทย 100% ป้องกันสระลอย/วรรณยุกต์ตัดทอน สามารถคลิกเลือกเพื่อดูตัวอย่างทันที',
              style: TextStyle(fontFamily: font, fontSize: 12.5, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 14),
            _buildFontSelectorCards(_customThemeConfig),

            const SizedBox(height: 28),
            Divider(height: 1, thickness: 1, color: secondary.withValues(alpha: 0.25)),
            const SizedBox(height: 20),

            // Save Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!isAdmin) ...[
                  const Icon(Icons.info_outline, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text(
                    'เข้าสู่ระบบเป็นผู้ดูแลระบบ (Admin) เพื่อบันทึกการเปลี่ยนสีและฟอนต์',
                    style: TextStyle(fontFamily: font, fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(width: 16),
                ],
                ElevatedButton.icon(
                  onPressed: (!isAdmin || _isSavingTheme) ? null : _saveSchoolThemeConfig,
                  icon: _isSavingTheme
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save_rounded, size: 18),
                  label: Text(
                    _isSavingTheme ? 'กำลังบันทึกธีม...' : 'บันทึกสีและฟอนต์ประจำโรงเรียน',
                    style: TextStyle(
                      fontFamily: font,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    side: BorderSide(color: secondary, width: 1.4),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeLivePreview(SchoolThemeConfig config) {
    final font = config.fontFamily;
    final menu = config.menuColor;
    final body = config.bodyColor;
    final primary = config.primaryColor;
    final secondary = config.secondaryColor;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: secondary, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Browser Window Chrome Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: const Color(0xFF0F172A),
            child: Row(
              children: [
                Row(
                  children: const [
                    CircleAvatar(radius: 5, backgroundColor: Color(0xFFEF4444)),
                    SizedBox(width: 6),
                    CircleAvatar(radius: 5, backgroundColor: Color(0xFFF59E0B)),
                    SizedBox(width: 6),
                    CircleAvatar(radius: 5, backgroundColor: Color(0xFF10B981)),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'ตัวอย่างการแสดงผลเสมือนจริง (Live Preview)  •  ฟอนต์: $font',
                      style: TextStyle(
                        fontFamily: font,
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: secondary, width: 0.8),
                  ),
                  child: Text(
                    'เรียลไทม์',
                    style: TextStyle(fontFamily: font, fontSize: 10, color: secondary, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),

          // App Canvas Body
          SizedBox(
            height: 190,
            child: Row(
              children: [
                // Mini Sidebar
                Container(
                  width: 95,
                  color: menu,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  child: Column(
                    children: [
                      // Mini Logo
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: secondary, width: 1.2),
                        ),
                        child: Icon(Icons.school, size: 18, color: primary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'แถบเมนู',
                        style: TextStyle(fontFamily: font, fontSize: 9.5, color: secondary, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      // Mini Selected Item
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                        decoration: BoxDecoration(
                          color: primary,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: secondary, width: 1),
                        ),
                        child: Row(
                          children: [
                            Container(width: 2.5, height: 12, color: secondary),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                'แดชบอร์ด',
                                style: TextStyle(fontFamily: font, fontSize: 9.5, color: secondary, fontWeight: FontWeight.bold),
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 5),
                      // Mini Unselected Item
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Text(
                          'เช็คเวลาเรียน',
                          style: TextStyle(fontFamily: font, fontSize: 9, color: Colors.white70),
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Text(
                          'บันทึกคะแนน',
                          style: TextStyle(fontFamily: font, fontSize: 9, color: Colors.white70),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),

                // Main Content Body in Sample Colors
                Expanded(
                  child: Container(
                    color: body,
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Sample Card
                        Expanded(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: secondary, width: 1.2),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.auto_stories, size: 16, color: primary),
                                    const SizedBox(width: 6),
                                    Text(
                                      'ระบบงาน ปพ.5 บันทึกคะแนนและเวลาเรียน 100 วัน',
                                      style: TextStyle(
                                        fontFamily: font,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.bold,
                                        color: primary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'ทดสอบฟอนต์ $font: ที่นี่ คุณครูผู้สอน ปู่ ย่า นักเรียนชาย-หญิง | ตัวเลข 0 1 2 3 4 5 6 7 8 9',
                                  style: TextStyle(
                                    fontFamily: font,
                                    fontSize: 11,
                                    color: const Color(0xFF334155),
                                    height: 1.4,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const Spacer(),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: primary,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: secondary, width: 1),
                                      ),
                                      child: Text(
                                        'ปุ่มสีหลัก',
                                        style: TextStyle(fontFamily: font, fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: secondary, width: 1.2),
                                      ),
                                      child: Text(
                                        'ปุ่มสีรอง',
                                        style: TextStyle(fontFamily: font, fontSize: 10, color: primary, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: secondary.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: secondary, width: 0.8),
                                      ),
                                      child: Text(
                                        'เกรดเฉลี่ย 4.00',
                                        style: TextStyle(fontFamily: font, fontSize: 10, color: primary, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetPaletteCards(SchoolThemeConfig config) {
    final font = config.fontFamily;

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: SchoolThemeConfig.popularPresets.map((preset) {
        final isSelected = config.menuColor == preset.config.menuColor &&
            config.bodyColor == preset.config.bodyColor &&
            config.primaryColor == preset.config.primaryColor &&
            config.secondaryColor == preset.config.secondaryColor;

        return InkWell(
          onTap: () {
            setState(() {
              _customThemeConfig = preset.config.copyWith(fontFamily: _customThemeConfig.fontFamily);
              _menuColorHexCtrl.text = colorToHex(preset.config.menuColor);
              _bodyColorHexCtrl.text = colorToHex(preset.config.bodyColor);
              _primaryColorHexCtrl.text = colorToHex(preset.config.primaryColor);
              _secondaryColorHexCtrl.text = colorToHex(preset.config.secondaryColor);
            });
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 175,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isSelected ? preset.config.primaryColor.withValues(alpha: 0.08) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? preset.config.secondaryColor : Colors.grey.shade300,
                width: isSelected ? 2.0 : 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: isSelected
                      ? preset.config.primaryColor.withValues(alpha: 0.15)
                      : Colors.black.withValues(alpha: 0.03),
                  blurRadius: isSelected ? 6 : 3,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _buildMiniColorDot(preset.config.menuColor, 'เมนู: ${colorToHex(preset.config.menuColor)}'),
                    const SizedBox(width: 4),
                    _buildMiniColorDot(preset.config.bodyColor, 'พื้นหลัง: ${colorToHex(preset.config.bodyColor)}'),
                    const SizedBox(width: 4),
                    _buildMiniColorDot(preset.config.primaryColor, 'สีหลัก: ${colorToHex(preset.config.primaryColor)}'),
                    const SizedBox(width: 4),
                    _buildMiniColorDot(preset.config.secondaryColor, 'สีรอง: ${colorToHex(preset.config.secondaryColor)}'),
                    const Spacer(),
                    if (isSelected)
                      Icon(Icons.check_circle_rounded, size: 16, color: preset.config.secondaryColor),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  preset.name,
                  style: TextStyle(
                    fontFamily: font,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    color: isSelected ? preset.config.primaryColor : const Color(0xFF1E293B),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  preset.description,
                  style: TextStyle(
                    fontFamily: font,
                    fontSize: 10.5,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMiniColorDot(Color color, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black26, width: 0.8),
        ),
      ),
    );
  }

  Widget _buildColorScalePicker({
    required String title,
    required String subtitle,
    required Color currentColor,
    required TextEditingController hexCtrl,
    required List<Color> swatches,
    required ValueChanged<Color> onColorChanged,
    required String fontFamily,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: currentColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black26, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: currentColor.withValues(alpha: 0.35),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              // Hex input field
              SizedBox(
                width: 95,
                height: 34,
                child: TextField(
                  controller: hexCtrl,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  onSubmitted: (val) {
                    final color = hexToColor(val);
                    if (color != null) onColorChanged(color);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'สเกลเฉดสีให้เลือก (คลิกเลือกเฉดที่ต้องการ):',
            style: TextStyle(fontFamily: fontFamily, fontSize: 11, color: Colors.grey.shade700, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
  runSpacing: 6,
  children: swatches.map((swatch) {
                final isSelected = currentColor == swatch;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () => onColorChanged(swatch),
                    borderRadius: BorderRadius.circular(6),
                    child: Tooltip(
                      message: colorToHex(swatch),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: swatch,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isSelected ? Colors.black : Colors.black26,
                            width: isSelected ? 2.2 : 0.8,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: swatch.withValues(alpha: 0.5),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: isSelected
                            ? Center(
                                child: Icon(
                                  Icons.check,
                                  size: 14,
                                  color: swatch.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                );
              }).toList(),
),
        ],
      ),
    );
  }

  Widget _buildFontSelectorCards(SchoolThemeConfig config) {
    final currentFont = config.fontFamily;
    final primary = config.primaryColor;
    final secondary = config.secondaryColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 750;
        final fontItems = SchoolThemeConfig.availableFonts.map((fontInfo) {
          final isSelected = currentFont == fontInfo.family;

          return InkWell(
            onTap: () {
              setState(() {
                _customThemeConfig = _customThemeConfig.copyWith(fontFamily: fontInfo.family);
              });
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isSelected ? primary.withValues(alpha: 0.07) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? secondary : Colors.grey.shade300,
                  width: isSelected ? 2.2 : 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isSelected ? primary.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.03),
                    blurRadius: isSelected ? 6 : 3,
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
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isSelected ? primary : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          fontInfo.name,
                          style: TextStyle(
                            fontFamily: fontInfo.family,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isSelected ? secondary.withValues(alpha: 0.2) : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          fontInfo.description,
                          style: TextStyle(
                            fontFamily: fontInfo.family,
                            fontSize: 11,
                            color: isSelected ? primary : Colors.grey.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                        color: isSelected ? secondary : Colors.grey.shade400,
                        size: 22,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    fontInfo.sampleText,
                    style: TextStyle(
                      fontFamily: fontInfo.family,
                      fontSize: 15.5,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF0F172A),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'กขฃคฅฆงจฉชซฌญฎฏฐฑฒณดตถทธนบปผฝพฟภมยรลวศษสหฬอฮ • 0123456789 (๑๒๓๔๕)',
                    style: TextStyle(
                      fontFamily: fontInfo.family,
                      fontSize: 12,
                      color: Colors.blueGrey.shade700,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList();

        if (isWide) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: fontItems[0]),
                  const SizedBox(width: 12),
                  Expanded(child: fontItems[1]),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: fontItems[2]),
                  const SizedBox(width: 12),
                  Expanded(child: fontItems[3]),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: fontItems[4]),
                  const SizedBox(width: 12),
                  Expanded(child: fontItems[5]),
                ],
              ),
            ],
          );
        } else {
          return Column(
            children: fontItems
                .map((item) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: item,
                    ))
                .toList(),
          );
        }
      },
    );
  }

  Widget _buildSignatoriesSection(ThemeData theme) {

    final isAdmin = widget.apiService.isAdmin;

    return Card(

      elevation: 1,

      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

      child: Padding(

        padding: const EdgeInsets.all(22),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Row(

              crossAxisAlignment: CrossAxisAlignment.start,

              children: [

                Container(

                  padding: const EdgeInsets.all(8),

                  decoration: BoxDecoration(

                    color: Colors.indigo.shade100.withValues(alpha: 0.6),

                    borderRadius: BorderRadius.circular(10),

                  ),

                  child: Icon(Icons.verified_user_rounded, color: Colors.indigo.shade800, size: 24),

                ),

                const SizedBox(width: 12),

                Expanded(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Text(

                        'ข้อมูลผู้ลงนามและผู้บริหาร หน้าปก ปพ.5 (Signatories & School Authorities)',

                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),

                      ),

                      const SizedBox(height: 2),

                      Text(

                        'กำหนดชื่อและตำแหน่งผู้อำนวยการ, หัวหน้างานวิชาการ, งานทะเบียน-วัดผล และหัวหน้ากลุ่มสาระฯ ในแต่ละปีการศึกษา',

                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                      ),

                    ],

                  ),

                ),

              ],

            ),

            const SizedBox(height: 18),



            // Year selector & Actions Bar

            Container(

              padding: const EdgeInsets.all(12),

              decoration: BoxDecoration(

                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),

                borderRadius: BorderRadius.circular(12),

                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),

              ),

              child: Wrap(

                spacing: 10,

                runSpacing: 10,

                alignment: WrapAlignment.spaceBetween,

                crossAxisAlignment: WrapCrossAlignment.center,

                children: [

                  Row(

                    mainAxisSize: MainAxisSize.min,

                    children: [

                      const Text('ปีการศึกษา: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),

                      const SizedBox(width: 6),

                      if (_availableSignatoryYears.isNotEmpty)

                        DropdownButton<String>(

                          value: _availableSignatoryYears.contains(_selectedSignatoryYear)

                              ? _selectedSignatoryYear

                              : _availableSignatoryYears.first,

                          underline: const SizedBox(),

                          borderRadius: BorderRadius.circular(10),

                          items: _availableSignatoryYears.map((y) {

                            return DropdownMenuItem(

                              value: y,

                              child: Text(

                                'ปีการศึกษา $y',

                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),

                              ),

                            );

                          }).toList(),

                          onChanged: (val) {

                            if (val != null) {

                              setState(() => _selectedSignatoryYear = val);

                              _loadSignatories(year: val);

                            }

                          },

                        ),

                    ],

                  ),

                  Wrap(

                    spacing: 8,

                    runSpacing: 8,

                    children: [

                      if (isAdmin) ...[

                        OutlinedButton.icon(

                          icon: const Icon(Icons.add, size: 16),

                          label: const Text('เพิ่มปีใหม่', style: TextStyle(fontSize: 12)),

                          onPressed: _openAddNewSignatoryYearDialog,

                        ),

                        OutlinedButton.icon(

                          icon: const Icon(Icons.copy_rounded, size: 16),

                          label: const Text('คัดลอกข้อมูลจากปีอื่น', style: TextStyle(fontSize: 12)),

                          onPressed: _openCopySignatoriesDialog,

                        ),

                      ],

                      IconButton(

                        tooltip: 'โหลดข้อมูลใหม่',

                        icon: const Icon(Icons.refresh_rounded, size: 20),

                        onPressed: () => _loadSignatories(year: _selectedSignatoryYear),

                      ),

                    ],

                  ),

                ],

              ),

            ),

            const SizedBox(height: 18),



            if (_loadingSignatories)

              const Center(

                child: Padding(

                  padding: EdgeInsets.all(24),

                  child: CircularProgressIndicator(),

                ),

              )

            else if (_signatoriesError != null)

              Container(

                padding: const EdgeInsets.all(12),

                decoration: BoxDecoration(

                  color: Colors.red.shade50,

                  borderRadius: BorderRadius.circular(8),

                ),

                child: Row(

                  children: [

                    Icon(Icons.error_outline, color: Colors.red.shade700),

                    const SizedBox(width: 8),

                    Expanded(child: Text('เกิดข้อผิดพลาด: $_signatoriesError')),

                    TextButton(

                      onPressed: () => _loadSignatories(year: _selectedSignatoryYear),

                      child: const Text('ลองใหม่'),

                    ),

                  ],

                ),

              )

            else

              Column(

                crossAxisAlignment: CrossAxisAlignment.start,

                children: [

                  // Section: ผู้อำนวยการโรงเรียน

                  _buildSignatoryInputField(

                    label: 'ผู้อำนวยการโรงเรียน (School Director)',

                    icon: Icons.account_balance_rounded,

                    nameController: _directorNameCtrl,

                    titleController: _directorTitleCtrl,

                    nameHint: 'นาย... / นาง...',

                    titleHint: 'เช่น ผู้อำนวยการโรงเรียนบ้านตัวอย่างวิทยา',

                    theme: theme,

                  ),

                  const SizedBox(height: 14),



                  // Section: หัวหน้างานวิชาการ

                  _buildSignatoryInputField(

                    label: 'หัวหน้างานวิชาการ (Academic Affairs Head)',

                    icon: Icons.menu_book_rounded,

                    nameController: _academicNameCtrl,

                    titleController: _academicTitleCtrl,

                    nameHint: 'นาย... / นางสาว...',

                    titleHint: 'หัวหน้างานวิชาการ',

                    theme: theme,

                  ),

                  const SizedBox(height: 14),



                  // Section: งานทะเบียน-วัดผล

                  _buildSignatoryInputField(

                    label: 'งานทะเบียน-วัดผล (Registrar & Measurement)',

                    icon: Icons.badge_rounded,

                    nameController: _registrarNameCtrl,

                    titleController: _registrarTitleCtrl,

                    nameHint: 'นาย... / นางสาว...',

                    titleHint: 'งานทะเบียน-วัดผล',

                    theme: theme,

                  ),

                  const SizedBox(height: 14),



                  // Section: หัวหน้ากลุ่มสาระการเรียนรู้

                  Container(

                    padding: const EdgeInsets.all(16),

                    decoration: BoxDecoration(

                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),

                      borderRadius: BorderRadius.circular(12),

                      border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),

                    ),

                    child: Column(

                      crossAxisAlignment: CrossAxisAlignment.start,

                      children: [

                        Row(

                          children: [

                            Icon(Icons.diversity_3_rounded, size: 20, color: theme.colorScheme.primary),

                            const SizedBox(width: 8),

                            const Text(

                              'หัวหน้ากลุ่มสาระการเรียนรู้ (Department Heads)',

                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),

                            ),

                          ],

                        ),

                        const SizedBox(height: 10),

                        Row(

                          children: [

                            Expanded(

                              flex: 3,

                              child: TextField(

                                controller: _deptHeadDefaultCtrl,

                                decoration: InputDecoration(

                                  labelText: 'หัวหน้ากลุ่มสาระฯ (ค่าเริ่มต้นทั่วไปทุกวิชา)',

                                  hintText: 'นางสาว... / นาย...',

                                  border: const OutlineInputBorder(),

                                  isDense: true,

                                  suffixIcon: IconButton(

                                    tooltip: 'เลือกจากทำเนียบครู',

                                    icon: const Icon(Icons.person_search_rounded, size: 20),

                                    onPressed: () => _pickTeacherForController(_deptHeadDefaultCtrl, 'หัวหน้ากลุ่มสาระฯ ทั่วไป'),

                                  ),

                                ),

                              ),

                            ),

                            const SizedBox(width: 12),

                            OutlinedButton.icon(

                              icon: Icon(_expandDeptHeads ? Icons.expand_less_rounded : Icons.expand_more_rounded),

                              label: Text(_expandDeptHeads ? 'ซ่อนการแยกกลุ่มสาระ' : 'กำหนดแยกตาม 8 กลุ่มสาระฯ'),

                              onPressed: () => setState(() => _expandDeptHeads = !_expandDeptHeads),

                            ),

                          ],

                        ),



                        if (_expandDeptHeads) ...[

                          const SizedBox(height: 14),

                          const Divider(),

                          const SizedBox(height: 8),

                          Text(

                            'ระบุชื่อหัวหน้ากลุ่มสาระเฉพาะวิชา (หากเว้นว่างไว้ ระบบจะใช้ค่าเริ่มต้นทั่วไปด้านบน):',

                            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                          ),

                          const SizedBox(height: 12),

                          LayoutBuilder(

                            builder: (ctx, constraints) {

                              final isNarrow = constraints.maxWidth < 600;

                              return Wrap(

                                spacing: 12,

                                runSpacing: 12,

                                children: kStandardDepartments.map((dept) {

                                  final ctrl = _deptHeadsCtrls[dept]!;

                                  return SizedBox(

                                    width: isNarrow ? constraints.maxWidth : (constraints.maxWidth - 12) / 2,

                                    child: TextField(

                                      controller: ctrl,

                                      decoration: InputDecoration(

                                        labelText: 'กลุ่มสาระฯ $dept',

                                        hintText: 'เลือกหรือพิมพ์ชื่อครู...',

                                        border: const OutlineInputBorder(),

                                        isDense: true,

                                        suffixIcon: IconButton(

                                          tooltip: 'เลือกจากทำเนียบครู',

                                          icon: const Icon(Icons.person_search_rounded, size: 18),

                                          onPressed: () => _pickTeacherForController(ctrl, 'กลุ่มสาระฯ $dept'),

                                        ),

                                      ),

                                    ),

                                  );

                                }).toList(),

                              );

                            },

                          ),

                        ],

                      ],

                    ),

                  ),

                  const SizedBox(height: 14),



                  // School Name

                  TextField(
                    controller: _schoolNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'ชื่อสถานศึกษา (บนหน้าปก ปพ.5)',
                      hintText: 'เช่น บ้านตัวอย่างวิทยา',
                      prefixText: 'โรงเรียน ',
                      prefixStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.school_rounded),
                      isDense: true,
                      helperText: 'กรอกเฉพาะชื่อสถานศึกษา เช่น "บ้านตัวอย่างวิทยา"',
                    ),

                  ),

                  const SizedBox(height: 18),



                  // Bottom action bar

                  Wrap(

                    spacing: 12,

                    runSpacing: 10,

                    alignment: WrapAlignment.spaceBetween,

                    crossAxisAlignment: WrapCrossAlignment.center,

                    children: [

                      Row(

                        mainAxisSize: MainAxisSize.min,

                        children: [

                          Checkbox(

                            value: _syncExistingSignatoryFiles,

                            onChanged: (val) => setState(() => _syncExistingSignatoryFiles = val ?? true),

                          ),

                          const Text(

                            'อัปเดตไฟล์ Excel และ PDF ปพ.5 ที่มีอยู่ของปีนี้ทันที',

                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),

                          ),

                        ],

                      ),

                      if (isAdmin)

                                                App3DButton.primary(
                          icon: Icons.save_rounded,
                          label: _savingSignatories ? 'กำลังบันทึกและซิงค์...' : 'บันทึกข้อมูลปีการศึกษา $_selectedSignatoryYear',
                          isLoading: _savingSignatories,
                          depth: 3.5,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          onPressed: _savingSignatories ? null : _saveSignatories,
                        ),

                    ],

                  ),

                ],

              ),

          ],

        ),

      ),

    );

  }



  Widget _buildSignatoryInputField({

    required String label,

    required IconData icon,

    required TextEditingController nameController,

    required TextEditingController titleController,

    required String nameHint,

    required String titleHint,

    required ThemeData theme,

  }) {

    final isAdmin = widget.apiService.isAdmin;

    return LayoutBuilder(

      builder: (ctx, constraints) {

        final isNarrow = constraints.maxWidth < 600;

        final nameField = TextField(

          controller: nameController,

          enabled: isAdmin,

          decoration: InputDecoration(

            labelText: 'ชื่อ-สกุล $label',

            hintText: nameHint,

            border: const OutlineInputBorder(),

            prefixIcon: Icon(icon, size: 20),

            isDense: true,

            suffixIcon: IconButton(

              tooltip: 'เลือกจากทำเนียบครู',

              icon: const Icon(Icons.person_search_rounded, size: 20),

              onPressed: isAdmin ? () => _pickTeacherForController(nameController, label) : null,

            ),

          ),

        );



        final titleField = TextField(

          controller: titleController,

          enabled: isAdmin,

          decoration: InputDecoration(

            labelText: 'ตำแหน่งผู้ลงนาม',

            hintText: titleHint,

            border: const OutlineInputBorder(),

            prefixIcon: const Icon(Icons.work_outline_rounded, size: 20),

            isDense: true,

          ),

        );



        if (isNarrow) {

          return Column(

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              nameField,

              const SizedBox(height: 10),

              titleField,

            ],

          );

        }



        return Row(

          children: [

            Expanded(flex: 3, child: nameField),

            const SizedBox(width: 12),

            Expanded(flex: 2, child: titleField),

          ],

        );

      },

    );

  }



  // ===========================================================================

  // SECTION 5: TEACHER DIRECTORY & TEACHER CODES (รายชื่อและรหัสครูผู้สอน)

  // ===========================================================================



  Widget _buildTeacherDirectorySection(ThemeData theme) {

    final isAdmin = widget.apiService.isAdmin;

    final filtered = _teachersWithCode.where((t) {

      final q = _teacherSearchQuery.trim().toLowerCase();

      if (q.isEmpty) return true;

      final name = (t['name'] ?? '').toString().toLowerCase();

      final code = (t['code'] ?? '').toString().toLowerCase();

      return name.contains(q) || code.contains(q);

    }).toList();



    return Card(

      elevation: 1,

      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

      child: Padding(

        padding: const EdgeInsets.all(20),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Row(

              children: [

                Container(

                  padding: const EdgeInsets.all(8),

                  decoration: BoxDecoration(

                    color: Colors.amber.shade100,

                    borderRadius: BorderRadius.circular(8),

                  ),

                  child: Icon(Icons.badge_outlined, color: Colors.amber.shade900),

                ),

                const SizedBox(width: 12),

                Expanded(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Text(

                        'รายชื่อครูและรหัสครูผู้สอน (Teacher Directory)',

                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),

                      ),

                      Text(

                        'กำหนดรหัสครู (เช่น 102, 306, 804) เพื่อให้อ้างอิงรายวิชาและจัดทำ ปพ.5 ได้อย่างแม่นยำแม้ชื่อสะกดต่างกัน',

                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                      ),

                    ],

                  ),

                ),

                if (isAdmin) ...[

                  OutlinedButton.icon(

                    icon: const Icon(Icons.sync_rounded, size: 16),

                    label: const Text('ดึงจากระบบ', style: TextStyle(fontSize: 12)),

                    onPressed: _loadingTeachers ? null : _syncTeachersFromSystem,

                  ),

                  const SizedBox(width: 8),

                  FilledButton.icon(

                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),

                    label: const Text('เพิ่มครูผู้สอน', style: TextStyle(fontSize: 12)),

                    style: FilledButton.styleFrom(backgroundColor: Colors.indigo.shade700),

                    onPressed: () => _openTeacherDialog(),

                  ),

                ],

              ],

            ),

            const SizedBox(height: 16),

            const Divider(height: 1),

            const SizedBox(height: 16),



            // Search Bar & Counter

            Row(

              children: [

                Expanded(

                  child: SizedBox(

                    height: 38,

                    child: TextField(

                      decoration: InputDecoration(

                        hintText: 'ค้นหาด้วยรหัสครู หรือชื่อ-นามสกุล...',

                        hintStyle: const TextStyle(fontSize: 12),

                        prefixIcon: const Icon(Icons.search, size: 18),

                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),

                      ),

                      onChanged: (v) => setState(() => _teacherSearchQuery = v),

                    ),

                  ),

                ),

                const SizedBox(width: 16),

                Chip(

                  avatar: const Icon(Icons.people_alt_outlined, size: 14),

                  label: Text('ครูทั้งหมด ${_teachersWithCode.length} ท่าน', style: const TextStyle(fontSize: 11)),

                  visualDensity: VisualDensity.compact,

                ),

              ],

            ),

            const SizedBox(height: 16),



            // Teachers List Table

            if (_loadingTeachers)

              const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))

            else if (filtered.isEmpty)

              Container(

                width: double.infinity,

                padding: const EdgeInsets.all(24),

                decoration: BoxDecoration(

                  color: Colors.grey.shade50,

                  borderRadius: BorderRadius.circular(8),

                  border: Border.all(color: Colors.grey.shade200),

                ),

                child: Center(

                  child: Text(

                    _teacherSearchQuery.isEmpty ? 'ยังไม่มีข้อมูลครูในระบบ' : 'ไม่พบข้อมูลครูที่ตรงกับ "$_teacherSearchQuery"',

                    style: TextStyle(color: Colors.grey.shade600),

                  ),

                ),

              )

            else

              Container(

                decoration: BoxDecoration(

                  border: Border.all(color: Colors.grey.shade200),

                  borderRadius: BorderRadius.circular(10),

                ),

                clipBehavior: Clip.antiAlias,

                child: Table(

                  columnWidths: const {

                    0: FixedColumnWidth(95),

                    1: FlexColumnWidth(4),

                    2: FixedColumnWidth(110),

                    3: FixedColumnWidth(125),

                  },

                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,

                  children: [

                    TableRow(

                      decoration: BoxDecoration(color: Colors.grey.shade100),

                      children: const [

                        Padding(

                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),

                          child: Text('รหัสครู', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),

                        ),

                        Padding(

                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),

                          child: Text('ชื่อ-นามสกุลครูผู้สอน', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),

                        ),

                        Padding(

                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),

                          child: Center(child: Text('รหัสใช้งาน', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),

                        ),

                        Padding(

                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),

                          child: Center(child: Text('จัดการ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),

                        ),

                      ],

                    ),

                    ...filtered.asMap().entries.map((entry) {

                      final idx = entry.key;

                      final t = entry.value;

                      final code = (t['code'] ?? '').toString().trim();

                      final name = (t['name'] ?? '').toString().trim();

                      final pin = (t['login_pin'] != null && t['login_pin'].toString().trim().isNotEmpty)

                          ? t['login_pin'].toString().trim()

                          : (code.isNotEmpty ? code : '-');

                      final isEven = idx % 2 == 0;



                      return TableRow(

                        decoration: BoxDecoration(color: isEven ? Colors.white : Colors.grey.shade50),

                        children: [

                          Padding(

                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),

                            child: code.isNotEmpty

                                ? Container(

                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),

                                    decoration: BoxDecoration(

                                      color: Colors.indigo.shade50,

                                      borderRadius: BorderRadius.circular(6),

                                      border: Border.all(color: Colors.indigo.shade200),

                                    ),

                                    child: Text(

                                      code,

                                      style: TextStyle(

                                        fontFamily: 'monospace',

                                        fontSize: 12,

                                        fontWeight: FontWeight.bold,

                                        color: Colors.indigo.shade900,

                                      ),

                                    ),

                                  )

                                : Text('-', style: TextStyle(color: Colors.grey.shade400)),

                          ),

                          InkWell(

                            onTap: () => _openTeacherCourses(t),

                            child: Tooltip(

                              message: 'คลิกเพื่อดูวิชาและระดับชั้นที่สอน',

                              waitDuration: const Duration(milliseconds: 500),

                              child: Padding(

                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),

                                child: Row(

                                  children: [

                                    Flexible(

                                      child: Text(

                                        name,

                                        style: TextStyle(

                                          fontSize: 13,

                                          fontWeight: FontWeight.w500,

                                          height: 1.4,

                                          color: Colors.indigo.shade800,

                                          decoration: TextDecoration.underline,

                                          decorationColor: Colors.indigo.shade200,

                                        ),

                                      ),

                                    ),

                                    const SizedBox(width: 4),

                                    Icon(Icons.chevron_right_rounded, size: 16, color: Colors.grey.shade500),

                                  ],

                                ),

                              ),

                            ),

                          ),

                          // Column: รหัสใช้งาน (Login PIN)

                          Padding(

                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),

                            child: Center(

                              child: Container(

                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),

                                decoration: BoxDecoration(

                                  color: Colors.amber.shade50,

                                  borderRadius: BorderRadius.circular(6),

                                  border: Border.all(color: Colors.amber.shade300),

                                ),

                                child: Row(

                                  mainAxisSize: MainAxisSize.min,

                                  children: [

                                    Icon(Icons.key_rounded, size: 12, color: Colors.amber.shade900),

                                    const SizedBox(width: 4),

                                    Text(

                                      pin,

                                      style: TextStyle(

                                        fontFamily: 'monospace',

                                        fontSize: 12,

                                        fontWeight: FontWeight.bold,

                                        color: Colors.amber.shade900,

                                      ),

                                    ),

                                  ],

                                ),

                              ),

                            ),

                          ),

                          // Column: จัดการ

                          Padding(

                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),

                            child: isAdmin

                                ? Row(

                                    mainAxisAlignment: MainAxisAlignment.center,

                                    children: [

                                      IconButton(

                                        icon: Icon(Icons.key_rounded, size: 17, color: Colors.amber.shade800),

                                        tooltip: 'เปลี่ยนรหัสใช้งาน (PIN)',

                                        onPressed: () => _openChangeTeacherPinDialog(t),

                                      ),

                                      IconButton(

                                        icon: const Icon(Icons.edit_outlined, size: 17),

                                        tooltip: 'แก้ไข',

                                        color: Colors.indigo.shade700,

                                        onPressed: () => _openTeacherDialog(t),

                                      ),

                                      IconButton(

                                        icon: const Icon(Icons.delete_outline, size: 17),

                                        tooltip: 'ลบ',

                                        color: Colors.red.shade600,

                                        onPressed: () => _deleteTeacherConfirm(t),

                                      ),

                                    ],

                                  )

                                : const Center(

                                    child: Text('-', style: TextStyle(color: Colors.grey)),

                                  ),

                          ),

                        ],

                      );

                    }),

                  ],

                ),

              ),

          ],

        ),

      ),

    );

  }



  Future<void> _openTeacherCourses(Map<String, dynamic> teacher) async {

    // Default to the current semester by device date: 1 Apr - 10 Oct = term 1, otherwise term 2

    final now = DateTime.now();

    final beYear = now.year + 543;

    String term;

    String year;

    final isTerm1 = (now.month > 4 || now.month == 4) &&

        (now.month < 10 || (now.month == 10 && now.day <= 10));

    if (isTerm1) {

      term = '1';

      year = '$beYear';

    } else {

      term = '2';

      year = now.month <= 3 ? '${beYear - 1}' : '$beYear';

    }



    final changed = await TeacherCoursesDialog.show(

      context,

      apiService: widget.apiService,

      teacherName: (teacher['name'] ?? '').toString(),

      teacherCode: (teacher['code'] ?? '').toString(),

      allTeachers: _teachersWithCode,

      initialTerm: term,

      initialYear: year,

    );

    if (changed == true) {

      widget.onSettingsChanged?.call();

    }

  }



  void _openChangeTeacherPinDialog(Map<String, dynamic> teacher) {

    final name = (teacher['name'] ?? '').toString();

    final code = (teacher['code'] ?? '').toString();

    final currentPin = (teacher['login_pin'] != null && teacher['login_pin'].toString().isNotEmpty)

        ? teacher['login_pin'].toString()

        : code;

    final pinCtrl = TextEditingController(text: currentPin);

    final formKey = GlobalKey<FormState>();



    showDialog(

      context: context,

      builder: (ctx) {

        bool isSaving = false;

        return StatefulBuilder(

          builder: (context, setDialogState) {

            return AlertDialog(

              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

              title: Row(

                children: [

                  Container(

                    padding: const EdgeInsets.all(8),

                    decoration: BoxDecoration(

                      color: Colors.amber.shade100,

                      borderRadius: BorderRadius.circular(8),

                    ),

                    child: Icon(Icons.key_rounded, color: Colors.amber.shade900, size: 22),

                  ),

                  const SizedBox(width: 12),

                  const Text('เปลี่ยนรหัสใช้งาน (Login PIN)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),

                ],

              ),

              content: Form(

                key: formKey,

                child: Column(

                  mainAxisSize: MainAxisSize.min,

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Text('คุณครู: $name', style: const TextStyle(fontWeight: FontWeight.bold)),

                    const SizedBox(height: 4),

                    Text('รหัสประจำตัวครู: $code', style: const TextStyle(color: Colors.black54, fontSize: 13)),

                    const SizedBox(height: 16),

                    TextFormField(

                      controller: pinCtrl,

                      autofocus: true,

                      keyboardType: TextInputType.number,

                      maxLength: 6,

                      inputFormatters: [

                        FilteringTextInputFormatter.digitsOnly,

                        LengthLimitingTextInputFormatter(6),

                      ],

                      decoration: InputDecoration(

                        labelText: 'รหัสใช้งาน (ตัวเลข 1-6 หลัก)',

                        hintText: 'เช่น 1234 หรือเลขเดียวกับรหัสครู',

                        prefixIcon: const Icon(Icons.pin_outlined),

                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),

                        counterText: '',

                      ),

                      validator: (v) {

                        final val = (v ?? '').trim();

                        if (val.isEmpty) return 'กรุณาระบุรหัสใช้งาน';

                        if (!RegExp(r'^\d{1,6}$').hasMatch(val)) return 'กรุณาระบุตัวเลขไม่เกิน 6 หลัก';

                        return null;

                      },

                    ),

                    const SizedBox(height: 8),

                    Text(

                      'หมายเหตุ: รหัสใช้งานใช้สำหรับล็อกอินเข้าระบบคู่กับรหัสครู สามารถตั้งเป็นตัวเลขได้ไม่เกิน 6 ตัว',

                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),

                    ),

                  ],

                ),

              ),

              actions: [

                TextButton(

                  onPressed: isSaving ? null : () => Navigator.pop(ctx),

                  child: const Text('ยกเลิก'),

                ),

                FilledButton(

                  onPressed: isSaving

                      ? null

                      : () async {

                          if (!formKey.currentState!.validate()) return;

                          setDialogState(() => isSaving = true);

                          try {

                            await widget.apiService.updateTeacherPin(code, pinCtrl.text.trim());

                            await _loadSchoolTeachers();

                            if (mounted) {

                              Navigator.pop(ctx);

                              ScaffoldMessenger.of(context).showSnackBar(

                                SnackBar(

                                  backgroundColor: Colors.green.shade800,

                                  content: Text('เปลี่ยนรหัสใช้งานสำหรับ $name สำเร็จ (รหัสใหม่: ${pinCtrl.text.trim()})'),

                                ),

                              );

                            }

                          } catch (e) {

                            setDialogState(() => isSaving = false);

                            if (mounted) {

                              ScaffoldMessenger.of(context).showSnackBar(

                                SnackBar(

                                  backgroundColor: Colors.red.shade800,

                                  content: Text('เกิดข้อผิดพลาด: $e'),

                                ),

                              );

                            }

                          }

                        },

                  child: isSaving

                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))

                      : const Text('บันทึกรหัสใหม่'),

                ),

              ],

            );

          },

        );

      },

    );

  }



  void _openTeacherDialog([Map<String, dynamic>? existing]) {

    final isEditing = existing != null;

    final codeCtrl = TextEditingController(text: isEditing ? (existing['code'] ?? '') : '');

    final nameCtrl = TextEditingController(text: isEditing ? (existing['name'] ?? '') : '');

    final pinCtrl = TextEditingController(

      text: isEditing ? (existing['login_pin'] ?? existing['code'] ?? '') : '',

    );



    showDialog(

      context: context,

      builder: (ctx) => AlertDialog(

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: Row(

          children: [

            Icon(isEditing ? Icons.edit_outlined : Icons.person_add_alt_1_rounded, color: Colors.indigo.shade800),

            const SizedBox(width: 8),

            Text(isEditing ? 'แก้ไขข้อมูลครูผู้สอน' : 'เพิ่มครูผู้สอนใหม่', style: const TextStyle(fontSize: 16)),

          ],

        ),

        content: SizedBox(

          width: 380,

          child: Column(

            mainAxisSize: MainAxisSize.min,

            children: [

              TextField(

                controller: codeCtrl,

                decoration: const InputDecoration(

                  labelText: 'รหัสครู (เช่น 102, 306, 804)',

                  hintText: 'กรอกตัวเลขรหัสครู...',

                  border: OutlineInputBorder(),

                  prefixIcon: Icon(Icons.numbers_rounded),

                ),

              ),

              const SizedBox(height: 14),

              TextField(

                controller: nameCtrl,

                decoration: const InputDecoration(

                  labelText: 'ชื่อ-นามสกุลครูผู้สอน (ชื่อเต็มทางการ)',

                  hintText: 'เช่น นางสาวสมหญิง รักเรียน',

                  border: OutlineInputBorder(),

                  prefixIcon: Icon(Icons.person_outline_rounded),

                ),

              ),

              const SizedBox(height: 14),

              TextField(

                controller: pinCtrl,

                keyboardType: TextInputType.number,

                maxLength: 6,

                inputFormatters: [

                  FilteringTextInputFormatter.digitsOnly,

                  LengthLimitingTextInputFormatter(6),

                ],

                decoration: const InputDecoration(

                  labelText: 'รหัสใช้งาน (Login PIN ไม่เกิน 6 ตัวเลข)',

                  hintText: 'หากเว้นว่างจะใช้รหัสครูเป็นค่าเริ่มต้น',

                  border: OutlineInputBorder(),

                  prefixIcon: Icon(Icons.pin_outlined),

                  counterText: '',

                ),

              ),

              const SizedBox(height: 8),

              Text(

                '* รหัสครูจะใช้อ้างอิงตอนนำเข้ารายวิชา แม้ชื่อในไฟล์จะสะกดผิดหรือมีคำนำหน้าต่างกัน ระบบจะดึงชื่อทางการนี้ไปใช้ใน ปพ.5 อัตโนมัติ',

                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),

              ),

            ],

          ),

        ),

        actions: [

          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ยกเลิก')),

          FilledButton(

            onPressed: () async {

              final name = nameCtrl.text.trim();

              final code = codeCtrl.text.trim();

              final pin = pinCtrl.text.trim();

              final loginPin = pin.isNotEmpty ? pin : (code.isNotEmpty ? code : null);



              if (name.isEmpty) {

                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('กรุณากรอกชื่อครูผู้สอน')));

                return;

              }

              Navigator.pop(ctx);

              try {

                if (isEditing) {

                  await widget.apiService.updateSchoolTeacher(

                    id: existing['id'] as int,

                    name: name,

                    code: code.isEmpty ? null : code,

                    loginPin: loginPin,

                  );

                } else {

                  await widget.apiService.addSchoolTeacherWithCode(

                    name: name,

                    code: code.isEmpty ? null : code,

                    loginPin: loginPin,

                  );

                }

                _loadSchoolTeachers();

                if (mounted) {

                  ScaffoldMessenger.of(context).showSnackBar(

                    SnackBar(backgroundColor: Colors.green.shade800, content: Text('บันทึกข้อมูล $name สำเร็จ')),

                  );

                }

              } catch (e) {

                if (mounted) {

                  ScaffoldMessenger.of(context).showSnackBar(

                    SnackBar(backgroundColor: Colors.red.shade800, content: Text('เกิดข้อผิดพลาด: $e')),

                  );

                }

              }

            },

            child: const Text('บันทึก'),

          ),

        ],

      ),

    );

  }



  void _deleteTeacherConfirm(Map<String, dynamic> teacher) {

    final name = (teacher['name'] ?? '').toString();

    final id = teacher['id'];



    showDialog(

      context: context,

      builder: (ctx) => AlertDialog(

        title: const Text('ยืนยันการลบ'),

        content: Text('ต้องการลบข้อมูลครู "$name" ออกจากระบบใช่หรือไม่?'),

        actions: [

          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ยกเลิก')),

          FilledButton(

            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),

            onPressed: () async {

              Navigator.pop(ctx);

              try {

                await widget.apiService.deleteSchoolTeacherByIdOrName(id ?? name);

                _loadSchoolTeachers();

                if (mounted) {

                  ScaffoldMessenger.of(context).showSnackBar(

                    SnackBar(content: Text('ลบข้อมูล $name เรียบร้อยแล้ว')),

                  );

                }

              } catch (e) {

                if (mounted) {

                  ScaffoldMessenger.of(context).showSnackBar(

                    SnackBar(backgroundColor: Colors.red.shade800, content: Text('เกิดข้อผิดพลาด: $e')),

                  );

                }

              }

            },

            child: const Text('ลบข้อมูล'),

          ),

        ],

      ),

    );

  }



  Future<void> _syncTeachersFromSystem() async {

    setState(() => _loadingTeachers = true);

    try {

      final res = await widget.apiService.syncSchoolTeachers();

      await _loadSchoolTeachers();

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(

            backgroundColor: Colors.green.shade800,

            content: Text('ดึงข้อมูลรายชื่อครูจากระบบสำเร็จ (พบครูทั้งหมด ${res.length} ท่าน)'),

          ),

        );

      }

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(backgroundColor: Colors.red.shade800, content: Text('เกิดข้อผิดพลาด: $e')),

        );

      }

    } finally {

      if (mounted) setState(() => _loadingTeachers = false);

    }

  }



  // ===========================================================================

  // SECTION 6: COURSE STRUCTURE & AUTOMATED PORPOR 5 GENERATION (นำเข้ารายวิชา)

  // ===========================================================================



  /// ชื่อนักเรียน: ปุ่มให้แอดมินสั่งปรับคำนำหน้าตามอายุได้เองทันที (ปกติระบบทำให้เองทุกวัน)



  Widget _buildStudentNameMaintenanceCard(ThemeData theme) {



    return Card(



      elevation: 1,



      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),



      child: Padding(



        padding: const EdgeInsets.all(20),



        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [



          Row(children: [



            Container(



              padding: const EdgeInsets.all(8),



              decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(8)),



              child: Icon(Icons.badge_outlined, color: Colors.orange.shade900),



            ),



            const SizedBox(width: 12),



            Expanded(



              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [



                Text('คำนำหน้าชื่อนักเรียน', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),



                Text(



                  'ระบบเปลี่ยน เด็กชาย/เด็กหญิง เป็น นาย/นางสาว ให้เองเมื่ออายุครบ 15 ปี โดยดูจากวันเกิดในฐานข้อมูล '



                  'และตรวจให้วันละครั้ง • แก้ชื่อรายคนได้ที่ช่องชื่อในหน้าเช็คเวลาเรียน',



                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),



                ),



              ]),



            ),



          ]),



          const SizedBox(height: 14),



          Align(



            alignment: Alignment.centerLeft,



            child: OutlinedButton.icon(



              icon: const Icon(Icons.refresh_rounded),



              label: const Text('ตรวจและปรับคำนำหน้าตามอายุเดี๋ยวนี้'),



              onPressed: () async {



                try {



                  final res = await widget.apiService.refreshStudentPrefixes();



                  if (!mounted) return;



                  final n = ((res['data'] as List?) ?? []).length;



                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(



                    backgroundColor: n > 0 ? Colors.green.shade800 : null,



                    content: Text('${res['message'] ?? 'ตรวจคำนำหน้าเรียบร้อย'}'),



                  ));



                } catch (e) {



                  if (!mounted) return;



                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(



                    backgroundColor: Colors.red.shade800,



                    content: Text(e.toString().replaceFirst('Exception: ', '')),



                  ));



                }



              },



            ),



          ),



        ]),



      ),



    );



  }







  Widget _buildCourseImportSection(ThemeData theme) {

    final isAdmin = widget.apiService.isAdmin;

    return Card(

      elevation: 1,

      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

      child: Padding(

        padding: const EdgeInsets.all(20),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Row(

              children: [

                Container(

                  padding: const EdgeInsets.all(8),

                  decoration: BoxDecoration(

                    color: Colors.teal.shade100,

                    borderRadius: BorderRadius.circular(8),

                  ),

                  child: Icon(Icons.auto_stories_outlined, color: Colors.teal.shade900),

                ),

                const SizedBox(width: 12),

                Expanded(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Text(

                        'นำเข้ารายวิชาและครูผู้สอน (สร้าง ปพ.5 อัตโนมัติ)',

                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),

                      ),

                      Text(

                        'อัปโหลดตารางรายวิชาและรหัสครู เพื่อจัดเก็บโครงสร้างหลักสูตรและสร้างไฟล์ ปพ.5 Excel พร้อมดึงรายชื่อนักเรียนให้อัตโนมัติ',

                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),

                      ),

                    ],

                  ),

                ),

              ],

            ),

            const SizedBox(height: 16),

            const Divider(height: 1),

            const SizedBox(height: 16),



            // Controls: Term / Year / Generate Excel Toggle

            Wrap(

              spacing: 16,

              runSpacing: 12,

              crossAxisAlignment: WrapCrossAlignment.center,

              children: [

                // Term Selector

                Row(

                  mainAxisSize: MainAxisSize.min,

                  children: [

                    const Text('ภาคเรียนที่:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),

                    const SizedBox(width: 8),

                    DropdownButton<String>(

                      value: _importTerm,

                      items: const [

                        DropdownMenuItem(value: '1', child: Text('ภาคเรียนที่ 1')),

                        DropdownMenuItem(value: '2', child: Text('ภาคเรียนที่ 2')),

                      ],

                      onChanged: (v) {

                        if (v != null) setState(() => _importTerm = v);

                      },

                    ),

                  ],

                ),



                // Year Selector

                Row(

                  mainAxisSize: MainAxisSize.min,

                  children: [

                    const Text('ปีการศึกษา:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),

                    const SizedBox(width: 8),

                    DropdownButton<String>(

                      value: _importYear,

                      items: ['2567', '2568', '2569', '2570', '2571'].map((y) {

                        return DropdownMenuItem(value: y, child: Text(y));

                      }).toList(),

                      onChanged: (v) {

                        if (v != null) setState(() => _importYear = v);

                      },

                    ),

                  ],

                ),



                // Checkbox: Create PorPor 5 Excel

                Row(

                  mainAxisSize: MainAxisSize.min,

                  children: [

                    Checkbox(

                      value: _importGenerateExcel,

                      onChanged: (v) => setState(() => _importGenerateExcel = v ?? true),

                    ),

                    const Text('สร้างไฟล์ ปพ.5 Excel ทันที (ดึงรายชื่อนักเรียนครบทุกห้อง)', style: TextStyle(fontSize: 12)),

                  ],

                ),

              ],

            ),

            const SizedBox(height: 16),



            // Action Buttons

            Wrap(

              spacing: 12,

              runSpacing: 10,

              children: [

                if (isAdmin) ...[

                  FilledButton.icon(

                    icon: _importingCourses

                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))

                        : const Icon(Icons.file_upload_outlined, size: 18),

                    label: const Text('นำเข้าไฟล์ตารางสอน (.xlsx / .csv)'),

                    style: FilledButton.styleFrom(

                      backgroundColor: Colors.teal.shade800,

                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),

                    ),

                    onPressed: _importingCourses ? null : _pickAndImportCoursesFile,

                  ),

                  OutlinedButton.icon(

                    icon: const Icon(Icons.content_paste_go_rounded, size: 18),

                    label: const Text('วางข้อความตารางสอน (Paste)'),

                    style: OutlinedButton.styleFrom(

                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),

                    ),

                    onPressed: _importingCourses ? null : _openPasteCoursesDialog,

                  ),

                ] else ...[

                  Container(

                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                    decoration: BoxDecoration(

                      color: Colors.grey.shade100,

                      borderRadius: BorderRadius.circular(8),

                      border: Border.all(color: Colors.grey.shade300),

                    ),

                    child: const Row(

                      mainAxisSize: MainAxisSize.min,

                      children: [

                        Icon(Icons.lock_outline, size: 16, color: Colors.black54),

                        SizedBox(width: 8),

                        Text('เฉพาะผู้ดูแลระบบ (Admin) เท่านั้นที่สามารถนำเข้าตารางรายวิชาได้', style: TextStyle(fontSize: 11.5, color: Colors.black54)),

                      ],

                    ),

                  ),

                ],

                OutlinedButton.icon(

                  icon: const Icon(Icons.download_rounded, size: 18),

                  label: const Text('ดาวน์โหลดตัวอย่าง Excel'),

                  onPressed: () => _downloadCourseTemplate('xlsx'),

                ),

                OutlinedButton.icon(

                  icon: const Icon(Icons.text_snippet_outlined, size: 18),

                  label: const Text('ดาวน์โหลดตัวอย่าง CSV'),

                  onPressed: () => _downloadCourseTemplate('csv'),

                ),

              ],

            ),



            if (_lastCourseImportResult != null) ...[

              const SizedBox(height: 16),

              Container(

                width: double.infinity,

                padding: const EdgeInsets.all(16),

                decoration: BoxDecoration(

                  color: Colors.green.shade50,

                  borderRadius: BorderRadius.circular(10),

                  border: Border.all(color: Colors.green.shade200),

                ),

                child: Column(

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Row(

                      children: [

                        Icon(Icons.check_circle_rounded, color: Colors.green.shade800, size: 20),

                        const SizedBox(width: 8),

                        Text(

                          'ผลการนำเข้าล่าสุด:',

                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green.shade900),

                        ),

                      ],

                    ),

                    const SizedBox(height: 6),

                    Text(

                      _lastCourseImportResult!['message'] ?? 'นำเข้ารายวิชาเรียบร้อยแล้ว',

                      style: TextStyle(fontSize: 13, color: Colors.green.shade900),

                    ),

                    const SizedBox(height: 4),

                    Text(

                      'ข้อมูลถูกเชื่อมต่อกับรายชื่อครูและบันทึกลงในระบบ สามารถเปิดดูไฟล์ ปพ.5 ได้ที่เมนู "คลังข้อมูลวิชา / ปพ.5"',

                      style: TextStyle(fontSize: 11, color: Colors.green.shade800),

                    ),

                  ],

                ),

              ),

            ],

          ],

        ),

      ),

    );

  }



  Future<void> _pickAndImportCoursesFile() async {

    try {

      final pickedFiles = await FilePicker.pickFiles(

        type: FileType.custom,

        allowedExtensions: ['xlsx', 'csv'],

      );

      if (pickedFiles.isEmpty) return;

      final file = pickedFiles.first;

      final bytes = await file.readAsBytes();



      setState(() => _importingCourses = true);



      final result = await widget.apiService.importCourses(

        fileBytes: bytes,

        filename: file.name,

        term: _importTerm,

        year: _importYear,

        generateExcel: _importGenerateExcel,

      );



      setState(() {

        _lastCourseImportResult = result;

        _importingCourses = false;

      });



      await _loadSchoolTeachers();

      widget.onSettingsChanged?.call();



      if (mounted) {

        _showImportSummaryDialog(result);

      }

    } catch (e) {

      if (mounted) {

        setState(() => _importingCourses = false);

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(backgroundColor: Colors.red.shade800, content: Text('นำเข้าไม่สำเร็จ: $e')),

        );

      }

    }

  }



  void _openPasteCoursesDialog() {

    final textCtrl = TextEditingController();



    showDialog(

      context: context,

      builder: (ctx) => AlertDialog(

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: Row(

          children: [

            Icon(Icons.content_paste_go_rounded, color: Colors.teal.shade800),

            const SizedBox(width: 8),

            const Text('วางข้อความตารางสอน (CSV/ตาราง)', style: TextStyle(fontSize: 16)),

          ],

        ),

        content: SizedBox(

          width: 550,

          child: Column(

            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              Text(

                'วางข้อมูลตารางรายวิชาที่มีคอลัมน์: รหัสวิชา, ชื่อรายวิชา, หน่วยกิต, ชั้นเรียน, รหัสครู, ครูผู้สอน...',

                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),

              ),

              const SizedBox(height: 10),

              TextField(

                controller: textCtrl,

                maxLines: 10,

                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),

                decoration: const InputDecoration(

                  hintText: 'รหัสวิชา,ชื่อรายวิชา,หน่วยกิต,ชั้นเรียน,ประเภทวิชา,กลุ่มสาระ,รหัสครู,ครูผู้สอน\nท21102,ภาษาไทย 2,1.5,ม.1,1 พื้นฐาน,1 ภาษาไทย,101,ครูสมชาย\n...',

                  border: OutlineInputBorder(),

                ),

              ),

            ],

          ),

        ),

        actions: [

          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ยกเลิก')),

          FilledButton(

            style: FilledButton.styleFrom(backgroundColor: Colors.teal.shade800),

            onPressed: () async {

              final text = textCtrl.text.trim();

              if (text.isEmpty) {

                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('กรุณาวางข้อความตารางรายวิชา')));

                return;

              }

              Navigator.pop(ctx);

              setState(() => _importingCourses = true);

              try {

                final result = await widget.apiService.importCourses(

                  csvText: text,

                  term: _importTerm,

                  year: _importYear,

                  generateExcel: _importGenerateExcel,

                );

                setState(() {

                  _lastCourseImportResult = result;

                  _importingCourses = false;

                });

                await _loadSchoolTeachers();

                widget.onSettingsChanged?.call();

                if (mounted) {

                  _showImportSummaryDialog(result);

                }

              } catch (e) {

                if (mounted) {

                  setState(() => _importingCourses = false);

                  ScaffoldMessenger.of(context).showSnackBar(

                    SnackBar(backgroundColor: Colors.red.shade800, content: Text('นำเข้าไม่สำเร็จ: $e')),

                  );

                }

              }

            },

            child: const Text('นำเข้าข้อมูล'),

          ),

        ],

      ),

    );

  }



  void _showImportSummaryDialog(Map<String, dynamic> result) {

    final total = result['total_courses'] ?? 0;

    final excelCount = result['excel_count'] ?? 0;

    final courses = (result['courses'] as List?) ?? [];



    showDialog(

      context: context,

      builder: (ctx) => AlertDialog(

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: Row(

          children: [

            const Icon(Icons.check_circle_rounded, color: Colors.green),

            const SizedBox(width: 8),

            const Text('นำเข้ารายวิชาและเตรียม ปพ.5 สำเร็จ'),

          ],

        ),

        content: SizedBox(

          width: 500,

          child: Column(

            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              Container(

                padding: const EdgeInsets.all(12),

                decoration: BoxDecoration(

                  color: Colors.teal.shade50,

                  borderRadius: BorderRadius.circular(8),

                  border: Border.all(color: Colors.teal.shade200),

                ),

                child: Column(

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Text('• บันทึกรายวิชาลงระบบ: $total วิชา', style: const TextStyle(fontWeight: FontWeight.bold)),

                    Text('• สร้างไฟล์ ปพ.5 Excel พร้อมรายชื่อนักเรียน: $excelCount ไฟล์'),

                    Text('• ภาคเรียน/ปีการศึกษา: $_importTerm/$_importYear'),

                  ],

                ),

              ),

              const SizedBox(height: 12),

              const Text('ตัวอย่างรายวิชาที่นำเข้า:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),

              const SizedBox(height: 6),

              ConstrainedBox(

                constraints: const BoxConstraints(maxHeight: 220),

                child: ListView.separated(

                  shrinkWrap: true,

                  itemCount: courses.take(15).length,

                  separatorBuilder: (_, i) => const Divider(height: 1),

                  itemBuilder: (_, i) {

                    final c = courses[i];

                    return ListTile(

                      dense: true,

                      contentPadding: EdgeInsets.zero,

                      leading: Chip(

                        label: Text(c['class_level'] ?? '', style: const TextStyle(fontSize: 10)),

                        visualDensity: VisualDensity.compact,

                      ),

                      title: Text('${c['course_code']} ${c['course_name']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),

                      subtitle: Text('ครู: ${c['teacher']} (รหัส ${c['teacher_code']}) • นักเรียน ${c['student_count']} คน', style: const TextStyle(fontSize: 11)),

                    );

                  },

                ),

              ),

              if (courses.length > 15)

                Padding(

                  padding: const EdgeInsets.only(top: 6),

                  child: Text('...และอีก ${courses.length - 15} รายวิชา', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),

                ),

            ],

          ),

        ),

        actions: [

          FilledButton(

            onPressed: () => Navigator.pop(ctx),

            child: const Text('ตกลง'),

          ),

        ],

      ),

    );

  }



  void _downloadCourseTemplate(String format) async {

    final url = '${widget.apiService.baseUrl}/api/v1/courses/template?format=$format';

    final uri = Uri.parse(url);

    try {

      if (await canLaunchUrl(uri)) {

        await launchUrl(uri, mode: LaunchMode.externalApplication);

      } else {

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(content: Text('เปิดลิงก์ดาวน์โหลด: $url')),

          );

        }

      }

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(content: Text('เกิดข้อผิดพลาดในการดาวน์โหลด: $e')),

        );

      }

    }

  }





  // ===========================================================================

  // SYSTEM ADMINISTRATOR (ADMIN) MANAGEMENT

  // ===========================================================================

  Future<void> _loadSystemAdmins() async {

    setState(() => _loadingAdmins = true);

    try {

      final list = await widget.apiService.getSystemAdmins();

      if (mounted) {

        setState(() {

          _systemAdmins = list;

          _loadingAdmins = false;

        });

      }

    } catch (_) {

      if (mounted) {

        setState(() => _loadingAdmins = false);

      }

    }

  }



  Future<void> _openAddAdminDialog() async {

    if (_systemAdmins.length >= 3) {

      ScaffoldMessenger.of(context).showSnackBar(

        const SnackBar(content: Text('แต่งตั้งผู้ดูแลระบบครบ 3 ท่านแล้ว')),

      );

      return;

    }



    final existingCodes = _systemAdmins.map((a) => (a['teacher_code'] ?? '').toString()).toSet();

    final eligibleTeachers = _teachersWithCode.where((t) {

      final code = (t['code'] ?? '').toString().trim();

      return code.isNotEmpty && !existingCodes.contains(code);

    }).toList();



    if (eligibleTeachers.isEmpty) {

      ScaffoldMessenger.of(context).showSnackBar(

        const SnackBar(content: Text('ไม่พบครูที่มีรหัสประจำตัวและยังไม่ได้เป็นแอดมิน (กรุณาเพิ่มรหัสครูในระบบก่อน)')),

      );

      return;

    }



    String selectedCode = eligibleTeachers.first['code'].toString().trim();



    final confirmed = await showDialog<bool>(

      context: context,

      builder: (ctx) {

        return StatefulBuilder(

          builder: (dCtx, setDState) {

            return AlertDialog(

              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

              title: const Row(

                children: [

                  Icon(Icons.admin_panel_settings_rounded, color: Colors.amber),

                  SizedBox(width: 8),

                  Text('แต่งตั้งผู้ดูแลระบบเพิ่ม'),

                ],

              ),

              content: Column(

                mainAxisSize: MainAxisSize.min,

                crossAxisAlignment: CrossAxisAlignment.start,

                children: [

                  const Text('เลือกคุณครูที่ต้องการแต่งตั้งเป็นผู้ดูแลระบบ (Admin) สูงสุด 3 ท่าน:'),

                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(

                    value: selectedCode,

                    isExpanded: true,

                    decoration: const InputDecoration(

                      labelText: 'เลือกคุณครู',

                      border: OutlineInputBorder(),

                    ),

                    items: eligibleTeachers.map((t) {

                      return DropdownMenuItem<String>(

                        value: t['code'].toString().trim(),

                        child: Text('${t['name']} (รหัส: ${t['code']})', overflow: TextOverflow.ellipsis),

                      );

                    }).toList(),

                    onChanged: (val) {

                      if (val != null) {

                        setDState(() => selectedCode = val);

                      }

                    },

                  ),

                ],

              ),

              actions: [

                TextButton(

                  onPressed: () => Navigator.of(ctx).pop(false),

                  child: const Text('ยกเลิก'),

                ),

                FilledButton(

                  style: FilledButton.styleFrom(backgroundColor: Colors.amber.shade800),

                  onPressed: () => Navigator.of(ctx).pop(true),

                  child: const Text('แต่งตั้งเป็นแอดมิน'),

                ),

              ],

            );

          },

        );

      },

    );



    if (confirmed == true) {

      try {

        final updated = await widget.apiService.addSystemAdmin(selectedCode);

        setState(() {

          _systemAdmins = updated;

        });

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            const SnackBar(content: Text('แต่งตั้งผู้ดูแลระบบเรียบร้อยแล้ว'), backgroundColor: Colors.teal),

          );

        }

      } catch (e) {

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(content: Text('เกิดข้อผิดพลาด: $e'), backgroundColor: Colors.red),

          );

        }

      }

    }

  }



  Future<void> _removeAdmin(Map<String, dynamic> admin) async {

    final code = admin['teacher_code'] ?? '';

    final name = admin['teacher_name'] ?? '';



    final confirm = await showDialog<bool>(

      context: context,

      builder: (ctx) => AlertDialog(

        title: const Text('ยืนยันถอดถอนผู้ดูแลระบบ'),

        content: Text('ท่านต้องการถอดถอนสิทธิ์ผู้ดูแลระบบของ "$name (รหัส: $code)" ใช่หรือไม่?'),

        actions: [

          TextButton(

            onPressed: () => Navigator.of(ctx).pop(false),

            child: const Text('ยกเลิก'),

          ),

          FilledButton(

            style: FilledButton.styleFrom(backgroundColor: Colors.red),

            onPressed: () => Navigator.of(ctx).pop(true),

            child: const Text('ยืนยันถอดถอน'),

          ),

        ],

      ),

    );



    if (confirm == true) {

      try {

        final updated = await widget.apiService.removeSystemAdmin(code);

        setState(() {

          _systemAdmins = updated;

        });

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            const SnackBar(content: Text('ถอดถอนสิทธิ์ผู้ดูแลระบบเรียบร้อยแล้ว')),

          );

        }

      } catch (e) {

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            SnackBar(content: Text('เกิดข้อผิดพลาด: $e'), backgroundColor: Colors.red),

          );

        }

      }

    }

  }



  Widget _buildAdminManagementSection(ThemeData theme) {

    final cs = theme.colorScheme;

    final isAdmin = widget.apiService.isAdmin;



    return Card(

      elevation: 1,

      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

      child: Padding(

        padding: const EdgeInsets.all(22),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Row(

              children: [

                Container(

                  padding: const EdgeInsets.all(8),

                  decoration: BoxDecoration(

                    color: Colors.amber.shade100,

                    borderRadius: BorderRadius.circular(10),

                  ),

                  child: Icon(Icons.admin_panel_settings_rounded, color: Colors.amber.shade900, size: 24),

                ),

                const SizedBox(width: 12),

                Expanded(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Row(

                        children: [

                          Text(

                            'ผู้ดูแลระบบ (Admin) สูงสุด 3 ท่าน',

                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),

                          ),

                          const SizedBox(width: 8),

                          Container(

                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),

                            decoration: BoxDecoration(

                              color: Colors.amber.shade50,

                              borderRadius: BorderRadius.circular(6),

                              border: Border.all(color: Colors.amber.shade400),

                            ),

                            child: Text(

                              '${_systemAdmins.length}/3 ท่าน',

                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amber.shade900),

                            ),

                          ),

                        ],

                      ),

                      const SizedBox(height: 2),

                      Text(

                        'ผู้ดูแลระบบสามารถเข้าถึงและแก้ไขข้อมูลทุกส่วน รวมถึงจัดการรายชื่อผู้ดูแลระบบ',

                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),

                      ),

                    ],

                  ),

                ),

                if (isAdmin && _systemAdmins.length < 3)

                  FilledButton.icon(

                    style: FilledButton.styleFrom(

                      backgroundColor: Colors.amber.shade800,

                      foregroundColor: Colors.white,

                    ),

                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),

                    label: const Text('แต่งตั้งแอดมิน'),

                    onPressed: _openAddAdminDialog,

                  ),

              ],

            ),

            const SizedBox(height: 18),

            if (_loadingAdmins)

              const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))

            else if (_systemAdmins.isEmpty)

              const Center(child: Text('ไม่พบข้อมูลผู้ดูแลระบบ'))

            else

              ListView.separated(

                shrinkWrap: true,

                physics: const NeverScrollableScrollPhysics(),

                itemCount: _systemAdmins.length,

                separatorBuilder: (_, idx) => const SizedBox(height: 8),

                itemBuilder: (ctx, idx) {

                  final adm = _systemAdmins[idx];

                  final code = adm['teacher_code'] ?? '';

                  final name = adm['teacher_name'] ?? '';

                  final isPrimary = (code == '308' || idx == 0);



                  return Container(

                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),

                    decoration: BoxDecoration(

                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),

                      borderRadius: BorderRadius.circular(12),

                      border: Border.all(color: Colors.amber.shade200),

                    ),

                    child: Row(

                      children: [

                        CircleAvatar(

                          radius: 18,

                          backgroundColor: Colors.amber.shade100,

                          child: Icon(Icons.shield_rounded, size: 18, color: Colors.amber.shade900),

                        ),

                        const SizedBox(width: 12),

                        Expanded(

                          child: Column(

                            crossAxisAlignment: CrossAxisAlignment.start,

                            children: [

                              Row(

                                children: [

                                  Text(

                                    name,

                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),

                                  ),

                                  if (isPrimary) ...[

                                    const SizedBox(width: 6),

                                    Container(

                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),

                                      decoration: BoxDecoration(

                                        color: Colors.amber.shade700,

                                        borderRadius: BorderRadius.circular(4),

                                      ),

                                      child: const Text(

                                        'แอดมินหลัก',

                                        style: TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),

                                      ),

                                    ),

                                  ],

                                ],

                              ),

                              const SizedBox(height: 2),

                              Text(

                                'รหัสครู: $code',

                                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),

                              ),

                            ],

                          ),

                        ),

                        if (isAdmin && _systemAdmins.length > 1)

                          IconButton(

                            icon: const Icon(Icons.person_remove_rounded, color: Colors.red, size: 20),

                            tooltip: 'ถอดถอนสิทธิ์ผู้ดูแลระบบ',

                            onPressed: () => _removeAdmin(adm),

                          ),

                      ],

                    ),

                  );

                },

              ),

            if (!isAdmin) ...[

              const SizedBox(height: 12),

              Container(

                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                decoration: BoxDecoration(

                  color: Colors.grey.shade100,

                  borderRadius: BorderRadius.circular(8),

                  border: Border.all(color: Colors.grey.shade300),

                ),

                child: const Row(

                  children: [

                    Icon(Icons.lock_outline, size: 16, color: Colors.black54),

                    SizedBox(width: 8),

                    Text(

                      'เฉพาะผู้ดูแลระบบ (Admin) เท่านั้นที่สามารถแต่งตั้งหรือจัดการผู้ดูแลระบบได้',

                      style: TextStyle(fontSize: 11.5, color: Colors.black54),

                    ),

                  ],

                ),

              ),

            ],

          ],

        ),

      ),

    );

  }




  // ===========================================================================
  // DATA STORAGE & MULTI-YEAR BACKUP ARCHIVE (การจัดเก็บและกู้คืนข้อมูล)
  // ===========================================================================
  List<Map<String, dynamic>> _backups = [];
  bool _isLoadingBackups = false;

  Future<void> _loadBackups() async {
    setState(() => _isLoadingBackups = true);
    try {
      final list = await widget.apiService.getBackups();
      if (mounted) {
        setState(() {
          _backups = list;
          _isLoadingBackups = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingBackups = false);
      }
    }
  }

  Future<void> _showImportBackupForSemesterModal({
    required BuildContext parentCtx,
    required String targetTerm,
    required String targetYear,
  }) async {
    showDialog(
      context: context,
      builder: (dlgCtx) {
        return StatefulBuilder(
          builder: (modalCtx, setDlgState) {
            return FutureBuilder<List<Map<String, dynamic>>>(
              future: widget.apiService.getBackups(),
              builder: (ctx, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const AlertDialog(
                    content: SizedBox(
                      height: 120,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('กำลังค้นหาไฟล์สำรองในระบบ...'),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                final backups = snapshot.data ?? [];
                if (backups.isEmpty) {
                  return AlertDialog(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    title: const Row(
                      children: [
                        Icon(Icons.info_outline_rounded, color: Colors.orange),
                        SizedBox(width: 10),
                        Text('ไม่พบไฟล์สำรองในระบบ'),
                      ],
                    ),
                    content: const Text(
                      'ขณะนี้ยังไม่มีไฟล์สำรองในคลังจัดเก็บข้อมูล\n\n'
                      'คุณครูสามารถกด "จัดเก็บข้อมูลทุกอย่าง" ในหัวข้อ "จัดเก็บข้อมูล" ด้านล่างของหน้าตั้งค่า เพื่อสร้างไฟล์สำรองเก็บไว้ได้ครับ',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dlgCtx).pop(),
                        child: const Text('ตกลง'),
                      ),
                    ],
                  );
                }

                Map<String, dynamic>? selectedBackup = backups.first;

                return StatefulBuilder(
                  builder: (ctx2, setSelectionState) {
                    return AlertDialog(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Row(
                        children: [
                          Icon(Icons.cloud_download_rounded, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 10),
                          const Text('เลือกไฟล์สำรองเพื่อนำเข้าข้อมูล', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                        ],
                      ),
                      content: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'เป้าหมายการนำเข้า: ปีการศึกษา $targetYear ภาคเรียนที่ $targetTerm',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo),
                            ),
                            const SizedBox(height: 12),
                            const Text('เลือกไฟล์ที่จัดเก็บไว้:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade400),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: selectedBackup?['id'],
                                  items: backups.map((b) {
                                    final label = b['label'] ?? b['filename'];
                                    final dt = b['created_at'] ?? '';
                                    final size = '${b['size_mb'] ?? 0} MB';
                                    return DropdownMenuItem<String>(
                                      value: b['id'] as String,
                                      child: Text(
                                        '$label  ($size, $dt)',
                                        style: const TextStyle(fontSize: 13),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (id) {
                                    if (id != null) {
                                      setSelectionState(() {
                                        selectedBackup = backups.firstWhere((e) => e['id'] == id);
                                      });
                                    }
                                  },
                                ),
                              ),
                            ),
                            if (selectedBackup != null) ...[
                              const SizedBox(height: 14),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey.shade300),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('รายละเอียดไฟล์:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey.shade800)),
                                    const SizedBox(height: 4),
                                    Text('• ชื่อไฟล์: ${selectedBackup!['filename']}', style: const TextStyle(fontSize: 11.5)),
                                    Text('• จำนวนรายวิชา: ${selectedBackup!['courses_count'] ?? 0} วิชา', style: const TextStyle(fontSize: 11.5)),
                                    Text('• ผลการเรียน: ${selectedBackup!['grades_count'] ?? 0} รายการ', style: const TextStyle(fontSize: 11.5)),
                                    Text('• นักเรียน: ${selectedBackup!['students_count'] ?? 0} คน', style: const TextStyle(fontSize: 11.5)),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dlgCtx).pop(),
                          child: const Text('ยกเลิก'),
                        ),
                        FilledButton.icon(
                          icon: const Icon(Icons.file_download_done_rounded, size: 18),
                          label: const Text('ยืนยันนำเข้าข้อมูลนี้'),
                          onPressed: selectedBackup == null
                              ? null
                              : () async {
                                  Navigator.of(dlgCtx).pop();
                                  try {
                                    final res = await widget.apiService.restoreBackup(
                                      backupId: selectedBackup!['id'],
                                      mode: 'semester',
                                      targetTerm: targetTerm,
                                      targetYear: targetYear,
                                    );
                                    _loadSemesterConfigs();
                                    _loadBackups();
    _loadSchoolThemeConfig();
                                    widget.onSettingsChanged?.call();
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          backgroundColor: Colors.green.shade800,
                                          content: Text(res['message'] ?? 'นำเข้าข้อมูลเดิมสำเร็จ'),
                                        ),
                                      );
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          backgroundColor: Colors.red.shade800,
                                          content: Text('นำเข้าข้อมูลไม่สำเร็จ: $e'),
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
          },
        );
      },
    );
  }

  Future<void> _openCreateBackupDialog() async {
    final labelCtrl = TextEditingController(
      text: 'สำรองข้อมูลระบบทั้งหมด ณ วันที่ ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year + 543}',
    );
    bool isSaving = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setModalState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.archive_rounded, color: Color(0xFF0F766E), size: 24),
                  ),
                  const SizedBox(width: 10),
                  const Text('จัดเก็บข้อมูลทุกอย่าง (สำรองข้อมูล)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                ],
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ระบบจะทำการบันทึกข้อมูลทุกอย่าง (ผลการเรียน, รายวิชา, ข้อมูลนักเรียน, ตารางสอน) เป็นไฟล์สำรองถาวร เก็บไว้ในระบบอย่างปลอดภัย สามารถนำกลับมาใช้งานต่อเนื่องได้กว่า 10 ปี',
                      style: TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: labelCtrl,
                      decoration: const InputDecoration(
                        labelText: 'ชื่อไฟล์/ข้อความอธิบายข้อมูลสำรองนี้',
                        hintText: 'เช่น ปีการศึกษา 2568 ภาคเรียนที่ 1 หรือ สำรองสิ้นปี 2568',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.label_outline_rounded),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('ยกเลิก'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    foregroundColor: Colors.white,
                  ),
                  icon: isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_rounded, size: 18),
                  label: Text(isSaving ? 'กำลังจัดเก็บ...' : 'ยืนยันจัดเก็บข้อมูล'),
                  onPressed: isSaving
                      ? null
                      : () async {
                          setModalState(() => isSaving = true);
                          try {
                            final res = await widget.apiService.createBackup(label: labelCtrl.text.trim());
                            _loadBackups();
    _loadSchoolThemeConfig();
                            if (ctx.mounted) Navigator.of(ctx).pop();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: Colors.teal.shade800,
                                  content: Text('จัดเก็บข้อมูลสำเร็จ: ${res['label']} (${res['size_mb']} MB)'),
                                ),
                              );
                            }
                          } catch (e) {
                            setModalState(() => isSaving = false);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(backgroundColor: Colors.red.shade800, content: Text('จัดเก็บไม่สำเร็จ: $e')),
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

  Future<void> _openRestoreBackupConfirmDialog(Map<String, dynamic> backup) async {
    final label = backup['label'] ?? backup['filename'];
    final bid = backup['id'];
    bool isRestoring = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setModalState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
                  SizedBox(width: 10),
                  Text('ยืนยันกู้คืนข้อมูลระบบทั้งหมด', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                ],
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('คุณต้องการกู้คืนข้อมูลจากไฟล์: "$label" ใช่หรือไม่?', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: const Text(
                        '✓ ระบบจะสำรองข้อมูลปัจจุบันไว้ให้อัตโนมัติก่อนเริ่มกู้คืน เพื่อความปลอดภัยสูงสุด\n'
                        '✓ ข้อมูลทั้งหมดจะถูกย้อนกลับไปตรงตามที่บันทึกไว้ในไฟล์สำรองนี้',
                        style: TextStyle(fontSize: 12, color: Color(0xFF1E3A8A), height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isRestoring ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('ยกเลิก'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1E3A8A)),
                  icon: isRestoring
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.settings_backup_restore_rounded, size: 18),
                  label: Text(isRestoring ? 'กำลังกู้คืน...' : 'ยืนยันกู้คืนข้อมูล'),
                  onPressed: isRestoring
                      ? null
                      : () async {
                          setModalState(() => isRestoring = true);
                          try {
                            final res = await widget.apiService.restoreBackup(backupId: bid, mode: 'full');
                            _loadSemesterConfigs();
                            _loadBackups();
    _loadSchoolThemeConfig();
                            widget.onSettingsChanged?.call();
                            if (ctx.mounted) Navigator.of(ctx).pop();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: Colors.green.shade800,
                                  content: Text(res['message'] ?? 'กู้คืนข้อมูลเรียบร้อยแล้ว'),
                                ),
                              );
                            }
                          } catch (e) {
                            setModalState(() => isRestoring = false);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(backgroundColor: Colors.red.shade800, content: Text('กู้คืนไม่สำเร็จ: $e')),
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

  Future<void> _openDeleteBackupConfirmDialog(Map<String, dynamic> backup) async {
    final label = backup['label'] ?? backup['filename'];
    final bid = backup['id'];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('ยืนยันการลบไฟล์สำรอง'),
        content: Text('คุณต้องการลบไฟล์สำรอง "$label" ใช่หรือไม่? การกระทำนี้ไม่สามารถย้อนกลับได้'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('ยกเลิก')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ลบไฟล์สำรอง'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await widget.apiService.deleteBackup(bid);
        _loadBackups();
    _loadSchoolThemeConfig();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(backgroundColor: Colors.green, content: Text('ลบไฟล์สำรองเรียบร้อยแล้ว')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(backgroundColor: Colors.red, content: Text('ลบไม่สำเร็จ: $e')),
          );
        }
      }
    }
  }

  Widget _buildDataStorageSection(ThemeData theme) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFCCFBF1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.archive_rounded, color: Color(0xFF0F766E), size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'จัดเก็บข้อมูล (Data Storage & Multi-Year Archive)',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'จัดเก็บข้อมูลผลการเรียน ตารางสอน และรายชื่อนักเรียนทุกอย่างเป็นไฟล์สำรอง เพื่อเก็บเป็นคลังข้อมูลต่อเนื่อง 10 ปี',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  icon: const Icon(Icons.backup_rounded, size: 18),
                  label: const Text('จัดเก็บข้อมูลทุกอย่างตอนนี้ (สำรองข้อมูล)', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _openCreateBackupDialog,
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Text(
              'รายการไฟล์สำรองข้อมูลที่จัดเก็บไว้ในระบบ (${_backups.length} ไฟล์):',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 10),
            if (_isLoadingBackups)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_backups.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  children: [
                    Icon(Icons.inventory_2_outlined, size: 40, color: Colors.grey.shade400),
                    const SizedBox(height: 8),
                    Text(
                      'ยังไม่มีไฟล์สำรองในระบบ',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'คุณครูสามารถกดปุ่ม "จัดเก็บข้อมูลทุกอย่างตอนนี้" ด้านบน เพื่อสำรองข้อมูลชุดแรกเก็บไว้ได้ทันทีครับ',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _backups.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (ctx, idx) {
                  final b = _backups[idx];
                  final label = b['label'] ?? b['filename'];
                  final dt = b['created_at'] ?? '';
                  final sizeMb = b['size_mb'] ?? 0;
                  final coursesCount = b['courses_count'] ?? 0;
                  final gradesCount = b['grades_count'] ?? 0;
                  final studentsCount = b['students_count'] ?? 0;
                  final semesters = (b['semesters'] as List<dynamic>?)?.join(', ') ?? '';

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
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
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.teal.shade50,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.inventory_2_rounded, color: Color(0xFF0F766E), size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 12,
                                runSpacing: 4,
                                children: [
                                  Text('📅 $dt', style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
                                  Text('💾 $sizeMb MB', style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
                                  Text('📚 $coursesCount วิชา', style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
                                  Text('📝 $gradesCount ผลคะแนน', style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
                                  if (semesters.isNotEmpty)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: Colors.blue.shade50,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: Colors.blue.shade200),
                                      ),
                                      child: Text(
                                        'เทอม: $semesters',
                                        style: TextStyle(fontSize: 10.5, color: Colors.blue.shade900, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF1E3A8A),
                            side: const BorderSide(color: Color(0xFF93C5FD)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          ),
                          icon: const Icon(Icons.settings_backup_restore_rounded, size: 16),
                          label: const Text('กู้คืน', style: TextStyle(fontSize: 12)),
                          onPressed: () => _openRestoreBackupConfirmDialog(b),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'ดาวน์โหลดไฟล์สำรอง (.db)',
                          icon: const Icon(Icons.download_rounded, size: 20, color: Color(0xFF0F766E)),
                          onPressed: () async {
                            final downloadUrl = '${widget.apiService.baseUrl}/api/v1/backups/${b['id']}/download';
                            final uri = Uri.parse(downloadUrl);
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                        ),
                        IconButton(
                          tooltip: 'ลบไฟล์สำรอง',
                          icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.red),
                          onPressed: () => _openDeleteBackupConfirmDialog(b),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

}
