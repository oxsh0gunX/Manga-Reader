import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'native.dart';

/// One manually defined panel, as fractions of the page size.
/// Fractions (not pixels) are what make a saved layout restore correctly
/// on any screen and any render resolution.
class PanelRect {
  PanelRect({required this.x, required this.y, required this.w, required this.h});

  double x, y, w, h;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};

  // Sanitized on load: a hand-edited or corrupted library file must never
  // produce a zero/negative or out-of-page rect, because the frame reader
  // divides by rect width/height. x/y are capped at 0.95 so w/h always
  // keep at least 0.05 of room inside the page.
  static PanelRect fromJson(Map<String, dynamic> j) {
    double numOr(String k, double d) {
      final v = j[k];
      return v is num ? v.toDouble() : d;
    }

    final x = numOr('x', 0).clamp(0.0, 0.95);
    final y = numOr('y', 0).clamp(0.0, 0.95);
    final w = numOr('w', 1).clamp(0.05, 1.0 - x);
    final h = numOr('h', 1).clamp(0.05, 1.0 - y);
    return PanelRect(x: x, y: y, w: w, h: h);
  }

  PanelRect copy() => PanelRect(x: x, y: y, w: w, h: h);
}

class PdfDoc {
  PdfDoc({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.pageCount,
    this.lastPage = 0,
    this.lastOpenedMs = 0,
    required this.addedMs,
    this.style = 'horizontal',
    this.panels = 0,
    this.frameLayout = 'auto',
    Map<String, List<PanelRect>>? customPanels,
  }) : customPanels = customPanels ?? {};

  final String id;
  final String name;
  final String path;
  final int size;
  final int pageCount;
  int lastPage;
  int lastOpenedMs;
  final int addedMs;
  // Reading style saved per document: horizontal | vertical | panel |
  // frame | continuous | auto. 'auto' adapts to the page shape.
  String style;
  // Panels per page for panel/frame modes. 0 = automatic (by page shape).
  int panels;
  // Frame layout: auto | vertical (stacked bands) | grid (columns x rows).
  String frameLayout;
  // Manually edited panel layouts, keyed by page index as a string.
  // The list order IS the reading order for that page. When a page has
  // an entry here it wins over automatic detection and over the grid.
  Map<String, List<PanelRect>> customPanels;

  double get progress =>
      pageCount <= 0 ? 0 : (lastPage + 1) / pageCount;
  int get currentPageNumber => lastPage + 1;
  bool get isFinished => pageCount > 0 && lastPage >= pageCount - 1;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'size': size,
        'pageCount': pageCount,
        'lastPage': lastPage,
        'lastOpenedMs': lastOpenedMs,
        'addedMs': addedMs,
        'style': style,
        'panels': panels,
        'frameLayout': frameLayout,
        'customPanels': {
          for (final e in customPanels.entries)
            e.key: e.value.map((r) => r.toJson()).toList(),
        },
      };

  static PdfDoc fromJson(Map<String, dynamic> j) {
    String str(String k, String d) {
      final v = j[k];
      return v is String ? v : d;
    }

    int numInt(String k, int d) {
      final v = j[k];
      return v is num ? v.toInt() : d;
    }

    // A saved lastPage can be out of range if the file was edited or the
    // PDF was replaced; clamp it here so the reader never opens on an
    // invalid page (and never hits clamp(0, -1) on an empty document).
    final pc = numInt('pageCount', 0);
    final lp = pc > 0 ? numInt('lastPage', 0).clamp(0, pc - 1) : 0;
    const styles = {
      'horizontal', 'vertical', 'panel', 'frame', 'continuous', 'auto'
    };
    final style = str('style', 'horizontal');
    const layouts = {'auto', 'vertical', 'grid'};
    final layout = str('frameLayout', 'auto');
    return PdfDoc(
      id: str('id', ''),
      name: str('name', 'Unknown'),
      path: str('path', ''),
      size: numInt('size', 0),
      pageCount: pc,
      lastPage: lp,
      lastOpenedMs: numInt('lastOpenedMs', 0),
      addedMs: numInt('addedMs', 0),
      style: styles.contains(style) ? style : 'horizontal',
      panels: numInt('panels', 0) < 0 ? 0 : numInt('panels', 0),
      frameLayout: layouts.contains(layout) ? layout : 'auto',
      customPanels: _parseCustomPanels(j['customPanels']),
    );
  }
}

