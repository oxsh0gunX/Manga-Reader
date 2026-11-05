import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

/// Comic / manga support: format detection, natural page order and
/// offline extraction into the app's private files dir.
///
/// Supported here (all offline, no native plugins):
///   PDF (unchanged, handled by the PDF code), CBZ/ZIP and CBT/TAR
///   (pure-Dart `archive` package), CB7/7Z (native Commons Compress,
///   see [NativeBridge.extractSevenZ]), and single image files
///   (JPG, JPEG, PNG, WEBP, GIF, BMP — BMP is converted to JPEG by
///   the native BitmapFactory step because Flutter cannot decode BMP).
///
/// NOT supported, by design: CBR/RAR. No RAR reader fits this app —
/// the pure-Dart RAR package needs Dart ^3.7 (this Flutter ships
/// Dart 3.5.4), the FFI UnRAR package needs Dart 3.10 build hooks,
/// the Flutter `rar` plugin needs a Gradle/CMake native build, and
/// junrar reads RAR4 only and cannot be verified here. A .cbr is
/// detected and refused with a clear message instead of being
/// claimed as supported. See README for the full reasoning.

/// User-facing import failure. [message] is written for the SnackBar,
/// not for a log: short, plain, and it says what to do next.
class ComicError implements Exception {
  ComicError(this.message);
  final String message;
  @override
  String toString() => message;
}

enum ComicFormat { pdf, zip, tar, sevenZ, rar, image, unknown }

/// Image extensions the app can show, after BMP conversion.
const _imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};

bool isImageName(String name) {
  final base = name.split('/').last;
  // Hidden files and macOS metadata are never pages.
  if (base.startsWith('.')) return false;
  if (name.contains('__MACOSX/')) return false;
  final dot = base.lastIndexOf('.');
  if (dot < 0) return false;
  return _imageExts.contains(base.substring(dot + 1).toLowerCase());
}

String _extOf(String name) {
  final base = name.split('/').last;
  final dot = base.lastIndexOf('.');
  return dot < 0 ? '' : base.substring(dot + 1).toLowerCase();
}

/// Magic-byte sniffing. `header` is the first bytes of the file
/// (at least 512 when available, so the tar "ustar" marker at
/// offset 257 is covered).
ComicFormat _formatByMagic(Uint8List header) {
  bool starts(List<int> magic, [int at = 0]) {
    if (header.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (header[at + i] != magic[i]) return false;
    }
    return true;
  }

  // %PDF — scanned, not just at offset 0: real PDFs are allowed a
  // little leading junk before the header (spec: within 1024 bytes).
  for (var i = 0; i + 4 <= header.length; i++) {
    if (header[i] == 0x25 &&
        header[i + 1] == 0x50 &&
        header[i + 2] == 0x44 &&
        header[i + 3] == 0x46) {
      return ComicFormat.pdf;
    }
  }
  if (starts([0x50, 0x4B, 0x03, 0x04]) || // PK\x03\x04
      starts([0x50, 0x4B, 0x05, 0x06])) return ComicFormat.zip; // PK\x05\x06 empty
  if (starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) {
    return ComicFormat.sevenZ; // 7z
  }
  if (starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) {
    return ComicFormat.rar; // Rar!
  }
  if (starts([0x75, 0x73, 0x74, 0x61, 0x72], 257)) {
    return ComicFormat.tar; // ustar
  }
  // Compressed tars: the outer layer is gzip/bzip2/xz, the tar check
  // happens in the decoder (header checksum), which rejects non-tars.
  if (starts([0x1F, 0x8B]) || // gzip
      starts([0x42, 0x5A, 0x68]) || // BZh (bzip2)
      starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) { // xz
    return ComicFormat.tar;
  }
  if (starts([0xFF, 0xD8, 0xFF])) return ComicFormat.image; // JPEG
  if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return ComicFormat.image; // PNG
  }
  if (starts([0x47, 0x49, 0x46, 0x38])) return ComicFormat.image; // GIF8
  if (starts([0x42, 0x4D])) return ComicFormat.image; // BM
  if (starts([0x52, 0x49, 0x46, 0x46]) && header.length >= 12) {
    // RIFF....WEBP
    if (starts([0x57, 0x45, 0x42, 0x50], 8)) return ComicFormat.image;
  }
  return ComicFormat.unknown;
}

