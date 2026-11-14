import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

enum CropAction { save, again, skip, cancel }

class CropResult {
  final CropAction action;
  final Uint8List? bytes; // the framed photo (PNG 480x640) when action == save
  const CropResult(this.action, [this.bytes]);
}

/// จัดรูปให้อยู่ในกรอบ แบบรูปโปรไฟล์ Facebook: ลากเพื่อเลื่อน, ล้อเมาส์ / สองนิ้ว / แถบเลื่อน เพื่อซูม,
/// นอกกรอบมืดลง • กรอบแนวตั้ง 3:4 (รูปติดบัตร) • ผลลัพธ์ = เฉพาะส่วนในกรอบ (PNG 480x640)
Future<CropResult> showPhotoCropper(
  BuildContext context, {
  required Uint8List bytes,
  required String title,
  String? subtitle,
  String? againLabel = 'เลือกใหม่', // null = no "again" button (re-framing the photo already saved)
  bool allowSkip = false,
}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  if (!context.mounted) {
    image.dispose();
    return const CropResult(CropAction.cancel);
  }
  final r = await showDialog<CropResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CropperDialog(
      image: image,
      title: title,
      subtitle: subtitle,
      againLabel: againLabel,
      allowSkip: allowSkip,
    ),
  );
  image.dispose();
  return r ?? const CropResult(CropAction.cancel);
}

class _CropperDialog extends StatefulWidget {
  final ui.Image image;
  final String title;
  final String? subtitle;
  final String? againLabel;
  final bool allowSkip;

  const _CropperDialog({
    required this.image,
    required this.title,
    required this.subtitle,
    required this.againLabel,
    required this.allowSkip,
  });

  @override
  State<_CropperDialog> createState() => _CropperDialogState();
}

class _CropperDialogState extends State<_CropperDialog> {
  static const double _aspect = 3 / 4; // width / height of the frame
  static const double _pad = 34; // dimmed margin around the frame
  static const double _maxZoom = 5;
  static const int _outW = 480, _outH = 640;

  double _zoom = 1; // 1 = the photo just covers the frame
  late Offset _center; // the photo pixel shown at the middle of the frame
  double _fw = 270, _fh = 360; // frame size on screen (set by the layout)
  double _lastScale = 1;
  bool _saving = false;

  double get _iw => widget.image.width.toDouble();
  double get _ih => widget.image.height.toDouble();
  double get _base => math.max(_fw / _iw, _fh / _ih);
  double get _s => _base * _zoom; // screen px per photo px

  @override
  void initState() {
    super.initState();
    _zoom = 1;
    // like the server's automatic crop: centred left-right, more room kept above (faces sit high)
    final s = math.max(_fw / _iw, _fh / _ih);
    final visibleH = _fh / s;
    _center = Offset(_iw / 2, (_ih - visibleH) * 0.3 + visibleH / 2);
  }

  Offset _clamp(Offset c, double s) {
    final hw = _fw / (2 * s), hh = _fh / (2 * s);
    return Offset(c.dx.clamp(hw, math.max(hw, _iw - hw)), c.dy.clamp(hh, math.max(hh, _ih - hh)));
  }

  /// zoom to [z] keeping the photo point under [focal] (frame coordinates) where it is
  void _zoomTo(double z, Offset focal) {
    z = z.clamp(1.0, _maxZoom);
    final fc = Offset(_fw / 2, _fh / 2);
    final s1 = _s, s2 = _base * z;
    final p = _center + (focal - fc) / s1;
    setState(() {
      _zoom = z;
      _center = _clamp(p - (focal - fc) / s2, s2);
    });
  }

