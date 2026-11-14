import 'package:flutter/material.dart';
import '../services/api_service.dart';

/// Dialog that lists every subject + class level a teacher is assigned to,
/// with inline edit / delete / add so wrong imports can be fixed quickly.
class TeacherCoursesDialog extends StatefulWidget {
  final ApiService apiService;
  final String teacherName;
  final String teacherCode;
  final List<Map<String, dynamic>> allTeachers;
  final String initialTerm;
  final String initialYear;

  const TeacherCoursesDialog({
    super.key,
    required this.apiService,
    required this.teacherName,
    required this.teacherCode,
    required this.allTeachers,
    required this.initialTerm,
    required this.initialYear,
  });

  static Future<bool?> show(
    BuildContext context, {
    required ApiService apiService,
    required String teacherName,
    required String teacherCode,
    required List<Map<String, dynamic>> allTeachers,
    required String initialTerm,
    required String initialYear,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => TeacherCoursesDialog(
        apiService: apiService,
        teacherName: teacherName,
        teacherCode: teacherCode,
        allTeachers: allTeachers,
        initialTerm: initialTerm,
        initialYear: initialYear,
      ),
    );
  }

  @override
  State<TeacherCoursesDialog> createState() => _TeacherCoursesDialogState();
}

class _TeacherCoursesDialogState extends State<TeacherCoursesDialog> {
  static const _levels = ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'];
  static const _years = ['2567', '2568', '2569', '2570', '2571'];

  late String _term;
  late String _year;
  bool _loading = true;
  String? _error;
  bool _changed = false;
  List<Map<String, dynamic>> _courses = [];

  @override
  void initState() {
    super.initState();
    _term = widget.initialTerm;
    _year = widget.initialYear;
    _load();
  }

  String get _lookupKey =>
      widget.teacherCode.trim().isNotEmpty ? widget.teacherCode.trim() : widget.teacherName;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Query by name (canonical) – backend also matches teacher_code.
      final byName = await widget.apiService.getTeacherCourses(
        teacher: widget.teacherName,
        term: _term,
        year: _year,
      );
      var rows = byName;
      if (widget.teacherCode.trim().isNotEmpty) {
        final byCode = await widget.apiService.getTeacherCourses(
          teacher: _lookupKey,
          term: _term,
          year: _year,
        );
        final seen = <String>{for (final r in rows) '${r['course_code']}|${r['term']}|${r['year']}'};
        for (final r in byCode) {
          final k = '${r['course_code']}|${r['term']}|${r['year']}';
          if (seen.add(k)) rows.add(r);
        }
      }
      rows.sort((a, b) {
        final l = (a['class_level'] ?? '').toString().compareTo((b['class_level'] ?? '').toString());
        if (l != 0) return l;
        return (a['course_code'] ?? '').toString().compareTo((b['course_code'] ?? '').toString());
      });
      if (mounted) {
        setState(() {
          _courses = rows;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: error ? Colors.red.shade800 : Colors.green.shade800,
      content: Text(msg),
    ));
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ยืนยันการลบรายวิชา'),
        content: Text(
          'ลบ "${c['course_code']} ${c['course_name']}" (${c['class_level'] ?? '-'}) '
          'ออกจากรายวิชาของครูท่านนี้ในภาคเรียน ${c['term']}/${c['year']} ใช่หรือไม่?',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ลบรายวิชา'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.apiService.deleteCourseItem(
        courseCode: c['course_code'].toString(),
        term: c['term'].toString(),
        year: c['year'].toString(),
      );
      _changed = true;
      _snack('ลบรายวิชา ${c['course_code']} เรียบร้อยแล้ว');
      _load();
    } catch (e) {
      _snack('ลบไม่สำเร็จ: $e', error: true);
    }
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final isEdit = existing != null;
    final codeCtrl = TextEditingController(text: existing?['course_code']?.toString() ?? '');
    final nameCtrl = TextEditingController(text: existing?['course_name']?.toString() ?? '');
    final creditsCtrl = TextEditingController(
      text: existing?['credits'] != null ? existing!['credits'].toString() : '1.0',
    );
    String? level = existing?['class_level']?.toString();
    if (level != null && !_levels.contains(level)) level = null;
    String term = existing?['term']?.toString() ?? _term;
    String year = existing?['year']?.toString() ?? _year;
    if (!_years.contains(year)) year = _year;