Map<String, List<PanelRect>> _parseCustomPanels(dynamic raw) {
  final out = <String, List<PanelRect>>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      if (v is List) {
        final rects = <PanelRect>[];
        for (final e in v) {
          // One malformed rect must not lose the whole page's layout.
          try {
            if (e is Map) {
              rects.add(PanelRect.fromJson(Map<String, dynamic>.from(e)));
            }
          } catch (_) {}
        }
        if (rects.isNotEmpty) out[k.toString()] = rects;
      }
    });
  }
  return out;
}

class AppSettings {
  AppSettings({
    this.volumeEnabled = true,
    this.theme = 'system',
    this.screenshotShortcutEnabled = true,
    this.readingFilter = false,
    // Text & Character settings (used by the extracted-text view).
    this.textSize = 16.0,
    this.textColor = 0,
    this.textFont = 0,
    this.letterSpacing = 0.0,
    this.lineHeight = 1.5,
    this.frameOverlap = 0.08,
    this.frameZoom = 1.0,
    this.controlsHintShown = false,
  });

  bool volumeEnabled;
  // 'system' | 'light' | 'dark'
  String theme;
  // Volume Up + Volume Down together = screenshot (inside the reader).
  bool screenshotShortcutEnabled;
  // Opt-in only: invert page colours for dark reading. Off by default so
  // the original PDF content is never changed without asking.
  bool readingFilter;
  double textSize;
  // 0 = theme default, 1 = black, 2 = sepia brown, 3 = white.
  int textColor;
  // 0 = sans, 1 = serif, 2 = monospace.
  int textFont;
  double letterSpacing;
  double lineHeight;
  // Frame/panel crop overlap, 0.0 - 0.20: padding around each frame so
  // content at a boundary is never cut off.
  double frameOverlap;
  double frameZoom;
  bool controlsHintShown;

  Map<String, dynamic> toJson() => {
        'volumeEnabled': volumeEnabled,
        'theme': theme,
        'screenshotShortcutEnabled': screenshotShortcutEnabled,
        'readingFilter': readingFilter,
        'textSize': textSize,
        'textColor': textColor,
        'textFont': textFont,
        'letterSpacing': letterSpacing,
        'lineHeight': lineHeight,
        'frameOverlap': frameOverlap,
        'frameZoom': frameZoom,
        'controlsHintShown': controlsHintShown,
      };

  static AppSettings fromJson(Map<String, dynamic> j) {
    bool flag(String k, bool d) {
      final v = j[k];
      return v is bool ? v : d;
    }

    double numD(String k, double d) {
      final v = j[k];
      return v is num ? v.toDouble() : d;
    }

    int numI(String k, int d) {
      final v = j[k];
      return v is num ? v.toInt() : d;
    }

    final theme = j['theme'];
    final textSize = numD('textSize', 16.0);
    final lineHeight = numD('lineHeight', 1.5);
    final frameZoom = numD('frameZoom', 1.0);
    return AppSettings(
      volumeEnabled: flag('volumeEnabled', true),
      theme: theme is String && const {'system', 'light', 'dark'}.contains(theme)
          ? theme
          : 'system',
      screenshotShortcutEnabled: flag('screenshotShortcutEnabled', true),
      readingFilter: flag('readingFilter', false),
      textSize: textSize > 0 ? textSize : 16.0,
      textColor: numI('textColor', 0),
      textFont: numI('textFont', 0),
      letterSpacing: numD('letterSpacing', 0.0),
      lineHeight: lineHeight > 0 ? lineHeight : 1.5,
      frameOverlap: numD('frameOverlap', 0.08).clamp(0.0, 0.2),
      frameZoom: frameZoom > 0 ? frameZoom : 1.0,
      controlsHintShown: flag('controlsHintShown', false),
    );
  }
}

/// Library + settings, persisted as JSON in the app's private files dir.
/// The list order IS the reading sequence: reordering it reorders the
/// "Next Document" chain, and it is saved on every change.
class Library extends ChangeNotifier {
  Library();

  final List<PdfDoc> docs = [];
  AppSettings settings = AppSettings();
  bool loaded = false;
  String? _dir;

  String get _libraryPath => '$_dir/library.json';

