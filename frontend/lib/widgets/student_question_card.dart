import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../utils/app_theme.dart';
import 'question_kinds.dart';

/// One question as a student sees it (the exam page, and the teacher's phone preview beside the editor).
/// [q] is the student's copy (no key): type, q, points, parts, image, as_image, and choices / unit / items /
/// options / letters / segments / bank.

const _letters = 'กขคงจ';

String _n(dynamic v) {
  if (v == null) return '-';
  final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

/// a set with nothing filled is "not answered"
dynamic _orNull(List<dynamic> v) => filledParts(v) == 0 ? null : v;

bool studentAnswered(Map q, dynamic answer, {int photos = 0}) {
  final type = '${q['type'] ?? 'choice'}';
  if (type == 'photo') return photos > 0;
  if (setTypes.contains(type)) return filledParts(answer) >= ((q['parts'] as num?)?.toInt() ?? 1);
  return answer != null && '$answer'.trim().isNotEmpty;
}

class StudentQuestionCard extends StatelessWidget {
  final ApiService api;
  final int index;
  final Map q;
  final dynamic answer;
  final ValueChanged<dynamic> onAnswer;
  final TextEditingController? textCtrl; // เติมตัวเลข / เติมคำ
  final Widget? photoArea; // เขียนตอบ ถ่ายภาพส่ง: the camera buttons
  final bool done;
  const StudentQuestionCard({
    super.key,
    required this.api,
    required this.index,
    required this.q,
    required this.answer,
    required this.onAnswer,
    this.textCtrl,
    this.photoArea,
    this.done = false,
  });

  bool get _asImage => q['as_image'] == true && q['image'] != null;

  @override
  Widget build(BuildContext context) {
    final type = '${q['type'] ?? 'choice'}';
    final parts = (q['parts'] as num?)?.toInt() ?? 1;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: done ? AppColors.gold : Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_asImage)
            Text('ข้อ ${index + 1}', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600))
          else
            Text('${index + 1}. ${q['q']}', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
          Text(
              setTypes.contains(type)
                  ? '$parts ช่อง ช่องละ ${_n(q['points'] ?? 1)} คะแนน${type == 'truefalse' ? ' • เลือก ✓ หรือ ✗ ทุกข้อ' : type == 'match' ? ' • เลือกตัวอักษรที่คู่กัน' : ''}'
                  : '${_n(q['points'] ?? 1)} คะแนน${type == 'number' ? ' • ตอบเป็นตัวเลข' : type == 'text' ? ' • พิมพ์คำตอบ' : type == 'photo' ? ' • เขียนในกระดาษแล้วถ่ายภาพส่ง' : ''}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          if (q['image'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _asImage
                  ? ExamImage(api: api, name: '${q['image']}', height: 640, wide: true)
                  : ExamImage(api: api, name: '${q['image']}', height: 180),
            ),
          const SizedBox(height: 6),
          if (type == 'choice') ..._choiceItems(),
          if (type == 'number') _field(number: true),
          if (type == 'text') _field(number: false),
          if (type == 'truefalse')
            TrueFalseAnswer(items: (q['items'] as List).map((e) => '$e').toList(), value: answer, onChanged: (v) => onAnswer(_orNull(v))),
          if (type == 'match')
            MatchAnswer(
              api: api,
              items: (q['items'] as List).cast<Map>(),
              options: (q['options'] as List).cast<Map>(),
              letters: '${q['letters'] ?? ''}',
              value: answer,
              onChanged: (v) => onAnswer(_orNull(v)),
            ),
          if (type == 'cloze')
            ClozeAnswer(
              segments: (q['segments'] as List).map((e) => '$e').toList(),
              bank: (q['bank'] as List? ?? []).map((e) => '$e').toList(),
              value: answer,
              onChanged: (v) => onAnswer(_orNull(v)),
            ),
          if (type == 'photo') photoArea ?? const SizedBox.shrink(),
        ]),
      ),
    );
  }

  List<Widget> _choiceItems() {
    final choices = (q['choices'] as List).map((e) => '$e').toList();
    // the letters printed on the paper: a b c d / 1 2 3 4 (ก ข ค ง when not given)
    final lbl = '${q['labels'] ?? ''}'.length >= choices.length ? '${q['labels']}' : _letters;
    final picked = answer is num ? (answer as num).toInt() : null;
    if (_asImage) {
      // the choices are in the picture: pick the letter
      return [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(spacing: 10, runSpacing: 8, children: [
            for (var c = 0; c < choices.length; c++)
              ChoiceChip(
                showCheckmark: false,
                labelPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                label: Text(lbl[c], style: TextStyle(fontSize: 20, fontWeight: picked == c ? FontWeight.bold : FontWeight.normal)),
                selected: picked == c,
                selectedColor: const Color(0xFFEDE9FE),
                onSelected: (_) => onAnswer(c),
              ),
          ]),
        ),
      ];
    }
    return [
      for (var c = 0; c < choices.length; c++)
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onAnswer(c),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(picked == c ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: picked == c ? AppColors.purpleDark : Colors.grey, size: 22),
              const SizedBox(width: 8),
              Text('${lbl[c]}. ', style: const TextStyle(fontSize: 15)),
              Expanded(child: Text(choices[c], style: const TextStyle(fontSize: 15))),
            ]),
          ),
        ),
    ];
  }

  Widget _field({required bool number}) {
    final unit = '${q['unit'] ?? ''}';
    final field = TextField(
      controller: textCtrl,
      keyboardType: number ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
      style: const TextStyle(fontSize: 17),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        labelText: number ? 'คำตอบ (ตัวเลข)' : 'คำตอบ',
        hintText: number ? 'เช่น 45, -3.5, 3/4' : null,
      ),
      onChanged: (v) => onAnswer(v.trim().isEmpty ? null : v),
    );
    return Row(children: [
      if (number) SizedBox(width: 200, child: field) else Expanded(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: field)),
      if (unit.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 8), child: Text(unit, style: const TextStyle(fontSize: 15))),
    ]);
  }
}

