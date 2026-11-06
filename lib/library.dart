import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'comic.dart';
import 'file_hash.dart';
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
    this.contentHash,
    this.kind = 'pdf',
    this.rtl = false,
    this.mangaPaged = false,
    this.pageFiles,
  }) : customPanels = customPanels ?? {};

  final String id;
  final String name;
  final String path;
  final int size;
  final int pageCount;
  int lastPage;
  int lastOpenedMs;
  final int addedMs;
  // What this document is: 'pdf' (rendered by PdfRenderer), 'comic'
  // (an extracted archive: pages live in filesDir/comics/<id>/), or
  // 'image' (one image file; doc.path IS the page). Legacy entries
  // saved before v2.3.0 have no kind and load as 'pdf'.
  final String kind;
  // Manga reading direction for this document: false = left to
  // right (comics), true = right to left (manga). Toggled in the
  // reader's menu; only affects page-turn direction, never the
  // reading order (page 0 is always first).
  bool rtl;
  // Manga mode, one page at a time: false = the strip (pages flow
  // down, several visible at once), true = a single page, swiped up
  // and down. Only used when style is 'manga'; saved per document.
  bool mangaPaged;
  // Page filenames inside filesDir/comics/<id>/, in reading order.
  // Only for kind 'comic'. Null for PDFs and single images.
  final List<String>? pageFiles;
  // Reading style saved per document: horizontal | vertical | panel |
  // frame | continuous | manga | auto. 'auto' adapts to the page
  // shape. 'manga' is top-to-bottom: a continuous strip of pages,
  // or one page at a time when mangaPaged is on.
  String style;
  // Panels per page for panel/frame modes. 0 = automatic (by page shape).
  int panels;
  // Frame layout: auto | vertical (stacked bands) | grid (columns x rows).
  String frameLayout;
  // Manually edited panel layouts, keyed by page index as a string.
  // The list order IS the reading order for that page. When a page has
  // an entry here it wins over automatic detection and over the grid.
  Map<String, List<PanelRect>> customPanels;
  // SHA-256 of the imported file's bytes. This is the duplicate check:
  // same hash means the same PDF, whatever the filename is. Null for
  // entries saved before v2.2.3; those are hashed (and saved) lazily
  // the next time an import runs, so old entries take part too.
  String? contentHash;

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
        'contentHash': contentHash,
        'kind': kind,
        'rtl': rtl,
        'mangaPaged': mangaPaged,
        'pageFiles': pageFiles,
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
      'horizontal', 'vertical', 'panel', 'frame', 'continuous', 'manga', 'auto'
    };
    final style = str('style', 'horizontal');
    const layouts = {'auto', 'vertical', 'grid'};
    final layout = str('frameLayout', 'auto');
    const kinds = {'pdf', 'comic', 'image'};
    final kind = str('kind', 'pdf');
    final rawPages = j['pageFiles'];
    final pageFiles = rawPages is List
        ? rawPages.whereType<String>().toList()
        : null;
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
      contentHash: j['contentHash'] is String ? j['contentHash'] as String : null,
      kind: kinds.contains(kind) ? kind : 'pdf',
      rtl: j['rtl'] is bool ? j['rtl'] as bool : false,
      mangaPaged: j['mangaPaged'] == true,
      pageFiles: pageFiles,
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
    this.autoScrollSeconds = 3,
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
  // Auto-scroll (Manga mode): seconds per page. 1, 2, 3, 5 or 10 from
  // the presets, or any custom value 1-300. Saved, so the user's
  // reading speed is remembered; whether auto-scroll is actually
  // running right now is session-only and never saved.
  int autoScrollSeconds;

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
        'autoScrollSeconds': autoScrollSeconds,
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
      autoScrollSeconds: numI('autoScrollSeconds', 3).clamp(1, 300),
    );
  }
}