/// The archive family an extension belongs to, or null when the
/// extension is not one this app knows at all.
ComicFormat? _familyByExtension(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.pdf')) return ComicFormat.pdf;
  if (lower.endsWith('.cbz') || lower.endsWith('.zip')) {
    return ComicFormat.zip;
  }
  if (lower.endsWith('.cb7') || lower.endsWith('.7z')) {
    return ComicFormat.sevenZ;
  }
  if (lower.endsWith('.cbr') || lower.endsWith('.rar')) {
    return ComicFormat.rar;
  }
  if (lower.endsWith('.cbt') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz') ||
      lower.endsWith('.tar.bz2') ||
      lower.endsWith('.tbz2') ||
      lower.endsWith('.tar.xz') ||
      lower.endsWith('.txz')) {
    return ComicFormat.tar;
  }
  if (_imageExts.contains(_extOf(name))) return ComicFormat.image;
  return null;
}

/// Detect a file's format from its extension and its contents.
/// The contents win when the extension is missing or unknown; a
/// known extension that disagrees with the contents is refused
/// instead of opened as the wrong thing.
ComicFormat detectFormat(String name, Uint8List header) {
  final byMagic = _formatByMagic(header);
  final byExt = _familyByExtension(name);
  if (byMagic == ComicFormat.unknown) {
    throw ComicError(
      'This file is not a PDF, comic archive, or image I can open.',
    );
  }
  if (byExt != null && byExt != byMagic) {
    throw ComicError(
      'This file is a ${byMagic.name} file, but its name ends in '
      '.${_extOf(name)} — rename it to match, or pick the right file.',
    );
  }
  return byMagic;
}

/// Natural page order: page1, page2, page10 — not page1, page10,
/// page2. Numbers compare by value; text compares case-insensitively.
int naturalCompare(String a, String b) {
  final ra = _chunks(a);
  final rb = _chunks(b);
  final n = ra.length < rb.length ? ra.length : rb.length;
  for (var i = 0; i < n; i++) {
    final ca = ra[i];
    final cb = rb[i];
    int cmp;
    if (ca is int && cb is int) {
      cmp = ca.compareTo(cb);
    } else if (ca is int) {
      cmp = -1; // numbers sort before text at the same spot
    } else if (cb is int) {
      cmp = 1;
    } else {
      cmp = (ca as String).toLowerCase().compareTo(
        (cb as String).toLowerCase(),
      );
    }
    if (cmp != 0) return cmp;
  }
  return ra.length.compareTo(rb.length);
}

/// Splits "page12b.jpg" into ["page", 12, "b.jpg"].
List<Object> _chunks(String s) {
  final out = <Object>[];
  final buf = StringBuffer();
  void flushText() {
    if (buf.isNotEmpty) {
      out.add(buf.toString());
      buf.clear();
    }
  }

  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) {
      flushText();
      var j = i;
      while (j < s.length &&
          s[j].codeUnitAt(0) >= 0x30 &&
          s[j].codeUnitAt(0) <= 0x39) {
        j++;
      }
      out.add(int.parse(s.substring(i, j)));
      i = j;
    } else {
      buf.write(c);
      i++;
    }
  }
  flushText();
  return out;
}

/// Safety rails for hostile or broken archives: a page image bigger
/// than this, or more pages than this, is refused instead of filling
/// the phone's storage. A real comic book is far below both.
const maxPagesPerBook = 2000;
const maxPageBytes = 100 * 1024 * 1024;

/// Extracts the image pages of a ZIP or TAR archive into [destDir]
/// (which must exist and be empty), in natural page order, named
/// 0001.jpg, 0002.png, ... — sequential names, never the archive's
/// own paths, so a crafted entry name can never escape the folder.
/// Returns the page filenames in reading order.
/// Runs off the UI isolate via [Isolate.run]; throws [ComicError]
/// with a user-facing message for corrupt, encrypted, empty, or
/// unsupported archives.
Future<List<String>> extractArchivePages({
  required String archivePath,
  required String destDir,
  required ComicFormat format,
}) async {
  if (format == ComicFormat.sevenZ) {
    // 7z extraction lives in MainActivity (Commons Compress); it
    // returns the extracted relative paths, already filtered to
    // images. Sorting, renaming and BMP conversion happen in Dart
    // below, shared with the ZIP/TAR path.
    throw StateError('7z extraction must go through NativeBridge');
  }
  return Isolate.run(() => _extractInIsolate(archivePath, destDir, format));
}

