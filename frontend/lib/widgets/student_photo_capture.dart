import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import 'student_photo_cropper.dart';
import 'webcam/webcam.dart';

enum PhotoResult { saved, skipped, cancelled }

class _Got {
  final Uint8List? bytes;
  final bool skip;
  const _Got.bytes(this.bytes) : skip = false;
  const _Got.skip()
      : bytes = null,
        skip = true;
  const _Got.cancel()
      : bytes = null,
        skip = false;
}

bool get _isPhone => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// รูปของนักเรียนคนเดียว: "ถ่ายจากกล้อง" (มือถือ = กล้องหลัง, คอมพิวเตอร์ = เว็บแคม) หรือ "เลือกรูปจากเครื่อง"
/// -> จัดรูปให้อยู่ในกรอบ (ลาก/ซูม แบบรูปโปรไฟล์) -> บันทึก (แทนรูปเดิม)
/// [source] given = skip the choice (the class camera run); [progress] e.g. "คนที่ 3/14" adds "ข้ามคนนี้".
/// สิทธิ์: ผู้ดูแลระบบ / ครูประจำชั้นของนักเรียนคนนั้น (เซิร์ฟเวอร์ตรวจ)
Future<PhotoResult> pickAndUploadStudentPhoto(
  BuildContext context, {
  required ApiService apiService,
  required String studentId,
  required String studentName,
  required String term,
  required String year,
  ImageSource? source,
  String? progress,
  bool quiet = false,
}) async {
  final inRun = progress != null;
  ImageSource? src = source;
  while (true) {
    if (!context.mounted) return PhotoResult.cancelled;
    src ??= await _chooseSource(context, studentName);
    if (src == null || !context.mounted) return PhotoResult.cancelled;

    final title = inRun ? '$progress • $studentName' : 'รูปของ $studentName';
    final got = await _acquire(context, src, title, allowSkip: inRun);
    if (got.skip) return PhotoResult.skipped;
    final bytes = got.bytes;
    if (bytes == null || !context.mounted) return PhotoResult.cancelled;

    final CropResult crop;
    try {
      crop = await showPhotoCropper(
        context,
        bytes: bytes,
        title: 'จัดรูปให้อยู่ในกรอบ',
        subtitle: '$studentName • $studentId',
        againLabel: src == ImageSource.camera ? 'ถ่ายใหม่' : 'เลือกใหม่',
        allowSkip: inRun,
      );
    } catch (e) {
      if (context.mounted) _snack(context, 'เปิดรูปนี้ไม่ได้ (ไม่ใช่ไฟล์รูป หรือเป็นชนิดที่เบราว์เซอร์ไม่รองรับ)', error: true);
      continue;
    }
    if (!context.mounted) return PhotoResult.cancelled;
    switch (crop.action) {
      case CropAction.cancel:
        return PhotoResult.cancelled;
      case CropAction.skip:
        return PhotoResult.skipped;
      case CropAction.again:
        continue;
      case CropAction.save:
        break;
    }

    try {
      final res = await apiService.uploadStudentPhoto(studentId, crop.bytes!, '$studentId.png', term: term, year: year);
      if (context.mounted && !quiet) _snack(context, res['message']?.toString() ?? 'บันทึกรูปนักเรียนแล้ว');
      return PhotoResult.saved;
    } catch (e) {
      if (context.mounted) _snack(context, e.toString().replaceFirst('Exception: ', ''), error: true);
      return PhotoResult.cancelled;
    }
  }
}

String _cameraHint() => _isPhone
    ? 'เปิดกล้องหลังของเครื่อง'
    : webcamAvailable()
        ? 'ใช้กล้องเว็บแคมของคอมพิวเตอร์'
        : 'ใช้กล้องของคอมพิวเตอร์ได้เมื่อเปิดผ่านลิงก์ https หรือที่เครื่องเซิร์ฟเวอร์';

enum _EditChoice { camera, gallery, reframe, delete }

