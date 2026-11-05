import 'dart:io';
import 'dart:math' as math;

/// Pure-Dart SHA-256 (FIPS 180-4), streaming, no dependencies.
///
/// The app deliberately has no third-party packages (that is what lets it
/// be packaged without Gradle resolving plugins), so the hash is
/// implemented here instead of pulling in `crypto`. It is used only to
/// recognise a PDF the user already imported: two files with the same
/// SHA-256 are the same content, whatever their names are.
///
/// Verified against the NIST test vectors in test/v223_test.dart
/// (empty input, "abc", and the 56-byte message).
class Sha256 {
  static const _mask = 0xffffffff;

  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
    0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
    0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
    0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
    0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
    0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
    0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
    0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
    0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final List<int> _h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  /// Leftover bytes of an incomplete 64-byte block.
  final List<int> _buf = [];
  int _len = 0;
  bool _closed = false;

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

  void add(List<int> data) {
    if (_closed) throw StateError('SHA-256 already closed');
    _len += data.length;
    var off = 0;
    if (_buf.isNotEmpty) {
      final need = 64 - _buf.length;
      final take = math.min(need, data.length);
      _buf.addAll(data.sublist(0, take));
      off = take;
      if (_buf.length == 64) {
        _process(_buf);
        _buf.clear();
      }
    }
    while (off + 64 <= data.length) {
      _process(data.sublist(off, off + 64));
      off += 64;
    }
    if (off < data.length) _buf.addAll(data.sublist(off));
  }

  String digest() {
    if (_closed) throw StateError('SHA-256 already closed');
    _closed = true;
    final bitLen = _len * 8;
    _buf.add(0x80);
    while (_buf.length % 64 != 56) {
      _buf.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      _buf.add((bitLen >> (8 * i)) & 0xff);
    }
    while (_buf.isNotEmpty) {
      _process(_buf.sublist(0, 64));
      _buf.removeRange(0, 64);
    }
    return _h.map((w) => w.toRadixString(16).padLeft(8, '0')).join();
  }

  void _process(List<int> block) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (block[i * 4] << 24) |
          (block[i * 4 + 1] << 16) |
          (block[i * 4 + 2] << 8) |
          block[i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 =
          _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 =
          _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
    }
    var a = _h[0];
    var b = _h[1];
    var c = _h[2];
    var d = _h[3];
    var e = _h[4];
    var f = _h[5];
    var g = _h[6];
    var h = _h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final temp1 = (h + s1 + ch + _k[i] + w[i]) & _mask;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & _mask;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _mask;
    }
    _h[0] = (_h[0] + a) & _mask;
    _h[1] = (_h[1] + b) & _mask;
    _h[2] = (_h[2] + c) & _mask;
    _h[3] = (_h[3] + d) & _mask;
    _h[4] = (_h[4] + e) & _mask;
    _h[5] = (_h[5] + f) & _mask;
    _h[6] = (_h[6] + g) & _mask;
    _h[7] = (_h[7] + h) & _mask;
  }
}

/// SHA-256 of in-memory bytes, as lowercase hex.
String sha256Hex(List<int> bytes) {
  final h = Sha256();
  h.add(bytes);
  return h.digest();
}

/// SHA-256 of a file, read in 64 KB chunks so a large PDF is never held
/// fully in memory. Throws if the file cannot be read.
Future<String> sha256File(File file) async {
  final h = Sha256();
  final raf = await file.open();
  try {
    while (true) {
      final chunk = await raf.read(65536);
      if (chunk.isEmpty) break;
      h.add(chunk);
    }
  } finally {
    await raf.close();
  }
  return h.digest();
}
