import 'package:flutter/services.dart';

/// Thin bridge to MainActivity. No plugins: everything native the app needs
/// (SAF picking, PdfRenderer, volume keys, brightness, gallery save, share)
/// goes through these two channels.
class NativeBridge {
  static const MethodChannel _native = MethodChannel('pdfreader/native');
  static const MethodChannel _events = MethodChannel('pdfreader/events');

  static Future<String> filesDir() async =>
      (await _native.invokeMethod<String>('getFilesDir')) ?? '';
  static Future<String> cacheDir() async =>
      (await _native.invokeMethod<String>('getCacheDir')) ?? '';

  /// Picks exactly ONE PDF. Native code copies it into filesDir/pdfs, so
  /// the library keeps working even if the original file moves.
  /// Returns {name, path, size}, or null if the user cancelled.
  static Future<Map<String, dynamic>?> pickPdf() async {
    final res = await _native.invokeMethod('pickPdf');
    if (res == null) return null;
    return Map<String, dynamic>.from(res as Map);
  }

  static Future<int> pageCount(String path) async {
    final n = await _native.invokeMethod<int>('getPageCount', {'path': path});
    if (n == null) throw Exception('Could not read this PDF');
    return n;
  }

  /// Renders one page to a cached JPEG and returns {path, width, height}.
  static Future<Map<String, dynamic>> renderPage({
    required String path,
    required int page,
    required int width,
    required String docId,
  }) async {
    final res = await _native.invokeMethod('renderPage', {
      'path': path,
      'page': page,
      'width': width,
      'docId': docId,
    });
    if (res == null) throw Exception('Could not render page');
    return Map<String, dynamic>.from(res as Map);
  }

  static void setVolumeEnabled(bool enabled) {
    _native.invokeMethod('setVolumeEnabled', {'enabled': enabled});
  }

  static void setScreenshotShortcutEnabled(bool enabled) {
    _native.invokeMethod(
        'setScreenshotShortcutEnabled', {'enabled': enabled});
  }

  static void onVolumeEvent(void Function(String method) handler) {
    _events.setMethodCallHandler((call) async {
      handler(call.method);
    });
  }

  static void clearVolumeEvent() {
    _events.setMethodCallHandler(null);
  }

  static Future<double> beginBrightness() async {
    final v = await _native.invokeMethod<double>('beginBrightness');
    return v ?? 0.7;
  }

  static void setBrightness(double value) {
    // value < 0 means "system brightness" (the reset option).
    _native.invokeMethod('setBrightness', {'value': value});
  }

  static void restoreBrightness() {
    _native.invokeMethod('restoreBrightness');
  }

  static Future<String?> saveScreenshot(String path, String name) async =>
      _native.invokeMethod<String>('saveScreenshot', {'path': path, 'name': name});

  static void shareText(String text) {
    _native.invokeMethod('shareText', {'text': text});
  }

  /// Automatic panel detection for one rendered page image. Returns a
  /// list of {x, y, w, h} fractions in reading order, or an empty list
  /// when no panel layout could be detected (the reader then falls back
  /// to its grid/band layout instead of pretending detection worked).
  static Future<List<Map<String, dynamic>>> detectPanels(String path) async {
    final res = await _native.invokeMethod('detectPanels', {'path': path});
    if (res == null) return [];
    return (res as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Opens the default email app addressed to the developer, via mailto.
  static Future<void> mailto(String email) async {
    await _native.invokeMethod('mailto', {'email': email});
  }

  /// Opens a URL in the system browser (or the matching app, e.g. GitHub).
  static Future<void> openUrl(String url) async {
    await _native.invokeMethod('openUrl', {'url': url});
  }

  /// Shares a screenshot via the MediaStore uri returned by saveScreenshot.
  static void shareImageUri(String uri) {
    _native.invokeMethod('shareImage', {'uri': uri});
  }
}
