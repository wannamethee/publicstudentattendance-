import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/semester_config.dart';
import '../services/api_service.dart';

/// ฟอร์มนำเข้าข้อมูลโรงเรียน (admin): one workbook for teachers, programmes, rooms, students, courses,
/// teachers per room, timetable and enrolment by name. Download -> fill -> check (nothing written) -> save.
class SchoolImportCard extends StatefulWidget {
  final ApiService apiService;
  const SchoolImportCard({super.key, required this.apiService});

  @override
  State<SchoolImportCard> createState() => _SchoolImportCardState();
}

class _SchoolImportCardState extends State<SchoolImportCard> {
  List<SemesterConfigItem> _semesters = [];
  String? _sem; // "term|year"
  Uint8List? _bytes;
  String? _fileName;
  Map<String, dynamic>? _report;
  bool _busy = false;
  String _filter = 'error';

  @override
  void initState() {
    super.initState();
    _loadSemesters();
  }

  Future<void> _loadSemesters() async {
    try {
      final list = await widget.apiService.getSemesterConfigs();
      if (!mounted) return;
      final def = widget.apiService.defaultSemester;
      setState(() {
        _semesters = list;
        _sem = def != null ? '${def.term}|${def.year}' : (list.isNotEmpty ? '${list.last.term}|${list.last.year}' : null);
      });
    } catch (_) {}
  }

