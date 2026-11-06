import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/library.dart';
import 'package:pdfreader/reader.dart';

// ---------------------------------------------------------------------------
// v2.3.4 — Manga mode: top to bottom, made for manga.
//
// A manga spread is one image running across two pages, so showing one
// page at a time left-to-right splits it. Manga mode flows top to
// bottom instead: the strip shows several pages at once (both pages of
// a spread together), and a single-page view shows one page at a time,
// swiped up and down. Saved per document, like the other styles.
// ---------------------------------------------------------------------------

void main() {
  group('Manga mode persistence', () {
    test('mangaPaged round-trips through JSON', () {
      final doc = PdfDoc(
        id: 'c',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 1,
        pageCount: 3,
        addedMs: 1,
        style: 'manga',
        kind: 'comic',
        mangaPaged: true,
      );
      final back = PdfDoc.fromJson(doc.toJson());
      expect(back.style, 'manga');
      expect(back.mangaPaged, isTrue);
    });

    test('old JSON without mangaPaged loads as the strip', () {
      final doc = PdfDoc(
        id: 'c',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 1,
        pageCount: 3,
        addedMs: 1,
        style: 'manga',
        kind: 'comic',
      );
      final json = doc.toJson()..remove('mangaPaged');
      final back = PdfDoc.fromJson(json);
      expect(back.style, 'manga');
      expect(back.mangaPaged, isFalse);
    });

    test('an unknown style still falls back to horizontal', () {
      final json = PdfDoc(
        id: 'c',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 1,
        pageCount: 3,
        addedMs: 1,
      ).toJson()
        ..['style'] = 'spread';
      expect(PdfDoc.fromJson(json).style, 'horizontal');
    });
  });

  group('Manga mode in the reader', () {
    setUpAll(_mockChannels);

    PdfDoc comic({String style = 'manga', bool mangaPaged = false}) =>
        PdfDoc(
          id: 'comic',
          name: 'manga.cbz',
          path: '/pdfs/manga.cbz',
          size: 100,
          pageCount: 3,
          addedMs: 1,
          style: style,
          kind: 'comic',
          mangaPaged: mangaPaged,
          pageFiles: ['0001.jpg', '0002.jpg', '0003.jpg'],
        );

    testWidgets('the strip scrolls top to bottom, several pages at once',
        (tester) async {
      final lib = Library();
      final doc = comic();
      // A tall phone screen: two 800x1200 pages fit at once.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);

      expect(find.byType(ListView), findsOneWidget);
      // Both pages of a spread are on screen together.
      expect(find.byType(Image).evaluate().length, greaterThanOrEqualTo(2));
      expect(doc.lastPage, 0);

      // Scroll down; progress follows the scroll.
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(doc.lastPage, greaterThan(0));
    });

    testWidgets('single page: one page at a time, vertical paging',
        (tester) async {
      final lib = Library();
      final doc = comic(mangaPaged: true);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);

      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.scrollDirection, Axis.vertical);
      expect(doc.lastPage, 0);

      // Bottom third turns forward, top third turns back.
      await _tapAt(tester, const Offset(400, 1300));
      expect(doc.lastPage, 1);
      await _tapAt(tester, const Offset(400, 100));
      expect(doc.lastPage, 0);
      // Centre tap only toggles the controls, never the page.
      await _tapAt(tester, const Offset(400, 700));
      expect(doc.lastPage, 0);
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('the style sheet offers Manga mode with strip / single page',
        (tester) async {
      final lib = Library();
      final doc = comic(style: 'horizontal');
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);

      await _tapAt(tester, const Offset(400, 700)); // show controls
      await tester.tap(find.byTooltip('Reading style'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Manga mode'), findsOneWidget);
      await tester.tap(find.text('Manga mode'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(doc.style, 'manga');
      expect(doc.mangaPaged, isFalse);
      expect(find.byType(ListView), findsOneWidget);

      // Reopen the sheet: the manga sub-options are there, and
      // switching to single page swaps the strip for a vertical
      // PageView without leaving the reader. (The controls are
      // still visible from the first sheet, so no tap is needed
      // to show them — tapping the middle would hide them.)
      await tester.tap(find.byTooltip('Reading style'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Strip'), findsOneWidget);
      expect(find.text('Single page'), findsOneWidget);
      await tester.tap(find.text('Single page'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(doc.mangaPaged, isTrue);
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.scrollDirection, Axis.vertical);
    });

    testWidgets('the menu flips manga between strip and single page',
        (tester) async {
      final lib = Library();
      final doc = comic();
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);
      expect(find.byType(ListView), findsOneWidget);

      await _tapAt(tester, const Offset(400, 700)); // show controls
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Manga: one page at a time'), findsOneWidget);
      await tester.tap(find.text('Manga: one page at a time'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(doc.mangaPaged, isTrue);
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.scrollDirection, Axis.vertical);
    });

    testWidgets('volume keys turn pages in the manga strip',
        (tester) async {
      final lib = Library();
      final doc = comic();
      await _pumpReader(tester, lib, doc);
      await _sendVolume(tester, 'volumeUp');
      expect(doc.lastPage, 1);
      await _sendVolume(tester, 'volumeDown');
      expect(doc.lastPage, 0);
    });

    testWidgets('volume keys turn pages in manga single page',
        (tester) async {
      final lib = Library();
      final doc = comic(mangaPaged: true);
      await _pumpReader(tester, lib, doc);
      await _sendVolume(tester, 'volumeUp');
      expect(doc.lastPage, 1);
      await _sendVolume(tester, 'volumeDown');
      expect(doc.lastPage, 0);
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
