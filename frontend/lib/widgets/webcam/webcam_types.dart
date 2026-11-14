import 'dart:typed_data';

/// A live camera opened in the browser (getUserMedia): shown with HtmlElementView(viewType),
/// [capture] grabs the current frame as JPEG. Always [close] it (turns the camera light off).
abstract class WebcamSession {
  String get viewType;

  /// true once the camera sends frames
  bool get ready;

  Future<Uint8List> capture();

  void close();
}

/// A Thai message for the teacher (permission refused, no camera, camera busy, not https).
class WebcamError implements Exception {
  final String message;
  WebcamError(this.message);
  @override
  String toString() => message;
}
