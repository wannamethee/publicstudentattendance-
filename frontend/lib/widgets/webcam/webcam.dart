/// The computer's camera in the browser (web build) or nothing (other builds).
library;

export 'webcam_types.dart';
export 'webcam_stub.dart' if (dart.library.js_interop) 'webcam_web.dart';
