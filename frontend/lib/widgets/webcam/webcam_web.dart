import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'webcam_types.dart';

/// Browsers give the camera only to secure pages: https (the online link) or the server PC itself
/// (localhost). A page opened as http://(IP):8000 on the school network has no navigator.mediaDevices.
bool webcamAvailable() {
  try {
    return web.window.isSecureContext && (web.window.navigator as JSObject).has('mediaDevices');
  } catch (_) {
    return false;
  }
}

String webcamUnavailableReason() =>
    'เบราว์เซอร์อนุญาตให้ใช้กล้องของคอมพิวเตอร์เฉพาะเมื่อเปิดระบบผ่านลิงก์ https:// (ลิงก์ออนไลน์) '
    'หรือเปิดที่เครื่องเซิร์ฟเวอร์ (localhost) • ตอนนี้เปิดผ่าน http จึงใช้กล้องไม่ได้';

int _views = 0;

Future<WebcamSession> openWebcam() async {
  if (!webcamAvailable()) throw WebcamError(webcamUnavailableReason());
  final web.MediaStream stream;
  try {
    stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(
          video: {
            'width': {'ideal': 1280},
            'height': {'ideal': 960},
            'facingMode': 'user',
          }.jsify()!,
          audio: false.toJS,
        ))
        .toDart;
  } catch (e) {
    final s = e.toString();
    if (s.contains('NotAllowed') || s.contains('Permission')) {
      throw WebcamError('ไม่ได้รับอนุญาตให้ใช้กล้อง: กดรูปกล้อง/แม่กุญแจที่แถบที่อยู่ของเบราว์เซอร์ แล้วเลือก "อนุญาต" จากนั้นลองใหม่');
    }
    if (s.contains('NotFound') || s.contains('DevicesNotFound') || s.contains('Overconstrained')) {
      throw WebcamError('ไม่พบกล้องในเครื่องนี้');
    }
    if (s.contains('NotReadable') || s.contains('TrackStart')) {
      throw WebcamError('กล้องถูกโปรแกรมอื่นใช้อยู่ (เช่น Zoom / Line / Meet) กรุณาปิดโปรแกรมนั้นก่อน');
    }
    throw WebcamError('เปิดกล้องไม่ได้: $s');
  }
  return _BrowserWebcam(stream);
}

class _BrowserWebcam implements WebcamSession {
  final web.MediaStream _stream;
  late final web.HTMLVideoElement _video;
  @override
  late final String viewType;

  _BrowserWebcam(this._stream) {
    _video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..srcObject = _stream;
    _video.setAttribute('playsinline', 'true');
    _video.style
      ..width = '100%'
      ..height = '100%'
      ..setProperty('object-fit', 'cover')
      // a mirror, like every video call: moving left moves left on screen (the photo itself is not mirrored)
      ..setProperty('transform', 'scaleX(-1)')
      ..setProperty('background', '#000');
    viewType = 'student-webcam-${_views++}';
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => _video);
    _video.play();
  }

  @override
  bool get ready => _video.videoWidth > 0 && _video.videoHeight > 0;

  @override
  Future<Uint8List> capture() async {
    final w = _video.videoWidth, h = _video.videoHeight;
    if (w == 0 || h == 0) throw WebcamError('กล้องยังไม่พร้อม รอสักครู่แล้วลองใหม่');
    final canvas = web.HTMLCanvasElement()
      ..width = w
      ..height = h;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(_video, 0, 0);
    final url = canvas.toDataURL('image/jpeg', 0.92.toJS);
    return base64Decode(url.substring(url.indexOf(',') + 1));
  }

  @override
  void close() {
    for (final t in _stream.getTracks().toDart) {
      t.stop();
    }
    _video.srcObject = null;
  }
}
