import re

file_path = 'frontend/lib/screens/scores_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update build method to start with LayoutBuilder
target1 = """    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.isDialog) ...[
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.fact_check_rounded, color: cs.primary, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'บันทึกและตรวจคะแนน: ${_selectedCourse?.courseName ?? widget.initialCourse?.courseName ?? ""} (${_selectedCourse?.courseCode ?? widget.initialCourse?.courseCode ?? ""})',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'ระดับชั้น: ${_selectedCourse?.classLevel ?? widget.initialCourse?.classLevel ?? "-"} | ภาคเรียนที่ ${_selectedCourse?.term ?? widget.initialCourse?.term ?? ""}/${_selectedCourse?.year ?? widget.initialCourse?.year ?? ""} | ครูผู้สอน: ${_selectedCourse?.teacher ?? widget.initialCourse?.teacher ?? "-"}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'ปิดหน้าต่าง',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(height: 24),
          ],
          // ===================================================================
          // Header & Primary Actions
          // ===================================================================
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'บันทึกคะแนนตามตัวชี้วัด / ผลการเรียนรู้ (ปพ.5 แผ่นที่ 4)',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'แสดงและแก้ไขคะแนนจาก SGS หรือกรอกคะแนนใหม่ พร้อมเชื่อมสถานะเวลาเรียน (<80% สีส้มอ่อน, <60% สีแดงอ่อน)',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  App3DButton.secondary(
                    onPressed: _selectedCourse == null || _saving ? null : _downloadExcel,
                    icon: Icons.table_view_outlined,
                    label: 'ดาวน์โหลด Excel ปพ.5',
                    depth: 3.0,
                  ),
                  _hasUnsavedChanges
                      ? App3DButton.success(
                          onPressed: _selectedCourse == null || _saving ? null : _saveScores,
                          icon: Icons.save_outlined,
                          label: _saving ? 'กำลังบันทึก...' : 'บันทึกคะแนน & อัปเดตไฟล์ ปพ.5 *',
                          isLoading: _saving,
                          depth: 3.5,
                        )
                      : App3DButton.primary(
                          onPressed: _selectedCourse == null || _saving ? null : _saveScores,
                          icon: Icons.save_outlined,
                          label: _saving ? 'กำลังบันทึก...' : 'บันทึกคะแนน & อัปเดตไฟล์ ปพ.5',
                          isLoading: _saving,
                          depth: 3.5,
                        ),
                ],
              ),
            ],
          ),"""

replace1 = """    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 750;
        final isMobile = constraints.maxWidth < 500;
        final hPad = isMobile ? 12.0 : (isNarrow ? 16.0 : 24.0);
        final vPad = isMobile ? 12.0 : (isNarrow ? 16.0 : 24.0);

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.isDialog) ...[
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.fact_check_rounded, color: cs.primary, size: isMobile ? 20 : 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'บันทึกและตรวจคะแนน: ${_selectedCourse?.courseName ?? widget.initialCourse?.courseName ?? ""} (${_selectedCourse?.courseCode ?? widget.initialCourse?.courseCode ?? ""})',
                            style: (isMobile ? theme.textTheme.titleSmall : theme.textTheme.titleMedium)?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'ระดับชั้น: ${_selectedCourse?.classLevel ?? widget.initialCourse?.classLevel ?? "-"} | ภาคเรียนที่ ${_selectedCourse?.term ?? widget.initialCourse?.term ?? ""}/${_selectedCourse?.year ?? widget.initialCourse?.year ?? ""} | ครูผู้สอน: ${_selectedCourse?.teacher ?? widget.initialCourse?.teacher ?? "-"}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'ปิดหน้าต่าง',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const Divider(height: 24),
              ],
              // ===================================================================
              // Header & Primary Actions (Responsive Layout)
              // ===================================================================
              Builder(
                builder: (context) {
                  final titleBlock = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'บันทึกคะแนนตามตัวชี้วัด / ผลการเรียนรู้ (ปพ.5 แผ่นที่ 4)',
                        style: (isMobile
                                ? theme.textTheme.titleMedium
                                : (isNarrow ? theme.textTheme.titleLarge : theme.textTheme.headlineSmall))
                            ?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'แสดงและแก้ไขคะแนนจาก SGS หรือกรอกคะแนนใหม่ พร้อมเชื่อมสถานะเวลาเรียน (<80% สีส้มอ่อน, <60% สีแดงอ่อน)',
                        style: (isMobile ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ],
                  );

                  final actionButtons = Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      App3DButton.secondary(
                        onPressed: _selectedCourse == null || _saving ? null : _downloadExcel,
                        icon: Icons.table_view_outlined,
                        label: 'ดาวน์โหลด Excel ปพ.5',
                        depth: 3.0,
                      ),
                      _hasUnsavedChanges
                          ? App3DButton.success(
                              onPressed: _selectedCourse == null || _saving ? null : _saveScores,
                              icon: Icons.save_outlined,
                              label: _saving ? 'กำลังบันทึก...' : 'บันทึกคะแนน & อัปเดตไฟล์ ปพ.5 *',
                              isLoading: _saving,
                              depth: 3.5,
                            )
                          : App3DButton.primary(
                              onPressed: _selectedCourse == null || _saving ? null : _saveScores,
                              icon: Icons.save_outlined,
                              label: _saving ? 'กำลังบันทึก...' : 'บันทึกคะแนน & อัปเดตไฟล์ ปพ.5',
                              isLoading: _saving,
                              depth: 3.5,
                            ),
                    ],
                  );

                  if (isNarrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        titleBlock,
                        const SizedBox(height: 12),
                        actionButtons,
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: titleBlock),
                      const SizedBox(width: 16),
                      actionButtons,
                    ],
                  );
                },
              ),"""

