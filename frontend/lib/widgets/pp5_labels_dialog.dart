import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// Vertical header labels of a course's ปพ.5 (server: pp5_labels.py).
///
/// sheet 4 (sheet5 == false): ตัวชี้วัด / ผลการเรียนรู้ of score slots 1-8 (C6:J6)
/// sheet 5 (sheet5 == true):  คุณลักษณะอันพึงประสงค์ items 1-8 (C5:J5) and อ่าน คิด วิเคราะห์ เขียน items 1-5 (L5:P5)
///
/// The Excel columns are narrow, so the text is written upwards; a long label makes the header row taller, never
/// the columns wider. Returns the saved labels (group -> texts), or null when nothing was saved.
Future<Map<String, List<String>>?> showPp5LabelsDialog(
  BuildContext context, {
  required ApiService api,
  required String courseCode,
  required String term,
  required String year,
  required bool sheet5,
  String? focusGroup,
  int focusIndex = 0,
  List<dynamic>? unitMax,
}) {
  return showDialog<Map<String, List<String>>>(
    context: context,
    builder: (_) => _Pp5LabelsDialog(
      api: api,
      courseCode: courseCode,
      term: term,
      year: year,
      sheet5: sheet5,
      focusGroup: focusGroup ?? (sheet5 ? 'attributes' : 'indicators'),
      focusIndex: focusIndex,
      unitMax: unitMax,
    ),
  );
}

const Map<String, int> _groupSize = {'indicators': 8, 'attributes': 8, 'reading': 5};

/// Same estimate as pp5_labels.text_height_pt on the server: ~0.38 em per character that takes space
/// (Thai vowel and tone marks above/below take none), plus 6 pt of padding.
double pp5LabelHeightPt(String text, {double fontPt = 14}) {
  var n = 0;
  for (final r in text.runes) {
    final mark = r == 0x0E31 || (r >= 0x0E34 && r <= 0x0E3A) || (r >= 0x0E47 && r <= 0x0E4E);
    if (!mark) n++;
  }
  return n == 0 ? 0 : n * 0.38 * fontPt + 6;
}

class _Pp5LabelsDialog extends StatefulWidget {
  const _Pp5LabelsDialog({
    required this.api,
    required this.courseCode,
    required this.term,
    required this.year,
    required this.sheet5,
    required this.focusGroup,
    required this.focusIndex,
    this.unitMax,
  });

  final ApiService api;
  final String courseCode;
  final String term;
  final String year;
  final bool sheet5;
  final String focusGroup;
  final int focusIndex;
  final List<dynamic>? unitMax;

  @override
  State<_Pp5LabelsDialog> createState() => _Pp5LabelsDialogState();
}

class _Pp5LabelsDialogState extends State<_Pp5LabelsDialog> {
  static const navy = Color(0xFF1A237E);

  bool _loading = true;
  bool _saving = false;
  bool _canEdit = false;
  String? _error;
  int _maxLen = 80;
  List<String> _standardAttributes = const [];
  final Map<String, List<TextEditingController>> _ctl = {};
  final Map<String, List<FocusNode>> _focus = {};

  List<String> get _groups => widget.sheet5 ? const ['attributes', 'reading'] : const ['indicators'];

  @override
  void initState() {
    super.initState();
    for (final g in _groups) {
      _ctl[g] = List.generate(_groupSize[g]!, (_) => TextEditingController()..addListener(_onTyped));
      _focus[g] = List.generate(_groupSize[g]!, (_) => FocusNode());
    }
    _load();
  }

  @override
  void dispose() {
    for (final list in _ctl.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _focus.values) {
      for (final f in list) {
        f.dispose();
      }
    }
    super.dispose();
  }

  void _onTyped() {
    if (mounted) setState(() {}); // the header-height estimate follows the typing
  }

