import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// ข้อสอบแบบชุด (ถูก/ผิด, จับคู่, cloze) and เติมคำ: the teacher's editors, the student's answer widgets, and
/// the rows of the teacher's review. Points of a set are per part (statement / pair / blank).

const setTypes = {'truefalse', 'match', 'cloze'};
const matchLetters = {'thai': 'กขคงจฉชซฌญฎฏฐฑฒณดตถท', 'latin': 'abcdefghijklmnopqrst'};
final _blankRe = RegExp(r'\[\[(.*?)\]\]');
const _ok = Color(0xFF15803D);

String _thaiDigits(String s) {
  const th = '๐๑๒๓๔๕๖๗๘๙';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = th.indexOf(ch);
    b.write(i >= 0 ? '$i' : ch);
  }
  return b.toString();
}

/// A word as the server compares it: no case, spaces or punctuation.
String normWord(String s) => _thaiDigits(s)
    .toLowerCase()
    .replaceAll('ํา', 'ำ')
    .replaceAll(RegExp(r'''[\s.,;:!?"'“”‘’()\[\]{}…\-–—_]+'''), '');

List<String> splitAccepts(String s) => s.split(RegExp(r'[/|]')).map((e) => e.trim()).where((e) => normWord(e).isNotEmpty).toList();

List<List<String>> clozeBlanks(String text) => _blankRe.allMatches(text).map((m) => splitAccepts(m.group(1) ?? '')).toList();

String letterOf(String letters, int i) => i >= 0 && i < letters.length ? letters[i] : '?';

// ---------------------------------------------------------------- pictures

Future<String?> pickExamImage(BuildContext context, ApiService api) async {
  final picked = await FilePicker.pickFiles(type: FileType.image);
  if (picked.isEmpty) return null;
  try {
    return await api.uploadExamImage(await picked.first.readAsBytes(), picked.first.name);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Colors.red.shade700));
    }
    return null;
  }
}

class ExamImage extends StatelessWidget {
  final ApiService api;
  final String name;
  final double height;
  /// as wide as the card (a question shown as its printed picture), at most this tall
  final bool wide;
  const ExamImage({super.key, required this.api, required this.name, this.height = 140, this.wide = false});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => showDialog(
          context: context,
          builder: (ctx) => Dialog(
            insetPadding: const EdgeInsets.all(8),
            child: Stack(children: [
              InteractiveViewer(maxScale: 5, child: Image.network(api.examImageUrl(name))),
              Positioned(right: 4, top: 4, child: IconButton.filledTonal(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx))),
            ]),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: wide
              ? ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: height, maxWidth: 760),
                  child: Image.network(api.examImageUrl(name), fit: BoxFit.contain, alignment: Alignment.centerLeft,
                      errorBuilder: (_, _, _) => const SizedBox(height: 80, child: Icon(Icons.broken_image_outlined))),
                )
              : Image.network(api.examImageUrl(name), height: height, fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => SizedBox(width: height, height: height, child: const Icon(Icons.broken_image_outlined))),
        ),
      );
}

/// A small picture slot in the editor: add / change / remove.
class ImageSlot extends StatelessWidget {
  final ApiService api;
  final String? name;
  final ValueChanged<String?> onChanged;
  final String label;
  final double height;
  const ImageSlot({super.key, required this.api, required this.name, required this.onChanged, this.label = 'ใส่รูป', this.height = 56});

  @override
  Widget build(BuildContext context) {
    if (name == null) {
      return IconButton(
        tooltip: label,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        onPressed: () async {
          final n = await pickExamImage(context, api);
          if (n != null) onChanged(n);
        },
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ExamImage(api: api, name: name!, height: height),
      IconButton(
        tooltip: 'เปลี่ยนรูป',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.swap_horiz_rounded, size: 18),
        onPressed: () async {
          final n = await pickExamImage(context, api);
          if (n != null) onChanged(n);
        },
      ),
      IconButton(tooltip: 'เอารูปออก', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: () => onChanged(null)),
    ]);
  }
}

// ---------------------------------------------------------------- the teacher's draft of a set

class PartDraft {
  final TextEditingController text;
  bool? tf; // ถูก/ผิด
  int? pair; // จับคู่: the option's index
  String? image;
  PartDraft({String t = '', this.tf, this.pair, this.image}) : text = TextEditingController(text: t);
  bool get filled => text.text.trim().isNotEmpty || image != null;
}

