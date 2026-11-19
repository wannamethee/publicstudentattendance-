import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'teacher_attendance_grid.dart';

const _ink = Color(0xFF0F172A);
const _muted = Color(0xFF64748B);
const _line = Color(0xFFE2E8F0);
const _panel = Color(0xFFF8FAFC);
const _accent = Color(0xFF3B2580);

/// แดชบอร์ดมุมมอง "ครู" (ผู้อำนวยการ / ผู้ดูแลระบบ / หัวหน้างานบุคคล):
///  1. ใครไม่อยู่ในวันที่เลือก (ล ร ขส ส) พร้อมคาบสอนที่ได้รับผลกระทบ จากตารางสอนครู
///  2. สถิติรายสัปดาห์ / รายเดือน / ทั้งภาคเรียน: กล่องตัวเลข กราฟแนวโน้ม และกราฟรายคน (ล ส ขส)
/// ข้อมูลมาจาก GET /api/v1/leaves/attendance-grid และ /day-overview (ไม่มีเหตุผลการลา)
class TeacherDashboardView extends StatefulWidget {
  final ApiService apiService;
  const TeacherDashboardView({super.key, required this.apiService});

  @override
  State<TeacherDashboardView> createState() => TeacherDashboardViewState();
}

class TeacherDashboardViewState extends State<TeacherDashboardView> {
  Map<String, dynamic>? _grid;
  String? _error;

  String _period = 'week';
  final Map<String, int> _index = {}; // ไม่มี = ช่วงที่มีวันนี้

  int? _slot; // ช่องวันที่เลือกในส่วน "ใครไม่อยู่"
  Map<String, dynamic>? _day;
  bool _dayLoading = false;
  String? _dayError;
  int _dayRequest = 0;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// โหลดใหม่ทั้งตารางและวันที่เลือก (เรียกจากปุ่มรีเฟรช / หลังอนุมัติใบลา)
  Future<void> reload() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      var sem = widget.apiService.defaultSemesterNotifier.value;
      if (sem == null) {
        await widget.apiService.getSemesterConfigs();
        sem = widget.apiService.defaultSemesterNotifier.value;
      }
      if (sem == null) throw Exception('ยังไม่ได้ตั้งค่าภาคเรียน');
      final g = await widget.apiService.getTeacherAttendanceGrid(term: sem.term, year: sem.year);
      if (!mounted) return;
      setState(() {
        _grid = g;
        _slot ??= _initialSlot(g);
      });
      await _loadDay();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  /// วันนี้ถ้าเป็นวันเรียน ไม่อย่างนั้นวันเรียนถัดไป (หรือวันเรียนสุดท้ายถ้าภาคเรียนจบแล้ว)
  int _initialSlot(Map<String, dynamic> g) {
    final dates = (g['dates'] as List).map((e) => e.toString()).toList();
    final holidays = ((g['holidays'] as List?) ?? const []).map((e) => e as int).toSet();
    final today = g['today']?.toString() ?? '';
    int? next;
    int? last;
    for (var i = 0; i < dates.length; i++) {
      if (holidays.contains(i)) continue;
      if (dates[i].compareTo(today) >= 0) {
        next ??= i;
      } else {
        last = i;
      }
    }
    return next ?? last ?? 0;
  }

  List<int> _schoolSlots(Map<String, dynamic> g) {
    final holidays = ((g['holidays'] as List?) ?? const []).map((e) => e as int).toSet();
    final n = (g['dates'] as List).length;
    return [for (var i = 0; i < n; i++) if (!holidays.contains(i)) i];
  }

  Future<void> _loadDay() async {
    final g = _grid;
    final slot = _slot;
    if (g == null || slot == null) return;
    final req = ++_dayRequest;
    setState(() {
      _dayLoading = true;
      _dayError = null;
    });
    try {
      final d = await widget.apiService.getTeacherDayOverview(
        term: g['term'].toString(),
        year: g['year'].toString(),
        date: (g['dates'] as List)[slot].toString(),
      );
      if (mounted && req == _dayRequest) setState(() => _day = d);
    } catch (e) {
      if (mounted && req == _dayRequest) setState(() => _dayError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted && req == _dayRequest) setState(() => _dayLoading = false);
    }
  }

  void _goSlot(int slot) {
    if (slot == _slot) return;
    setState(() {
      _slot = slot;
      _day = null;
    });
    _loadDay();
  }

