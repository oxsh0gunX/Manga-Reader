import 'dart:io';

import 'package:flutter/material.dart';

import 'comic.dart';
import 'library.dart';
import 'native.dart';

// ---------------------------------------------------------------------------
// In-app file browser (v2.3.3).
//
// Why this exists: on this phone the system picker cannot be relied on
// for multi-select — Mi File Explorer either drops all but one file or
// opens in browse mode, and the system Documents picker is not
// reachable. So the app lists the shared storage itself (needs "All
// files access") and lets the user tick several files with big,
// obvious checkboxes. The files are then imported through the exact
// same path as a system-picked file, so duplicates, corrupt files and
// unsupported formats behave identically.
// ---------------------------------------------------------------------------

/// The shared storage root the browser starts in.
const String kStorageRoot = '/storage/emulated/0';

/// File types the reader can import (extension check only — the real
/// validation is magic bytes at import time, so a lying extension is
/// still refused with a clear message).
bool isSupportedFileName(String name) {
  final n = name.toLowerCase();
  if (n.startsWith('.')) return false;
  const suffixes = [
    '.pdf',
    '.cbz',
    '.cbr',
    '.cb7',
    '.cbt',
    '.zip',
    '.7z',
    '.tar',
    '.tar.gz',
    '.tgz',
    '.tar.bz2',
    '.tbz2',
    '.tar.xz',
    '.txz',
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
  ];
  return suffixes.any(n.endsWith);
}

class BrowserEntry {
  BrowserEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.size = 0,
  });

  final String path;
  final String name;
  final bool isDir;
  final int size;
}

/// One folder's contents: subfolders first, then importable files,
/// both in natural order (page1, page2, page10). Hidden entries and
/// files the reader cannot import are left out. An unreadable folder
/// reads as empty instead of throwing.
Future<List<BrowserEntry>> listBrowserEntries(Directory dir) async {
  final entries = <BrowserEntry>[];
  try {
    await for (final e in dir.list(followLinks: false)) {
      final name = e.path.split('/').last;
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        entries.add(BrowserEntry(path: e.path, name: name, isDir: true));
      } else if (e is File && isSupportedFileName(name)) {
        var size = 0;
        try {
          size = await e.length();
        } catch (_) {}
        entries.add(BrowserEntry(
            path: e.path, name: name, isDir: false, size: size));
      }
    }
  } catch (_) {
    return [];
  }
  entries.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return naturalCompare(a.name, b.name);
  });
  return entries;
}

/// Runs one import (system picker or in-app selection) with a
/// progress dialog while it works and a summary afterwards, so the
/// user always sees what happened to every file. Returns the summary,
/// or null when the import threw or the user cancelled the picker.
Future<ImportSummary?> runImportJob(
  BuildContext context,
  Future<ImportSummary> Function(
    void Function(int done, int total) onProgress,
  ) start,
) async {
  // Progress dialog, shown while the files import one by one. The
  // user can dismiss it with the back button; the import keeps going,
  // and the summary still appears.
  var done = 0;
  var total = 0;
  var dialogOpen = false;
  StateSetter? dialogSetState;
  if (context.mounted) {
    dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          dialogSetState = setState;
          return AlertDialog(
            title: const Text('Importing…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: total == 0 ? null : done / total,
                ),
                const SizedBox(height: 12),
                Text(total == 0
                    ? 'Getting ready…'
                    : 'Importing $done of $total…'),
              ],
            ),
          );
        },
      ),
    ).then((_) => dialogOpen = false);
  }
  ImportSummary? summary;
  try {
    summary = await start((d, t) {
      done = d;
      total = t;
      dialogSetState?.call(() {});
    });
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  } finally {
    if (context.mounted) {
      if (dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }
  if (!context.mounted || summary == null || summary.cancelled) {
    // User closed the picker without choosing: say nothing.
    return summary;
  }
  if (summary.failed.isEmpty && summary.duplicates.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(summary.added.length == 1
            ? 'Added to your library'
            : 'Added ${summary.added.length} files to your library'),
      ),
    );
    return summary;
  }
  if (summary.total == 1 && summary.failed.length == 1) {
    // One file, and it failed: the plain message, no dialog.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(summary.failed.first.message)),
    );
    return summary;
  }
  // Mixed result: a summary listing every outcome, so a failed or
  // duplicate file is never silently swallowed.
  final lines = <Widget>[];
  if (summary.added.isNotEmpty) {
    lines.add(Text('Added (${summary.added.length}): '
        '${summary.added.join(', ')}'));
  }
  if (summary.duplicates.isNotEmpty) {
    lines.add(Text('Already in your library '
        '(${summary.duplicates.length}): '
        '${summary.duplicates.join(', ')}'));
  }
  for (final f in summary.failed) {
    lines.add(Text('${f.name}: ${f.message}'));
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Import finished'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              lines[i],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return summary;
}

