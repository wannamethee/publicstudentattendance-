import 'dart:math' as math;

import 'package:flutter/material.dart';

/// สัญลักษณ์ในตารางลงเวลาครู (สีเดียวกับตารางเช็คชื่อนักเรียน: ส สีน้ำเงิน, ล สีส้ม)
class TeacherMark {
  static const order = ['/', 'ส', 'ขส', 'ล', 'ร'];
  static const label = {'/': 'มา', 'ส': 'มาสาย', 'ขส': 'ขอเข้าสาย', 'ล': 'ลา', 'ร': 'ไปราชการ'};

  /// คีย์ในสรุปจากเซิร์ฟเวอร์ (summary / weekly / monthly)
  static const summaryKey = {'ส': 'late', 'ขส': 'late_request', 'ล': 'leave', 'ร': 'official'};

  static Color color(String s) {
    switch (s) {
      case '/':
        return const Color(0xFF15803D);
      case 'ส':
        return const Color(0xFF1D4ED8);
      case 'ขส':
        return const Color(0xFF6D28D9);
      case 'ล':
        return const Color(0xFFC2410C);
      case 'ร':
        return const Color(0xFF0F766E);
      default:
        return const Color(0xFF64748B);
    }
  }

  /// สีพื้นช่องในตาราง ("/" ใช้พื้นขาว)
  static Color fill(String s) {
    switch (s) {
      case 'ส':
        return const Color(0xFFEFF6FF);
      case 'ขส':
        return const Color(0xFFF5F3FF);
      case 'ล':
        return const Color(0xFFFFF7ED);
      case 'ร':
        return const Color(0xFFF0FDFA);
      default:
        return Colors.white;
    }
  }

  /// สีพื้นของป้ายสัญลักษณ์ (มีสีเขียวอ่อนสำหรับ "/")
  static Color soft(String s) => s == '/' ? const Color(0xFFF0FDF4) : fill(s);

  static Color border(String s) {
    switch (s) {
      case '/':
        return const Color(0xFFBBF7D0);
      case 'ส':
        return const Color(0xFFBFDBFE);
      case 'ขส':
        return const Color(0xFFDDD6FE);
      case 'ล':
        return const Color(0xFFFED7AA);
      case 'ร':
        return const Color(0xFF99F6E4);
      default:
        return const Color(0xFFE2E8F0);
    }
  }
}

const dayShortThai = ['จ', 'อ', 'พ', 'พฤ', 'ศ'];
const dayFullThai = ['จันทร์', 'อังคาร', 'พุธ', 'พฤหัสบดี', 'ศุกร์'];
const monthShortThai = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];
const monthFullThai = ['', 'มกราคม', 'กุมภาพันธ์', 'มีนาคม', 'เมษายน', 'พฤษภาคม', 'มิถุนายน', 'กรกฎาคม', 'สิงหาคม', 'กันยายน', 'ตุลาคม', 'พฤศจิกายน', 'ธันวาคม'];

const _ink = Color(0xFF0F172A);
const _muted = Color(0xFF64748B);
const _line = Color(0xFFE2E8F0);
const _lineSoft = Color(0xFFEEF2F6);
const _lineStrong = Color(0xFFCBD5E1);
const _headBg = Color(0xFFF8FAFC);
const _holidayBg = Color(0xFFE2E8F0);
const _todayHead = Color(0xFFFDE68A);
const _todayAmber = Color(0xFFF59E0B);
const _accent = Color(0xFF3B2580);

/// "17 พ.ย. 69"
String thaiShortDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${d.day} ${monthShortThai[d.month]} ${(d.year + 543) % 100}';
}

int _n(Map<String, dynamic> s, String k) => (s[k] as num?)?.toInt() ?? 0;

/// ช่วงที่ดูอยู่: รายสัปดาห์ (week) / รายเดือน (month) / ทั้งภาคเรียน (term)
/// ข้อมูลช่วงมาจาก GET /api/v1/leaves/attendance-grid (weeks, months และ weekly / monthly ของครูแต่ละคน)
class TeacherPeriod {
  final String kind;
  final int index;
  final int first;
  final int last;
  final String title;
  final String sub;
  final String printLabel;
  final int schoolDays;
  final int elapsed;

  const TeacherPeriod._(this.kind, this.index, this.first, this.last, this.title, this.sub, this.printLabel, this.schoolDays, this.elapsed);

