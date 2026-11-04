import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/library.dart';

void main() {
  test('custom panel layout round-trips through JSON and restores', () {
    final doc = PdfDoc(
      id: 'd1',
      name: 'comic.pdf',
      path: '/tmp/comic.pdf',
      size: 1234,
      addedMs: 0,
      pageCount: 3,
      style: 'panel',
      panels: 0,
      frameLayout: 'auto',
      customPanels: {
        '1': [
          PanelRect(x: 0, y: 0, w: 1, h: 0.5),
          PanelRect(x: 0, y: 0.5, w: 0.5, h: 0.5),
          PanelRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5),
        ],
      },
    );
    final decoded =
        PdfDoc.fromJson(jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>);
    expect(decoded.customPanels['1']!.length, 3);
    expect(decoded.customPanels['1']![1].x, 0.0);
    expect(decoded.customPanels['1']![1].w, 0.5);
    expect(decoded.style, 'panel');
  });

  test('old JSON without customPanels or controlsHintShown still loads', () {
    final doc = PdfDoc.fromJson({
      'id': 'old',
      'name': 'old.pdf',
      'path': '/tmp/old.pdf',
      'size': 100,
      'addedMs': 0,
      'pageCount': 10,
      'lastPage': 2,
    });
    expect(doc.customPanels, isEmpty);
    expect(doc.style, 'horizontal');
    final settings = AppSettings.fromJson({});
    expect(settings.controlsHintShown, isFalse);
    expect(settings.volumeEnabled, isTrue);
  });

  test('panel order is preserved (list order is reading order)', () {
    final doc = PdfDoc.fromJson({
      'id': 'd2',
      'name': 'm.pdf',
      'path': '/tmp/m.pdf',
      'size': 100,
      'addedMs': 0,
      'pageCount': 1,
      'customPanels': {
        '0': [
          {'x': 0.5, 'y': 0.0, 'w': 0.5, 'h': 1.0},
          {'x': 0.0, 'y': 0.0, 'w': 0.5, 'h': 1.0},
        ],
      },
    });
    // First entry stays first: the user-defined order is not re-sorted.
    expect(doc.customPanels['0']![0].x, 0.5);
    expect(doc.customPanels['0']![1].x, 0.0);
  });
}
