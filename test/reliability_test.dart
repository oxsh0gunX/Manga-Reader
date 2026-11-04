import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/library.dart';

PdfDoc _doc(String id, {int pageCount = 5, int lastPage = 0}) => PdfDoc(
      id: id,
      name: id,
      path: '/pdfs/$id.pdf',
      size: 1000,
      pageCount: pageCount,
      lastPage: lastPage,
      addedMs: 1,
    );

void main() {
  group('PanelRect sanitization on load', () {
    test('out-of-range and zero/negative rects become valid in-page rects', () {
      final r = PanelRect.fromJson({'x': 2, 'y': -1, 'w': 0, 'h': -5});
      expect(r.x, lessThanOrEqualTo(0.95));
      expect(r.y, greaterThanOrEqualTo(0));
      expect(r.w, greaterThanOrEqualTo(0.05));
      expect(r.h, greaterThanOrEqualTo(0.05));
      expect(r.x + r.w, lessThanOrEqualTo(1.0));
      expect(r.y + r.h, lessThanOrEqualTo(1.0));
    });

    test('wrong-typed values fall back to defaults, not throws', () {
      final r = PanelRect.fromJson({'x': 'a', 'w': null});
      expect(r.x, 0);
      expect(r.w, 1);
    });
  });

  group('PdfDoc.fromJson tolerance', () {
    test('empty document clamps lastPage to 0 (no clamp(0, -1) crash)', () {
      final d = PdfDoc.fromJson({
        'id': 'e',
        'name': 'e',
        'path': '/e.pdf',
        'pageCount': 0,
        'lastPage': 99,
        'addedMs': 1,
      });
      expect(d.lastPage, 0);
    });

    test('out-of-range lastPage clamps to the last real page', () {
      final d = PdfDoc.fromJson({
        'id': 'd',
        'name': 'd',
        'path': '/d.pdf',
        'pageCount': 10,
        'lastPage': 99,
        'addedMs': 1,
      });
      expect(d.lastPage, 9);
    });

    test('unknown style/layout and negative panels fall back safely', () {
      final d = PdfDoc.fromJson({
        'id': 'd',
        'name': 'd',
        'path': '/d.pdf',
        'pageCount': 5,
        'style': 'neon',
        'frameLayout': 'weird',
        'panels': -3,
        'addedMs': 1,
      });
      expect(d.style, 'horizontal');
      expect(d.frameLayout, 'auto');
      expect(d.panels, 0);
    });

    test('missing id/path become empty (load skips such entries)', () {
      final d = PdfDoc.fromJson({'pageCount': 5});
      expect(d.id, '');
      expect(d.path, '');
    });
  });

  group('AppSettings.fromJson tolerance', () {
    test('wrong types and unknown theme fall back to defaults', () {
      final s = AppSettings.fromJson({
        'volumeEnabled': 'yes',
        'theme': 'neon',
        'textSize': 'big',
        'frameZoom': -2,
        'frameOverlap': 5,
      });
      expect(s.volumeEnabled, true);
      expect(s.theme, 'system');
      expect(s.textSize, 16.0);
      expect(s.frameZoom, 1.0);
      expect(s.frameOverlap, 0.2);
    });

    test('settings round-trip preserves every field', () {
      final s = AppSettings(
        volumeEnabled: false,
        theme: 'dark',
        screenshotShortcutEnabled: false,
        readingFilter: true,
        textSize: 20,
        textColor: 2,
        textFont: 1,
        letterSpacing: 0.5,
        lineHeight: 1.8,
        frameOverlap: 0.12,
        frameZoom: 1.3,
        controlsHintShown: true,
      );
      final back = AppSettings.fromJson(s.toJson());
      expect(back.volumeEnabled, false);
      expect(back.theme, 'dark');
      expect(back.screenshotShortcutEnabled, false);
      expect(back.readingFilter, true);
      expect(back.textSize, 20);
      expect(back.textColor, 2);
      expect(back.textFont, 1);
      expect(back.letterSpacing, 0.5);
      expect(back.lineHeight, 1.8);
      expect(back.frameOverlap, 0.12);
      expect(back.frameZoom, 1.3);
      expect(back.controlsHintShown, true);
    });
  });

  group('Progress and navigation bounds', () {
    test('saveProgress ignores out-of-range pages and keeps valid ones', () async {
      final lib = Library();
      final doc = _doc('a', lastPage: 2);
      await lib.saveProgress(doc, -1);
      expect(doc.lastPage, 2);
      await lib.saveProgress(doc, 5);
      expect(doc.lastPage, 2);
      await lib.saveProgress(doc, 4);
      expect(doc.lastPage, 4);
      final empty = _doc('e', pageCount: 0);
      await lib.saveProgress(empty, 0);
      expect(empty.lastPage, 0);
    });

    test('docAtSequence returns null outside the list', () {
      final lib = Library();
      lib.docs.addAll([_doc('a'), _doc('b')]);
      expect(lib.docAtSequence(-1), isNull);
      expect(lib.docAtSequence(2), isNull);
      expect(lib.docAtSequence(1)?.id, 'b');
    });

    test('reorder ignores bad indices and keeps valid moves', () async {
      final lib = Library();
      lib.docs.addAll([_doc('a'), _doc('b'), _doc('c')]);
      await lib.reorder(-1, 0);
      await lib.reorder(0, 99);
      expect(lib.docs.map((d) => d.id).toList(), ['a', 'b', 'c']);
      await lib.reorder(0, 2);
      expect(lib.docs.map((d) => d.id).toList(), ['b', 'a', 'c']);
      await lib.reorder(2, 0);
      expect(lib.docs.map((d) => d.id).toList(), ['c', 'b', 'a']);
    });
  });

  group('Panel persistence and restart restoration', () {
    test('custom panels round-trip in order, invalid rects sanitized', () {
      final doc = _doc('a', pageCount: 10);
      doc.customPanels['0'] = [
        PanelRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
        PanelRect(x: 2, y: -1, w: 0, h: -5),
      ];
      final back = PdfDoc.fromJson(doc.toJson());
      final rects = back.customPanels['0']!;
      expect(rects.length, 2);
      expect(rects[0].x, 0.1);
      expect(rects[0].w, 0.2);
      expect(rects[1].x + rects[1].w, lessThanOrEqualTo(1.0));
      expect(rects[1].w, greaterThanOrEqualTo(0.05));
    });

    test('restart simulation: lastPage, style, panels, layouts restored', () {
      final doc = _doc('a', pageCount: 20, lastPage: 7);
      doc.style = 'panel';
      doc.panels = 4;
      doc.customPanels['3'] = [PanelRect(x: 0, y: 0, w: 0.5, h: 0.5)];
      final back = PdfDoc.fromJson(doc.toJson());
      expect(back.lastPage, 7);
      expect(back.style, 'panel');
      expect(back.panels, 4);
      expect(back.customPanels['3']!.length, 1);
      expect(back.customPanels['3']!.first.w, 0.5);
    });
  });
}
