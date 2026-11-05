<p align="center">
  <img src="assets/app_icon.png" width="128" alt="PDF Reader icon">
</p>

<h1 align="center">PDF Reader</h1>

<p align="center">
  A premium, minimal PDF &amp; comic reader for Android.<br>
  No login. No ads. No cloud. No AI. Just your books, exactly where you left them.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-2.3.0-red" alt="version 2.3.0">
  <img src="https://img.shields.io/badge/Android-8.0%2B-green" alt="Android 8.0+">
  <img src="https://img.shields.io/badge/offline-100%25-blue" alt="100% offline">
  <img src="https://img.shields.io/badge/login-none-lightgrey" alt="no login">
</p>

---

## 📥 Get it

Download the latest APK from **[Releases](https://github.com/oxsh0gunX/PDF-Reader/releases)** and install it on your phone.

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
- Reading styles saved per document: horizontal, vertical, panel, frame, continuous, or auto (adapts to the page shape)
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
| Auto | Lets the page shape decide |

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
test/                  # JSON, reliability, volume-navigation, v2.2.3, and
                       # comic (detection, extraction, sorting, errors) tests
MANUAL_TESTS.md        # manual procedures for what automated tests can't cover
```

## 🔨 Building

Standard route, if your Gradle setup works:

```sh
flutter pub get
flutter build apk --release
```

Manual route used for the delivered APKs (bypasses Gradle): see `build-pdfreader-v230.sh` next to this folder. It runs `flutter assemble` for arm64 + arm, compiles the Java host, links with `aapt2`, dexes with `d8`, then `zipalign` + `apksigner`. Its locations are overridable with environment variables instead of being hard-coded to one machine:

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

Version consistency: `2.3.0+8` in `pubspec.yaml`, `2.3.0` on the About page and in the Settings subtitle, and `v2.3.0` here. Package `com.example.pdfreader`, minSdk 26, targetSdk 34, signing configuration unchanged.

## ✅ Tests

```sh
flutter analyze   # clean
flutter test      # 83 tests: JSON round-trips, reliability bounds, panel
                  # persistence, volume navigation, v2.2.3 tap/duplicate
                  # tests, plus comic detection, natural sort, ZIP/TAR
                  # extraction, import flow, errors, and RTL reader tests
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
  <b>PDF Reader</b> · by Safvan · <a href="mailto:safvanmbn@gmail.com">safvanmbn@gmail.com</a> · <a href="https://github.com/oxsh0gunX">GitHub</a><br>
  © 2026 Safvan. All rights reserved.
</p>
