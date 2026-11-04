import 'package:flutter/material.dart';

import 'about_page.dart';
import 'library.dart';

/// Full Settings screen (v2). Everything here is saved immediately to the
/// same library.json the reader already uses, so settings survive restarts.
/// Text & Character settings apply to the extracted-text view; they never
/// change the PDF file itself.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.library, required this.onChanged});

  final Library library;
  final void Function() onChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get s => widget.library.settings;

  Future<void> _save() async {
    await widget.library.saveSettings();
    widget.onChanged();
    if (mounted) setState(() {});
  }

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
          child: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        ...children,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _section('Reading', [
            SwitchListTile(
              title: const Text('Volume buttons turn pages'),
              subtitle: const Text(
                  'Volume Up: next page or panel. Volume Down: previous. '
                  'When off, volume buttons work normally.'),
              value: s.volumeEnabled,
              onChanged: (v) async {
                s.volumeEnabled = v;
                await _save();
              },
            ),
            SwitchListTile(
              title: const Text('Volume Up + Down screenshot shortcut'),
              subtitle: const Text(
                  'Press both volume buttons together inside the reader '
                  'to capture a screenshot. Page navigation is paused '
                  'for that press, so you never turn a page by accident.'),
              value: s.screenshotShortcutEnabled,
              onChanged: (v) async {
                s.screenshotShortcutEnabled = v;
                await _save();
              },
            ),
            SwitchListTile(
              title: const Text('Dark page filter (opt-in)'),
              subtitle: const Text(
                  'Inverts page colours for comfortable dark reading. '
                  'Off by default: the original PDF is shown unchanged '
                  'unless you turn this on.'),
              value: s.readingFilter,
              onChanged: (v) async {
                s.readingFilter = v;
                await _save();
              },
            ),
            ListTile(
              title: const Text('Screenshots folder'),
              subtitle: const Text('Pictures / PDF Reader (in your gallery)'),
              leading: const Icon(Icons.photo_library_outlined),
            ),
          ]),
          _section('Theme', [
            RadioListTile<String>(
              title: const Text('System default'),
              value: 'system',
              groupValue: s.theme,
              onChanged: (v) async {
                s.theme = v!;
                await _save();
              },
            ),
            RadioListTile<String>(
              title: const Text('Light mode'),
              value: 'light',
              groupValue: s.theme,
              onChanged: (v) async {
                s.theme = v!;
                await _save();
              },
            ),
            RadioListTile<String>(
              title: const Text('Dark mode'),
              value: 'dark',
              groupValue: s.theme,
              onChanged: (v) async {
                s.theme = v!;
                await _save();
              },
            ),
          ]),
          _section('Text & Character', [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'These change how extracted text looks in the text view '
                'only (font, character spacing, size, colour). They never '
                'modify the PDF file, and they do not restyle the original '
                'page image — that image is shown unchanged, except for the '
                'separate opt-in Dark page filter above. On scanned PDFs '
                'with no text layer there is no text to restyle, so the '
                'text view explains that instead of showing junk.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                      color: Theme.of(context).dividerColor.withOpacity(0.6)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Aa — The quick brown fox jumps over the lazy dog.',
                    style: TextStyle(
                      fontSize: s.textSize,
                      height: s.lineHeight,
                      letterSpacing: s.letterSpacing,
                      fontFamily: s.textFont == 1
                          ? 'serif'
                          : (s.textFont == 2 ? 'monospace' : null),
                      color: s.textColor == 1
                          ? const Color(0xFF111111)
                          : (s.textColor == 2
                              ? const Color(0xFF4A3226)
                              : (s.textColor == 3 ? Colors.white : null)),
                    ),
                  ),
                ),
              ),
            ),
            ListTile(
              title: const Text('Text size'),
              subtitle: Text('${s.textSize.round()} pt'),
              trailing: SizedBox(
                width: 180,
                child: Slider(
                  value: s.textSize,
                  min: 12,
                  max: 28,
                  divisions: 16,
                  onChanged: (v) => setState(() => s.textSize = v),
                  onChangeEnd: (_) => _save(),
                ),
              ),
            ),
            ListTile(
              title: const Text('Character spacing'),
              subtitle: Text('${s.letterSpacing.toStringAsFixed(1)} pt'),
              trailing: SizedBox(
                width: 180,
                child: Slider(
                  value: s.letterSpacing,
                  min: 0,
                  max: 3,
                  divisions: 12,
                  onChanged: (v) => setState(() => s.letterSpacing = v),
                  onChangeEnd: (_) => _save(),
                ),
              ),
            ),
            ListTile(
              title: const Text('Line height'),
              subtitle: Text('${s.lineHeight.toStringAsFixed(1)}x'),
              trailing: SizedBox(
                width: 180,
                child: Slider(
                  value: s.lineHeight,
                  min: 1.2,
                  max: 2.0,
                  divisions: 8,
                  onChanged: (v) => setState(() => s.lineHeight = v),
                  onChangeEnd: (_) => _save(),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Character style (font)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            RadioListTile<int>(
              title: const Text('Sans (default)'),
              value: 0,
              groupValue: s.textFont,
              onChanged: (v) async {
                s.textFont = v!;
                await _save();
              },
            ),
            RadioListTile<int>(
              title: const Text('Serif'),
              value: 1,
              groupValue: s.textFont,
              onChanged: (v) async {
                s.textFont = v!;
                await _save();
              },
            ),
            RadioListTile<int>(
              title: const Text('Monospace'),
              value: 2,
              groupValue: s.textFont,
              onChanged: (v) async {
                s.textFont = v!;
                await _save();
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Text colour',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            RadioListTile<int>(
              title: const Text('Theme default'),
              value: 0,
              groupValue: s.textColor,
              onChanged: (v) async {
                s.textColor = v!;
                await _save();
              },
            ),
            RadioListTile<int>(
              title: const Text('Black'),
              value: 1,
              groupValue: s.textColor,
              onChanged: (v) async {
                s.textColor = v!;
                await _save();
              },
            ),
            RadioListTile<int>(
              title: const Text('Sepia brown'),
              value: 2,
              groupValue: s.textColor,
              onChanged: (v) async {
                s.textColor = v!;
                await _save();
              },
            ),
            RadioListTile<int>(
              title: const Text('White'),
              value: 3,
              groupValue: s.textColor,
              onChanged: (v) async {
                s.textColor = v!;
                await _save();
              },
            ),
          ]),
          _section('Frame & Panel defaults', [
            ListTile(
              title: const Text('Frame overlap'),
              subtitle: Text(
                  '${(s.frameOverlap * 100).round()}% padding around each frame, '
                  'so content at a boundary is not cut off'),
              trailing: SizedBox(
                width: 180,
                child: Slider(
                  value: s.frameOverlap,
                  min: 0,
                  max: 0.20,
                  divisions: 10,
                  onChanged: (v) => setState(() => s.frameOverlap = v),
                  onChangeEnd: (_) => _save(),
                ),
              ),
            ),
            ListTile(
              title: const Text('Frame zoom'),
              subtitle: Text('${s.frameZoom.toStringAsFixed(1)}x'),
              trailing: SizedBox(
                width: 180,
                child: Slider(
                  value: s.frameZoom,
                  min: 1.0,
                  max: 2.0,
                  divisions: 10,
                  onChanged: (v) => setState(() => s.frameZoom = v),
                  onChangeEnd: (_) => _save(),
                ),
              ),
            ),
          ]),
          _section('About', [
            ListTile(
              leading: const Icon(Icons.info_outlined),
              title: const Text('About PDF Reader'),
              subtitle: const Text('Version 2.2.2 • Safvan'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AboutPage()),
                );
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'PDF Reader, fully offline, no login, no AI chat, '
                'no OCR, no cloud sync, no subscriptions. Your PDFs, '
                'reading order and progress stay on your phone.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
