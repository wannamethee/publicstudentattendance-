import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// เครื่องที่ลงใหม่ (ฐานข้อมูลว่าง ยังไม่มีครูให้ล็อกอิน) มี 2 ทาง:
///  - ตั้งค่าโรงเรียนใหม่ (เริ่มใช้ครั้งแรก, ฉบับเปล่า): ชื่อโรงเรียน ที่ตั้ง สังกัด + ผู้ดูแลระบบคนแรก (รหัสครู + PIN)
///  - กู้คืนจากไฟล์สำรองทั้งระบบ (.zip)
/// เซิร์ฟเวอร์ยอมรับทั้งสองอย่างเฉพาะจากหน้าจอเครื่องเซิร์ฟเวอร์เอง (http://localhost:8000) และเฉพาะตอนฐานข้อมูลว่าง
class RecoveryDialog extends StatefulWidget {
  final ApiService apiService;
  final bool local;
  const RecoveryDialog({super.key, required this.apiService, required this.local});

  static Future<bool> show(BuildContext context, ApiService api, {required bool local}) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RecoveryDialog(apiService: api, local: local),
      ) ==
      true;

  @override
  State<RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<RecoveryDialog> {
  String _mode = 'choose'; // choose | setup | restore
  bool _busy = false;
  String? _error;
  String? _done;

  final _form = GlobalKey<FormState>();
  final Map<String, TextEditingController> _c = {
    for (final k in [
      'school_name', 'subdistrict', 'district', 'province', 'area_office', 'area_short', 'school_id',
      'director_name', 'admin_name', 'admin_code', 'admin_pin', 'admin_pin2',
    ])
      k: TextEditingController(),
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (picked.isEmpty) return;
    final f = picked.first;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await f.readAsBytes();
      final r = await widget.apiService.recoveryRestore(bytes, f.name);
      setState(() => _done = '${r['message'] ?? 'กู้คืนเรียบร้อย'}');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setup() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = {for (final e in _c.entries) if (e.key != 'admin_pin2') e.key: e.value.text.trim()};
      final r = await widget.apiService.setupNewSchool(body);
      setState(() => _done = '${r['message'] ?? 'ตั้งค่าโรงเรียนเรียบร้อย'}');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String key, String label, {String? hint, bool required = false, bool obscure = false,
      TextInputType? keyboard, String? Function(String?)? validator}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        key: ValueKey('setup-$key'),
        controller: _c[key],
        obscureText: obscure,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        validator: validator ??
            (required ? (v) => (v ?? '').trim().isEmpty ? 'กรุณากรอก$label' : null : null),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
      );

  Widget _localOnlyNote() => Container(
        padding: const EdgeInsets.all(10),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8)),
        child: const Text('ทำได้เฉพาะจากหน้าจอเครื่องเซิร์ฟเวอร์เท่านั้น (เพื่อความปลอดภัย)\n'
            'ไปที่เครื่องเซิร์ฟเวอร์ เปิดเบราว์เซอร์ที่ http://localhost:8000 แล้วทำต่อที่นั่น'),
      );

  Widget _choose() {
    Widget card(String key, IconData icon, Color color, String title, String text) => Card(
          key: ValueKey('setup-choice-$key'),
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: Icon(icon, color: color, size: 32),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(text),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => setState(() {
              _mode = key;
              _error = null;
            }),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('ระบบยังไม่มีข้อมูลครูและนักเรียน เลือกวิธีเริ่มต้นใช้งาน'),
      const SizedBox(height: 12),
      card('setup', Icons.school_rounded, Colors.indigo, 'ตั้งค่าโรงเรียนใหม่ (เริ่มใช้ครั้งแรก)',
          'กรอกชื่อโรงเรียน ที่ตั้ง สังกัด และสร้างผู้ดูแลระบบคนแรก แล้วนำเข้าครู นักเรียน รายวิชาด้วยแบบฟอร์ม Excel'),
      card('restore', Icons.settings_backup_restore_rounded, Colors.teal, 'กู้คืนจากไฟล์สำรอง (.zip)',
          'เครื่องที่ลงใหม่ หรือไดรฟ์เดิมเสีย: ใช้ไฟล์สำรองทั้งระบบ school_backup_….zip'),
    ]);
  }

  Widget _setupForm() {
    return Form(
      key: _form,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!widget.local) _localOnlyNote(),
        _section('ข้อมูลโรงเรียน (ใช้บนหน้าปก ปพ.5 และหัวรายงาน แก้ภายหลังได้ที่หน้าตั้งค่า)'),
        _field('school_name', 'ชื่อโรงเรียน', hint: 'เช่น บ้านตัวอย่างวิทยา', required: true),
        Row(children: [
          Expanded(child: _field('subdistrict', 'ตำบล')),
          const SizedBox(width: 8),
          Expanded(child: _field('district', 'อำเภอ')),
          const SizedBox(width: 8),
          Expanded(child: _field('province', 'จังหวัด')),
        ]),
        _field('area_office', 'สังกัด', hint: 'เช่น สำนักงานเขตพื้นที่การศึกษามัธยมศึกษา…'),
        Row(children: [
          Expanded(child: _field('area_short', 'ชื่อย่อสังกัด', hint: 'เช่น สพม.…')),
          const SizedBox(width: 8),
          Expanded(child: _field('school_id', 'รหัสสถานศึกษา', keyboard: TextInputType.number)),
        ]),
        _field('director_name', 'ชื่อผู้อำนวยการ', hint: 'เช่น นายสมชาย ใจดี'),
        _section('ผู้ดูแลระบบคนแรก (ใช้เข้าสู่ระบบ)'),
        _field('admin_name', 'ชื่อ-สกุลครู', hint: 'เช่น นางสาวสมหญิง รักเรียน', required: true),
        Row(children: [
          Expanded(child: _field('admin_code', 'รหัสครู', hint: 'เช่น 101', required: true)),
          const SizedBox(width: 8),
          Expanded(
            child: _field('admin_pin', 'PIN', obscure: true, keyboard: TextInputType.number,
                validator: (v) => RegExp(r'^\d{4,6}$').hasMatch((v ?? '').trim()) ? null : 'ตัวเลข 4–6 หลัก'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _field('admin_pin2', 'ยืนยัน PIN', obscure: true, keyboard: TextInputType.number,
                validator: (v) => (v ?? '').trim() != _c['admin_pin']!.text.trim() ? 'PIN ไม่ตรงกัน' : null),
          ),
        ]),
        const Text('ครูคนอื่น นักเรียน รายวิชา และตารางสอน นำเข้าภายหลังได้ที่หน้าตั้งค่า → นำเข้าข้อมูลโรงเรียน (แบบฟอร์ม Excel)',
            style: TextStyle(fontSize: 12.5, color: Colors.black54)),
      ]),
    );
  }

  Widget _restore() {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('เลือกไฟล์สำรองทั้งระบบ school_backup_….zip ที่เก็บไว้ (USB / Google Drive / ที่ดาวน์โหลดไว้) '
          'ระบบจะกู้คืนข้อมูลทุกภาคเรียน รูป และไฟล์แนบให้ ไฟล์ ปพ.5 ที่ไม่อยู่ในไฟล์สำรองระบบสร้างใหม่ให้ตอนกลางคืน'),
      const SizedBox(height: 12),
      if (!widget.local) _localOnlyNote(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_mode) {
      'setup' => 'ตั้งค่าโรงเรียนใหม่',
      'restore' => 'กู้คืนระบบจากไฟล์สำรอง',
      _ => 'เริ่มต้นใช้งานระบบ',
    };
    return AlertDialog(
      title: Row(children: [
        Icon(_mode == 'restore' ? Icons.settings_backup_restore_rounded : Icons.school_rounded, color: Colors.indigo),
        const SizedBox(width: 8),
        Expanded(child: Text(title)),
      ]),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_done == null) ...[
              if (_mode == 'choose') _choose(),
              if (_mode == 'setup') _setupForm(),
              if (_mode == 'restore') _restore(),
            ],
            if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Colors.red.shade700))),
            if (_done != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('$_done\nกด "เข้าสู่ระบบ" เพื่อเริ่มใช้งาน',
                    style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.bold)),
              ),
          ]),
        ),
      ),
      actions: [
        if (_done != null)
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('เข้าสู่ระบบ'))
        else ...[
          if (_mode != 'choose')
            TextButton(onPressed: _busy ? null : () => setState(() => _mode = 'choose'), child: const Text('ย้อนกลับ')),
          if (_mode == 'setup')
            FilledButton.icon(
              onPressed: !widget.local || _busy ? null : _setup,
              icon: const Icon(Icons.check_rounded),
              label: const Text('บันทึกและเริ่มใช้งาน'),
            ),
          if (_mode == 'restore')
            FilledButton.icon(
              onPressed: !widget.local || _busy ? null : _pick,
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('เลือกไฟล์สำรอง (.zip)'),
            ),
        ],
      ],
    );
  }
}
