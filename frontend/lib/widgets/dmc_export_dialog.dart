import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';

class DmcExportDialog extends StatefulWidget {
  final ApiService apiService;
  final String initialTerm;
  final String initialYear;
  final String initialClassLevel;
  final String? initialRoom;
  final List<Map<String, dynamic>>? students;

  const DmcExportDialog({
    super.key,
    required this.apiService,
    required this.initialTerm,
    required this.initialYear,
    required this.initialClassLevel,
    this.initialRoom,
    this.students,
  });

  static Future<void> show(
    BuildContext context, {
    required ApiService apiService,
    required String initialTerm,
    required String initialYear,
    required String initialClassLevel,
    String? initialRoom,
    List<Map<String, dynamic>>? students,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => DmcExportDialog(
        apiService: apiService,
        initialTerm: initialTerm,
        initialYear: initialYear,
        initialClassLevel: initialClassLevel,
        initialRoom: initialRoom,
        students: students,
      ),
    );
  }

  @override
  State<DmcExportDialog> createState() => _DmcExportDialogState();
}

class _DmcExportDialogState extends State<DmcExportDialog> {
  late String _term;
  late String _year;
  late String _classLevel;
  String _selectedRoom = 'all';

  List<Map<String, dynamic>> _students = [];
  bool _loadingStudents = false;

  bool _customSelectStudents = false;
  final Set<String> _selectedStudentIds = {};
  String _searchQuery = '';

  // Column mode: 'all' or 'custom'
  String _columnMode = 'all';
  final Set<String> _selectedGroups = {'student', 'parents'};

  bool _exporting = false;

  final List<String> _classLevels = ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6', 'all'];

  @override
  void initState() {
    super.initState();
    _term = widget.initialTerm;
    _year = widget.initialYear;
    _classLevel = widget.initialClassLevel;
    _selectedRoom = widget.initialRoom ?? 'all';

    // Populate initial students if provided and specific level
    if (widget.students != null && widget.students!.isNotEmpty && widget.initialClassLevel != 'all') {
      _students = List.from(widget.students!);
      for (final s in _students) {
        final sid = s['student_id']?.toString() ?? '';
        if (sid.isNotEmpty) _selectedStudentIds.add(sid);
      }
    }

    // Always fetch from backend to ensure we have all rooms and full data across the selected level
    _fetchStudents();
  }