class OptionDraft {
  final TextEditingController text;
  String? image;
  OptionDraft({String t = '', this.image}) : text = TextEditingController(text: t);
  bool get filled => text.text.trim().isNotEmpty || image != null;
}

class KindDraft {
  final List<PartDraft> items = [];
  final List<OptionDraft> options = [];
  String letters = 'thai';
  final TextEditingController cloze = TextEditingController();
  final TextEditingController bank = TextEditingController();

  void load(String type, Map q) {
    if (type == 'truefalse' || type == 'match') {
      for (final it in (q['items'] as List? ?? [])) {
        final m = it is Map ? it : {'text': '$it'};
        items.add(PartDraft(
          t: '${m['text'] ?? ''}',
          tf: m['answer'] is bool ? m['answer'] as bool : null,
          pair: type == 'match' && m['answer'] is num ? (m['answer'] as num).toInt() : null,
          image: m['image'] == null || '${m['image']}'.isEmpty ? null : '${m['image']}',
        ));
      }
    }
    if (type == 'match') {
      letters = q['letters'] == 'latin' ? 'latin' : 'thai';
      for (final o in (q['options'] as List? ?? [])) {
        final m = o is Map ? o : {'text': '$o'};
        options.add(OptionDraft(t: '${m['text'] ?? ''}', image: m['image'] == null || '${m['image']}'.isEmpty ? null : '${m['image']}'));
      }
    }
    if (type == 'cloze') {
      cloze.text = '${q['text'] ?? ''}';
      bank.text = (q['bank'] as List? ?? []).map((e) => '$e').join(', ');
    }
  }

  /// Rows to type into when a question is switched to a set.
  void ensure(String type) {
    if ((type == 'truefalse' || type == 'match') && items.isEmpty) {
      for (var i = 0; i < 3; i++) {
        items.add(PartDraft());
      }
    }
    if (type == 'match') {
      while (options.length < 3) {
        options.add(OptionDraft());
      }
    }
  }

  List<String> get bankWords => bank.text.split(RegExp(r'[,\n，、|]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  int parts(String type) => switch (type) {
        'truefalse' || 'match' => items.where((i) => i.filled).length,
        'cloze' => _blankRe.allMatches(cloze.text).length,
        _ => 1,
      };

  bool hasKey(String type) {
    switch (type) {
      case 'truefalse':
        final f = items.where((i) => i.filled);
        return f.isNotEmpty && f.every((i) => i.tf != null);
      case 'match':
        final f = items.where((i) => i.filled);
        return options.where((o) => o.filled).length >= 2 && f.isNotEmpty && f.every((i) => i.pair != null && i.pair! < options.length && options[i.pair!].filled);
      case 'cloze':
        final b = clozeBlanks(cloze.text);
        final words = bankWords.map(normWord).toSet();
        return b.isNotEmpty && b.every((a) => a.isNotEmpty && (words.isEmpty || a.any((x) => words.contains(normWord(x)))));
    }
    return true;
  }

  Map<String, dynamic> toJson(String type) => switch (type) {
        'truefalse' => {
            'items': [for (final i in items) if (i.filled) {'text': i.text.text.trim(), 'answer': i.tf}],
          },
        'match' => {
            'letters': letters,
            'options': [for (final o in options) {'text': o.text.text.trim(), if (o.image != null) 'image': o.image}],
            'items': [
              for (final i in items)
                if (i.filled) {'text': i.text.text.trim(), 'answer': i.pair, if (i.image != null) 'image': i.image},
            ],
          },
        'cloze' => {'text': cloze.text, 'bank': bankWords},
        _ => <String, dynamic>{},
      };

  void dispose() {
    for (final i in items) {
      i.text.dispose();
    }
    for (final o in options) {
      o.text.dispose();
    }
    cloze.dispose();
    bank.dispose();
  }
}

/// The editor of a set (ถูก/ผิด, จับคู่, cloze); onChanged lets the card recount points and the key.
class KindEditor extends StatefulWidget {
  final String type;
  final KindDraft d;
  final ApiService api;
  final VoidCallback onChanged;
  const KindEditor({super.key, required this.type, required this.d, required this.api, required this.onChanged});

  @override
  State<KindEditor> createState() => _KindEditorState();
}

class _KindEditorState extends State<KindEditor> {
  KindDraft get d => widget.d;

