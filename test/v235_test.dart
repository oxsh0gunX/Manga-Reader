import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/library.dart';
import 'package:pdfreader/reader.dart';

// ---------------------------------------------------------------------------
// v2.3.5 — Manga mode improvements.
//
// 1. No gaps in the manga strip: pages touch, so a spread reads as one
//    image. (Vertical mode keeps its 8px gap.)
// 2. Smoother scrolling: placeholders are sized like the real page, so
//    the list does not jump as images load; comic pages ahead are
//    pre-sized; manga turns glide a little slower and softer.
// 3. Auto-scroll: 1/2/3/5/10s per page or a custom interval, saved;
//    Start / Pause / Resume / Stop; a manual turn restarts the
//    interval; it pauses in the background and never restarts itself.
// 4. Manga auto-next: reaching the end opens the next document in
//    Manga mode, from its first page — no popup. The last document
//    in the library simply stops.
// ---------------------------------------------------------------------------

void main() {
  group('Auto-scroll interval persistence', () {
    test('autoScrollSeconds round-trips through settings JSON', () {
      final s = AppSettings(autoScrollSeconds: 7);
      expect(AppSettings.fromJson(s.toJson()).autoScrollSeconds, 7);
    });

    test('old settings JSON without autoScrollSeconds defaults to 3', () {
      final json = AppSettings().toJson()..remove('autoScrollSeconds');
      expect(AppSettings.fromJson(json).autoScrollSeconds, 3);
    });

    test('out-of-range autoScrollSeconds is clamped', () {
      final low = AppSettings().toJson()..['autoScrollSeconds'] = 0;
      expect(AppSettings.fromJson(low).autoScrollSeconds, 1);
      final high = AppSettings().toJson()..['autoScrollSeconds'] = 9999;
      expect(AppSettings.fromJson(high).autoScrollSeconds, 300);
    });
  });

  group('Manga mode v2.3.5 in the reader', () {
    setUpAll(_mockChannels);

    PdfDoc comic({
      String id = 'comic',
      String name = 'manga.cbz',
      String style = 'manga',
      bool mangaPaged = false,
      int pageCount = 3,
    }) =>
        PdfDoc(
          id: id,
          name: name,
          path: '/pdfs/$name',
          size: 100,
          pageCount: pageCount,
          addedMs: 1,
          style: style,
          kind: 'comic',
          mangaPaged: mangaPaged,
          pageFiles: [
            for (int i = 1; i <= pageCount; i++) '000$i.jpg',
          ],
        );

    testWidgets('manga strip pages touch with no gap', (tester) async {
      final lib = Library();
      final doc = comic();
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);

      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(Image).evaluate().length, greaterThanOrEqualTo(2));
      final firstBottom =
          tester.getBottomRight(find.byType(Image).at(0)).dy;
      final secondTop = tester.getTopLeft(find.byType(Image).at(1)).dy;
      expect(secondTop, firstBottom);
    });

    testWidgets('vertical mode keeps its gap between pages',
        (tester) async {
      final lib = Library();
      final doc = comic(style: 'vertical');
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);

      expect(find.byType(ListView), findsOneWidget);
      final firstBottom =
          tester.getBottomRight(find.byType(Image).at(0)).dy;
      final secondTop = tester.getTopLeft(find.byType(Image).at(1)).dy;
      expect(secondTop - firstBottom, 8);
    });

    testWidgets('a drag during a programmatic scroll does not fight it',
        (tester) async {
      final lib = Library();
      final doc = comic();
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);

      // Start a volume-key scroll, then grab the list mid-animation.
      await _sendVolumeNoPump(tester, 'volumeUp');
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(doc.lastPage, inInclusiveRange(0, 2));

      // The reader is still responsive afterwards.
      final before = doc.lastPage;
      await _sendVolume(tester, 'volumeUp');
      expect(doc.lastPage, before + 1);
    });

    testWidgets('auto-scroll advances one page per interval',
        (tester) async {
      final lib = Library();
      lib.settings.autoScrollSeconds = 1;
      final doc = comic(mangaPaged: true);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);
      await _startAutoScroll(tester);

      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 2);
    });

    testWidgets('auto-scroll pause, resume and stop', (tester) async {
      final lib = Library();
      lib.settings.autoScrollSeconds = 1;
      final doc = comic(mangaPaged: true);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);
      await _startAutoScroll(tester);

      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 1);

      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(doc.lastPage, 1);
      expect(find.textContaining('Paused'), findsOneWidget);

      await tester.tap(find.byTooltip('Resume'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 2);

      await tester.tap(find.byTooltip('Stop auto-scroll'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(doc.lastPage, 2);
      expect(find.textContaining('Scrolling'), findsNothing);
      expect(find.byTooltip('Pause'), findsNothing);
    });

    testWidgets('pausing and resuming again never runs two timers',
        (tester) async {
      final lib = Library();
      lib.settings.autoScrollSeconds = 1;
      final doc = comic(mangaPaged: true, pageCount: 4);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);
      await _startAutoScroll(tester);

      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 1);

      // Pause and resume twice in a row; each resume must replace
      // the timer, not stack another one.
      await _openAutoScrollSheet(tester);
      await tester.tap(find.text('Pause'));
      await tester.pump();
      await tester.tap(find.text('Resume'));
      await tester.pump();
      await tester.tap(find.text('Pause'));
      await tester.pump();
      await tester.tap(find.text('Resume'));
      await tester.pump();
      await tester.tapAt(const Offset(400, 100)); // dismiss the sheet
      await tester.pump();

      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 2);
    });

    testWidgets('a custom interval is saved and honoured', (tester) async {
      final lib = Library();
      final doc = comic(mangaPaged: true);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);

      // The Custom… option opens a dialog; saving 7 stores it.
      await _openAutoScrollSheet(tester);
      await tester.tap(find.text('Custom…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '7');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(lib.settings.autoScrollSeconds, 7);
      expect(find.text('Custom: 7 seconds per page'), findsOneWidget);

      // A 2-second interval waits the full 2 seconds per page.
      lib.settings.autoScrollSeconds = 2;
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1900));
      expect(doc.lastPage, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(doc.lastPage, 1);
    });

    testWidgets('a manual turn restarts the interval clock',
        (tester) async {
      final lib = Library();
      final doc = comic(mangaPaged: true);
      lib.settings.autoScrollSeconds = 2;
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);
      await _startAutoScroll(tester);

      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 0);
      // Turn a page by hand one second in: the clock restarts, so
      // the next automatic turn is two full seconds later, not one.
      await _sendVolume(tester, 'volumeUp');
      expect(doc.lastPage, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 2);
    });

    testWidgets('auto-scroll pauses when the app goes to the background',
        (tester) async {
      final lib = Library();
      lib.settings.autoScrollSeconds = 1;
      final doc = comic(mangaPaged: true);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);
      await _startAutoScroll(tester);

      await tester.pump(const Duration(milliseconds: 500));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(doc.lastPage, 0);
      expect(find.textContaining('Paused'), findsOneWidget);

      // It does not resume by itself; the user taps Resume.
      await tester.tap(find.byTooltip('Resume'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 1);
    });

    testWidgets('auto-scroll stops at the end of the library',
        (tester) async {
      final lib = Library();
      lib.settings.autoScrollSeconds = 1;
      final doc = comic(mangaPaged: true);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);
      await _startAutoScroll(tester);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(doc.lastPage, 2);
      // The next tick has no next document: it stops, no restart.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(doc.lastPage, 2);
      expect(find.textContaining('Scrolling'), findsNothing);
      expect(find.text('End of library — auto-scroll stopped'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(doc.lastPage, 2);
    });

    testWidgets('manga strip: scrolling to the bottom opens the next document',
        (tester) async {
      final lib = Library();
      final first = comic(id: 'ch1', name: 'chapter1.cbz');
      final second = comic(id: 'ch2', name: 'chapter2.cbz');
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, first);
      lib.docs.add(second);

      await _tapAt(tester, const Offset(400, 700)); // show controls
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pump();
      // The short pause at the bottom, then the next document.
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('chapter2.cbz'), findsOneWidget);
      expect(second.style, 'manga');
      expect(second.mangaPaged, isFalse);
      expect(second.lastPage, 0);
    });

    testWidgets(
        'manga single page: advancing past the last page opens the next document',
        (tester) async {
      final lib = Library();
      final first = comic(id: 'ch1', name: 'chapter1.cbz', mangaPaged: true);
      final second = comic(id: 'ch2', name: 'chapter2.cbz');
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, first);
      lib.docs.add(second);

      await _tapAt(tester, const Offset(400, 1300));
      await _tapAt(tester, const Offset(400, 1300));
      expect(first.lastPage, 2);
      // One more advance past the end: the next document, manga
      // mode, from its first page. No popup.
      await _tapAt(tester, const Offset(400, 1300));
      expect(second.style, 'manga');
      expect(second.mangaPaged, isTrue);
      expect(second.lastPage, 0);
      await _tapAt(tester, const Offset(400, 700)); // show controls
      expect(find.text('chapter2.cbz'), findsOneWidget);
    });

    testWidgets('manga auto-next stops at the last document',
        (tester) async {
      final lib = Library();
      final doc = comic(mangaPaged: true);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, doc);

      await _tapAt(tester, const Offset(400, 1300));
      await _tapAt(tester, const Offset(400, 1300));
      expect(doc.lastPage, 2);
      await _tapAt(tester, const Offset(400, 1300));
      await tester.pump(const Duration(seconds: 2));
      expect(doc.lastPage, 2);
    });

    testWidgets('the strip does not auto-open the next document in vertical mode',
        (tester) async {
      final lib = Library();
      final first = comic(
          id: 'v1', name: 'vertical.pdf', style: 'vertical', pageCount: 3);
      final second = comic(id: 'v2', name: 'next.pdf', style: 'vertical');
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, first);
      lib.docs.add(second);

      await _tapAt(tester, const Offset(400, 700)); // show controls
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      expect(find.text('vertical.pdf'), findsOneWidget);
      expect(find.text('next.pdf'), findsNothing);
    });

    testWidgets('auto-scroll continues into the next document',
        (tester) async {
      final lib = Library();
      lib.settings.autoScrollSeconds = 1;
      final first = comic(id: 'ch1', name: 'chapter1.cbz', mangaPaged: true);
      final second = comic(id: 'ch2', name: 'chapter2.cbz');
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpReader(tester, lib, first);
      lib.docs.add(second);
      await _startAutoScroll(tester);

      await tester.pump(const Duration(seconds: 1));
      expect(first.lastPage, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(first.lastPage, 2);
      // The tick at the last page moves to the next document and
      // keeps scrolling from its first page.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(second.style, 'manga');
      expect(second.lastPage, 0);
      expect(find.textContaining('Scrolling'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(second.lastPage, 1);
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

/// A tap plus time for the 400 ms manga page-turn animation to finish.
Future<void> _tapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
}

/// Deliver a real volume event through the events channel, exactly as
/// the Android host does, then let page animations finish.
Future<void> _sendVolume(WidgetTester tester, String method) async {
  await _sendVolumeNoPump(tester, method);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
}

/// Deliver the volume event without pumping, so the test can act
/// while the page-turn animation is still running.
Future<void> _sendVolumeNoPump(WidgetTester tester, String method) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'pdfreader/events',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    (_) {},
  );
}

/// Open the auto-scroll sheet from the reader's overflow menu.
Future<void> _openAutoScrollSheet(WidgetTester tester) async {
  // The controls may already be visible (e.g. right after starting
  // auto-scroll from the sheet); a centre tap would hide them again.
  if (find.byType(AppBar).evaluate().isEmpty) {
    await _tapAt(tester, const Offset(400, 700)); // show controls
  }
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  // The menu item reads 'Auto-scroll…' when off, and
  // 'Auto-scroll: scrolling' / 'Auto-scroll: paused' while it runs.
  final off = find.text('Auto-scroll…');
  if (off.evaluate().isNotEmpty) {
    await tester.tap(off);
  } else {
    await tester.tap(find.textContaining('Auto-scroll:'));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Open the sheet and start auto-scroll.
Future<void> _startAutoScroll(WidgetTester tester) async {
  await _openAutoScrollSheet(tester);
  expect(find.text('Auto-scroll'), findsOneWidget);
  await tester.tap(find.text('Start'));
  await tester.pump();
  expect(find.textContaining('Scrolling'), findsOneWidget);
}