/// What an import attempt ended as. `duplicate` means the exact same
/// file content is already in the library: no new entry is created
/// and the existing document is left untouched. `unsupported` means
/// the file was recognised (a RAR/CBR archive) but this app cannot
/// open that format — see [Library.lastImportMessage] for the reason.
/// The message for the last failed/unsupported import is kept on
/// [Library.lastImportMessage] so the UI can show the real reason
/// instead of a generic "could not be read".
enum ImportOutcome { added, duplicate, failed, unsupported }

/// One file that could not be imported, with the plain-language reason.
class ImportFailure {
  ImportFailure(this.name, this.message);
  final String name;
  final String message;
}

/// The outcome of importing a whole picker session. Every picked file
/// is accounted for — added, already in the library, or failed with a
/// reason — so the UI can show a real summary instead of a single
/// yes/no, and [done] tracks progress while the import is running.
class ImportSummary {
  ImportSummary({required this.total, this.cancelled = false});
  final int total;
  final bool cancelled;
  final List<String> added = [];
  final List<String> duplicates = [];
  final List<ImportFailure> failed = [];
  int done = 0;
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

  /// Plain-language reason for the last failed or unsupported import,
  /// or null when the last import added a document / was a duplicate.
  /// Read it right after [importMany]/[importPicked] returns.
  String? lastImportMessage;

  String get _libraryPath => '$_dir/library.json';

  /// App-private folder holding one subfolder per extracted comic:
  /// filesDir/comics/<docId>/0001.jpg, ... Nothing is ever written
  /// to a public folder, and the folder is deleted with the document.
  String comicsDirFor(String docId) => '${_dir ?? ''}/comics/$docId';

  /// Full path of one comic page. For a single image the document's
  /// own file IS the page; for an archive it is the extracted file.
  /// Returns '' when the page does not exist (the reader then shows
  /// its "could not load this page" message instead of crashing).
  String comicPagePath(PdfDoc doc, int page) {
    if (doc.kind == 'image') return doc.path;
    final files = doc.pageFiles;
    if (files == null || page < 0 || page >= files.length) return '';
    return '${comicsDirFor(doc.id)}/${files[page]}';
  }

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

  /// Imports a whole picker session: one call picks as many files as
  /// the user chose (one file is just a session of one), then every
  /// file is imported in turn. See [importPickedList] for the loop.
  Future<ImportSummary> importMany({
    void Function(int done, int total)? onProgress,
  }) async {
    final picked = await NativeBridge.pickFiles();
    return importPickedList(picked, onProgress: onProgress);
  }

  /// Imports files the user chose in the in-app browser: each one is
  /// first copied into the app's own files (filesDir/pdfs, unique
  /// name, like the system picker does), then imported through the
  /// same [importPicked] path as every other import — so duplicates,
  /// unsupported formats and corrupt files behave identically. One
  /// bad file never stops the rest.
  Future<ImportSummary> importLocalFiles(
    List<String> paths, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (_dir == null) {
      final summary = ImportSummary(total: paths.length);
      for (final p in paths) {
        summary.failed.add(
            ImportFailure(_baseName(p), 'Library not ready. Try again.'));
        summary.done++;
      }
      return summary;
    }
    final pdfsDir = Directory('$_dir/pdfs');
    await pdfsDir.create(recursive: true);
    final entries = <Map<String, dynamic>>[];
    for (final p in paths) {
      final name = _baseName(p);
      try {
        final src = File(p);
        final size = await src.length();
        final dest = await _uniqueCopyTarget(pdfsDir, name);
        await src.copy(dest.path);
        entries.add({'name': name, 'path': dest.path, 'size': size});
      } catch (_) {
        entries.add({'name': name, 'error': 'Could not copy this file.'});
      }
    }
    return importPickedList(entries, onProgress: onProgress);
  }

