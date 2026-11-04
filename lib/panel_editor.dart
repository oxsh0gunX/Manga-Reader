import 'dart:io';

import 'package:flutter/material.dart';

import 'library.dart';
import 'native.dart';

/// Manual panel editor for one page.
///
/// The user taps a panel to select it, drags its body to move it, drags its
/// bottom-right corner to resize it, or uses the sliders for precise
/// numbers. Panels can be added, deleted and reordered (the list order is
/// the reading order). Saving stores the layout for this document + page
/// in library.json, so reopening the PDF restores it exactly. "Reset to
/// automatic" deletes the saved layout and lets the reader fall back to
/// automatic detection or its grid layout.
class PanelEditorPage extends StatefulWidget {
  const PanelEditorPage({
    super.key,
    required this.library,
    required this.doc,
    required this.page,
    required this.imagePath,
    required this.imgW,
    required this.imgH,
    required this.initial,
  });

  final Library library;
  final PdfDoc doc;
  final int page;
  final String imagePath;
  final double imgW;
  final double imgH;
  final List<PanelRect> initial;

  @override
  State<PanelEditorPage> createState() => _PanelEditorPageState();
}

class _PanelEditorPageState extends State<PanelEditorPage> {
  late List<PanelRect> _rects;
  int _selected = 0;
  int _dragIndex = -1;
  String _dragMode = 'move';

  @override
  void initState() {
    super.initState();
    _rects = widget.initial.isEmpty
        ? [PanelRect(x: 0, y: 0, w: 1, h: 1)]
        : widget.initial.map((r) => r.copy()).toList();
  }

  bool get _hasCustom =>
      widget.doc.customPanels.containsKey('${widget.page}');

  PanelRect get _current => _rects[_selected.clamp(0, _rects.length - 1)];

  String _pct(double v) => '${(v * 100).round()}%';