    // Teacher selection (allows moving a subject to the correct teacher)
    final teacherNames = widget.allTeachers.map((t) => (t['name'] ?? '').toString()).where((n) => n.isNotEmpty).toList();
    String teacher = existing?['teacher']?.toString() ?? widget.teacherName;
    if (!teacherNames.contains(teacher)) {
      teacherNames.insert(0, teacher);
    }
    bool regenerate = true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(isEdit ? 'แก้ไขรายวิชาที่สอน' : 'เพิ่มรายวิชาที่สอน', style: const TextStyle(fontSize: 17)),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(labelText: 'รหัสวิชา', border: OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(labelText: 'ชื่อรายวิชา', border: OutlineInputBorder()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: level,
                          decoration: const InputDecoration(labelText: 'ระดับชั้น', border: OutlineInputBorder()),
                          items: _levels.map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(),
                          onChanged: (v) => setD(() => level = v),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: creditsCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'หน่วยกิต', border: OutlineInputBorder()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: teacher,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'ครูผู้สอน',
                      helperText: 'เปลี่ยนเพื่อย้ายวิชานี้ไปให้ครูที่สอนจริง',
                      border: OutlineInputBorder(),
                    ),
                    items: teacherNames.map((n) {
                      final code = widget.allTeachers
                          .firstWhere((t) => t['name'] == n, orElse: () => const {})['code']
                          ?.toString() ?? '';
                      return DropdownMenuItem(
                        value: n,
                        child: Text(code.isNotEmpty ? '$code • $n' : n, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (v) => setD(() => teacher = v ?? teacher),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: term,
                          decoration: const InputDecoration(labelText: 'ภาคเรียน', border: OutlineInputBorder()),
                          items: const [
                            DropdownMenuItem(value: '1', child: Text('ภาคเรียนที่ 1')),
                            DropdownMenuItem(value: '2', child: Text('ภาคเรียนที่ 2')),
                          ],
                          onChanged: (v) => setD(() => term = v ?? term),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: year,
                          decoration: const InputDecoration(labelText: 'ปีการศึกษา', border: OutlineInputBorder()),
                          items: _years.map((y) => DropdownMenuItem(value: y, child: Text(y))).toList(),
                          onChanged: (v) => setD(() => year = v ?? year),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: regenerate,
                    onChanged: (v) => setD(() => regenerate = v ?? true),
                    title: const Text('สร้างไฟล์ ปพ.5 ใหม่ตามข้อมูลที่แก้ไข (ดึงรายชื่อนักเรียนของชั้นนี้)',
                        style: TextStyle(fontSize: 13, height: 1.4)),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
            FilledButton(
              onPressed: () async {
                final code = codeCtrl.text.trim();
                final name = nameCtrl.text.trim();
                if (code.isEmpty || name.isEmpty || level == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('กรุณากรอกรหัสวิชา ชื่อรายวิชา และเลือกระดับชั้น')),
                  );
                  return;
                }
                final teacherCode = widget.allTeachers
                        .firstWhere((t) => t['name'] == teacher, orElse: () => const {})['code']
                        ?.toString() ??
                    '';
                try {
                  await widget.apiService.saveCourseItem({
                    'course_code': code,
                    'course_name': name,
                    'term': term,
                    'year': year,
                    'class_level': level,
                    'teacher': teacher,
                    'teacher_code': teacherCode,
                    'credits': double.tryParse(creditsCtrl.text.trim()) ?? 1.0,
                    'department': existing?['department'] ?? '',
                    'course_type': existing?['course_type'] ?? 'พื้นฐาน',
                    'score_ratio': existing?['score_ratio'] ?? '70:30',
                    if (existing?['periods_per_week'] != null) 'periods_per_week': existing!['periods_per_week'],
                    if (isEdit) 'old_course_code': existing['course_code'],
                    if (isEdit) 'old_term': existing['term'],
                    if (isEdit) 'old_year': existing['year'],
                    'regenerate_porpor5': regenerate,
                  });
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(backgroundColor: Colors.red.shade800, content: Text('บันทึกไม่สำเร็จ: $e')),
                    );
                  }
                }
              },
              child: const Text('บันทึก'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      _changed = true;
      _snack(isEdit ? 'บันทึกการแก้ไขรายวิชาเรียบร้อยแล้ว' : 'เพิ่มรายวิชาเรียบร้อยแล้ว');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final levels = _courses.map((c) => c['class_level']?.toString() ?? '').where((l) => l.isNotEmpty).toSet().toList()
      ..sort();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  if (widget.teacherCode.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.indigo.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.indigo.shade200),
                      ),
                      child: Text(
                        widget.teacherCode,
                        style: TextStyle(
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo.shade900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      widget.teacherName,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, height: 1.4),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'ปิด',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context, _changed),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'รายวิชาและระดับชั้นที่สอน — ตรวจสอบและแก้ไขได้หากนำเข้าข้อมูลไม่ถูกต้อง',
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant, height: 1.4),
              ),
              const SizedBox(height: 14),

