import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../utils/app_theme.dart';

/// แก้ชื่อนักเรียน แยกเป็น คำนำหน้า / ชื่อ / สกุล (ตรงกับช่องในฐานข้อมูล)
/// บันทึกแล้วระบบอัปเดตให้ทุกหน้าและไฟล์ ปพ.5 ทันที ไม่ต้องแก้ที่อื่นอีก
class StudentNameDialog extends StatefulWidget {
  final ApiService apiService;
  final String studentId;
  const StudentNameDialog({super.key, required this.apiService, required this.studentId});

  /// คืนชื่อเต็มใหม่เมื่อบันทึกสำเร็จ (null = ไม่ได้แก้)
  static Future<String?> show(BuildContext context, ApiService api, String studentId) =>
      showDialog<String>(context: context, builder: (_) => StudentNameDialog(apiService: api, studentId: studentId));

  @override
  State<StudentNameDialog> createState() => _StudentNameDialogState();
}

class _StudentNameDialogState extends State<StudentNameDialog> {
  static const _prefixes = ['เด็กชาย', 'เด็กหญิง', 'นาย', 'นางสาว'];
  final _first = TextEditingController();
  final _last = TextEditingController();
  String _prefix = '';
  String? _birthDate;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.apiService.getStudentName(widget.studentId);
      if (!mounted) return;
      setState(() {
        _prefix = '${d['prefix'] ?? ''}';
        _first.text = '${d['first_name'] ?? ''}';
        _last.text = '${d['last_name'] ?? ''}';
        _birthDate = '${d['birth_date'] ?? ''}';
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_first.text.trim().isEmpty) {
      setState(() => _error = 'กรุณากรอกชื่อ');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final d = await widget.apiService.setStudentName(widget.studentId,
          prefix: _prefix, firstName: _first.text.trim(), lastName: _last.text.trim());
      if (mounted) Navigator.pop(context, '${d['full_name']}');
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.gold, width: 1.5)),
      title: Text('แก้ไขชื่อนักเรียน • รหัส ${widget.studentId}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 460,
        child: _loading
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                DropdownButtonFormField<String>(
                  initialValue: _prefixes.contains(_prefix) ? _prefix : null,
                  decoration: const InputDecoration(labelText: 'คำนำหน้า', border: OutlineInputBorder(), isDense: true),
                  items: [
                    for (final p in _prefixes) DropdownMenuItem(value: p, child: Text(p)),
                    if (_prefix.isNotEmpty && !_prefixes.contains(_prefix)) DropdownMenuItem(value: _prefix, child: Text(_prefix)),
                  ],
                  onChanged: _saving ? null : (v) => setState(() => _prefix = v ?? ''),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _first,
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: 'ชื่อ', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _last,
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: 'นามสกุล', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppColors.goldLight, borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('วันเกิด ${(_birthDate ?? '').isEmpty ? 'ไม่มีข้อมูล' : _birthDate}',
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    const Text(
                      'ระบบเปลี่ยน เด็กชาย/เด็กหญิง เป็น นาย/นางสาว ให้เองเมื่ออายุครบ 15 ปี\n'
                      'บันทึกแล้วชื่อจะอัปเดตทุกหน้าและไฟล์ ปพ.5 ของนักเรียนคนนี้ทันที',
                      style: TextStyle(fontSize: 12),
                    ),
                  ]),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                  ),
              ]),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('ยกเลิก')),
        FilledButton.icon(
          onPressed: _loading || _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check_rounded, size: 18),
          label: const Text('บันทึกชื่อ'),
        ),
      ],
    );
  }
}
