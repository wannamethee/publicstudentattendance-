import 'package:flutter/material.dart';
import '../utils/app_theme.dart';

/// Students per class level and room, split ชาย / หญิง, with the group total.
/// Used twice on the dashboard: regular classes (`rooms_breakdown`) and the
/// โปรแกรม 3 รูปแบบ group (`program3_breakdown`).
/// Horizontal stacked bars on one shared scale (lengths compare across classes);
/// counts are written next to every bar, so colour is never the only cue.
/// Colours: categorical slots 1-2 of the reference palette, validated (CVD ΔE 24.7, all checks pass).
class EnrollmentChart extends StatelessWidget {
  final List<Map<String, dynamic>> levels;
  final String breakdownKey;
  final String title;
  final String totalLabel;
  final IconData icon;

  const EnrollmentChart({
    super.key,
    required this.levels,
    this.breakdownKey = 'rooms_breakdown',
    this.title = 'จำนวนนักเรียน แยกตามชั้น ห้อง และเพศ',
    this.totalLabel = 'ทั้งโรงเรียน',
    this.icon = Icons.groups_2_rounded,
  });

  static const Color maleColor = Color(0xFF2A78D6);
  static const Color femaleColor = Color(0xFFEB6834);
  static const Color unknownColor = Color(0xFFB4B2AA);
  static const Color _ink = Color(0xFF1F1F1F);
  static const Color _inkMuted = Color(0xFF52514E);

  @override
  Widget build(BuildContext context) {
    final rows = <_RoomRow>[];
    for (final lvl in levels) {
      final rooms = (lvl[breakdownKey] as List?)?.cast<Map>() ?? const [];
      for (final r in rooms) {
        rows.add(_RoomRow(
          level: lvl['class_level']?.toString() ?? '',
          room: r['room']?.toString() ?? '1',
          male: (r['male'] as num?)?.toInt() ?? 0,
          female: (r['female'] as num?)?.toInt() ?? 0,
          total: (r['total'] as num?)?.toInt() ?? 0,
        ));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();

    final totalMale = rows.fold<int>(0, (a, r) => a + r.male);
    final totalFemale = rows.fold<int>(0, (a, r) => a + r.female);
    final total = rows.fold<int>(0, (a, r) => a + r.total);
    final levelCount = rows.map((r) => r.level).toSet().length;
    final maxRoom = rows.fold<int>(1, (a, r) => r.total > a ? r.total : a);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: AppColors.purplePrimary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(title,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _ink)),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _legendDot(maleColor, 'ชาย'),
                  const SizedBox(width: 14),
                  _legendDot(femaleColor, 'หญิง'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Group total: hero number + one share bar
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 14,
            runSpacing: 4,
            children: [
              Text('$total คน', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _ink)),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '$totalLabel • ชาย $totalMale • หญิง $totalFemale • $levelCount ระดับชั้น ${rows.length} ห้อง',
                  style: const TextStyle(fontSize: 13, color: _inkMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _StackedBar(male: totalMale, female: totalFemale, total: total, scaleMax: total, height: 14, tooltipPrefix: totalLabel),
          const SizedBox(height: 16),
          for (final level in rows.map((r) => r.level).toSet()) ...[
            _levelBlock(level, rows.where((r) => r.level == level).toList(), maxRoom),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _levelBlock(String level, List<_RoomRow> rooms, int maxRoom) {
    final levelTotal = rooms.fold<int>(0, (a, r) => a + r.total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$level  •  ${rooms.length} ห้อง  •  $levelTotal คน',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _ink)),
        const SizedBox(height: 4),
        for (final r in rooms)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text('ห้อง ${r.room}', style: const TextStyle(fontSize: 12.5, color: _inkMuted)),
                ),
                Expanded(
                  child: _StackedBar(
                    male: r.male,
                    female: r.female,
                    total: r.total,
                    scaleMax: maxRoom,
                    height: 18,
                    tooltipPrefix: '$level/${r.room}',
                  ),
                ),
                SizedBox(
                  width: 128,
                  child: Text(
                    'ช ${r.male} • ญ ${r.female} • รวม ${r.total}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12.5, color: _ink, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _legendDot(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12.5, color: _ink)),
        ],
      );
}

class _RoomRow {
  final String level;
  final String room;
  final int male;
  final int female;
  final int total;
  const _RoomRow({required this.level, required this.room, required this.male, required this.female, required this.total});
}

/// One horizontal bar: ชาย | หญิง (| ไม่ระบุ) segments, 2px surface gap between them,
/// rounded outer ends, length = total / scaleMax of the available width. Hover/long-press shows counts.
class _StackedBar extends StatelessWidget {
  final int male;
  final int female;
  final int total;
  final int scaleMax;
  final double height;
  final String tooltipPrefix;
  const _StackedBar({
    required this.male,
    required this.female,
    required this.total,
    required this.scaleMax,
    required this.height,
    required this.tooltipPrefix,
  });

  @override
  Widget build(BuildContext context) {
    final unknown = (total - male - female).clamp(0, total);
    final segments = <(int, Color, String)>[
      if (male > 0) (male, EnrollmentChart.maleColor, 'ชาย'),
      if (female > 0) (female, EnrollmentChart.femaleColor, 'หญิง'),
      if (unknown > 0) (unknown, EnrollmentChart.unknownColor, 'ไม่ระบุเพศ'),
    ];
    return LayoutBuilder(builder: (context, c) {
      final full = c.maxWidth - 8;
      final barWidth = scaleMax > 0 ? full * total / scaleMax : 0.0;
      final gaps = (segments.length - 1) * 2.0;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            for (int i = 0; i < segments.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Tooltip(
                message: '$tooltipPrefix ${segments[i].$3} ${segments[i].$1} คน (${(segments[i].$1 * 100 / (total == 0 ? 1 : total)).toStringAsFixed(0)}%)',
                child: Container(
                  width: ((barWidth - gaps) * segments[i].$1 / (total == 0 ? 1 : total)).clamp(2.0, full),
                  height: height,
                  decoration: BoxDecoration(
                    color: segments[i].$2,
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(i == 0 ? 4 : 0),
                      right: Radius.circular(i == segments.length - 1 ? 4 : 0),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    });
  }
}