  static List<Map<String, dynamic>> items(Map<String, dynamic> g, String kind) =>
      ((g[kind == 'week' ? 'weeks' : 'months'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  static int count(Map<String, dynamic> g, String kind) => kind == 'term' ? 1 : items(g, kind).length;

  /// ช่วงที่มีวันนี้ (ก่อนเปิดภาค = ช่วงแรก, หลังปิดภาค = ช่วงสุดท้าย)
  static int todayIndex(Map<String, dynamic> g, String kind) {
    if (kind == 'term') return 0;
    final list = items(g, kind);
    if (list.isEmpty) return 0;
    final t = g['today_slot'];
    if (t is int) {
      for (var k = 0; k < list.length; k++) {
        if ((list[k]['first_slot'] as int) <= t && t <= (list[k]['last_slot'] as int)) return k;
      }
    }
    final today = g['today']?.toString() ?? '';
    return today.compareTo(list.last['end'].toString()) > 0 ? list.length - 1 : 0;
  }

  static TeacherPeriod of(Map<String, dynamic> g, String kind, int index) {
    final dates = ((g['dates'] as List?) ?? const []).map((e) => e.toString()).toList();
    final holidays = ((g['holidays'] as List?) ?? const []).map((e) => e as int).toSet();
    if (kind == 'term' || dates.isEmpty) {
      final school = [for (var i = 0; i < dates.length; i++) if (!holidays.contains(i)) i].length;
      final elapsed = (g['school_days'] as num?)?.toInt() ?? 0;
      var sub = dates.isEmpty ? '' : '${thaiShortDate(dates.first)} – ${thaiShortDate(dates.last)} • วันเรียน $school วัน';
      sub += elapsed == 0 ? ' • ยังไม่ถึง' : (elapsed < school ? ' • ผ่านมาแล้ว $elapsed วัน' : '');
      return TeacherPeriod._('term', 0, 0, math.max(0, dates.length - 1), 'ภาคเรียนที่ ${g['term']}/${g['year']}', sub,
          'พิมพ์สรุปทั้งภาคเรียน', school, elapsed);
    }
    final list = items(g, kind);
    final k = index.clamp(0, list.length - 1);
    final p = list[k];
    final first = p['first_slot'] as int;
    final last = p['last_slot'] as int;
    final school = (p['school_days'] as num).toInt();
    final elapsed = (p['elapsed'] as num).toInt();
    String title;
    String sub;
    String printLabel;
    if (kind == 'week') {
      final a = DateTime.parse(p['start'].toString());
      final b = DateTime.parse(p['end'].toString());
      title = 'สัปดาห์ที่ ${k + 1}';
      sub = '${a.month == b.month ? '${a.day}' : '${a.day} ${monthShortThai[a.month]} '}–${b.day} ${monthShortThai[b.month]} ${(b.year + 543) % 100}';
      printLabel = 'พิมพ์สรุปสัปดาห์ที่ ${k + 1}';
    } else {
      final m = (p['month'] as num).toInt();
      final y = (p['year'] as num).toInt();
      title = '${monthFullThai[m]} ${y + 543}';
      sub = 'วันเรียน $school วัน';
      printLabel = 'พิมพ์สรุปเดือน${monthFullThai[m]}';
    }
    final off = (last - first + 1) - school;
    if (off > 0) sub += ' • หยุด $off วัน';
    sub += elapsed == 0 ? ' • ยังไม่ถึง' : (elapsed < school ? ' • ผ่านมาแล้ว $elapsed วัน' : '');
    return TeacherPeriod._(kind, k, first, last, title, sub, printLabel, school, elapsed);
  }

  /// สรุปของครูหนึ่งคนในช่วงนี้ (นับเฉพาะวันเรียนที่ผ่านมาแล้ว)
  Map<String, dynamic> summaryOf(Map<String, dynamic> row) {
    if (kind == 'term') return Map<String, dynamic>.from((row['summary'] as Map?) ?? const {});
    final list = row[kind == 'week' ? 'weekly' : 'monthly'] as List?;
    if (list == null || index >= list.length) return const {};
    return Map<String, dynamic>.from(list[index] as Map);
  }

  List<int> get slots => [for (var i = first; i <= last; i++) i];
}

/// ป้ายสัญลักษณ์เล็ก ๆ (/ ส ขส ล ร)
class TeacherMarkBadge extends StatelessWidget {
  final String sym;
  final double size;
  const TeacherMarkBadge(this.sym, {super.key, this.size = 12.5});

  @override
  Widget build(BuildContext context) => Container(
        constraints: BoxConstraints(minWidth: size * 2.1),
        height: size * 1.75,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: TeacherMark.soft(sym),
          border: Border.all(color: TeacherMark.border(sym)),
          borderRadius: BorderRadius.circular(6),
        ),
        // widthFactor 1: the badge is as wide as its text (an alignment would stretch it across a table cell)
        child: Center(
          widthFactor: 1,
          child: Text(sym, style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: TeacherMark.color(sym), height: 1.1)),
        ),
      );
}

class PeriodTile {
  final String sym;
  final String label;
  final String value;
  final String unit;
  final String sub;
  final double? bar; // 0..100
  const PeriodTile(this.sym, this.label, this.value, this.unit, this.sub, {this.bar});

