import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'native.dart';
import 'panel_editor.dart';
import 'pdf_text.dart';
import 'settings_page.dart';

class _Entry {
  _Entry(this.doc, this.page);
  final PdfDoc doc;
  final int page;
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.library, required this.doc});

  final Library library;
  final PdfDoc doc;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late PdfDoc _doc;
  late int _seqIndex;
  late PageController _pageController;
  late ScrollController _scrollController;
  late TransformationController _zoomController;
  late AnimationController _zoomAnimController;
  Animation<Matrix4>? _zoomAnim;
  int _page = 0;
  int? _previewPage;
  bool _showText = false;
  bool _cleanedUp = false;
  double _brightness = 0.7;
  bool _brightnessReady = false;
  final GlobalKey _shotKey = GlobalKey();
  final Map<String, Future<Map<String, dynamic>>> _pageFutures = {};
  final Map<String, Map<String, dynamic>> _pageInfo = {};
  int _frameIndex = 0;
  // Clean reading: controls are hidden by default and only appear when
  // the user taps the screen. Nothing else (no watermark, no branding,
  // no ads) is ever drawn over the document.
  bool _controlsVisible = false;
  final Map<String, Future<List<PanelRect>>> _detectedFutures = {};
  final Map<String, List<PanelRect>> _detectedCache = {};
  bool _zoomed = false;
  String? _lastScreenshotUri;
  double _split = 0.5;

  // ---------- auto-scroll (Manga mode only) ----------
  // 'off' | 'running' | 'paused'. The state is session-only: it is
  // never saved, so leaving the reader or the app never restarts
  // scrolling on its own. Only the interval (AppSettings) is saved.
  String _autoScrollState = 'off';
  // The one timer. It is always cancelled before a new one is made,
  // so two timers can never run at once.
  Timer? _autoScrollTimer;
  // The page an auto-scroll tick is turning to, or null. When the
  // PageView reports that page, it is the tick's own turn — not a
  // manual swipe — so the interval clock is not reset for it.
  int? _autoScrollTargetPage;

  // ---------- manga auto-next ----------
  // The strip's "next document" switch is scheduled a moment after
  // the user reaches the very bottom of the last page, so scrolling
  // back up cancels it. Cancelled on any document switch and when
  // the reader closes.
  Timer? _autoNextTimer;
  // True once the user has turned a page or scrolled themself. The
  // auto-next never fires from the opening jump to a saved page:
  // opening a short book must not yank the user to the next one.
  bool _userNavigated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _doc = widget.doc;
    _seqIndex = widget.library.indexOf(_doc);
    _page = _safePage(_doc, _doc.lastPage);
    _pageController = PageController(initialPage: _page);
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _zoomController = TransformationController();
    _zoomController.addListener(_onZoomChanged);
    _zoomAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    widget.library.markOpened(_doc);
    _applyNativeSettings();
    NativeBridge.onVolumeEvent((method) {
      if (method == 'screenshotShortcut') {
        _screenshot();
        return;
      }
      if (_showText) {
        if (method == 'volumeUp') {
          _nextPageOrDoc();
        } else {
          _prevPageOrDoc();
        }
        return;
      }
      final style = _effectiveStyle();
      if (style == 'panel' || style == 'frame') {
        if (method == 'volumeUp') {
          _nextFrame();
        } else {
          _prevFrame();
        }
      } else {
        if (method == 'volumeUp') {
          _nextPageOrDoc();
        } else {
          _prevPageOrDoc();
        }
      }
    });
    NativeBridge.beginBrightness().then((v) {
      if (mounted) {
        setState(() {
          _brightness = v.clamp(0.1, 1.0);
          _brightnessReady = true;
        });
      }
    });
    // Scroll modes (vertical, continuous, manga strip) start at the
    // remembered page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isScrollMode && _scrollController.hasClients) {
        _scrollToPage(_page, animate: false);
      }
    });
    // True fullscreen from the start: system bars hidden, controls hidden.
    // Shown exactly once, on the very first reader open, so the tap
    // gesture is discoverable without a permanent overlay.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (!widget.library.settings.controlsHintShown) {
        widget.library.settings.controlsHintShown = true;
        widget.library.saveSettings();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tap the screen to show or hide the controls.'),
            ),
          );
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelAutoScrollTimer();
    _cancelAutoNext();
    _cleanup();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    _zoomAnimController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Auto-scroll pauses when the app goes into the background (or a
    // system interruption arrives). It never resumes by itself: the
    // user taps Resume. Leaving the reader stops it outright
    // (_cleanup), so nothing ever starts scrolling after the user
    // has gone.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_autoScrollState == 'running') _pauseAutoScroll();
    }
  }

  void _cleanup() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _stopAutoScroll();
    _cancelAutoNext();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    NativeBridge.setVolumeEnabled(false);
    NativeBridge.clearVolumeEvent();
    NativeBridge.restoreBrightness();
  }

  void _applyNativeSettings() {
    final s = widget.library.settings;
    NativeBridge.setVolumeEnabled(s.volumeEnabled);
    NativeBridge.setScreenshotShortcutEnabled(s.screenshotShortcutEnabled);
  }

  void _setControlsVisible(bool v) {
    if (v == _controlsVisible) return;
    setState(() => _controlsVisible = v);
    SystemChrome.setEnabledSystemUIMode(
        v ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  void _toggleControls() => _setControlsVisible(!_controlsVisible);

  /// Tap navigation, page-by-page (horizontal) mode only. The reading
  /// area is split in thirds: left turns back a page, right turns
  /// forward, and the centre keeps the old behaviour (show/hide the
  /// controls). Side taps never toggle the controls and never switch
  /// documents: at the first or last page they simply do nothing.
  /// Text view, scroll modes and panel/frame modes keep plain tap =
  /// toggle controls, so text selection, scrolling, long-press zoom
  /// and panel taps are untouched. A pinch or drag wins the gesture
  /// arena over a tap, and a long-press wins over a tap, so zooming
  /// can never turn a page by accident.
  void _onTapUp(TapUpDetails details) {
    if (_showText) {
      _toggleControls();
      return;
    }
    // Manga mode, one page at a time: the same thirds idea, but top
    // to bottom — top turns back a page, bottom turns forward, the
    // middle only toggles the controls. The strip, like the other
    // scroll modes, keeps plain tap = toggle controls.
    if (_effectiveStyle() == 'manga' && _doc.mangaPaged) {
      final box = _shotKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || box.size.height <= 0) {
        _toggleControls();
        return;
      }
      final local = box.globalToLocal(details.globalPosition);
      final third = box.size.height / 3;
      if (local.dy < third) {
        if (!_isFirstPage) _goToPage(_page - 1);
      } else if (local.dy > 2 * third) {
        // In Manga mode the bottom tap at the last page opens the
        // next document (from its first page); with no next document
        // it simply stays put.
        _nextPageOrDoc();
      } else {
        _toggleControls();
      }
      return;
    }
    if (_effectiveStyle() != 'horizontal') {
      _toggleControls();
      return;
    }
    final box = _shotKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.width <= 0) {
      _toggleControls();
      return;
    }
    final local = box.globalToLocal(details.globalPosition);
    final third = box.size.width / 3;
    // In manga (right-to-left) reading, forward is towards the left:
    // the left third turns the page forward, the right third back.
    // The centre third still only toggles the controls, in both
    // directions, and the first/last page still stays put.
    final forwardIsLeft = _doc.rtl;
    if (local.dx < third) {
      if (forwardIsLeft) {
        if (!_isLastPage) _goToPage(_page + 1);
      } else {
        if (!_isFirstPage) _goToPage(_page - 1);
      }
    } else if (local.dx > 2 * third) {
      if (forwardIsLeft) {
        if (!_isFirstPage) _goToPage(_page - 1);
      } else {
        if (!_isLastPage) _goToPage(_page + 1);
      }
    } else {
      _toggleControls();
    }
  }

  // ---------- page rendering / info ----------

  Future<Map<String, dynamic>> _pageFutureFor(PdfDoc doc, int page,
      {bool preloadNeighbours = true}) {
    final key = '${doc.id}_$page';
    final fut = _pageFutures.putIfAbsent(key, () async {
      // Comic / single-image pages already exist as files on disk:
      // no rendering, just the image path and its size (found lazily
      // from the header, the same way a PDF render returns its size).
      // Everything below — the _pageInfo cache, the 120-entry cap,
      // neighbour preloading, panels, frames, zoom — works off this
      // same {path, width, height} map as for PDFs.
      if (doc.kind != 'pdf') {
        final path = widget.library.comicPagePath(doc, page);
        final size = await NativeBridge.imageSize(path);
        final res = <String, dynamic>{
          'path': path,
          'width': (size?['width'] as num?)?.toInt() ?? 0,
          'height': (size?['height'] as num?)?.toInt() ?? 0,
        };
        final isNew = !_pageInfo.containsKey(key);
        _pageInfo[key] = res;
        if (isNew) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        if (preloadNeighbours) {
          // Comic pages are just a header read, so in Manga mode the
          // next two pages' sizes are fetched ahead too: the strip
          // then knows every upcoming page's real height before the
          // user scrolls there, and the list never jumps as images
          // load. PDFs keep immediate neighbours only — rendering
          // extra PDF pages would cost real work and storage.
          final ahead = _effectiveStyle() == 'manga'
              ? [page - 2, page - 1, page + 1, page + 2]
              : [page - 1, page + 1];
          for (final n in ahead) {
            if (n >= 0 && n < doc.pageCount) {
              _pageFutureFor(doc, n, preloadNeighbours: false);
            }
          }
        }
        return res;
      }
      final width = mounted
          ? (MediaQuery.of(context).size.width *
                  MediaQuery.of(context).devicePixelRatio)
              .round()
              .clamp(600, 1600)
          : 1080;
      var res = await NativeBridge.renderPage(
        path: doc.path,
        page: page,
        width: width,
        docId: doc.id,
      );
      // The native cache prunes old pages: if this file was pruned
      // between render and use, render it again instead of showing a
      // broken page (the filename is deterministic, so this regenerates it).
      if (!await File(res['path'] as String).exists()) {
        res = await NativeBridge.renderPage(
          path: doc.path,
          page: page,
          width: width,
          docId: doc.id,
        );
      }
      final isNew = !_pageInfo.containsKey(key);
      _pageInfo[key] = res;
      if (isNew) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
      // Preload immediate neighbours only, so swiping feels instant.
      // Neighbours must NOT preload further, or opening one page would
      // silently render the whole book (battery + storage).
      if (preloadNeighbours) {
        for (final n in [page - 1, page + 1]) {
          if (n >= 0 && n < doc.pageCount) {
            _pageFutureFor(doc, n, preloadNeighbours: false);
          }
        }
      }
      return res;
    });
    // Bound the caches: evict the oldest entries once past 120, so a
    // long reading session cannot grow them without limit. Evicted
    // pages simply re-render if revisited.
    while (_pageFutures.length > 120) {
      final oldest = _pageFutures.keys.first;
      if (oldest == key) break;
      _pageFutures.remove(oldest);
      _pageInfo.remove(oldest);
    }
    return fut;
  }

  Map<String, dynamic>? _infoFor(PdfDoc doc, int page) =>
      _pageInfo['${doc.id}_$page'];

  double _aspectFor(PdfDoc doc, int page) {
    final info = _infoFor(doc, page);
    if (info == null) return 1.414;
    final w = (info['width'] as num?)?.toDouble() ?? 1;
    final h = (info['height'] as num?)?.toDouble() ?? 1.414;
    if (w <= 0) return 1.414;
    return h / w;
  }

  // ---------- styles ----------

  /// The style actually in use right now. 'auto' adapts to the page shape:
  /// tall pages read frame by frame, wide pages panel by panel, normal
  /// pages page by page.
  String _effectiveStyle() {
    if (_doc.style != 'auto') return _doc.style;
    final aspect = _aspectFor(_doc, _page);
    if (aspect >= 1.5) return 'frame';
    if (aspect < 1.0) return 'panel';
    return 'horizontal';
  }

  bool get _isFrameMode {
    final s = _effectiveStyle();
    return s == 'panel' || s == 'frame';
  }

  bool get _isScrollMode {
    final s = _effectiveStyle();
    // Manga mode scrolls top to bottom as a strip, unless the user
    // switched it to one page at a time (mangaPaged), in which case
    // it is a vertical PageView instead.
    return s == 'vertical' ||
        s == 'continuous' ||
        (s == 'manga' && !_doc.mangaPaged);
  }

  String _frameLayout() {
    if (_doc.frameLayout != 'auto') return _doc.frameLayout;
    return _effectiveStyle() == 'frame' ? 'vertical' : 'grid';
  }

  int _frameCountFor(double aspect) {
    if (_doc.panels > 0) return _doc.panels;
    if (_frameLayout() == 'vertical') {
      if (aspect >= 2.5) return 5;
      if (aspect >= 1.8) return 4;
      if (aspect >= 1.4) return 3;
      return 2;
    }
    return aspect >= 1.0 ? 4 : 6;
  }

  int _currentFrameCount() {
    final info = _infoFor(_doc, _page);
    if (info != null) {
      final imgW = (info['width'] as num).toDouble();
      final imgH = (info['height'] as num).toDouble();
      return _effectivePixelRects(imgW, imgH, _page).length;
    }
    return _frameCountFor(_aspectFor(_doc, _page));
  }

  int _clampedFrame(int count) => _frameIndex.clamp(0, count - 1);

  // clamp(0, pageCount - 1) throws when pageCount is 0 (lower > upper).
  // An empty document opens on page 0 and shows its "no pages" state
  // instead of crashing the reader.
  static int _safePage(PdfDoc doc, int page) =>
      doc.pageCount <= 0 ? 0 : page.clamp(0, doc.pageCount - 1);

  /// Automatic detection for one page (cached). Returns [] when nothing
  /// was detected; the caller then falls back to the grid/band layout.
  Future<List<PanelRect>> _detectedFor(PdfDoc doc, int page) {
    final key = '${doc.id}_$page';
    if (_detectedCache.containsKey(key)) return Future.value(_detectedCache[key]!);
    return _detectedFutures.putIfAbsent(key, () async {
      final info = await _pageFutureFor(doc, page);
      List<PanelRect> out = [];
      try {
        final found = await NativeBridge.detectPanels(info['path'] as String);
        out = found
            .map((m) => PanelRect(
                  x: (m['x'] as num).toDouble(),
                  y: (m['y'] as num).toDouble(),
                  w: (m['w'] as num).toDouble(),
                  h: (m['h'] as num).toDouble(),
                ))
            .toList();
      } catch (_) {
        out = [];
      }
      _detectedCache[key] = out;
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
      return out;
    });
  }

  /// Panel rectangles for a page, in reading order, in image pixels.
  /// Priority: the user's saved layout for this page, then automatic
  /// detection (2+ panels), then the grid/band layout.
  List<Rect> _effectivePixelRects(double imgW, double imgH, int page) {
    // 1% safety margin on each side, clamped to the page, so text or
    // art sitting exactly on a panel boundary is never clipped in
    // display. (The grid fallback already has its own overlap.)
    Rect expanded(PanelRect r) {
      final x0 = (r.x - 0.01).clamp(0.0, 1.0);
      final y0 = (r.y - 0.01).clamp(0.0, 1.0);
      final x1 = (r.x + r.w + 0.01).clamp(0.0, 1.0);
      final y1 = (r.y + r.h + 0.01).clamp(0.0, 1.0);
      return Rect.fromLTWH(
          x0 * imgW, y0 * imgH, (x1 - x0) * imgW, (y1 - y0) * imgH);
    }

    final custom = _doc.customPanels['$page'];
    if (custom != null && custom.isNotEmpty) {
      return custom.map(expanded).toList();
    }
    final detected = _detectedCache['${_doc.id}_$page'];
    if (detected != null && detected.length >= 2) {
      return detected.map(expanded).toList();
    }
    final count = _frameCountFor(imgH / imgW);
    return [for (int i = 0; i < count; i++) _frameRect(i, count, imgW, imgH)];
  }

  /// Same panels as fractions, for the overview and the editor. The
  /// fallback grid uses the true (pre-overlap) cells so cells never overlap.
  List<PanelRect> _effectiveFractionRects(double imgW, double imgH, int page) {
    final custom = _doc.customPanels['$page'];
    if (custom != null && custom.isNotEmpty) return custom;
    final detected = _detectedCache['${_doc.id}_$page'];
    if (detected != null && detected.length >= 2) return detected;
    final count = _frameCountFor(imgH / imgW);
    return [
      for (int i = 0; i < count; i++)
        (() {
          final r = _rawFrameRect(i, count, imgW, imgH);
          return PanelRect(
              x: r.left / imgW,
              y: r.top / imgH,
              w: r.width / imgW,
              h: r.height / imgH);
        })(),
    ];
  }

  /// One frame's rectangle in page-image pixels, expanded by the overlap
  /// setting so content sitting on a boundary is never cut off.
  Rect _frameRect(int frame, int count, double imgW, double imgH) {
    double x = 0, y = 0, w = imgW, h = imgH;
    if (_frameLayout() == 'vertical') {
      if (count == 2) {
        final splitY = _split * imgH;
        if (frame == 0) {
          y = 0;
          h = splitY;
        } else {
          y = splitY;
          h = imgH - splitY;
        }
      } else {
        h = imgH / count;
        y = frame * h;
      }
      w = imgW;
      x = 0;
    } else {
      final cols = count == 2 ? 2 : (count <= 4 ? 2 : 3);
      final rows = (count + cols - 1) ~/ cols;
      final col = frame % cols;
      final row = frame ~/ cols;
      w = imgW / cols;
      h = imgH / rows;
      x = col * w;
      y = row * h;
    }
    final overlap = widget.library.settings.frameOverlap;
    final ox = w * overlap;
    final oy = h * overlap;
    final nx = (x - ox).clamp(0.0, imgW);
    final ny = (y - oy).clamp(0.0, imgH);
    final nw = (w + 2 * ox).clamp(0.0, imgW - nx);
    final nh = (h + 2 * oy).clamp(0.0, imgH - ny);
    return Rect.fromLTWH(nx, ny, nw, nh);
  }

  // ---------- navigation ----------

  void _goToPage(int page, {bool keepFrame = false, bool fromAutoScroll = false}) {
    if (_doc.pageCount <= 0) return;
    final target = page.clamp(0, _doc.pageCount - 1);
    final wasScroll = _isScrollMode;
    setState(() {
      _page = target;
      _previewPage = null;
      if (!keepFrame) _frameIndex = 0;
    });
    _resetZoomInstant();
    widget.library.saveProgress(_doc, target);
    // A manual turn restarts the auto-scroll interval, so the user
    // gets a full interval on the page they turned to. The tick's
    // own turn does not reset it (the tick schedules the next one).
    // A manual turn also marks the user as having navigated, which
    // is what arms the manga auto-next guard.
    if (!fromAutoScroll) {
      _userNavigated = true;
      if (_autoScrollState == 'running') _resetAutoScrollClock();
    }
    if (wasScroll) {
      if (_scrollController.hasClients) {
        _scrollToPage(target);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToPage(target);
        });
      }
    } else if (_pageController.hasClients && target != _pageController.page?.round()) {
      _pageController.animateToPage(
        target,
        duration: _turnDuration,
        curve: _turnCurve,
      );
    }
  }

  void _onPageChanged(int page) {
    // A stale report from the previous document's PageView — its
    // animation finishing after a document switch — must not be
    // saved as this document's progress. Accept a report only if it
    // is the page this reader is already on (a turn _goToPage set)
    // or the page the controller is actually on (a swipe). A stale
    // report agrees with neither: after a switch the reader is on
    // the new document's first page and the new controller has no
    // clients yet, or is on page 0.
    final onControllerPage = _pageController.hasClients &&
        _pageController.page != null &&
        page == _pageController.page!.round();
    if (page != _page && !onControllerPage) return;
    setState(() {
      _page = page;
      _previewPage = null;
      _frameIndex = 0;
    });
    _resetZoomInstant();
    widget.library.saveProgress(_doc, page);
    // A page change from a swipe is the user navigating: it marks
    // them as having read (for the manga auto-next guard) and, when
    // auto-scroll runs, restarts the interval. A change to the page
    // an auto-scroll tick is turning to is the tick's own turn, and
    // does neither.
    if (_autoScrollTargetPage != null && page == _autoScrollTargetPage) {
      _autoScrollTargetPage = null;
    } else {
      _autoScrollTargetPage = null;
      _userNavigated = true;
      _resetAutoScrollClock();
    }
  }

  void _goToFrame(int frame) {
    final count = _currentFrameCount();
    final target = frame.clamp(0, count - 1);
    if (target == _clampedFrame(count)) return;
    setState(() => _frameIndex = target);
    _resetZoomInstant();
  }

  void _nextFrame() {
    final count = _currentFrameCount();
    if (_clampedFrame(count) < count - 1) {
      _goToFrame(_frameIndex + 1);
    } else if (_isLastPage) {
      if (_nextDoc != null) _switchDoc(_nextDoc!);
    } else {
      _goToPage(_page + 1);
    }
  }

  void _prevFrame() {
    if (_clampedFrame(_currentFrameCount()) > 0) {
      _goToFrame(_frameIndex - 1);
    } else if (_isFirstPage) {
      if (_prevDoc != null) _switchDoc(_prevDoc!);
    } else {
      // Land on the last frame of the previous page (sentinel clamped
      // to that page's real frame count by _clampedFrame).
      _frameIndex = 100000;
      _goToPage(_page - 1, keepFrame: true);
    }
  }

  // Page-mode volume navigation: a normal page turn, except at the
  // ends of the document, where it follows the library's Next Document
  // sequence instead of stopping. Mirrors _nextFrame/_prevFrame.
  void _nextPageOrDoc() {
    if (_isLastPage) {
      if (_nextDoc != null) {
        // Manga mode: the next document opens in Manga mode, from
        // its first page. Every other mode keeps its existing
        // behaviour (resume at the saved page).
        if (_effectiveStyle() == 'manga') {
          _switchDocManga(_nextDoc!);
        } else {
          _switchDoc(_nextDoc!);
        }
      }
    } else {
      _goToPage(_page + 1);
    }
  }

  void _prevPageOrDoc() {
    if (_isFirstPage) {
      if (_prevDoc != null) _switchDoc(_prevDoc!);
    } else {
      _goToPage(_page - 1);
    }
  }

  // ---------- auto-scroll (Manga mode only) ----------

  bool get _autoScrollRunning => _autoScrollState == 'running';
  int get _autoScrollInterval =>
      widget.library.settings.autoScrollSeconds;

  void _cancelAutoScrollTimer() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  // (Re)starts the interval clock: exactly one timer exists at any
  // time, because the old one is always cancelled first.
  void _scheduleAutoScrollTick() {
    _cancelAutoScrollTimer();
    if (!_autoScrollRunning || !mounted) return;
    _autoScrollTimer =
        Timer(Duration(seconds: _autoScrollInterval), _autoScrollTick);
  }

  // A manual turn restarts the interval, so the user gets a full
  // interval on the page they turned to. Called from _goToPage,
  // _onPageChanged and _onScroll — never from the tick itself.
  void _resetAutoScrollClock() {
    if (_autoScrollRunning) _scheduleAutoScrollTick();
  }

  void _startAutoScroll() {
    if (_effectiveStyle() != 'manga') return;
    if (_autoScrollState == 'running') {
      // Starting twice must not stack a second timer.
      _scheduleAutoScrollTick();
      return;
    }
    setState(() => _autoScrollState = 'running');
    _scheduleAutoScrollTick();
  }

  void _pauseAutoScroll() {
    if (_autoScrollState != 'running') return;
    _cancelAutoScrollTimer();
    setState(() => _autoScrollState = 'paused');
  }

  void _resumeAutoScroll() {
    if (_autoScrollState != 'paused') return;
    setState(() => _autoScrollState = 'running');
    _scheduleAutoScrollTick();
  }

  void _stopAutoScroll() {
    _cancelAutoScrollTimer();
    _autoScrollTargetPage = null;
    // _cleanup sets _cleanedUp before calling this from dispose, and
    // setState is illegal while the widget is being torn down.
    if (_autoScrollState != 'off' && mounted && !_cleanedUp) {
      setState(() => _autoScrollState = 'off');
    } else {
      _autoScrollState = 'off';
    }
  }

  Future<void> _autoScrollTick() async {
    if (!_autoScrollRunning || !mounted) return;
    if (_isLastPage) {
      // End of this document: in Manga mode, move to the next
      // document and keep scrolling from its first page. At the
      // end of the library, stop instead of looping or restarting.
      final next = _nextDoc;
      if (next == null) {
        _stopAutoScroll();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('End of library — auto-scroll stopped')),
          );
        }
        return;
      }
      await _switchDocManga(next);
      // _switchDoc already restarted the clock for the new
      // document's first page; nothing more to schedule here.
      return;
    }
    _autoScrollTargetPage = _page + 1;
    _goToPage(_page + 1, fromAutoScroll: true);
    _scheduleAutoScrollTick();
  }

  void _switchDoc(PdfDoc doc, {int? page}) {
    final idx = widget.library.indexOf(doc);
    if (idx < 0) return;
    // A switch cancels any pending manga auto-next, and the new
    // document starts un-navigated: its auto-next must not fire
    // from the opening jump to the saved page.
    _cancelAutoNext();
    _userNavigated = false;
    final old = _pageController;
    final p = _safePage(doc, page ?? doc.lastPage);
    setState(() {
      _doc = doc;
      _seqIndex = idx;
      _page = p;
      _showText = false;
      _frameIndex = 0;
      _pageController = PageController(initialPage: p);
    });
    old.dispose();
    _resetZoomInstant();
    widget.library.markOpened(doc);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Opened ${doc.name}')),
    );
    // A running auto-scroll keeps going into the new document, with
    // a full interval on its first page.
    _resetAutoScrollClock();
    if (_isScrollMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToPage(p, animate: false);
      });
    }
  }

  // True while a manga next-document switch is in flight (the style
  // save is async): a second switch attempt in the same moment —
  // e.g. more overscroll notifications from one long swipe — is
  // ignored instead of chaining through documents.
  bool _mangaSwitching = false;

  /// Manga mode's next-document switch: the next document opens in
  /// Manga mode too (same strip / single-page view), from its first
  /// page. The style is saved on the document, so it stays Manga
  /// mode afterwards as well.
  Future<void> _switchDocManga(PdfDoc doc) async {
    if (_mangaSwitching) return;
    _mangaSwitching = true;
    try {
      doc.style = 'manga';
      doc.mangaPaged = _doc.mangaPaged;
      await widget.library.saveDoc(doc);
      if (!mounted) return;
      _switchDoc(doc, page: 0);
    } finally {
      _mangaSwitching = false;
    }
  }

  PdfDoc? get _prevDoc =>
      _seqIndex < 0 ? null : widget.library.docAtSequence(_seqIndex - 1);
  PdfDoc? get _nextDoc =>
      _seqIndex < 0 ? null : widget.library.docAtSequence(_seqIndex + 1);
  bool get _isLastPage => _doc.pageCount > 0 && _page >= _doc.pageCount - 1;
  bool get _isFirstPage => _page <= 0;

  // ---------- scroll modes ----------

  List<_Entry> _scrollEntries() {
    if (_effectiveStyle() == 'continuous') {
      final out = <_Entry>[];
      for (final d in widget.library.docs) {
        for (int p = 0; p < d.pageCount; p++) {
          out.add(_Entry(d, p));
        }
      }
      return out;
    }
    return [for (int p = 0; p < _doc.pageCount; p++) _Entry(_doc, p)];
  }

  // The gap between pages in a scroll view. Manga mode is seamless:
  // the 8px gap the other scroll modes use shows as a black band
  // between pages, and a manga spread is one image across two pages,
  // so the pages must touch. Every other mode keeps its 8px gap.
  double get _pageGap => _effectiveStyle() == 'manga' ? 0 : 8;

  // Page turns: manga mode glides a little slower and softer than
  // the standard turn, so long strips do not feel abrupt.
  Duration get _turnDuration => _effectiveStyle() == 'manga'
      ? const Duration(milliseconds: 400)
      : const Duration(milliseconds: 300);
  Curve get _turnCurve =>
      _effectiveStyle() == 'manga' ? Curves.easeInOutCubic : Curves.easeInOut;

  double _itemHeight(_Entry e, double viewportWidth) {
    final info = _infoFor(e.doc, e.page);
    if (info == null) return viewportWidth * 1.414 + _pageGap;
    final w = (info['width'] as num?)?.toDouble() ?? 1;
    final h = (info['height'] as num?)?.toDouble() ?? 1.414;
    if (w <= 0) return viewportWidth * 1.414 + _pageGap;
    return viewportWidth * h / w + _pageGap;
  }

  void _onScroll() {
    if (!_isScrollMode || !_scrollController.hasClients) return;
    final entries = _scrollEntries();
    if (entries.isEmpty) return;
    final vw = MediaQuery.of(context).size.width;
    final anchor = _scrollController.position.pixels + 60;
    double acc = 0;
    _Entry found = entries.first;
    for (final e in entries) {
      acc += _itemHeight(e, vw);
      if (anchor < acc) {
        found = e;
        break;
      }
      found = e;
    }
    if (_scrollTarget != null) {
      // A volume key or jump is scrolling to a page: the position
      // still sits on the old page mid-animation, and must not push
      // the page (and the saved progress) backwards. Once the anchor
      // reaches the target page the programmatic scroll is done.
      if (found.doc.id == _doc.id && found.page == _scrollTarget) {
        _scrollTarget = null;
      } else {
        return;
      }
    }
    if (found.page != _page || found.doc.id != _doc.id) {
      final switched = found.doc.id != _doc.id;
      setState(() {
        _doc = found.doc;
        _seqIndex = widget.library.indexOf(found.doc);
        _page = found.page;
        _frameIndex = 0;
      });
      if (switched) widget.library.markOpened(found.doc);
      widget.library.saveProgress(found.doc, found.page);
      // A scroll-driven page change is the user navigating (for the
      // manga auto-next guard); it also restarts the auto-scroll
      // interval, so auto-scroll waits while the user scrolls.
      _userNavigated = true;
      _resetAutoScrollClock();
    }
    _checkMangaAutoNext();
  }

  void _checkMangaAutoNext() {
    // Manga strip only: when the user has scrolled to the very
    // bottom of the document — the last page is fully in view — the
    // next document opens by itself after a short pause (scrolling
    // back up cancels it). The scroll position is the signal, not
    // the tracked page: the anchor that tracks the current page only
    // moves to a page once its top nears the top of the screen, and
    // the last page's top can never get there when the page is
    // shorter than the screen. Other styles keep their existing
    // behaviour, and the last document in the library simply stops.
    if (_effectiveStyle() != 'manga' ||
        !_userNavigated ||
        !_scrollController.hasClients) {
      _cancelAutoNext();
      return;
    }
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 4) {
      _scheduleAutoNext();
    } else {
      _cancelAutoNext();
    }
  }

  void _scheduleAutoNext() {
    if (_autoNextTimer?.isActive == true) return;
    _autoNextTimer = Timer(const Duration(milliseconds: 1200), _autoNextNow);
  }

  void _cancelAutoNext() {
    _autoNextTimer?.cancel();
    _autoNextTimer = null;
  }

  Future<void> _autoNextNow() async {
    _autoNextTimer = null;
    if (!mounted || _effectiveStyle() != 'manga') return;
    if (_nextDoc == null) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels < pos.maxScrollExtent - 4) return;
    await _switchDocManga(_nextDoc!);
  }

  // The page a volume key or jump is scrolling to, or null when no
  // programmatic scroll is in flight. While it is set, _onScroll
  // ignores the mid-animation position (see there). Cleared when the
  // animation finishes, when the anchor reaches the target, or when
  // the user grabs the list and drags it themself.
  int? _scrollTarget;

  void _scrollToPage(int page, {bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final entries = _scrollEntries();
    final vw = MediaQuery.of(context).size.width;
    double offset = 0;
    for (final e in entries) {
      if (e.doc.id == _doc.id && e.page == page) break;
      offset += _itemHeight(e, vw);
    }
    if (animate) {
      _scrollTarget = page;
      _scrollController
          .animateTo(
        offset,
        duration: _turnDuration,
        curve: _turnCurve,
      )
          .whenComplete(() {
        _scrollTarget = null;
      });
    } else {
      _scrollTarget = null;
      _scrollController.jumpTo(offset);
    }
  }

  // ---------- zoom ----------

  void _onZoomChanged() {
    final zoomed = _zoomController.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  void _animateZoom(Matrix4 target) {
    _zoomAnim = Matrix4Tween(begin: _zoomController.value, end: target)
        .animate(_zoomAnimController);
    _zoomAnim!.addListener(() {
      _zoomController.value = _zoomAnim!.value;
    });
    _zoomAnimController
      ..reset()
      ..forward();
  }

  void _resetZoomInstant() {
    _zoomController.value = Matrix4.identity();
  }

  void _zoomToPointCentered(Offset globalPosition) {
    // Zoom 2.5x with the long-pressed area centred on screen.
    final box = _shotKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final size = box.size;
    final m = Matrix4.identity()
      ..translate(size.width / 2, size.height / 2)
      ..scale(2.5)
      ..translate(-local.dx, -local.dy);
    _animateZoom(m);
  }

  // ---------- screenshot ----------

  Future<void> _screenshot() async {
    try {
      final boundary =
          _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('Nothing to capture');
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw Exception('Capture failed');
      final cache = await NativeBridge.cacheDir();
      final file = File(
          '$cache/shot_${_doc.id}_${_page + 1}_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      final uri = await NativeBridge.saveScreenshot(
          file.path, 'PDF Reader - ${_doc.name} - p${_page + 1}.png');
      if (!mounted) return;
      setState(() => _lastScreenshotUri = uri);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(uri != null
              ? 'Screenshot saved to Pictures / PDF Reader'
              : 'Screenshot could not be saved'),
          action: uri == null
              ? null
              : SnackBarAction(
                  label: 'Share',
                  onPressed: () => NativeBridge.shareImageUri(uri),
                ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Screenshot failed: $e')),
      );
    }
  }

  // ---------- sheets / dialogs ----------

  void _openBrightnessSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.brightness_6_outlined),
                  const SizedBox(width: 10),
                  Text(
                    'Brightness  ${(_brightness * 100).round()}%',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      NativeBridge.setBrightness(-1);
                      final sys = await NativeBridge.beginBrightness();
                      setSheet(() => _brightness = sys.clamp(0.1, 1.0));
                      setState(() => _brightness = sys.clamp(0.1, 1.0));
                    },
                    child: const Text('Reset'),
                  ),
                ],
              ),
              Slider(
                value: _brightness,
                min: 0.1,
                max: 1.0,
                divisions: 18,
                label: '${(_brightness * 100).round()}%',
                onChanged: (v) {
                  setSheet(() => _brightness = v);
                  setState(() => _brightness = v);
                  NativeBridge.setBrightness(v);
                },
              ),
              const Text(
                'This changes brightness only inside the reader. '
                'Reset returns to your system brightness, and your original '
                'brightness is restored when you leave the reader.',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _jumpDialog() async {
    final ctrl = TextEditingController(text: '${_page + 1}');
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Jump to page'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Page (1 - ${_doc.pageCount})',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v);
            if (n != null) Navigator.of(ctx).pop(n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text);
              if (n != null) Navigator.of(ctx).pop(n);
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
    if (value != null) {
      if (value < 1 || value > _doc.pageCount) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Enter a page between 1 and ${_doc.pageCount}')),
          );
        }
      } else {
        _goToPage(value - 1);
      }
    }
  }

  /// After a style change (or a manga strip / single-page switch),
  /// land the view on the current page: scroll to it in scroll
  /// modes, jump to it in page modes.
  void _afterStyleChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isScrollMode) {
        _scrollToPage(_page, animate: false);
      } else if (_pageController.hasClients) {
        _pageController.jumpToPage(_page);
      }
    });
  }

  void _openStyleSheet() {
    const styles = [
      ('manga', 'Manga mode',
          'Top to bottom, made for manga: pages flow down, several '
          'visible at once.'),
      ('horizontal', 'Horizontal', 'Page by page, swipe left and right.'),
      ('vertical', 'Vertical scrolling', 'Pages flow down in one scroll.'),
      ('panel', 'Panel by panel', 'One comic panel at a time, in a grid.'),
      ('frame', 'Frame by frame', 'One band at a time, for long pages.'),
      ('continuous', 'Continuous document',
          'All documents flow vertically, one after another.'),
      ('auto', 'Auto', 'Adapts to each page: tall pages use frames, '
          'wide pages use panels, normal pages use horizontal.'),
    ];
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Reading style',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              for (final (value, label, desc) in styles)
                RadioListTile<String>(
                  title: Text(label),
                  subtitle: Text(desc, style: const TextStyle(fontSize: 13)),
                  value: value,
                  groupValue: _doc.style,
                  onChanged: (v) async {
                    if (v == null) return;
                    _doc.style = v;
                    await widget.library.saveDoc(_doc);
                    setSheet(() {});
                    if (mounted) setState(() {});
                    Navigator.of(ctx).pop();
                    _afterStyleChange();
                  },
                ),
              // Manga mode has two views, and the choice matters most
              // for two-page spreads (one image running across two
              // pages): the strip shows both pages of a spread
              // together, one above the other, while single page
              // shows one page at a time. The sheet stays open here
              // so the user can flip between the two and see the
              // reader change behind it.
              if (_doc.style == 'manga') ...[
                RadioListTile<String>(
                  title: const Text('Strip'),
                  subtitle: const Text(
                      'Pages flow down, several at once — both pages '
                      'of a spread show together.',
                      style: TextStyle(fontSize: 13)),
                  value: 'strip',
                  groupValue: _doc.mangaPaged ? 'single' : 'strip',
                  contentPadding:
                      const EdgeInsets.only(left: 32, right: 16),
                  onChanged: (v) async {
                    if (v == null) return;
                    _doc.mangaPaged = false;
                    await widget.library.saveDoc(_doc);
                    setSheet(() {});
                    if (mounted) setState(() {});
                    _afterStyleChange();
                  },
                ),
                RadioListTile<String>(
                  title: const Text('Single page'),
                  subtitle: const Text(
                      'One page at a time, swipe up and down.',
                      style: TextStyle(fontSize: 13)),
                  value: 'single',
                  groupValue: _doc.mangaPaged ? 'single' : 'strip',
                  contentPadding:
                      const EdgeInsets.only(left: 32, right: 16),
                  onChanged: (v) async {
                    if (v == null) return;
                    _doc.mangaPaged = true;
                    await widget.library.saveDoc(_doc);
                    setSheet(() {});
                    if (mounted) setState(() {});
                    _afterStyleChange();
                  },
                ),
              ],
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'The style is saved for this document and remembered '
                    'after restarting the app.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openAutoScrollSheet() {
    const presets = [1, 2, 3, 5, 10];
    final settings = widget.library.settings;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final interval = settings.autoScrollSeconds;
          final isCustom = !presets.contains(interval);
          final plural = interval == 1 ? '' : 's';
          final status = _autoScrollState == 'running'
              ? 'Scrolling • $interval second$plural per page'
              : _autoScrollState == 'paused'
                  ? 'Paused • $interval second$plural per page'
                  : 'Off • $interval second$plural per page';
          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Auto-scroll',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(status,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  for (final s in presets)
                    RadioListTile<int>(
                      title: Text(
                          '$s second${s == 1 ? '' : 's'} per page'),
                      value: s,
                      groupValue: isCustom ? null : interval,
                      onChanged: (v) async {
                        if (v == null) return;
                        settings.autoScrollSeconds = v;
                        await widget.library.saveSettings();
                        setSheet(() {});
                        if (mounted) setState(() {});
                      },
                    ),
                  RadioListTile<int>(
                    title: Text(isCustom
                        ? 'Custom: $interval seconds per page'
                        : 'Custom…'),
                    value: -1,
                    groupValue: isCustom ? -1 : null,
                    onChanged: (_) async {
                      final v = await _pickCustomInterval(ctx, interval);
                      if (v == null) return;
                      settings.autoScrollSeconds = v;
                      await widget.library.saveSettings();
                      setSheet(() {});
                      if (mounted) setState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (_autoScrollState == 'off')
                        FilledButton(
                          onPressed: () {
                            _startAutoScroll();
                            Navigator.of(ctx).pop();
                          },
                          child: const Text('Start'),
                        ),
                      if (_autoScrollState == 'running')
                        FilledButton(
                          onPressed: () {
                            _pauseAutoScroll();
                            setSheet(() {});
                            if (mounted) setState(() {});
                          },
                          child: const Text('Pause'),
                        ),
                      if (_autoScrollState == 'paused')
                        FilledButton(
                          onPressed: () {
                            _resumeAutoScroll();
                            setSheet(() {});
                            if (mounted) setState(() {});
                          },
                          child: const Text('Resume'),
                        ),
                      if (_autoScrollState != 'off')
                        TextButton(
                          onPressed: () {
                            _stopAutoScroll();
                            Navigator.of(ctx).pop();
                          },
                          child: const Text('Stop'),
                        ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(
                      'Turns to the next page by itself at the chosen '
                      'speed. You can still scroll or turn pages '
                      'yourself — the timer restarts after each manual '
                      'turn. It pauses when the app goes into the '
                      'background, and never starts on its own.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<int?> _pickCustomInterval(BuildContext context, int current) async {
    final controller = TextEditingController(text: '$current');
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom interval'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Seconds per page (1–300)',
            suffixText: 's',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              if (v == null || v < 1 || v > 300) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Enter 1 to 300 seconds.')),
                );
                return;
              }
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    return value;
  }

  void _openFrameSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final lib = widget.library;
          final count = _currentFrameCount();
          const panelOptions = [0, 2, 3, 4, 6, 9];
          return Padding(
            padding: EdgeInsets.fromLTRB(
                20, 20, 20, 28 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Panels & Frames',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                  'Panels and frames use the same engine, so they never '
                  'fight each other: a frame is just the panel you are '
                  'reading right now.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                const Text('Panels per page',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final n in panelOptions)
                      ChoiceChip(
                        label: Text(n == 0 ? 'Auto' : '$n'),
                        selected: _doc.panels == n,
                        onSelected: (_) async {
                          _doc.panels = n;
                          await lib.saveDoc(_doc);
                          setSheet(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Layout',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (v, l) in [
                      ('auto', 'Auto'),
                      ('vertical', 'Vertical bands'),
                      ('grid', 'Grid'),
                    ])
                      ChoiceChip(
                        label: Text(l),
                        selected: _doc.frameLayout == v,
                        onSelected: (_) async {
                          _doc.frameLayout = v;
                          await lib.saveDoc(_doc);
                          setSheet(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                ),
                if (_frameLayout() == 'vertical' && count == 2) ...[
                  const SizedBox(height: 12),
                  Text(
                      'Split point: ${(_split * 100).round()}% down the page'),
                  Slider(
                    value: _split,
                    min: 0.3,
                    max: 0.7,
                    divisions: 8,
                    onChanged: (v) {
                      setSheet(() => _split = v);
                      if (mounted) setState(() => _split = v);
                    },
                  ),
                  const Text(
                    'Drag this to move the boundary between the two panels '
                    'when the automatic split cuts something important.',
                    style: TextStyle(fontSize: 13),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                    'Frame overlap: ${(lib.settings.frameOverlap * 100).round()}%'),
                Slider(
                  value: lib.settings.frameOverlap,
                  min: 0,
                  max: 0.20,
                  divisions: 10,
                  onChanged: (v) => setSheet(() => lib.settings.frameOverlap = v),
                  onChangeEnd: (_) async {
                    await lib.saveSettings();
                    if (mounted) setState(() {});
                  },
                ),
                Text('Frame zoom: ${lib.settings.frameZoom.toStringAsFixed(1)}x'),
                Slider(
                  value: lib.settings.frameZoom,
                  min: 1.0,
                  max: 2.0,
                  divisions: 10,
                  onChanged: (v) => setSheet(() => lib.settings.frameZoom = v),
                  onChangeEnd: (_) async {
                    await lib.saveSettings();
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _openPanelEditor();
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit panels for this page…'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openPanelOverview() async {
    try {
      await _detectedFor(_doc, _page);
    } catch (_) {}
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => FutureBuilder<Map<String, dynamic>>(
        future: _pageFutureFor(_doc, _page),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const SizedBox(
              height: 240,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final info = snap.data!;
          final imgW = (info['width'] as num).toDouble();
          final imgH = (info['height'] as num).toDouble();
          final fracs = _effectiveFractionRects(imgW, imgH, _page);
          final count = fracs.length;
          final frame = _clampedFrame(count);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Tap a panel to jump to it',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (ctx, cons) {
                    var w = cons.maxWidth;
                    var h = w * imgH / imgW;
                    if (h > 380) {
                      h = 380;
                      w = h * imgW / imgH;
                    }
                    return Center(
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Image.file(
                                File(info['path'] as String),
                                fit: BoxFit.fill,
                              ),
                            ),
                            for (int i = 0; i < count; i++)
                              Builder(
                                builder: (ctx) {
                                  final cell = fracs[i];
                                  return Positioned(
                                    left: cell.x * w,
                                    top: cell.y * h,
                                    width: cell.w * w,
                                    height: cell.h * h,
                                    child: GestureDetector(
                                      onTap: () {
                                        setState(() => _frameIndex = i);
                                        Navigator.of(ctx).pop();
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: i == frame
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withOpacity(0.25)
                                              : Colors.black.withOpacity(0.15),
                                          border: Border.all(
                                            color: i == frame
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                : Colors.white,
                                            width: i == frame ? 3 : 1,
                                          ),
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(
                                          '${i + 1}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                            shadows: [
                                              Shadow(blurRadius: 4,
                                                  color: Colors.black)
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text('Page ${_page + 1}  •  $count panels  •  '
                    'currently panel ${frame + 1}'),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _openPanelEditor();
                  },
                  child: const Text('Edit panels for this page…'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Frame rectangle without the overlap padding (used by the overview).
  Rect _rawFrameRect(int frame, int count, double imgW, double imgH) {
    // Temporarily compute with zero overlap by calling the same layout
    // logic: vertical bands / grid cells without expansion.
    double x = 0, y = 0, w = imgW, h = imgH;
    if (_frameLayout() == 'vertical') {
      if (count == 2) {
        final splitY = _split * imgH;
        if (frame == 0) {
          y = 0;
          h = splitY;
        } else {
          y = splitY;
          h = imgH - splitY;
        }
      } else {
        h = imgH / count;
        y = frame * h;
      }
      w = imgW;
      x = 0;
    } else {
      final cols = count == 2 ? 2 : (count <= 4 ? 2 : 3);
      final rows = (count + cols - 1) ~/ cols;
      final col = frame % cols;
      final row = frame ~/ cols;
      w = imgW / cols;
      h = imgH / rows;
      x = col * w;
      y = row * h;
    }
    return Rect.fromLTWH(x, y, w, h);
  }

  void _openTextSettings() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final lib = widget.library;
          final s = lib.settings;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Text & Character',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                  'Applies to the extracted-text view only. The PDF file '
                  'itself is never changed.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                Text('Text size: ${s.textSize.round()} pt'),
                Slider(
                  value: s.textSize,
                  min: 12,
                  max: 28,
                  divisions: 16,
                  onChanged: (v) => setSheet(() => s.textSize = v),
                  onChangeEnd: (_) async {
                    await lib.saveSettings();
                    if (mounted) setState(() {});
                  },
                ),
                Text('Character spacing: ${s.letterSpacing.toStringAsFixed(1)} pt'),
                Slider(
                  value: s.letterSpacing,
                  min: 0,
                  max: 3,
                  divisions: 12,
                  onChanged: (v) => setSheet(() => s.letterSpacing = v),
                  onChangeEnd: (_) async {
                    await lib.saveSettings();
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 8),
                const Text('Text colour',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (v, l) in [
                      (0, 'Default'),
                      (1, 'Black'),
                      (2, 'Sepia'),
                      (3, 'White'),
                    ])
                      ChoiceChip(
                        label: Text(l),
                        selected: s.textColor == v,
                        onSelected: (_) async {
                          s.textColor = v;
                          await lib.saveSettings();
                          setSheet(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Character style',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (v, l) in [
                      (0, 'Sans'),
                      (1, 'Serif'),
                      (2, 'Mono'),
                    ])
                      ChoiceChip(
                        label: Text(l),
                        selected: s.textFont == v,
                        onSelected: (_) async {
                          s.textFont = v;
                          await lib.saveSettings();
                          setSheet(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          library: widget.library,
          onChanged: () {
            if (mounted) setState(() {});
          },
        ),
      ),
    );
    _applyNativeSettings();
    if (mounted) setState(() {});
  }

  Future<void> _openPanelEditor() async {
    final info = await _pageFutureFor(_doc, _page);
    if (!mounted) return;
    final imgW = (info['width'] as num).toDouble();
    final imgH = (info['height'] as num).toDouble();
    final initial = _effectiveFractionRects(imgW, imgH, _page);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PanelEditorPage(
          library: widget.library,
          doc: _doc,
          page: _page,
          imagePath: info['path'] as String,
          imgW: imgW,
          imgH: imgH,
          initial: initial,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openZoomDialog(_Entry entry) async {
    final info = await _pageFutureFor(entry.doc, entry.page);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: Image.file(
                File(info['path'] as String),
                fit: BoxFit.contain,
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- content widgets ----------

  static const _invertMatrix = <double>[
    -1, 0, 0, 0, 255,
    0, -1, 0, 0, 255,
    0, 0, -1, 0, 255,
    0, 0, 0, 1, 0,
  ];

  Widget _filteredImage(File f,
      {double? width, double? height, BoxFit fit = BoxFit.contain}) {
    Widget img = Image.file(
      f,
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (ctx, _, __) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Could not render this page. The file may have moved or '
            'be damaged — try reopening the document.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
    if (widget.library.settings.readingFilter) {
      img = ColorFiltered(
        colorFilter: const ColorFilter.matrix(_invertMatrix),
        child: img,
      );
    }
    return img;
  }

  Widget _pageView() {
    if (_doc.pageCount <= 0) {
      return const Center(child: Text('This PDF has no pages.'));
    }
    final frameMode = _isFrameMode;
    final manga = _effectiveStyle() == 'manga';
    // Manga single page: swiping past the last page opens the next
    // document. Only the trailing edge (overscroll > 0, swiping down
    // past the last page), and only for books with more than one
    // page, so one continuous swipe cannot chain through several
    // one-page documents.
    return NotificationListener<OverscrollNotification>(
      onNotification: (n) {
        if (manga &&
            _doc.mangaPaged &&
            _isLastPage &&
            _doc.pageCount > 1 &&
            _nextDoc != null &&
            n.overscroll > 0) {
          _switchDocManga(_nextDoc!);
        }
        return false;
      },
      child: PageView.builder(
        controller: _pageController,
        // Manga mode pages turn top to bottom (one page at a time), so
        // the PageView scrolls vertically and right-to-left does not
        // apply. Horizontal manga reads right to left: the page turn
        // runs the other way, while the page indices stay in reading
        // order (0 is first).
        scrollDirection: manga ? Axis.vertical : Axis.horizontal,
        reverse: manga ? false : _doc.rtl,
        itemCount: _doc.pageCount,
        onPageChanged: _onPageChanged,
      itemBuilder: (ctx, index) {
        return FutureBuilder<Map<String, dynamic>>(
          future: _pageFutureFor(_doc, index),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        'Could not render this page.\n${snap.error}',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            final data = snap.data!;
            if (frameMode) {
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: KeyedSubtree(
                  key: ValueKey('$index-$_frameIndex'),
                  child: _frameContent(data, index),
                ),
              );
            }
            return GestureDetector(
              onLongPressStart: (details) {
                _zoomToPointCentered(details.globalPosition);
              },
              child: InteractiveViewer(
                transformationController: _zoomController,
                minScale: 1.0,
                maxScale: 4.0,
                child: Center(
                  child: _filteredImage(File(data['path'] as String)),
                ),
              ),
            );
          },
        );
      },
      ),
    );
  }

  Widget _frameContent(Map<String, dynamic> data, int pageIndex) {
    final imgW = (data['width'] as num).toDouble();
    final imgH = (data['height'] as num).toDouble();
    // Start automatic detection for this page (cached; the fallback
    // layout shows until detection returns, then the view updates).
    if (_doc.customPanels['$pageIndex'] == null) {
      _detectedFor(_doc, pageIndex);
    }
    final rects = _effectivePixelRects(imgW, imgH, pageIndex);
    final frame = pageIndex == _page
        ? _clampedFrame(rects.length)
        : 0;
    // Defense in depth: saved layouts are sanitized on load, but a
    // degenerate rect must never reach the scale division below (width
    // 0 would make the scale infinite). Show the full page instead.
    final raw = rects[frame.clamp(0, rects.length - 1)];
    final rect = (raw.width > 0 && raw.height > 0)
        ? raw
        : Rect.fromLTWH(0, 0, imgW, imgH);
    final zoom = widget.library.settings.frameZoom;
    return GestureDetector(
      onLongPressStart: (details) {
        _zoomToPointCentered(details.globalPosition);
      },
      child: LayoutBuilder(
      builder: (ctx, cons) {
        final vw = cons.maxWidth;
        final vh = cons.maxHeight;
        final scale = (vw / rect.width) * zoom;
        final dw = imgW * scale;
        final dh = imgH * scale;
        final left = (vw - rect.width * scale) / 2 - rect.left * scale;
        final top = (vh - rect.height * scale) / 2 - rect.top * scale;
        return InteractiveViewer(
          transformationController: _zoomController,
          minScale: 1.0,
          maxScale: 4.0,
          child: SizedBox(
            width: vw,
            height: vh,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: SizedBox(
                    width: dw,
                    height: dh,
                    child: _filteredImage(
                      File(data['path'] as String),
                      width: dw,
                      height: dh,
                      fit: BoxFit.fill,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      ),
    );
  }

  Widget _scrollView() {
    final entries = _scrollEntries();
    final vw = MediaQuery.of(context).size.width;
    // A user drag cancels any programmatic scroll in flight (a
    // volume-key page turn): the scroll target is dropped, so page
    // tracking follows the user's finger again at once. A drag also
    // marks the user as having navigated, which is what arms the
    // manga auto-next guard.
    return NotificationListener<ScrollStartNotification>(
      onNotification: (n) {
        if (n.dragDetails != null) {
          _scrollTarget = null;
          _userNavigated = true;
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        // Explicit Android-standard physics: no bounce, no
        // overshoot stutter, and a drag always wins over a
        // running programmatic scroll.
        physics: const ClampingScrollPhysics(),
        itemCount: entries.length,
      itemBuilder: (ctx, idx) {
        final e = entries[idx];
        return FutureBuilder<Map<String, dynamic>>(
          future: _pageFutureFor(e.doc, e.page),
          builder: (ctx, snap) {
            if (!snap.hasData) {
              // Size the placeholder exactly like the real page
              // (real aspect ratio once known, same estimate
              // otherwise): a placeholder that is a different
              // height from the page makes the list jump when the
              // image loads.
              return SizedBox(
                height: _itemHeight(e, vw),
                child: const Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return const SizedBox(
                height: 200,
                child: Center(child: Text('Could not render this page.')),
              );
            }
            final data = snap.data!;
            final imgW = (data['width'] as num).toDouble();
            final imgH = (data['height'] as num).toDouble();
            final h = vw * imgH / imgW;
            return Column(
              children: [
                GestureDetector(
                  onLongPress: () => _openZoomDialog(e),
                  child: _filteredImage(
                    File(data['path'] as String),
                    width: vw,
                    height: h,
                    fit: BoxFit.fill,
                  ),
                ),
                // The gap between pages. In Manga mode this is 0:
                // the pages touch, so a spread reads as one image.
                // Every other scroll mode keeps its 8px gap.
                SizedBox(height: _pageGap),
              ],
            );
          },
        );
      },
      ),
    );
  }

  Widget _textView() {
    final s = widget.library.settings;
    final font = s.textFont == 1
        ? 'serif'
        : (s.textFont == 2 ? 'monospace' : null);
    final color = s.textColor == 1
        ? const Color(0xFF111111)
        : (s.textColor == 2
            ? const Color(0xFF4A3226)
            : (s.textColor == 3 ? Colors.white : null));
    return FutureBuilder<String>(
      future: PdfTextExtractor.pageText(File(_doc.path), _page),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final text = (snap.data ?? '').trim();
        if (text.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.article_outlined, size: 48),
                  SizedBox(height: 12),
                  Text(
                    'No extractable text on this page.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'This PDF is probably scanned or image-only, so there is '
                    'no text layer to select or restyle, and text colour '
                    'and size cannot change the scanned page image. The '
                    'page image still reads fine — switch back with the '
                    'text icon.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: SelectableText(
                  text,
                  style: TextStyle(
                    fontSize: s.textSize,
                    height: s.lineHeight,
                    letterSpacing: s.letterSpacing,
                    fontFamily: font,
                    color: color,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Page text copied')),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy text'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => NativeBridge.shareText(text),
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Share text'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Text & Character settings',
                    icon: const Icon(Icons.text_fields),
                    onPressed: _openTextSettings,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final shownPage = _previewPage ?? _page;
    final progressPct =
        _doc.pageCount > 0 ? ((_page + 1) / _doc.pageCount * 100).round() : 0;
    final theme = Theme.of(context);
    final style = _effectiveStyle();
    final frameMode = _isFrameMode && !_showText;
    final frameCount = _currentFrameCount();
    final frame = _clampedFrame(frameCount);
    final scrollMode = _isScrollMode && !_showText;

    Widget content;
    if (_showText) {
      content = _textView();
    } else if (scrollMode) {
      content = _scrollView();
    } else {
      content = _pageView();
    }

    final appBar = _controlsVisible
        ? AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                _cleanup();
                Navigator.of(context).pop();
              },
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _doc.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
                Text(
                  frameMode
                      ? 'Page ${_page + 1} / ${_doc.pageCount}  •  '
                          'Panel ${frame + 1} / $frameCount  •  $progressPct%'
                      : 'Page ${_page + 1} / ${_doc.pageCount}  •  $progressPct%',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withOpacity(0.65),
                  ),
                ),
              ],
            ),
            actions: [
              // Text view only exists for PDFs (extracted text). Comic
              // pages are images, so the toggle is hidden for them.
              if (_doc.kind == 'pdf')
                IconButton(
                  tooltip: _showText ? 'Show page image' : 'Select text',
                  icon: Icon(_showText ? Icons.image_outlined : Icons.text_fields),
                  onPressed: () => setState(() => _showText = !_showText),
                ),
              IconButton(
                tooltip: 'Brightness',
                icon: const Icon(Icons.brightness_6_outlined),
                onPressed: _brightnessReady ? _openBrightnessSheet : null,
              ),
              IconButton(
                tooltip: 'Screenshot this page',
                icon: const Icon(Icons.camera_alt_outlined),
                onPressed: _screenshot,
              ),
              IconButton(
                tooltip: 'Reading style',
                icon: const Icon(Icons.auto_stories_outlined),
                onPressed: _openStyleSheet,
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'prev' && _prevDoc != null) {
                    _switchDoc(_prevDoc!);
                  } else if (v == 'next' && _nextDoc != null) {
                    _switchDoc(_nextDoc!);
                  } else if (v == 'volume') {
                    final lib = widget.library;
                    lib.settings.volumeEnabled = !lib.settings.volumeEnabled;
                    await lib.saveSettings();
                    _applyNativeSettings();
                    if (mounted) setState(() {});
                  } else if (v == 'shortcut') {
                    final lib = widget.library;
                    lib.settings.screenshotShortcutEnabled =
                        !lib.settings.screenshotShortcutEnabled;
                    await lib.saveSettings();
                    _applyNativeSettings();
                    if (mounted) setState(() {});
                  } else if (v == 'filter') {
                    final lib = widget.library;
                    lib.settings.readingFilter = !lib.settings.readingFilter;
                    await lib.saveSettings();
                    if (mounted) setState(() {});
                  } else if (v == 'rtl') {
                    _doc.rtl = !_doc.rtl;
                    await widget.library.saveDoc(_doc);
                    if (mounted) setState(() {});
                  } else if (v == 'mangaPaged') {
                    _doc.mangaPaged = !_doc.mangaPaged;
                    await widget.library.saveDoc(_doc);
                    if (mounted) setState(() {});
                    _afterStyleChange();
                  } else if (v == 'autoScroll') {
                    _openAutoScrollSheet();
                  } else if (v == 'panels') {
                    _openFrameSettings();
                  } else if (v == 'overview') {
                    _openPanelOverview();
                  } else if (v == 'controls') {
                    _setControlsVisible(false);
                  } else if (v == 'editPanels') {
                    _openPanelEditor();
                  } else if (v == 'settings') {
                    _openSettings();
                  } else if (v == 'shareShot') {
                    if (_lastScreenshotUri != null) {
                      NativeBridge.shareImageUri(_lastScreenshotUri!);
                    }
                  }
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                    value: 'prev',
                    enabled: _prevDoc != null,
                    child: Text(_prevDoc == null
                        ? 'Previous document'
                        : 'Previous: ${_prevDoc!.name}'),
                  ),
                  PopupMenuItem(
                    value: 'next',
                    enabled: _nextDoc != null,
                    child: Text(_nextDoc == null
                        ? 'Next document'
                        : 'Next: ${_nextDoc!.name}'),
                  ),
                  PopupMenuItem(
                    value: 'volume',
                    child: Row(
                      children: [
                        Icon(
                          widget.library.settings.volumeEnabled
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: const Text('Volume buttons turn pages')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'shortcut',
                    child: Row(
                      children: [
                        Icon(
                          widget.library.settings.screenshotShortcutEnabled
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: const Text('Vol Up + Down = screenshot')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'filter',
                    child: Row(
                      children: [
                        Icon(
                          widget.library.settings.readingFilter
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: const Text('Dark page filter')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rtl',
                    child: Row(
                      children: [
                        Icon(
                          _doc.rtl
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: const Text('Read right to left (manga)')),
                      ],
                    ),
                  ),
                  // Manga mode only: flip between the strip (several
                  // pages at once) and one page at a time, without
                  // leaving the reader.
                  if (style == 'manga')
                    PopupMenuItem(
                      value: 'mangaPaged',
                      child: Row(
                        children: [
                          Icon(
                            _doc.mangaPaged
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                              child: const Text('Manga: one page at a time')),
                        ],
                      ),
                    ),
                  // Manga mode only: automatic page turns at the
                  // user's chosen speed.
                  if (style == 'manga')
                    PopupMenuItem(
                      value: 'autoScroll',
                      child: Row(
                        children: [
                          Icon(
                            _autoScrollState == 'running'
                                ? Icons.pause_circle_outline
                                : Icons.play_circle_outline,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(_autoScrollState == 'off'
                                ? 'Auto-scroll…'
                                : 'Auto-scroll: ${_autoScrollState == 'running' ? 'scrolling' : 'paused'}'),
                          ),
                        ],
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'panels',
                    child: Text('Panels & Frames…'),
                  ),
                  const PopupMenuItem(
                    value: 'overview',
                    child: Text('Panel overview…'),
                  ),
                  PopupMenuItem(
                    value: 'shareShot',
                    enabled: _lastScreenshotUri != null,
                    child: const Text('Share last screenshot'),
                  ),
                  const PopupMenuItem(
                    value: 'editPanels',
                    child: Text('Edit panels for this page…'),
                  ),
                  const PopupMenuItem(
                    value: 'controls',
                    child: Text('Hide controls (tap to show)'),
                  ),
                  const PopupMenuItem(
                    value: 'settings',
                    child: Text('Settings…'),
                  ),
                ],
              ),
            ],
          )
        : null;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cleanup();
      },
      child: Scaffold(
        appBar: appBar,
        body: Column(
          children: [
            Expanded(
              child: RepaintBoundary(
                key: _shotKey,
                child: Stack(
                  children: [
                    GestureDetector(
                      onTapUp: _onTapUp,
                      child: content,
                    ),
                    if (_controlsVisible &&
                        _isLastPage &&
                        _nextDoc != null &&
                        style != 'continuous' &&
                        // Manga mode opens the next document by
                        // itself — no prompt card.
                        style != 'manga' &&
                        !_showText)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Card(
                          elevation: 4,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'End of document',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Next up: ${_nextDoc!.name}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 10),
                                FilledButton.icon(
                                  onPressed: () => _switchDoc(_nextDoc!),
                                  icon: const Icon(Icons.skip_next, size: 18),
                                  label: const Text('Next Document'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_controlsVisible &&
                        _isFirstPage &&
                        _prevDoc != null &&
                        style != 'continuous' &&
                        // Hidden while auto-scroll runs: the status
                        // bar below occupies the same corner.
                        _autoScrollState == 'off' &&
                        !_showText)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Card(
                          elevation: 4,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Previous: ${_prevDoc!.name}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _switchDoc(_prevDoc!),
                                  child: const Text('Previous'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // Auto-scroll status: the current interval and
                    // state, with Pause / Resume and Stop at hand.
                    // Tapping the speed icon opens the settings
                    // sheet. Shown whenever auto-scroll is running
                    // or paused, controls or not.
                    if (_autoScrollState != 'off' && !_showText)
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(24),
                          color: theme.colorScheme.surfaceContainerHigh,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: 'Auto-scroll settings',
                                  icon: const Icon(Icons.speed, size: 20),
                                  onPressed: _openAutoScrollSheet,
                                ),
                                Expanded(
                                  child: Text(
                                    'Auto-scroll • ${_autoScrollInterval}s / page • '
                                    '${_autoScrollState == 'running' ? 'Scrolling' : 'Paused'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                IconButton(
                                  tooltip: _autoScrollState == 'running'
                                      ? 'Pause'
                                      : 'Resume',
                                  icon: Icon(
                                    _autoScrollState == 'running'
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    size: 20,
                                  ),
                                  onPressed: _autoScrollState == 'running'
                                      ? _pauseAutoScroll
                                      : _resumeAutoScroll,
                                ),
                                IconButton(
                                  tooltip: 'Stop auto-scroll',
                                  icon: const Icon(Icons.stop, size: 20),
                                  onPressed: _stopAutoScroll,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_controlsVisible)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: theme.dividerColor),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                child: Column(
                  children: [
                    if (_zoomed && !_showText)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: () =>
                                _animateZoom(Matrix4.identity()),
                            icon: const Icon(Icons.zoom_out_map, size: 18),
                            label: const Text('Reset zoom'),
                          ),
                        ],
                      ),
                    if (frameMode) ...[
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Previous panel',
                            icon: const Icon(Icons.chevron_left),
                            onPressed: frame == 0 && _isFirstPage
                                ? null
                                : _prevFrame,
                          ),
                          Expanded(
                            child: Slider(
                              value: frame.toDouble(),
                              min: 0,
                              max: (frameCount - 1).toDouble(),
                              divisions:
                                  frameCount > 1 ? frameCount - 1 : null,
                              label: 'Panel ${frame + 1}',
                              onChanged: (v) => setState(
                                  () => _frameIndex = v.round()),
                              onChangeEnd: (v) => _goToFrame(v.round()),
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: Text(
                              'Panel ${frame + 1} / $frameCount',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Next panel',
                            icon: const Icon(Icons.chevron_right),
                            onPressed: frame == frameCount - 1 && _isLastPage
                                ? null
                                : _nextFrame,
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton(
                            onPressed: _openPanelOverview,
                            child: const Text('Choose panel'),
                          ),
                          TextButton(
                            onPressed: _openFrameSettings,
                            child: const Text('Adjust panels'),
                          ),
                        ],
                      ),
                    ],
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Previous page',
                          // Manga reads right to left: "previous" points
                          // right, "next" points left. The actions stay
                          // the same (previous = earlier page).
                          icon: Icon(_doc.rtl
                              ? Icons.chevron_right
                              : Icons.chevron_left),
                          onPressed: (_doc.pageCount <= 0 || _isFirstPage)
                              ? null
                              : () => _goToPage(_page - 1),
                        ),
                        Expanded(
                          child: Slider(
                            value: _doc.pageCount <= 0
                                ? 0
                                : shownPage.toDouble(),
                            min: 0,
                            max: (_doc.pageCount - 1)
                                .clamp(0, 100000)
                                .toDouble(),
                            divisions:
                                _doc.pageCount > 1 ? _doc.pageCount - 1 : null,
                            label: '${shownPage + 1}',
                            onChanged: (v) =>
                                setState(() => _previewPage = v.round()),
                            onChangeEnd: (v) => _goToPage(v.round()),
                          ),
                        ),
                        SizedBox(
                          width: 86,
                          child: Text(
                            '${shownPage + 1} / ${_doc.pageCount}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Next page',
                          icon: Icon(_doc.rtl
                              ? Icons.chevron_left
                              : Icons.chevron_right),
                          onPressed: (_doc.pageCount <= 0 || _isLastPage)
                              ? null
                              : () => _goToPage(_page + 1),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton.icon(
                          onPressed: _prevDoc == null
                              ? null
                              : () => _switchDoc(_prevDoc!),
                          icon: const Icon(Icons.skip_previous, size: 18),
                          label: const Text('Prev doc'),
                        ),
                        TextButton(
                          onPressed: _jumpDialog,
                          child: const Text('Jump to page'),
                        ),
                        TextButton.icon(
                          onPressed: _nextDoc == null
                              ? null
                              : () => _switchDoc(_nextDoc!),
                          label: const Text('Next doc'),
                          icon: const Icon(Icons.skip_next, size: 18),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