  Future<void> load() async {
    _dir = await NativeBridge.filesDir();
    try {
      final f = File(_libraryPath);
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        // A bad settings block must not lose the documents, and one bad
        // document entry must not lose the rest of the library.
        try {
          final s = data['settings'];
          settings = s is Map
              ? AppSettings.fromJson(Map<String, dynamic>.from(s))
              : AppSettings();
        } catch (_) {
          settings = AppSettings();
        }
        docs.clear();
        for (final e in (data['docs'] as List? ?? [])) {
          try {
            if (e is Map) {
              final doc = PdfDoc.fromJson(Map<String, dynamic>.from(e));
              // Entries without an id or a path cannot be opened or
              // removed safely; skip them instead of crashing the list.
              if (doc.id.isNotEmpty && doc.path.isNotEmpty) docs.add(doc);
            }
          } catch (_) {}
        }
      }
    } catch (_) {
      // Corrupt JSON: start empty rather than crash. Files stay on disk.
      docs.clear();
    }
    loaded = true;
    notifyListeners();
  }

  // Writes are serialized: without this, two overlapping saves (e.g. a
  // page turn and a settings change) could finish out of order and the
  // older snapshot would silently overwrite the newer change. Each
  // snapshot is taken when its turn runs, so it always sees the latest
  // in-memory state.
  Future<void> _saveChain = Future.value();

  Future<void> _save() {
    _saveChain = _saveChain.then((_) => _writeLibraryFile());
    return _saveChain;
  }

  Future<void> _writeLibraryFile() async {
    if (_dir == null) return;
    try {
      // Atomic write: write a temp file, then rename over the real one.
      // If the app is killed mid-write, library.json still holds the
      // previous complete version instead of a truncated half-file.
      final tmp = File('$_dir/library.json.tmp');
      await tmp.writeAsString(jsonEncode({
        'settings': settings.toJson(),
        'docs': docs.map((d) => d.toJson()).toList(),
      }));
      await tmp.rename(_libraryPath);
    } catch (_) {}
  }

  Future<void> saveSettings() async {
    await _save();
    notifyListeners();
  }

  List<PdfDoc> get recent {
    final r = docs.where((d) => d.lastOpenedMs > 0).toList()
      ..sort((a, b) => b.lastOpenedMs.compareTo(a.lastOpenedMs));
    return r.take(8).toList();
  }

  /// Imports exactly ONE PDF (v2 rule: the picker selects one file at a
  /// time; the user imports more by tapping Import again). Returns
  /// (added, failed, cancelled).
  Future<(int, int, bool)> importOne() async {
    final p = await NativeBridge.pickPdf();
    if (p == null) return (0, 0, true);
    final path = p['path'] as String;
    final name = p['name'] as String;
    try {
      final count = await NativeBridge.pageCount(path);
      if (count <= 0) throw Exception('No pages');
      docs.add(PdfDoc(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        path: path,
        size: (p['size'] as num?)?.toInt() ?? 0,
        pageCount: count,
        addedMs: DateTime.now().millisecondsSinceEpoch,
      ));
      await _save();
      notifyListeners();
      return (1, 0, false);
    } catch (_) {
      try {
        await File(path).delete();
      } catch (_) {}
      return (0, 1, false);
    }
  }

  /// Persists a per-document change (reading style, panel count, layout).
  Future<void> saveDoc(PdfDoc doc) async {
    await _save();
  }

  Future<void> markOpened(PdfDoc doc) async {
    doc.lastOpenedMs = DateTime.now().millisecondsSinceEpoch;
    await _save();
    notifyListeners();
  }

  Future<void> saveProgress(PdfDoc doc, int page) async {
    if (page < 0 || page >= doc.pageCount) return;
    if (doc.lastPage == page) return;
    doc.lastPage = page;
    await _save();
    // No notify: progress changes on every page turn; the reader paints
    // its own indicator, and the library refreshes when you return to it.
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    // ReorderableListView only sends valid indices, but a bad index must
    // be a no-op, never a removeAt/insert crash that loses the list.
    if (oldIndex < 0 ||
        oldIndex >= docs.length ||
        newIndex < 0 ||
        newIndex > docs.length) {
      return;
    }
    if (newIndex > oldIndex) newIndex -= 1;
    final d = docs.removeAt(oldIndex);
    docs.insert(newIndex, d);
    await _save();
    notifyListeners();
  }

  Future<void> remove(PdfDoc doc) async {
    docs.removeWhere((d) => d.id == doc.id);
    await _save();
    notifyListeners();
    try {
      await File(doc.path).delete();
    } catch (_) {}
    // Drop cached page renders for this doc.
    try {
      final cache = await NativeBridge.cacheDir();
      final dir = Directory('$cache/pdf_pages');
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f.path.contains(doc.id)) await f.delete();
        }
      }
    } catch (_) {}
  }

  PdfDoc? docAtSequence(int index) =>
      index >= 0 && index < docs.length ? docs[index] : null;

  int indexOf(PdfDoc doc) => docs.indexWhere((d) => d.id == doc.id);
}
