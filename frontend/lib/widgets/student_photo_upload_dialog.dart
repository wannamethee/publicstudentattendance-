import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import 'student_photo_capture.dart';

/// อัปโหลดรูปนักเรียนทีละหลายรูป / ZIP: ตั้งชื่อไฟล์ตามรหัสนักเรียน (01234.jpg)
/// ขั้นที่ 1 ส่งรูปเป็นชุด ๆ ให้เซิร์ฟเวอร์ย่อ + จับคู่ (ยังไม่บันทึก) -> ตรวจรูปย่อ -> ขั้นที่ 2 บันทึก
/// ผู้ดูแลระบบ: ทุกชั้น, ครูประจำชั้น: เฉพาะชั้นของตน (เซิร์ฟเวอร์ตรวจ)
class StudentPhotoUploadDialog extends StatefulWidget {
  final ApiService apiService;
  final String term;
  final String year;

  const StudentPhotoUploadDialog({super.key, required this.apiService, required this.term, required this.year});

  /// Returns the server's message after saving, or null when closed without saving.
  static Future<String?> show(BuildContext context,
      {required ApiService apiService, required String term, required String year}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StudentPhotoUploadDialog(apiService: apiService, term: term, year: year),
    );
  }

  @override
  State<StudentPhotoUploadDialog> createState() => _StudentPhotoUploadDialogState();
}

class _Picked {
  final String name;
  final int size;
  final Future<Uint8List> Function() read;
  _Picked(this.name, this.size, this.read);
}

class _StudentPhotoUploadDialogState extends State<StudentPhotoUploadDialog> {
  static const _purple = Color(0xFF1B0B38);
  static const _batchFiles = 25;
  static const _batchBytes = 30 * 1024 * 1024;

  Map<String, dynamic>? _scope;
  String? _scopeError;
  Map<String, dynamic>? _stage; // summary of everything staged so far
  String? _error;
  String? _camLevel; // the class picked for the camera run (null = every class)
  bool _busy = false;
  int _sent = 0;
  int _toSend = 0;

  @override
  void initState() {
    super.initState();
    _loadScope();
  }