# Normalize CRLF in content for matching
content_norm = content.replace('\r\n', '\n')
if target1 in content_norm:
    content_norm = content_norm.replace(target1, replace1, 1)
    print("1. Header & Primary Actions replaced successfully!")
else:
    print("Target 1 NOT found in content_norm!")

# 2. Update Dropdown widths in Filter Bar to be responsive
target2_sem = """                // 1. Semester Dropdown
                SizedBox(
                  width: 240,"""
replace2_sem = """                // 1. Semester Dropdown
                SizedBox(
                  width: isNarrow ? (constraints.maxWidth - (hPad * 2) - (isMobile ? 20 : 28)).clamp(180.0, 500.0) : 240,"""
if target2_sem in content_norm:
    content_norm = content_norm.replace(target2_sem, replace2_sem, 1)
    print("2. Semester Dropdown width updated!")
else:
    print("Target 2_sem NOT found!")

target2_tea = """                // 2. Teacher Dropdown
                SizedBox(
                  width: 250,"""
replace2_tea = """                // 2. Teacher Dropdown
                SizedBox(
                  width: isNarrow ? (constraints.maxWidth - (hPad * 2) - (isMobile ? 20 : 28)).clamp(180.0, 500.0) : 250,"""
if target2_tea in content_norm:
    content_norm = content_norm.replace(target2_tea, replace2_tea, 1)
    print("2. Teacher Dropdown width updated!")
else:
    print("Target 2_tea NOT found!")

target2_cou = """                // 3. Course Dropdown
                SizedBox(
                  width: 340,"""
replace2_cou = """                // 3. Course Dropdown
                SizedBox(
                  width: isNarrow ? (constraints.maxWidth - (hPad * 2) - (isMobile ? 20 : 28)).clamp(180.0, 500.0) : 340,"""
if target2_cou in content_norm:
    content_norm = content_norm.replace(target2_cou, replace2_cou, 1)
    print("2. Course Dropdown width updated!")
else:
    print("Target 2_cou NOT found!")

# 3. Close LayoutBuilder at the end of build method
target3_end = """                        : _buildExcelScoreSheet(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildExcelScoreSheet(ThemeData theme) {"""

replace3_end = """                        : _buildExcelScoreSheet(theme),
          ),
        ],
      ),
    );
      },
    );
  }

  Widget _buildExcelScoreSheet(ThemeData theme) {"""

if target3_end in content_norm:
    content_norm = content_norm.replace(target3_end, replace3_end, 1)
    print("3. LayoutBuilder closed successfully!")
else:
    print("Target 3_end NOT found!")

# 4. Make frozenWidth and column widths in _buildExcelScoreSheet responsive
target4_sheet = """  Widget _buildExcelScoreSheet(ThemeData theme) {
    final cs = theme.colorScheme;
    final headerBg = cs.surfaceContainerHighest;
    final formulaBg = cs.surfaceContainerLow;
    final borderColor = cs.outlineVariant;
    final maxRowBg = cs.primaryContainer.withValues(alpha: 0.35);

    const double frozenWidth = 52 + 80 + 220; // 352px
    const double rightWidth = 480 + 198 + 206 + 68 + 96; // 1048px
    const double rowHeight = 42;"""

