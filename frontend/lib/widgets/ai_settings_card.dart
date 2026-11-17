import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

/// ตัวช่วย AI ออกข้อสอบ (ผู้ดูแลระบบ): the Gemini key (kept on the server only, never shown again), the model,
/// and how many times a day each teacher may ask.
class AiSettingsCard extends StatefulWidget {
  final ApiService apiService;
  const AiSettingsCard({super.key, required this.apiService});

  @override
  State<AiSettingsCard> createState() => _AiSettingsCardState();
}

class _AiSettingsCardState extends State<AiSettingsCard> {
  Map<String, dynamic>? _st;
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _limit = TextEditingController();
  bool _busy = false;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _limit.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? Colors.red.shade700 : null));
  }

  String _err(Object e) => e.toString().replaceFirst('Exception: ', '');

  void _fill(Map<String, dynamic> st) {
    _st = st;
    _model.text = '${st['model'] ?? ''}';
    _limit.text = '${st['daily_limit'] ?? 30}';
  }

  Future<void> _load() async {
    try {
      final st = await widget.apiService.getAiStatus();
      if (mounted) setState(() => _fill(st));
    } catch (e) {
      _snack(_err(e), error: true);
    }
  }

  Future<void> _save({bool clear = false}) async {
    setState(() => _busy = true);
    try {
      final st = await widget.apiService.saveAiSettings(
        apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
        model: _model.text.trim(),
        dailyLimit: int.tryParse(_limit.text.trim()),
        clearKey: clear,
      );
      _key.clear();
      if (mounted) setState(() => _fill(st));
      _snack(clear ? 'ลบกุญแจ AI แล้ว' : 'บันทึกการตั้งค่า AI แล้ว');
    } catch (e) {
      _snack(_err(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    try {
      _snack('เชื่อมต่อ AI สำเร็จ: ${await widget.apiService.testAi()}');
    } catch (e) {
      _snack(_err(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = _st;
    final configured = st?['configured'] == true;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.deepPurple.shade100, borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.auto_awesome_rounded, color: Colors.deepPurple.shade900),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ตัวช่วย AI ออกข้อสอบ (Gemini)', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                Text(
                  'ครูผู้สอนใช้ร่างแบบทดสอบย่อย / กลางภาค / ปลายภาค ในเมนู "ตัวช่วย AI" • กุญแจเก็บบนเครื่องเซิร์ฟเวอร์เท่านั้น '
                  '(ไม่อยู่ในไฟล์สำรอง ต้องใส่ใหม่หลังกู้คืน) • ส่งเฉพาะตัวชี้วัดและเนื้อหาที่ครูเลือก ไม่ส่งข้อมูลนักเรียน',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
            IconButton(tooltip: 'รีเฟรช', onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh_rounded)),
          ]),
          const SizedBox(height: 14),
          if (st == null)
            const LinearProgressIndicator()
          else ...[
            Row(children: [
              Icon(configured ? Icons.check_circle_rounded : Icons.key_off_rounded, color: configured ? Colors.green : Colors.orange),
              const SizedBox(width: 6),
              Expanded(child: Text(configured ? 'ตั้งกุญแจแล้ว (${st['key_hint'] ?? ''})' : 'ยังไม่ได้ตั้งกุญแจ ครูยังใช้ตัวช่วย AI ไม่ได้')),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: [
              SizedBox(
                width: 420,
                child: TextField(
                  controller: _key,
                  obscureText: !_show,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    labelText: configured ? 'กุญแจใหม่ (ว่าง = ใช้อันเดิม)' : 'Gemini API key',
                    hintText: 'วางกุญแจจาก AI Studio ทั้งหมด (AIza... หรือ AQ....)',
                    suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show)),
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _model,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'รุ่น AI', hintText: 'gemini-flash-latest'),
                ),
              ),
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _limit,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'ครั้งต่อวัน ต่อครู 1 คน'),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(onPressed: _busy ? null : () => _save(), icon: const Icon(Icons.save_rounded), label: const Text('บันทึก')),
              OutlinedButton.icon(
                onPressed: _busy || !configured ? null : _test,
                icon: const Icon(Icons.wifi_tethering_rounded),
                label: const Text('ทดสอบการเชื่อมต่อ'),
              ),
              if (configured)
                TextButton.icon(
                  onPressed: _busy ? null : () => _save(clear: true),
                  icon: Icon(Icons.delete_outline, color: Colors.red.shade700),
                  label: Text('ลบกุญแจ', style: TextStyle(color: Colors.red.shade700)),
                ),
              TextButton.icon(
                onPressed: () => launchUrl(Uri.parse('https://aistudio.google.com/apikey')),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('ขอกุญแจที่ Google AI Studio'),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
              'กุญแจแบบฟรี: Google อาจนำเนื้อหาที่ส่งไปปรับปรุงบริการและให้คนอ่านได้ • ใช้เฉพาะครู (ผู้ใช้ต้องอายุ 18 ปีขึ้นไป) นักเรียนใช้ไม่ได้ '
              '• ถ้าต้องการให้เนื้อหาเป็นความลับ ให้เปิดการเรียกเก็บเงินในโครงการ Google Cloud ของกุญแจ',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ],
        ]),
      ),
    );
  }
}