  TeacherPeriod _currentPeriod(Map<String, dynamic> g) =>
      TeacherPeriod.of(g, _period, _index[_period] ?? TeacherPeriod.todayIndex(g, _period));

  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final g = _grid;
    if (g == null) {
      if (_error != null) {
        return _card(
          child: Column(children: [
            Icon(Icons.error_outline_rounded, size: 40, color: Colors.red.shade700),
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Colors.red.shade800)),
            const SizedBox(height: 10),
            FilledButton(onPressed: reload, child: const Text('ลองใหม่')),
          ]),
        );
      }
      return _card(child: const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _dayPanel(g),
      const SizedBox(height: 16),
      _periodSection(g),
    ]);
  }

  // ------------------------------------------------------------------ ใครไม่อยู่ในวันที่เลือก

  Widget _dayPanel(Map<String, dynamic> g) {
    final dates = (g['dates'] as List).map((e) => e.toString()).toList();
    final slots = _schoolSlots(g);
    final slot = _slot ?? 0;
    final pos = slots.indexOf(slot);
    final todaySlot = g['today_slot'] as int?;
    final day = _day;
    final iso = dates[slot];
    final isToday = todaySlot == slot;
    final isFuture = iso.compareTo(g['today']?.toString() ?? '') > 0;
    final narrow = MediaQuery.of(context).size.width < 600;
    final entries = ((day?['entries'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final counts = Map<String, dynamic>.from((day?['counts'] as Map?) ?? const {});
    final affected = (day?['affected_periods'] as num?)?.toInt() ?? 0;
    final holiday = day?['is_holiday'] == true;

    Future<void> pick() async {
      final first = DateTime.parse(dates.first);
      final last = DateTime.parse(dates.last);
      final set = {for (final i in slots) dates[i]};
      final init = DateTime.parse(iso);
      final d = await showDatePicker(
        context: context,
        initialDate: init,
        firstDate: first,
        lastDate: last,
        selectableDayPredicate: (d) => set.contains(
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'),
      );
      if (d == null) return;
      final s = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final i = dates.indexOf(s);
      if (i >= 0) _goSlot(i);
    }

    final nav = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'วันเรียนก่อนหน้า',
        onPressed: pos <= 0 ? null : () => _goSlot(slots[pos - 1]),
        icon: const Icon(Icons.chevron_left_rounded),
      ),
      OutlinedButton.icon(
        onPressed: pick,
        icon: const Icon(Icons.calendar_month_rounded, size: 18),
        label: Text('${dayFullThai[slot % 5]} ${thaiShortDate(iso)}'),
      ),
      IconButton(
        tooltip: 'วันเรียนถัดไป',
        onPressed: pos < 0 || pos >= slots.length - 1 ? null : () => _goSlot(slots[pos + 1]),
        icon: const Icon(Icons.chevron_right_rounded),
      ),
      if (!isToday && todaySlot != null && slots.contains(todaySlot))
        TextButton(onPressed: () => _goSlot(todaySlot), child: const Text('วันนี้')),
    ]);

    Widget count(String sym) {
      final n = (counts[sym] as num?)?.toInt() ?? 0;
      return Container(
        padding: const EdgeInsets.fromLTRB(4, 3, 12, 3),
        decoration: BoxDecoration(
          color: n > 0 ? TeacherMark.fill(sym) : Colors.white,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: n > 0 ? TeacherMark.border(sym) : _line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          TeacherMarkBadge(sym, size: 12),
          const SizedBox(width: 8),
          Text('${TeacherMark.label[sym]} $n คน',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: n > 0 ? _ink : _muted)),
        ]),
      );
    }

    Widget body;
    if (_dayError != null) {
      body = Row(children: [
        Expanded(child: Text(_dayError!, style: TextStyle(color: Colors.red.shade800))),
        TextButton(onPressed: _loadDay, child: const Text('ลองใหม่')),
      ]);
    } else if (day == null) {
      body = const SizedBox(height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    } else if (holiday) {
      body = const Text('วันหยุด ไม่มีการเรียนการสอน', style: TextStyle(fontSize: 14, color: _muted));
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final s in const ['ล', 'ร', 'ขส', 'ส']) count(s),
          if (entries.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: affected > 0 ? const Color(0xFFFFF7ED) : const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: affected > 0 ? const Color(0xFFFED7AA) : const Color(0xFFBBF7D0)),
              ),
              child: Text(
                affected > 0 ? 'ต้องหาครูสอนแทน $affected คาบ' : 'ไม่มีคาบที่ต้องหาครูสอนแทน',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: affected > 0 ? TeacherMark.color('ล') : TeacherMark.color('/')),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        if (entries.isEmpty)
          Text(
            isFuture ? 'ยังไม่มีรายการลา ไปราชการ หรือขอเข้าสาย ล่วงหน้าในวันนี้' : 'ไม่มีครูลา ไปราชการ ขอเข้าสาย หรือมาสาย • มาครบทุกคน',
            style: TextStyle(fontSize: 14, color: TeacherMark.color('/'), fontWeight: FontWeight.w600),
          )
        else
          for (final e in entries) ...[_entryCard(e), const SizedBox(height: 8)],
      ]);
    }

    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: isToday ? const Color(0xFFF59E0B) : _muted, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text('ใครไม่อยู่ วัน${dayFullThai[slot % 5]}ที่ ${thaiShortDate(iso)}',
                style: TextStyle(fontSize: narrow ? 15 : 17, fontWeight: FontWeight.w800, color: _ink)),
            if (isToday || isFuture) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: isToday ? const Color(0xFFFEF3C7) : const Color(0xFFEDE9FE), borderRadius: BorderRadius.circular(99)),
                child: Text(isToday ? 'วันนี้' : 'ล่วงหน้า',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isToday ? const Color(0xFF92400E) : _accent)),
              ),
            ],
            if (_dayLoading) ...[
              const SizedBox(width: 10),
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ]),
          nav,
        ]),
        const SizedBox(height: 4),
        Text('เชื่อมกับตารางสอนครู: คาบสีส้มคือคาบที่ครูไม่อยู่สอน ต้องจัดครูสอนแทน',
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
        const SizedBox(height: 12),
        body,
      ]),
    );
  }

  Widget _entryCard(Map<String, dynamic> e) {
    final st = e['status'].toString();
    final periods = ((e['periods'] as List?) ?? const []).map((p) => Map<String, dynamic>.from(p as Map)).toList();
    final n = (e['affected_periods'] as num?)?.toInt() ?? 0;
    final arrival = e['arrival_time']?.toString();
    String detail;
    switch (st) {
      case 'ขส':
        detail = arrival != null ? 'ขอเข้าสาย ถึง $arrival น.' : 'ขอเข้าสาย (ไม่ได้ระบุเวลา)';
        break;
      case 'ล':
        detail = e['leave_type']?.toString() ?? 'ลา';
        break;
      default:
        detail = TeacherMark.label[st] ?? st;
    }
    final pending = e['approval'] == 'pending';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: _line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TeacherMarkBadge(st, size: 13),
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${e['teacher_name']}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: _ink)),
              Text(detail, style: const TextStyle(fontSize: 13, color: Color(0xFF475569))),
              if (pending)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(99)),
                  child: const Text('รออนุมัติ', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                ),
            ]),
          ),
          if (n > 0) ...[
            const SizedBox(width: 8),
            Text('$n คาบ', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: TeacherMark.color('ล'))),
          ],
        ]),
        if (st != 'ส') ...[
          const SizedBox(height: 8),
          if (periods.isEmpty)
            const Text('ไม่มีคาบสอนในวันนี้', style: TextStyle(fontSize: 12.5, color: _muted))
          else
            Wrap(spacing: 6, runSpacing: 6, children: [for (final p in periods) _periodChip(p)]),
        ],
      ]),
    );
  }

  Widget _periodChip(Map<String, dynamic> p) {
    final hit = p['affected'] == true;
    final first = (p['period'] as num).toInt();
    final span = (p['span'] as num?)?.toInt() ?? 1;
    final label = span > 1 ? 'คาบ $first–${first + span - 1}' : 'คาบ $first';
    final level = _levelsText((p['class_level'] ?? '').toString());
    final name = (p['course_name'] ?? '').toString();
    final noStudents = p['no_students'] == true;
    final room = (p['room'] ?? '').toString();
    return Tooltip(
      message: [
        '$label ${p['time_start']}–${p['time_end']} น.',
        '${p['course_code']}${name.isEmpty ? '' : ' $name'}',
        if (level.isNotEmpty) level,
        if (room.isNotEmpty) 'ห้อง $room',
        noStudents ? 'คาบของครูล้วน ไม่มีนักเรียน ไม่ต้องหาครูสอนแทน' : (hit ? 'ครูไม่อยู่ ต้องจัดครูสอนแทน' : 'ครูอยู่ในคาบนี้'),
      ].join(' • '),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: hit ? const Color(0xFFFFF7ED) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: hit ? const Color(0xFFFDBA74) : _line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: hit ? TeacherMark.color('ล') : _muted)),
          const SizedBox(width: 6),
          Flexible(
            child: Text('${p['course_code']}${level.isEmpty ? '' : ' $level'}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: hit ? _ink : _muted)),
          ),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ สถิติรายสัปดาห์ / เดือน / ทั้งภาคเรียน

  Widget _periodSection(Map<String, dynamic> g) {
    final rows = ((g['teachers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final period = _currentPeriod(g);
    final todayIdx = TeacherPeriod.todayIndex(g, _period);
    final lastIdx = TeacherPeriod.count(g, _period) - 1;
    final narrow = MediaQuery.of(context).size.width < 600;

    void set(String kind, [int? index]) => setState(() {
          _period = kind;
          if (index != null) _index[kind] = index;
        });

    final navButton = IconButton.styleFrom(
      side: const BorderSide(color: _line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
    final navigator = Row(mainAxisSize: MainAxisSize.min, children: [
      if (_period != 'term')
        IconButton(
          tooltip: 'ช่วงก่อนหน้า',
          style: navButton,
          onPressed: period.index <= 0 ? null : () => set(_period, period.index - 1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
      ConstrainedBox(
        constraints: BoxConstraints(minWidth: narrow ? 170 : 240, maxWidth: narrow ? 230 : 380),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(children: [
            Text(period.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: _ink)),
            Text(period.sub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: _muted)),
          ]),
        ),
      ),
      if (_period != 'term')
        IconButton(
          tooltip: 'ช่วงถัดไป',
          style: navButton,
          onPressed: period.index >= lastIdx ? null : () => set(_period, period.index + 1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
    ]);

    final trend = _TrendChart(
      groups: _trendGroups(g, rows),
      selected: _period == 'term' ? null : period.index,
      weekMode: _period == 'week',
      onTap: (k) => _period == 'week' ? set('week', k) : set('month', k),
    );
    final persons = _PersonChart(rows: rows, period: period, narrow: narrow);

    return _card(
      padding: EdgeInsets.all(narrow ? 12 : 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.query_stats_rounded, color: _accent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('สถิติการมาปฏิบัติงานของครู', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _ink)),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 16, runSpacing: 10, alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'week', label: Text('รายสัปดาห์')),
                const ButtonSegment(value: 'month', label: Text('รายเดือน')),
                ButtonSegment(value: 'term', label: Text(narrow ? 'ทั้งภาค' : 'ทั้งภาคเรียน')),
              ],
              selected: {_period},
              showSelectedIcon: false,
              onSelectionChanged: (v) => set(v.first),
            ),
          ),
          navigator,
          if (_period != 'term' && period.index != todayIdx)
            TextButton.icon(
              onPressed: () => setState(() => _index.remove(_period)),
              icon: const Icon(Icons.today_rounded, size: 18),
              label: const Text('กลับไปช่วงที่มีวันนี้'),
            ),
        ]),
        const SizedBox(height: 14),
        PeriodTiles(tiles: PeriodTile.forAll(rows, period)),
        const SizedBox(height: 16),
        Wrap(spacing: 14, runSpacing: 6, children: [
          for (final s in const ['ล', 'ส', 'ขส'])
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: TeacherMark.color(s), borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 6),
              Text('${TeacherMark.label[s]} ($s)', style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569))),
            ]),
          const Text('จำนวนวัน • ไม่รวมไปราชการ', style: TextStyle(fontSize: 12.5, color: _muted)),
        ]),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= 900) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 5, child: _chartBox(_period == 'week' ? 'แนวโน้มรายสัปดาห์ (ครูทุกคนรวมกัน)' : 'แนวโน้มรายเดือน (ครูทุกคนรวมกัน)', trend)),
              const SizedBox(width: 14),
              Expanded(flex: 6, child: _chartBox('รายคน • ${period.title}', persons)),
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _chartBox(_period == 'week' ? 'แนวโน้มรายสัปดาห์ (ครูทุกคนรวมกัน)' : 'แนวโน้มรายเดือน (ครูทุกคนรวมกัน)', trend),
            const SizedBox(height: 12),
            _chartBox('รายคน • ${period.title}', persons),
          ]);
        }),
      ]),
    );
  }

  Widget _chartBox(String title, Widget chart) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF334155))),
          const SizedBox(height: 10),
          chart,
        ]),
      );

  /// กลุ่มของกราฟแนวโน้ม: สัปดาห์ทั้ง 20 (โหมดรายสัปดาห์) หรือเดือนทั้งภาค (โหมดรายเดือน / ทั้งภาค)
  List<_TrendGroup> _trendGroups(Map<String, dynamic> g, List<Map<String, dynamic>> rows) {
    final weekMode = _period == 'week';
    final items = TeacherPeriod.items(g, weekMode ? 'week' : 'month');
    final key = weekMode ? 'weekly' : 'monthly';
    return [
      for (var k = 0; k < items.length; k++)
        () {
          var leave = 0, late = 0, req = 0;
          for (final r in rows) {
            final list = (r[key] as List?) ?? const [];
            if (k >= list.length) continue;
            final s = list[k] as Map;
            leave += (s['leave'] as num?)?.toInt() ?? 0;
            late += (s['late'] as num?)?.toInt() ?? 0;
            req += (s['late_request'] as num?)?.toInt() ?? 0;
          }
          final it = items[k];
          return _TrendGroup(
            label: weekMode ? '${k + 1}' : monthShortThai[(it['month'] as num).toInt()],
            tooltip: weekMode
                ? 'สัปดาห์ที่ ${k + 1} (${thaiShortDate(it['start'].toString())} – ${thaiShortDate(it['end'].toString())})'
                : '${monthFullThai[(it['month'] as num).toInt()]} ${(it['year'] as num).toInt() + 543}',
            leave: leave,
            late: late,
            lateRequest: req,
            reached: ((it['elapsed'] as num?) ?? 0) > 0,
          );
        }(),
    ];
  }
}