  /// กล่องตัวเลขของครูทุกคนในช่วงที่เลือก (หน้าบันทึกการลาและแดชบอร์ดใช้ชุดเดียวกัน จึงตรงกันเสมอ)
  static List<PeriodTile> forAll(List<Map<String, dynamic>> rows, TeacherPeriod period) {
    final reached = period.elapsed > 0;
    final sums = rows.map(period.summaryOf).toList();
    int sum(String k) => sums.fold(0, (a, s) => a + _n(s, k));
    int who(String k) => sums.where((s) => _n(s, k) > 0).length;
    final personDays = sum('school_days');
    final present = sum('present');
    final rate = personDays == 0 ? 0.0 : present * 100 / personDays;
    PeriodTile tc(String sym, String key, String unit, [String extra = '']) {
      final v = sum(key);
      return PeriodTile(sym, TeacherMark.label[sym]!, reached ? '$v' : '–', reached ? unit : '',
          !reached ? 'ยังไม่ถึงช่วงนี้' : (v == 0 ? 'ไม่มีในช่วงนี้' : '${who(key)} คน$extra'));
    }

    return [
      PeriodTile('/', 'มาปฏิบัติงาน', reached && personDays > 0 ? rate.toStringAsFixed(1) : '–', reached ? '%' : '',
          reached ? 'มา $present จาก $personDays (${period.elapsed} วัน × ${rows.length} คน)' : 'ยังไม่ถึงช่วงนี้',
          bar: reached && personDays > 0 ? rate : null),
      tc('ส', 'late', 'ครั้ง'),
      tc('ขส', 'late_request', 'ครั้ง'),
      tc('ล', 'leave', 'วัน', ' • ลาป่วย ${sum('leave_puay')} • ลากิจ ${sum('leave_kij')}'),
      tc('ร', 'official', 'วัน'),
    ];
  }
}

/// กล่องตัวเลขสรุปของช่วงที่เลือก (5 กล่อง; จอแคบ กล่องแรกเต็มแถว ที่เหลือ 2 คอลัมน์)
class PeriodTiles extends StatelessWidget {
  final List<PeriodTile> tiles;
  const PeriodTiles({super.key, required this.tiles});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 10.0;
      if (c.maxWidth < 560 && tiles.length > 1) {
        // มือถือ: กล่องแรกเต็มแถว ที่เหลือเป็นตัวนับเล็ก ๆ แถวเดียว
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _tile(tiles.first),
          const SizedBox(height: 8),
          Row(children: [
            for (var i = 1; i < tiles.length; i++) ...[
              if (i > 1) const SizedBox(width: 8),
              Expanded(child: _counter(tiles[i])),
            ],
          ]),
        ]);
      }
      final cols = c.maxWidth >= 900 ? tiles.length : 3;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final t in tiles) SizedBox(width: w - 0.01, child: _tile(t)),
      ]);
    });
  }

  Widget _counter(PeriodTile t) {
    final on = t.value != '0' && t.value != '–';
    return Tooltip(
      message: '${t.label} ${t.value} ${t.unit} • ${t.sub}',
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        decoration: BoxDecoration(
          color: on ? TeacherMark.fill(t.sym) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? TeacherMark.border(t.sym) : _line),
        ),
        child: Column(children: [
          Text(t.sym, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: TeacherMark.color(t.sym))),
          Text(t.value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.15, color: on ? _ink : const Color(0xFF94A3B8))),
          Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
        ]),
      ),
    );
  }

  Widget _tile(PeriodTile t) {
    final dim = t.value == '0' || t.value == '–';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          TeacherMarkBadge(t.sym),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t.label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
          ),
        ]),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(t.value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.15, color: dim ? const Color(0xFF94A3B8) : _ink)),
          const SizedBox(width: 6),
          Text(t.unit, style: const TextStyle(fontSize: 13.5, color: _muted)),
        ]),
        if (t.bar != null) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (t.bar! / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: _line,
              color: TeacherMark.color('/'),
            ),
          ),
        ],
        const SizedBox(height: 4),
        Text(t.sub, style: const TextStyle(fontSize: 12.5, color: _muted)),
      ]),
    );
  }
}

/// ตารางลงเวลาครูตามช่วง (ผู้ที่เห็นครูทุกคน): ชื่อครูตรึงซ้าย • กลาง = วันในสัปดาห์ / วันในเดือน / เดือนในภาคเรียน
/// • ขวา = ยอดรวมของช่วงนั้น (จอกว้างตรึงไว้ จอแคบเลื่อนตามไป) แตะหัวยอดรวมเพื่อเรียง
class TeacherPeriodTable extends StatefulWidget {
  final Map<String, dynamic> data;
  final TeacherPeriod period;
  final String sortKey; // '' | 'มา' | 'ส' | 'ขส' | 'ล' | 'ร'
  final void Function(String key)? onSort;
  final void Function(Map<String, dynamic> row, int slot)? onCellTap;
  final void Function(Map<String, dynamic> row)? onNameTap;
  final void Function(int week)? onWeekTap;
  final void Function(int month)? onMonthTap;

  const TeacherPeriodTable({
    super.key,
    required this.data,
    required this.period,
    this.sortKey = '',
    this.onSort,
    this.onCellTap,
    this.onNameTap,
    this.onWeekTap,
    this.onMonthTap,
  });

