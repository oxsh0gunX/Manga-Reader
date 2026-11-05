import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/file_hash.dart';
import 'package:pdfreader/library.dart';
import 'package:pdfreader/reader.dart';

// ---------------------------------------------------------------------------
// SHA-256 (pure-Dart implementation, NIST test vectors)
// ---------------------------------------------------------------------------

void main() {
  group('SHA-256', () {
    test('empty input matches the NIST vector', () {
      expect(sha256Hex([]),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('"abc" matches the NIST vector', () {
      expect(sha256Hex('abc'.codeUnits),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('56-byte message matches the NIST vector', () {
      const msg =
          'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq';
      expect(sha256Hex(msg.codeUnits),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    });

    test('feeding in pieces gives the same hash as feeding at once', () {
      final h = Sha256();
      h.add('ab'.codeUnits);
      h.add('c'.codeUnits);
      expect(h.digest(), sha256Hex('abc'.codeUnits));
    });

    test('sha256File hashes a real file, chunked', () async {
      final dir = await Directory.systemTemp.createTemp('v223_hash_');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/a.bin');
      await f.writeAsBytes('abc'.codeUnits);
      expect(await sha256File(f),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });
  });

  group('Duplicate import detection', () {
    setUpAll(_mockNativeForImport);

    Future<File> writeFile(Directory dir, String name, List<int> bytes) async {
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes);
      return f;
    }

    test('same content under a different name is a duplicate', () async {
      final dir = await Directory.systemTemp.createTemp('v223_dup_');
      addTearDown(() => dir.delete(recursive: true));
      final lib = Library();
      final first = await writeFile(dir, 'book.pdf', [1, 2, 3, 4, 5]);
      final copy = await writeFile(dir, 'renamed.pdf', [1, 2, 3, 4, 5]);

      expect(
          await lib.importPicked(
              path: first.path, name: 'book.pdf', size: 5),
          ImportOutcome.added);
      expect(lib.docs.length, 1);

      expect(
          await lib.importPicked(
              path: copy.path, name: 'renamed.pdf', size: 5),
          ImportOutcome.duplicate);
      expect(lib.docs.length, 1);
      // The existing entry is untouched, and only the freshly picked
      // copy is deleted.
      expect(lib.docs.first.name, 'book.pdf');
      expect(lib.docs.first.contentHash, isNotNull);
      expect(await copy.exists(), isFalse);
      expect(await first.exists(), isTrue);
    });

    test('different content with the same filename is allowed', () async {
      final dir = await Directory.systemTemp.createTemp('v223_same_');
      addTearDown(() => dir.delete(recursive: true));
      final a = Directory('${dir.path}/a')..createSync();
      final b = Directory('${dir.path}/b')..createSync();
      final lib = Library();
      final first = await writeFile(a, 'book.pdf', [1, 2, 3]);
      final second = await writeFile(b, 'book.pdf', [9, 9, 9]);

      expect(
          await lib.importPicked(
              path: first.path, name: 'book.pdf', size: 3),
          ImportOutcome.added);
      expect(
          await lib.importPicked(
              path: second.path, name: 'book.pdf', size: 3),
          ImportOutcome.added);
      expect(lib.docs.length, 2);
      expect(lib.docs.map((d) => d.name).toSet(), {'book.pdf'});
      expect(lib.docs[0].path, isNot(lib.docs[1].path));
    });

    test('legacy entries without a hash are backfilled and then match',
        () async {
      final dir = await Directory.systemTemp.createTemp('v223_old_');
      addTearDown(() => dir.delete(recursive: true));
      final lib = Library();
      final legacyFile = await writeFile(dir, 'old.pdf', [7, 7, 7, 7]);
      lib.docs.add(PdfDoc(
        id: 'legacy',
        name: 'old.pdf',
        path: legacyFile.path,
        size: 4,
        pageCount: 2,
        addedMs: 1,
        // contentHash left null, as saved before v2.2.3.
      ));
      final copy = await writeFile(dir, 'old-copy.pdf', [7, 7, 7, 7]);

      expect(
          await lib.importPicked(
              path: copy.path, name: 'old-copy.pdf', size: 4),
          ImportOutcome.duplicate);
      expect(lib.docs.length, 1);
      expect(lib.docs.first.contentHash, sha256Hex([7, 7, 7, 7]));
    });

    test('contentHash round-trips through JSON; old JSON loads as null',
        () {
      final doc = PdfDoc(
        id: 'h',
        name: 'h.pdf',
        path: '/h.pdf',
        size: 10,
        pageCount: 1,
        addedMs: 1,
        contentHash: 'deadbeef',
      );
      final decoded =
          PdfDoc.fromJson(Map<String, dynamic>.from(doc.toJson()));
      expect(decoded.contentHash, 'deadbeef');
      final old = PdfDoc.fromJson({
        'id': 'o',
        'name': 'o.pdf',
        'path': '/o.pdf',
        'size': 10,
        'pageCount': 1,
        'addedMs': 1,
      });
      expect(old.contentHash, isNull);
    });
  });

  group('Tap navigation (page-by-page mode)', () {
    setUpAll(_mockChannels);

    testWidgets('right tap goes to the next page', (tester) async {
      final lib = Library();
      final doc = _doc('a.pdf', pageCount: 3, lastPage: 0);
      lib.docs.add(doc);
      await _pumpReader(tester, lib, doc);
      await _tapAt(tester, const Offset(700, 300));
      expect(doc.lastPage, 1);
    });

    testWidgets('left tap goes to the previous page', (tester) async {
      final lib = Library();
      final doc = _doc('a.pdf', pageCount: 3, lastPage: 1);
      lib.docs.add(doc);
      await _pumpReader(tester, lib, doc);
      await _tapAt(tester, const Offset(100, 300));
      expect(doc.lastPage, 0);
    });

    testWidgets('left tap on the first page stays put, no crash',
        (tester) async {
      final lib = Library();
      final doc = _doc('a.pdf', pageCount: 3, lastPage: 0);
      lib.docs.add(doc);
      await _pumpReader(tester, lib, doc);
      await _tapAt(tester, const Offset(100, 300));
      expect(doc.lastPage, 0);
      expect(find.textContaining('Opened'), findsNothing);
    });

    testWidgets(
        'right tap on the last page stays put and does not switch documents',
        (tester) async {
      final lib = Library();
      final a = _doc('a.pdf', pageCount: 2, lastPage: 1);
      final b = _doc('b.pdf', pageCount: 2, lastPage: 0);
      lib.docs.addAll([a, b]);
      await _pumpReader(tester, lib, a);
      await _tapAt(tester, const Offset(700, 300));
      expect(a.lastPage, 1);
      expect(find.text('Opened b.pdf'), findsNothing);
    });

    testWidgets('centre tap toggles the controls', (tester) async {
      final lib = Library();
      final doc = _doc('a.pdf', pageCount: 3, lastPage: 0);
      lib.docs.add(doc);
      await _pumpReader(tester, lib, doc);
      expect(find.byType(AppBar), findsNothing);
      await _tapAt(tester, const Offset(400, 300));
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('tap navigation is off in panel mode', (tester) async {
      final lib = Library();
      final doc = _doc('a.pdf', pageCount: 3, lastPage: 0, style: 'panel');
      lib.docs.add(doc);
      await _pumpReader(tester, lib, doc);
      await _tapAt(tester, const Offset(700, 300));
      expect(doc.lastPage, 0);
      // The tap still toggles the controls, as before.
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('tap navigation is off in the text view', (tester) async {
      final lib = Library();
      final doc = _doc('a.pdf', pageCount: 3, lastPage: 0);
      lib.docs.add(doc);
      await _pumpReader(tester, lib, doc);
      await _tapAt(tester, const Offset(400, 300)); // show controls
      await tester.tap(find.byTooltip('Select text'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await _tapAt(tester, const Offset(700, 300));
      expect(doc.lastPage, 0);
    });

    testWidgets('volume keys still turn pages after the tap change',
        (tester) async {
      final lib = Library();
      final doc = _doc('a.pdf', pageCount: 3, lastPage: 0);
      lib.docs.add(doc);
      await _pumpReader(tester, lib, doc);
      await _sendVolume(tester, 'volumeUp');
      expect(doc.lastPage, 1);
      await _sendVolume(tester, 'volumeDown');
      expect(doc.lastPage, 0);
    });
  });

  group('Vertical mode and mode switching', () {
    setUpAll(_mockChannels);

    testWidgets('vertical scrolling moves through pages and tracks progress',
        (tester) async {
      final lib = Library();
      final doc = _doc('v.pdf', pageCount: 5, lastPage: 0, style: 'vertical');
      lib.docs.add(doc);
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

    testWidgets('switching modes preserves the saved page', (tester) async {
      // A phone-tall surface: the style sheet holds six options plus a
      // note, which needs more height than the default 800x600 window.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lib = Library();
      final doc = _doc('m.pdf', pageCount: 5, lastPage: 2);
      lib.docs.add(doc);
      await _pumpReader(tester, lib, doc);
      expect(doc.lastPage, 2);

      // Horizontal -> vertical.
      await _tapAt(tester, const Offset(400, 700)); // show controls
      await tester.tap(find.byTooltip('Reading style'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Vertical scrolling'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(doc.lastPage, 2);
      expect(find.byType(ListView), findsOneWidget);

      // Vertical -> horizontal.
      await tester.tap(find.byTooltip('Reading style'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Horizontal'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(doc.lastPage, 2);
      expect(find.byType(PageView), findsOneWidget);
    });
  });
}

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

/// Native calls used by importPicked (pageCount) and the reader.
/// The render "file" deliberately does not exist: the reader's image
/// errorBuilder shows its message instead of crashing.
void _mockNativeForImport() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('pdfreader/native'),
    (MethodCall call) async {
      switch (call.method) {
        case 'getFilesDir':
          return '/tmp';
        case 'getCacheDir':
          return '/tmp';
        case 'getPageCount':
          return 3;
        default:
          return null;
      }
    },
  );
}

void _mockChannels() {
  _mockNativeForImport();
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
        case 'getPageCount':
          return 3;
        case 'detectPanels':
          return <Map<String, dynamic>>[];
        default:
          return null;
      }
    },
  );
  // SystemChrome calls from reader setup/cleanup use the JSON codec.
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter/platform', JSONMethodCodec()),
    (MethodCall call) async => null,
  );
}

Future<void> _pumpReader(
    WidgetTester tester, Library lib, PdfDoc doc) async {
  lib.settings.controlsHintShown = true;
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