class _TrendGroup {
  final String label;
  final String tooltip;
  final int leave;
  final int late;
  final int lateRequest;
  final bool reached;
  const _TrendGroup({
    required this.label,
    required this.tooltip,
    required this.leave,
    required this.late,
    required this.lateRequest,
    required this.reached,
  });
  int get total => leave + late + lateRequest;
}

/// กราฟแท่งซ้อน ล / ส / ขส รายสัปดาห์หรือรายเดือน (ครูทุกคนรวมกัน) แตะแท่งเพื่อเลือกช่วงนั้น
class _TrendChart extends StatelessWidget {
  final List<_TrendGroup> groups;
  final int? selected;
  final bool weekMode;
  final void Function(int index) onTap;
  const _TrendChart({required this.groups, required this.selected, required this.weekMode, required this.onTap});

  static const double _h = 130;

  @override
  Widget build(BuildContext context) {
    final maxV = math.max(3, groups.fold<int>(0, (m, g) => math.max(m, g.total)));
    Widget seg(int v, Color c) => v <= 0
        ? const SizedBox.shrink()
        : Container(
            height: math.max(3.0, v / maxV * _h),
            margin: const EdgeInsets.only(bottom: 1.5),
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
          );

    Widget bar(int k) {
      final g = groups[k];
      final sel = selected == k;
      return Expanded(
        child: Tooltip(
          message: g.reached
              ? '${g.tooltip}\nลา ${g.leave} วัน • มาสาย ${g.late} • ขอเข้าสาย ${g.lateRequest}'
              : '${g.tooltip}\nยังไม่ถึง',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onTap(k),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              padding: const EdgeInsets.fromLTRB(1, 4, 1, 4),
              decoration: BoxDecoration(
                color: sel ? const Color(0xFFF5F3FF) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: sel ? const Color(0xFFC4B5FD) : Colors.transparent),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                SizedBox(
                  height: _h + 18,
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    if (g.total > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text('${g.total}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _ink)),
                      ),
                    seg(g.lateRequest, TeacherMark.color('ขส')),
                    seg(g.late, TeacherMark.color('ส')),
                    seg(g.leave, TeacherMark.color('ล')),
                  ]),
                ),
                Container(height: 1.5, color: g.reached ? const Color(0xFF94A3B8) : _line),
                const SizedBox(height: 4),
                Text(g.label,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                        fontSize: weekMode ? 10.5 : 12,
                        fontWeight: sel ? FontWeight.w800 : FontWeight.w500,
                        color: !g.reached ? const Color(0xFFA0AEC0) : (sel ? _accent : const Color(0xFF475569)))),
              ]),
            ),
          ),
        ),
      );
    }

    if (groups.isEmpty) return const Text('ไม่มีข้อมูล', style: TextStyle(color: _muted));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [for (var k = 0; k < groups.length; k++) bar(k)]),
      const SizedBox(height: 6),
      Text(
        weekMode ? 'แกนนอน = สัปดาห์ที่ (แตะแท่งเพื่อดูสัปดาห์นั้น)' : 'แกนนอน = เดือน (แตะแท่งเพื่อดูเดือนนั้น)',
        style: const TextStyle(fontSize: 11.5, color: _muted),
      ),
    ]);
  }
}