  Future<void> _save() async {
    widget.doc.customPanels['${widget.page}'] =
        _rects.map((r) => r.copy()).toList();
    await widget.library.saveDoc(widget.doc);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Panel layout saved for page ${widget.page + 1}')),
    );
    Navigator.of(context).pop(true);
  }

  Future<void> _detect() async {
    try {
      final found = await NativeBridge.detectPanels(widget.imagePath);
      if (!mounted) return;
      if (found.length < 2) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'No panels detected on this page — your current layout '
                'is unchanged. Draw the panels yourself instead.'),
          ),
        );
        return;
      }
      if (_hasCustom) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Replace saved layout?'),
            content: Text(
                'Automatic detection found ${found.length} panels. '
                'Replace your saved layout with it? You can still edit '
                'the result before saving.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Keep mine'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Use detected'),
              ),
            ],
          ),
        );
        if (ok != true) return;
      }
      setState(() {
        _rects = found
            .map((m) => PanelRect(
                  x: (m['x'] as num).toDouble(),
                  y: (m['y'] as num).toDouble(),
                  w: (m['w'] as num).toDouble(),
                  h: (m['h'] as num).toDouble(),
                ))
            .toList();
        _selected = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Detected ${found.length} panels. Tap Save layout to keep them.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Detection failed: $e')),
        );
      }
    }
  }

  Future<void> _resetToAutomatic() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset to automatic?'),
        content: const Text(
            'Remove your saved layout for this page? The reader will '
            'use automatic detection, or its grid layout if detection '
            'finds nothing.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep mine'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    widget.doc.customPanels.remove('${widget.page}');
    await widget.library.saveDoc(widget.doc);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _moveSelected(int i, double dxF, double dyF) {
    final r = _rects[i];
    setState(() {
      r.x = (r.x + dxF).clamp(0.0, 1.0 - r.w);
      r.y = (r.y + dyF).clamp(0.0, 1.0 - r.h);
    });
  }

  void _resizeSelected(int i, double dxF, double dyF) {
    final r = _rects[i];
    setState(() {
      r.w = (r.w + dxF).clamp(0.08, 1.0 - r.x);
      r.h = (r.h + dyF).clamp(0.08, 1.0 - r.y);
    });
  }

  Widget _imageArea() {
    return LayoutBuilder(
      builder: (ctx, cons) {
        var w = cons.maxWidth - 24;
        var h = w * widget.imgH / widget.imgW;
        if (h > cons.maxHeight) {
          h = cons.maxHeight;
          w = h * widget.imgW / widget.imgH;
        }
        final theme = Theme.of(context);
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.fill,
                  ),
                ),
                for (int i = 0; i < _rects.length; i++)
                  Builder(
                    builder: (ctx) {
                      final r = _rects[i];
                      final selected = i == _selected;
                      return Positioned(
                        left: r.x * w,
                        top: r.y * h,
                        width: r.w * w,
                        height: r.h * h,
                        child: GestureDetector(
                          onTap: () => setState(() => _selected = i),
                          onPanStart: (details) {
                            _dragIndex = i;
                            final pw = r.w * w;
                            final ph = r.h * h;
                            _dragMode =
                                (details.localPosition.dx > pw - 28 &&
                                        details.localPosition.dy > ph - 28)
                                    ? 'resize'
                                    : 'move';
                            setState(() => _selected = i);
                          },
                          onPanUpdate: (details) {
                            if (_dragIndex != i) return;
                            final dxF = details.delta.dx / w;
                            final dyF = details.delta.dy / h;
                            if (_dragMode == 'resize') {
                              _resizeSelected(i, dxF, dyF);
                            } else {
                              _moveSelected(i, dxF, dyF);
                            }
                          },
                          onPanEnd: (_) => _dragIndex = -1,
                          onPanCancel: () => _dragIndex = -1,
                          child: Container(
                            decoration: BoxDecoration(
                              color: selected
                                  ? theme.colorScheme.primary.withOpacity(0.18)
                                  : Colors.black.withOpacity(0.12),
                              border: Border.all(
                                color: selected
                                    ? theme.colorScheme.primary
                                    : Colors.white,
                                width: selected ? 3 : 1.5,
                              ),
                            ),
                            child: Stack(
                              children: [
                                Center(
                                  child: Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 18,
                                      shadows: [
                                        Shadow(
                                            blurRadius: 4, color: Colors.black)
                                      ],
                                    ),
                                  ),
                                ),
                                if (selected)
                                  const Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Icon(
                                      Icons.open_in_full,
                                      size: 20,
                                      color: Colors.white,
                                      shadows: [
                                        Shadow(
                                            blurRadius: 4, color: Colors.black)
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sliderRow(String label, double value, double min, double max,
      void Function(double) onChanged) {
    // A zero-range slider (e.g. Left when the panel is full-width, so
    // max == min == 0) makes Flutter divide by (max - min) == 0. Show it
    // disabled instead of risking a NaN layout.
    if (max - min < 0.001) {
      return Row(
        children: [
          SizedBox(width: 64, child: Text(label)),
          const Expanded(
            child: Slider(value: 0, min: 0, max: 1, onChanged: null),
          ),
          SizedBox(width: 44, child: Text(_pct(min))),
        ],
      );
    }
    final v = value.clamp(min, max);
    return Row(
      children: [
        SizedBox(width: 64, child: Text(label)),
        Expanded(
          child: Slider(
            value: v,
            min: min,
            max: max,
            divisions: 100,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 44, child: Text(_pct(v))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _current;
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit panels — page ${widget.page + 1}'),
        actions: [
          IconButton(
            tooltip: 'Save layout',
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(flex: 5, child: Padding(
            padding: const EdgeInsets.all(12),
            child: _imageArea(),
          )),
          Expanded(
            flex: 6,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Text(
                  'Panel ${_selected + 1} of ${_rects.length}'
                  '${_hasCustom ? '  •  saved layout' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Drag a panel to move it, drag its bottom-right corner '
                  'to resize it, or use the sliders. Panels are read in '
                  'number order.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                _sliderRow('Left', r.x, 0, (1 - r.w).clamp(0.0, 1.0),
                    (v) => setState(() => r.x = v)),
                _sliderRow('Top', r.y, 0, (1 - r.h).clamp(0.0, 1.0),
                    (v) => setState(() => r.y = v)),
                _sliderRow('Width', r.w, 0.08, (1 - r.x).clamp(0.09, 1.0),
                    (v) => setState(() => r.w = v)),
                _sliderRow('Height', r.h, 0.08, (1 - r.y).clamp(0.09, 1.0),
                    (v) => setState(() => r.h = v)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _rects.add(
                              PanelRect(x: 0.2, y: 0.35, w: 0.6, h: 0.3));
                          _selected = _rects.length - 1;
                        });
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add panel'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        if (_rects.length <= 1) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'At least one panel is needed.')),
                          );
                          return;
                        }
                        setState(() {
                          _rects.removeAt(_selected);
                          _selected =
                              _selected.clamp(0, _rects.length - 1);
                        });
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete panel'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _detect,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: const Text('Detect panels'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _resetToAutomatic,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Reset to automatic'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Reading order',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                for (int i = 0; i < _rects.length; i++)
                  ListTile(
                    selected: i == _selected,
                    leading: CircleAvatar(child: Text('${i + 1}')),
                    title: Text('Panel ${i + 1}'),
                    subtitle: Text(
                        '${_pct(_rects[i].x)}, ${_pct(_rects[i].y)} — '
                        '${_pct(_rects[i].w)} × ${_pct(_rects[i].h)}'),
                    onTap: () => setState(() => _selected = i),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Earlier in reading order',
                          icon: const Icon(Icons.arrow_upward, size: 20),
                          onPressed: i == 0
                              ? null
                              : () {
                                  setState(() {
                                    final tmp = _rects[i - 1];
                                    _rects[i - 1] = _rects[i];
                                    _rects[i] = tmp;
                                    _selected = i - 1;
                                  });
                                },
                        ),
                        IconButton(
                          tooltip: 'Later in reading order',
                          icon: const Icon(Icons.arrow_downward, size: 20),
                          onPressed: i == _rects.length - 1
                              ? null
                              : () {
                                  setState(() {
                                    final tmp = _rects[i + 1];
                                    _rects[i + 1] = _rects[i];
                                    _rects[i] = tmp;
                                    _selected = i + 1;
                                  });
                                },
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Save layout'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