replace4_sheet = """  Widget _buildExcelScoreSheet(ThemeData theme) {
    final cs = theme.colorScheme;
    final headerBg = cs.surfaceContainerHighest;
    final formulaBg = cs.surfaceContainerLow;
    final borderColor = cs.outlineVariant;
    final maxRowBg = cs.primaryContainer.withValues(alpha: 0.35);

    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 750;
    final double colNo = isCompact ? 38 : 52;
    final double colId = isCompact ? 68 : 80;
    final double colName = isCompact ? 150 : 220;
    final double frozenWidth = colNo + colId + colName;

    const double rightWidth = 480 + 198 + 206 + 68 + 96; // 1048px
    const double rowHeight = 42;"""

if target4_sheet in content_norm:
    content_norm = content_norm.replace(target4_sheet, replace4_sheet, 1)
    print("4. Sheet column definitions updated!")
else:
    print("Target 4_sheet NOT found!")

# 5. Replace frozen pane cells with colNo, colId, colName
target5_row1 = """                            _headerCell('เลขที่', 52, borderColor),
                            _headerCell('รหัส', 80, borderColor),
                            _headerCell('ชื่อ - สกุล', 220, borderColor, isLast: true),"""
replace5_row1 = """                            _headerCell('เลขที่', colNo, borderColor),
                            _headerCell('รหัส', colId, borderColor),
                            _headerCell('ชื่อ - สกุล', colName, borderColor, isLast: true),"""
if target5_row1 in content_norm:
    content_norm = content_norm.replace(target5_row1, replace5_row1, 1)
    print("5. Row 1 cells updated!")
else:
    print("Target 5_row1 NOT found!")

target5_row2 = """                            _headerCell('', 52, borderColor),
                            _headerCell('นักเรียน', 80, borderColor),
                            _headerCell('(ล็อกชื่อ-สกุลขณะเลื่อนกรอกคะแนน)', 220, borderColor, isLast: true),"""
replace5_row2 = """                            _headerCell('', colNo, borderColor),
                            _headerCell('นักเรียน', colId, borderColor),
                            _headerCell(isCompact ? '(ล็อกชื่อ)' : '(ล็อกชื่อ-สกุลขณะเลื่อนกรอกคะแนน)', colName, borderColor, isLast: true),"""
if target5_row2 in content_norm:
    content_norm = content_norm.replace(target5_row2, replace5_row2, 1)
    print("5. Row 2 cells updated!")
else:
    print("Target 5_row2 NOT found!")

target5_row3 = """                            _headerCell('-', 52, borderColor),
                            _headerCell('-', 80, borderColor),
                            _headerCell('คะแนนเต็ม (แก้ไขได้)', 220, borderColor, alignLeft: true, isLast: true),"""
replace5_row3 = """                            _headerCell('-', colNo, borderColor),
                            _headerCell('-', colId, borderColor),
                            _headerCell(isCompact ? 'คะแนนเต็ม' : 'คะแนนเต็ม (แก้ไขได้)', colName, borderColor, alignLeft: true, isLast: true),"""
if target5_row3 in content_norm:
    content_norm = content_norm.replace(target5_row3, replace5_row3, 1)
    print("5. Row 3 cells updated!")
else:
    print("Target 5_row3 NOT found!")

target5_row4 = """                            _headerCell('-', 52, borderColor),
                            _headerCell('-', 80, borderColor),
                            _headerCell('คะแนนเต็มทั้งหมด (ติ๊กรายช่อง)', 220, borderColor, alignLeft: true, isLast: true),"""
replace5_row4 = """                            _headerCell('-', colNo, borderColor),
                            _headerCell('-', colId, borderColor),
                            _headerCell(isCompact ? 'คะแนนเต็มรวม' : 'คะแนนเต็มทั้งหมด (ติ๊กรายช่อง)', colName, borderColor, alignLeft: true, isLast: true),"""
if target5_row4 in content_norm:
    content_norm = content_norm.replace(target5_row4, replace5_row4, 1)
    print("5. Row 4 cells updated!")
else:
    print("Target 5_row4 NOT found!")

target5_data = """                                    _staticTextCell('${row.studentNo}', 52, borderColor, alignCenter: true),
                                    _staticTextCell(row.studentId, 80, borderColor, alignCenter: true),
                                    _staticTextCell(row.fullName, 220, borderColor, bold: true, isLast: true),"""
replace5_data = """                                    _staticTextCell('${row.studentNo}', colNo, borderColor, alignCenter: true),
                                    _staticTextCell(row.studentId, colId, borderColor, alignCenter: true),
                                    _staticTextCell(row.fullName, colName, borderColor, bold: true, isLast: true),"""
if target5_data in content_norm:
    content_norm = content_norm.replace(target5_data, replace5_data, 1)
    print("5. Student row cells updated!")
else:
    print("Target 5_data NOT found!")

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content_norm)
print("scores_screen.dart updated successfully!")