  Future<void> _load() async {
    try {
      final res = await widget.api.getPp5Labels(courseCode: widget.courseCode, term: widget.term, year: widget.year);
      final labels = (res['labels'] as Map?) ?? {};
      for (final g in _groups) {
        final vals = (labels[g] as List?) ?? const [];
        for (var i = 0; i < _ctl[g]!.length; i++) {
          _ctl[g]![i].text = i < vals.length ? (vals[i]?.toString() ?? '') : '';
        }
      }
      if (!mounted) return;
      setState(() {
        _canEdit = res['can_edit'] == true;
        _maxLen = (res['max_len'] as num?)?.toInt() ?? 80;
        _standardAttributes = ((res['standard_attributes'] as List?) ?? const []).map((e) => e.toString()).toList();
        _loading = false;
      });
      final g = _groups.contains(widget.focusGroup) ? widget.focusGroup : _groups.first;
      final i = widget.focusIndex.clamp(0, _groupSize[g]! - 1);
      if (_canEdit) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus[g]![i].requestFocus();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    List<String> vals(String g) => _ctl[g]!.map((c) => c.text.trim()).toList();
    try {
      final res = await widget.api.savePp5Labels(
        courseCode: widget.courseCode,
        term: widget.term,
        year: widget.year,
        indicators: widget.sheet5 ? null : vals('indicators'),
        attributes: widget.sheet5 ? vals('attributes') : null,
        reading: widget.sheet5 ? vals('reading') : null,
      );
      final labels = (res['labels'] as Map?) ?? {};
      final out = <String, List<String>>{
        for (final g in _groupSize.keys) g: ((labels[g] as List?) ?? const []).map((e) => e?.toString() ?? '').toList(),
      };
      if (mounted) Navigator.of(context).pop(out);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  /// Height of the vertical header in the printed sheet, in cm (the template's own height when nothing is long).
  double _headerCm() {
    final base = widget.sheet5 ? 43.5 : 66.75;
    var need = 0.0;
    for (final g in _groups) {
      final texts = _ctl[g]!.map((c) => c.text.trim()).toList();
      final custom = texts.any((t) => t.isNotEmpty);
      for (var i = 0; i < texts.length; i++) {
        final shown = texts[i].isNotEmpty ? texts[i] : (widget.sheet5 && custom ? 'ข้อ ${i + 1}' : '');
        final h = pp5LabelHeightPt(shown);
        if (h > need) need = h;
      }
    }
    return (need > base ? need : base) / 28.35;
  }

  String _maxText(int i) {
    final list = widget.unitMax;
    if (list == null || i >= list.length || list[i] == null) return '';
    final v = list[i];
    final s = v is num ? (v == v.roundToDouble() ? v.toInt().toString() : v.toString()) : v.toString();
    return s.isEmpty ? '' : ' · เต็ม $s';
  }

  Widget _field(String g, int i) {
    final label = g == 'indicators' ? 'ช่อง ${i + 1}${_maxText(i)}' : 'ข้อ ${i + 1}';
    final hint = g == 'indicators' ? 'เช่น ค 1.1 ม.4/1' : (g == 'attributes' ? 'เช่น มีวินัย' : 'เช่น อ่านจับใจความ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: ValueKey('pp5-label-$g-$i'),
        controller: _ctl[g]![i],
        focusNode: _focus[g]![i],
        readOnly: !_canEdit,
        maxLength: _maxLen,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: label,
          hintText: _canEdit ? hint : null,
          isDense: true,
          counterText: '',
          border: const OutlineInputBorder(),
          suffixIcon: _canEdit && _ctl[g]![i].text.isNotEmpty
              ? IconButton(
                  tooltip: 'ล้างช่องนี้',
                  icon: const Icon(Icons.clear_rounded, size: 18),
                  onPressed: () => _ctl[g]![i].clear(),
                )
              : null,
        ),
      ),
    );
  }

  Widget _section(String g) {
    final title = switch (g) {
      'indicators' => 'ตัวชี้วัด / ผลการเรียนรู้ ของช่องคะแนน 1–8',
      'attributes' => 'คุณลักษณะอันพึงประสงค์ (ข้อ 1–8)',
      _ => 'อ่าน คิด วิเคราะห์ และเขียน (ข้อ 1–5)',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: navy)),
              if (g == 'attributes' && _canEdit && _standardAttributes.length == 8)
                TextButton.icon(
                  onPressed: () {
                    for (var i = 0; i < 8; i++) {
                      _ctl[g]![i].text = _standardAttributes[i];
                    }
                  },
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                  label: const Text('ใส่ชื่อมาตรฐาน 8 ข้อ'),
                ),
            ],
          ),
        ),
        for (var i = 0; i < _groupSize[g]!; i++) _field(g, i),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cm = _headerCm();
    final baseCm = (widget.sheet5 ? 43.5 : 66.75) / 28.35;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      title: Row(
        children: [
          const Icon(Icons.text_rotate_up_rounded, color: navy),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.sheet5 ? 'หัวข้อคุณลักษณะ (ปพ.5 แผ่นที่ 5)' : 'ตัวชี้วัด (ปพ.5 แผ่นที่ 4)',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: navy),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${widget.courseCode} • ภาคเรียนที่ ${widget.term}/${widget.year}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF8E1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFFE082)),
                      ),
                      child: Text(
                        '${_canEdit ? 'ข้อความจะเขียนเป็นแนวตั้ง (อ่านจากล่างขึ้นบน) ในไฟล์ Excel และ PDF ช่องไม่กว้างขึ้น '
                            'ถ้าข้อความยาว หัวตารางจะสูงขึ้นแทน' : 'ดูได้อย่างเดียว: แก้ได้เฉพาะครูผู้สอนวิชานี้และผู้ดูแลระบบ'}'
                        '\nหัวตารางสูงประมาณ ${cm.toStringAsFixed(1)} ซม.'
                        '${cm > baseCm + 0.05 ? ' (เดิม ${baseCm.toStringAsFixed(1)} ซม.)' : ''}',
                        style: const TextStyle(fontSize: 12.5, height: 1.4),
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final g in _groups) _section(g),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(_error!, style: const TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(_canEdit ? 'ยกเลิก' : 'ปิด'),
        ),
        if (_canEdit)
          FilledButton.icon(
            onPressed: _saving || _loading ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_rounded, size: 18),
            label: const Text('บันทึกลง ปพ.5'),
          ),
      ],
    );
  }
}