  @override
  State<TeacherPeriodTable> createState() => _TeacherPeriodTableState();
}

class _TeacherPeriodTableState extends State<TeacherPeriodTable> {
  static const double _rowH = 44;
  static const double _headH = 64;
  final _hScroll = ScrollController();
  double _cellW = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToToday());
  }

  @override
  void didUpdateWidget(covariant TeacherPeriodTable old) {
    super.didUpdateWidget(old);
    if (old.period.kind != widget.period.kind || old.period.index != widget.period.index) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToToday());
    }
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  void _scrollToToday() {
    if (!_hScroll.hasClients) return;
    final p = widget.period;
    final today = widget.data['today_slot'];
    var target = 0.0;
    if (p.kind != 'term' && today is int && today >= p.first && today <= p.last) {
      target = math.max(0, today - p.first - 2) * _cellW;
    }
    _hScroll.jumpTo(target.clamp(0, _hScroll.position.maxScrollExtent).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.data;
    final p = widget.period;
    final dates = ((g['dates'] as List?) ?? const []).map((e) => e.toString()).toList();
    final holidays = ((g['holidays'] as List?) ?? const []).map((e) => e as int).toSet();
    final todaySlot = g['today_slot'] as int?;
    final months = TeacherPeriod.items(g, 'month');
    final todayMonth = TeacherPeriod.todayIndex(g, 'month');
    final isTerm = p.kind == 'term';
    final isWeek = p.kind == 'week';
    final slots = isTerm ? <int>[] : p.slots;

    final order = <String, int>{};
    var rows = ((g['teachers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    for (var i = 0; i < rows.length; i++) {
      order[rows[i]['teacher_code'].toString()] = i;
    }
    final sums = {for (final r in rows) r['teacher_code'].toString(): p.summaryOf(r)};
    if (widget.sortKey.isNotEmpty) {
      rows = [...rows]..sort((a, b) {
          final sa = sums[a['teacher_code'].toString()]!;
          final sb = sums[b['teacher_code'].toString()]!;
          final d = widget.sortKey == 'มา'
              ? _n(sa, 'present') - _n(sb, 'present')
              : _n(sb, TeacherMark.summaryKey[widget.sortKey]!) - _n(sa, TeacherMark.summaryKey[widget.sortKey]!);
          return d != 0 ? d : order[a['teacher_code'].toString()]! - order[b['teacher_code'].toString()]!;
        });
    }

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 720;
      final nameW = wide ? 200.0 : 116.0;
      final totW = wide ? 62.0 : 48.0;
      final avail = c.maxWidth - nameW - (wide ? totW * 5 : 0) - 2;
      double cellW;
      if (isWeek) {
        cellW = math.max(48, avail / 5);
      } else if (isTerm) {
        cellW = math.max(92, avail / math.max(1, months.length));
      } else {
        cellW = (avail / math.max(1, slots.length)).clamp(30, 44).toDouble();
      }
      _cellW = cellW;

      // ---------- ยอดรวมของช่วง ----------
      Widget totalsHead() => Row(children: [
            for (final d in const [['มา', '/'], ['ส', 'ส'], ['ขส', 'ขส'], ['ล', 'ล'], ['ร', 'ร']])
              InkWell(
                onTap: widget.onSort == null ? null : () => widget.onSort!(d[0]),
                child: Tooltip(
                  message: d[0] == 'มา' ? 'เรียงคนที่มาน้อยที่สุดขึ้นก่อน' : 'เรียงคนที่${TeacherMark.label[d[1]]}มากที่สุดขึ้นก่อน',
                  child: Container(
                    width: totW,
                    height: _headH,
                    color: widget.sortKey == d[0] ? const Color(0xFFEDE9FE) : _headBg,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      TeacherMarkBadge(d[1], size: 11.5),
                      const SizedBox(height: 3),
                      Text(
                        '${wide ? TeacherMark.label[d[1]] : (d[0] == 'มา' ? 'มา' : d[1])}${widget.sortKey == d[0] ? (d[0] == 'มา' ? ' ▴' : ' ▾') : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                      ),
                    ]),
                  ),
                ),
              ),
          ]);

      Widget totalsRow(Map<String, dynamic> s) {
        final days = _n(s, 'school_days');
        Widget cell(String text, {bool strong = false, Color? bg, Color? color}) => Container(
              width: totW,
              height: _rowH,
              alignment: Alignment.center,
              color: bg ?? Colors.white,
              child: Text(text,
                  style: TextStyle(fontSize: strong ? 15 : 14, fontWeight: strong ? FontWeight.w800 : FontWeight.w600, color: color ?? _ink)),
            );
        return Row(children: [
          cell(days == 0 ? '–' : '${_n(s, 'present')}/$days', color: days == 0 ? _lineStrong : _ink),
          for (final sym in const ['ส', 'ขส', 'ล', 'ร'])
            Builder(builder: (_) {
              final v = _n(s, TeacherMark.summaryKey[sym]!);
              return cell(v > 0 ? '$v' : '–', strong: v > 0, bg: v > 0 ? TeacherMark.fill(sym) : null, color: v > 0 ? _ink : _lineStrong);
            }),
        ]);
      }

      // ---------- หัวตารางช่วงกลาง ----------
      Widget dayHead(int i, double h, {bool big = false}) {
        final d = DateTime.tryParse(dates[i]);
        final isToday = i == todaySlot;
        final hol = holidays.contains(i);
        return Container(
          width: cellW,
          height: h,
          decoration: BoxDecoration(
            color: isToday ? _todayHead : (hol ? _holidayBg : _headBg),
            border: Border(right: BorderSide(color: i % 5 == 4 ? _lineStrong : _line)),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(big && cellW >= 70 ? dayFullThai[i % 5] : dayShortThai[i % 5],
                style: TextStyle(fontSize: big ? 13.5 : 10.5, fontWeight: FontWeight.bold, color: const Color(0xFF334155), height: 1.2)),
            Text(
                big && d != null
                    ? '${isToday ? 'วันนี้ ' : (hol ? 'หยุด ' : '')}${d.day} ${monthShortThai[d.month]}'
                    : '${d?.day ?? ''}',
                maxLines: 1,
                style: TextStyle(
                    fontSize: big ? 12.5 : 11.5,
                    fontWeight: big && (isToday || hol) ? FontWeight.bold : FontWeight.normal,
                    color: big && isToday ? const Color(0xFF92400E) : const Color(0xFF475569),
                    height: 1.2)),
          ]),
        );
      }

      Widget middleHead() {
        if (isWeek) return Row(children: [for (final i in slots) dayHead(i, _headH, big: true)]);
        if (isTerm) {
          return Row(children: [
            for (var k = 0; k < months.length; k++)
              InkWell(
                onTap: widget.onMonthTap == null ? null : () => widget.onMonthTap!(k),
                child: Container(
                  width: cellW,
                  height: _headH,
                  decoration: BoxDecoration(
                    color: k == todayMonth ? const Color(0xFFFEF3C7) : _headBg,
                    border: const Border(right: BorderSide(color: _line)),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('${monthShortThai[(months[k]['month'] as num).toInt()]} ${((months[k]['year'] as num).toInt() + 543) % 100}',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
                    Text(_monthHeadSub(months[k]), style: const TextStyle(fontSize: 11.5, color: _muted)),
                  ]),
                ),
              ),
          ]);
        }
        // รายเดือน: แถบสัปดาห์ (แตะเพื่อดูสัปดาห์นั้น) + วัน
        final groups = <List<int>>[];
        for (final i in slots) {
          if (groups.isNotEmpty && groups.last.first ~/ 5 == i ~/ 5) {
            groups.last.add(i);
          } else {
            groups.add([i]);
          }
        }
        return Column(children: [
          Row(children: [
            for (final gr in groups)
              InkWell(
                onTap: widget.onWeekTap == null ? null : () => widget.onWeekTap!(gr.first ~/ 5),
                child: Tooltip(
                  message: 'ดูสัปดาห์ที่ ${gr.first ~/ 5 + 1}',
                  child: Container(
                    width: cellW * gr.length,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF1EEFB),
                      border: Border(right: BorderSide(color: _lineStrong), bottom: BorderSide(color: _line)),
                    ),
                    child: Text(gr.length >= 3 ? 'สัปดาห์ที่ ${gr.first ~/ 5 + 1}' : '${gr.first ~/ 5 + 1}',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: _accent)),
                  ),
                ),
              ),
          ]),
          Row(children: [for (final i in slots) dayHead(i, _headH - 24)]),
        ]);
      }

      // ---------- ช่องข้อมูล ----------
      Widget dayCell(Map<String, dynamic> row, int i) {
        final status = ((row['status_list'] as List?) ?? const [])[i]?.toString() ?? '';
        final info = ((row['info'] as List?) ?? const [])[i];
        final hol = holidays.contains(i);
        final isToday = i == todaySlot;
        final pending = info is Map && info['approval'] == 'pending';
        final tip = hol
            ? 'วันหยุด'
            : '${row['teacher_name']} • วัน${dayFullThai[i % 5]} ${thaiShortDate(dates[i])}'
                '${status.isEmpty ? '' : ' • ${info is Map ? info['leave_type'] : TeacherMark.label[status] ?? status}'}'
                '${info is Map && (info['time'] ?? '').toString().isNotEmpty ? ' (ถึง ${info['time']} น.)' : ''}'
                '${pending ? ' • รออนุมัติ' : ''}';
        final cell = Container(
          width: cellW,
          height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hol ? _holidayBg : (status.isNotEmpty && status != '/' ? TeacherMark.fill(status) : (isToday ? const Color(0xFFFFFBEB) : Colors.white)),
            border: Border(
              right: BorderSide(color: isToday ? _todayAmber : (i % 5 == 4 ? _lineStrong : _lineSoft), width: isToday ? 1.5 : 1),
              left: isToday ? const BorderSide(color: _todayAmber, width: 1.5) : BorderSide.none,
            ),
          ),
          child: status.isEmpty
              ? null
              : Text(
                  status,
                  style: TextStyle(
                    fontSize: status.length > 1 ? (isWeek ? 15 : 12) : (isWeek ? 19 : 15),
                    fontWeight: FontWeight.w800,
                    color: TeacherMark.color(status),
                    decoration: pending ? TextDecoration.underline : null,
                    decorationStyle: TextDecorationStyle.dotted,
                  ),
                ),
        );
        return Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 400),
          child: InkWell(onTap: hol || widget.onCellTap == null ? null : () => widget.onCellTap!(row, i), child: cell),
        );
      }

      Widget monthCell(Map<String, dynamic> row, int k) {
        final m = months[k];
        final list = (row['monthly'] as List?) ?? const [];
        final s = k < list.length ? Map<String, dynamic>.from(list[k] as Map) : <String, dynamic>{};
        final reached = (m['elapsed'] as num? ?? 0) > 0;
        final pills = [
          for (final sym in const ['ส', 'ขส', 'ล', 'ร'])
            if (_n(s, TeacherMark.summaryKey[sym]!) > 0) sym,
        ];
        Widget content;
        if (!reached) {
          content = const Text('ยังไม่ถึง', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)));
        } else if (pills.isEmpty) {
          content = Icon(Icons.check_rounded, size: 20, color: TeacherMark.color('/'), semanticLabel: 'มาตรงเวลาทุกวัน');
        } else {
          content = Wrap(spacing: 3, runSpacing: 2, alignment: WrapAlignment.center, children: [
            for (final sym in pills) _countPill(sym, _n(s, TeacherMark.summaryKey[sym]!)),
          ]);
        }
        return InkWell(
          onTap: widget.onMonthTap == null ? null : () => widget.onMonthTap!(k),
          child: Tooltip(
            message: reached ? '${row['teacher_name']} • ${monthShortThai[(m['month'] as num).toInt()]} มา ${_n(s, 'present')}/${_n(s, 'school_days')} วัน' : 'ยังไม่ถึง',
            child: Container(
              width: cellW,
              height: _rowH,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: k == todayMonth ? const Color(0xFFFFFDF5) : Colors.white,
                border: const Border(right: BorderSide(color: _line)),
              ),
              child: content,
            ),
          ),
        );
      }

      Widget nameCell(Map<String, dynamic> row) {
        final name = row['teacher_name']?.toString() ?? '';
        final no = (order[row['teacher_code'].toString()] ?? 0) + 1;
        return InkWell(
          onTap: widget.onNameTap == null ? null : () => widget.onNameTap!(row),
          child: Container(
            height: _rowH,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _lineSoft), right: BorderSide(color: _line))),
            child: Row(children: [
              if (wide) SizedBox(width: 24, child: Text('$no', style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)))),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: wide ? 14 : 12.5,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                    decoration: widget.onNameTap == null ? null : TextDecoration.underline,
                    decorationColor: _lineStrong,
                  ),
                ),
              ),
            ]),
          ),
        );
      }

      Widget middleRow(Map<String, dynamic> row) => Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _lineSoft))),
            child: Row(children: [
              if (isTerm)
                for (var k = 0; k < months.length; k++) monthCell(row, k)
              else
                for (final i in slots) dayCell(row, i),
              if (!wide) totalsRow(sums[row['teacher_code'].toString()]!),
            ]),
          );

      return Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _lineStrong)),
        clipBehavior: Clip.antiAlias,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: nameW,
            child: Column(children: [
              Container(
                height: _headH,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: const BoxDecoration(color: _headBg, border: Border(bottom: BorderSide(color: _lineStrong), right: BorderSide(color: _line))),
                child: const Text('ชื่อครู', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
              ),
              for (final r in rows) nameCell(r),
            ]),
          ),
          Expanded(
            child: Scrollbar(
              controller: _hScroll,
              thumbVisibility: !wide || !isWeek,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _lineStrong))),
                    child: Row(children: [middleHead(), if (!wide) totalsHead()]),
                  ),
                  for (final r in rows) middleRow(r),
                  const SizedBox(height: 8),
                ]),
              ),
            ),
          ),
          if (wide)
            Container(
              decoration: const BoxDecoration(border: Border(left: BorderSide(color: _lineStrong))),
              child: Column(children: [
                Container(decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _lineStrong))), child: totalsHead()),
                for (final r in rows)
                  Container(
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _lineSoft))),
                    child: totalsRow(sums[r['teacher_code'].toString()]!),
                  ),
              ]),
            ),
        ]),
      );
    });
  }
}