  Future<void> _loadScope() async {
    try {
      final s = await widget.apiService.getStudentPhotoScope(term: widget.term, year: widget.year);
      if (mounted) setState(() => _scope = s);
    } catch (e) {
      if (mounted) setState(() => _scopeError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  bool get _canUpload => _scope != null && (_scope!['all'] == true || (_scope!['levels'] as List).isNotEmpty);
  String? get _token => _stage?['token']?.toString();
  Map<String, dynamic> get _counts => Map<String, dynamic>.from((_stage?['counts'] as Map?) ?? {});
  int _n(String k) => (_counts[k] as num?)?.toInt() ?? 0;

  Future<void> _pickImages() async {
    // image_picker reads each file only when it is sent (no preloading of hundreds of photos)
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty) return;
    final picked = <_Picked>[];
    for (final f in files) {
      picked.add(_Picked(f.name, await f.length(), f.readAsBytes));
    }
    await _send(picked);
  }

  Future<void> _pickZip() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'เลือกไฟล์ ZIP ที่มีรูปนักเรียน',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (files.isEmpty) return;
    await _send([for (final f in files) _Picked(f.name, f.lengthSync() ?? 0, f.readAsBytes)]);
  }

  Future<void> _send(List<_Picked> picked) async {
    setState(() {
      _busy = true;
      _error = null;
      _sent = 0;
      _toSend = picked.length;
    });
    try {
      var i = 0;
      while (i < picked.length) {
        final batch = <MapEntry<String, Uint8List>>[];
        var bytes = 0;
        while (i < picked.length && batch.length < _batchFiles && (batch.isEmpty || bytes + picked[i].size <= _batchBytes)) {
          final data = await picked[i].read();
          batch.add(MapEntry(picked[i].name, data));
          bytes += data.length;
          i++;
        }
        final res = await widget.apiService.stageStudentPhotos(batch, term: widget.term, year: widget.year, token: _token);
        if (!mounted) return;
        setState(() {
          _stage = res;
          _sent = i;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// one student from the "ยังไม่มีรูป" list: camera or a file on the device, saved at once
  Future<void> _photoOne(Map m) async {
    final saved = await pickAndUploadStudentPhoto(
      context,
      apiService: widget.apiService,
      studentId: m['student_id'].toString(),
      studentName: m['full_name']?.toString() ?? m['student_id'].toString(),
      term: widget.term,
      year: widget.year,
    );
    if (saved == PhotoResult.saved && mounted) _loadScope();
  }

  Future<void> _commit() async {
    final token = _token;
    if (token == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.apiService.commitStudentPhotos(token);
      if (mounted) Navigator.of(context).pop(res['message']?.toString() ?? 'บันทึกรูปนักเรียนแล้ว');
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _close() async {
    final token = _token;
    if (token != null) await widget.apiService.cancelStudentPhotos(token);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final matched = _n('matched');
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
              decoration: const BoxDecoration(
                color: _purple,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.photo_library_rounded, color: Color(0xFFFACC15)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('อัปโหลดรูปนักเรียน • ภาคเรียนที่ ${widget.term}/${widget.year}',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
                    onPressed: _busy ? null : _close,
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildScope(),
                    const SizedBox(height: 12),
                    _buildCamera(),
                    const SizedBox(height: 12),
                    _buildHowTo(),
                    const SizedBox(height: 12),
                    if (_busy && _toSend > 0) _buildProgress(),
                    if (_error != null) _note(Icons.error_outline_rounded, _error!, Colors.red),
                    if (_stage != null) ...[
                      const SizedBox(height: 4),
                      _buildSummary(),
                      const SizedBox(height: 10),
                      if (matched > 0) _buildGrid(),
                      _buildList('ไฟล์ที่ไม่ได้ใช้', 'unmatched', Colors.orange.shade800, (m) => m['reason']?.toString() ?? ''),
                      _buildList('ไม่ใช่นักเรียนในชั้นของท่าน', 'not_allowed', Colors.red.shade700,
                          (m) => '${m['student_id']} ${m['full_name']} (${m['class_level']}/${m['room']})'),
                      _buildList('ไฟล์ซ้ำรหัสเดียวกัน (ใช้ไฟล์ที่ส่งทีหลัง)', 'duplicates', Colors.blueGrey,
                          (m) => m['reason']?.toString() ?? ''),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: _busy ? null : _close, child: const Text('ยกเลิก')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: _purple),
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: Text(matched > 0 ? 'บันทึกรูป $matched คน' : 'บันทึกรูป'),
                    onPressed: (_busy || matched == 0) ? null : _commit,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScope() {
    if (_scopeError != null) return _note(Icons.error_outline_rounded, _scopeError!, Colors.red);
    final s = _scope;
    if (s == null) return const LinearProgressIndicator();
    if (!_canUpload) {
      return _note(Icons.lock_outline_rounded,
          'อัปโหลดรูปได้เฉพาะครูประจำชั้น (ครูที่ปรึกษา) ของภาคเรียน ${widget.term}/${widget.year} หรือผู้ดูแลระบบ', Colors.red);
    }
    final total = (s['total'] as num?)?.toInt() ?? 0;
    final have = (s['with_photo'] as num?)?.toInt() ?? 0;
    final missing = ((s['missing'] as List?) ?? []).cast<Map>();
    final who = s['all'] == true ? 'ทุกชั้น (ผู้ดูแลระบบ)' : '${(s['levels'] as List).join(', ')} (ครูประจำชั้น)';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ท่านอัปโหลดได้: $who', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : have / total,
                    minHeight: 8,
                    backgroundColor: Colors.grey.shade200,
                    color: Colors.teal,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text('มีรูปแล้ว $have / $total คน', style: const TextStyle(fontSize: 12.5)),
            ],
          ),
          if (missing.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: Text('ยังไม่มีรูป ${total - have} คน', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800)),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('กดปุ่มกล้องหลังชื่อ เพื่อถ่ายหรือเลือกรูปให้นักเรียนทีละคน (บันทึกทันที)',
                        style: TextStyle(fontSize: 11.5, color: Colors.purple.shade700)),
                  ),
                  SizedBox(
                    height: 220,
                    child: ListView.builder(
                      itemCount: missing.length,
                      itemBuilder: (_, i) {
                        final m = missing[i];
                        final no = m['student_no'] == null ? '' : ' เลขที่ ${m['student_no']}';
                        return Row(
                          children: [
                            Expanded(
                              child: Text('${m['class_level']}/${m['room']}$no • ${m['student_id']} ${m['full_name']}',
                                  style: const TextStyle(fontSize: 12)),
                            ),
                            IconButton(
                              tooltip: 'ถ่ายจากกล้อง / เลือกรูปจากเครื่อง',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.add_a_photo_rounded, size: 18, color: Colors.purple.shade700),
                              onPressed: _busy ? null : () => _photoOne(m),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Map> get _missing => ((_scope?['missing'] as List?) ?? []).cast<Map>();

  List<Map> get _cameraQueue =>
      _missing.where((m) => _camLevel == null || m['class_level']?.toString() == _camLevel).toList();

  /// ถ่ายไล่ทีละคน: นักเรียนที่ยังไม่มีรูป เรียงตามชั้น/ห้อง/เลขที่ • ถ่าย -> จัดกรอบ -> บันทึก -> คนถัดไปอัตโนมัติ
  Future<void> _cameraRun({ImageSource source = ImageSource.camera}) async {
    final queue = _cameraQueue;
    if (queue.isEmpty) return;
    var saved = 0, skipped = 0;
    for (var i = 0; i < queue.length; i++) {
      final m = queue[i];
      final r = await pickAndUploadStudentPhoto(
        context,
        apiService: widget.apiService,
        studentId: m['student_id'].toString(),
        studentName: m['full_name']?.toString() ?? m['student_id'].toString(),
        term: widget.term,
        year: widget.year,
        source: source,
        progress: 'คนที่ ${i + 1}/${queue.length} • ${m['class_level']}/${m['room']}'
            '${m['student_no'] == null ? '' : ' เลขที่ ${m['student_no']}'}',
        quiet: true,
      );
      if (!mounted) return;
      if (r == PhotoResult.cancelled) break;
      if (r == PhotoResult.saved) saved++;
      if (r == PhotoResult.skipped) skipped++;
    }
    if (!mounted) return;
    await _loadScope();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: Colors.teal.shade700,
      content: Text('ถ่ายรูปแล้ว $saved คน${skipped > 0 ? ' • ข้าม $skipped คน' : ''}'),
    ));
  }

  Widget _buildCamera() {
    if (!_canUpload) return const SizedBox.shrink();
    final missing = _missing;
    final levels = {for (final m in missing) m['class_level']?.toString() ?? ''}.where((e) => e.isNotEmpty).toList()..sort();
    final queue = _cameraQueue;
    final enabled = !_busy && queue.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF5FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE9D5FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.photo_camera_rounded, size: 20, color: Colors.purple.shade800),
            const SizedBox(width: 6),
            const Text('ถ่ายรูปด้วยกล้อง', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 4),
          Text(
              'ไล่ถ่ายนักเรียนที่ยังไม่มีรูปทีละคนตามเลขที่ • หลังถ่ายลาก/ซูมให้ใบหน้าอยู่ในกรอบแล้วกดบันทึก ระบบไปคนถัดไปให้เอง '
              '• มือถือใช้กล้องหลัง คอมพิวเตอร์ใช้เว็บแคม',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade800)),
          if (levels.length > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: Text('ทุกชั้น (${missing.length})', style: const TextStyle(fontSize: 12)),
                  selected: _camLevel == null,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _camLevel = null),
                ),
                for (final lv in levels)
                  ChoiceChip(
                    label: Text('$lv (${missing.where((m) => m['class_level'] == lv).length})', style: const TextStyle(fontSize: 12)),
                    selected: _camLevel == lv,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _camLevel = lv),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.purple.shade800),
                icon: const Icon(Icons.photo_camera_rounded, size: 18),
                label: Text(queue.isEmpty ? 'ทุกคนมีรูปแล้ว' : 'เริ่มถ่ายรูป (${queue.length} คน)'),
                onPressed: enabled ? _cameraRun : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.photo_library_rounded, size: 18),
                label: const Text('เลือกรูปทีละคนจากเครื่อง'),
                onPressed: enabled ? () => _cameraRun(source: ImageSource.gallery) : null,
              ),
              Text('ถ่ายใหม่ให้คนที่มีรูปแล้ว: กดชื่อนักเรียนในแดชบอร์ด › เปลี่ยนรูป',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHowTo() {
    final enabled = _canUpload && !_busy;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ตั้งชื่อไฟล์เป็นรหัสนักเรียน เช่น 01234.jpg (มีชื่อต่อท้ายได้ เช่น "01234 สมชาย.jpg")',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('เลือกได้ทีละหลายร้อยรูป หรือบีบอัดทั้งโฟลเดอร์เป็น .zip • ระบบหมุนรูป ครอป 3:4 และย่อขนาดให้เอง '
              '• ยังไม่บันทึกจนกว่าจะกด "บันทึกรูป" • อัปโหลดรหัสเดิมซ้ำ = แทนรูปเดิม',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade800)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.purple.shade700),
                icon: const Icon(Icons.add_photo_alternate_rounded, size: 18),
                label: Text(_stage == null ? 'เลือกรูป (หลายรูป)' : 'เพิ่มรูป'),
                onPressed: enabled ? _pickImages : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_zip_rounded, size: 18),
                label: const Text('เลือกไฟล์ ZIP'),
                onPressed: enabled ? _pickZip : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('กำลังส่งและย่อรูป $_sent / $_toSend ไฟล์...', style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: _toSend == 0 ? null : _sent / _toSend),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    Widget chip(IconData icon, String text, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(fontSize: 12.5, color: Colors.black87)),
          ]),
        );
    final replace = _n('replace');
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(Icons.check_circle_rounded, 'จับคู่ได้ ${_n('matched')} คน (ใหม่ ${_n('new')}${replace > 0 ? ' • แทนรูปเดิม $replace' : ''})',
            Colors.teal.shade700),
        if (_n('unmatched') > 0) chip(Icons.help_outline_rounded, 'ไฟล์ที่ไม่ได้ใช้ ${_n('unmatched')}', Colors.orange.shade800),
        if (_n('not_allowed') > 0) chip(Icons.block_rounded, 'ไม่ใช่ชั้นของท่าน ${_n('not_allowed')}', Colors.red.shade700),
        if (_n('duplicates') > 0) chip(Icons.content_copy_rounded, 'ไฟล์ซ้ำรหัส ${_n('duplicates')}', Colors.blueGrey),
      ],
    );
  }