  void _pan(Offset delta) {
    setState(() => _center = _clamp(_center - delta / _s, _s));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final s = _s;
      final src = Rect.fromCenter(center: _center, width: _fw / s, height: _fh / s);
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(
        widget.image,
        src,
        Rect.fromLTWH(0, 0, _outW.toDouble(), _outH.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
      final pic = rec.endRecording();
      final img = await pic.toImage(_outW, _outH);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      pic.dispose();
      if (mounted) Navigator.of(context).pop(CropResult(CropAction.save, data!.buffer.asUint8List()));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ตัดรูปไม่สำเร็จ: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              if (widget.subtitle != null)
                Text(widget.subtitle!, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, c) {
                final screenH = MediaQuery.of(context).size.height;
                // the frame grows with the space: at most 300x400, smaller on a phone or a short window
                final fh = math.min(400.0, math.min((c.maxWidth - 2 * _pad) / _aspect, screenH - 330)).clamp(180.0, 400.0);
                final fw = fh * _aspect;
                if ((fw - _fw).abs() > 0.5) {
                  // keep the same framing when the size changes (the zoom is relative to the frame)
                  _fw = fw;
                  _fh = fh;
                  _center = _clamp(_center, _s);
                }
                return Center(child: _viewport());
              }),
              const SizedBox(height: 6),
              Row(
                children: [
                  IconButton(
                    tooltip: 'ซูมออก',
                    icon: const Icon(Icons.zoom_out_rounded),
                    onPressed: () => _zoomTo(_zoom / 1.2, Offset(_fw / 2, _fh / 2)),
                  ),
                  Expanded(
                    child: Slider(
                      value: _zoom,
                      min: 1,
                      max: _maxZoom,
                      onChanged: (v) => _zoomTo(v, Offset(_fw / 2, _fh / 2)),
                    ),
                  ),
                  IconButton(
                    tooltip: 'ซูมเข้า',
                    icon: const Icon(Icons.zoom_in_rounded),
                    onPressed: () => _zoomTo(_zoom * 1.2, Offset(_fw / 2, _fh / 2)),
                  ),
                ],
              ),
              Text('ลากเพื่อเลื่อนรูป • หมุนล้อเมาส์ ใช้สองนิ้ว หรือแถบเลื่อนเพื่อซูม • ให้ใบหน้าอยู่ในวงรี',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(const CropResult(CropAction.cancel)),
                    child: const Text('ยกเลิก'),
                  ),
                  if (widget.allowSkip)
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.of(context).pop(const CropResult(CropAction.skip)),
                      child: const Text('ข้ามคนนี้'),
                    ),
                  if (widget.againLabel != null)
                    OutlinedButton(
                      onPressed: _saving ? null : () => Navigator.of(context).pop(const CropResult(CropAction.again)),
                      child: Text(widget.againLabel!),
                    ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B0B38)),
                    icon: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_rounded, size: 18),
                    label: const Text('บันทึกรูป'),
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _viewport() {
    final vw = _fw + 2 * _pad, vh = _fh + 2 * _pad;
    final s = _s;
    final left = _pad + _fw / 2 - _center.dx * s;
    final top = _pad + _fh / 2 - _center.dy * s;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: vw,
        height: vh,
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                final factor = e.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1;
                _zoomTo(_zoom * factor, e.localPosition - const Offset(_pad, _pad));
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (_) => _lastScale = 1,
              onScaleUpdate: (d) {
                if (d.pointerCount > 1 && d.scale != _lastScale) {
                  _zoomTo(_zoom * d.scale / _lastScale, d.localFocalPoint - const Offset(_pad, _pad));
                  _lastScale = d.scale;
                }
                _pan(d.focalPointDelta);
              },
              child: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Color(0xFF111111))),
                  Positioned(
                    left: left,
                    top: top,
                    width: _iw * s,
                    height: _ih * s,
                    child: RawImage(image: widget.image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(child: CustomPaint(painter: _FramePainter(Rect.fromLTWH(_pad, _pad, _fw, _fh)))),
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

/// Dims everything outside the frame, draws its border, thirds and an oval where the face goes.
class _FramePainter extends CustomPainter {
  final Rect frame;
  _FramePainter(this.frame);

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.62));
    final thin = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3, y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), thin);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), thin);
    }
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(frame.center.dx, frame.top + frame.height * 0.40),
        width: frame.width * 0.56,
        height: frame.height * 0.52,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: 0.7),
    );
    canvas.drawRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.frame != frame;
}
