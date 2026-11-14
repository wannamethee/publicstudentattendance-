/// What the server wrote into index.html (web build), or nothing (other builds).
library;

export 'host_page_stub.dart' if (dart.library.js_interop) 'host_page_web.dart';