String _sizeLabel(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The in-app file browser: folders to walk into, files to tick.
/// Selection survives navigating between folders (it is keyed by full
/// path), and the bottom button imports everything ticked, in one go.
class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({super.key, required this.library});

  final Library library;

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage>
    with WidgetsBindingObserver {
  String _dir = kStorageRoot;
  List<BrowserEntry> _entries = [];
  bool _loading = true;
  bool? _hasAccess;
  final Set<String> _selected = {};
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user comes back from the settings screen: re-check, so the
    // list appears without them having to tap anything.
    if (state == AppLifecycleState.resumed && _hasAccess != true) {
      _checkAccess();
    }
  }

  Future<void> _checkAccess() async {
    final ok = await NativeBridge.isAllFilesAccess();
    if (!mounted) return;
    setState(() => _hasAccess = ok);
    if (ok) _loadDir(_dir);
  }

  Future<void> _loadDir(String path) async {
    setState(() {
      _dir = path;
      _loading = true;
    });
    final entries = await listBrowserEntries(Directory(path));
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  String get _title {
    if (_dir == kStorageRoot) return 'Your files';
    return _dir.split('/').last;
  }

  Future<void> _importSelected() async {
    if (_importing || _selected.isEmpty) return;
    setState(() => _importing = true);
    try {
      final summary = await runImportJob(
        context,
        (onProgress) => widget.library.importLocalFiles(
          _selected.toList()..sort(naturalCompare),
          onProgress: onProgress,
        ),
      );
      if (!mounted) return;
      if (summary != null && summary.added.isNotEmpty) {
        // Library changed; go back to the home list to see it.
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _systemPicker() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final summary = await runImportJob(
        context,
        (onProgress) =>
            widget.library.importMany(onProgress: onProgress),
      );
      if (!mounted) return;
      if (summary != null && summary.added.isNotEmpty) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAccess = _hasAccess;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (hasAccess == true)
            TextButton(
              onPressed: _entries.where((e) => !e.isDir).isEmpty
                  ? null
                  : () {
                      setState(() {
                        final files =
                            _entries.where((e) => !e.isDir).toList();
                        final allSelected = files
                            .every((f) => _selected.contains(f.path));
                        if (allSelected) {
                          for (final f in files) {
                            _selected.remove(f.path);
                          }
                        } else {
                          for (final f in files) {
                            _selected.add(f.path);
                          }
                        }
                      });
                    },
              child: const Text('Select all'),
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'system') _systemPicker();
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'system',
                child: Text('Use system picker'),
              ),
            ],
          ),
        ],
      ),
      body: hasAccess == null
          ? const Center(child: CircularProgressIndicator())
          : hasAccess == false
              ? _permissionView()
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _entries.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'No importable files in this folder.\n'
                              'Open a folder to look inside it.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _entries.length,
                          itemBuilder: (ctx, i) {
                            final e = _entries[i];
                            if (e.isDir) {
                              return ListTile(
                                leading:
                                    const Icon(Icons.folder_outlined),
                                title: Text(e.name),
                                trailing:
                                    const Icon(Icons.chevron_right),
                                onTap: () => _loadDir(e.path),
                              );
                            }
                            final checked =
                                _selected.contains(e.path);
                            return CheckboxListTile(
                              value: checked,
                              onChanged: (_) {
                                setState(() {
                                  if (checked) {
                                    _selected.remove(e.path);
                                  } else {
                                    _selected.add(e.path);
                                  }
                                });
                              },
                              title: Text(e.name),
                              subtitle:
                                  Text(_sizeLabel(e.size)),
                              secondary: const Icon(
                                  Icons.picture_as_pdf_outlined),
                              controlAffinity:
                                  ListTileControlAffinity.trailing,
                            );
                          },
                        ),
      bottomNavigationBar: hasAccess == true && _selected.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  onPressed: _importing ? null : _importSelected,
                  icon: const Icon(Icons.download),
                  label: Text(_importing
                      ? 'Importing…'
                      : 'Import ${_selected.length} selected'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _permissionView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_off_outlined, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Let the app see your files',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Your phone\'s own file picker will not hand over more '
              'than one file at a time, so Manga Reader lists your '
              'files itself. It only reads the files you choose to '
              'import — nothing leaves your phone.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                await NativeBridge.openAllFilesAccessSettings();
              },
              child: const Text('Allow access to all files'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Turn the switch on in the settings screen that opens, '
              'then come back here.',
              style: TextStyle(fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