  Widget _buildGrid() {
    final token = _token!;
    final items = ((_stage?['matched'] as List?) ?? []).cast<Map>();
    // its own scroll area: only the thumbnails in view are loaded
    return SizedBox(
      height: 380,
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.56,
        ),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final m = items[i];
          final sid = m['student_id'].toString();
          final no = m['student_no'] == null ? '' : ' เลขที่ ${m['student_no']}';
          return Tooltip(
            message: 'ไฟล์: ${m['file']}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          // the file name keeps a re-sent photo of the same student from showing the old picture
                          '${widget.apiService.stagedStudentPhotoUrl(token, sid)}?f=${Uri.encodeComponent(m['file'].toString())}',
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(color: Colors.grey.shade200),
                        ),
                      ),
                      if (m['has_photo'] == true)
                        Positioned(
                          left: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(color: Colors.orange.shade700, borderRadius: BorderRadius.circular(4)),
                            child: const Text('แทนรูปเดิม', style: TextStyle(color: Colors.white, fontSize: 9.5)),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                Text(m['full_name']?.toString() ?? sid,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, height: 1.2)),
                Text('${m['class_level']}/${m['room']}$no',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildList(String title, String key, Color color, String Function(Map) detail) {
    final items = ((_stage?[key] as List?) ?? []).cast<Map>();
    if (items.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        dense: true,
        title: Text('$title (${items.length})', style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.bold)),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• ${items[i]['file']} — ${detail(items[i])}', style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(IconData icon, String text, Color color) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: color))),
        ]),
      );
}