  /// The shared import loop: every entry is imported in turn through
  /// [importPicked], so duplicates, unsupported formats and corrupt
  /// files are all handled exactly as they were for a single import.
  /// One bad file never stops the rest: its failure is recorded and
  /// the loop goes on. The returned summary accounts for every picked
  /// file, and [onProgress] fires after each file (done, total) so
  /// the UI can show real progress. An entry with an 'error' key
  /// (its copy failed) counts as failed without being imported.
  Future<ImportSummary> importPickedList(
    List<Map<String, dynamic>> picked, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (picked.isEmpty) return ImportSummary(total: 0, cancelled: true);
    final summary = ImportSummary(total: picked.length);
    for (final p in picked) {
      final name = (p['name'] as String?)?.isNotEmpty == true
          ? p['name'] as String
          : 'file';
      if (p.containsKey('error')) {
        // Native could not copy this one file; the rest still import.
        summary.failed.add(ImportFailure(
          name,
          (p['error'] as String?) ?? 'Could not copy this file.',
        ));
      } else {
        final outcome = await importPicked(
          path: p['path'] as String,
          name: name,
          size: (p['size'] as num?)?.toInt() ?? 0,
        );
        switch (outcome) {
          case ImportOutcome.added:
            summary.added.add(name);
          case ImportOutcome.duplicate:
            summary.duplicates.add(name);
          case ImportOutcome.failed:
          case ImportOutcome.unsupported:
            summary.failed.add(ImportFailure(
              name,
              lastImportMessage ??
                  'That file could not be read. It may be corrupted.',
            ));
        }
      }
      summary.done++;
      onProgress?.call(summary.done, summary.total);
    }
    return summary;
  }

