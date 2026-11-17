import 'package:flutter/material.dart';

/// The server's rule (exams.scale_score, owner 17 พ.ย. 2569): earned/total of the points it is worth,
/// 1 decimal place, always rounded up, never above [worth].
double scaleScore(double earned, double total, double worth) {
  if (total <= 0) return 0;
  final x = earned / total * worth;
  final up = ((x * 10 * 1000000).round() / 1000000).ceil() / 10;
  return up > worth ? worth : up;
}

String fmtPoints(num v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);

/// "คิดเป็นกี่คะแนน" of one quiz in its column, with a worked example of the conversion.
class SlotPointsField extends StatelessWidget {
  final TextEditingController controller;
  final double? slotFull;
  final double rawPoints;
  final VoidCallback onChanged;
  const SlotPointsField({super.key, required this.controller, required this.slotFull, required this.rawPoints, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final typed = double.tryParse(controller.text.trim());
    final worth = typed ?? slotFull;
    String example = '';
    if (worth != null && worth > 0 && rawPoints > 0) {
      final got = (rawPoints * 0.7).floorToDouble().clamp(1, rawPoints).toDouble();
      example = 'ข้อสอบ ${fmtPoints(rawPoints)} คะแนนดิบ → คิดเป็น ${fmtPoints(worth)} คะแนน • '
          'เช่น ทำได้ ${fmtPoints(got)} → ${fmtPoints(scaleScore(got, rawPoints, worth))} คะแนน (ทศนิยม 1 ตำแหน่ง ปัดขึ้น)';
    }
    final over = typed != null && slotFull != null && typed > slotFull!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 320,
        child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            labelText: 'คิดเป็นกี่คะแนน (ในช่องนี้)',
            hintText: slotFull == null ? '' : 'ว่าง = แบ่งจากเต็ม ${fmtPoints(slotFull!)}',
            errorText: over ? 'เกินคะแนนเต็มของช่อง (${fmtPoints(slotFull!)})' : null,
            suffixText: 'คะแนน',
          ),
        ),
      ),
      if (example.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(example, style: TextStyle(fontSize: 12, color: Colors.indigo.shade700)),
        ),
    ]);
  }
}
