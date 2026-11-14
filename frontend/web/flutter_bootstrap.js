{{flutter_js}}
{{flutter_build_config}}

// No service worker: it kept serving the old app after an update (teachers saw last week's screens).
// The server answers /flutter_service_worker.js with a script that removes the old one from browsers.
_flutter.loader.load();