  static String _baseName(String path) {
    final i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  /// A copy target in [dir] that never clobbers an existing file:
  /// "name (2).pdf", "name (3).pdf", ... — the same rule the native
  /// picker uses.
  Future<File> _uniqueCopyTarget(Directory dir, String name) async {
    var candidate = File('${dir.path}/$name');
    if (!await candidate.exists()) return candidate;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var i = 2;
    while (await File('${dir.path}/$base ($i)$ext').exists()) {
      i++;
    }
    return File('${dir.path}/$base ($i)$ext');
  }

  /// The part of the import after picking, kept separate so tests can
  /// drive it with real files and no picker. `path` is the picked copy
  /// in the app's own files (the native picker already copied it there).
  Future<ImportOutcome> importPicked({
    required String path,
    required String name,
    required int size,
  }) async {
    PdfDoc? addedDoc;
    Directory? pagesDir;
    lastImportMessage = null;
    try {
      final hash = await sha256File(File(path));
      // Fill in hashes for entries saved before v2.2.3, so they take
      // part in the check too. A file that is gone (or unreadable) is
      // simply skipped: its entry stays, and it cannot match.
      var dirty = false;
      for (final d in docs) {
        if (d.contentHash != null) continue;
        try {
          final f = File(d.path);
          if (await f.exists()) {
            d.contentHash = await sha256File(f);
            dirty = true;
          }
        } catch (_) {}
      }
      PdfDoc? existing;
      for (final d in docs) {
        if (d.contentHash == hash) {
          existing = d;
          break;
        }
      }
      if (existing != null) {
        // Same content, already in the library: keep the existing
        // entry exactly as it is, and drop only the freshly picked
        // copy. Never delete the existing document's file (the guard
        // covers the case where the picked path IS that file).
        if (path != existing.path) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
        if (dirty) await _save();
        return ImportOutcome.duplicate;
      }
      // What is this file, really? Extension + magic bytes (comic.dart).
      // A file whose name lies about its contents is refused, and a
      // RAR/CBR is recognised but not opened — see comic.dart for why.
      final header = await File(
        path,
      ).openRead(0, 512).fold<Uint8List>(
        Uint8List(0),
        (a, b) => Uint8List.fromList([...a, ...b]),
      );
      final format = detectFormat(name, header);
      if (format == ComicFormat.rar) {
        lastImportMessage =
            'RAR archives (.cbr) are not supported yet — this app '
            'cannot open RAR files. Convert it to CBZ (ZIP) on your '
            'computer to read it here.';
        if (!docs.any((d) => d.path == path)) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
        return ImportOutcome.unsupported;
      }
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (format == ComicFormat.pdf) {
        final count = await NativeBridge.pageCount(path);
        if (count <= 0) throw ComicError('This PDF has no pages.');
        addedDoc = PdfDoc(
          id: id,
          name: name,
          path: path,
          size: size,
          pageCount: count,
          addedMs: nowMs,
          contentHash: hash,
        );
      } else if (format == ComicFormat.image) {
        addedDoc = await _importSingleImage(
          id: id,
          path: path,
          name: name,
          size: size,
          hash: hash,
          nowMs: nowMs,
        );
        pagesDir = Directory(comicsDirFor(id));
      } else {
        // Comic archive: extract its pages into a fresh app-private
        // folder, then convert any BMP pages (Flutter cannot decode
        // BMP) to JPEG. The archive file itself stays as the
        // document's source, like a PDF.
        pagesDir = Directory(comicsDirFor(id));
        await pagesDir.create(recursive: true);
        List<String> pageFiles;
        if (format == ComicFormat.sevenZ) {
          final raw = await NativeBridge.extractSevenZ(
            path: path,
            destDir: pagesDir.path,
          );
          pageFiles = await _sortAndRenamePages(pagesDir, raw);
        } else {
          pageFiles = await extractArchivePages(
            archivePath: path,
            destDir: pagesDir.path,
            format: format,
          );
        }
        pageFiles = await _convertBmpPages(pagesDir, pageFiles);
        if (pageFiles.isEmpty) {
          throw ComicError('No images found in this archive.');
        }
        addedDoc = PdfDoc(
          id: id,
          name: name,
          path: path,
          size: size,
          pageCount: pageFiles.length,
          addedMs: nowMs,
          contentHash: hash,
          kind: 'comic',
          pageFiles: pageFiles,
        );
      }
      docs.add(addedDoc);
      await _save();
      notifyListeners();
      return ImportOutcome.added;
    } on ComicError catch (e) {
      lastImportMessage = e.message;
      await _dropFailedImport(addedDoc, pagesDir, path);
      return ImportOutcome.failed;
    } catch (e) {
      // Native 7z failures arrive as PlatformException; anything
      // else is a corrupt or unreadable file.
      final msg = e.toString();
      lastImportMessage = msg.contains('password') ||
              msg.contains('Password')
          ? 'This archive is password-protected. Passwords are not supported.'
          : msg.contains('7z') || msg.contains('SevenZ')
              ? 'This 7z archive could not be opened. It may be damaged, '
                  'or use a compression method this app does not support.'
              : 'That file could not be read. It may be corrupted.';
      await _dropFailedImport(addedDoc, pagesDir, path);
      return ImportOutcome.failed;
    }
  }

  /// A failed import leaves nothing behind: drop the entry again if
  /// it was added, delete the half-extracted pages folder, and delete
  /// the picked copy — unless the path belongs to a document already
  /// in the library, which must never be deleted by a failed import
  /// of something else.
  Future<void> _dropFailedImport(
    PdfDoc? addedDoc,
    Directory? pagesDir,
    String path,
  ) async {
    if (addedDoc != null) {
      docs.removeWhere((d) => d.id == addedDoc.id);
    }
    if (pagesDir != null) {
      try {
        if (await pagesDir.exists()) {
          await pagesDir.delete(recursive: true);
        }
        // The parent comics/ folder was created with the pages folder;
        // remove it too when it is now empty, so a failed import leaves
        // no trace at all. Fails silently when other books live there.
        await pagesDir.parent.delete();
      } catch (_) {}
    }
    if (!docs.any((d) => d.path == path)) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// One image file becomes a one-page document. The picked copy is
  /// moved into the document's own app-private folder; a BMP is
  /// converted to JPEG first, because Flutter cannot show BMP.
  Future<PdfDoc> _importSingleImage({
    required String id,
    required String path,
    required String name,
    required int size,
    required String hash,
    required int nowMs,
  }) async {
    final dir = Directory(comicsDirFor(id));
    await dir.create(recursive: true);
    final ext = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : 'jpg';
    final destName = '0001.$ext';
    final dest = File('${dir.path}/$destName');
    await File(path).rename(dest.path);
    String pageFile = destName;
    if (ext == 'bmp') {
      final jpg = File('${dir.path}/0001.jpg');
      final ok = await NativeBridge.convertToJpeg(
        path: dest.path,
        destPath: jpg.path,
      );
      if (!ok) {
        throw ComicError('This image could not be read. It may be corrupted.');
      }
      try {
        await dest.delete();
      } catch (_) {}
      pageFile = '0001.jpg';
    }
    return PdfDoc(
      id: id,
      name: name,
      path: '${dir.path}/$pageFile',
      size: size,
      pageCount: 1,
      addedMs: nowMs,
      contentHash: hash,
      kind: 'image',
      pageFiles: [pageFile],
    );
  }

  /// The native 7z extractor writes files under their archive paths
  /// (possibly in subfolders, in archive order). Keep only images,
  /// sort them naturally, and rename them to 0001.jpg, 0002.png, ...
  /// so a crafted entry name can never escape the pages folder.
  /// Non-image files are deleted, and emptied subfolders are removed.
  Future<List<String>> _sortAndRenamePages(
    Directory dir,
    List<String> relativePaths,
  ) async {
    final images = relativePaths.where(isImageName).toList()
      ..sort(naturalCompare);
    // Delete everything that is not a kept page.
    final kept = images.toSet();
    for (final rel in relativePaths) {
      if (!kept.contains(rel)) {
        try {
          await File('${dir.path}/$rel').delete();
        } catch (_) {}
      }
    }
    // Two passes: first to temp names, then to the final sequential
    // names. A single pass could clobber an archive file that already
    // has a target name (e.g. an entry literally called "0001.jpg"
    // sitting where another page's "0001.jpg" must go).
    final out = <String>[];
    final temps = <String>[];
    var i = 0;
    for (final rel in images) {
      i++;
      final ext = rel.contains('.') ? rel.split('.').last.toLowerCase() : 'jpg';
      final name = '${i.toString().padLeft(4, '0')}.$ext';
      final tmp = '__tmp_${i.toString().padLeft(4, '0')}.$ext';
      await File('${dir.path}/$rel').rename('${dir.path}/$tmp');
      temps.add(tmp);
      out.add(name);
    }
    for (var j = 0; j < temps.length; j++) {
      await File('${dir.path}/${temps[j]}').rename('${dir.path}/${out[j]}');
    }
    // Remove subfolders left empty by the moves.
    try {
      await for (final e in dir.list()) {
        if (e is Directory) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    return out;
  }

  /// BMP pages cannot be shown by Flutter: convert each to JPEG in
  /// place (native BitmapFactory) and point the page list at the
  /// JPEG. A page that will not convert stays a BMP and the reader
  /// shows its "could not load this page" message for that page
  /// instead of losing the whole book.
  Future<List<String>> _convertBmpPages(
    Directory dir,
    List<String> pageFiles,
  ) async {
    final out = <String>[];
    for (final f in pageFiles) {
      if (!f.toLowerCase().endsWith('.bmp')) {
        out.add(f);
        continue;
      }
      final src = File('${dir.path}/$f');
      final dstName = '${f.substring(0, f.length - 4)}.jpg';
      final dst = File('${dir.path}/$dstName');
      final ok = await NativeBridge.convertToJpeg(
        path: src.path,
        destPath: dst.path,
      );
      if (ok) {
        try {
          await src.delete();
        } catch (_) {}
        out.add(dstName);
      } else {
        out.add(f);
      }
    }
    return out;
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
    // Drop the extracted pages folder for a comic / single image.
    // (For an image doc.path already lives inside it, so the folder
    // is empty by now; deleting it is still safe.)
    try {
      if (_dir != null) {
        final dir = Directory(comicsDirFor(doc.id));
        if (await dir.exists()) await dir.delete(recursive: true);
      }
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
