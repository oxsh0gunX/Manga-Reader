import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/library.dart';
import 'package:pdfreader/reader.dart';

// ---------------------------------------------------------------------------
// v2.3.0 — comic / manga reading in the existing reader
//
// Patterns copied from v223_test.dart: controls start hidden
// (_controlsVisible = false), so a centre tap shows them first; page turns
// are asserted on doc.lastPage, and the AppBar subtitle is a single Text
// ('Page 1 / 3 • 0%'), so indicator checks use textContaining.
// ---------------------------------------------------------------------------

void main() {
  group('Comic pages in the reader', () {
    setUpAll(_mockChannels);

    PdfDoc comic({bool rtl = false, String style = 'horizontal', int lastPage = 0}) =>
        PdfDoc(
          id: 'comic',
          name: 'manga.cbz',
          path: '/pdfs/manga.cbz',
          size: 100,
          pageCount: 3,
          lastPage: lastPage,
          addedMs: 1,
          style: style,
          kind: 'comic',
          rtl: rtl,
          pageFiles: ['0001.jpg', '0002.jpg', '0003.jpg'],
        );

    testWidgets('a comic page shows with its page indicator', (tester) async {
      final lib = Library();
      final doc = comic();
      await _pumpReader(tester, lib, doc);
      await _tapAt(tester, const Offset(400, 300)); // show controls
      expect(find.textContaining('Page 1 / 3'), findsOneWidget);
      expect(doc.lastPage, 0);
    });

    testWidgets('right tap turns forward, left tap turns back (LTR)', (tester) async {
      final lib = Library();
      final doc = comic();
      await _pumpReader(tester, lib, doc);

      await _tapAt(tester, const Offset(700, 300));
      expect(doc.lastPage, 1);

      await _tapAt(tester, const Offset(100, 300));
      expect(doc.lastPage, 0);
    });

    testWidgets('centre tap toggles the controls, never the page', (tester) async {
      final lib = Library();
      final doc = comic();
      await _pumpReader(tester, lib, doc);

      expect(find.byType(AppBar), findsNothing);
      await _tapAt(tester, const Offset(400, 300));
      expect(doc.lastPage, 0);
      expect(find.byType(AppBar), findsOneWidget);
      await _tapAt(tester, const Offset(400, 300));
      expect(doc.lastPage, 0);
      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('taps stay put at the first and last page', (tester) async {
      final lib = Library();
      final doc = comic();
      await _pumpReader(tester, lib, doc);

      await _tapAt(tester, const Offset(100, 300));
      expect(doc.lastPage, 0);
      await _tapAt(tester, const Offset(700, 300));
      await _tapAt(tester, const Offset(700, 300));
      expect(doc.lastPage, 2);
      await _tapAt(tester, const Offset(700, 300));
      expect(doc.lastPage, 2);
    });

    testWidgets('volume keys turn comic pages forward and back', (tester) async {
      final lib = Library();
      final doc = comic();
      await _pumpReader(tester, lib, doc);

      await _sendVolume(tester, 'volumeUp');
      expect(doc.lastPage, 1);
      await _sendVolume(tester, 'volumeDown');
      expect(doc.lastPage, 0);
    });

    testWidgets('the text view toggle is hidden for comics', (tester) async {
      final lib = Library();
      final doc = comic();
      await _pumpReader(tester, lib, doc);
      await _tapAt(tester, const Offset(400, 300)); // show controls
      expect(find.byTooltip('Select text'), findsNothing);
    });

    testWidgets('the text view toggle is still there for PDFs', (tester) async {
      final lib = Library();
      final doc = PdfDoc(
        id: 'pdf',
        name: 'book.pdf',
        path: '/pdfs/book.pdf',
        size: 100,
        pageCount: 3,
        addedMs: 1,
      );
      await _pumpReader(tester, lib, doc);
      await _tapAt(tester, const Offset(400, 300)); // show controls
      expect(find.byTooltip('Select text'), findsOneWidget);
    });
  });

  group('Right-to-left (manga) reading', () {
    setUpAll(_mockChannels);

    testWidgets('tap zones swap: left turns forward, right turns back', (tester) async {
      final lib = Library();
      final doc = PdfDoc(
        id: 'manga',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 100,
        pageCount: 3,
        addedMs: 1,
        kind: 'comic',
        rtl: true,
        pageFiles: ['0001.jpg', '0002.jpg', '0003.jpg'],
      );
      await _pumpReader(tester, lib, doc);

      await _tapAt(tester, const Offset(100, 300));
      expect(doc.lastPage, 1);
      await _tapAt(tester, const Offset(700, 300));
      expect(doc.lastPage, 0);
    });

    testWidgets('volume keys still move in reading order when RTL', (tester) async {
      final lib = Library();
      final doc = PdfDoc(
        id: 'manga',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 100,
        pageCount: 3,
        addedMs: 1,
        kind: 'comic',
        rtl: true,
        pageFiles: ['0001.jpg', '0002.jpg', '0003.jpg'],
      );
      await _pumpReader(tester, lib, doc);

      await _sendVolume(tester, 'volumeUp');
      expect(doc.lastPage, 1);
    });

    testWidgets('the menu toggles RTL and it is saved on the document', (tester) async {
      final lib = Library();
      final doc = PdfDoc(
        id: 'manga',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 100,
        pageCount: 3,
        addedMs: 1,
        kind: 'comic',
        pageFiles: ['0001.jpg', '0002.jpg', '0003.jpg'],
      );
      await _pumpReader(tester, lib, doc);
      expect(doc.rtl, isFalse);

      await _tapAt(tester, const Offset(400, 300)); // show controls
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read right to left (manga)'));
      await tester.pump();
      expect(doc.rtl, isTrue);

      // And the tap zones follow the new direction immediately.
      await _tapAt(tester, const Offset(100, 300));
      expect(doc.lastPage, 1);
    });
  });

  group('Comic vertical mode and style switching', () {
    setUpAll(_mockChannels);

    testWidgets('vertical scrolling follows the pages of a comic', (tester) async {
      final lib = Library();
      final doc = PdfDoc(
        id: 'comic',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 100,
        pageCount: 5,
        addedMs: 1,
        style: 'vertical',
        kind: 'comic',
        pageFiles: [
          '0001.jpg',
          '0002.jpg',
          '0003.jpg',
          '0004.jpg',
          '0005.jpg',
        ],
      );
      // Default 800x600 surface, exactly like the v2.2.3 scroll test:
      // on a taller surface the scroll anchor cannot reach the last
      // page of a short book (pre-existing quirk, see README).
      await _pumpReader(tester, lib, doc);
      expect(find.byType(ListView), findsOneWidget);
      expect(doc.lastPage, 0);

      // Drag down through the book; progress must follow the scroll.
      for (var i = 0; i < 8 && doc.lastPage < 4; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -1500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(doc.lastPage, 4);
    });

    testWidgets('switching horizontal to vertical keeps the page', (tester) async {
      final lib = Library();
      final doc = PdfDoc(
        id: 'comic',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 100,
        pageCount: 3,
        lastPage: 1,
        addedMs: 1,
        kind: 'comic',
        pageFiles: ['0001.jpg', '0002.jpg', '0003.jpg'],
      );
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);
      expect(doc.lastPage, 1);

      // Horizontal -> vertical (same steps as the v2.2.3 mode-switch test).
      await _tapAt(tester, const Offset(400, 700)); // show controls
      await tester.tap(find.byTooltip('Reading style'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Vertical scrolling'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(doc.style, 'vertical');
      expect(doc.lastPage, 1);
      expect(find.byType(ListView), findsOneWidget);
    });
  });
}

void _mockChannels() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
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
        case 'getPageCount':
          return 3;
        case 'detectPanels':
          return <Map<String, dynamic>>[];
        case 'imageSize':
          // Comic pages are 800x1200 portrait.
          return {'width': 800, 'height': 1200};
        default:
          return null;
      }
    },
  );
  final binding = TestDefaultBinaryMessengerBinding.instance;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter/platform', JSONMethodCodec()),
    (MethodCall call) async => null,
  );
}

Future<void> _pumpReader(
    WidgetTester tester, Library lib, PdfDoc doc) async {
  lib.settings.controlsHintShown = true;
  if (!lib.docs.contains(doc)) lib.docs.add(doc);
  await tester.pumpWidget(MaterialApp(home: ReaderPage(library: lib, doc: doc)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// A tap plus time for the 300 ms page-turn animation to finish.
Future<void> _tapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

/// Deliver a real volume event through the events channel, exactly as
/// the Android host does, then let page animations finish.
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