  String get _term => _sem!.split('|')[0];
  String get _year => _sem!.split('|')[1];

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? Colors.red.shade700 : null));
  }

  Future<void> _download(bool prefill, {bool full = false}) async {
    if (_sem == null) return;
    final uri = Uri.parse(widget.apiService.schoolImportTemplateUrl(_term, _year, prefill: prefill, full: full));
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) _snack('เปิดลิงก์ดาวน์โหลดไม่ได้', error: true);
  }

  Future<void> _pickAndCheck() async {
    if (_sem == null) return;
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (picked.isEmpty) return;
    final f = picked.first;
    final bytes = await f.readAsBytes();
    setState(() {
      _bytes = bytes;
      _fileName = f.name;
      _report = null;
    });
    await _check();
  }

  Future<void> _check() async {
    if (_bytes == null) return;
    setState(() => _busy = true);
    try {
      final r = await widget.apiService.schoolImport(_term, _year, _bytes!, _fileName ?? 'form.xlsx', commit: false);
      if (!mounted) return;
      setState(() {
        _report = r;
        _filter = (r['errors'] as num? ?? 0) > 0 ? 'error' : 'warning';
      });
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('บันทึกข้อมูลจากฟอร์มเข้าระบบ'),
        content: Text('ภาคเรียน $_term/$_year\n\n'
            '• ระบบสำรองฐานข้อมูลก่อนบันทึก (กู้คืนได้ที่ จัดเก็บข้อมูล → สำรองข้อมูล)\n'
            '• ตารางสอนของครูที่อยู่ในแผ่น 7 จะถูกแทนที่ทั้งชุด\n'
            '• นักเรียนลงทะเบียนรายวิชาอัตโนมัติตามระดับชั้น/โปรแกรม/รายชื่อ แล้วนับเวลาเรียนและปรับ ปพ.5 ใหม่\n'
            '• แผ่นข้อมูล (9 ขึ้นไป): แถวที่มีอยู่แล้วอัปเดต แถวใหม่เพิ่ม แถวที่ไม่อยู่ในไฟล์คงเดิม\n'
            '• ไม่มีการลบนักเรียน ครู หรือรายวิชา'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('บันทึก')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final r = await widget.apiService.schoolImport(_term, _year, _bytes!, _fileName ?? 'form.xlsx', commit: true);
      if (!mounted) return;
      setState(() => _report = r);
      if (r['committed'] == true) {
        final done = (r['done'] as Map?) ?? {};
        _snack('บันทึกแล้ว • ลงทะเบียนเพิ่ม ${done['enrolments_added'] ?? 0} รายการ • ตารางสอน ${done['timetable_rows'] ?? 0} คาบ'
            '${(done['data_rows'] ?? 0) > 0 ? ' • ข้อมูลระหว่างเทอม ${done['data_rows']} แถว' : ''}');
      } else {
        _snack('ยังบันทึกไม่ได้ ไฟล์มีจุดที่ต้องแก้', error: true);
      }
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _report;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.indigo.shade100, borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.dataset_linked_outlined, color: Colors.indigo.shade900),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('นำเข้าข้อมูลโรงเรียน (ฟอร์มมาตรฐาน)', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                Text(
                  'ไฟล์เดียว 8 แผ่น ตรงกับฐานข้อมูล: ครู • โปรแกรม • ห้องเรียน • นักเรียน • รายวิชา • ครูผู้สอนรายห้อง • ตารางสอน • วิชาเลือกรายคน '
                  '— รองรับหลายห้องและหลายโปรแกรมต่อชั้น ตรวจทุกแถวก่อนบันทึก • "ไฟล์ข้อมูลทั้งหมด" มีแผ่น 9 ขึ้นไปเพิ่ม '
                  '(ผลการเรียน เช็คชื่อรายวัน ตั้งค่า DMC เยี่ยมบ้าน ข้อสอบ การลา ...) ส่งออกแล้วนำเข้าไฟล์เดียวได้ครบทุกหน้า',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                initialValue: _sem,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'ภาคเรียนที่นำเข้า', border: OutlineInputBorder(), isDense: true),
                items: [
                  for (final s in _semesters) DropdownMenuItem(value: '${s.term}|${s.year}', child: Text('ภาคเรียนที่ ${s.term}/${s.year}')),
                ],
                onChanged: _busy ? null : (v) => setState(() {
                  _sem = v;
                  _report = null;
                }),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _sem == null ? null : () => _download(true),
              icon: const Icon(Icons.download_rounded),
              label: const Text('1. ดาวน์โหลดพร้อมข้อมูลปัจจุบัน'),
            ),
            OutlinedButton.icon(
              onPressed: _sem == null ? null : () => _download(true, full: true),
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('ไฟล์ข้อมูลทั้งหมด (รวมคะแนน เวลาเรียน)'),
            ),
            TextButton.icon(
              onPressed: _sem == null ? null : () => _download(false),
              icon: const Icon(Icons.description_outlined),
              label: const Text('แบบฟอร์มเปล่า'),
            ),
            FilledButton.tonalIcon(
              onPressed: _sem == null || _busy ? null : _pickAndCheck,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('2. เลือกไฟล์แล้วตรวจ'),
            ),
            if (_bytes != null)
              IconButton(tooltip: 'ตรวจไฟล์เดิมอีกครั้ง', onPressed: _busy ? null : _check, icon: const Icon(Icons.refresh_rounded)),
            FilledButton.icon(
              onPressed: r != null && r['can_commit'] == true && r['committed'] != true && !_busy ? _commit : null,
              icon: const Icon(Icons.save_rounded),
              label: const Text('3. บันทึกเข้าระบบ'),
            ),
          ]),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (r != null) ...[
            const SizedBox(height: 14),
            _summaryLine(r),
            const SizedBox(height: 10),
            _sheetTable(r),
            const SizedBox(height: 10),
            _issueList(r),
          ],
        ]),
      ),
    );
  }

  Widget _summaryLine(Map<String, dynamic> r) {
    final errors = (r['errors'] as num?)?.toInt() ?? 0;
    final warnings = (r['warnings'] as num?)?.toInt() ?? 0;
    final committed = r['committed'] == true;
    final color = committed ? const Color(0xFF15803D) : (errors > 0 ? Colors.red.shade700 : const Color(0xFF1D4ED8));
    final text = committed
        ? 'บันทึกเรียบร้อย ($_fileName) • สำรองข้อมูลไว้ที่ ${r['backup_id'] ?? '-'}'
        : errors > 0
            ? '$_fileName: ต้องแก้ $errors จุด (สีแดง) ก่อนบันทึก • เตือน $warnings จุด'
            : '$_fileName: ตรวจผ่าน พร้อมบันทึก • เตือน $warnings จุด (บันทึกได้ แต่ควรอ่าน)';
    return Row(children: [
      Icon(committed ? Icons.check_circle_rounded : (errors > 0 ? Icons.error_rounded : Icons.task_alt_rounded), color: color),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
    ]);
  }

  Widget _sheetTable(Map<String, dynamic> r) {
    final sheets = ((r['sheets'] as List?) ?? []).cast<Map>();
    Widget cell(String s, {bool head = false, Color? color, TextAlign align = TextAlign.center}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Text(s, textAlign: align, style: TextStyle(fontSize: 12.5, fontWeight: head ? FontWeight.bold : null, color: color)),
        );
    String n(dynamic v) => (v as num? ?? 0) == 0 ? '-' : '$v';
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: Colors.grey.shade300),
        children: [
          TableRow(decoration: BoxDecoration(color: Colors.grey.shade100), children: [
            for (final h in ['แผ่น', 'ตารางในระบบ', 'แถว', 'ใหม่', 'แก้ไข', 'เหมือนเดิม', 'ต้องแก้', 'เตือน']) cell(h, head: true),
          ]),
          for (final s in sheets)
            TableRow(children: [
              cell('${s['title']}', align: TextAlign.left),
              cell('${s['tables']}', color: Colors.grey.shade700, align: TextAlign.left),
              cell(n(s['rows'])),
              cell(n(s['new']), color: const Color(0xFF15803D)),
              cell(n(s['update']), color: const Color(0xFF1D4ED8)),
              cell(n(s['same']), color: Colors.grey.shade700),
              cell(n(s['errors']), color: Colors.red.shade700),
              cell(n(s['warnings']), color: Colors.orange.shade800),
            ]),
        ],
      ),
    );
  }

  Widget _issueList(Map<String, dynamic> r) {
    final all = ((r['issues'] as List?) ?? []).cast<Map>();
    final shown = all.where((i) => i['level'] == _filter).toList();
    const labels = {'error': 'ต้องแก้', 'warning': 'เตือน', 'info': 'ข้อมูล'};
    final colors = {'error': Colors.red.shade700, 'warning': Colors.orange.shade800, 'info': Colors.blueGrey};
    final icons = {'error': Icons.error_outline, 'warning': Icons.warning_amber_rounded, 'info': Icons.info_outline};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, children: [
        for (final k in labels.keys)
          ChoiceChip(
            label: Text('${labels[k]} ${all.where((i) => i['level'] == k).length}'),
            selected: _filter == k,
            onSelected: (_) => setState(() => _filter = k),
          ),
        if ((r['issue_total'] as num? ?? 0) > all.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('แสดง ${all.length} จาก ${r['issue_total']} รายการ', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ),
      ]),
      const SizedBox(height: 6),
      if (shown.isEmpty)
        Padding(padding: const EdgeInsets.all(8), child: Text('ไม่มีรายการ${labels[_filter]}', style: TextStyle(color: Colors.grey.shade700)))
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: shown.length,
            itemBuilder: (_, i) {
              final it = shown[i];
              final where = [
                '${it['sheet']}',
                if (it['row'] != null) 'แถว ${it['row']}',
                if (it['column'] != null) '${it['column']}',
              ].join(' • ');
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: Icon(icons[it['level']], color: colors[it['level']], size: 20),
                title: Text('${it['message']}', style: const TextStyle(fontSize: 13)),
                subtitle: Text(where, style: const TextStyle(fontSize: 11.5)),
              );
            },
          ),
        ),
    ]);
  }
}