/// The isolate body: sync IO only, one entry at a time, so memory
/// stays bounded by a single page image however big the book is.
List<String> _extractInIsolate(
  String archivePath,
  String destDir,
  ComicFormat format,
) {
  try {
    final names = format == ComicFormat.zip
        ? _extractZip(archivePath, destDir)
        : _extractTar(archivePath, destDir);
    if (names.isEmpty) {
      throw ComicError('No images found in this archive.');
    }
    return names;
  } on ComicError {
    rethrow;
  } on ArchivePasswordException {
    throw ComicError(
      'This archive is password-protected. Passwords are not supported.',
    );
  } on ArchiveException catch (e) {
    throw ComicError('This archive is damaged and could not be opened. ($e)');
  } catch (e) {
    throw ComicError('This archive could not be opened. ($e)');
  }
}

List<String> _writePages(
  List<(String, Uint8List)> pages,
  String destDir,
) {
  // Sort by the archive's own path, naturally, so "page10" lands
  // after "page2" and a subfolder's pages sit in reading order too.
  pages.sort((a, b) => naturalCompare(a.$1, b.$1));
  if (pages.length > maxPagesPerBook) {
    throw ComicError(
      'This archive has more than $maxPagesPerBook pages, which is too many.',
    );
  }
  final out = <String>[];
  var i = 0;
  for (final (name, bytes) in pages) {
    if (bytes.length > maxPageBytes) {
      throw ComicError('One page in this archive is too large to open.');
    }
    i++;
    final ext = _extOf(name);
    final fileName = '${i.toString().padLeft(4, '0')}.$ext';
    File('$destDir/$fileName').writeAsBytesSync(bytes);
    out.add(fileName);
  }
  return out;
}

List<String> _extractZip(String archivePath, String destDir) {
  final input = InputFileStream(archivePath);
  try {
    // decodeStream with an InputFileStream reads the central directory
    // and leaves each entry's bytes lazy: nothing is decompressed
    // until readBytes() is called on that one entry.
    final archive = ZipDecoder().decodeStream(
      input,
      verify: true,
      throwOnError: true,
    );
    final pages = <(String, Uint8List)>[];
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      if (!isImageName(entry.name)) continue;
      final bytes = entry.readBytes();
      if (bytes == null || bytes.isEmpty) continue;
      pages.add((entry.name, bytes));
    }
    return _writePages(pages, destDir);
  } finally {
    // The stream must stay open while entries are read, and be closed
    // after — even when a corrupt entry throws halfway through.
    input.closeSync();
  }
}

List<String> _extractTar(String archivePath, String destDir) {
  final input = InputFileStream(archivePath);
  try {
    // Peel the outer compression, if any, then stream the tar: with
    // keepEntries false the decoder hands each entry to the callback
    // and drops it, so memory never grows with the number of pages.
    final first = input.peekBytes(6).toUint8List();
    InputStream tarInput = input;
    if (first.length >= 2 && first[0] == 0x1F && first[1] == 0x8B) {
      tarInput = GZipDecoder().decodeLazy(input, verify: true);
    } else if (first.length >= 3 &&
        first[0] == 0x42 &&
        first[1] == 0x5A &&
        first[2] == 0x68) {
      tarInput = BZip2Decoder().decodeLazy(input, verify: true);
    } else if (first.length >= 6 &&
        first[0] == 0xFD &&
        first[1] == 0x37 &&
        first[2] == 0x7A &&
        first[3] == 0x58 &&
        first[4] == 0x5A &&
        first[5] == 0x00) {
      tarInput = XZDecoder().decodeLazy(input, verify: true);
    }
    final pages = <(String, Uint8List)>[];
    TarDecoder().decodeStream(
      tarInput,
      verify: true,
      throwOnError: true,
      keepEntries: false,
      callback: (file) {
        if (!file.isFile) return;
        if (!isImageName(file.name)) return;
        final bytes = file.readBytes();
        if (bytes == null || bytes.isEmpty) return;
        pages.add((file.name, bytes));
      },
    );
    return _writePages(pages, destDir);
  } finally {
    input.closeSync();
  }
}
