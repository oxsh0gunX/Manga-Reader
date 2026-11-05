import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/comic.dart';
import 'package:pdfreader/library.dart';

// ---------------------------------------------------------------------------
// Format detection (extension + magic bytes)
// ---------------------------------------------------------------------------

void main() {
  group('Format detection', () {
    Uint8List header(List<int> bytes, {int length = 512}) {
      final h = Uint8List(length);
      for (var i = 0; i < bytes.length && i < length; i++) {
        h[i] = bytes[i];
      }
      return h;
    }

    test('PDF by magic + extension', () {
      expect(detectFormat('book.pdf', header([0x25, 0x50, 0x44, 0x46])),
          ComicFormat.pdf);
    });

    test('CBZ and ZIP by PK magic', () {
      final zip = header([0x50, 0x4B, 0x03, 0x04]);
      expect(detectFormat('manga.cbz', zip), ComicFormat.zip);
      expect(detectFormat('manga.zip', zip), ComicFormat.zip);
    });

    test('CB7 by 7z magic', () {
      expect(
          detectFormat(
              'manga.cb7', header([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])),
          ComicFormat.sevenZ);
    });

    test('CBR by RAR magic', () {
      expect(
          detectFormat(
              'manga.cbr', header([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])),
          ComicFormat.rar);
    });

    test('CBT by ustar magic at offset 257', () {
      final h = header([], length: 512);
      const ustar = [0x75, 0x73, 0x74, 0x61, 0x72];
      for (var i = 0; i < ustar.length; i++) {
        h[257 + i] = ustar[i];
      }
      expect(detectFormat('manga.cbt', h), ComicFormat.tar);
    });

    test('compressed tar by gzip/bzip2/xz magic', () {
      expect(detectFormat('manga.tar.gz', header([0x1F, 0x8B])),
          ComicFormat.tar);
      expect(detectFormat('manga.tgz', header([0x1F, 0x8B])),
          ComicFormat.tar);
      expect(detectFormat('manga.tar.bz2', header([0x42, 0x5A, 0x68])),
          ComicFormat.tar);
      expect(
          detectFormat('manga.tar.xz',
              header([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])),
          ComicFormat.tar);
    });

    test('single images by magic + extension', () {
      expect(detectFormat('p.jpg', header([0xFF, 0xD8, 0xFF])),
          ComicFormat.image);
      expect(
          detectFormat('p.png',
              header([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
          ComicFormat.image);
      expect(detectFormat('p.gif', header([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
          ComicFormat.image);
      final webp = header([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);
      expect(detectFormat('p.webp', webp), ComicFormat.image);
      expect(detectFormat('p.bmp', header([0x42, 0x4D])), ComicFormat.image);
    });

    test('a file whose name lies about its contents is refused', () {
      expect(
          () => detectFormat('manga.cbz', header([0x25, 0x50, 0x44, 0x46])),
          throwsA(isA<ComicError>()));
      expect(
          () => detectFormat('book.pdf', header([0x50, 0x4B, 0x03, 0x04])),
          throwsA(isA<ComicError>()));
    });

    test('an unknown file is refused', () {
      expect(() => detectFormat('notes.txt', header([1, 2, 3, 4, 5])),
          throwsA(isA<ComicError>()));
    });

    test('a missing extension falls back to the magic bytes', () {
      expect(detectFormat('manga', header([0x50, 0x4B, 0x03, 0x04])),
          ComicFormat.zip);
    });
  });

  group('Natural page order', () {
    test('page1, page2, page10 — not page1, page10, page2', () {
      final names = ['page10.jpg', 'page1.jpg', 'page2.jpg'];
      names.sort(naturalCompare);
      expect(names, ['page1.jpg', 'page2.jpg', 'page10.jpg']);
    });

    test('zero-padded and bare numbers interleave', () {
      final names = ['010.png', '002.png', '1.png', '9.png'];
      names.sort(naturalCompare);
      expect(names, ['1.png', '002.png', '9.png', '010.png']);
    });

    test('text compares case-insensitively, folders stay in order', () {
      final names = ['Vol 2/003.jpg', 'vol 1/001.jpg', 'vol 1/002.jpg'];
      names.sort(naturalCompare);
      expect(names, ['vol 1/001.jpg', 'vol 1/002.jpg', 'Vol 2/003.jpg']);
    });
  });

  group('ZIP / TAR extraction (real archives, off the UI isolate)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('comic_extract_');
      addTearDown(() => dir.delete(recursive: true));
    });

    List<int> zipBytes(Map<String, List<int>> files) {
      final archive = Archive();
      for (final e in files.entries) {
        archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
      }
      return ZipEncoder().encode(archive);
    }

    List<int> tarBytes(Map<String, List<int>> files) {
      final archive = Archive();
      for (final e in files.entries) {
        archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
      }
      return TarEncoder().encode(archive);
    }

    test('CBZ: pages come out in natural order, non-images dropped', () async {
      final bytes = zipBytes({
        'page10.jpg': [10],
        'ComicInfo.xml': [60, 120, 109, 108, 47, 62],
        'page1.jpg': [1],
        'sub/page2.jpg': [2],
        '.hidden.jpg': [9],
        'page3.png': [3],
      });
      final file = File('${dir.path}/book.cbz');
      await file.writeAsBytes(bytes);
      final dest = Directory('${dir.path}/out')..createSync();

      final pages = await extractArchivePages(
        archivePath: file.path,
        destDir: dest.path,
        format: ComicFormat.zip,
      );
      // Sorted by full path, naturally: the top-level pages come
      // first (page1, page3, page10), then the subfolder's page2.
      expect(pages, ['0001.jpg', '0002.png', '0003.jpg', '0004.jpg']);
      expect(await File('${dest.path}/0001.jpg').readAsBytes(), [1]);
      expect(await File('${dest.path}/0002.png').readAsBytes(), [3]);
      expect(await File('${dest.path}/0003.jpg').readAsBytes(), [10]);
      expect(await File('${dest.path}/0004.jpg').readAsBytes(), [2]);
    });

    test('CBT: tar pages extract in natural order', () async {
      final bytes = tarBytes({
        '003.jpg': [3],
        '001.jpg': [1],
        '002.jpg': [2],
      });
      final file = File('${dir.path}/book.cbt');
      await file.writeAsBytes(bytes);
      final dest = Directory('${dir.path}/out')..createSync();

      final pages = await extractArchivePages(
        archivePath: file.path,
        destDir: dest.path,
        format: ComicFormat.tar,
      );
      expect(pages, ['0001.jpg', '0002.jpg', '0003.jpg']);
    });

    test('gzipped tar extracts too', () async {
      final tar = tarBytes({'001.jpg': [1], '002.jpg': [2]});
      final file = File('${dir.path}/book.tar.gz');
      await file.writeAsBytes(gzip.encode(tar));
      final dest = Directory('${dir.path}/out')..createSync();

      final pages = await extractArchivePages(
        archivePath: file.path,
        destDir: dest.path,
        format: ComicFormat.tar,
      );
      expect(pages, ['0001.jpg', '0002.jpg']);
    });

    test('a truncated archive fails with a clear message', () async {
      final bytes = zipBytes({'001.jpg': [1], '002.jpg': [2]});
      final file = File('${dir.path}/broken.cbz');
      await file.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));
      final dest = Directory('${dir.path}/out')..createSync();

      expect(
        extractArchivePages(
          archivePath: file.path,
          destDir: dest.path,
          format: ComicFormat.zip,
        ),
        throwsA(isA<ComicError>()),
      );
    });

    test('an archive with no images fails with a clear message', () async {
      final bytes = zipBytes({'readme.txt': [104, 105]});
      final file = File('${dir.path}/empty.cbz');
      await file.writeAsBytes(bytes);
      final dest = Directory('${dir.path}/out')..createSync();

      expect(
        extractArchivePages(
          archivePath: file.path,
          destDir: dest.path,
          format: ComicFormat.zip,
        ),
        throwsA(predicate<ComicError>(
            (e) => e.message.contains('No images'))),
      );
    });

    test('a gzip file that is not a tar fails', () async {
      final file = File('${dir.path}/notatar.tar.gz');
      await file.writeAsBytes(gzip.encode([1, 2, 3, 4]));
      final dest = Directory('${dir.path}/out')..createSync();

      expect(
        extractArchivePages(
          archivePath: file.path,
          destDir: dest.path,
          format: ComicFormat.tar,
        ),
        throwsA(isA<ComicError>()),
      );
    });
  });

  group('Import flow', () {
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
              // Simulate the native BMP -> JPEG conversion: write a
              // stand-in JPEG at the destination and report success.
              final dest = call.arguments['destPath'] as String;
              await File(dest).writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0]);
              return true;
            case 'extractSevenZ':
              // Simulate the native 7z extractor: write the entries
              // under their archive paths and return them in archive
              // order, including one non-image file.
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
      dir = await Directory.systemTemp.createTemp('comic_import_');
      _filesDir = dir.path;
      addTearDown(() => dir.delete(recursive: true));
    });

    Future<Library> freshLib() async {
      final lib = Library();
      await lib.load();
      return lib;
    }

    List<int> zipBytes(Map<String, List<int>> files) {
      final archive = Archive();
      for (final e in files.entries) {
        archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
      }
      return ZipEncoder().encode(archive);
    }

    test('CBZ imports as a comic with pages in natural order', () async {
      final lib = await freshLib();
      final file = File('${dir.path}/manga.cbz');
      await file.writeAsBytes(zipBytes({
        'page10.jpg': [10],
        'page1.jpg': [1],
        'page2.jpg': [2],
      }));

      expect(
          await lib.importPicked(
              path: file.path, name: 'manga.cbz', size: 10),
          ImportOutcome.added);
      expect(lib.docs.length, 1);
      final doc = lib.docs.first;
      expect(doc.kind, 'comic');
      expect(doc.pageCount, 3);
      expect(doc.pageFiles, ['0001.jpg', '0002.jpg', '0003.jpg']);
      expect(doc.rtl, isFalse);
      // Pages exist in the app-private folder, in reading order.
      final pagesDir = Directory(lib.comicsDirFor(doc.id));
      expect(await File('${pagesDir.path}/0001.jpg').readAsBytes(), [1]);
      expect(await File('${pagesDir.path}/0003.jpg').readAsBytes(), [10]);
      expect(lib.comicPagePath(doc, 0), '${pagesDir.path}/0001.jpg');
    });

    test('the same CBZ under another name is a duplicate', () async {
      final lib = await freshLib();
      final bytes = zipBytes({'001.jpg': [1]});
      final first = File('${dir.path}/a.cbz');
      await first.writeAsBytes(bytes);
      final copy = File('${dir.path}/b.cbz');
      await copy.writeAsBytes(bytes);

      expect(
          await lib.importPicked(path: first.path, name: 'a.cbz', size: 1),
          ImportOutcome.added);
      expect(
          await lib.importPicked(path: copy.path, name: 'b.cbz', size: 1),
          ImportOutcome.duplicate);
      expect(lib.docs.length, 1);
      expect(await copy.exists(), isFalse);
    });

    test('a different CBZ with the same filename still imports', () async {
      final lib = await freshLib();
      final a = Directory('${dir.path}/a')..createSync();
      final b = Directory('${dir.path}/b')..createSync();
      final first = File('${a.path}/manga.cbz');
      await first.writeAsBytes(zipBytes({'001.jpg': [1]}));
      final second = File('${b.path}/manga.cbz');
      await second.writeAsBytes(zipBytes({'001.jpg': [2]}));

      expect(
          await lib.importPicked(
              path: first.path, name: 'manga.cbz', size: 1),
          ImportOutcome.added);
      expect(
          await lib.importPicked(
              path: second.path, name: 'manga.cbz', size: 1),
          ImportOutcome.added);
      expect(lib.docs.length, 2);
    });

    test('a BMP page inside a CBZ is converted to JPEG', () async {
      final lib = await freshLib();
      final file = File('${dir.path}/bmp.cbz');
      await file.writeAsBytes(zipBytes({
        '001.bmp': [0x42, 0x4D, 1, 2],
        '002.jpg': [2],
      }));

      expect(
          await lib.importPicked(path: file.path, name: 'bmp.cbz', size: 1),
          ImportOutcome.added);
      final doc = lib.docs.first;
      expect(doc.pageFiles, ['0001.jpg', '0002.jpg']);
      final pagesDir = Directory(lib.comicsDirFor(doc.id));
      expect(await File('${pagesDir.path}/0001.jpg').exists(), isTrue);
      expect(await File('${pagesDir.path}/0001.bmp').exists(), isFalse);
    });

    test('7z imports through the native extractor, sorted and renamed',
        () async {
      final lib = await freshLib();
      final file = File('${dir.path}/manga.cb7');
      // The bytes only need the right magic: extraction is mocked.
      await file.writeAsBytes(
          [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 0]);

      expect(
          await lib.importPicked(
              path: file.path, name: 'manga.cb7', size: 8),
          ImportOutcome.added);
      final doc = lib.docs.first;
      expect(doc.kind, 'comic');
      // Archive order was sub/002.png, 001.jpg, 010.jpg; natural
      // sort gives 001.jpg, 010.jpg, sub/002.png.
      expect(doc.pageFiles, ['0001.jpg', '0002.jpg', '0003.png']);
      final pagesDir = Directory(lib.comicsDirFor(doc.id));
      expect(await File('${pagesDir.path}/0001.jpg').readAsBytes(), [1]);
      expect(await File('${pagesDir.path}/0002.jpg').readAsBytes(), [10]);
      expect(await File('${pagesDir.path}/0003.png').readAsBytes(), [2]);
      // The non-image file is gone and the empty subfolder is removed.
      expect(await File('${pagesDir.path}/ComicInfo.xml').exists(), isFalse);
      expect(await Directory('${pagesDir.path}/sub').exists(), isFalse);
    });

    test('a CBR is refused as unsupported, with a clear message', () async {
      final lib = await freshLib();
      final file = File('${dir.path}/manga.cbr');
      await file.writeAsBytes(
          [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 1, 2, 3]);

      expect(
          await lib.importPicked(
              path: file.path, name: 'manga.cbr', size: 10),
          ImportOutcome.unsupported);
      expect(lib.docs, isEmpty);
      expect(lib.lastImportMessage, contains('RAR'));
      expect(await file.exists(), isFalse);
    });

    test('a corrupt CBZ fails and leaves nothing behind', () async {
      final lib = await freshLib();
      final bytes = zipBytes({'001.jpg': [1]});
      final file = File('${dir.path}/broken.cbz');
      await file.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));

      expect(
          await lib.importPicked(
              path: file.path, name: 'broken.cbz', size: 1),
          ImportOutcome.failed);
      expect(lib.docs, isEmpty);
      expect(lib.lastImportMessage, isNotNull);
      expect(await file.exists(), isFalse);
      // No half-extracted pages folder is left.
      expect(await Directory('${dir.path}/comics').exists(), isFalse);
    });

    test('a single image imports as a one-page document', () async {
      final lib = await freshLib();
      // A minimal 1x1 PNG (signature + IHDR + IDAT + IEND).
      final png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
        0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54,
        0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05,
        0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
      ];
      final file = File('${dir.path}/cover.png');
      await file.writeAsBytes(png);

      expect(
          await lib.importPicked(
              path: file.path, name: 'cover.png', size: png.length),
          ImportOutcome.added);
      final doc = lib.docs.first;
      expect(doc.kind, 'image');
      expect(doc.pageCount, 1);
      expect(doc.pageFiles, ['0001.png']);
      expect(await File(doc.path).exists(), isTrue);
      expect(lib.comicPagePath(doc, 0), doc.path);
    });

    test('removing a comic deletes its extracted pages folder', () async {
      final lib = await freshLib();
      final file = File('${dir.path}/manga.cbz');
      await file.writeAsBytes(zipBytes({'001.jpg': [1]}));
      await lib.importPicked(path: file.path, name: 'manga.cbz', size: 1);
      final doc = lib.docs.first;
      final pagesDir = Directory(lib.comicsDirFor(doc.id));
      expect(await pagesDir.exists(), isTrue);

      await lib.remove(doc);
      expect(lib.docs, isEmpty);
      expect(await pagesDir.exists(), isFalse);
    });
  });

  group('PdfDoc JSON with comics', () {
    test('kind, rtl and pageFiles round-trip', () {
      final doc = PdfDoc(
        id: 'c1',
        name: 'manga.cbz',
        path: '/pdfs/manga.cbz',
        size: 10,
        pageCount: 3,
        addedMs: 1,
        kind: 'comic',
        rtl: true,
        pageFiles: ['0001.jpg', '0002.jpg', '0003.jpg'],
      );
      final back = PdfDoc.fromJson(doc.toJson());
      expect(back.kind, 'comic');
      expect(back.rtl, isTrue);
      expect(back.pageFiles, ['0001.jpg', '0002.jpg', '0003.jpg']);
    });

    test('entries saved before v2.3.0 load as PDFs', () {
      final doc = PdfDoc.fromJson({
        'id': 'old',
        'name': 'book.pdf',
        'path': '/pdfs/book.pdf',
        'size': 5,
        'pageCount': 4,
        'lastPage': 0,
        'lastOpenedMs': 0,
        'addedMs': 1,
        'style': 'horizontal',
        'panels': 0,
        'frameLayout': 'auto',
        'customPanels': {},
      });
      expect(doc.kind, 'pdf');
      expect(doc.rtl, isFalse);
      expect(doc.pageFiles, isNull);
    });
  });
}

String _filesDir = '/tmp';