  void _changed([VoidCallback? f]) {
    setState(f ?? () {});
    widget.onChanged();
  }

  InputDecoration _dec(String hint) => InputDecoration(isDense: true, hintText: hint);

  Widget _note(String s) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(s, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      );

  @override
  Widget build(BuildContext context) => switch (widget.type) {
        'truefalse' => _trueFalse(),
        'match' => _match(),
        'cloze' => _cloze(),
        _ => const SizedBox.shrink(),
      };

  Widget _trueFalse() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var k = 0; k < d.items.length; k++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              SizedBox(width: 28, child: Text('${k + 1}.')),
              Expanded(child: TextField(controller: d.items[k].text, decoration: _dec('ข้อความ'), onChanged: (_) => _changed())),
              const SizedBox(width: 6),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                emptySelectionAllowed: true,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: true, label: Text('✓ ถูก')),
                  ButtonSegment(value: false, label: Text('✗ ผิด')),
                ],
                selected: d.items[k].tf == null ? <bool>{} : {d.items[k].tf!},
                onSelectionChanged: (s) => _changed(() => d.items[k].tf = s.isEmpty ? null : s.first),
              ),
              IconButton(
                tooltip: 'ลบข้อย่อย',
                icon: const Icon(Icons.close, size: 18),
                onPressed: d.items.length <= 1
                    ? null
                    : () {
                        final gone = d.items.removeAt(k);
                        _changed();
                        WidgetsBinding.instance.addPostFrameCallback((_) => gone.text.dispose());
                      },
              ),
            ]),
          ),
        TextButton.icon(onPressed: () => _changed(() => d.items.add(PartDraft())), icon: const Icon(Icons.add, size: 18), label: const Text('ข้อย่อย')),
        _note('นักเรียนเลือก ✓ หรือ ✗ ทีละข้อ • ช่อง "คะแนน" ด้านบน = คะแนนต่อข้อย่อย • สลับลำดับข้อย่อยให้แต่ละคน'),
      ]);

  Widget _match() {
    final letters = matchLetters[d.letters]!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('ตัวเลือกใช้'),
        SegmentedButton<String>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [ButtonSegment(value: 'thai', label: Text('ก ข ค')), ButtonSegment(value: 'latin', label: Text('a b c'))],
          selected: {d.letters},
          onSelectionChanged: (s) => _changed(() => d.letters = s.first),
        ),
      ]),
      const SizedBox(height: 6),
      const Text('ตัวเลือก (คำตอบที่ให้จับคู่ ใส่เป็นข้อความหรือรูปก็ได้)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      for (var j = 0; j < d.options.length; j++)
        Row(children: [
          SizedBox(width: 28, child: Text('${letterOf(letters, j)}.')),
          Expanded(child: TextField(controller: d.options[j].text, decoration: _dec('ข้อความ (หรือใส่รูป)'), onChanged: (_) => _changed())),
          ImageSlot(api: widget.api, name: d.options[j].image, onChanged: (n) => _changed(() => d.options[j].image = n)),
          IconButton(
            tooltip: 'ลบตัวเลือก',
            icon: const Icon(Icons.close, size: 18),
            onPressed: d.options.length <= 2
                ? null
                : () {
                    final gone = d.options.removeAt(j);
                    _changed(() {
                      for (final it in d.items) {
                        if (it.pair == j) {
                          it.pair = null;
                        } else if (it.pair != null && it.pair! > j) {
                          it.pair = it.pair! - 1;
                        }
                      }
                    });
                    WidgetsBinding.instance.addPostFrameCallback((_) => gone.text.dispose());
                  },
          ),
        ]),
      if (d.options.length < letters.length)
        TextButton.icon(onPressed: () => _changed(() => d.options.add(OptionDraft())), icon: const Icon(Icons.add, size: 18), label: const Text('ตัวเลือก')),
      const SizedBox(height: 6),
      const Text('ข้อที่ให้นักเรียนจับคู่ และคู่ที่ถูก', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      for (var k = 0; k < d.items.length; k++)
        Row(children: [
          SizedBox(width: 28, child: Text('${k + 1}.')),
          Expanded(child: TextField(controller: d.items[k].text, decoration: _dec('ข้อ'), onChanged: (_) => _changed())),
          ImageSlot(api: widget.api, name: d.items[k].image, onChanged: (n) => _changed(() => d.items[k].image = n)),
          DropdownButton<int>(
            value: d.items[k].pair != null && d.items[k].pair! < d.options.length ? d.items[k].pair : null,
            hint: Text('คู่', style: TextStyle(color: Colors.orange.shade800)),
            items: [for (var j = 0; j < d.options.length; j++) DropdownMenuItem(value: j, child: Text(letterOf(letters, j)))],
            onChanged: (v) => _changed(() => d.items[k].pair = v),
          ),
          IconButton(
            tooltip: 'ลบข้อ',
            icon: const Icon(Icons.close, size: 18),
            onPressed: d.items.length <= 1
                ? null
                : () {
                    final gone = d.items.removeAt(k);
                    _changed();
                    WidgetsBinding.instance.addPostFrameCallback((_) => gone.text.dispose());
                  },
          ),
        ]),
      TextButton.icon(onPressed: () => _changed(() => d.items.add(PartDraft())), icon: const Icon(Icons.add, size: 18), label: const Text('ข้อ')),
      _note('ตัวเลือกมากกว่าข้อได้ (ตัวลวง) • ใช้ตัวเลือกซ้ำได้ • ช่อง "คะแนน" ด้านบน = คะแนนต่อคู่'),
    ]);
  }

  void _wrapSelection() {
    final c = d.cloze;
    final sel = c.selection;
    final text = c.text;
    if (!sel.isValid || sel.isCollapsed) {
      final at = sel.isValid ? sel.start : text.length;
      c.value = TextEditingValue(text: '${text.substring(0, at)}[[]]${text.substring(at)}', selection: TextSelection.collapsed(offset: at + 2));
    } else {
      final word = text.substring(sel.start, sel.end).trim();
      c.value = TextEditingValue(
        text: '${text.substring(0, sel.start)}[[$word]]${text.substring(sel.end)}',
        selection: TextSelection.collapsed(offset: sel.start + word.length + 4),
      );
    }
    _changed();
  }

  Widget _cloze() {
    final blanks = clozeBlanks(d.cloze.text);
    final words = d.bankWords.map(normWord).toSet();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: d.cloze,
        minLines: 3,
        maxLines: 14,
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          labelText: 'เรื่อง / ข้อความ — ใส่คำตอบไว้ใน [[ ]]',
          hintText: 'เช่น Giraffes are the [[tallest]] living animal in the world. They can [[grow]] up to ...',
        ),
        onChanged: (_) => _changed(),
      ),
      Wrap(spacing: 8, children: [
        TextButton.icon(onPressed: _wrapSelection, icon: const Icon(Icons.space_bar_rounded, size: 18), label: const Text('ทำคำที่เลือกเป็นช่องว่าง')),
        TextButton.icon(
          onPressed: blanks.isEmpty
              ? null
              : () => _changed(() {
                    final have = d.bankWords;
                    for (final a in blanks) {
                      if (a.isNotEmpty && !a.any((x) => have.map(normWord).contains(normWord(x)))) have.add(a.first);
                    }
                    d.bank.text = have.join(', ');
                  }),
          icon: const Icon(Icons.playlist_add_rounded, size: 18),
          label: const Text('ใส่คำตอบทุกช่องลงกล่องคำ'),
        ),
      ]),
      TextField(
        controller: d.bank,
        decoration: const InputDecoration(
          isDense: true,
          labelText: 'กล่องคำ (คั่นด้วย , ) — มีกล่องคำ = นักเรียนเลือกคำ, ว่าง = นักเรียนพิมพ์เอง',
          hintText: 'เช่น most, up, grow, necks, Africa',
        ),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 4, children: [
        for (var k = 0; k < blanks.length; k++)
          Chip(
            visualDensity: VisualDensity.compact,
            backgroundColor: blanks[k].isEmpty || (words.isNotEmpty && !blanks[k].any((x) => words.contains(normWord(x))))
                ? Colors.orange.shade50
                : const Color(0xFFF0FDF4),
            label: Text(
              'ช่อง ${k + 1}: ${blanks[k].isEmpty ? 'ยังไม่มีคำตอบ' : blanks[k].join(' / ')}'
              '${blanks[k].isNotEmpty && words.isNotEmpty && !blanks[k].any((x) => words.contains(normWord(x))) ? ' (ไม่อยู่ในกล่องคำ)' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        if (blanks.isEmpty) Text('ยังไม่มีช่องว่าง — เลือกคำในเรื่องแล้วกด "ทำคำที่เลือกเป็นช่องว่าง"', style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
      ]),
      _note('นักเรียนเห็นเป็นช่องว่าง • ตอบได้หลายแบบ คั่นด้วย / เช่น [[colour / color]] • ระบบไม่สนตัวพิมพ์เล็ก/ใหญ่ ช่องว่าง และจุด • '
          'ช่อง "คะแนน" ด้านบน = คะแนนต่อช่อง • ครูกดให้ถูก/ผิดรายช่องได้ในหน้า "ผลสอบ"'),
    ]);
  }
}

