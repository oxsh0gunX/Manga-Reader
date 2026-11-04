# PDF Reader — manual test procedures

These behaviours cannot be tested by `flutter test` because they live in
the Android host (`MainActivity.java`), the device window, or the
MediaStore. Run them on a real phone after installing a new build.
Tick each one off; anything that fails is a bug, not a "known issue".

## 1. Import, library, restart
- [ ] Import one PDF: it appears with name, page count, 0% progress.
- [ ] Import the same file again: a second entry appears (no overwrite).
- [ ] Import a renamed non-PDF (e.g. a `.txt` renamed to `.pdf`): import
      fails with a message, no broken entry stays in the library.
- [ ] Open a PDF, turn 5 pages, close the app completely, reopen: the
      library still lists the PDF and resumes on the page you left.
- [ ] Reorder the reading sequence, close the app completely, reopen:
      the order is unchanged. Open the first document and use Next
      Document at its last page: the next document in your order opens.

## 2. Missing / damaged files
- [ ] In the library, a document whose file is gone shows
      "File not found on this phone"; tapping it offers Remove, not a
      reader full of errors. (This path is hard to trigger by hand
      because imported copies live in the app's private files; it is
      covered by code review and by the string check on the built APK.)
- [ ] A document with a corrupted library entry (one bad record in
      `library.json`) must not wipe the rest of the library on restart.

## 3. Page and panel navigation bounds
- [ ] First page: Previous does nothing harmful; volume Down on the
      first page of the first document does nothing harmful.
- [ ] Last page: Next opens the next document; on the last document it
      shows the end state, never a blank or crashed page.
- [ ] Panel mode: volume Up walks panels in order, volume Down walks
      back; leaving the first panel goes to the previous page's last
      panel, leaving the last panel goes to the next page.
- [ ] A document with 0 pages (only reachable from a corrupted library
      file) opens to a "no pages" state instead of crashing.

## 4. Panel editing and detection
- [ ] Open a bordered comic page in panel mode: detected panels follow
      the borders; if detection finds nothing, the grid layout shows
      instead (never a claim that detection worked).
- [ ] Open a borderless / full-bleed page: the grid fallback shows.
- [ ] Edit panels for a page: move, resize (corner drag + sliders),
      add, delete (never below 1 panel), reorder with the arrows.
      Save, leave, reopen: the layout is exactly as saved.
- [ ] Reset to automatic clears the saved layout for that page only.
- [ ] Make a panel full-width (width slider to maximum), then move the
      Left slider: no crash, no blank slider (it shows disabled).
- [ ] Close the app completely and reopen the same page: the saved
      layout is still there (layouts survive app updates too, because
      the package and signing key are unchanged).

## 5. Volume keys
- [ ] Volume Up = next page/panel, Volume Down = previous, single
      presses only (holding a key does not repeat turns).
- [ ] Volume Up + Down together (within a moment) = screenshot, with
      no page turn. Two quick presses of the same key = two turns.
- [ ] With the screenshot shortcut off in Settings, Up+Down together
      turns pages instead of screenshotting.
- [ ] With volume navigation off in Settings, the keys change the
      system volume normally.
- [ ] Volume Up on the last page of a document opens the next document
      in your reading order, on that document's saved page — not on
      page 1. Volume Down on the first page opens the previous
      document, also on its saved page.
- [ ] Volume Up on the last page of the last document, and Volume Down
      on the first page of the first document, stay put (no jump, no
      crash). The Prev doc / Next doc buttons still work as before.
- [ ] Press Volume Up, then immediately switch to another app: no
      page turn or screenshot fires while the app is in the background.
- [ ] Leave the reader: volume keys work normally again at once.

## 6. Screenshots and brightness
- [ ] Toolbar screenshot button: a "Screenshot saved to Pictures /
      PDF Reader" message appears, and the image is in
      Pictures / PDF Reader in the gallery, with a Share action.
- [ ] Volume Up + Down screenshot: same result, no page turn.
- [ ] Brightness slider changes only the reader (home screen and other
      apps keep their brightness). Reset returns to system brightness.
- [ ] Leave the reader (back button, document switch, or closing the
      app): the original brightness is restored every time, including
      after using Reset inside the reader.

## 7. Large PDFs and performance
- [ ] Open a 200+ page PDF: pages swipe smoothly, opening does not
      freeze the UI, and switching documents stays responsive.
- [ ] Read through many pages of a long book: storage used by cached
      page images stays bounded (oldest renders are re-created on
      demand, not kept forever).
- [ ] Airplane mode: every feature above works; nothing in the app
      needs the network (verified in code: no network calls anywhere).

## 8. Themes and settings
- [ ] Day / Dark / System themes apply across library, reader and
      Settings, and survive an app restart.
- [ ] Text settings (size, colour, font, spacing, line height) change
      only the extracted-text view, never the PDF page image.
- [ ] A scanned PDF with no text layer reports "no text" instead of
      showing junk in the text view.