/// ปุ่ม "แก้ไขรูป" (นักเรียนที่มีรูปแล้ว): ถ่ายรูปใหม่ / เลือกรูปใหม่ / จัดตำแหน่ง-ซูมรูปเดิม / ลบรูป (กรณีใส่ผิด)
/// Returns true when the photo was replaced, re-framed or deleted, so the caller reloads it.
Future<bool> editStudentPhoto(
  BuildContext context, {
  required ApiService apiService,
  required String studentId,
  required String studentName,
  required String term,
  required String year,
  required dynamic version,
}) async {
  final url = apiService.studentPhotoUrl(studentId, version);
  Widget option(BuildContext ctx, _EditChoice c, IconData icon, Color color, String title, String sub) => SimpleDialogOption(
        onPressed: () => Navigator.of(ctx).pop(c),
        child: ListTile(
          leading: Icon(icon, color: color),
          title: Text(title, style: c == _EditChoice.delete ? TextStyle(color: color, fontWeight: FontWeight.w600) : null),
          subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
        ),
      );
  final choice = await showDialog<_EditChoice>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.network(url, width: 42, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(width: 42, height: 56)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('แก้ไขรูป', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text('$studentName • $studentId', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
          ]),
        ),
      ]),
      children: [
        option(ctx, _EditChoice.camera, Icons.photo_camera_rounded, const Color(0xFF6B21A8), 'ถ่ายรูปใหม่', _cameraHint()),
        option(ctx, _EditChoice.gallery, Icons.photo_library_rounded, const Color(0xFF0F766E), 'เลือกรูปใหม่จากเครื่อง',
            'แทนรูปเดิม'),
        option(ctx, _EditChoice.reframe, Icons.crop_rounded, const Color(0xFF1D4ED8), 'จัดตำแหน่ง / ซูมรูปเดิม',
            'ลากและซูมรูปที่มีอยู่ให้ใบหน้าอยู่กลางกรอบ'),
        const Divider(height: 10),
        option(ctx, _EditChoice.delete, Icons.delete_outline_rounded, Colors.red.shade700, 'ลบรูปนี้',
            'กรณีใส่รูปผิดคน • อัปโหลดใหม่ได้ภายหลัง'),
      ],
    ),
  );
  if (choice == null || !context.mounted) return false;
  switch (choice) {
    case _EditChoice.camera:
    case _EditChoice.gallery:
      final r = await pickAndUploadStudentPhoto(
        context,
        apiService: apiService,
        studentId: studentId,
        studentName: studentName,
        term: term,
        year: year,
        source: choice == _EditChoice.camera ? ImageSource.camera : ImageSource.gallery,
      );
      return r == PhotoResult.saved;
    case _EditChoice.reframe:
      return _reframe(context, apiService, studentId, studentName, term, year, version);
    case _EditChoice.delete:
      return _deletePhoto(context, apiService, studentId, studentName, term, year);
  }
}

/// The saved photo back in the frame: zoom in / move it (it cannot zoom out past the saved picture).
Future<bool> _reframe(BuildContext context, ApiService api, String studentId, String studentName, String term,
    String year, dynamic version) async {
  try {
    final bytes = await api.getStudentPhotoBytes(studentId, version);
    if (!context.mounted) return false;
    final crop = await showPhotoCropper(
      context,
      bytes: bytes,
      title: 'จัดตำแหน่ง / ซูมรูปเดิม',
      subtitle: '$studentName • $studentId',
      againLabel: null,
    );
    if (crop.action != CropAction.save || !context.mounted) return false;
    final res = await api.uploadStudentPhoto(studentId, crop.bytes!, '$studentId.png', term: term, year: year);
    if (context.mounted) _snack(context, res['message']?.toString() ?? 'บันทึกรูปนักเรียนแล้ว');
    return true;
  } catch (e) {
    if (context.mounted) _snack(context, e.toString().replaceFirst('Exception: ', ''), error: true);
    return false;
  }
}