/// The teacher's answer key of a set, for "ดูเฉลยทั้งชุด".
String setKeyText(String type, KindDraft d) {
  switch (type) {
    case 'truefalse':
      return [for (var k = 0; k < d.items.length; k++) if (d.items[k].filled) '${k + 1}. ${d.items[k].tf == null ? '(ยังไม่เลือก)' : d.items[k].tf! ? '✓' : '✗'}'].join('   ');
    case 'match':
      final l = matchLetters[d.letters]!;
      return [for (var k = 0; k < d.items.length; k++) if (d.items[k].filled) '${k + 1}. ${d.items[k].pair == null ? '?' : letterOf(l, d.items[k].pair!)}'].join('   ');
    case 'cloze':
      final b = clozeBlanks(d.cloze.text);
      return [for (var k = 0; k < b.length; k++) '(${k + 1}) ${b[k].isEmpty ? '?' : b[k].join(' / ')}'].join('   ');
  }
  return '';
}

// ---------------------------------------------------------------- the student's answers

List<dynamic> _list(dynamic v, int n) {
  final l = v is List ? List<dynamic>.from(v) : <dynamic>[];
  while (l.length < n) {
    l.add(null);
  }
  return l.sublist(0, n);
}

class TrueFalseAnswer extends StatelessWidget {
  final List<String> items;
  final dynamic value;
  final ValueChanged<List<dynamic>> onChanged;
  const TrueFalseAnswer({super.key, required this.items, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final v = _list(value, items.length);
    return Column(children: [
      for (var k = 0; k < items.length; k++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text('${k + 1}. ${items[k]}', style: const TextStyle(fontSize: 15))),
            const SizedBox(width: 6),
            for (final opt in const [true, false])
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: ChoiceChip(
                  showCheckmark: false,
                  label: Text(opt ? '✓ ถูก' : '✗ ผิด', style: const TextStyle(fontSize: 15)),
                  selected: v[k] == opt,
                  selectedColor: opt ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                  onSelected: (s) {
                    final n = List<dynamic>.from(v);
                    n[k] = s ? opt : null;
                    onChanged(n);
                  },
                ),
              ),
          ]),
        ),
    ]);
  }
}

