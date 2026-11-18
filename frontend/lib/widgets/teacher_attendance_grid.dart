import 'package:flutter/material.dart';

/// สัญลักษณ์ในตารางลงเวลาครู (สีเดียวกับตารางเช็คชื่อนักเรียน: ส สีน้ำเงิน, ล สีส้ม)
class TeacherMark {
  static const order = ['/', 'ส', 'ขส', 'ล', 'ร'];
  static const label = {'/': 'มา', 'ส': 'มาสาย', 'ขส': 'ขอเข้าสาย', 'ล': 'ลา', 'ร': 'ไปราชการ'};

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
}

const _dayShort = ['จ', 'อ', 'พ', 'พฤ', 'ศ'];
const dayFullThai = ['จันทร์', 'อังคาร', 'พุธ', 'พฤหัสบดี', 'ศุกร์'];
const _monthShort = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];

/// "17 พ.ย. 69"
String thaiShortDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${d.day} ${_monthShort[d.month]} ${(d.year + 543) % 100}';
}

/// ตารางลงเวลาครู: แถว = ครู, คอลัมน์ = วันเรียน (20 สัปดาห์ × จ–ศ เหมือนตารางเช็คชื่อนักเรียน)
/// data = ผลจาก GET /api/v1/leaves/attendance-grid; แสดงสัปดาห์ weekFrom..weekTo (เริ่มที่ 0)
class TeacherAttendanceGrid extends StatefulWidget {
  final Map<String, dynamic> data;
  final int weekFrom;
  final int weekTo;
  final void Function(Map<String, dynamic> row, int slot)? onCellTap;
  final void Function(Map<String, dynamic> row)? onNameTap;

  const TeacherAttendanceGrid({
    super.key,
    required this.data,
    required this.weekFrom,
    required this.weekTo,
    this.onCellTap,
    this.onNameTap,
  });

  @override
  State<TeacherAttendanceGrid> createState() => _TeacherAttendanceGridState();
}

