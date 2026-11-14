import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../models/semester_config.dart';

class DmcImportDialog extends StatefulWidget {
  final ApiService apiService;
  final String initialTerm;
  final String initialYear;
  final List<SemesterConfigItem> semesters;

  const DmcImportDialog({
    super.key,
    required this.apiService,
    required this.initialTerm,
    required this.initialYear,
    this.semesters = const [],
  });

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required ApiService apiService,
    required String initialTerm,
    required String initialYear,
    List<SemesterConfigItem> semesters = const [],
  }) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DmcImportDialog(
        apiService: apiService,
        initialTerm: initialTerm,
        initialYear: initialYear,
        semesters: semesters,
      ),
    );
  }

  @override
  State<DmcImportDialog> createState() => _DmcImportDialogState();
}

class _DmcImportDialogState extends State<DmcImportDialog> {
  late String _selectedTerm;
  late String _selectedYear;
  // false = เพิ่มเฉพาะนักเรียนใหม่ (owner 10 พ.ย. 2569: the default; existing students keep everything)
  bool _overwrite = false;

  String? _pickedFileName;
  Uint8List? _pickedFileBytes;
  int? _pickedFileSize;

  bool _loadingPreview = false;
  Map<String, dynamic>? _previewData;
  String? _errorMessage;

  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _selectedTerm = widget.initialTerm;
    _selectedYear = widget.initialYear;
  }

  Future<void> _pickFile() async {
    try {
      setState(() {
        _errorMessage = null;
      });

      final result = await FilePicker.pickFiles(
        dialogTitle: 'เลือกไฟล์รายชื่อนักเรียน DMC (.xlsx, .xls, .csv)',
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls', 'csv'],
      );

      if (result.isEmpty) return;
      final file = result.first;
      final bytes = await file.readAsBytes();
      final size = file.lengthSync() ?? bytes.length;

      setState(() {
        _pickedFileName = file.name;
        _pickedFileBytes = bytes;
        _pickedFileSize = size;
      });
      await _loadPreview();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingPreview = false;
          _errorMessage = 'ตรวจสอบไฟล์ไม่สำเร็จ: $e';
        });
      }
    }
  }

  /// Reads the file on the server and compares it with the roster of the chosen semester (writes nothing).
  Future<void> _loadPreview() async {
    final bytes = _pickedFileBytes, name = _pickedFileName;
    if (bytes == null || name == null) return;
    setState(() {
      _loadingPreview = true;
      _previewData = null;
      _errorMessage = null;
    });
    try {
      final preview = await widget.apiService.previewDmcStudents(bytes, name, term: _selectedTerm, year: _selectedYear);
      if (mounted) {
        setState(() {
          _previewData = preview;
          _loadingPreview = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingPreview = false;
          _errorMessage = 'ตรวจสอบไฟล์ไม่สำเร็จ: $e';
        });
      }
    }
  }

  Map<String, dynamic>? get _compare => _previewData?['compare'] as Map<String, dynamic>?;

  int _count(String key) => ((_compare?['counts'] as Map?)?[key] as num?)?.toInt() ?? 0;

  bool get _nothingToAdd => _compare != null && !_overwrite && _count('new') == 0;

  Future<bool> _confirmOverwrite() async {
    final lines = <String>[
      'ภาคเรียนที่ $_selectedTerm/$_selectedYear เฉพาะชั้นที่มีในไฟล์:',
      '• ชื่อ ห้อง และเลขที่ จะเปลี่ยนตามไฟล์ DMC',
      if (_count('changed') > 0) '• แก้ชื่อ/ห้องตามไฟล์ ${_count('changed')} คน (รวมชื่อที่ครูแก้ไว้เอง)',
      if (_count('missing') > 0) '• นำออกจากรายชื่อ ${_count('missing')} คน (ไม่มีในไฟล์)',
      if (_count('other_level') > 0) '• ย้ายไปชั้นตามไฟล์ ${_count('other_level')} คน',
      if (_count('removed') > 0) '• นำกลับเข้ารายชื่อ ${_count('removed')} คน',
      '• ประวัติเช็คเวลาเรียนและคะแนนไม่ถูกลบ และระบบสำรองข้อมูลไว้ก่อนนำเข้า',
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ยืนยันปรับรายชื่อให้ตรงกับไฟล์?'),
        content: Text(lines.join('\n'), style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('ยกเลิก')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ยืนยันทับข้อมูล'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Widget _buildCompare() {
    final cmp = _compare;
    if (cmp == null) return const SizedBox.shrink();
    final add = !_overwrite;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.compare_arrows_rounded, size: 18, color: Colors.teal.shade700),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'เทียบกับรายชื่อภาคเรียนที่ ${cmp['term']}/${cmp['year']} ในระบบ (แตะเพื่อดูรายชื่อ)',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _cmpRow('new', Icons.person_add_alt_1_rounded, Colors.green.shade700, 'นักเรียนใหม่ (ยังไม่มีในภาคเรียนนี้)',
              add ? 'จะเพิ่มต่อท้ายเลขที่เดิมของชั้น' : 'จะเพิ่มเข้ารายชื่อ'),
          _cmpRow('same', Icons.check_circle_outline_rounded, Colors.blueGrey.shade700, 'มีอยู่แล้ว ข้อมูลตรงกับไฟล์',
              add ? 'คงข้อมูลเดิม' : 'เลขที่เรียงใหม่ตามไฟล์'),
          _cmpRow('changed', Icons.edit_note_rounded, Colors.orange.shade800, 'มีอยู่แล้ว แต่ชื่อหรือห้องในไฟล์ต่างจากระบบ',
              add ? 'คงข้อมูลเดิม ไม่แก้ตามไฟล์' : 'จะแก้ชื่อ/ห้องตามไฟล์'),
          _cmpRow('other_level', Icons.swap_horiz_rounded, Colors.indigo.shade700, 'อยู่ในรายชื่อชั้นอื่นของภาคเรียนนี้',
              add ? 'คงไว้ชั้นเดิม ไม่เพิ่มซ้ำ' : 'จะย้ายไปชั้นตามไฟล์'),
          _cmpRow('removed', Icons.person_off_outlined, Colors.brown.shade600, 'เคยถูกนำออกจากรายชื่อแล้ว',
              add ? 'ไม่เพิ่มกลับ (เพิ่มเองได้ที่ปุ่ม + หน้าเช็คเวลาเรียน)' : 'จะนำกลับเข้ารายชื่อ'),
          _cmpRow('missing', Icons.person_remove_alt_1_outlined, Colors.red.shade700, 'อยู่ในรายชื่อของระบบ แต่ไม่มีในไฟล์',
              add ? 'คงไว้ ไม่แตะ' : 'จะถูกนำออกจากรายชื่อ (ประวัติเช็คชื่อและคะแนนยังเก็บไว้)'),
          _cmpRow('no_id', Icons.warning_amber_rounded, Colors.red.shade700, 'แถวในไฟล์ที่ไม่มีเลขประจำตัวนักเรียน',
              'ข้าม นำเข้าไม่ได้'),
        ],
      ),
    );
  }

  Widget _cmpRow(String key, IconData icon, Color color, String label, String effect) {
    final n = _count(key);
    if (n == 0) return const SizedBox.shrink();
    final items = ((_compare?[key] as List?) ?? const []).cast<Map<String, dynamic>>();
    String line(Map<String, dynamic> s) {
      final base = '${s['class_level'] ?? ''} ห้อง ${s['room'] ?? ''} • ${s['student_id'] ?? ''} ${s['full_name'] ?? ''}';
      if (key == 'changed') {
        final diffs = (s['diffs'] as List?)?.cast<String>() ?? const <String>[];
        final was = <String>[
          if (diffs.contains('ชื่อ')) 'ในระบบ: ${s['old_name']}',
          if (diffs.contains('ห้อง')) 'ห้องในระบบ: ${s['old_room']}',
        ];
        return '$base  (${was.join(', ')})';
      }
      if (key == 'other_level') return '$base  (ตอนนี้อยู่ ${s['old_level']})';
      if (key == 'removed') return '$base  (เคยอยู่ ${s['old_level']})';
      if (key == 'missing' && s['is_locked'] == true) return '$base  (ล็อกไว้)';
      return base;
    }

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        tilePadding: const EdgeInsets.symmetric(horizontal: 2),
        childrenPadding: const EdgeInsets.fromLTRB(34, 0, 8, 8),
        leading: Icon(icon, color: color, size: 20),
        title: Text('$label: $n คน', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
        subtitle: Text('→ $effect', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
        children: [
          for (final s in items.take(60))
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(line(s), style: const TextStyle(fontSize: 11.5)),
              ),
            ),
          if (n > 60)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('… และอีก ${n - 60} คน', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ),
        ],
      ),
    );
  }

  Widget _buildModeChoice() {
    Widget option(bool overwrite, String title, String subtitle, Color color) {
      final selected = _overwrite == overwrite;
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _importing ? null : () => setState(() => _overwrite = overwrite),
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
            decoration: BoxDecoration(
              color: selected ? color.withValues(alpha: 0.06) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? color : Colors.grey.shade300, width: selected ? 1.5 : 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                    size: 20, color: selected ? color : Colors.grey.shade500),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? color : null)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade700, height: 1.35)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Icon(Icons.rule_rounded, size: 16, color: Colors.teal),
            SizedBox(width: 6),
            Text('3. วิธีนำเข้า:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
        option(false, 'เพิ่มเฉพาะนักเรียนใหม่ (แนะนำ)',
            'คนที่มีอยู่แล้วคงข้อมูลเดิมทั้งหมด: ชื่อ เลขที่ ห้อง การเช็คเวลาเรียน คะแนน — คนใหม่ต่อท้ายเลขที่เดิมและลงทะเบียนรายวิชาของชั้นให้อัตโนมัติ',
            Colors.teal.shade700),
        option(true, 'ปรับรายชื่อให้ตรงกับไฟล์ (ทับข้อมูลเดิม)',
            'ชื่อ ห้อง เลขที่ เปลี่ยนตามไฟล์ และคนที่ไม่มีในไฟล์ถูกนำออกจากรายชื่อ — ประวัติเช็คเวลาเรียนและคะแนนไม่ถูกลบ ระบบสำรองข้อมูลให้ก่อน',
            Colors.red.shade700),
      ],
    );
  }

  Future<void> _submitImport() async {
    if (_pickedFileBytes == null || _pickedFileName == null) {
      setState(() => _errorMessage = 'กรุณาเลือกไฟล์ DMC ก่อนดำเนินการ');
      return;
    }
    if (_overwrite && !await _confirmOverwrite()) return;

    setState(() {
      _importing = true;
      _errorMessage = null;
    });

    try {
      final res = await widget.apiService.importDmcStudents(
        _pickedFileBytes!,
        _pickedFileName!,
        term: _selectedTerm,
        year: _selectedYear,
        overwrite: _overwrite,
      );

      if (mounted) {
        Navigator.of(context).pop(res);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _importing = false;
          _errorMessage = 'การนำเข้าข้อมูลล้มเหลว: $e';
        });
      }
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final classes = (_previewData?['classes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final totalStudents = (_previewData?['total_students'] as num?)?.toInt() ?? 0;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.teal.shade200),
            ),
            child: Icon(Icons.table_view_rounded, color: Colors.teal.shade700, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'นำเข้าข้อมูลนักเรียนจากระบบ DMC',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  'นำเข้าไฟล์ Excel/CSV และจัดนักเรียนลงห้องเรียนอัตโนมัติ (ม.1 – ม.6)',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: _importing ? null : () => Navigator.of(context).pop(null),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Destination Semester Selection
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.calendar_month_outlined, size: 16, color: Colors.teal),
                        SizedBox(width: 6),
                        Text(
                          '1. กำหนดภาคเรียนปลายทางที่ต้องการนำเข้า:',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (widget.semesters.isNotEmpty)
                      DropdownButtonFormField<String>(
                        value: widget.semesters.any((s) => s.term == _selectedTerm && s.year == _selectedYear)
                            ? '$_selectedTerm-$_selectedYear'
                            : '${widget.semesters.first.term}-${widget.semesters.first.year}',
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        items: widget.semesters.map((s) {
                          return DropdownMenuItem<String>(
                            value: '${s.term}-${s.year}',
                            child: Text(
                              s.title.isNotEmpty ? s.title : 'ภาคเรียนที่ ${s.term}/${s.year}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          );
                        }).toList(),
                        onChanged: _importing
                            ? null
                            : (val) {
                                if (val != null) {
                                  final parts = val.split('-');
                                  setState(() {
                                    _selectedTerm = parts[0];
                                    _selectedYear = parts[1];
                                  });
                                  _loadPreview(); // the comparison depends on the semester
                                }
                              },
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedTerm,
                              decoration: InputDecoration(
                                labelText: 'ภาคเรียน',
                                isDense: true,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              items: const [
                                DropdownMenuItem(value: '1', child: Text('ภาคเรียนที่ 1')),
                                DropdownMenuItem(value: '2', child: Text('ภาคเรียนที่ 2')),
                              ],
                              onChanged: _importing
                                  ? null
                                  : (v) {
                                      setState(() => _selectedTerm = v ?? '1');
                                      _loadPreview();
                                    },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedYear,
                              decoration: InputDecoration(
                                labelText: 'ปีการศึกษา',
                                isDense: true,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              items: const [
                                DropdownMenuItem(value: '2567', child: Text('2567')),
                                DropdownMenuItem(value: '2568', child: Text('2568')),
                                DropdownMenuItem(value: '2569', child: Text('2569')),
                                DropdownMenuItem(value: '2570', child: Text('2570')),
                              ],
                              onChanged: _importing
                                  ? null
                                  : (v) {
                                      setState(() => _selectedYear = v ?? '2568');
                                      _loadPreview();
                                    },
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // 2. File Picker Section
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _pickedFileName == null ? Colors.teal.shade50.withOpacity(0.3) : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _pickedFileName == null ? Colors.teal.shade200 : Colors.teal.shade400,
                    width: _pickedFileName == null ? 1 : 1.5,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.file_present_rounded, size: 16, color: Colors.teal),
                        SizedBox(width: 6),
                        Text(
                          '2. เลือกไฟล์รายงานจากระบบ DMC (.xlsx, .xls, .csv):',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_pickedFileName == null)
                      Center(
                        child: Column(
                          children: [
                            Icon(Icons.cloud_upload_outlined, size: 40, color: Colors.teal.shade400),
                            const SizedBox(height: 6),
                            const Text(
                              'ไฟล์ส่งออกจากระบบ Data Management Center (DMC)',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  icon: const Icon(Icons.attach_file_rounded, size: 18),
                                  label: const Text('เลือกไฟล์จากเครื่อง'),
                                  style: FilledButton.styleFrom(backgroundColor: Colors.teal.shade700),
                                  onPressed: _importing ? null : _pickFile,
                                ),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.download_rounded, size: 18),
                                  label: const Text('ดาวน์โหลดแม่แบบ Excel'),
                                  onPressed: () {
                                    final url = widget.apiService.getStudentsTemplateUrl();
                                    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    else
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.teal.shade50,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.description_rounded, color: Colors.teal.shade700, size: 24),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _pickedFileName!,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (_pickedFileSize != null)
                                  Text(
                                    'ขนาดไฟล์: ${_formatFileSize(_pickedFileSize!)}',
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                              ],
                            ),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text('เปลี่ยนไฟล์', style: TextStyle(fontSize: 12)),
                            onPressed: _importing ? null : _pickFile,
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              // 3. Loading or Preview Data Display
              if (_loadingPreview) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: const Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('กำลังตรวจสอบและอ่านข้อมูลรายชื่อนักเรียน...', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ],

              if (_previewData != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.teal.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.check_circle_rounded, color: Colors.teal.shade700, size: 18),
                              const SizedBox(width: 6),
                              const Text(
                                'ตรวจสอบข้อมูลสำเร็จ — พบโครงสร้างห้องเรียน:',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.teal.shade700,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              'รวม $totalStudents คน',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Class level breakdown table
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Table(
                            columnWidths: const {
                              0: FlexColumnWidth(1.2),
                              1: FlexColumnWidth(1.0),
                              2: FlexColumnWidth(1.4),
                              3: FlexColumnWidth(2.4),
                            },
                            children: [
                              TableRow(
                                decoration: BoxDecoration(color: Colors.grey.shade100),
                                children: const [
                                  Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    child: Text('ระดับชั้น', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    child: Text('จำนวนนักเรียน', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    child: Text('ห้องเรียนที่พบ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    child: Text('ตัวอย่างรายชื่อ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                                ],
                              ),
                              ...classes.map((c) {
                                final cl = c['class_level'] ?? '';
                                final total = c['total'] ?? 0;
                                final rooms = (c['rooms'] as List?)?.join(', ') ?? '1';
                                final samples = (c['samples'] as List?)?.join(', ') ?? '';

                                return TableRow(
                                  decoration: BoxDecoration(
                                    border: Border(top: BorderSide(color: Colors.grey.shade100)),
                                  ),
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.indigo.shade50,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              cl,
                                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.indigo.shade900),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      child: Text('$total คน', style: const TextStyle(fontSize: 12)),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      child: Text('ห้อง $rooms', style: TextStyle(fontSize: 12, color: Colors.teal.shade800)),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      child: Text(
                                        samples,
                                        style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 3. Comparison with the roster of the chosen semester + how to import
              if (_previewData != null && _compare != null) ...[
                const SizedBox(height: 12),
                _buildCompare(),
              ],
              const SizedBox(height: 12),
              _buildModeChoice(),

              // Error display
              if (_errorMessage != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded, color: Colors.red.shade700, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(fontSize: 12, color: Colors.red.shade800),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(null),
          child: const Text('ยกเลิก'),
        ),
        FilledButton.icon(
          icon: _importing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.check_circle_rounded, size: 18),
          label: Text(
            _importing
                ? 'กำลังนำเข้าข้อมูล...'
                : _compare != null
                    ? (_overwrite
                        ? 'ปรับรายชื่อตามไฟล์ ($totalStudents คน)'
                        : (_nothingToAdd ? 'ไม่มีนักเรียนใหม่' : 'เพิ่มนักเรียนใหม่ (${_count('new')} คน)'))
                    : (_previewData != null ? 'ยืนยันนำเข้า ($totalStudents คน)' : 'ยืนยันนำเข้าข้อมูล'),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: _overwrite ? Colors.red.shade700 : Colors.teal.shade700,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
          onPressed: _importing || _loadingPreview || _pickedFileBytes == null || _nothingToAdd ? null : _submitImport,
        ),
      ],
    );
  }
}