// ---------------------------------------------------------------- the teacher's preview: a phone beside the editor

/// The student's copy of a question as the editor holds it (what the server's student_question sends: no key).
Map<String, dynamic> studentCopy(Map<String, dynamic> t, {int parts = 1}) {
  final type = '${t['type'] ?? 'choice'}';
  const defaults = {'truefalse': 'ข้อความต่อไปนี้ถูกหรือผิด', 'match': 'จับคู่ให้ถูกต้อง', 'cloze': 'เติมคำในช่องว่างให้ถูกต้อง'};
  var text = '${t['q'] ?? ''}'.trim();
  if (text.isEmpty) text = defaults[type] ?? (t['as_image'] == true ? 'ดูโจทย์จากภาพ' : '(ยังไม่มีโจทย์)');
  final q = <String, dynamic>{
    'type': type,
    'q': text,
    'points': num.tryParse('${t['points'] ?? 1}') ?? 1,
    'parts': parts,
    if (t['image'] != null) 'image': t['image'],
    if (t['image'] != null && t['as_image'] == true) 'as_image': true,
  };
  switch (type) {
    case 'choice':
      q['choices'] = [for (final c in (t['choices'] as List? ?? [])) if ('$c'.trim().isNotEmpty) '$c'.trim()];
      if (t['labels'] == 'latin') q['labels'] = 'abcde';
      if (t['labels'] == 'number') q['labels'] = '12345';
    case 'number':
    case 'text':
      q['unit'] = '${t['unit'] ?? ''}';
    case 'truefalse':
      q['items'] = [for (final it in (t['items'] as List? ?? [])) '${(it as Map)['text'] ?? ''}'];
    case 'match':
      final opts = [for (final o in (t['options'] as List? ?? [])) if ('${(o as Map)['text'] ?? ''}'.trim().isNotEmpty || o['image'] != null) o];
      q['items'] = [for (final it in (t['items'] as List? ?? [])) {'text': (it as Map)['text'] ?? '', if (it['image'] != null) 'image': it['image']}];
      q['options'] = opts;
      final l = matchLetters[t['letters'] == 'latin' ? 'latin' : 'thai']!;
      q['letters'] = l.substring(0, opts.length.clamp(0, l.length));
    case 'cloze':
      q['segments'] = '${t['text'] ?? ''}'.split(RegExp(r'\[\[.*?\]\]'));
      q['bank'] = (t['bank'] as List? ?? []).map((e) => '$e').toList();
  }
  return q;
}