class _TeacherAttendanceGridState extends State<TeacherAttendanceGrid> {
  static const double _cellW = 36;
  static const double _cellH = 38;
  static const double _weekH = 34;
  static const double _dayH = 36;
  final _hScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToToday());
  }

  @override
  void didUpdateWidget(covariant TeacherAttendanceGrid old) {
    super.didUpdateWidget(old);
    if (old.weekFrom != widget.weekFrom || old.weekTo != widget.weekTo) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToToday());
    }
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  /// เลื่อนให้สัปดาห์ของวันนี้อยู่ในจอ (เห็นสัปดาห์ก่อนหน้าด้วย 1 สัปดาห์)
  void _scrollToToday() {
    if (!_hScroll.hasClients) return;
    final today = widget.data['today_slot'];
    if (today is! int) return;
    final week = today ~/ 5;
    if (week < widget.weekFrom || week > widget.weekTo) return;
    final target = ((week - widget.weekFrom - 1).clamp(0, 99)) * 5 * _cellW;
    _hScroll.jumpTo(target.toDouble().clamp(0, _hScroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final dates = ((widget.data['dates'] as List?) ?? const []).map((e) => e.toString()).toList();
    final holidays = ((widget.data['holidays'] as List?) ?? const []).map((e) => e as int).toSet();
    final todaySlot = widget.data['today_slot'] as int?;
    final rows = ((widget.data['teachers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final weeks = [for (var w = widget.weekFrom; w <= widget.weekTo && w * 5 < dates.length; w++) w];
    final narrow = MediaQuery.of(context).size.width < 600;
    final nameW = narrow ? 112.0 : 210.0;
    const line = Color(0xFFE2E8F0);

    Widget nameCell(Map<String, dynamic> row, int i) {
      final name = row['teacher_name']?.toString() ?? '';
      final code = row['teacher_code']?.toString() ?? '';
      return InkWell(
        onTap: widget.onNameTap == null ? null : () => widget.onNameTap!(row),
        child: Container(
          height: _cellH,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: line), right: BorderSide(color: line))),
          child: Row(
            children: [
              if (!narrow)
                SizedBox(width: 22, child: Text('${i + 1}', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)))),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: narrow ? 12 : 13,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF0F172A),
                    decoration: widget.onNameTap == null ? null : TextDecoration.underline,
                    decorationColor: const Color(0xFFCBD5E1),
                  ),
                ),
              ),
              if (!narrow) Text(code, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
            ],
          ),
        ),
      );
    }

    Widget dayCell(Map<String, dynamic> row, int slot) {
      final status = ((row['status_list'] as List?) ?? const [])[slot]?.toString() ?? '';
      final info = ((row['info'] as List?) ?? const [])[slot];
      final isHoliday = holidays.contains(slot);
      final isToday = slot == todaySlot;
      final pending = info is Map && info['approval'] == 'pending';
      final dayIdx = slot % 5;
      final tip = isHoliday
          ? 'วันหยุด'
          : '${row['teacher_name']} • วัน${dayFullThai[dayIdx]} ${thaiShortDate(dates[slot])}'
              '${status.isEmpty ? '' : ' • ${TeacherMark.label[status] ?? status}'}'
              '${info is Map && (info['time'] ?? '').toString().isNotEmpty ? ' (ถึง ${info['time']} น.)' : ''}'
              '${pending ? ' • รออนุมัติ' : ''}';
      final cell = Container(
        width: _cellW,
        height: _cellH,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isHoliday ? const Color(0xFFE2E8F0) : (isToday && status.isEmpty ? const Color(0xFFFFFBEB) : TeacherMark.fill(status)),
          border: Border(
            bottom: const BorderSide(color: line),
            right: BorderSide(color: dayIdx == 4 ? const Color(0xFFCBD5E1) : line),
            left: isToday ? const BorderSide(color: Color(0xFFF59E0B), width: 1.5) : BorderSide.none,
          ),
        ),
        child: status.isEmpty
            ? null
            : Text(
                status,
                style: TextStyle(
                  fontSize: status.length > 1 ? 12 : 15,
                  fontWeight: FontWeight.bold,
                  color: TeacherMark.color(status),
                  decoration: pending ? TextDecoration.underline : null,
                  decorationStyle: TextDecorationStyle.dotted,
                ),
              ),
      );
      return Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: isHoliday || widget.onCellTap == null ? null : () => widget.onCellTap!(row, slot),
          child: cell,
        ),
      );
    }

    final header = Column(
      children: [
        Row(
          children: [
            for (final w in weeks)
              Container(
                width: _cellW * 5,
                height: _weekH,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F5F9),
                  border: Border(bottom: BorderSide(color: line), right: BorderSide(color: Color(0xFFCBD5E1))),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('สัปดาห์ที่ ${w + 1}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
                    Text(
                      '${thaiShortDate(dates[w * 5]).split(' ').take(2).join(' ')} – ${thaiShortDate(dates[w * 5 + 4]).split(' ').take(2).join(' ')}',
                      style: const TextStyle(fontSize: 9.5, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
          ],
        ),
        Row(
          children: [
            for (final w in weeks)
              for (var d = 0; d < 5; d++)
                Builder(builder: (_) {
                  final slot = w * 5 + d;
                  final isToday = slot == todaySlot;
                  final isHoliday = holidays.contains(slot);
                  return Container(
                    width: _cellW,
                    height: _dayH,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isToday ? const Color(0xFFFDE68A) : (isHoliday ? const Color(0xFFE2E8F0) : Colors.white),
                      border: Border(
                        bottom: const BorderSide(color: Color(0xFFCBD5E1)),
                        right: BorderSide(color: d == 4 ? const Color(0xFFCBD5E1) : line),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_dayShort[d], style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                        Text('${DateTime.tryParse(dates[slot])?.day ?? ''}', style: const TextStyle(fontSize: 10.5, color: Color(0xFF475569))),
                      ],
                    ),
                  );
                }),
          ],
        ),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: nameW,
            child: Column(
              children: [
                Container(
                  height: _weekH + _dayH,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: const BoxDecoration(
                    color: Color(0xFFF1F5F9),
                    border: Border(bottom: BorderSide(color: Color(0xFFCBD5E1)), right: BorderSide(color: line)),
                  ),
                  child: const Text('ชื่อครู', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
                ),
                for (var i = 0; i < rows.length; i++) nameCell(rows[i], i),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: _hScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header,
                    for (final row in rows)
                      Row(children: [
                        for (final w in weeks)
                          for (var d = 0; d < 5; d++) dayCell(row, w * 5 + d),
                      ]),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// สรุปรายคน: มา (รวม ส ขส ร) • ส • ขส • ล (กิจ/ป่วย) • ร  นับเฉพาะวันเรียนที่ผ่านมาแล้ว
class TeacherAttendanceSummaryTable extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row)? onNameTap;

  const TeacherAttendanceSummaryTable({super.key, required this.rows, this.onNameTap});

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155));
    const line = Color(0xFFE2E8F0);
    Widget c(Widget child, {double w = 84, Alignment a = Alignment.center, Color? bg}) => Container(
          width: w,
          height: 40,
          alignment: a,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: bg, border: const Border(bottom: BorderSide(color: line))),
          child: child,
        );
    Widget n(dynamic v, String sym) {
      final x = (v as num?)?.toInt() ?? 0;
      return Text('$x',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: x == 0 && sym != '/' ? const Color(0xFFCBD5E1) : TeacherMark.color(sym),
          ));
    }

    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          c(const Text('ลำดับ', style: head), w: 56, bg: const Color(0xFFF1F5F9)),
          c(const Text('ชื่อครู', style: head), w: 220, a: Alignment.centerLeft, bg: const Color(0xFFF1F5F9)),
          c(const Text('วันเรียน', style: head), bg: const Color(0xFFF1F5F9)),
          for (final s in TeacherMark.order)
            c(Text('${TeacherMark.label[s]} ($s)', style: head.copyWith(color: TeacherMark.color(s))), w: s == 'ขส' ? 108 : 92, bg: const Color(0xFFF1F5F9)),
          c(const Text('ลากิจ / ลาป่วย', style: head), w: 116, bg: const Color(0xFFF1F5F9)),
        ]),
        for (var i = 0; i < rows.length; i++)
          Builder(builder: (_) {
            final r = rows[i];
            final s = Map<String, dynamic>.from((r['summary'] as Map?) ?? const {});
            return Row(children: [
              c(Text('${i + 1}', style: const TextStyle(color: Color(0xFF64748B))), w: 56),
              c(
                InkWell(
                  onTap: onNameTap == null ? null : () => onNameTap!(r),
                  child: Text(r['teacher_name']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF0F172A),
                        decoration: onNameTap == null ? null : TextDecoration.underline,
                        decorationColor: const Color(0xFFCBD5E1),
                      )),
                ),
                w: 220,
                a: Alignment.centerLeft,
              ),
              c(Text('${s['school_days'] ?? 0}', style: const TextStyle(fontWeight: FontWeight.w600))),
              c(n(s['present'], '/'), w: 92),
              c(n(s['late'], 'ส'), w: 92),
              c(n(s['late_request'], 'ขส'), w: 108),
              c(n(s['leave'], 'ล'), w: 92),
              c(n(s['official'], 'ร'), w: 92),
              c(Text('${s['leave_kij'] ?? 0} / ${s['leave_puay'] ?? 0}', style: const TextStyle(color: Color(0xFF475569))), w: 116),
            ]);
          }),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
    );
  }
}
