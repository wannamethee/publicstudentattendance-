import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../models/process_result.dart';
import '../utils/format_utils.dart';

enum ProcessingState { idle, filesSelected, processing, completed }

class SelectedFileItem {
  final String name;
  final Uint8List bytes;
  final int size;
  String status; // 'pending', 'processing', 'success', 'error'
  String? error;
  ProcessResult? result;

  SelectedFileItem({
    required this.name,
    required this.bytes,
    required this.size,
    this.status = 'pending',
    this.error,
    this.result,
  });
}

class UploadProcessScreen extends StatefulWidget {
  final ApiService apiService;

  const UploadProcessScreen({super.key, required this.apiService});

  @override
  State<UploadProcessScreen> createState() => _UploadProcessScreenState();
}

class _UploadProcessScreenState extends State<UploadProcessScreen> {
  ProcessingState _state = ProcessingState.idle;
  final List<SelectedFileItem> _files = [];
  int _currentIndex = 0;
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _teacherController = TextEditingController();

  @override
  void dispose() {
    _descController.dispose();
    _teacherController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    try {
      final pickedFiles = await FilePicker.pickFiles(
        dialogTitle: 'เลือกไฟล์ SGS PDF (เลือกได้หลายไฟล์พร้อมกัน)',
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (pickedFiles.isEmpty) return;

      final List<SelectedFileItem> newItems = [];
      for (final picked in pickedFiles) {
        // Prevent duplicate filenames in selection
        if (_files.any((f) => f.name == picked.name)) continue;
        final bytes = await picked.readAsBytes();
        newItems.add(SelectedFileItem(
          name: picked.name,
          bytes: bytes,
          size: picked.lengthSync() ?? bytes.length,
        ));
      }

      if (newItems.isNotEmpty) {
        setState(() {
          _files.addAll(newItems);
          if (_state == ProcessingState.idle || _state == ProcessingState.filesSelected) {
            _state = ProcessingState.filesSelected;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('เกิดข้อผิดพลาดในการเลือกไฟล์: $e'),
          ),
        );
      }
    }
  }

  void _removeFile(int index) {
    setState(() {
      _files.removeAt(index);
      if (_files.isEmpty) {
        _state = ProcessingState.idle;
      }
    });
  }

  Future<void> _processBatch() async {
    if (_files.isEmpty) return;

    setState(() {
      _state = ProcessingState.processing;
      _currentIndex = 0;
      for (var f in _files) {
        if (f.status != 'success') {
          f.status = 'pending';
          f.error = null;
        }
      }
    });

    final desc = _descController.text.trim();
    final teacher = _teacherController.text.trim();

    for (int i = 0; i < _files.length; i++) {
      if (_files[i].status == 'success') continue;

      setState(() {
        _currentIndex = i;
        _files[i].status = 'processing';
      });

      try {
        final res = await widget.apiService.uploadAndProcessPdf(
          _files[i].bytes,
          _files[i].name,
          description: desc.isNotEmpty ? desc : null,
          teacher: teacher.isNotEmpty ? teacher : null,
        );
        setState(() {
          _files[i].status = 'success';
          _files[i].result = res;
        });
      } catch (e) {
        setState(() {
          _files[i].status = 'error';
          _files[i].error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }

    setState(() {
      _state = ProcessingState.completed;
    });
  }

  Future<void> _retryFile(int index) async {
    final item = _files[index];
    setState(() {
      item.status = 'processing';
      item.error = null;
    });

    try {
      final desc = _descController.text.trim();
      final teacher = _teacherController.text.trim();
      final res = await widget.apiService.uploadAndProcessPdf(
        item.bytes,
        item.name,
        description: desc.isNotEmpty ? desc : null,
        teacher: teacher.isNotEmpty ? teacher : null,
      );
      setState(() {
        item.status = 'success';
        item.result = res;
      });
    } catch (e) {
      setState(() {
        item.status = 'error';
        item.error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _reset() {
    setState(() {
      _state = ProcessingState.idle;
      _files.clear();
      _currentIndex = 0;
      _descController.clear();
      _teacherController.clear();
    });
  }

  Future<void> _openDownload(String filename) async {
    final url = widget.apiService.getDownloadUrl(filename);
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final descText = _descController.text;
    final estLines = calculateEstimatedLines(descText);
    final fontSize = calculateRecommendedFontSize(descText);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title
              Text(
                'แปลงไฟล์ SGS เป็น ปพ.5 (รองรับการอัปโหลดหลายไฟล์พร้อมกัน)',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'เลือกไฟล์ SGS PDF ครั้งละหนึ่งหรือหลายไฟล์พร้อมกัน ระบบจะแกะข้อมูล บันทึกลงฐานข้อมูล และสร้างเอกสาร ปพ.5 ทั้ง Excel และ PDF อัตโนมัติ',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),

              // Upload Dropzone
              _buildUploadZone(theme),

              // File list & actions
              if (_files.isNotEmpty) ...[
                const SizedBox(height: 20),
                _buildFileListSection(theme),
              ],

              // Course Description input (only before or after processing)
              if (_state == ProcessingState.filesSelected) ...[
                const SizedBox(height: 20),
                _buildCourseDescriptionBox(theme, descText, estLines, fontSize),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _processBatch,
                  icon: const Icon(Icons.play_arrow_rounded, size: 24),
                  label: Text('เริ่มแปลงไฟล์ทั้งหมด (${_files.length} ไฟล์)'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],

              // Batch Processing Progress Bar
              if (_state == ProcessingState.processing) ...[
                const SizedBox(height: 24),
                _buildProcessingProgress(theme),
              ],

              // Completed Summary and Batch Downloads
              if (_state == ProcessingState.completed) ...[
                const SizedBox(height: 24),
                _buildCompletedSummary(theme),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUploadZone(ThemeData theme) {
    final canPick = _state != ProcessingState.processing;
    return InkWell(
      onTap: canPick ? _pickFiles : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
        decoration: BoxDecoration(
          color: _files.isNotEmpty
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _files.isNotEmpty
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: 2,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _files.isNotEmpty ? Icons.folder_zip_rounded : Icons.cloud_upload_outlined,
              size: 56,
              color: _files.isNotEmpty
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              _files.isNotEmpty
                  ? 'เลือกไว้แล้ว ${_files.length} ไฟล์ (คลิกเพื่อเลือกไฟล์เพิ่ม)'
                  : 'คลิกเพื่อเลือกไฟล์ SGS PDF (เลือกได้หลายไฟล์พร้อมกัน)',
              style: theme.textTheme.titleMedium?.copyWith(
                color: _files.isNotEmpty
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'รองรับไฟล์ .pdf จากระบบ SGS (สามารถกด Ctrl/Shift เพื่อเลือกหลายไฟล์ได้พร้อมกัน)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileListSection(ThemeData theme) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.list_alt_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'รายการไฟล์ที่เลือก (${_files.length} ไฟล์)',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (_state != ProcessingState.processing) ...[
                  OutlinedButton.icon(
                    onPressed: _pickFiles,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('เพิ่มไฟล์'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: const Text('ล้างทั้งหมด'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ],
            ),
            const Divider(height: 20),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _files.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final file = _files[index];
                return _buildFileItemRow(theme, file, index);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileItemRow(ThemeData theme, SelectedFileItem file, int index) {
    Widget statusBadge;
    switch (file.status) {
      case 'processing':
        statusBadge = const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        );
        break;
      case 'success':
        statusBadge = const Icon(Icons.check_circle, color: Colors.green, size: 24);
        break;
      case 'error':
        statusBadge = const Icon(Icons.error, color: Colors.red, size: 24);
        break;
      default:
        statusBadge = Icon(Icons.schedule, color: Colors.grey.shade400, size: 22);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          statusBadge,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      'ขนาด: ${(file.size / 1024).toStringAsFixed(1)} KB',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    if (file.status == 'success' && file.result != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Text(
                          'วิชา: ${file.result!.courseCode ?? "-"} | นักเรียน: ${file.result!.totalStudents} คน',
                          style: TextStyle(fontSize: 11, color: Colors.green.shade800, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                    if (file.status == 'error' && file.error != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          file.error!,
                          style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Action buttons per row
          if (file.status == 'success' && file.result != null) ...[
            FilledButton.tonalIcon(
              onPressed: () => _openDownload(file.result!.excelFilename),
              icon: const Icon(Icons.table_chart, size: 14),
              label: const Text('Excel', style: TextStyle(fontSize: 11)),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: () => _openDownload(file.result!.pdfFilename),
              icon: const Icon(Icons.picture_as_pdf, size: 14),
              label: const Text('PDF', style: TextStyle(fontSize: 11)),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
            ),
          ] else if (file.status == 'error' && _state != ProcessingState.processing) ...[
            OutlinedButton.icon(
              onPressed: () => _retryFile(index),
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('ลองใหม่', style: TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ] else if (_state != ProcessingState.processing) ...[
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => _removeFile(index),
              tooltip: 'ลบไฟล์นี้',
              color: Colors.grey.shade600,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCourseDescriptionBox(ThemeData theme, String descText, int estLines, int fontSize) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.edit_note_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'คำอธิบายรายวิชาและตัวชี้วัด (แผ่น 6 ตัวชี้วัด)',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'หากต้องการระบุคำอธิบายรายวิชาและตัวชี้วัดล่วงหน้า (สามารถแก้ไขแยกทีหลังในคลัง ปพ.5 ได้เช่นกัน) '
              'ระบบจะคำนวณขนาดตัวอักษรให้อัตโนมัติเพื่อแสดงพอดีในกรอบเส้น A4 ทั้ง Excel และ PDF',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descController,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'วางหรือพิมพ์คำอธิบายรายวิชา และตัวชี้วัด / ผลการเรียนรู้ ที่นี่ (ไม่บังคับ)...',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(12),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.format_size_rounded, size: 18, color: Colors.grey.shade700),
                  const SizedBox(width: 8),
                  Text(
                    'ความยาว: ${descText.length} ตัวอักษร (~$estLines บรรทัด)',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      border: Border.all(color: Colors.teal.shade400),
                    ),
                    child: Text(
                      'ขนาดฟอนต์อัตโนมัติ: $fontSize pt',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.teal.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingProgress(ThemeData theme) {
    final successCount = _files.where((f) => f.status == 'success').length;
    final progress = (_currentIndex + 1) / _files.length;
    final currentFileName = _files.isNotEmpty && _currentIndex < _files.length
        ? _files[_currentIndex].name
        : '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'กำลังประมวลผลไฟล์ที่ ${_currentIndex + 1} จากทั้งหมด ${_files.length} (${(progress * 100).toInt()}%)',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              currentFileName,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 8),
            Text(
              'แกะข้อมูล PDF → บันทึกฐานข้อมูล → สร้าง Excel ปพ.5 → ส่งออก PDF พร้อมพิมพ์',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'สำเร็จแล้ว: $successCount ไฟล์',
              style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletedSummary(ThemeData theme) {
    final successFiles = _files.where((f) => f.status == 'success').toList();
    final errorFiles = _files.where((f) => f.status == 'error').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary Card
        Card(
          color: (errorFiles.isEmpty)
              ? Colors.green.shade50
              : Colors.amber.shade50,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: (errorFiles.isEmpty) ? Colors.green.shade300 : Colors.amber.shade300,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(
                  (errorFiles.isEmpty) ? Icons.check_circle_rounded : Icons.info_rounded,
                  size: 48,
                  color: (errorFiles.isEmpty) ? Colors.green.shade700 : Colors.amber.shade900,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'แปลงไฟล์เสร็จสิ้นเรียบร้อย',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: (errorFiles.isEmpty) ? Colors.green.shade900 : Colors.amber.shade900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'สำเร็จ ${successFiles.length} ไฟล์ จากทั้งหมด ${_files.length} ไฟล์'
                        '${errorFiles.isNotEmpty ? ' (พบข้อผิดพลาด ${errorFiles.length} ไฟล์)' : ''}',
                        style: TextStyle(
                          fontSize: 13,
                          color: (errorFiles.isEmpty) ? Colors.green.shade800 : Colors.amber.shade900,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.replay),
                  label: const Text('แปลงชุดใหม่'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
