import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/library.dart';
import 'package:pdfreader/reader.dart';

PdfDoc _doc(String name,
        {required int pageCount, required int lastPage, String style = 'horizontal'}) =>
    PdfDoc(
      id: name,
      name: name,
      path: '/pdfs/$name',
      size: 1000,
      pageCount: pageCount,
      lastPage: lastPage,
      addedMs: 1,
      style: style,
    );

/// Native calls the reader makes on open and while rendering. The render
/// "file" deliberately does not exist: the reader's image errorBuilder
/// shows its message instead of crashing, which is all these tests need.
void _mockChannels() {
  final binding = TestDefaultBinaryMessengerBinding.instance;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('pdfreader/native'),
    (MethodCall call) async {
      switch (call.method) {
        case 'getFilesDir':
          return '/tmp';
        case 'getCacheDir':
          return '/tmp';
        case 'beginBrightness':
          return 0.7;
        case 'renderPage':
          return {'path': '/tmp/nope.jpg', 'width': 800, 'height': 1000};
        case 'detectPanels':
          return <Map<String, dynamic>>[];
        default:
          return null;
      }
    },
  );
  // SystemChrome calls from reader setup/cleanup. This channel uses
  // the JSON codec, not the standard one: mocking it with the wrong
  // codec makes every SystemChrome call fail with "Message corrupted".
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter/platform', JSONMethodCodec()),
    (MethodCall call) async => null,
  );
}

Future<void> _pumpReader(
    WidgetTester tester, Library lib, PdfDoc doc) async {
  // A returning user has already seen the first-run controls hint. With
  // the hint enabled, its SnackBar would queue ahead of the "Opened ..."
  // SnackBar a document switch shows, hiding it from these assertions.
  lib.settings.controlsHintShown = true;
  await tester.pumpWidget(MaterialApp(home: ReaderPage(library: lib, doc: doc)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Deliver a real volume event through the events channel, exactly as
/// the Android host does, then let page/frame animations finish.
Future<void> _sendVolume(WidgetTester tester, String method) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'pdfreader/events',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    (_) {},
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('volume up turns a page normally, no document switch',
      (tester) async {
    _mockChannels();
    final lib = Library();
    final a = _doc('first.pdf', pageCount: 2, lastPage: 0);
    final b = _doc('second.pdf', pageCount: 3, lastPage: 1);
    lib.docs.addAll([a, b]);
    await _pumpReader(tester, lib, a);
    await _sendVolume(tester, 'volumeUp');
    expect(a.lastPage, 1);
    expect(find.text('Opened second.pdf'), findsNothing);
  });

  testWidgets('volume up on the last page opens the next document',
      (tester) async {
    _mockChannels();
    final lib = Library();
    final a = _doc('first.pdf', pageCount: 2, lastPage: 1);
    final b = _doc('second.pdf', pageCount: 3, lastPage: 1);
    lib.docs.addAll([a, b]);
    await _pumpReader(tester, lib, a);
    await _sendVolume(tester, 'volumeUp');
    expect(find.text('Opened second.pdf'), findsOneWidget);
    // Both sides keep their saved progress: the old doc stays on its
    // last page, the new doc opens on its own saved page (index 1).
    expect(a.lastPage, 1);
    expect(b.lastPage, 1);
  });

  testWidgets('volume down on the first page opens the previous document',
      (tester) async {
    _mockChannels();
    final lib = Library();
    final a = _doc('first.pdf', pageCount: 2, lastPage: 1);
    final b = _doc('second.pdf', pageCount: 3, lastPage: 0);
    lib.docs.addAll([a, b]);
    await _pumpReader(tester, lib, b);
    await _sendVolume(tester, 'volumeDown');
    expect(find.text('Opened first.pdf'), findsOneWidget);
    expect(a.lastPage, 1);
    expect(b.lastPage, 0);
  });

  testWidgets('volume up on the last page of the last document stays',
      (tester) async {
    _mockChannels();
    final lib = Library();
    final a = _doc('first.pdf', pageCount: 2, lastPage: 1);
    final b = _doc('second.pdf', pageCount: 3, lastPage: 2);
    lib.docs.addAll([a, b]);
    await _pumpReader(tester, lib, b);
    await _sendVolume(tester, 'volumeUp');
    expect(find.textContaining('Opened'), findsNothing);
    expect(b.lastPage, 2);
  });

  testWidgets('volume down on the first page of the first document stays',
      (tester) async {
    _mockChannels();
    final lib = Library();
    final a = _doc('first.pdf', pageCount: 2, lastPage: 0);
    final b = _doc('second.pdf', pageCount: 3, lastPage: 1);
    lib.docs.addAll([a, b]);
    await _pumpReader(tester, lib, a);
    await _sendVolume(tester, 'volumeDown');
    expect(find.textContaining('Opened'), findsNothing);
    expect(a.lastPage, 0);
  });

  testWidgets('panel-mode volume still switches documents at the last frame',
      (tester) async {
    _mockChannels();
    final lib = Library();
    final a = _doc('first.pdf',
        pageCount: 2, lastPage: 1, style: 'panel');
    final b = _doc('second.pdf', pageCount: 3, lastPage: 1);
    lib.docs.addAll([a, b]);
    await _pumpReader(tester, lib, a);
    // Grid fallback for the 800x1000 mock page: 4 frames. The first
    // three presses step frames; the fourth crosses into the next doc.
    for (var i = 0; i < 3; i++) {
      await _sendVolume(tester, 'volumeUp');
      expect(find.text('Opened second.pdf'), findsNothing);
    }
    await _sendVolume(tester, 'volumeUp');
    expect(find.text('Opened second.pdf'), findsOneWidget);
    expect(b.lastPage, 1);
  });
}
