import 'dart:io';

import 'package:flutter/material.dart';

import 'library.dart';
import 'reader.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.library, required this.onThemeChanged});

  final Library library;
  final void Function(String theme) onThemeChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _searching = false;
  String _query = '';
  bool _importing = false;

  String _sizeLabel(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _import() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final (added, failed, cancelled, duplicate) =
          await widget.library.importOne();
      if (!mounted) return;
      if (cancelled) {
        // User closed the picker without choosing: say nothing.
      } else if (duplicate) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('This PDF is already in your library')),
        );
      } else if (added == 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF added to your library')),
        );
      } else if (failed == 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('That PDF could not be read. It may be corrupted.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _open(PdfDoc doc) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderPage(library: widget.library, doc: doc),
      ),
    );
  }

  Future<void> _openMissing(PdfDoc doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('File not found'),
        content: Text(
            '“${doc.name}” is no longer on this phone, so it cannot be '
            'opened. Remove it from the library?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.library.remove(doc);
  }

  Future<void> _confirmDelete(PdfDoc doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove PDF?'),
        content: Text(
            'Remove "${doc.name}" from your library? The imported copy will be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.library.remove(doc);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          library: widget.library,
          onChanged: () {
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  Widget _docCard(PdfDoc doc, {bool showHandle = false}) {
    final pct = (doc.progress * 100).round();
    // The imported copy lives in the app's own files, but it can still
    // disappear (e.g. app data cleared). Say so on the card instead of
    // opening a reader full of render errors.
    final missing = !File(doc.path).existsSync();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(context).dividerColor.withOpacity(0.6),
        ),
      ),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => missing ? _openMissing(doc) : _open(doc),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 56,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: const Icon(Icons.picture_as_pdf_outlined, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doc.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${doc.pageCount} pages'
                      '${doc.size > 0 ? '  •  ${_sizeLabel(doc.size)}' : ''}'
                      '${doc.lastOpenedMs > 0 ? '  •  $pct% read' : ''}',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(0.65),
                      ),
                    ),
                    if (missing) ...[
                      const SizedBox(height: 4),
                      Text(
                        'File not found on this phone',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (doc.lastOpenedMs > 0) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: doc.progress,
                          minHeight: 4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        doc.isFinished
                            ? 'Finished'
                            : 'Continue: page ${doc.currentPageNumber}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              if (showHandle) ...[
                const SizedBox(width: 8),
                const Icon(Icons.drag_handle, size: 20),
              ],
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'delete') _confirmDelete(doc);
                },
                itemBuilder: (ctx) => const [
                  PopupMenuItem(value: 'delete', child: Text('Remove')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lib = widget.library;
    final all = _query.isEmpty
        ? lib.docs
        : lib.docs
            .where((d) => d.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    final recent = _query.isEmpty ? lib.recent : <PdfDoc>[];
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search PDFs…',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : const Text('PDF Reader'),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _query = '';
            }),
          ),
          IconButton(
            tooltip: 'Reading order',
            icon: const Icon(Icons.reorder),
            onPressed: lib.docs.isEmpty
                ? null
                : () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ReorderPage(library: lib, onOpen: _open),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _import,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: const Text('Import PDF'),
      ),
      body: !lib.loaded
          ? const Center(child: CircularProgressIndicator())
          : lib.docs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.picture_as_pdf_outlined, size: 64),
                        const SizedBox(height: 16),
                        const Text(
                          'No PDFs yet',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Import PDFs from your phone. They stay on your '
                          'device, your place in each one is remembered, and '
                          'you can read them in order, one after another.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: _import,
                          icon: const Icon(Icons.add),
                          label: const Text('Import your first PDF'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 96),
                  children: [
                    if (recent.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(
                          'Recently opened',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ),
                      SizedBox(
                        height: 132,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: recent.length,
                          itemBuilder: (ctx, i) {
                            final d = recent[i];
                            return SizedBox(
                              width: 210,
                              child: Card(
                                margin: const EdgeInsets.all(4),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(
                                    color: Theme.of(context)
                                        .dividerColor
                                        .withOpacity(0.6),
                                  ),
                                ),
                                elevation: 0,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () => _open(d),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Icon(
                                            Icons.picture_as_pdf_outlined),
                                        const SizedBox(height: 8),
                                        Text(
                                          d.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600),
                                        ),
                                        const Spacer(),
                                        Text(
                                          'Page ${d.currentPageNumber} / ${d.pageCount}',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                      child: Row(
                        children: [
                          Text(
                            'All documents',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                          SizedBox(width: 8),
                          Icon(Icons.info_outline, size: 16),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'This order is your reading sequence. Use the reorder '
                        'button above to drag documents into a new order.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    if (_query.isNotEmpty && all.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No PDFs match that search.'),
                      ),
                    for (final d in all) _docCard(d),
                  ],
                ),
    );
  }
}

/// Drag-and-drop sequencing screen: the saved order is the order the
/// reader's "Next Document" chain follows.
class ReorderPage extends StatefulWidget {
  const ReorderPage({super.key, required this.library, required this.onOpen});

  final Library library;
  final void Function(PdfDoc doc) onOpen;

  @override
  State<ReorderPage> createState() => _ReorderPageState();
}

class _ReorderPageState extends State<ReorderPage> {
  @override
  Widget build(BuildContext context) {
    final lib = widget.library;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reading order'),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Drag the handle on the right to reorder. '
              'The order is saved automatically and becomes the '
              '"Next Document" sequence in the reader.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: lib.docs.length,
              onReorder: (oldIndex, newIndex) async {
                await lib.reorder(oldIndex, newIndex);
                if (mounted) setState(() {});
              },
              itemBuilder: (ctx, i) {
                final d = lib.docs[i];
                return ListTile(
                  key: ValueKey(d.id),
                  leading: CircleAvatar(child: Text('${i + 1}')),
                  title: Text(
                    d.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${d.pageCount} pages'),
                  trailing: const Icon(Icons.drag_handle),
                  onTap: () => widget.onOpen(d),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done — order saved'),
            ),
          ),
        ],
      ),
    );
  }
}