class MatchAnswer extends StatelessWidget {
  final ApiService api;
  final List<Map> items;
  final List<Map> options;
  final String letters;
  final dynamic value;
  final ValueChanged<List<dynamic>> onChanged;
  const MatchAnswer({super.key, required this.api, required this.items, required this.options, required this.letters, required this.value, required this.onChanged});

  Widget _side(Map m, {double h = 90}) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if ('${m['text'] ?? ''}'.isNotEmpty) Text('${m['text']}', style: const TextStyle(fontSize: 15)),
        if (m['image'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: ExamImage(api: api, name: '${m['image']}', height: h)),
      ]);

  @override
  Widget build(BuildContext context) {
    final v = _list(value, items.length);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade300)),
        child: Wrap(spacing: 14, runSpacing: 10, children: [
          for (var j = 0; j < options.length; j++)
            Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${letterOf(letters, j)}. ', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260), child: _side(options[j])),
            ]),
        ]),
      ),
      const SizedBox(height: 8),
      for (var k = 0; k < items.length; k++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                border: Border.all(color: v[k] == null ? Colors.grey.shade400 : const Color(0xFF7C3AED)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButton<int>(
                value: v[k] is int ? v[k] as int : null,
                hint: const Text(' ? '),
                underline: const SizedBox.shrink(),
                items: [for (var j = 0; j < options.length; j++) DropdownMenuItem(value: j, child: Text(letterOf(letters, j), style: const TextStyle(fontSize: 16)))],
                onChanged: (x) {
                  final n = List<dynamic>.from(v);
                  n[k] = x;
                  onChanged(n);
                },
              ),
            ),
            const SizedBox(width: 8),
            Text('${k + 1}. ', style: const TextStyle(fontSize: 15)),
            Expanded(child: _side(items[k], h: 80)),
          ]),
        ),
    ]);
  }
}

