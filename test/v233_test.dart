import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/file_browser.dart';
import 'package:pdfreader/library.dart';

// ---------------------------------------------------------------------------
// v2.3.3 — in-app file browser: the system picker on this phone will not
// return multi-select picks, so the app lists the shared storage itself
// and imports the ticked files through the same path as a picked file.
// These are plain tests (no widgets): the browser page itself is
// verified by MANUAL_TESTS section 12 on the phone.
// ---------------------------------------------------------------------------

String _filesDir = '/tmp';

void main() {
  group('browser listing', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v233_list_');
      addTearDown(() => dir.delete(recursive: true));
    });

    test('folders first, files in natural order, junk left out', () async {
      await Directory('${dir.path}/Manga').create();
      await Directory('${dir.path}/.hidden').create();
      await Directory('${dir.path}/a folder').create();
      for (final name in [
        'page10.pdf',
        'page2.pdf',
        'page1.pdf',
        'notes.txt',
        '.secret.pdf',
        'song.mp3',
        'manga.cbz',
        'photo.png',
      ]) {
        await File('${dir.path}/$name').writeAsBytes([1, 2, 3]);
      }
      final entries = await listBrowserEntries(dir);
      expect(
          entries.map((e) => e.name).toList(),
          [
            'a folder',
            'Manga',
            'manga.cbz',
            'page1.pdf',
            'page2.pdf',
            'page10.pdf',
            'photo.png',
          ]);
      expect(entries.where((e) => e.isDir).length, 2);
      expect(entries.where((e) => !e.isDir).length, 5);
    });

    test('an unreadable folder reads as empty, not a throw', () async {
      final missing = Directory('${dir.path}/nope');
      expect(await listBrowserEntries(missing), isEmpty);
    });

    test('supported names', () {
      expect(isSupportedFileName('book.pdf'), isTrue);
      expect(isSupportedFileName('manga.CBZ'), isTrue);
      expect(isSupportedFileName('manga.cb7'), isTrue);
      expect(isSupportedFileName('arc.tar.gz'), isTrue);
      expect(isSupportedFileName('pic.bmp'), isTrue);
      expect(isSupportedFileName('notes.txt'), isFalse);
      expect(isSupportedFileName('song.mp3'), isFalse);
      expect(isSupportedFileName('.hidden.pdf'), isFalse);
    });
  });

  group('importLocalFiles (in-app selection)', () {
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
            case 'convertToJpeg':
              final dest = call.arguments['destPath'] as String;
              await File(dest).writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0]);
              return true;
            case 'extractSevenZ':
              final destDir = call.arguments['destDir'] as String;
              final files = {
                '001.jpg': [1],
                '002.jpg': [2],
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
      dir = await Directory.systemTemp.createTemp('v233_import_');
      _filesDir = dir.path;
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

    test('five ticked files import together, originals stay put', () async {
      final lib = await freshLib();
      final a = await writeFile('book1.pdf', pdfBytes([1]));
      final b = await writeFile('book2.pdf', pdfBytes([2]));
      final c = await writeFile(
          'manga.cbz', zipBytes({'001.jpg': [1], '002.jpg': [2]}));
      final d = await writeFile('photo.png', pngBytes());
      final e = await writeFile('manga.cb7',
          [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 1, 2, 3]);
      final progress = <int>[];
      final summary = await lib.importLocalFiles(
        [a.path, b.path, c.path, d.path, e.path],
        onProgress: (done, total) => progress.add(done),
      );

      expect(summary.cancelled, isFalse);
      expect(summary.total, 5);
      expect(summary.added,
          ['book1.pdf', 'book2.pdf', 'manga.cbz', 'photo.png', 'manga.cb7']);
      expect(summary.duplicates, isEmpty);
      expect(summary.failed, isEmpty);
      expect(progress, [1, 2, 3, 4, 5]);
      expect(lib.docs.length, 5);
      // The library keeps its own copies in filesDir/pdfs; the
      // originals the user ticked are untouched.
      for (final f in [a, b, c, d, e]) {
        expect(await f.exists(), isTrue);
      }
      // PDFs and comic archives keep the copied file as their path;
      // a single image points at its copy in the extracted folder.
      final byName = {for (final d in lib.docs) d.name: d};
      expect(byName['book1.pdf']!.path, contains('/pdfs/'));
      expect(byName['book2.pdf']!.path, contains('/pdfs/'));
      expect(byName['manga.cbz']!.path, contains('/pdfs/'));
      expect(byName['manga.cb7']!.path, contains('/pdfs/'));
      expect(byName['photo.png']!.path, contains('/comics/'));
    });

    test('one corrupt file does not stop the others', () async {
      final lib = await freshLib();
      final good = zipBytes({'001.jpg': [1]});
      final a = await writeFile('book1.pdf', pdfBytes([1]));
      final b = await writeFile('manga.cbz', good);
      final broken = await writeFile(
          'broken.cbz', good.sublist(0, good.length ~/ 2));
      final c = await writeFile('book2.pdf', pdfBytes([2]));
      final summary = await lib.importLocalFiles(
          [a.path, b.path, broken.path, c.path]);
      expect(summary.added, ['book1.pdf', 'manga.cbz', 'book2.pdf']);
      expect(summary.failed.length, 1);
      expect(summary.failed.first.name, 'broken.cbz');
      expect(lib.docs.length, 3);
    });

    test('a duplicate among the ticked files is reported', () async {
      final lib = await freshLib();
      final bytes = pdfBytes([7, 7, 7]);
      final first = await writeFile('book1.pdf', bytes);
      expect(
          await lib.importPicked(
              path: first.path, name: 'book1.pdf', size: bytes.length),
          ImportOutcome.added);
      final again = await writeFile('book1-copy.pdf', bytes);
      final b = await writeFile('book2.pdf', pdfBytes([8]));
      final summary =
          await lib.importLocalFiles([again.path, b.path]);
      expect(summary.added, ['book2.pdf']);
      expect(summary.duplicates, ['book1-copy.pdf']);
      expect(lib.docs.length, 2);
    });

    test('a file that vanished is reported, the rest import', () async {
      final lib = await freshLib();
      final a = await writeFile('book1.pdf', pdfBytes([1]));
      final gone = '${dir.path}/gone.pdf';
      final summary =
          await lib.importLocalFiles([gone, a.path]);
      expect(summary.added, ['book1.pdf']);
      expect(summary.failed.length, 1);
      expect(summary.failed.first.name, 'gone.pdf');
      expect(lib.docs.length, 1);
    });

    test('two files with the same name do not clobber each other',
        () async {
      final lib = await freshLib();
      final sub1 = Directory('${dir.path}/one')..createSync();
      final sub2 = Directory('${dir.path}/two')..createSync();
      final a = File('${sub1.path}/book.pdf');
      await a.writeAsBytes(pdfBytes([1]));
      final b = File('${sub2.path}/book.pdf');
      await b.writeAsBytes(pdfBytes([2]));
      final summary =
          await lib.importLocalFiles([a.path, b.path]);
      expect(summary.added, ['book.pdf', 'book.pdf']);
      expect(lib.docs.length, 2);
      expect(lib.docs[0].path, isNot(lib.docs[1].path));
      expect(lib.docs[1].path.contains('book (2).pdf'), isTrue);
    });
  });
}
