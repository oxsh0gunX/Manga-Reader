import 'dart:io';
import 'dart:typed_data';

/// Pure-Dart PDF text extraction (no plugin, no network).
///
/// Parses the page tree, decompresses Flate streams and reads Tj / TJ text
/// operators. This covers the PDFs most phones actually hold (Word, Google
/// Docs, Chrome print, etc.). Scanned / image-only PDFs have no text layer,
/// and PDFs with custom font encodings without a ToUnicode map may come out
/// garbled — in both cases the reader says so instead of showing junk.
class PdfTextExtractor {
  static final Map<String, String> _cache = {};

  static Future<String> pageText(File file, int pageIndex) async {
    final key = '${file.path}|$pageIndex';
    if (_cache.containsKey(key)) return _cache[key]!;
    String text = '';
    try {
      final bytes = await file.readAsBytes();
      text = _extract(bytes, pageIndex);
    } catch (_) {
      text = '';
    }
    _cache[key] = text;
    return text;
  }

  static String _extract(Uint8List bytes, int pageIndex) {
    // Latin-1 view: byte index == string index, which keeps stream slicing exact.
    final raw = String.fromCharCodes(bytes);
    final objRe = RegExp(r'(\d+)\s+\d+\s+obj([\s\S]*?)endobj');
    final objects = <String, String>{};
    final order = <String>[];
    for (final m in objRe.allMatches(raw)) {
      objects[m.group(1)!] = m.group(2)!;
      order.add(m.group(1)!);
    }
    if (objects.isEmpty) return '';

    // Walk the /Pages tree so page order follows the document, not file order.
    final pages = <String>[];
    final visited = <String>{};
    void walk(String id) {
      if (!visited.add(id)) return;
      final body = objects[id];
      if (body == null) return;
      final kids = RegExp(r'/Kids\s*\[([^\]]*)\]').firstMatch(body);
      if (kids != null) {
        for (final km in RegExp(r'(\d+)\s+\d+\s+R').allMatches(kids.group(1)!)) {
          walk(km.group(1)!);
        }
      } else if (RegExp(r'/Type\s*/Page(?![a-zA-Z])').hasMatch(body)) {
        pages.add(id);
      }
    }

    for (final id in order) {
      final body = objects[id]!;
      if (RegExp(r'/Type\s*/Pages(?![a-zA-Z])').hasMatch(body)) {
        walk(id);
        break;
      }
    }
    if (pages.isEmpty) {
      for (final id in order) {
        final body = objects[id]!;
        if (RegExp(r'/Type\s*/Page(?![a-zA-Z])').hasMatch(body)) pages.add(id);
      }
    }
    if (pageIndex < 0 || pageIndex >= pages.length) return '';
    final pageBody = objects[pages[pageIndex]]!;

    // Content streams for this page.
    final contentIds = <String>[];
    final arr = RegExp(r'/Contents\s*\[([^\]]*)\]').firstMatch(pageBody);
    if (arr != null) {
      for (final m in RegExp(r'(\d+)\s+\d+\s+R').allMatches(arr.group(1)!)) {
        contentIds.add(m.group(1)!);
      }
    } else {
      final single = RegExp(r'/Contents\s+(\d+)\s+\d+\s+R').firstMatch(pageBody);
      if (single != null) contentIds.add(single.group(1)!);
    }

    final out = StringBuffer();
    for (final cid in contentIds) {
      final body = objects[cid];
      if (body == null) continue;
      final streamIdx = body.indexOf('stream');
      if (streamIdx < 0) continue;
      int start = streamIdx + 6;
      if (body.startsWith('\r\n', start)) {
        start += 2;
      } else if (body.startsWith('\n', start) || body.startsWith('\r', start)) {
        start += 1;
      }
      final end = body.indexOf('endstream', start);
      if (end < 0) continue;
      // Map the object-body slice back to raw bytes (same indices, Latin-1).
      final objStartInRaw = raw.indexOf(body);
      if (objStartInRaw < 0) continue;
      final streamBytes =
          bytes.sublist(objStartInRaw + start, objStartInRaw + end);
      Uint8List decoded = streamBytes;
      if (body.substring(0, streamIdx).contains('/FlateDecode')) {
        try {
          decoded = Uint8List.fromList(ZLibDecoder().convert(streamBytes));
        } catch (_) {
          // Keep the raw bytes; extraction below will just find nothing.
        }
      }
      out.write(_textFromContent(String.fromCharCodes(decoded)));
      out.write('\n');
    }
    return _clean(out.toString());
  }

