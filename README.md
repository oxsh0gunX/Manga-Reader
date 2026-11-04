# PDF Reader — Flutter source (v2.2.2)

Premium, minimal, fully offline PDF & comic reader for Android. No login,
no AI chat, no OCR, no cloud sync, no subscriptions.

## What is inside

- `lib/main.dart` — app entry, light/dark/system themes.
- `lib/home.dart` — library home: recently opened, all documents, search,
  import, drag-and-drop reading-order screen.
- `lib/reader.dart` — the reader: horizontal / vertical / panel / frame /
  continuous / auto styles, frame & panel engine, volume keys, brightness,
  screenshot, text view, area zoom, fullscreen, next/previous document.
- `lib/library.dart` — document model, reading style & panel settings per
  document, app settings, JSON persistence (`library.json` in the app's
  private files dir). The list order IS the reading sequence.
- `lib/native.dart` — MethodChannel bridge to the Android host.
- `lib/pdf_text.dart` — pure-Dart PDF text extraction (page tree, Flate
  streams, Tj/TJ operators). Scanned/image-only PDFs have no text layer
  and are reported as such instead of showing junk.
- `lib/settings_page.dart` — full Settings screen, including the About row.
- `lib/about_page.dart` — About page (app icon, version 2.2.2, developer
  Safvan, Contact Developer mailto button, GitHub Profile button, with a
  copy fallback if no email/browser app can open).
- `lib/panel_editor.dart` — manual panel editor for one page: drag to
  move, drag the corner to resize, sliders for precision, add/delete,
  reading-order arrows, automatic detection, and per-page saving.
- `test/library_test.dart` — JSON round-trip tests for saved panel
  layouts and backward compatibility with old library files.
- `test/reliability_test.dart` — tolerance and bounds tests: panel
  coordinate sanitization, out-of-range page clamping, tolerant
  settings/document parsing, progress and reorder guards, settings
  round-trip, panel persistence and restart restoration.
- `test/volume_navigation_test.dart` — widget tests driving real
  volume events through the events channel: normal page turns,
  document switching at both ends, staying put at the ends of the
  sequence, and the panel-mode frame-to-document crossing.
- `MANUAL_TESTS.md` — step-by-step manual procedures for everything
  automated tests cannot cover (volume keys, screenshots, brightness,
  native rendering, large PDFs, airplane mode).
- `android/app/src/main/java/com/example/pdfreader/MainActivity.java` —
  the Android host: Storage Access Framework single-PDF picking (copied
  into the app's files), `PdfRenderer` page rendering to cached JPEGs,
  volume-key interception (including the Volume Up + Down screenshot
  shortcut), window brightness, MediaStore screenshot saving, sharing.
- `manual/` — the Android manifest and resources used by the manual
  packaging route below (package `com.example.pdfreader`, minSdk 26,
  targetSdk 34).

## How it works

Pages are rendered by Android's native `PdfRenderer`, not by a Flutter
plugin, and shown from cached JPEGs. Dart has no third-party plugin
dependencies (`flutter` SDK only in `pubspec.yaml`), which is why the app
can be packaged without Gradle resolving plugins.

## Building

Standard route, if your Gradle setup works:

```sh
flutter pub get
flutter build apk --release
```

Manual route used for the delivered APKs (bypasses Gradle): see
`build-pdfreader-v222.sh` next to this folder. It runs `flutter assemble`
for arm64 + arm, compiles the Java host, links with `aapt2`, dexes with
`d8`, then `zipalign` + `apksigner`. Its locations are overridable with
environment variables instead of being hard-coded to one machine:

- `WORKSPACE` (default `~/workspace`) — project, Flutter install,
  toolchain jars and signing key all live under it.
- `JAVA_HOME` (default `~/jdk17`, used only if it contains `javac`),
  `FLUTTER_BIN` (default `$WORKSPACE/flutter/bin`),
  `ANDROID_SDK` (default `~/Android/Sdk`), `KEYSTORE` (default
  `$WORKSPACE/debug.keystore`).

The manual route still needs this machine's toolchain jars
(`flutter-proof/`, `m2/`) and the same signing key. A new signing key
means the app will NOT install over the existing one; keep the same
key if you want updates to keep the user's library and progress.

Version consistency: the version is `2.2.2+6` in `pubspec.yaml`,
`2.2.2` on the About page and in the Settings subtitle, and `v2.2.2`
in this README. The package (`com.example.pdfreader`), minSdk 26,
targetSdk 34 and signing configuration are unchanged.

Persistence note: `library.json` is written atomically (temp file +
rename) and saves are serialized, so a crash mid-write or two
overlapping saves cannot truncate the library or lose an update.