String _monthHeadSub(Map<String, dynamic> m) {
  final school = (m['school_days'] as num? ?? 0).toInt();
  final el = (m['elapsed'] as num? ?? 0).toInt();
  if (el == 0) return 'ยังไม่ถึง';
  if (el < school) return 'ผ่านมา $el/$school วัน';
  return '$school วันเรียน';
}

Widget _countPill(String sym, int n) => Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: TeacherMark.fill(sym),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: TeacherMark.border(sym)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(sym, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: TeacherMark.color(sym))),
        const SizedBox(width: 2),
        Text('$n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink)),
      ]),
    );

/// มุมมองของครูหนึ่งคน (ครูทั่วไปเห็นเฉพาะของตัวเอง): สัปดาห์ = 5 ช่องใหญ่ • เดือน = ปฏิทิน • ทั้งภาค = รายเดือน
/// ตามด้วยรายการ ส ขส ล ร ในช่วงนั้น
class TeacherMyPeriodView extends StatelessWidget {
  final Map<String, dynamic> data;
  final TeacherPeriod period;
  final Map<String, dynamic> row;
  final void Function(int slot)? onCellTap;
  final void Function(int month)? onMonthTap;

  const TeacherMyPeriodView({super.key, required this.data, required this.period, required this.row, this.onCellTap, this.onMonthTap});

