import 'package:web/web.dart' as web;

/// The school-logo URL the server put in the tab icon of index.html (`/api/v1/settings/school-logo?v=…`).
/// The app shows its logo from exactly this URL, so the browser downloads the logo once for the tab and the app.
String? pageSchoolLogoPath() {
  try {
    final href = web.document.getElementById('app-favicon')?.getAttribute('href');
    return href != null && href.startsWith('/api/v1/settings/school-logo') ? href : null;
  } catch (_) {
    return null;
  }
}
