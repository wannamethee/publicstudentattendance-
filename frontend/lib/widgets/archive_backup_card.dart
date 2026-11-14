import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

/// ไฟล์สำรองทั้งระบบ (.zip) สำหรับผู้ดูแลระบบ: ฐานข้อมูลทุกภาคเรียน + CSV ทุกตาราง + รูป/ไฟล์แนบ (+ ปพ.5)
/// ระบบสำรองให้เองทุกคืน (วันอาทิตย์รวม ปพ.5) • ไม่มี PIN ของครูในไฟล์
class ArchiveBackupCard extends StatefulWidget {
  final ApiService apiService;
  const ArchiveBackupCard({super.key, required this.apiService});

  @override
  State<ArchiveBackupCard> createState() => _ArchiveBackupCardState();
}

class _ArchiveBackupCardState extends State<ArchiveBackupCard> {
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _offsite;
  final _remoteCtrl = TextEditingController();
  bool _busy = false;
  String? _busyText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? Colors.red.shade700 : null));
  }

  @override
  void dispose() {
    _remoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await widget.apiService.listArchives();
      final off = await widget.apiService.offsiteStatus();
      if (mounted) {
        setState(() {
          _items = list;
          _offsite = off;
          if (_remoteCtrl.text.isEmpty) _remoteCtrl.text = '${off['remote'] ?? ''}';
        });
      }
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  Future<void> _run(String text, Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _busyText = text;
    });
    try {
      await job();
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _create(bool withPp5) => _run(withPp5 ? 'กำลังสร้างไฟล์สำรองรวม ปพ.5 (อาจใช้เวลา 1-3 นาที)…' : 'กำลังสร้างไฟล์สำรอง…', () async {
        final r = await widget.apiService.createArchive(includeOutputs: withPp5);
        _snack('สร้างไฟล์สำรองแล้ว ${r['name']} (${r['size_mb']} MB)');
        await _load();
      });

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (picked.isEmpty) return;
    final f = picked.first;
    final bytes = await f.readAsBytes();
    await _run('กำลังอัปโหลด…', () async {
      final r = await widget.apiService.uploadArchive(bytes, f.name);
      _snack('อัปโหลดแล้ว ${r['name']} • กด "กู้คืน" ที่แถวนั้นเพื่อใช้ข้อมูลชุดนี้');
      await _load();
    });
  }

  Future<void> _restore(Map<String, dynamic> a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('กู้คืนทั้งระบบจากไฟล์สำรอง'),
        content: Text('ไฟล์ ${a['name']}\nสร้างเมื่อ ${a['created_at'] ?? '-'}\n\n'
            '• ข้อมูลทุกภาคเรียนจะกลับไปเป็นตามไฟล์นี้ (ข้อมูลที่บันทึกหลังจากนั้นจะหาย)\n'
            '• ระบบสำรองฐานข้อมูลปัจจุบันให้ก่อน (ดูได้ที่ จัดเก็บข้อมูล → สำรองข้อมูล)\n'
            '• PIN ของครูในเครื่องนี้คงเดิม ครูที่ไม่มีในเครื่องนี้ใช้รหัสครูเป็น PIN แรก\n'
            '${a['include_outputs'] == true ? '• ไฟล์ ปพ.5 ในไฟล์สำรองจะเขียนทับไฟล์ในเครื่อง\n' : ''}'
            '\nยืนยันกู้คืน?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('กู้คืน'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run('กำลังกู้คืน…', () async {
      final r = await widget.apiService.restoreArchive('${a['name']}');
      _snack('${r['message'] ?? 'กู้คืนแล้ว'} • กรุณารีเฟรชหน้าเว็บ');
      await _load();
    });
  }

  Future<void> _saveRemote() => _run('กำลังบันทึก…', () async {
        final r = await widget.apiService.setOffsiteRemote(_remoteCtrl.text.trim());
        setState(() => _offsite = r);
        _snack(_remoteCtrl.text.trim().isEmpty ? 'ปิดการส่งขึ้น Google Drive แล้ว' : 'บันทึกแล้ว ระบบจะส่งขึ้นทุกคืนหลังสำรอง');
      });

  Future<void> _sendNow() => _run('กำลังส่งไฟล์สำรองขึ้น Google Drive…', () async {
        final r = await widget.apiService.runOffsiteNow();
        _snack('${r['message']}', error: r['ok'] != true);
        await _load();
      });

  void _howTo() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ตั้งค่าส่งไฟล์สำรองขึ้น Google Drive (ทำครั้งเดียว)'),
        content: const SingleChildScrollView(
          child: SelectableText(
            'ทำบนเครื่องเซิร์ฟเวอร์ ใช้บัญชี Google ของโรงเรียน (ไฟล์มีข้อมูลส่วนบุคคลของนักเรียน)\n\n'
            '1. ติดตั้ง rclone\n'
            '   • Linux (Xubuntu): เปิด Terminal พิมพ์  sudo apt install rclone\n'
            '   • Windows: ดาวน์โหลดจาก rclone.org/downloads แตกไฟล์ แล้ววาง rclone.exe ไว้ที่โฟลเดอร์ tools ของโปรแกรม\n\n'
            '2. เชื่อมบัญชี Google: พิมพ์  rclone config  แล้วตอบดังนี้\n'
            '   n (New remote) → name: gdrive → Storage: drive (Google Drive)\n'
            '   client_id / client_secret: กด Enter ว่างไว้ → scope: 3 (drive.file = เห็นเฉพาะไฟล์ที่ rclone สร้าง)\n'
            '   service_account_file: Enter → Edit advanced config: n → Use web browser: y\n'
            '   เบราว์เซอร์จะเปิดให้ล็อกอิน Google ของโรงเรียน กดอนุญาต → Shared Drive: n → y (ยืนยัน) → q (ออก)\n'
            '   (Linux: ต้องรันในบัญชีผู้ใช้เดียวกับที่รันเซิร์ฟเวอร์ ดูได้จาก deploy/linux/README_TH.md)\n\n'
            '3. กลับมาที่หน้านี้ ใส่  gdrive:SchoolBackup  ในช่อง "ที่เก็บบน Google Drive" กดบันทึก แล้วกด "ส่งขึ้นตอนนี้"\n'
            '   ถ้าขึ้น "ส่งขึ้น gdrive:SchoolBackup แล้ว" ก็เสร็จ ไฟล์จะอยู่ในโฟลเดอร์ SchoolBackup ของ Google Drive\n\n'
            'หลังจากนั้นระบบส่งให้เองทุกคืน และลบไฟล์บน Drive ที่เก่ากว่า 7 วันให้อัตโนมัติ\n'
            'อยากเก็บไฟล์ไหนนานกว่านั้น ให้ดาวน์โหลด/คัดลอกไปไว้ที่อื่นเอง',
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ปิด'))],
      ),
    );
  }

  Widget _offsitePanel() {
    final o = _offsite;
    final last = (o?['last'] as Map?) ?? {};
    final ok = last['ok'];
    final hasRclone = o?['rclone'] != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.blueGrey.shade50, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.cloud_upload_outlined, size: 20),
          const SizedBox(width: 6),
          const Expanded(child: Text('สำเนานอกเครื่อง: Google Drive (กันไดรฟ์เครื่องพัง)', style: TextStyle(fontWeight: FontWeight.bold))),
          TextButton.icon(onPressed: _howTo, icon: const Icon(Icons.help_outline_rounded, size: 18), label: const Text('วิธีตั้งค่า')),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 260,
            child: TextField(
              controller: _remoteCtrl,
              decoration: const InputDecoration(
                  labelText: 'ที่เก็บบน Google Drive', hintText: 'gdrive:SchoolBackup', isDense: true, border: OutlineInputBorder()),
            ),
          ),
          OutlinedButton(onPressed: _busy ? null : _saveRemote, child: const Text('บันทึก')),
          FilledButton.tonalIcon(
            onPressed: _busy || (o?['remote'] ?? '').toString().isEmpty ? null : _sendNow,
            icon: const Icon(Icons.cloud_sync_rounded),
            label: const Text('ส่งขึ้นตอนนี้'),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          !hasRclone
              ? 'ยังไม่ได้ติดตั้ง rclone ในเครื่องนี้ (กด "วิธีตั้งค่า")'
              : last.isEmpty
                  ? 'ยังไม่เคยส่ง • ส่งทุกคืนหลังสำรอง เก็บบน Drive ${o?['keep_days'] ?? 7} วันล่าสุด'
                  : '${ok == true ? '✓' : '✗'} ครั้งล่าสุด ${last['at'] ?? ''}: ${last['message'] ?? ''}',
          style: TextStyle(fontSize: 12, color: ok == false || !hasRclone ? Colors.red.shade700 : Colors.grey.shade800),
        ),
      ]),
    );
  }

  Future<void> _download(String name) async {
    if (!await launchUrl(Uri.parse(widget.apiService.archiveDownloadUrl(name)), mode: LaunchMode.externalApplication)) {
      _snack('เปิดลิงก์ดาวน์โหลดไม่ได้', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.teal.shade100, borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.backup_outlined, color: Colors.teal.shade900),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('สำรองทั้งระบบ (.zip)', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                Text(
                  'ไฟล์เดียวมีทุกอย่าง: ฐานข้อมูลทุกภาคเรียน • CSV ทุกตาราง (เปิดด้วย Excel ได้) • รูปเยี่ยมบ้าน ไฟล์ตารางสอบ โลโก้ • ไฟล์ ปพ.5 (ชุด "รวม ปพ.5") '
                  '• ตัวโปรแกรมทั้งชุด (ไดรฟ์พังลงใหม่ได้จากไฟล์นี้ไฟล์เดียว) — ระบบสำรองให้เองทุกคืน (วันอาทิตย์รวม ปพ.5) '
                  'เก็บไว้ 7 วันล่าสุด ไฟล์ที่เก่ากว่าถูกลบอัตโนมัติ อยากเก็บนานกว่านั้นให้ดาวน์โหลดไปเก็บเอง • ไม่มี PIN ของครู',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Wrap(spacing: 12, runSpacing: 10, children: [
            FilledButton.tonalIcon(
              onPressed: _busy ? null : () => _create(false),
              icon: const Icon(Icons.save_alt_rounded),
              label: const Text('สำรองตอนนี้'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _create(true),
              icon: const Icon(Icons.folder_zip_outlined),
              label: const Text('สำรองตอนนี้ (รวม ปพ.5)'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _upload,
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('อัปโหลดไฟล์สำรองจากเครื่องอื่น'),
            ),
            IconButton(tooltip: 'รีเฟรช', onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh_rounded)),
          ]),
          if (_busy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            if (_busyText != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_busyText!, style: const TextStyle(fontSize: 12))),
          ],
          const SizedBox(height: 12),
          _offsitePanel(),
          const SizedBox(height: 12),
          if (_items.isEmpty)
            Text('ยังไม่มีไฟล์สำรอง', style: TextStyle(color: Colors.grey.shade600, fontSize: 13))
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final a = _items[i];
                  final tags = [
                    a['auto'] == true ? 'อัตโนมัติ' : 'สร้างเอง',
                    if (a['include_outputs'] == true) 'รวม ปพ.5',
                    '${a['size_mb']} MB',
                    if (a['students'] != null) 'นักเรียน ${a['students']} คน',
                  ].join(' • ');
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(a['include_outputs'] == true ? Icons.folder_zip : Icons.inventory_2_outlined,
                        color: a['error'] != null ? Colors.red : Colors.teal.shade700),
                    title: Text('${a['created_at'] ?? a['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(a['error'] != null ? '${a['error']}' : tags),
                    trailing: Wrap(spacing: 4, children: [
                      IconButton(tooltip: 'ดาวน์โหลด', onPressed: _busy ? null : () => _download('${a['name']}'), icon: const Icon(Icons.download_rounded)),
                      IconButton(
                        tooltip: 'กู้คืนทั้งระบบจากไฟล์นี้',
                        onPressed: _busy || a['error'] != null ? null : () => _restore(a),
                        icon: Icon(Icons.settings_backup_restore_rounded, color: Colors.red.shade700),
                      ),
                    ]),
                  );
                },
              ),
            ),
        ]),
      ),
    );
  }
}