  Future<void> _fetchStudents() async {
    setState(() => _loadingStudents = true);
    try {
      // Fetch all rooms for this level so user can filter rooms dynamically
      final list = await widget.apiService.getClassStudents(
        term: _term,
        year: _year,
        classLevel: _classLevel,
      );
      if (mounted) {
        setState(() {
          _students = list;
          _loadingStudents = false;
          _selectedStudentIds.clear();
          for (final s in _students) {
            final sid = s['student_id']?.toString() ?? '';
            if (sid.isNotEmpty) _selectedStudentIds.add(sid);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingStudents = false);
      }
    }
  }

  List<String> _getAvailableRooms() {
    final rooms = <String>{};
    for (final s in _students) {
      final rm = s['room']?.toString().trim();
      if (rm != null && rm.isNotEmpty && rm != 'all') {
        rooms.add(rm);
      }
    }
    // Always provide at least room 1 and 2 as standard options
    rooms.add('1');
    rooms.add('2');

    final sorted = rooms.toList()
      ..sort((a, b) {
        final na = int.tryParse(a);
        final nb = int.tryParse(b);
        if (na != null && nb != null) return na.compareTo(nb);
        return a.compareTo(b);
      });
    return ['all', ...sorted];
  }

  List<Map<String, dynamic>> _getFilteredStudents() {
    return _students.where((s) {
      // Room filter
      if (_selectedRoom != 'all') {
        final rm = s['room']?.toString().trim() ?? '1';
        if (rm != _selectedRoom) return false;
      }
      // Search filter
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final name = (s['full_name'] ?? '').toString().toLowerCase();
        final sid = (s['student_id'] ?? '').toString().toLowerCase();
        final cl = (s['class_level'] ?? '').toString().toLowerCase();
        if (!name.contains(q) && !sid.contains(q) && !cl.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  List<String>? _resolveColumnsSubset() {
    if (_columnMode == 'all') return null; // All 39 DMC columns

    final cols = <String>[];
    // Map group to field names preserving DMC order
    if (_selectedGroups.contains('school')) {
      cols.addAll(['school_id', 'school_name']);
    }
    if (_selectedGroups.contains('student')) {
      cols.addAll(['citizen_id', 'class_level', 'room', 'student_id', 'gender', 'prefix', 'first_name', 'last_name']);
    }
    if (_selectedGroups.contains('health')) {
      cols.addAll(['birth_date', 'age', 'weight', 'height', 'blood_group', 'religion', 'race', 'nationality']);
    }
    if (_selectedGroups.contains('address')) {
      cols.addAll(['address_no', 'moo', 'street', 'subdistrict', 'district', 'province']);
    }
    if (_selectedGroups.contains('guardian')) {
      cols.addAll(['guardian_prefix', 'guardian_name', 'guardian_lastname', 'guardian_occupation', 'guardian_relation']);
    }
    if (_selectedGroups.contains('parents')) {
      cols.addAll(['father_prefix', 'father_name', 'father_lastname', 'father_occupation', 'mother_prefix', 'mother_name', 'mother_lastname', 'mother_occupation']);
    }
    if (_selectedGroups.contains('status')) {
      cols.addAll(['disadvantaged', 'cannot_discharge']);
    }
    return cols.isNotEmpty ? cols : null;
  }

  Future<void> _handleExport() async {
    setState(() => _exporting = true);
    try {
      final columnsSubset = _resolveColumnsSubset();
      final filteredStudents = _getFilteredStudents();

      List<String>? targetStudentIds;
      if (_customSelectStudents) {
        final validIds = filteredStudents
            .map((s) => s['student_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty && _selectedStudentIds.contains(id))
            .toList();
        if (validIds.isEmpty) {
          throw Exception('กรุณาเลือกนักเรียนอย่างน้อย 1 คน');
        }
        targetStudentIds = validIds;
      }

      final downloadUrl = widget.apiService.getExportDmcUrl(
        term: _term,
        year: _year,
        classLevel: _classLevel,
        room: _selectedRoom,
        studentIds: targetStudentIds,
        columns: columnsSubset,
      );

      final uri = Uri.parse(downloadUrl);
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF15803D),
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 8),
                Text('กำลังดาวน์โหลดไฟล์รายชื่อนักเรียน DMC (${_classLevel != "all" ? _classLevel : "ทุกระดับชั้น"}) สำเร็จ'),
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
            content: Text('เกิดข้อผิดพลาดในการนำออก: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final availableRooms = _getAvailableRooms();
    final filteredStudents = _getFilteredStudents();

    final selectedInFiltered = filteredStudents
        .where((s) => _selectedStudentIds.contains(s['student_id']?.toString()))
        .length;
    final int studentExportCount = _customSelectStudents ? selectedInFiltered : filteredStudents.length;

    final int colExportCount = _columnMode == 'all' ? 39 : (_resolveColumnsSubset()?.length ?? 39);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
              decoration: const BoxDecoration(
                color: Color(0xFF1A237E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.file_download_rounded, color: Color(0xFFFACC15), size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'นำออกรายชื่อนักเรียน (Export DMC Excel)',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'จัดรูปแบบและเรียงลำดับคอลัมน์ตามแบบฟอร์ม DMC ของ สพฐ. อย่างเป็นทางการ',
                          style: TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // 2. Body
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Section A: Scope Selection
                    _buildSectionTitle('1. เลือกระดับชั้นและห้องเรียนที่ต้องการนำออก', Icons.groups_rounded),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        children: [
                          // Level
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('ระดับชั้น', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                                const SizedBox(height: 4),
                                DropdownButtonFormField<String>(
                                  value: _classLevel,
                                  isDense: true,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                    fillColor: Colors.white,
                                    filled: true,
                                  ),
                                  items: _classLevels.map((lvl) {
                                    return DropdownMenuItem(
                                      value: lvl,
                                      child: Text(lvl == 'all' ? 'ทุกระดับชั้น (ม.1 - ม.6)' : lvl, style: const TextStyle(fontSize: 13)),
                                    );
                                  }).toList(),
                                  onChanged: (val) {
                                    if (val != null && val != _classLevel) {
                                      setState(() {
                                        _classLevel = val;
                                        if (val == 'all') {
                                          _selectedRoom = 'all';
                                        }
                                      });
                                      _fetchStudents();
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Room
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('ห้องเรียน', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                                const SizedBox(height: 4),
                                DropdownButtonFormField<String>(
                                  value: availableRooms.contains(_selectedRoom) ? _selectedRoom : 'all',
                                  isDense: true,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                    fillColor: Colors.white,
                                    filled: true,
                                  ),
                                  items: availableRooms.map((rm) {
                                    return DropdownMenuItem(
                                      value: rm,
                                      child: Text(
                                        rm == 'all' ? 'ทุกห้อง' : 'ห้อง $rm',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: rm == 'all' ? FontWeight.bold : FontWeight.normal,
                                          color: rm == 'all' ? const Color(0xFF1A237E) : Colors.black87,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (val) {
                                    if (val != null) setState(() => _selectedRoom = val);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Section B: Student Selection Mode
                    _buildSectionTitle('2. รูปแบบการเลือกนักเรียน', Icons.checklist_rounded),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => setState(() => _customSelectStudents = false),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                              decoration: BoxDecoration(
                                color: !_customSelectStudents ? const Color(0xFFEFF6FF) : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: !_customSelectStudents ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1),
                                  width: !_customSelectStudents ? 1.5 : 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Radio<bool>(
                                    value: false,
                                    groupValue: _customSelectStudents,
                                    onChanged: (val) => setState(() => _customSelectStudents = false),
                                  ),
                                  const Expanded(
                                    child: Text(
                                      'นำออกนักเรียนทุกคนตามเงื่อนไข',
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkWell(
                            onTap: () => setState(() => _customSelectStudents = true),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                              decoration: BoxDecoration(
                                color: _customSelectStudents ? const Color(0xFFEFF6FF) : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: _customSelectStudents ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1),
                                  width: _customSelectStudents ? 1.5 : 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Radio<bool>(
                                    value: true,
                                    groupValue: _customSelectStudents,
                                    onChanged: (val) => setState(() => _customSelectStudents = true),
                                  ),
                                  const Expanded(
                                    child: Text(
                                      'เลือกรายชื่อนักเรียนด้วยเช็คบ็อกซ์',
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    // Custom Student Checkboxes List (Visible when _customSelectStudents == true)
                    if (_customSelectStudents) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText: 'ค้นหาชื่อ หรือรหัสนักเรียน...',
                                      hintStyle: const TextStyle(fontSize: 12),
                                      prefixIcon: const Icon(Icons.search, size: 16),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                      fillColor: Colors.white,
                                      filled: true,
                                    ),
                                    onChanged: (val) => setState(() => _searchQuery = val.trim()),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                TextButton.icon(
                                  icon: const Icon(Icons.select_all_rounded, size: 16),
                                  label: const Text('เลือกทั้งหมด', style: TextStyle(fontSize: 12)),
                                  onPressed: () {
                                    setState(() {
                                      for (final s in filteredStudents) {
                                        final sid = s['student_id']?.toString() ?? '';
                                        if (sid.isNotEmpty) _selectedStudentIds.add(sid);
                                      }
                                    });
                                  },
                                ),
                                TextButton.icon(
                                  icon: const Icon(Icons.deselect_rounded, size: 16),
                                  label: const Text('ล้าง', style: TextStyle(fontSize: 12)),
                                  onPressed: () {
                                    setState(() {
                                      for (final s in filteredStudents) {
                                        final sid = s['student_id']?.toString() ?? '';
                                        if (sid.isNotEmpty) _selectedStudentIds.remove(sid);
                                      }
                                    });
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 180),
                              child: _loadingStudents
                                  ? const Center(
                                      child: Padding(
                                        padding: EdgeInsets.all(24.0),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            ),
                                            SizedBox(width: 10),
                                            Text('กำลังโหลดรายชื่อนักเรียน...', style: TextStyle(fontSize: 12, color: Colors.black54)),
                                          ],
                                        ),
                                      ),
                                    )
                                  : filteredStudents.isEmpty
                                      ? const Center(
                                          child: Padding(
                                            padding: EdgeInsets.all(16.0),
                                            child: Text('ไม่พบรายชื่อนักเรียนตามเงื่อนไขที่เลือก', style: TextStyle(color: Colors.grey, fontSize: 12)),
                                          ),
                                        )
                                      : ListView.builder(
                                          shrinkWrap: true,
                                          itemCount: filteredStudents.length,
                                          itemBuilder: (ctx, idx) {
                                            final st = filteredStudents[idx];
                                            final sid = st['student_id']?.toString() ?? '';
                                            final name = st['full_name']?.toString() ?? '';
                                            final rm = st['room']?.toString() ?? '1';
                                            final stClass = st['class_level']?.toString() ?? (_classLevel == 'all' ? '' : _classLevel);
                                            final isChecked = _selectedStudentIds.contains(sid);

                                            return CheckboxListTile(
                                              dense: true,
                                              visualDensity: VisualDensity.compact,
                                              value: isChecked,
                                              title: Text('$name ($sid)', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
                                              subtitle: Text(
                                                stClass.isNotEmpty ? 'ชั้น $stClass ห้อง $rm' : 'ห้อง $rm',
                                                style: const TextStyle(fontSize: 11, color: Colors.black54),
                                              ),
                                              controlAffinity: ListTileControlAffinity.leading,
                                              activeColor: const Color(0xFF1A237E),
                                              onChanged: (val) {
                                                setState(() {
                                                  if (val == true) {
                                                    _selectedStudentIds.add(sid);
                                                  } else {
                                                    _selectedStudentIds.remove(sid);
                                                  }
                                                });
                                              },
                                            );
                                          },
                                        ),
                            ),
                            Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(top: 4, right: 8),
                              child: Text(
                                'เลือกแล้ว $selectedInFiltered จาก ${filteredStudents.length} คน',
                                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),

                    // Section C: Column Selection
                    _buildSectionTitle('3. ข้อมูลที่ต้องการนำออก (คอลัมน์ DMC)', Icons.view_column_rounded),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          RadioListTile<String>(
                            dense: true,
                            value: 'all',
                            groupValue: _columnMode,
                            activeColor: const Color(0xFF1A237E),
                            title: const Text(
                              'นำออกครบทุกคอลัมน์ตามตาราง DMC (39 คอลัมน์)',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                            subtitle: const Text(
                              'รวมข้อมูลโรงเรียน นักเรียน ที่อยู่ สุขภาพ ผู้ปกครอง บิดา มารดา ความด้อยโอกาส ตามฟอร์ม สพฐ.',
                              style: TextStyle(fontSize: 11.5, color: Colors.black54),
                            ),
                            onChanged: (val) => setState(() => _columnMode = val!),
                          ),
                          RadioListTile<String>(
                            dense: true,
                            value: 'custom',
                            groupValue: _columnMode,
                            activeColor: const Color(0xFF1A237E),
                            title: const Text(
                              'เลือกเฉพาะหมวดหมู่ข้อมูลที่ต้องการ (จัดเรียงตามลำดับ DMC)',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                            subtitle: const Text(
                              'เลือกระบุคอลัมน์ เช่น รหัสนักเรียน เลขบัตรประชาชน ชื่อบิดา-มารดา โดยระบบจะคงลำดับคอลัมน์ DMC เสมอ',
                              style: TextStyle(fontSize: 11.5, color: Colors.black54),
                            ),
                            onChanged: (val) => setState(() => _columnMode = val!),
                          ),

                          if (_columnMode == 'custom') ...[
                            const Divider(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                _buildGroupChip('student', 'ข้อมูลนักเรียนพื้นฐาน (รหัส/ชื่อ/เพศ/เลขบัตรประชาชน)'),
                                _buildGroupChip('parents', 'ข้อมูลบิดา-มารดา (ชื่อ-สกุล/อาชีพ)'),
                                _buildGroupChip('guardian', 'ข้อมูลผู้ปกครอง (ชื่อ-สกุล/อาชีพ/ความเกี่ยวข้อง)'),
                                _buildGroupChip('address', 'ข้อมูลที่อยู่ตามทะเบียนบ้าน'),
                                _buildGroupChip('health', 'ข้อมูลสุขภาพ (วันเกิด/อายุ/น้ำหนัก/ส่วนสูง/เลือด)'),
                                _buildGroupChip('school', 'ข้อมูลโรงเรียน (รหัส/ชื่อโรงเรียน)'),
                                _buildGroupChip('status', 'สถานะและสิทธิ์ (ความด้อยโอกาส/จำหน่าย)'),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Section D: Summary Info Card
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, color: Color(0xFF16A34A), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'พร้อมนำออก: นักเรียน $studentExportCount คน | ข้อมูล $colExportCount คอลัมน์ (Excel .xlsx)',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF15803D)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 3. Footer
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _exporting ? null : () => Navigator.of(context).pop(),
                    child: const Text('ยกเลิก'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1A237E),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                    icon: _exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.file_download_rounded, size: 18),
                    label: Text(
                      _exporting ? 'กำลังส่งออก...' : 'ดาวน์โหลดไฟล์ Excel (.xlsx)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: (_exporting || studentExportCount <= 0) ? null : _handleExport,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF1A237E)),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
        ),
      ],
    );
  }

  Widget _buildGroupChip(String groupKey, String label) {
    final isSelected = _selectedGroups.contains(groupKey);
    return FilterChip(
      selected: isSelected,
      label: Text(label, style: TextStyle(fontSize: 11.5, color: isSelected ? Colors.white : Colors.black87)),
      selectedColor: const Color(0xFF1A237E),
      checkmarkColor: Colors.white,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      side: BorderSide(color: isSelected ? const Color(0xFF1A237E) : const Color(0xFFCBD5E1)),
      onSelected: (val) {
        setState(() {
          if (val) {
            _selectedGroups.add(groupKey);
          } else {
            if (_selectedGroups.length > 1) {
              _selectedGroups.remove(groupKey);
            }
          }
        });
      },
    );
  }
}