              // Filters + actions
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: '1', label: Text('ภาคเรียนที่ 1')),
                      ButtonSegment(value: '2', label: Text('ภาคเรียนที่ 2')),
                    ],
                    selected: {_term},
                    onSelectionChanged: (s) {
                      setState(() => _term = s.first);
                      _load();
                    },
                  ),
                  DropdownButton<String>(
                    value: _years.contains(_year) ? _year : null,
                    items: _years.map((y) => DropdownMenuItem(value: y, child: Text('ปีการศึกษา $y'))).toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _year = v);
                      _load();
                    },
                  ),
                  if (widget.apiService.isAdmin)
                    FilledButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('เพิ่มรายวิชา'),
                      onPressed: () => _edit(),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // Summary
              if (!_loading && _error == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _courses.isEmpty
                        ? 'ไม่พบรายวิชาในภาคเรียน $_term/$_year'
                        : 'สอนทั้งหมด ${_courses.length} รายวิชา • ระดับชั้น ${levels.isEmpty ? '-' : levels.join(', ')}',
                    style: const TextStyle(fontWeight: FontWeight.w600, height: 1.4),
                  ),
                ),

              // Body
              Expanded(child: _buildBody(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('โหลดข้อมูลไม่สำเร็จ: $_error', style: TextStyle(color: Colors.red.shade700)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('ลองใหม่')),
          ],
        ),
      );
    }
    if (_courses.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined, size: 40, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text('ครูท่านนี้ยังไม่มีรายวิชาในภาคเรียนนี้', style: TextStyle(color: Colors.grey.shade700)),
            const SizedBox(height: 4),
            Text('กด "เพิ่มรายวิชา" หรือเลือกภาคเรียน/ปีการศึกษาอื่น',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
      );
    }

    const headStyle = TextStyle(fontWeight: FontWeight.bold, fontSize: 12);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: Colors.grey.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: const Row(
              children: [
                SizedBox(width: 70, child: Text('ระดับชั้น', style: headStyle)),
                SizedBox(width: 90, child: Text('รหัสวิชา', style: headStyle)),
                Expanded(child: Text('ชื่อรายวิชา', style: headStyle)),
                SizedBox(width: 70, child: Text('หน่วยกิต', style: headStyle, textAlign: TextAlign.center)),
                SizedBox(width: 70, child: Text('นักเรียน', style: headStyle, textAlign: TextAlign.center)),
                SizedBox(width: 96, child: Text('จัดการ', style: headStyle, textAlign: TextAlign.center)),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _courses.length,
              separatorBuilder: (_, i) => Divider(height: 1, color: Colors.grey.shade200),
              itemBuilder: (_, i) {
                final c = _courses[i];
                final lvl = (c['class_level'] ?? '').toString();
                final lvlValid = _levels.contains(lvl);
                final isAdmin = widget.apiService.isAdmin;
                return InkWell(
                  onTap: isAdmin ? () => _edit(c) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 70,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: lvlValid ? Colors.teal.shade50 : Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: lvlValid ? Colors.teal.shade200 : Colors.orange.shade300),
                              ),
                              child: Text(
                                lvl.isEmpty ? '?' : lvl,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: lvlValid ? Colors.teal.shade900 : Colors.orange.shade900,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 90,
                          child: Text(
                            c['course_code']?.toString() ?? '',
                            style: TextStyle(fontWeight: FontWeight.w600, color: theme.colorScheme.primary),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            c['course_name']?.toString() ?? '',
                            style: const TextStyle(height: 1.4),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          width: 70,
                          child: Text(
                            c['credits']?.toString() ?? '-',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                          ),
                        ),
                        SizedBox(
                          width: 70,
                          child: Text(
                            '${c['student_count'] ?? 0}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                          ),
                        ),
                        SizedBox(
                          width: 96,
                          child: isAdmin
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      tooltip: 'แก้ไขรายวิชา',
                                      icon: Icon(Icons.edit_outlined, size: 18, color: Colors.indigo.shade700),
                                      onPressed: () => _edit(c),
                                    ),
                                    IconButton(
                                      tooltip: 'ลบรายวิชา',
                                      icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade600),
                                      onPressed: () => _delete(c),
                                    ),
                                  ],
                                )
                              : const Center(
                                  child: Text('-', style: TextStyle(color: Colors.grey)),
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