  @override
  Widget build(BuildContext context) {
    final dates = ((data['dates'] as List?) ?? const []).map((e) => e.toString()).toList();
    final holidays = ((data['holidays'] as List?) ?? const []).map((e) => e as int).toSet();
    final todaySlot = data['today_slot'] as int?;
    final today = data['today']?.toString() ?? '';
    final status = ((row['status_list'] as List?) ?? const []).map((e) => (e ?? '').toString()).toList();
    final info = (row['info'] as List?) ?? const [];

    Widget dayTile(int i, {required bool big}) {
      final s = i < status.length ? status[i] : '';
      final hol = holidays.contains(i);
      final isToday = i == todaySlot;
      final marked = s.isNotEmpty && s != '/' && !hol;
      final inf = i < info.length ? info[i] : null;
      final pending = inf is Map && inf['approval'] == 'pending';
      final d = DateTime.tryParse(dates[i]);
      final symText = hol ? 'หยุด' : s;
      final symStyle = TextStyle(
        fontSize: hol ? 11 : (s.length > 1 ? (big ? 17 : 13) : (big ? 24 : 18)),
        fontWeight: hol ? FontWeight.w600 : FontWeight.w800,
        color: hol ? _muted : TeacherMark.color(s),
        decoration: pending ? TextDecoration.underline : null,
        decorationStyle: TextDecorationStyle.dotted,
      );
      final box = Container(
        height: big ? 86 : 54,
        decoration: BoxDecoration(
          color: hol ? _holidayBg : (marked ? TeacherMark.fill(s) : (isToday ? const Color(0xFFFFFBEB) : Colors.white)),
          borderRadius: BorderRadius.circular(big ? 12 : 10),
          border: Border.all(color: isToday ? _todayAmber : (marked ? TeacherMark.border(s) : _line), width: isToday ? 2 : 1),
        ),
        child: big
            ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(dayShortThai[i % 5], style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                Text(d == null ? '' : '${d.day} ${monthShortThai[d.month]}', style: const TextStyle(fontSize: 11.5, color: _muted)),
                SizedBox(height: 30, child: Center(child: Text(symText, style: symStyle))),
              ])
            : Stack(children: [
                Positioned(top: 3, left: 7, child: Text('${d?.day ?? ''}', style: const TextStyle(fontSize: 11, color: _muted))),
                Padding(padding: const EdgeInsets.only(top: 8), child: Center(child: Text(symText, style: symStyle))),
              ]),
      );
      return Tooltip(
        message: hol ? 'วันหยุด' : 'วัน${dayFullThai[i % 5]} ${thaiShortDate(dates[i])}${s.isEmpty ? '' : ' • ${TeacherMark.label[s]}'}',
        child: InkWell(borderRadius: BorderRadius.circular(12), onTap: hol || onCellTap == null ? null : () => onCellTap!(i), child: box),
      );
    }

