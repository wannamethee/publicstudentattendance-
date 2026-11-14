import 'webcam_types.dart';

/// Not a web build: no browser camera here (the photo dialog falls back to the file picker).
bool webcamAvailable() => false;

String webcamUnavailableReason() => 'กล้องใช้ได้เฉพาะในเบราว์เซอร์';

Future<WebcamSession> openWebcam() async => throw WebcamError(webcamUnavailableReason());
