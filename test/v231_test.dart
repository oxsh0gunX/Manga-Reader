import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/library.dart';

// ---------------------------------------------------------------------------
// v2.3.1 — multiple file selection: one picker session imports many files.
// The picker itself (ClipData + EXTRA_ALLOW_MULTIPLE) lives in
// MainActivity and cannot run in flutter test, so these tests drive
// importMany through a mocked pickFiles result — the exact list the
// native side returns. (There is deliberately no widget test of the
// home screen here: in a widget test the app's real file IO stalls —
// the tap fires but no document ever lands, even after real-time
// waits under runAsync — so the progress/summary flow is verified
// by MANUAL_TESTS section 11 on the phone instead.)
// ---------------------------------------------------------------------------

String _filesDir = '/tmp';

/// What the mocked picker returns for this test. Each entry is what
/// the native side hands back per file: {name, path, size}, or
/// {name, error} when that one file could not be copied.
List<Map<String, dynamic>> _picked = [];

void main() {
  group('importMany (one picker session, many files)', () {
    late Directory dir;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('pdfreader/native'),
        (MethodCall call) async {
          switch (call.method) {
            case 'getFilesDir':
              return _filesDir;
            case 'getCacheDir':
              return _filesDir;
            case 'getPageCount':
              return 3;
            case 'pickFiles':
              return _picked;
            case 'convertToJpeg':
              final dest = call.arguments['destPath'] as String;
              await File(dest).writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0]);
              return true;
            case 'extractSevenZ':
              final destDir = call.arguments['destDir'] as String;
              final files = {
                'sub/002.png': [2],
                '001.jpg': [1],
                'ComicInfo.xml': [60],
                '010.jpg': [10],
              };
              for (final e in files.entries) {
                final f = File('$destDir/${e.key}');
                await f.parent.create(recursive: true);
                await f.writeAsBytes(e.value);
              }
              return files.keys.toList();
            default:
              return null;
          }
        },
      );
    });

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v231_import_');
      _filesDir = dir.path;
      _picked = [];
      addTearDown(() => dir.delete(recursive: true));
    });

    Future<Library> freshLib() async {
      final lib = Library();
      await lib.load();
      return lib;
    }

    Future<File> writeFile(String name, List<int> bytes) async {
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes);
      return f;
    }

    List<int> pdfBytes(List<int> tail) =>
        [0x25, 0x50, 0x44, 0x46, ...tail]; // %PDF + body

    List<int> zipBytes(Map<String, List<int>> files) {
      final archive = Archive();
      for (final e in files.entries) {
        archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
      }
      return ZipEncoder().encode(archive);
    }

    // A minimal 1x1 PNG (signature + IHDR + IDAT + IEND).
    List<int> pngBytes() => [
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
          0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
          0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
          0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
          0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54,
          0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02,
          0x00, 0x01, 0xE5, 0x27, 0xDE, 0xFC,
          0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
          0xAE, 0x42, 0x60, 0x82,
        ];

    Map<String, dynamic> entry(File f, String name) => {
          'name': name,
          'path': f.path,
          'size': f.lengthSync(),
        };

    test('five different files import together in one session', () async {
      final lib = await freshLib();
      final a = await writeFile('book1.pdf', pdfBytes([1, 2, 3]));
      final b = await writeFile('book2.pdf', pdfBytes([4, 5, 6]));
      final c = await writeFile(
          'manga.cbz',
          zipBytes({'page2.jpg': [2], 'page1.jpg': [1], 'page10.jpg': [10]}));
      final d = await writeFile('photo.png', pngBytes());
      final e = await writeFile('manga.cb7',
          [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 1, 2, 3]);
      _picked = [
        entry(a, 'book1.pdf'),
        entry(b, 'book2.pdf'),
        entry(c, 'manga.cbz'),
        entry(d, 'photo.png'),
        entry(e, 'manga.cb7'),
      ];
      final progress = <int>[];
      final summary = await lib.importMany(
        onProgress: (done, total) => progress.add(done),
      );

      expect(summary.cancelled, isFalse);
      expect(summary.total, 5);
      expect(summary.added, [
        'book1.pdf',
        'book2.pdf',
        'manga.cbz',
        'photo.png',
        'manga.cb7',
      ]);
      expect(summary.duplicates, isEmpty);
      expect(summary.failed, isEmpty);
      expect(progress, [1, 2, 3, 4, 5]);
      expect(lib.docs.length, 5);
      expect(lib.docs.map((d) => d.kind).toList(),
          ['pdf', 'pdf', 'comic', 'image', 'comic']);
      expect(lib.docs[2].pageFiles, ['0001.jpg', '0002.jpg', '0003.jpg']);
    });

    test('one corrupt file does not stop the others', () async {
      final lib = await freshLib();
      final good = zipBytes({'001.jpg': [1]});
      final a = await writeFile('book1.pdf', pdfBytes([1]));
      final b = await writeFile('manga.cbz', good);
      final broken = await writeFile(
          'broken.cbz', good.sublist(0, good.length ~/ 2));
      final c = await writeFile('book2.pdf', pdfBytes([2]));
      final d = await writeFile('photo.png', pngBytes());
      _picked = [
        entry(a, 'book1.pdf'),
        entry(b, 'manga.cbz'),
        entry(broken, 'broken.cbz'),
        entry(c, 'book2.pdf'),
        entry(d, 'photo.png'),
      ];

      final summary = await lib.importMany();
      expect(summary.added,
          ['book1.pdf', 'manga.cbz', 'book2.pdf', 'photo.png']);
      expect(summary.failed.length, 1);
      expect(summary.failed.first.name, 'broken.cbz');
      expect(lib.docs.length, 4);
      expect(lib.docs.map((d) => d.name).toList(), summary.added);
    });

    test('a duplicate among the five is reported, the rest import',
        () async {
      final lib = await freshLib();
      final bytes = pdfBytes([7, 7, 7]);
      final first = await writeFile('book1.pdf', bytes);
      expect(
          await lib.importPicked(
              path: first.path, name: 'book1.pdf', size: bytes.length),
          ImportOutcome.added);
      final again = await writeFile('book1-copy.pdf', bytes);
      final b = await writeFile('book2.pdf', pdfBytes([8]));
      final c = await writeFile(
          'manga.cbz', zipBytes({'001.jpg': [1]}));
      final d = await writeFile('photo.png', pngBytes());
      final e = await writeFile('book3.pdf', pdfBytes([9]));
      _picked = [
        entry(again, 'book1-copy.pdf'),
        entry(b, 'book2.pdf'),
        entry(c, 'manga.cbz'),
        entry(d, 'photo.png'),
        entry(e, 'book3.pdf'),
      ];

      final summary = await lib.importMany();
      expect(summary.added,
          ['book2.pdf', 'manga.cbz', 'photo.png', 'book3.pdf']);
      expect(summary.duplicates, ['book1-copy.pdf']);
      expect(summary.failed, isEmpty);
      expect(lib.docs.length, 5);
    });

    test('cancelling the picker imports nothing', () async {
      final lib = await freshLib();
      _picked = [];
      final progress = <int>[];
      final summary = await lib.importMany(
        onProgress: (done, total) => progress.add(done),
      );
      expect(summary.cancelled, isTrue);
      expect(summary.total, 0);
      expect(progress, isEmpty);
      expect(lib.docs, isEmpty);
    });

    test('a single file still imports the old way', () async {
      final lib = await freshLib();
      final a = await writeFile('only.pdf', pdfBytes([1, 2]));
      _picked = [entry(a, 'only.pdf')];
      final summary = await lib.importMany();
      expect(summary.cancelled, isFalse);
      expect(summary.added, ['only.pdf']);
      expect(lib.docs.length, 1);
      expect(lib.docs.first.name, 'only.pdf');
    });

    test('a file the picker could not copy is reported, rest import',
        () async {
      final lib = await freshLib();
      final a = await writeFile('book1.pdf', pdfBytes([1]));
      _picked = [
        {'name': 'lost.pdf', 'error': 'Could not open file'},
        entry(a, 'book1.pdf'),
      ];
      final summary = await lib.importMany();
      expect(summary.added, ['book1.pdf']);
      expect(summary.failed.length, 1);
      expect(summary.failed.first.name, 'lost.pdf');
      expect(summary.failed.first.message, 'Could not open file');
      expect(lib.docs.length, 1);
    });
  });

}