class ClozeAnswer extends StatefulWidget {
  final List<String> segments;
  final List<String> bank;
  final dynamic value;
  final ValueChanged<List<dynamic>> onChanged;
  const ClozeAnswer({super.key, required this.segments, required this.bank, required this.value, required this.onChanged});

  @override
  State<ClozeAnswer> createState() => _ClozeAnswerState();
}

class _ClozeAnswerState extends State<ClozeAnswer> {
  final List<TextEditingController> _ctrls = [];
  int get _n => widget.segments.length - 1;

  @override
  void initState() {
    super.initState();
    final v = _list(widget.value, _n);
    for (var k = 0; k < _n; k++) {
      _ctrls.add(TextEditingController(text: v[k] == null ? '' : '${v[k]}'));
    }
  }

  @override
  void didUpdateWidget(covariant ClozeAnswer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // the teacher's preview follows the editor: blanks may be added or removed
    while (_ctrls.length < _n) {
      _ctrls.add(TextEditingController());
    }
    while (_ctrls.length > _n && _ctrls.isNotEmpty) {
      _ctrls.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(int k, String? s) {
    final n = _list(widget.value, _n);
    n[k] = s == null || s.trim().isEmpty ? null : s;
    widget.onChanged(n);
  }

  Widget _blank(int k, List<dynamic> v) {
    final picked = v[k] == null ? null : '${v[k]}';
    if (widget.bank.isNotEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: picked == null ? const Color(0xFFFFFBEB) : const Color(0xFFF5F3FF),
          border: Border.all(color: picked == null ? const Color(0xFFF59E0B) : const Color(0xFF7C3AED)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButton<String>(
          value: widget.bank.contains(picked) ? picked : null,
          hint: Text('(${k + 1}) เลือกคำ', style: const TextStyle(fontSize: 14)),
          underline: const SizedBox.shrink(),
          isDense: true,
          items: [for (final w in widget.bank) DropdownMenuItem(value: w, child: Text(w, style: const TextStyle(fontSize: 15)))],
          onChanged: (x) => _set(k, x),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      width: 140,
      child: TextField(
        controller: _ctrls[k],
        style: const TextStyle(fontSize: 15),
        decoration: InputDecoration(isDense: true, hintText: '(${k + 1})', border: const OutlineInputBorder()),
        onChanged: (s) => _set(k, s),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = _list(widget.value, _n);
    final children = <Widget>[];
    for (var i = 0; i < widget.segments.length; i++) {
      for (final w in widget.segments[i].split(RegExp(r'(?<=\s)'))) {
        if (w.isNotEmpty) children.add(Text(w, style: const TextStyle(fontSize: 15.5, height: 1.9)));
      }
      if (i < _n) children.add(_blank(i, v));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.bank.isNotEmpty)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade300)),
          child: Wrap(spacing: 10, runSpacing: 4, children: [
            for (final w in widget.bank)
              Text(w, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: v.contains(w) ? Colors.grey : Colors.black87,
                  decoration: v.contains(w) ? TextDecoration.lineThrough : null)),
          ]),
        ),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: children),
    ]);
  }
}

/// How many parts of a set the student has filled.
int filledParts(dynamic v) => v is List ? v.where((x) => x != null && '$x'.trim().isNotEmpty).length : 0;

// ---------------------------------------------------------------- the teacher's review: each part, with "ให้ถูก / ให้ผิด"

class PartsReview extends StatelessWidget {
  final ApiService api;
  final Map it;
  final Map<String, bool?> overrides; // "i:j" -> true / false / null (automatic)
  final void Function(String key, bool? value) onOverride;
  const PartsReview({super.key, required this.api, required this.it, required this.overrides, required this.onOverride});