/// A phone showing the paper the way a student gets it; answers here are only for trying, nothing is sent.
/// [questions] is called again every moment so the phone follows the editor as the teacher types.
class StudentPhonePreview extends StatefulWidget {
  final ApiService api;
  final String title;
  final String header;
  final List<Map<String, dynamic>> Function() questions;
  final int? durationMin;
  final double height;
  const StudentPhonePreview({super.key, required this.api, required this.title, required this.header, required this.questions, this.durationMin, this.height = 760});

  @override
  State<StudentPhonePreview> createState() => _StudentPhonePreviewState();
}

class _StudentPhonePreviewState extends State<StudentPhonePreview> {
  final Map<String, dynamic> _answers = {};
  final Map<String, TextEditingController> _ctrls = {};
  Timer? _tick;
  String _sig = '';

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 700), (_) {
      // follow the editor: rebuild when the paper changed
      final sig = widget.questions().toString();
      if (sig != _sig && mounted) setState(() => _sig = sig);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final qs = widget.questions();
    final answered = [for (var i = 0; i < qs.length; i++) if (studentAnswered(qs[i], _answers['$i'])) i].length;
    final mins = widget.durationMin;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 392,
        height: widget.height,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(34)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Container(
            color: const Color(0xFFFFF8E7),
            child: Column(children: [
              Container(
                color: AppColors.purplePrimary,
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                child: Row(children: [
                  const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(widget.header, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.bold, fontSize: 16))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                    child: Text(mins == null ? 'ถึงเวลาปิด' : 'เหลือ ${mins >= 60 ? '${mins ~/ 60}:${(mins % 60).toString().padLeft(2, '0')}:00' : '${mins.toString().padLeft(2, '0')}:00'}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ]),
              ),
              Expanded(
                child: qs.isEmpty
                    ? const Center(child: Text('ยังไม่มีข้อสอบ'))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
                        itemCount: qs.length + 1,
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            );
                          }
                          final k = i - 1;
                          final q = qs[k];
                          final type = '${q['type']}';
                          final ctrl = type == 'number' || type == 'text' ? _ctrls.putIfAbsent('$k', () => TextEditingController()) : null;
                          return StudentQuestionCard(
                            key: ValueKey('preview-$k-$type-${q['parts']}'),
                            api: widget.api,
                            index: k,
                            q: q,
                            answer: _answers['$k'],
                            textCtrl: ctrl,
                            done: studentAnswered(q, _answers['$k']),
                            onAnswer: (v) => setState(() {
                              if (v == null) {
                                _answers.remove('$k');
                              } else {
                                _answers['$k'] = v;
                              }
                            }),
                            photoArea: Wrap(spacing: 8, children: [
                              FilledButton.icon(onPressed: null, icon: const Icon(Icons.photo_camera_rounded), label: const Text('ถ่ายภาพ')),
                              OutlinedButton.icon(onPressed: null, icon: const Icon(Icons.photo_library_outlined), label: const Text('เลือกรูป')),
                            ]),
                          );
                        },
                      ),
              ),
              Container(
                color: const Color(0xFFFFF8E7),
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Row(children: [
                  Expanded(child: Text('ตอบแล้ว $answered/${qs.length} ข้อ', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                  FilledButton.icon(onPressed: null, icon: const Icon(Icons.send_rounded, size: 18), label: const Text('ส่งคำตอบ')),
                ]),
              ),
            ]),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('มุมมองนักเรียน (มือถือ) • ลองกดตอบได้ ไม่บันทึก • ของจริงสลับลำดับข้อให้แต่ละคน',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
      ),
    ]);
  }
}