Future<bool> _deletePhoto(
    BuildContext context, ApiService api, String studentId, String studentName, String term, String year) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.delete_outline_rounded, color: Colors.red.shade700),
      title: const Text('ลบรูปนักเรียน?'),
      content: Text('ลบรูปของ $studentName ($studentId) ออกจากระบบ\nอัปโหลดหรือถ่ายรูปใหม่ได้ภายหลัง'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('ยกเลิก')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('ลบรูป'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  try {
    final msg = await api.deleteStudentPhoto(studentId, term: term, year: year);
    if (context.mounted) _snack(context, msg);
    return true;
  } catch (e) {
    if (context.mounted) _snack(context, e.toString().replaceFirst('Exception: ', ''), error: true);
    return false;
  }
}

Future<ImageSource?> _chooseSource(BuildContext context, String studentName) {
  final cam = _cameraHint();
  return showDialog<ImageSource>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('รูปของ $studentName', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(ImageSource.camera),
          child: ListTile(
            leading: const Icon(Icons.photo_camera_rounded, color: Color(0xFF6B21A8)),
            title: const Text('ถ่ายจากกล้อง'),
            subtitle: Text(cam, style: const TextStyle(fontSize: 12)),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(ImageSource.gallery),
          child: const ListTile(
            leading: Icon(Icons.photo_library_rounded, color: Color(0xFF0F766E)),
            title: Text('เลือกรูปจากเครื่อง'),
            subtitle: Text('รูปในเครื่อง / แกลเลอรี', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    ),
  );
}

/// The raw photo: phone camera / computer webcam / a file on the device.
Future<_Got> _acquire(BuildContext context, ImageSource src, String title, {required bool allowSkip}) async {
  if (src == ImageSource.camera && !_isPhone) {
    if (webcamAvailable()) {
      WebcamSession? cam;
      try {
        cam = await openWebcam();
      } on WebcamError catch (e) {
        if (!context.mounted) return const _Got.cancel();
        return _cameraProblem(context, e.message);
      }
      try {
        if (!context.mounted) return const _Got.cancel();
        return await showDialog<_Got>(
              context: context,
              barrierDismissible: false,
              builder: (_) => _WebcamDialog(session: cam!, title: title, allowSkip: allowSkip),
            ) ??
            const _Got.cancel();
      } finally {
        cam.close();
      }
    }
    return _cameraProblem(context, webcamUnavailableReason());
  }
  return _pick(context, src);
}

Future<_Got> _pick(BuildContext context, ImageSource src) async {
  try {
    // shrunk in the browser first: a 12 MP phone photo becomes a few hundred KB, upright
    final f = await ImagePicker().pickImage(
      source: src,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 92,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (f == null) return const _Got.cancel();
    return _Got.bytes(await f.readAsBytes());
  } catch (e) {
    if (context.mounted) _snack(context, 'เปิดกล้อง/รูปไม่ได้: ${e.toString().replaceFirst('Exception: ', '')}', error: true);
    return const _Got.cancel();
  }
}

Future<_Got> _cameraProblem(BuildContext context, String message) async {
  final pickFile = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.videocam_off_rounded, color: Colors.orange.shade800),
      title: const Text('ใช้กล้องไม่ได้'),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('ปิด')),
        FilledButton.icon(
          icon: const Icon(Icons.photo_library_rounded, size: 18),
          label: const Text('เลือกรูปจากเครื่องแทน'),
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  if (pickFile != true || !context.mounted) return const _Got.cancel();
  return _pick(context, ImageSource.gallery);
}

/// Live webcam with a 3:4 guide; Space / Enter or the button takes the picture.
class _WebcamDialog extends StatefulWidget {
  final WebcamSession session;
  final String title;
  final bool allowSkip;
  const _WebcamDialog({required this.session, required this.title, required this.allowSkip});

  @override
  State<_WebcamDialog> createState() => _WebcamDialogState();
}

class _WebcamDialogState extends State<_WebcamDialog> {
  Timer? _poll;
  bool _ready = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final r = widget.session.ready;
      if (r != _ready && mounted) setState(() => _ready = r);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _shoot() async {
    if (!_ready || _busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await widget.session.capture();
      if (mounted) Navigator.of(context).pop(_Got.bytes(bytes));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _shoot,
        const SingleActivator(LogicalKeyboardKey.enter): _shoot,
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const Icon(Icons.videocam_rounded, color: Color(0xFF6B21A8)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          HtmlElementView(viewType: widget.session.viewType),
                          IgnorePointer(child: CustomPaint(painter: _GuidePainter())),
                          if (!_ready)
                            const Center(
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                CircularProgressIndicator(color: Colors.white),
                                SizedBox(height: 8),
                                Text('กำลังเปิดกล้อง...', style: TextStyle(color: Colors.white)),
                              ]),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('ให้ใบหน้าอยู่ในกรอบ แล้วกด "ถ่ายภาพ" (หรือกด Space) • จัดตำแหน่งละเอียดได้อีกครั้งหลังถ่าย',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      TextButton(onPressed: () => Navigator.of(context).pop(const _Got.cancel()), child: const Text('ยกเลิก')),
                      if (widget.allowSkip)
                        TextButton(onPressed: () => Navigator.of(context).pop(const _Got.skip()), child: const Text('ข้ามคนนี้')),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6B21A8)),
                        icon: const Icon(Icons.camera_rounded, size: 20),
                        label: const Text('ถ่ายภาพ'),
                        onPressed: _ready && !_busy ? _shoot : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 3:4 frame and a face oval over the live picture
class _GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height * 0.92, w = h * 3 / 4;
    final frame = Rect.fromCenter(center: size.center(Offset.zero), width: w, height: h);
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(frame),
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawRect(frame, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.9));
    canvas.drawOval(
      Rect.fromCenter(center: Offset(frame.center.dx, frame.top + h * 0.40), width: w * 0.56, height: h * 0.52),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(_GuidePainter old) => false;
}

void _snack(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(backgroundColor: error ? Colors.red.shade700 : Colors.teal.shade700, content: Text(text)),
  );
}