  String _given(int j) {
    final type = '${it['type']}';
    final g = it['given'];
    switch (type) {
      case 'choice':
        final ch = (it['choices'] as List).map((e) => '$e').toList();
        if (g is! num) return '(ไม่ได้ตอบ)';
        final l = '${it['labels'] ?? 'กขคงจ'}'[g.toInt()];
        return ch[g.toInt()] == l || it['image'] != null && ch.every((c) => c.length <= 1) ? l : '$l. ${ch[g.toInt()]}';
      case 'number':
      case 'text':
        return g == null || '$g'.trim().isEmpty ? '(ไม่ได้ตอบ)' : '$g ${it['unit'] ?? ''}'.trim();
      case 'truefalse':
        final x = g is List && j < g.length ? g[j] : null;
        return x == null ? '(ไม่ได้ตอบ)' : (x == true ? '✓ ถูก' : '✗ ผิด');
      case 'match':
        final x = g is List && j < g.length ? g[j] : null;
        if (x is! num) return '(ไม่ได้ตอบ)';
        final o = (it['options'] as List)[x.toInt()] as Map;
        return '${letterOf('${it['letters']}', x.toInt())}${'${o['text'] ?? ''}'.isEmpty ? '' : '. ${o['text']}'}';
      case 'cloze':
        final x = g is List && j < g.length ? g[j] : null;
        return x == null || '$x'.trim().isEmpty ? '(ไม่ได้ตอบ)' : '$x';
    }
    return '';
  }

  String _key(int j) {
    switch ('${it['type']}') {
      case 'choice':
        final ch = (it['choices'] as List).map((e) => '$e').toList();
        final k = (it['key'] as num).toInt();
        final l = '${it['labels'] ?? 'กขคงจ'}'[k];
        return ch[k] == l || ch.every((c) => c.length <= 1) ? l : '$l. ${ch[k]}';
      case 'number':
        return '${it['key']} ${it['unit'] ?? ''}${(it['tolerance'] ?? 0) != 0 ? ' (± ${it['tolerance']})' : ''}'.trim();
      case 'text':
        return (it['key'] as List? ?? [it['key']]).map((e) => '$e').join(' / ');
      case 'truefalse':
        return ((it['items'] as List)[j] as Map)['answer'] == true ? '✓ ถูก' : '✗ ผิด';
      case 'match':
        final a = (((it['items'] as List)[j] as Map)['answer'] as num).toInt();
        final o = (it['options'] as List)[a] as Map;
        return '${letterOf('${it['letters']}', a)}${'${o['text'] ?? ''}'.isEmpty ? '' : '. ${o['text']}'}';
      case 'cloze':
        return ((it['blanks'] as List)[j] as List).map((e) => '$e').join(' / ');
    }
    return '';
  }

  String? _label(int j) => switch ('${it['type']}') {
        'truefalse' || 'match' => '${j + 1}. ${((it['items'] as List)[j] as Map)['text'] ?? ''}',
        'cloze' => 'ช่อง ${j + 1}',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final parts = (it['parts'] as List? ?? []).cast<Map>();
    final i = (it['index'] as num).toInt();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if ('${it['type']}' == 'cloze')
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(() {
            final seg = (it['segments'] as List).map((e) => '$e').toList();
            final b = StringBuffer();
            for (var k = 0; k < seg.length; k++) {
              b.write(seg[k]);
              if (k < seg.length - 1) b.write('(${k + 1})____');
            }
            return b.toString();
          }(), style: TextStyle(fontSize: 13, color: Colors.grey.shade800)),
        ),
      for (var j = 0; j < parts.length; j++)
        Builder(builder: (context) {
          final key = '$i:$j';
          final auto = parts[j]['auto'] == true;
          final ov = overrides.containsKey(key) ? overrides[key] : (parts[j]['override'] as bool?);
          final good = ov ?? auto;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 2, children: [
              Icon(good ? Icons.check_circle_rounded : Icons.cancel_rounded, color: good ? _ok : Colors.red.shade700, size: 20),
              if (_label(j) != null) Text(_label(j)!, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('ตอบ: ${_given(j)}'),
              if (!auto) Text('• เฉลย ${_key(j)}', style: TextStyle(color: Colors.grey.shade700)),
              SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact, textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12))),
                segments: [
                  ButtonSegment(value: 'auto', label: Text('ระบบตรวจ (${auto ? 'ถูก' : 'ผิด'})')),
                  const ButtonSegment(value: 'yes', label: Text('ให้ถูก')),
                  const ButtonSegment(value: 'no', label: Text('ให้ผิด')),
                ],
                selected: {ov == null ? 'auto' : (ov ? 'yes' : 'no')},
                onSelectionChanged: (s) => onOverride(key, s.first == 'auto' ? null : s.first == 'yes'),
              ),
            ]),
          );
        }),
    ]);
  }
}
