import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

/// แสดงข้อมูลบนเว็บอื่น (API สาธารณะ, ผู้ดูแลระบบ): แดชบอร์ดการมาเรียน (ตัวเลขสรุป ไม่มีรายคน) และตารางสอนครู
/// เปิดให้ทุกเว็บดึงได้ไม่ต้องล็อกอิน • เปิด/ปิดแต่ละชุดได้ • คัดลอก "โค้ดสำหรับวาง" ไปใส่ช่อง Embed code ของเว็บโรงเรียน
class PublicApiCard extends StatefulWidget {
  final ApiService apiService;
  const PublicApiCard({super.key, required this.apiService});

  @override
  State<PublicApiCard> createState() => _PublicApiCardState();
}

class _PublicApiCardState extends State<PublicApiCard> {
  Map<String, dynamic>? _st;
  final _baseCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? Colors.red.shade700 : null));
  }

  String _err(Object e) => e.toString().replaceFirst('Exception: ', '');

  Future<void> _load() async {
    try {
      final st = await widget.apiService.publicApiSettings();
      if (!mounted) return;
      setState(() {
        _st = st;
        _baseCtrl.text = '${st['base_url'] ?? ''}';
      });
    } catch (e) {
      _snack(_err(e), error: true);
    }
  }

  Future<void> _save(Map<String, dynamic> change, String done) async {
    setState(() => _busy = true);
    try {
      final st = await widget.apiService.savePublicApiSettings(change);
      if (!mounted) return;
      setState(() => _st = st);
      _snack(done);
    } catch (e) {
      _snack(_err(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String view) async {
    try {
      final code = await widget.apiService.publicApiSnippet(view);
      await Clipboard.setData(ClipboardData(text: code));
      _snack('คัดลอกโค้ดแล้ว • นำไปวางในช่อง "ฝังโค้ด / Embed code" ของเว็บโรงเรียน');
    } catch (e) {
      _snack(_err(e), error: true);
    }
  }

  Future<void> _preview(String view) async {
    final url = Uri.parse('${widget.apiService.baseUrl}/api/public/v1/preview?view=$view');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) _snack('เปิดหน้าตัวอย่างไม่ได้', error: true);
  }

  Widget _dataset(String key, IconData icon, String title, String detail) {
    final on = _st?[key] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(color: on ? Colors.indigo.shade50 : Colors.grey.shade100, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 20, color: on ? Colors.indigo.shade800 : Colors.grey.shade600),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
          Text(on ? 'เปิดอยู่' : 'ปิดอยู่', style: TextStyle(fontSize: 12, color: on ? Colors.green.shade800 : Colors.grey.shade700)),
          Switch(
            value: on,
            onChanged: _busy || _st == null
                ? null
                : (v) => _save({key: v}, v ? 'เปิดให้เว็บอื่นดึง "$title" แล้ว' : 'ปิด "$title" แล้ว เว็บอื่นดึงไม่ได้ทันที'),
          ),
        ]),
        Text(detail, style: TextStyle(fontSize: 12, color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: on ? () => _copy(key) : null,
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('คัดลอกโค้ดสำหรับวาง'),
          ),
          OutlinedButton.icon(
            onPressed: on ? () => _preview(key) : null,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('ดูตัวอย่าง'),
          ),
        ]),
      ]),
    );
  }

  Widget _howTo(String base) {
    const style = TextStyle(fontSize: 12.5, height: 1.5);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: const Text('วิธีนำไปใส่เว็บ • สำหรับคนเขียนเว็บ (API)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          'Google Sites: แทรก → ฝัง → ฝังโค้ด → วางโค้ด → ถัดไป → แทรก แล้วลากขอบกรอบให้สูงพอ\n'
          'WordPress: เพิ่มบล็อก "HTML ที่กำหนดเอง" แล้ววางโค้ด • เว็บอื่น: วางในส่วน HTML ของหน้า\n'
          'ตารางสอนเฉพาะครูคนเดียว (เช่น หน้าประวัติครู): ในโค้ดแก้ data-teacher="" เป็นชื่อครู เช่น data-teacher="ครูสมชาย ใจดี"\n'
          'Facebook / LINE วางโค้ดไม่ได้ ให้แชร์ลิงก์หน้าเว็บโรงเรียนที่วางโค้ดไว้แทน\n\n'
          'API (JSON อ่านอย่างเดียว ไม่ต้องล็อกอิน • ผลพักไว้ 60 วินาที • จำกัด 60 ครั้ง/นาที/เครื่อง):\n'
          '  $base/api/public/v1/info  — ชื่อโรงเรียน สี ภาคเรียนปัจจุบัน\n'
          '  $base/api/public/v1/dashboard?term=2&year=2569&month=2026-11  — สรุปการมาเรียน (month ไม่ใส่ = ทั้งภาคเรียน)\n'
          '  $base/api/public/v1/timetables?term=2&year=2569&teacher=ชื่อครู  — ตารางสอน (teacher ไม่ใส่ = ทุกคน)\n'
          'ผ่านลิงก์ ngrok ต้องส่ง header  ngrok-skip-browser-warning: 1  (โค้ดสำหรับวางใส่ให้แล้ว)\n'
          'ฝังหน้าเว็บของระบบแบบ iframe ผ่าน ngrok ฟรีไม่ได้ (ngrok ขึ้นหน้าเตือนก่อน) จึงใช้โค้ดสำหรับวางแทน',
          style: style,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = _st;
    final base = '${st?['effective_base_url'] ?? ''}';
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
              child: Icon(Icons.public_rounded, color: Colors.indigo.shade900),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('แสดงข้อมูลบนเว็บอื่น (API สาธารณะ)', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                Text(
                  'ให้เว็บโรงเรียน / Google Sites แสดงแดชบอร์ดและตารางสอนครูได้ โดยคนดูไม่ต้องล็อกอิน • ข้อมูลอ่านอย่างเดียว '
                  '• ไม่มีชื่อ เลขประจำตัว หรือข้อมูลรายคนของนักเรียน',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
            IconButton(tooltip: 'รีเฟรช', onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh_rounded)),
          ]),
          const SizedBox(height: 14),
          if (st == null)
            const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
          else ...[
            _dataset('dashboard', Icons.insights_rounded, 'แดชบอร์ดการมาเรียน',
                'ตัวเลขสรุปเท่านั้น: จำนวนนักเรียน • % มาเรียนรวมและรายชั้น (เลือกเดือนได้) • จำนวนกลุ่มเสี่ยง/เฝ้าระวัง'),
            _dataset('timetable', Icons.calendar_view_week_rounded, 'ตารางสอนครู',
                'วัน คาบ รหัสวิชา ชื่อวิชา ชั้น ห้อง ของครูทุกคน (เลือกครูได้) • บนมือถือแสดงเป็นรายการตามวัน'),
            const SizedBox(height: 4),
            Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 360,
                child: TextField(
                  controller: _baseCtrl,
                  decoration: InputDecoration(
                    labelText: 'ที่อยู่เว็บของระบบ (ใส่ในโค้ดสำหรับวาง)',
                    hintText: '${st['default_base_url'] ?? ''}',
                    helperText: 'เว้นว่าง = ใช้ลิงก์ออนไลน์ของระบบ ${st['default_base_url'] ?? ''}',
                    helperMaxLines: 2,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _save({'base_url': _baseCtrl.text.trim()}, 'บันทึกที่อยู่เว็บแล้ว • คัดลอกโค้ดใหม่ไปวางแทนของเดิม'),
                child: const Text('บันทึก'),
              ),
            ]),
            const SizedBox(height: 6),
            _howTo(base),
          ],
        ]),
      ),
    );
  }
}