    Widget body;
    if (period.kind == 'week') {
      body = Row(children: [
        for (final i in period.slots) ...[
          if (i != period.first) const SizedBox(width: 6),
          Expanded(child: dayTile(i, big: true)),
        ],
      ]);
    } else if (period.kind == 'month') {
      final weeks = <int>[];
      for (final i in period.slots) {
        if (!weeks.contains(i ~/ 5)) weeks.add(i ~/ 5);
      }
      body = Column(children: [
        Row(children: [
          for (var d = 0; d < 5; d++)
            Expanded(
                child: Text(dayShortThai[d],
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _muted))),
        ]),
        const SizedBox(height: 4),
        for (final w in weeks)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              for (var d = 0; d < 5; d++) ...[
                if (d > 0) const SizedBox(width: 4),
                Expanded(
                  child: (w * 5 + d) < period.first || (w * 5 + d) > period.last
                      ? Container(
                          height: 54,
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: _lineSoft)),
                        )
                      : dayTile(w * 5 + d, big: false),
                ),
              ],
            ]),
          ),
      ]);
    } else {
      final months = TeacherPeriod.items(data, 'month');
      final todayMonth = TeacherPeriod.todayIndex(data, 'month');
      final monthly = (row['monthly'] as List?) ?? const [];
      body = Column(children: [
        for (var k = 0; k < months.length; k++)
          Builder(builder: (_) {
            final m = months[k];
            final s = k < monthly.length ? Map<String, dynamic>.from(monthly[k] as Map) : <String, dynamic>{};
            final reached = (m['elapsed'] as num? ?? 0) > 0;
            final pills = [
              for (final sym in const ['ส', 'ขส', 'ล', 'ร'])
                if (_n(s, TeacherMark.summaryKey[sym]!) > 0) sym,
            ];
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onMonthTap == null ? null : () => onMonthTap!(k),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 50),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: reached ? Colors.white : _headBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: k == todayMonth ? const Color(0xFFFCD34D) : _line),
                  ),
                  child: Row(children: [
                    SizedBox(
                      width: 66,
                      child: Text('${monthShortThai[(m['month'] as num).toInt()]} ${((m['year'] as num).toInt() + 543) % 100}',
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: reached ? _ink : const Color(0xFF94A3B8))),
                    ),
                    Expanded(
                      child: Text(reached ? 'มา ${_n(s, 'present')}/${_n(s, 'school_days')} วัน' : 'ยังไม่ถึง',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF475569))),
                    ),
                    if (reached && pills.isEmpty)
                      Icon(Icons.check_rounded, size: 20, color: TeacherMark.color('/'), semanticLabel: 'มาตรงเวลาทุกวัน')
                    else
                      Wrap(spacing: 4, children: [for (final sym in pills) _countPill(sym, _n(s, TeacherMark.summaryKey[sym]!))]),
                  ]),
                ),
              ),
            );
          }),
      ]);
    }

    // รายการ ส ขส ล ร ในช่วงนี้ (วันลาต่อเนื่องของใบลาเดียวกันรวมเป็นรายการเดียว)
    final events = <Map<String, dynamic>>[];
    for (final i in period.slots) {
      final s = i < status.length ? status[i] : '';
      if (s.isEmpty || s == '/' || holidays.contains(i)) continue;
      final inf = i < info.length && info[i] is Map ? Map<String, dynamic>.from(info[i] as Map) : null;
      final key = inf != null ? 'L${inf['leave_id']}' : 'M$i';
      if (events.isNotEmpty && events.last['key'] == key) {
        events.last['last'] = i;
        events.last['days'] = (events.last['days'] as int) + 1;
        continue;
      }
      events.add({'key': key, 'sym': s, 'first': i, 'last': i, 'days': 1, 'info': inf});
    }

    final eventsTitle = period.kind == 'week' ? 'รายการในสัปดาห์นี้' : (period.kind == 'month' ? 'รายการในเดือนนี้' : 'รายการทั้งภาคเรียน');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      body,
      const SizedBox(height: 14),
      Text(eventsTitle, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
      const SizedBox(height: 6),
      if (events.isEmpty)
        Text(period.elapsed == 0 ? 'ยังไม่มีรายการ' : 'มาตรงเวลาทุกวันในช่วงนี้',
            style: TextStyle(fontSize: 13, color: period.elapsed == 0 ? _muted : TeacherMark.color('/')))
      else
        for (final e in events)
          Builder(builder: (_) {
            final sym = e['sym'] as String;
            final inf = e['info'] as Map<String, dynamic>?;
            final first = e['first'] as int;
            final last = e['last'] as int;
            final days = e['days'] as int;
            String title;
            if (inf != null) {
              final t = inf['leave_type']?.toString() ?? TeacherMark.label[sym]!;
              final time = (inf['time'] ?? '').toString();
              title = sym == 'ขส' ? 'ขอเข้าสาย${time.isNotEmpty ? ' ถึง $time น.' : ''}' : '$t $days วัน';
            } else {
              title = TeacherMark.label[sym]!;
            }
            final when = first == last
                ? '${dayShortThai[first % 5]}. ${thaiShortDate(dates[first])}'
                : '${dayShortThai[first % 5]}. ${thaiShortDate(dates[first])} – ${dayShortThai[last % 5]}. ${thaiShortDate(dates[last])}';
            final approval = inf == null
                ? 'หัวหน้างานบุคคลบันทึก'
                : (inf['approval'] == 'approved' ? 'อนุมัติแล้ว' : (inf['approval'] == 'pending' ? 'รออนุมัติ' : '${inf['approval'] ?? ''}'));
            final ahead = dates[first].compareTo(today) > 0 ? 'ล่วงหน้า • ' : '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onCellTap == null ? null : () => onCellTap!(first),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: _headBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _lineSoft)),
                  child: Row(children: [
                    TeacherMarkBadge(sym, size: 13),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _ink)),
                        Text('$when • $ahead$approval', style: const TextStyle(fontSize: 12, color: _muted)),
                      ]),
                    ),
                  ]),
                ),
              ),
            );
          }),
    ]);
  }
}
