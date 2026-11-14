import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../models/semester_config.dart';
import '../models/class_advisor.dart';
import '../utils/app_theme.dart';
import '../widgets/app_3d_button.dart';

class HomeVisitScreen extends StatefulWidget {
  final ApiService apiService;

  const HomeVisitScreen({
    super.key,
    required this.apiService,
  });

  @override
  State<HomeVisitScreen> createState() => _HomeVisitScreenState();
}

class _HomeVisitScreenState extends State<HomeVisitScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = false;
  bool _saving = false;
  bool _uploadingPhoto = false;

  String _selectedTerm = '1';
  String _selectedYear = '2569';
  String _selectedClass = 'ม.1';
  List<SemesterConfigItem> _semesters = [];
  List<ClassAdvisorItem> _advisors = [];

  // Data for selected class
    String _classAdvisorName = '';
  int _classStudentCount = 0;
  List<String> _classPhotos = [];
  int _extraSlots = 0; // Number of added extra photo slots beyond 6
  int _classSubTab = 0; // 0: ผลรายงาน & แกลเลอรีรูปภาพ (Dashboard), 1: กรอก/แก้ไขแบบสำรวจ (Form Editor)

  // Form field controllers
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, TextEditingController> _photoCaptionControllers = {};

  String _formatClassLevelNum(String cl) {
    final s = cl.replaceAll(RegExp(r'^(?:ระดับชั้น|ระดับ)?\s*(?:มัธยมศึกษาปีที่|ม\.)\s*'), '').trim();
    return s.isNotEmpty ? s : cl;
  }

  // Summary data for school dashboard
  Map<String, dynamic>? _summaryData;

  final List<String> _classList = ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'];

  // All 28 question keys from the Google Form
  static const List<Map<String, dynamic>> formSections = [
    {
      'title': '1. สถิติจำนวนนักเรียนในการออกเยี่ยมบ้าน',
      'icon': Icons.people_alt_rounded,
      'items': [
        {'key': '1. จำนวนนักเรียนที่ออกเยี่ยมบ้าน (คน)', 'label': '1. จำนวนนักเรียนที่ออกเยี่ยมบ้านทั้งหมด', 'unit': 'คน', 'type': 'number'},
        {'key': '1.1 ชาย (คน)', 'label': '1.1 ชาย', 'unit': 'คน', 'type': 'number'},
        {'key': '1.2 หญิง (คน)', 'label': '1.2 หญิง', 'unit': 'คน', 'type': 'number'},
        {'key': '2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน (คน)', 'label': '2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน', 'unit': 'คน', 'type': 'number'},
        {'key': '3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน', 'label': '3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน', 'unit': '', 'type': 'text'},
      ]
    },
    {
      'title': '2. สภาพครอบครัวและความเป็นอยู่',
      'icon': Icons.family_restroom_rounded,
      'items': [
        {'key': '4. ครอบครัวอบอุ่น (คน)', 'label': '4. ครอบครัวอบอุ่น', 'unit': 'คน', 'type': 'number'},
        {'key': '5. ครอบครัวแตกแยก (คน)', 'label': '5. ครอบครัวแตกแยก', 'unit': 'คน', 'type': 'number'},
        {'key': '6. นักเรียนที่บิดาและมารดาเสียชีวิต (คน)', 'label': '6. นักเรียนที่บิดาและมารดาเสียชีวิต', 'unit': 'คน', 'type': 'number'},
        {'key': '7. นักเรียนที่บิดาหรือมารดาเสียชีวิต (คน)', 'label': '7. นักเรียนที่บิดาหรือมารดาเสียชีวิต', 'unit': 'คน', 'type': 'number'},
        {'key': '8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน (คน)', 'label': '8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน', 'unit': 'คน', 'type': 'number'},
        {'key': '9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาของตนเอง (คน)', 'label': '9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาตนเอง', 'unit': 'คน', 'type': 'number'},
      ]
    },
    {
      'title': '3. การคัดกรองปัญหาและความเสี่ยง',
      'icon': Icons.health_and_safety_rounded,
      'items': [
        {'key': '10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน (คน)', 'label': '10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน', 'unit': 'คน', 'type': 'number'},
        {'key': '11. นักเรียนมีปัญหาด้านสุขภาพ (คน)', 'label': '11. นักเรียนมีปัญหาด้านสุขภาพ', 'unit': 'คน', 'type': 'number'},
        {'key': '12. นักเรียนมีพฤติกรรมเสี่ยง (คน)', 'label': '12. นักเรียนมีพฤติกรรมเสี่ยง (รวม)', 'unit': 'คน', 'type': 'number'},
        {'key': '12.1 เสี่ยงด้านสุขภาพ (คน)', 'label': '   12.1 เสี่ยงด้านสุขภาพ', 'unit': 'คน', 'type': 'number'},
        {'key': '12.2 เสี่ยงด้านการใช้สารเสพติด (คน)', 'label': '   12.2 เสี่ยงด้านการใช้สารเสพติด', 'unit': 'คน', 'type': 'number'},
        {'key': '12.3 เสี่ยงด้านความรุนแรง', 'label': '   12.3 เสี่ยงด้านความรุนแรง', 'unit': 'คน', 'type': 'number'},
        {'key': '12.4 เสี่ยงด้านการเดินทางมาเรียน', 'label': '   12.4 เสี่ยงด้านการเดินทางมาเรียน', 'unit': 'คน', 'type': 'number'},
        {'key': '12.5 เสี่ยงด้านเพศ', 'label': '   12.5 เสี่ยงด้านเพศ', 'unit': 'คน', 'type': 'number'},
        {'key': '12.6 เสี่ยงติดเกม', 'label': '   12.6 เสี่ยงติดเกม', 'unit': 'คน', 'type': 'number'},
        {'key': '12.7 เสี่ยงด้านอื่นๆ (โปรดระบุ)', 'label': '   12.7 เสี่ยงด้านอื่นๆ (โปรดระบุ)', 'unit': '', 'type': 'text'},
        {'key': '13. นักเรียนมีปัญหาด้านเศรษฐกิจ (คน)', 'label': '13. นักเรียนมีปัญหาด้านเศรษฐกิจ', 'unit': 'คน', 'type': 'number'},
        {'key': '14. นักเรียนมีปัญหาอื่นๆ (คน)', 'label': '14. นักเรียนมีปัญหาอื่นๆ', 'unit': 'คน', 'type': 'number'},
        {'key': '14.1 ระบุปัญหาที่พบ', 'label': '   14.1 ระบุปัญหาที่พบ', 'unit': '', 'type': 'text'},
        {'key': '15. นักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วน (คน)', 'label': '15. นักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วน', 'unit': 'คน', 'type': 'number'},
      ]
    },
    {
      'title': '4. ภาคีเครือข่าย & การนำไปใช้ & ข้อห่วงใย',
      'icon': Icons.handshake_rounded,
      'items': [
        {'key': '16. หน่วยงาน/สหวิชาชีพ/องค์กร ที่ร่วมเยี่ยมบ้าน', 'label': '16. หน่วยงาน/สหวิชาชีพ/องค์กร ที่ร่วมเยี่ยมบ้าน', 'unit': '', 'type': 'text'},
        {'key': '17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์อย่างไร', 'label': '17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์อย่างไร', 'unit': '', 'type': 'text'},
        {'key': '18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน', 'label': '18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน', 'unit': '', 'type': 'text'},
      ]
    },
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initControllers();
    _loadInitialData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final c in _photoCaptionControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _initControllers() {
    for (final sec in formSections) {
      final items = sec['items'] as List<Map<String, dynamic>>;
      for (final it in items) {
        final key = it['key'] as String;
        _controllers[key] = TextEditingController();
      }
    }
  }

  Future<void> _loadInitialData() async {
    setState(() => _loading = true);
    try {
      // 1. Semesters
      final sList = await widget.apiService.getSemesterConfigs();
      _semesters = sList;
      if (sList.isNotEmpty) {
        final pinned = sList.firstWhere((s) => s.isDefault, orElse: () => sList.first);
        _selectedTerm = pinned.term;
        _selectedYear = pinned.year;
      }

      // 2. Advisors
      _advisors = await widget.apiService.getClassAdvisors(term: _selectedTerm, year: _selectedYear);

      // 3. User class auto-detection
      _detectUserClass();

      // 4. Load class report & summary
      await Future.wait([
        _loadClassReport(),
        _loadSummaryData(),
      ]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.red.shade700, content: Text('โหลดข้อมูลไม่สำเร็จ: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _detectUserClass() {
    final user = widget.apiService.currentUserNotifier.value;
    if (user != null && !user.isAdmin) {
      final cleanName = user.name.trim();
      for (final adv in _advisors) {
        final names = [adv.advisor1, adv.advisor2, adv.advisor3].map((n) => (n ?? '').trim());
        if (names.any((n) => n.isNotEmpty && (n.contains(cleanName) || cleanName.contains(n) || n.contains(user.baseName)))) {
          _selectedClass = adv.classLevel;
          break;
        }
      }
    }
  }

  Future<void> _loadClassReport() async {
    try {
      final res = await widget.apiService.getHomeVisitClass(
        _selectedClass,
        term: _selectedTerm,
        year: _selectedYear,
      );
      final meta = (res['meta'] as Map<String, dynamic>?) ?? {};
      final data = (res['data'] as Map<String, dynamic>?);

      if (mounted) {
        setState(() {
          _classAdvisorName = meta['advisor_name']?.toString() ?? '';
          _classStudentCount = (meta['student_count'] as num?)?.toInt() ?? 0;
          _classPhotos = (data?['photos'] as List?)?.cast<String>() ?? [];
        });
      }

      final captionsMap = (data?['photo_captions'] as Map<String, dynamic>?) ?? {};
      for (final p in _classPhotos) {
        final ctrl = _photoCaptionControllers.putIfAbsent(p, () => TextEditingController());
        ctrl.text = captionsMap[p]?.toString() ?? '';
      }

      final fields = (data?['fields'] as Map<String, dynamic>?) ?? {};
      for (final entry in _controllers.entries) {
        final val = fields[entry.key]?.toString() ?? '';
        entry.value.text = val;
      }
    } catch (e) {
      debugPrint('Error loading class report: $e');
    }
  }

  Future<void> _loadSummaryData() async {
    try {
      final res = await widget.apiService.getHomeVisitSummary(
        term: _selectedTerm,
        year: _selectedYear,
      );
      if (mounted) {
        setState(() => _summaryData = res);
      }
    } catch (e) {
      debugPrint('Error loading summary: $e');
    }
  }

  Future<void> _saveCurrentClassReport() async {
    setState(() => _saving = true);
    try {
      final fields = <String, dynamic>{};
      for (final entry in _controllers.entries) {
        fields[entry.key] = entry.value.text.trim();
      }

      final photoCaptions = <String, String>{};
      for (final p in _classPhotos) {
        final txt = _photoCaptionControllers[p]?.text.trim() ?? '';
        if (txt.isNotEmpty) {
          photoCaptions[p] = txt;
        }
      }

      final currentUserName = (widget.apiService.currentUser?.name ?? '').trim();

      await widget.apiService.saveHomeVisitClass(
        _selectedClass,
        term: _selectedTerm,
        year: _selectedYear,
        advisorName: _classAdvisorName,
        recordedByName: currentUserName,
        fields: fields,
        photos: _classPhotos,
        photoCaptions: photoCaptions,
      );

      await Future.wait([
        _loadClassReport(),
        _loadSummaryData(),
      ]);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF15803D),
            content: Text('บันทึกข้อมูลการเยี่ยมบ้านเรียบร้อยแล้ว'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.red.shade700, content: Text('บันทึกไม่สำเร็จ: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    try {
      final pickedFiles = await FilePicker.pickFiles(
        dialogTitle: 'เลือกรูปภาพหลักฐานการเยี่ยมบ้าน',
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
      );

      if (pickedFiles.isEmpty) return;
      final file = pickedFiles.first;
      final bytes = await file.readAsBytes();

      setState(() => _uploadingPhoto = true);
      final res = await widget.apiService.uploadHomeVisitPhoto(
        _selectedClass,
        term: _selectedTerm,
        year: _selectedYear,
        bytes: bytes,
        filename: file.name,
      );

      setState(() {
        _classPhotos = (res['photos'] as List?)?.cast<String>() ?? _classPhotos;
      });

      await _loadSummaryData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF15803D),
            content: Text('อัปโหลดรูปภาพเยี่ยมบ้านสำเร็จ'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.red.shade700, content: Text('อัปโหลดรูปไม่สำเร็จ: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _deletePhoto(String photoName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ยืนยันการลบรูปภาพ'),
        content: const Text('ท่านต้องการลบรูปภาพหลักฐานนี้หรือไม่?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ลบรูปภาพ'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final res = await widget.apiService.deleteHomeVisitPhoto(
        _selectedClass,
        term: _selectedTerm,
        year: _selectedYear,
        photoName: photoName,
      );
      setState(() {
        _classPhotos = (res['photos'] as List?)?.cast<String>() ?? [];
      });
      await _loadSummaryData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ลบรูปภาพเรียบร้อยแล้ว')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.red.shade700, content: Text('ลบรูปไม่สำเร็จ: $e')),
        );
      }
    }
  }

  /// ผู้อำนวยการ บุคคลทั่วไป และนักเรียน ดูได้บนหน้าจอ แต่บันทึกไฟล์ลงเครื่องไม่ได้
  bool get _canDownload => widget.apiService.currentUser?.canDownload ?? true;

  void _downloadClassDocx() {
    final url = widget.apiService.getHomeVisitClassDocxUrl(_selectedClass, term: _selectedTerm, year: _selectedYear);
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _downloadClassDocxFrameless() {
    final url = widget.apiService.getHomeVisitClassDocxUrl(_selectedClass, term: _selectedTerm, year: _selectedYear, frameless: true);
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _downloadSummaryDocxFrameless() {
    final url = widget.apiService.getHomeVisitSummaryDocxUrl(term: _selectedTerm, year: _selectedYear, frameless: true);
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _showPhotoLightbox(String photoUrl, int photoNumber, [String? caption]) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 820, maxHeight: 620),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.gold, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.6),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      color: AppColors.purpleDark,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.photo_library_rounded, color: AppColors.yellowSchool, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                (caption != null && caption.trim().isNotEmpty) ? caption.trim() : 'ภาพที่ $photoNumber: การเยี่ยมบ้านนักเรียน ชั้น มัธยมศึกษาปีที่ ${_formatClassLevelNum(_selectedClass)}',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: Image.network(
                        photoUrl,
                        fit: BoxFit.contain,
                        loadingBuilder: (c, child, progress) => progress == null
                            ? child
                            : const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(40),
                                  child: CircularProgressIndicator(color: AppColors.yellowSchool),
                                ),
                              ),
                        errorBuilder: (c, err, stack) => const Center(
                          child: Padding(
                            padding: EdgeInsets.all(40),
                            child: Icon(Icons.broken_image_rounded, size: 60, color: Colors.white54),
                          ),
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
    );
  }

  void _previewClassPdf() {
    final url = widget.apiService.getHomeVisitClassPdfPreviewUrl(_selectedClass, term: _selectedTerm, year: _selectedYear);
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _previewSummaryPdf() {
    final url = widget.apiService.getHomeVisitSummaryPdfPreviewUrl(term: _selectedTerm, year: _selectedYear);
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _downloadClassPdf() {
    final url = widget.apiService.getHomeVisitClassPdfUrl(_selectedClass, term: _selectedTerm, year: _selectedYear);
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _downloadSummaryDocx() {
    final url = widget.apiService.getHomeVisitSummaryDocxUrl(term: _selectedTerm, year: _selectedYear);
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _downloadSummaryPdf() {
    final url = widget.apiService.getHomeVisitSummaryPdfUrl(term: _selectedTerm, year: _selectedYear);
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = widget.apiService.currentUserNotifier.value;
    final isAdmin = currentUser?.isAdmin ?? false;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Top Header Toolbar & Tab Selector
                _buildHeaderToolbar(isAdmin),

                // Main Views (Tab 1: Class Form & Photos, Tab 2: School Summary Dashboard)
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildClassFormView(isAdmin),
                      _buildSchoolDashboardView(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildHeaderToolbar(bool isAdmin) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.35), width: 1.2)),
        boxShadow: [
          BoxShadow(
            color: AppColors.purplePrimary.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              // Title & Icon
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
                    child: const Icon(Icons.home_work_rounded, color: AppColors.purplePrimary, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ระบบบันทึก & รายงานการเยี่ยมบ้านนักเรียน',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                      ),
                      Text(
                        'แบบรายงานสรุปผลการเยี่ยมบ้านรายห้องเรียนและระดับโรงเรียน (สพฐ.)',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),

              // Controls: Semester Selector + Download buttons
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Semester Dropdown
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.gold, width: 1.2),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: '$_selectedTerm-$_selectedYear',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                        items: _semesters.map((s) {
                          return DropdownMenuItem(
                            value: '${s.term}-${s.year}',
                            child: Text(s.title.isNotEmpty ? s.title : 'ภาคเรียนที่ ${s.term}/${s.year}'),
                          );
                        }).toList(),
                        onChanged: (val) async {
                          if (val == null) return;
                          final parts = val.split('-');
                          setState(() {
                            _selectedTerm = parts[0];
                            _selectedYear = parts[1];
                            _loading = true;
                          });
                          try {
                            _advisors = await widget.apiService.getClassAdvisors(term: _selectedTerm, year: _selectedYear);
                            _detectUserClass();
                            await Future.wait([
                              _loadClassReport(),
                              _loadSummaryData(),
                            ]);
                          } finally {
                            if (mounted) setState(() => _loading = false);
                          }
                        },
                      ),
                    ),
                  ),

                  // Quick Refresh
                  IconButton(
                    tooltip: 'รีเฟรชข้อมูล',
                    icon: const Icon(Icons.refresh_rounded, color: AppColors.purplePrimary),
                    onPressed: () async {
                      setState(() => _loading = true);
                      try {
                        _advisors = await widget.apiService.getClassAdvisors(term: _selectedTerm, year: _selectedYear);
                        await Future.wait([
                          _loadClassReport(),
                          _loadSummaryData(),
                        ]);
                      } finally {
                        if (mounted) setState(() => _loading = false);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Tab Bar Selector
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFF1E8FC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: AppColors.purplePrimary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.gold, width: 1.2),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              labelColor: AppColors.yellowSchool,
              unselectedLabelColor: AppColors.purpleDark,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
              tabs: const [
                Tab(icon: Icon(Icons.assignment_rounded, size: 18), text: 'แบบบันทึกข้อมูลประจำห้อง & รูปภาพ'),
                Tab(icon: Icon(Icons.dashboard_rounded, size: 18), text: 'แดชบอร์ดสรุปภาพรวมโรงเรียน'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 1: CLASS FORM & PHOTO GALLERY
  // -------------------------------------------------------------
  Widget _buildClassFormView(bool isAdmin) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Class Selector Toolbar with View Mode Toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.gold, width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: AppColors.purplePrimary.withValues(alpha: 0.03),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
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
                    const Text('ระดับชั้น: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.purpleContainer,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.gold),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedClass,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.purpleDark),
                          items: _classList.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                          onChanged: (val) {
                            if (val == null || val == _selectedClass) return;
                            setState(() {
                              _selectedClass = val;
                              _classAdvisorName = '';
                              _classStudentCount = 0;
                              _classPhotos = [];
                            });
                            _loadClassReport();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      'ครูที่ปรึกษา: ${_classAdvisorName.isNotEmpty ? _classAdvisorName : "ยังไม่ได้กำหนด"} • นักเรียน $_classStudentCount คน',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),

                // Mode Toggle Bar (ผลรายงาน & รูปภาพ VS กรอก/แก้ไขแบบสำรวจ)
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: AppColors.purpleContainer,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.gold.withValues(alpha: 0.8), width: 1.2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onTap: () => setState(() => _classSubTab = 0),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: _classSubTab == 0 ? AppColors.purplePrimary : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: _classSubTab == 0
                                ? [
                                    BoxShadow(
                                      color: AppColors.purplePrimary.withValues(alpha: 0.3),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    )
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.dashboard_rounded, size: 16, color: _classSubTab == 0 ? AppColors.yellowSchool : AppColors.purpleDark),
                              const SizedBox(width: 6),
                              Text(
                                'ผลรายงาน & รูปภาพ',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: _classSubTab == 0 ? Colors.white : AppColors.purpleDark,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (!(widget.apiService.currentUser?.isGuest ?? false)) ...[
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () => setState(() => _classSubTab = 1),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                            decoration: BoxDecoration(
                              color: _classSubTab == 1 ? AppColors.purplePrimary : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: _classSubTab == 1
                                  ? [
                                      BoxShadow(
                                        color: AppColors.purplePrimary.withValues(alpha: 0.3),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2),
                                      )
                                    ]
                                  : null,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.edit_note_rounded, size: 16, color: _classSubTab == 1 ? AppColors.yellowSchool : AppColors.purpleDark),
                                const SizedBox(width: 6),
                                Text(
                                  'กรอก/แก้ไขแบบสำรวจ',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                    color: _classSubTab == 1 ? Colors.white : AppColors.purpleDark,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // Action Buttons for this class
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (_classSubTab == 1 && !(widget.apiService.currentUser?.isGuest ?? false))
                      App3DButton.success(
                        icon: Icons.save_rounded,
                        label: _saving ? 'กำลังบันทึก...' : 'บันทึกข้อมูล',
                        isLoading: _saving,
                        depth: 3.2,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        onPressed: _saving ? null : _saveCurrentClassReport,
                      ),
                    App3DButton.gold(
                      icon: Icons.visibility_rounded,
                      label: 'ดูตัวอย่าง PDF',
                      depth: 3.2,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      onPressed: _previewClassPdf,
                    ),
                    if (_canDownload)

                      App3DButton.primary(

                        icon: Icons.picture_as_pdf_rounded,

                        label: 'ดาวน์โหลด PDF',

                        depth: 3.2,

                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),

                        onPressed: _downloadClassPdf,

                      ),
                    if (_canDownload)

                      App3DButton.secondary(

                        icon: Icons.description_rounded,

                        label: 'ดาวน์โหลด Word',

                        depth: 3.0,

                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),

                        onPressed: _downloadClassDocx,

                      ),
                    if (_canDownload)

                      App3DButton.secondary(
                        icon: Icons.article_outlined,
                        label: 'Word แบบไม่มีกรอบ',
                        depth: 3.0,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        onPressed: _downloadClassDocxFrameless,
                      ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          // Render Selected Sub-View
          if (_classSubTab == 0 || (widget.apiService.currentUser?.isGuest ?? false))
            _buildClassDashboardAndGalleryView()
          else
            _buildClassFormEditorView(),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // VIEW A: CLASS DASHBOARD & PHOTO GALLERY (ผลรายงาน & แกลเลอรีรูปภาพ)
  // -------------------------------------------------------------
  Widget _buildClassDashboardAndGalleryView() {
    final visitedVal = int.tryParse(_controllers['1. จำนวนนักเรียนที่ออกเยี่ยมบ้าน (คน)']?.text ?? '') ?? 0;
    final maleVal = int.tryParse(_controllers['1.1 ชาย (คน)']?.text ?? '') ?? 0;
    final femaleVal = int.tryParse(_controllers['1.2 หญิง (คน)']?.text ?? '') ?? 0;
    var finalVisited = visitedVal;
    if (finalVisited == 0 && (maleVal + femaleVal) > 0) {
      finalVisited = maleVal + femaleVal;
    }
    final notVisitedVal = int.tryParse(_controllers['2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน (คน)']?.text ?? '') ?? (_classStudentCount > finalVisited ? _classStudentCount - finalVisited : 0);
    final pct = _classStudentCount > 0 ? ((finalVisited / _classStudentCount) * 100.0).clamp(0.0, 100.0) : 0.0;

    final urgentCount = int.tryParse(_controllers['15. นักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วน (คน)']?.text ?? '') ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Class 5 KPI Stat Cards
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _buildMiniStatCard('นักเรียนทั้งหมด', '$_classStudentCount คน', 'มัธยมศึกษาปีที่ ${_formatClassLevelNum(_selectedClass)}', AppColors.purplePrimary, Icons.groups_rounded),
            _buildMiniStatCard('ออกเยี่ยมบ้านแล้ว', '$finalVisited คน', '${pct.toStringAsFixed(1)}% ของห้อง', Colors.green.shade700, Icons.check_circle_rounded),
            _buildMiniStatCard('ยังไม่ได้เยี่ยม', '$notVisitedVal คน', 'คงเหลือ', Colors.red.shade700, Icons.pending_actions_rounded),
            _buildMiniStatCard('จำแนกเพศ', 'ช $maleVal • ญ $femaleVal', 'ชาย $maleVal / หญิง $femaleVal คน', Colors.blue.shade700, Icons.wc_rounded),
            _buildMiniStatCard('รูปภาพเยี่ยมบ้าน', '${_classPhotos.length} รูป', 'ภาพหลักฐานที่บันทึก', AppColors.goldDark, Icons.photo_camera_rounded),
          ],
        ),

        const SizedBox(height: 18),

        // 2. Urgent Alert Banner (if any)
        if (urgentCount > 0)
          Container(
            margin: const EdgeInsets.only(bottom: 18),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.shade300, width: 1.5),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'พบนักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วนจำนวน $urgentCount คน',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF991B1B)),
                      ),
                      const Text(
                        'โปรดประสานงานครูแนะแนว หรือหัวหน้างานระบบดูแลช่วยเหลือนักเรียนเพื่อดำเนินการให้ความช่วยเหลือต่อไป',
                        style: TextStyle(fontSize: 12, color: Color(0xFFB91C1C)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

        // 3. Survey Findings Cards (ข้อมูลครอบครัว, ปัญหาสุขภาพ, ความเสี่ยง)
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.gold, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: AppColors.purplePrimary.withValues(alpha: 0.03),
                blurRadius: 6,
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
                  Row(
                    children: [
                      const Icon(Icons.analytics_rounded, color: AppColors.purplePrimary, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        'ผลการสำรวจและข้อมูลสภาพความเป็นอยู่นักเรียน ชั้น $_selectedClass',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.purpleDark),
                      ),
                    ],
                  ),
                  if (!(widget.apiService.currentUser?.isGuest ?? false))
                    App3DButton.gold(
                      icon: Icons.edit_note_rounded,
                      label: 'แก้ไขข้อมูลสำรวจ',
                      depth: 2.8,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      onPressed: () => setState(() => _classSubTab = 1),
                    ),
                ],
              ),
              const Divider(height: 24, color: AppColors.gold),

              // Summary Badges Grid
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildInsightBadge('ครอบครัวอบอุ่น', '${_controllers["4. ครอบครัวอบอุ่น (คน)"]?.text.trim().isEmpty ?? true ? "0" : _controllers["4. ครอบครัวอบอุ่น (คน)"]!.text.trim()} คน', Colors.green),
                  _buildInsightBadge('ครอบครัวแตกแยก', '${_controllers["5. ครอบครัวแตกแยก (คน)"]?.text.trim().isEmpty ?? true ? "0" : _controllers["5. ครอบครัวแตกแยก (คน)"]!.text.trim()} คน', Colors.deepOrange),
                  _buildInsightBadge('บิดา/มารดาเสียชีวิต', '${int.tryParse(_controllers["6. นักเรียนที่บิดาและมารดาเสียชีวิต (คน)"]?.text ?? "") ?? 0 + (int.tryParse(_controllers["7. นักเรียนที่บิดาหรือมารดาเสียชีวิต (คน)"]?.text ?? "") ?? 0)} คน', Colors.purple),
                  _buildInsightBadge('บิดามารดาเลิกร้าง', '${_controllers["8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน (คน)"]?.text.trim().isEmpty ?? true ? "0" : _controllers["8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน (คน)"]!.text.trim()} คน', Colors.amber.shade800),
                  _buildInsightBadge('ไม่ได้อยู่กับพ่อแม่', '${_controllers["9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาของตนเอง (คน)"]?.text.trim().isEmpty ?? true ? "0" : _controllers["9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาของตนเอง (คน)"]!.text.trim()} คน', Colors.blueGrey),
                  _buildInsightBadge('เสี่ยงด้านการเรียน', '${_controllers["10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน (คน)"]?.text.trim().isEmpty ?? true ? "0" : _controllers["10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน (คน)"]!.text.trim()} คน', Colors.orange),
                  _buildInsightBadge('มีปัญหาด้านสุขภาพ', '${_controllers["11. นักเรียนมีปัญหาด้านสุขภาพ (คน)"]?.text.trim().isEmpty ?? true ? "0" : _controllers["11. นักเรียนมีปัญหาด้านสุขภาพ (คน)"]!.text.trim()} คน', Colors.pink),
                  _buildInsightBadge('มีพฤติกรรมเสี่ยง', '${_controllers["12. นักเรียนมีพฤติกรรมเสี่ยง (คน)"]?.text.trim().isEmpty ?? true ? "0" : _controllers["12. นักเรียนมีพฤติกรรมเสี่ยง (คน)"]!.text.trim()} คน', Colors.red),
                  _buildInsightBadge('มีปัญหาเศรษฐกิจ', '${_controllers["13. นักเรียนมีปัญหาด้านเศรษฐกิจ (คน)"]?.text.trim().isEmpty ?? true ? "0" : _controllers["13. นักเรียนมีปัญหาด้านเศรษฐกิจ (คน)"]!.text.trim()} คน', Colors.indigo),
                  _buildInsightBadge('ต้องการช่วยเร่งด่วน', '$urgentCount คน', urgentCount > 0 ? Colors.red.shade700 : Colors.grey),
                ],
              ),

              const SizedBox(height: 18),

              // Qualitative Text Records (ถ้ามีกรอก)
              if ((_controllers['18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน']?.text.trim().isNotEmpty ?? false) ||
                  (_controllers['17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์อย่างไร']?.text.trim().isNotEmpty ?? false) ||
                  (_controllers['3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน']?.text.trim().isNotEmpty ?? false)) ...[
                const SizedBox(height: 8),
                const Text('บันทึกข้อคิดเห็นและข้อห่วงใย:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.purpleDark)),
                const SizedBox(height: 8),
                if (_controllers['18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน']?.text.trim().isNotEmpty ?? false)
                  _buildTextDetailTile('ข้อห่วงใยของผู้ปกครอง', _controllers['18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน']!.text.trim()),
                if (_controllers['17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์อย่างไร']?.text.trim().isNotEmpty ?? false)
                  _buildTextDetailTile('การนำข้อมูลไปใช้ประโยชน์', _controllers['17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์อย่างไร']!.text.trim()),
                if (_controllers['3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน']?.text.trim().isNotEmpty ?? false)
                  _buildTextDetailTile('สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน', _controllers['3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน']!.text.trim()),
              ],
            ],
          ),
        ),

        const SizedBox(height: 20),

        // 4. Web Symmetrical Photo Gallery Card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.gold, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: AppColors.purplePrimary.withValues(alpha: 0.03),
                blurRadius: 6,
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
                  Row(
                    children: [
                      const Icon(Icons.photo_library_rounded, color: AppColors.purplePrimary, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        'แกลเลอรีรูปภาพกิจกรรมการเยี่ยมบ้าน ชั้น $_selectedClass (${_classPhotos.length} รูป)',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.purpleDark),
                      ),
                    ],
                  ),
                  if (!(widget.apiService.currentUser?.isGuest ?? false))
                    App3DButton.gold(
                      icon: Icons.add_photo_alternate_rounded,
                      label: 'จัดการรูปภาพ / อัปโหลดเพิ่ม',
                      depth: 2.8,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      onPressed: () => setState(() => _classSubTab = 1),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'คลิกที่รูปภาพเพื่อเปิดดูภาพขนาดใหญ่ (ระบบจะจัดเรียงและปรับขนาดสมมาตรในเอกสารสรุปอัตโนมัติ)',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const Divider(height: 20, color: AppColors.gold),

              if (_classPhotos.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  alignment: Alignment.center,
                  child: Column(
                    children: [
                      Icon(Icons.photo_library_outlined, size: 54, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      Text(
                        'ยังไม่มีรูปภาพกิจกรรมการเยี่ยมบ้านสำหรับชั้น $_selectedClass',
                        style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'ท่านสามารถสลับไปที่แท็บ "กรอก/แก้ไขแบบสำรวจ" เพื่ออัปโหลดรูปภาพหลักฐานการเยี่ยมบ้าน',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 14),
                      if (!(widget.apiService.currentUser?.isGuest ?? false))
                        App3DButton.primary(
                          icon: Icons.add_a_photo_rounded,
                          label: 'ไปที่หน้าอัปโหลดรูปภาพ',
                          depth: 3.0,
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                          onPressed: () => setState(() => _classSubTab = 1),
                        ),
                    ],
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final crossAxisCount = constraints.maxWidth > 900 ? 3 : (constraints.maxWidth > 600 ? 2 : 1);
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                        childAspectRatio: 1.25, // 4:3 image + caption
                      ),
                      itemCount: _classPhotos.length,
                      itemBuilder: (context, idx) {
                        final photoName = _classPhotos[idx];
                        final photoUrl = widget.apiService.getHomeVisitPhotoUrl(_selectedYear, _selectedTerm, _selectedClass, photoName);

                        final customCap = _photoCaptionControllers[photoName]?.text.trim() ?? '';
                        final displayCap = customCap.isNotEmpty ? customCap : 'ภาพที่ ${idx + 1}: การเยี่ยมบ้านนักเรียน';
                        return InkWell(
                          onTap: () => _showPhotoLightbox(photoUrl, idx + 1, displayCap),
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFFAF8F5),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppColors.gold, width: 1.2),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.purplePrimary.withValues(alpha: 0.05),
                                  blurRadius: 5,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Image with 4:3 fit
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(9), topRight: Radius.circular(9)),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.network(
                                          photoUrl,
                                          fit: BoxFit.cover,
                                          errorBuilder: (ctx, err, stack) => const Center(
                                            child: Icon(Icons.broken_image_rounded, size: 40, color: Colors.grey),
                                          ),
                                        ),
                                        Positioned(
                                          right: 6,
                                          bottom: 6,
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                              color: Colors.black54,
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 18),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),

                                // Caption Badge
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFFBF4E2),
                                    borderRadius: BorderRadius.only(bottomLeft: Radius.circular(9), bottomRight: Radius.circular(9)),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        displayCap,
                                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF78350F)),
                                      ),
                                      const Icon(Icons.visibility_rounded, size: 14, color: AppColors.purplePrimary),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
            ],
          ),
        ),

        const SizedBox(height: 36),
      ],
    );
  }

  Widget _buildMiniStatCard(String title, String value, String subtitle, Color color, IconData icon) {
    return Container(
      width: 200,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold, width: 1.1),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
                Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
                Text(subtitle, style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsightBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: TextStyle(fontSize: 12, color: Colors.grey.shade800, fontWeight: FontWeight.w600)),
          Text(value, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildTextDetailTile(String title, String content) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• $title', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.purpleDark)),
          const SizedBox(height: 2),
          Text(content, style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // VIEW B: CLASS FORM EDITOR (กรอก/แก้ไขข้อมูลแบบสำรวจ)
  // -------------------------------------------------------------
  Widget _buildClassFormEditorView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 4 Main Form Question Cards
        ...formSections.map((sec) => _buildSectionCard(sec)),

        const SizedBox(height: 18),

        // Section 5: Photo Gallery (Default 6 slots + button to add extra slots)
        _buildPhotoGalleryCard(),

        const SizedBox(height: 24),

        // Bottom Big Save Button
        Center(
          child: App3DButton.success(
            icon: Icons.save_rounded,
            label: _saving ? 'กำลังบันทึกข้อมูลการเยี่ยมบ้าน...' : 'บันทึกข้อมูลและรูปภาพการเยี่ยมบ้านชั้น $_selectedClass',
            isLoading: _saving,
            depth: 3.5,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            onPressed: _saving ? null : _saveCurrentClassReport,
          ),
        ),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildSectionCard(Map<String, dynamic> sec) {
    final title = sec['title'] as String;
    final icon = sec['icon'] as IconData;
    final items = sec['items'] as List<Map<String, dynamic>>;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold, width: 1.2),
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
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.purpleContainer,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(13), topRight: Radius.circular(13)),
              border: Border(bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.35))),
            ),
            child: Row(
              children: [
                Icon(icon, color: AppColors.purplePrimary, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                ),
              ],
            ),
          ),

          // Question Fields
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              runSpacing: 12,
              children: items.map((it) {
                final key = it['key'] as String;
                final label = it['label'] as String;
                final unit = it['unit'] as String;
                final type = it['type'] as String;
                final ctrl = _controllers[key]!;

                final isNumber = type == 'number';
                final isTextArea = type == 'text' && (key.startsWith('3.') || key.startsWith('16.') || key.startsWith('17.') || key.startsWith('18.'));

                return SizedBox(
                  width: isTextArea ? double.infinity : (isNumber ? 220 : 360),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: ctrl,
                        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
                        maxLines: isTextArea ? 2 : 1,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          hintText: isNumber ? '0' : 'ระบุข้อความ...',
                          hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                          suffixText: unit.isNotEmpty ? unit : null,
                          suffixStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFFCFAF5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: AppColors.purplePrimary, width: 1.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // SECTION 5: PHOTO GALLERY (Default 6 slots + Button to add slots)
  // -------------------------------------------------------------
  Widget _buildPhotoGalleryCard() {
    // Total slots = at least 6, or more if extra slots added or photos count > 6
    final totalSlots = 6 + _extraSlots > _classPhotos.length ? (6 + _extraSlots) : _classPhotos.length;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold, width: 1.2),
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
          // Header with [+ เพิ่มช่องรูปภาพ] button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.purpleContainer,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(13), topRight: Radius.circular(13)),
              border: Border(bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.35))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.add_photo_alternate_rounded, color: AppColors.purplePrimary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '5. รูปภาพหลักฐานการเยี่ยมบ้าน (อัปโหลดแล้ว ${_classPhotos.length} รูป)',
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                    ),
                  ],
                ),
                App3DButton.gold(
                  icon: Icons.add_circle_outline_rounded,
                  label: '+ เพิ่มช่องรูปภาพ',
                  depth: 2.8,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  onPressed: () {
                    setState(() => _extraSlots++);
                  },
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'กำหนดให้มีค่าเบื้องต้น 6 กรอบรูปภาพ สามารถกดปุ่ม "+ เพิ่มช่องรูปภาพ" เพื่อเพิ่มรูปได้ไม่จำกัด รูปจะถูกจัดวางอย่างสมมาตรตรงกลางเอกสาร PDF และ Word อัตโนมัติ',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 14),

                // Responsive Grid of Photo Slots (3 columns on desktop, 2 on tablet, 1 on mobile)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final crossAxisCount = width >= 900 ? 3 : (width >= 600 ? 2 : 1);
                    final itemWidth = (width - (crossAxisCount - 1) * 14) / crossAxisCount;

                    return Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: List.generate(totalSlots, (slotIdx) {
                        final hasPhoto = slotIdx < _classPhotos.length;
                        final photoName = hasPhoto ? _classPhotos[slotIdx] : null;

                        return SizedBox(
                          width: itemWidth,
                          child: _buildPhotoSlotCard(slotIdx + 1, photoName),
                        );
                      }),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSlotCard(int slotNumber, String? photoName) {
    final hasPhoto = photoName != null;
    final photoUrl = hasPhoto
        ? widget.apiService.getHomeVisitPhotoUrl(_selectedYear, _selectedTerm, _selectedClass, photoName)
        : null;

    final captionController = hasPhoto
        ? _photoCaptionControllers.putIfAbsent(photoName, () => TextEditingController())
        : null;

    return Container(
      constraints: const BoxConstraints(minHeight: 275),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF8F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: hasPhoto ? AppColors.gold : Colors.grey.shade300,
          width: hasPhoto ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Slot Header Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: hasPhoto ? AppColors.goldLight : Colors.grey.shade200,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(9), topRight: Radius.circular(9)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'กรอบรูปภาพที่ $slotNumber',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    color: hasPhoto ? const Color(0xFF78350F) : Colors.grey.shade700,
                  ),
                ),
                if (hasPhoto)
                  InkWell(
                    onTap: () => _deletePhoto(photoName),
                    child: const Icon(Icons.delete_outline_rounded, size: 16, color: Colors.red),
                  ),
              ],
            ),
          ),

          // Photo Preview or Upload Prompt
          SizedBox(
            height: 160,
            child: hasPhoto
                ? ClipRRect(
                    child: Image.network(
                      photoUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (ctx, err, stack) => const Center(
                        child: Icon(Icons.broken_image_rounded, size: 40, color: Colors.grey),
                      ),
                    ),
                  )
                : InkWell(
                    onTap: _uploadingPhoto ? null : _pickAndUploadPhoto,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_a_photo_rounded, size: 36, color: Colors.grey.shade400),
                          const SizedBox(height: 6),
                          Text(
                            'คลิกเพื่ออัปโหลดรูปภาพ',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'JPG, PNG, WEBP (ย่อขนาดอัตโนมัติ)',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),

          // Custom Photo Caption Input Field
          if (hasPhoto)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: const BoxDecoration(
                color: Color(0xFFFBF4E2),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(9), bottomRight: Radius.circular(9)),
                border: Border(top: BorderSide(color: Color(0xFFE5D5B5), width: 1.0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ข้อความใต้ภาพ:',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.brown.shade800),
                  ),
                  const SizedBox(height: 3),
                  TextField(
                    controller: captionController,
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF1E1E24)),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      hintText: 'ภาพที่ $slotNumber: การเยี่ยมบ้านนักเรียน',
                      hintStyle: TextStyle(fontSize: 11, color: Colors.grey.shade400, fontStyle: FontStyle.italic),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: AppColors.gold, width: 1.5),
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

  // -------------------------------------------------------------
  // TAB 2: SCHOOL-WIDE DASHBOARD & COMPARISON
  // -------------------------------------------------------------
  Widget _buildSchoolDashboardView() {
    final summary = _summaryData?['summary'] as Map<String, dynamic>?;
    final classes = (_summaryData?['classes'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Action Bar: School-wide Download buttons
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.gold, width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: AppColors.purplePrimary.withValues(alpha: 0.03),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'รายงานสรุปภาพรวมผลการเยี่ยมบ้านระดับโรงเรียน (ทุกระดับชั้น)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.purpleDark),
                    ),
                    Text(
                      'รวบรวมข้อมูลคำนวณจากทุกห้อง ม.1 – ม.6 สำหรับเสนอผู้บริหารหรือเขตพื้นที่ ${widget.apiService.schoolAreaShort}',
                      style: const TextStyle(fontSize: 11.5, color: Colors.grey),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 10,
                  children: [
                    App3DButton.gold(
                      icon: Icons.visibility_rounded,
                      label: 'ดูตัวอย่างสรุป PDF',
                      depth: 3.2,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      onPressed: _previewSummaryPdf,
                    ),
                    if (_canDownload)

                      App3DButton.primary(
                        icon: Icons.picture_as_pdf_rounded,
                        label: 'ดาวน์โหลดสรุปทั้งโรงเรียน PDF',
                        depth: 3.2,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        onPressed: _downloadSummaryPdf,
                      ),
                    if (_canDownload)

                      App3DButton.secondary(
                        icon: Icons.description_rounded,
                        label: 'ดาวน์โหลดสรุปทั้งโรงเรียน Word',
                        depth: 3.0,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        onPressed: _downloadSummaryDocx,
                      ),
                    if (_canDownload)

                      App3DButton.secondary(
                        icon: Icons.article_outlined,
                        label: 'Word สรุปแบบไม่มีกรอบ',
                        depth: 3.0,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        onPressed: _downloadSummaryDocxFrameless,
                      ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          // 4 KPI Stat Cards
          _buildKpiCardsRow(summary),

          const SizedBox(height: 20),

          // Class Comparison Table Card
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.gold, width: 1.2),
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
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.purpleContainer,
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(13), topRight: Radius.circular(13)),
                    border: Border(bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.35))),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.table_chart_rounded, color: AppColors.purplePrimary, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'ตารางเปรียบเทียบผลการเยี่ยมบ้านแต่ละระดับชั้น (ม.1 – ม.6)',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                      ),
                    ],
                  ),
                ),

                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowHeight: 44,
                    dataRowMinHeight: 46,
                    dataRowMaxHeight: 52,
                    headingRowColor: WidgetStateProperty.all(const Color(0xFFFBF4E2)),
                    columns: const [
                      DataColumn(label: Text('ระดับชั้น', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('ครูที่ปรึกษา', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('นักเรียนทั้งหมด', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('เยี่ยมแล้ว', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('ร้อยละ (%)', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('ไม่ได้เยี่ยม', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('รูปภาพ', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('เอกสาร', style: TextStyle(fontWeight: FontWeight.bold))),
                    ],
                    rows: classes.map((c) {
                      final cl = c['class_level']?.toString() ?? '';
                                            final pct = (c['percentage'] as num?)?.toDouble() ?? 0.0;

                      return DataRow(
                        cells: [
                          DataCell(
                            InkWell(
                              onTap: () {
                                setState(() {
                                  _selectedClass = cl;
                                  _classAdvisorName = '';
                                  _classStudentCount = 0;
                                  _classPhotos = [];
                                  _classSubTab = 0;
                                  _tabController.animateTo(0);
                                });
                                _loadClassReport();
                              },
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(cl, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.purpleDark, decoration: TextDecoration.underline)),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.open_in_new_rounded, size: 13, color: AppColors.purplePrimary),
                                ],
                              ),
                            ),
                          ),
                          DataCell(Text(c['advisor_name']?.toString() ?? '-')),
                          DataCell(Text('${c['student_count']} คน')),
                          DataCell(Text('${c['visited_count']} คน', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal))),
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: pct >= 80 ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '$pct%',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: pct >= 80 ? const Color(0xFF15803D) : const Color(0xFFB91C1C),
                                ),
                              ),
                            ),
                          ),
                          DataCell(Text('${c['not_visited_count']} คน')),
                          DataCell(Text('${c['photos_count']} รูป')),
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'ดูตัวอย่าง PDF ชั้น $cl',
                                  icon: const Icon(Icons.visibility_rounded, size: 20, color: AppColors.purplePrimary),
                                  onPressed: () {
                                    final u = widget.apiService.getHomeVisitClassPdfPreviewUrl(cl, term: _selectedTerm, year: _selectedYear);
                                    launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
                                  },
                                ),
                                if (_canDownload)

                                IconButton(

                                  tooltip: 'ดาวน์โหลด PDF ชั้น $cl',
                                  icon: const Icon(Icons.picture_as_pdf_rounded, size: 18, color: Colors.red),
                                  onPressed: () {
                                    final u = widget.apiService.getHomeVisitClassPdfUrl(cl, term: _selectedTerm, year: _selectedYear);
                                    launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
                                  },
                                ),
                                if (_canDownload)

                                IconButton(

                                  tooltip: 'ดาวน์โหลด Word ชั้น $cl',
                                  icon: const Icon(Icons.description_rounded, size: 18, color: Colors.blue),
                                  onPressed: () {
                                    final u = widget.apiService.getHomeVisitClassDocxUrl(cl, term: _selectedTerm, year: _selectedYear);
                                    launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Aggregated Screening Data Summary Table across all grades
          _buildSchoolScreeningSummaryCard(),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSchoolScreeningSummaryCard() {
    final screeningList = (_summaryData?['screening_totals'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    if (screeningList.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold, width: 1.2),
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
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.purpleContainer,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(13), topRight: Radius.circular(13)),
              border: Border(bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.35))),
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fact_check_rounded, color: AppColors.purplePrimary, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'ตารางสรุปผลการคัดกรองข้อมูลนักเรียนจากการเยี่ยมบ้าน (รวมทุกระดับชั้น ม.1 – ม.6)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.gold.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.gold, width: 0.8),
                  ),
                  child: const Text(
                    'รวม 28 รายการคัดกรอง',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: AppColors.purpleDark),
                  ),
                ),
              ],
            ),
          ),

          // Table
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 44,
              dataRowMinHeight: 42,
              dataRowMaxHeight: double.infinity,
              headingRowColor: WidgetStateProperty.all(const Color(0xFFFBF4E2)),
              columns: const [
                DataColumn(label: Text('รายการ / หัวข้อการคัดกรอง', style: TextStyle(fontWeight: FontWeight.bold))),
                DataColumn(label: Center(child: Text('ม.1', style: TextStyle(fontWeight: FontWeight.bold)))),
                DataColumn(label: Center(child: Text('ม.2', style: TextStyle(fontWeight: FontWeight.bold)))),
                DataColumn(label: Center(child: Text('ม.3', style: TextStyle(fontWeight: FontWeight.bold)))),
                DataColumn(label: Center(child: Text('ม.4', style: TextStyle(fontWeight: FontWeight.bold)))),
                DataColumn(label: Center(child: Text('ม.5', style: TextStyle(fontWeight: FontWeight.bold)))),
                DataColumn(label: Center(child: Text('ม.6', style: TextStyle(fontWeight: FontWeight.bold)))),
                DataColumn(label: Center(child: Text('รวมทั้งโรงเรียน', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.purpleDark)))),
                DataColumn(label: Center(child: Text('หน่วย', style: TextStyle(fontWeight: FontWeight.bold)))),
              ],
              rows: screeningList.map((item) {
                final isSub = item['is_sub'] == true;
                final isNum = item['type'] == 'number';
                final label = item['label']?.toString() ?? '';
                final val = item['value']?.toString() ?? '-';
                final unit = item['unit']?.toString() ?? '';
                final byClass = item['by_class'] as Map<String, dynamic>? ?? {};

                Color? rowBg;
                if (!isSub && (label.startsWith('1.') || label.startsWith('4.') || label.startsWith('10.') || label.startsWith('12.') || label.startsWith('16.'))) {
                  rowBg = const Color(0xFFFAF7F2);
                }

                Widget buildClassCell(String cl) {
                  final raw = byClass[cl]?.toString().trim() ?? '';
                  if (isNum) {
                    final numVal = raw.isNotEmpty ? raw : '0';
                    return SizedBox(
                      width: 45,
                      child: Center(
                        child: Text(
                          numVal,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: numVal != '0' ? FontWeight.w600 : FontWeight.normal,
                            color: numVal != '0' ? Colors.black87 : Colors.grey.shade400,
                          ),
                        ),
                      ),
                    );
                  }
                  if (raw.isEmpty || raw == '-' || raw == 'ไม่มี' || raw == 'ไม่พบ') {
                    return SizedBox(
                      width: 45,
                      child: Center(
                        child: Text('-', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                      ),
                    );
                  }
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 130),
                    child: Tooltip(
                      message: raw,
                      child: Text(
                        raw,
                        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade800),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                }

                return DataRow(
                  color: rowBg != null ? WidgetStateProperty.all(rowBg) : null,
                  cells: [
                    // Col 0: Label
                    DataCell(
                      Padding(
                        padding: EdgeInsets.only(left: isSub ? 16.0 : 0.0),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: isSub ? 13 : 13.5,
                              fontWeight: isSub ? FontWeight.normal : FontWeight.bold,
                              color: isSub ? Colors.black87 : AppColors.purpleDark,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // ม.1 - ม.6
                    DataCell(buildClassCell('ม.1')),
                    DataCell(buildClassCell('ม.2')),
                    DataCell(buildClassCell('ม.3')),
                    DataCell(buildClassCell('ม.4')),
                    DataCell(buildClassCell('ม.5')),
                    DataCell(buildClassCell('ม.6')),
                    // รวมทั้งโรงเรียน
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 90, maxWidth: 360),
                        child: isNum
                            ? Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: val != '0' && val != '-' ? const Color(0xFFDCFCE7) : const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: val != '0' && val != '-' ? const Color(0xFF86EFAC) : const Color(0xFFE5E7EB),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    val,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: val != '0' && val != '-' ? const Color(0xFF15803D) : Colors.black87,
                                    ),
                                  ),
                                ),
                              )
                            : (val == '-'
                                ? Center(
                                    child: Text('-', style: TextStyle(fontSize: 13, color: Colors.grey.shade500, fontWeight: FontWeight.bold)),
                                  )
                                : _buildSummaryTextValueCell(val)),
                      ),
                    ),
                    // หน่วย
                    DataCell(
                      SizedBox(
                        width: 45,
                        child: Center(
                          child: Text(unit, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                        ),
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

Widget _buildSummaryTextValueCell(String val) {
    final lines = val.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) {
      return Center(
        child: Text('-', style: TextStyle(fontSize: 13, color: Colors.grey.shade500, fontWeight: FontWeight.bold)),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines.map((line) {
          final trimmed = line.trim();
          final hasDash = trimmed.startsWith('-');
          final content = hasDash ? trimmed.replaceFirst(RegExp(r'^[-—\s]+'), '') : trimmed;
          if (!hasDash) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                content,
                textAlign: TextAlign.justify,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.purpleDark,
                  fontWeight: FontWeight.w500,
                  height: 1.45,
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 20,
                  child: Text(
                    '-',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: AppColors.purpleDark,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    content,
                    textAlign: TextAlign.justify,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.purpleDark,
                      fontWeight: FontWeight.w500,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildKpiCardsRow(Map<String, dynamic>? summary) {
    final totalSt = summary?['total_students'] ?? 0;
    final totalVis = summary?['total_visited'] ?? 0;
    final avgPct = summary?['average_percentage'] ?? 0.0;
    final warmFam = summary?['warm_family'] ?? 0;
    final econProb = summary?['economy_problem'] ?? 0;

    final cards = [
      _buildStatCard('นักเรียนทั้งหมด', '$totalSt คน', 'รวม 6 ระดับชั้น', Icons.people_alt_rounded, AppColors.purplePrimary),
      _buildStatCard('เยี่ยมบ้านแล้ว', '$totalVis คน', 'คิดเป็น $avgPct% ของทั้งโรงเรียน', Icons.task_alt_rounded, Colors.teal),
      _buildStatCard('ครอบครัวอบอุ่น', '$warmFam คน', 'สภาพครอบครัวปกติ', Icons.family_restroom_rounded, Colors.indigo),
      _buildStatCard('ปัญหาเศรษฐกิจ', '$econProb คน', 'ต้องการทุนช่วยเหลือ', Icons.monetization_on_rounded, Colors.orange.shade800),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 800) {
          return Row(children: cards.map((c) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5), child: c))).toList());
        } else {
          return Column(children: cards.map((c) => Padding(padding: const EdgeInsets.only(bottom: 8), child: c)).toList());
        }
      },
    );
  }

  Widget _buildStatCard(String title, String value, String subtitle, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold, width: 1.2),
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
              Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87)),
              Icon(icon, color: color, size: 20),
            ],
          ),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}