/// กราฟแท่งนอนรายคน: ล / ส / ขส ของช่วงที่เลือก เรียงคนที่มากที่สุดขึ้นก่อน (คนที่ไม่มีรายการรวมเป็นบรรทัดเดียว)
class _PersonChart extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final TeacherPeriod period;
  final bool narrow;
  const _PersonChart({required this.rows, required this.period, required this.narrow});

  @override
  Widget build(BuildContext context) {
    if (period.elapsed == 0) {
      return const Text('ยังไม่ถึงช่วงนี้', style: TextStyle(fontSize: 13.5, color: _muted));
    }
    final items = <_PersonBar>[];
    final zero = <String>[];
    for (var i = 0; i < rows.length; i++) {
      final s = period.summaryOf(rows[i]);
      int n(String k) => (s[k] as num?)?.toInt() ?? 0;
      final p = _PersonBar(rows[i]['teacher_name'].toString(), n('leave'), n('late'), n('late_request'), i);
      if (p.total == 0) {
        zero.add(p.name);
      } else {
        items.add(p);
      }
    }
    items.sort((a, b) => b.total != a.total ? b.total - a.total : a.order - b.order);
    if (items.isEmpty) {
      return Text('ไม่มีครูลา มาสาย หรือขอเข้าสาย ในช่วงนี้ • มาครบทุกคน',
          style: TextStyle(fontSize: 13.5, color: TeacherMark.color('/'), fontWeight: FontWeight.w600));
    }
    final maxV = math.max(3, items.first.total);
    final nameW = narrow ? 104.0 : 170.0;

    Widget seg(String sym, int v, double w) {
      if (v <= 0) return const SizedBox.shrink();
      return Container(
        width: math.max(4, w),
        height: 24,
        margin: const EdgeInsets.only(right: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: TeacherMark.color(sym), borderRadius: BorderRadius.circular(5)),
        child: w >= 22
            ? Text('$v', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white))
            : null,
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final p in items)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Tooltip(
            message: '${p.name}\nลา ${p.leave} วัน • มาสาย ${p.late} • ขอเข้าสาย ${p.lateRequest}',
            child: Row(children: [
              SizedBox(
                width: nameW,
                child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: narrow ? 12 : 13, fontWeight: FontWeight.w600, color: _ink)),
              ),
              Expanded(
                child: LayoutBuilder(builder: (context, c) {
                  final unit = (c.maxWidth - 40) / maxV;
                  return Row(children: [
                    seg('ล', p.leave, p.leave * unit - 2),
                    seg('ส', p.late, p.late * unit - 2),
                    seg('ขส', p.lateRequest, p.lateRequest * unit - 2),
                    const SizedBox(width: 4),
                    Text('${p.total}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink)),
                  ]);
                }),
              ),
            ]),
          ),
        ),
      if (zero.isNotEmpty) ...[
        const SizedBox(height: 8),
        Tooltip(
          message: zero.join('\n'),
          child: Text('ไม่มีรายการในช่วงนี้ ${zero.length} คน',
              style: const TextStyle(fontSize: 12.5, color: _muted, decoration: TextDecoration.underline, decorationStyle: TextDecorationStyle.dotted)),
        ),
      ],
    ]);
  }
}

class _PersonBar {
  final String name;
  final int leave;
  final int late;
  final int lateRequest;
  final int order;
  const _PersonBar(this.name, this.leave, this.late, this.lateRequest, this.order);
  int get total => leave + late + lateRequest;
}

/// "ม.1, ม.2, ม.3, ม.4, ม.5, ม.6" -> "ม.1–6" (ระดับชั้นติดกันตั้งแต่ 3 ชั้นขึ้นไป); อย่างอื่นคงเดิม
String _levelsText(String text) {
  final parts = text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final nums = <int>[];
  for (final p in parts) {
    final m = RegExp(r'^ม\.(\d)$').firstMatch(p);
    if (m == null) return text;
    nums.add(int.parse(m.group(1)!));
  }
  if (nums.length < 3) return text;
  for (var i = 1; i < nums.length; i++) {
    if (nums[i] != nums[i - 1] + 1) return text;
  }
  return 'ม.${nums.first}–${nums.last}';
}
