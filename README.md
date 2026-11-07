
## Questions?

Ask in [Discussions](https://github.com/oxsh0gunX/Manga-Reader/discussions) — the Q&A category is for import, reading styles, Manga mode and anything else. Answers that solve a question get marked as the accepted answer.

<p align="center">
  <img src="assets/app_icon.png" width="160" alt="Manga Reader icon">
</p>

<h1 align="center">📚 Manga Reader</h1>

<p align="center">
  <b>A premium, minimal PDF &amp; comic reader for Android.</b><br>
  No login. No ads. No cloud. No AI. Just your books, exactly where you left them. ⚡
</p>

<p align="center">
  <a href="https://github.com/oxsh0gunX/Manga-Reader/releases"><img src="https://img.shields.io/badge/version-2.3.5-red" alt="version 2.3.5"></a>
  <img src="https://img.shields.io/badge/Android-8.0%2B-brightgreen" alt="Android 8.0+">
  <img src="https://img.shields.io/badge/offline-100%25-blue" alt="100% offline">
  <img src="https://img.shields.io/badge/login-none-lightgrey" alt="no login">
  <img src="https://img.shields.io/badge/ads-none-yellow" alt="no ads">
  <img src="https://img.shields.io/badge/Manga_mode-on-purple" alt="Manga mode">
</p>

<p align="center">
  <a href="#-get-it"><b>📥 Download</b></a> ·
  <a href="#-what-it-does">✨ Features</a> ·
  <a href="#-manga-mode">🖼️ Manga mode</a> ·
  <a href="#-reading-styles">📐 Styles</a> ·
  <a href="#-version-history">🕘 What's new</a>
</p>

---

## ✨ At a glance

| 📚 Library | 📖 Reading | 🖼️ Manga mode | 🎛️ Controls |
| --- | --- | --- | --- |
| Import PDFs, CBZ, CB7, CBT & images | Clean fullscreen pages, tap to show controls | Strip & single page, top to bottom | Volume keys turn pages |
| Drag-and-drop reading order | Pinch zoom, long-press zoom, brightness | Auto-scroll at your speed | Volume Up+Down = screenshot |
| Search, recent books, progress | Text view with copy & share | Auto-opens the next book | Panels & frames, one at a time |

> 🎉 **New in v2.3.5 — Manga mode, improved:** strip pages now touch with **no gaps**, so a spread reads as one image; smoother scrolling; **Auto-scroll** (1–10 s per page or custom, Start / Pause / Resume / Stop); and **Auto-next document** — finish a book and the next one opens by itself, in Manga mode, from its first page. See [🕘 Version history](#-version-history).

---

## 📥 Get it

Download the latest APK from **[Releases](https://github.com/oxsh0gunX/Manga-Reader/releases)** and install it on your phone.

> ⚠️ **Install over the previous version — do not uninstall first**, or your library and reading progress will be lost. Updates keep everything: your PDFs, your reading order, and your place in every book.

## ✨ What it does

### 📚 Library
- Import PDFs one at a time from your phone — copies live in the app's private files, so books stay readable even if the original file moves
- Name, page count, and progress on every card, plus a recently-opened row and search
- Drag-and-drop reading order — that order *is* the Next Document sequence
- Missing files are flagged on their card with a Remove option, instead of opening a broken reader

### 📖 Reading
- Clean, distraction-free pages: controls hide while you read, tap to show them, true fullscreen
- Page indicator, slider, and jump-to-page — and your place is remembered in every document
- Pinch zoom, plus long-press any area to zoom into it, centred, with a reset
- In-reader brightness slider with reset — your system brightness is restored when you leave
- Extracted-text view with copy and share (scanned PDFs honestly report "no text" instead of showing junk)

### 🖼️ Comics & manga
- Comic archives open right from the library: **CBZ / ZIP, CB7 / 7Z, CBT / TAR** (including `.tar.gz`, `.tar.bz2`, `.tar.xz`), plus **single images** (JPG, PNG, WEBP, GIF, BMP — BMP is converted to JPEG on import, because Flutter cannot show it)
- Pages are sorted naturally — `page1, page2, page10` — never `page1, page10, page2`, including inside subfolders
- **Right-to-left manga reading**: menu → "Read right to left (manga)" flips the tap zones, the page-turn direction, and the bottom-bar arrows (volume keys always move in reading order). Left-to-right is the default for comics
- Everything from the PDF reader carries over: volume keys, tap navigation, vertical scrolling, brightness, screenshots, progress, and panel/frame modes where they apply
- **CBR / RAR is not supported**: no RAR reader could be verified for this Dart/Flutter version and Android setup, so a `.cbr` file is refused with a clear message suggesting conversion to CBZ instead of pretending to open it. Password-protected archives and 7z files using PPMd compression are refused the same way
- Automatic panel detection for bordered pages, with a grid fallback when nothing is found — never a claim of perfect detection
- Manual panel editor: move, resize, add, delete, reorder — saved per document and page, restored on reopening
- One panel at a time, in reading order, with smooth fade transitions and a panel overview to jump between panels

### 🎛️ Controls
| Key | Does |
| --- | --- |
| Volume Up | Next page / panel — on the last page, opens the next document |
| Volume Down | Previous page / panel — on the first page, opens the previous document |
| Volume Up + Down | Screenshot, saved to Pictures / PDF Reader, with a Share action |

Single presses only, both directions fully configurable in Settings, and the keys return to normal system volume outside the reader.

### 🎨 Make it yours
- Reading styles saved per document: horizontal, vertical, panel, frame, continuous, manga, or auto (adapts to the page shape)
- Frame layout, panels per page, overlap padding, and frame zoom
- Text size, colour, font, letter spacing, and line height for the text view (never restyles the PDF page image)
- Day, Dark, and System themes, plus an opt-in dark page filter

## 📐 Reading styles

| Style | Best for |
| --- | --- |
| Horizontal | Regular books, page by page |
| Vertical | Scrolling through a document |
| Panel | Comics and manga, one panel at a time |
| Frame | Tall pages, read in stacked bands |
| Continuous | Flowing through your whole library in order |
| **Manga** | **Manga: top to bottom, spreads together, auto-scroll & auto-next** |
| Auto | Lets the page shape decide |

## 🖼️ Manga mode

A manga spread is one image running across two pages, so one page at a time left-to-right splits it. Manga mode flows **top to bottom** instead:

- **Strip** (default) — pages scroll down with several visible at once, so both pages of a spread show together. Pages touch with no gap, so a spread reads as one image.
- **Single page** — one page at a time, swiped up and down (top tap = back, bottom tap = forward, middle tap = controls).
- **Auto-scroll** — the reader turns pages by itself at your speed: 1 / 2 / 3 / 5 / 10 seconds per page, or a custom interval (1–300 s, saved). Start / Pause / Resume / Stop, with a status bar showing the interval and state. A manual turn restarts the interval; it pauses when the app goes to the background and never restarts itself.
- **Auto-next document** — reach the end of a book and the next one in your library opens by itself, in Manga mode, from its first page. No popup. The last book simply stops.

Pick it in the Reading style sheet (top of the list), or flip between strip and single page from the reader's menu. Saved per document.

## 🛠️ How it works

Pages are rendered by Android's native `PdfRenderer`, not by a Flutter plugin, and shown from cached JPEGs. Comic pages are extracted locally on the device into the app's private `comics/` folder (never a public folder): ZIP and TAR archives with the pure-Dart `archive` package (`archive: ^4.6.0` in `pubspec.yaml`, the only Dart dependency), 7z archives with Apache Commons Compress 1.26.0 running in the Java host (vendored jars, no Gradle). Extraction caps at 2000 pages and 100 MB per page, and a failed or corrupt import deletes the picked copy and any half-extracted pages, leaving nothing behind. Importing a comic also stores the archive copy next to the PDFs, so a book takes roughly twice its archive size on disk. The rendered-page cache keeps only the newest 120 pages and re-renders older ones on demand.

Your library (`library.json` in the app's private files) is written atomically (temp file + rename) and saves are serialized, so a crash mid-write or two overlapping saves cannot truncate it or lose an update.

## 🗂️ Project structure

```
lib/
├── main.dart          # app entry, themes
├── home.dart          # library: recent, all docs, search, import, reorder
├── reader.dart        # the reader: styles, frames & panels, keys, brightness
├── library.dart       # document model, settings, JSON persistence
├── comic.dart         # comic format detection, natural sort, ZIP/TAR extraction
├── file_hash.dart     # pure-Dart streaming SHA-256 for duplicate detection
├── native.dart        # MethodChannel bridge to the Android host
├── pdf_text.dart      # pure-Dart text extraction (Flate, Tj/TJ)
├── settings_page.dart # full Settings screen
├── about_page.dart    # About page
└── panel_editor.dart  # manual panel editor
android/.../MainActivity.java  # SAF picking, PdfRenderer, volume keys,
                               # brightness, MediaStore screenshots, sharing
manual/                # manifest + resources for the manual packaging route
test/                  # JSON, reliability, volume-navigation, v2.2.3, comic
                       # (detection, extraction, sorting, errors), RTL,
                       # manga mode, and v2.3.5 auto-scroll / auto-next tests
MANUAL_TESTS.md        # manual procedures for what automated tests can't cover
```

## 🔨 Building

Standard route, if your Gradle setup works:

```sh
flutter pub get
flutter build apk --release
```

Manual route used for the delivered APKs (bypasses Gradle): see `build-pdfreader-v235.sh` next to this folder. It runs `flutter assemble` for arm64 + arm, compiles the Java host, links with `aapt2`, dexes with `d8`, then `zipalign` + `apksigner`. Its locations are overridable with environment variables instead of being hard-coded to one machine:

- `WORKSPACE` (default `~/workspace`) — project, Flutter install, toolchain jars and signing key all live under it
- `JAVA_HOME` (default `~/jdk17`, used only if it contains `javac`), `FLUTTER_BIN` (default `$WORKSPACE/flutter/bin`), `ANDROID_SDK` (default `~/Android/Sdk`), `KEYSTORE` (default `$WORKSPACE/debug.keystore`)

The manual route still needs this machine's toolchain jars (`flutter-proof/`, `m2/`) and the same signing key. A new signing key means the app will **not** install over the existing one; keep the same key if you want updates to keep the user's library and progress.

## 🕘 Version history

| Version | What landed |
| --- | --- |
| v1 | Library, progress, volume pages, brightness, text view, screenshots |
| v2 | Reading styles, frames & panels, screenshot shortcut, full Settings |
| v2.1 | Panel detection + editor, About page, clean fullscreen reader |
| v2.2 | Render-cache limits, panel transitions, missing-file handling, app icon |
| v2.2.1 | Reliability: tolerant loading, atomic saves, native resource fixes |
| v2.2.2 | Volume keys switch documents at the ends of a book |
| v2.2.3 | Duplicate-import guard (content hash), left/right tap navigation, vertical mode verified + tested |
| v2.3.0 | Comic & manga formats: CBZ/ZIP, CB7/7Z, CBT/TAR (+ compressed tar), single images; natural page order; right-to-left manga reading; duplicate guard and full reader feature set for comics. CBR/RAR is detected and refused, not claimed. |
| v2.3.1 | Multiple file selection: pick several PDFs, comics and images in one picker session — each imports in turn, with a progress dialog and a summary (added / already in library / failed, with the reason). One bad file never stops the rest. Also renamed to **Manga Reader** (launcher name, home title, About). Package name and signing unchanged; screenshots still save to Pictures / PDF Reader. |
| v2.3.2 | New launcher + About icon: the manga-reader face the user picked (Icon 2). Multi-select picker fix: the picker no longer goes through a chooser — on MIUI the chooser handed the pick to Mi File Explorer, whose multi-select does not stick (only one file came back). The app now opens the system Documents picker directly, which returns all selected files. |
| v2.3.3 | **In-app file browser — the real multi-select fix.** On the user's phone the system picker never returned the selection at all: the Documents picker is not reachable on MIUI, and Mi File Explorer opens in browse mode (tapping a file asks "Open with"; long-press select has no usable confirm) and returns nothing. So the app now lists the shared storage itself: tap **Import files** → allow "All files access" once → browse folders, tick several files with clear checkboxes, **Import N selected**. Same import path as before (duplicates, corrupt files, unsupported formats handled per file). System picker kept as a fallback in the browser menu. |
| v2.3.4 | **Manga mode.** A manga spread is one image running across two pages, so one page at a time left-to-right splits it. Manga mode flows top to bottom instead: **Strip** (default) scrolls the pages down with several visible at once, so both pages of a spread show together; **Single page** shows one page at a time, swiped up and down (top tap = back, bottom tap = forward, middle tap = controls). Pick it in the Reading style sheet (top of the list) or flip between strip and single page from the reader's menu. Saved per document. Also fixed while testing it: a volume-key page turn in any scroll mode could briefly push the saved page backwards mid-animation (`_scrollTarget` guard). |
| v2.3.5 | **Manga mode improvements.** Strip pages now touch with no gap, so a spread reads as one image (other scroll modes keep their 8px gap); smoother scrolling — placeholders are sized like the real page and comic pages ahead are pre-sized, so the list never jumps as images load, and manga turns glide a little slower and softer. **Auto-scroll** (reader menu, Manga mode only): 1 / 2 / 3 / 5 / 10 seconds per page or a custom interval (1–300 s, saved), with Start / Pause / Resume / Stop and a status bar showing the interval and state; a manual turn restarts the interval, it pauses when the app goes to the background and never restarts itself, and exactly one timer runs at a time. **Auto-next document:** reaching the end of a book in Manga mode opens the next document in library order, in Manga mode, from its first page — no popup; the last document simply stops. Also fixed while testing it: a stale page-change report from a previous document's PageView could be saved as the new document's progress after a switch (`_onPageChanged` now only accepts a page the reader or the controller is actually on), and `_stopAutoScroll` no longer calls `setState` while the reader is being torn down. |

Version consistency: `2.3.5+13` in `pubspec.yaml`, `2.3.5` on the About page and in the Settings subtitle, and `v2.3.5` here. Package `com.example.pdfreader`, minSdk 26, targetSdk 34, signing configuration unchanged.

## ✅ Tests

```sh
flutter analyze   # clean
flutter test      # 124 tests: JSON round-trips, reliability bounds, panel
                  # persistence, volume navigation, v2.2.3 tap/duplicate
                  # tests, plus comic detection, natural sort, ZIP/TAR
                  # extraction, import flow, errors, RTL reader tests,
                  # manga mode, and v2.3.5 auto-scroll / auto-next tests
```

Known limits worth knowing before you test on the phone:

- **CBR / RAR is not supported** (see above) — convert to CBZ on a computer first.
- **Encrypted archives are refused** — there is no password prompt by design.
- **7z with PPMd compression is refused** — Commons Compress cannot read it.
- **A short book's last page may not register as read in vertical mode**: the scroll tracker watches a point 60 px below the top of the screen, and a short book cannot scroll far enough for that point to pass the last page's top. Page-by-page mode, volume keys, and mode switching still record the page correctly.
- Comic pages are extracted next to the archive copy, so a comic uses roughly twice its archive size until you delete it (deleting the book removes its extracted pages too).

Native behaviour (volume dispatch, brightness, MediaStore, real rendering) can't run in `flutter test` — see `MANUAL_TESTS.md` for the step-by-step phone procedures.

---

<p align="center">
  <b>📚 Manga Reader</b> · by Safvan · <a href="mailto:safvanmbn@gmail.com">safvanmbn@gmail.com</a> · <a href="https://github.com/oxsh0gunX">GitHub</a><br>
  © 2026 Safvan. All rights reserved.
</p>