  static String _clean(String s) {
    var t = s.replaceAll('\r', '\n');
    t = t.replaceAll(RegExp(r'[ \t]+'), ' ');
    t = t.replaceAll(RegExp(r' ([,.!?:;%)])'), r'$1');
    t = t.replaceAll(RegExp(r'([(]) '), r'$1');
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // Collapse spaces created between Tj fragments on the same line.
    final lines = t.split('\n').map((l) => l.trim()).toList();
    while (lines.isNotEmpty && lines.first.isEmpty) lines.removeAt(0);
    while (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines.join('\n');
  }

  /// Reads one literal "(...)" string starting at i (raw[i] == '(').
  /// Returns the decoded text and the index just past the closing ')'.
  static ({String text, int next}) _literal(String s, int i) {
    int depth = 1;
    final buf = StringBuffer();
    i++; // past '('
    while (i < s.length && depth > 0) {
      final c = s[i];
      if (c == '\\' && i + 1 < s.length) {
        final n = s[i + 1];
        if (n == 'n') {
          buf.write('\n');
          i += 2;
        } else if (n == 'r') {
          buf.write('\n');
          i += 2;
        } else if (n == 't') {
          buf.write('\t');
          i += 2;
        } else if (n == 'b') {
          buf.write('\b');
          i += 2;
        } else if (n == 'f') {
          buf.write('\f');
          i += 2;
        } else if (n == '(' || n == ')' || n == '\\') {
          buf.write(n);
          i += 2;
        } else if (n == '\r' || n == '\n') {
          // Line continuation: skip the newline itself.
          i += 2;
          if (n == '\r' && i < s.length && s[i] == '\n') i++;
        } else if (n.codeUnitAt(0) >= 48 && n.codeUnitAt(0) <= 55) {
          int code = 0;
          int k = 0;
          while (k < 3 && i + 1 + k < s.length) {
            final d = s[i + 1 + k];
            if (d.codeUnitAt(0) < 48 || d.codeUnitAt(0) > 55) break;
            code = code * 8 + (d.codeUnitAt(0) - 48);
            k++;
          }
          buf.writeCharCode(code);
          i += 1 + k;
        } else {
          buf.write(n);
          i += 2;
        }
      } else if (c == '(') {
        depth++;
        buf.write(c);
        i++;
      } else if (c == ')') {
        depth--;
        if (depth > 0) buf.write(c);
        i++;
      } else {
        buf.write(c);
        i++;
      }
    }
    return (text: buf.toString(), next: i);
  }

  /// Reads one hex "<...>" string starting at i. Returns text + next index.
  static ({String text, int next}) _hex(String s, int i) {
    final hex = StringBuffer();
    i++; // past '<'
    while (i < s.length && s[i] != '>') {
      final c = s[i];
      if (!RegExp(r'\s').hasMatch(c)) hex.write(c);
      i++;
    }
    if (i < s.length) i++; // past '>'
    var h = hex.toString();
    if (h.length.isOdd) h += '0';
    final bytes = <int>[];
    for (int k = 0; k + 1 < h.length; k += 2) {
      bytes.add(int.tryParse(h.substring(k, k + 2), radix: 16) ?? 0);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      // UTF-16BE.
      final units = <int>[];
      for (int k = 2; k + 1 < bytes.length; k += 2) {
        units.add((bytes[k] << 8) | bytes[k + 1]);
      }
      return (text: String.fromCharCodes(units), next: i);
    }
    return (text: String.fromCharCodes(bytes), next: i);
  }

  static bool _isOpChar(String ch) {
    final u = ch.codeUnitAt(0);
    return (u >= 65 && u <= 90) ||
        (u >= 97 && u <= 122) ||
        u == 39 ||
        u == 34 ||
        u == 42;
  }

  static String _textFromContent(String s) {
    final out = StringBuffer();
    int i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == '(') {
        final lit = _literal(s, i);
        // Peek the operator that follows this string.
        int j = lit.next;
        while (j < s.length && RegExp(r'\s').hasMatch(s[j])) j++;
        String op = '';
        int k = j;
        while (k < s.length && _isOpChar(s[k])) {
          op += s[k];
          k++;
        }
        if (op == 'Tj' || op == "'" || op == '"') {
          if (op != 'Tj') out.write('\n');
          out.write(lit.text);
          out.write(' ');
        }
        i = lit.next;
      } else if (c == '<' && i + 1 < s.length && s[i + 1] != '<') {
        final hx = _hex(s, i);
        int j = hx.next;
        while (j < s.length && RegExp(r'\s').hasMatch(s[j])) j++;
        String op = '';
        int k = j;
        while (k < s.length && _isOpChar(s[k])) {
          op += s[k];
          k++;
        }
        if (op == 'Tj' || op == "'" || op == '"') {
          if (op != 'Tj') out.write('\n');
          out.write(hx.text);
          out.write(' ');
        }
        i = hx.next;
      } else if (c == '[') {
        // TJ array: strings + spacing numbers.
        final buf = StringBuffer();
        int j = i + 1;
        bool closed = false;
        while (j < s.length) {
          final ch = s[j];
          if (ch == ']') {
            closed = true;
            j++;
            break;
          } else if (ch == '(') {
            final lit = _literal(s, j);
            buf.write(lit.text);
            j = lit.next;
          } else if (ch == '<' && j + 1 < s.length && s[j + 1] != '<') {
            final hx = _hex(s, j);
            buf.write(hx.text);
            j = hx.next;
          } else if (ch == '-' || (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) || ch == '.' || ch == '+') {
            int st = j;
            while (j < s.length &&
                (s[j] == '-' || s[j] == '.' || s[j] == '+' ||
                    (s[j].codeUnitAt(0) >= 48 && s[j].codeUnitAt(0) <= 57))) {
              j++;
            }
            final num = double.tryParse(s.substring(st, j)) ?? 0;
            if (num < -200) buf.write(' ');
          } else {
            j++;
          }
        }
        if (closed) {
          int p = j;
          while (p < s.length && RegExp(r'\s').hasMatch(s[p])) p++;
          if (s.startsWith('TJ', p)) {
            out.write(buf.toString());
            out.write(' ');
            i = p + 2;
            continue;
          }
        }
        i = j;
      } else if (c == 'T' && i + 1 < s.length && s[i + 1] == '*') {
        out.write('\n');
        i += 2;
      } else if (c == 'E' && s.startsWith('ET', i)) {
        out.write('\n');
        i += 2;
      } else {
        i++;
      }
    }
    return out.toString();
  }
}
