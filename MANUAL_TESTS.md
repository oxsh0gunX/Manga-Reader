# PDF Reader — manual test procedures

These behaviours cannot be tested by `flutter test` because they live in
the Android host (`MainActivity.java`), the device window, or the
MediaStore. Run them on a real phone after installing a new build.
Tick each one off; anything that fails is a bug, not a "known issue".

## 1. Import, library, restart
- [ ] Import one PDF: it appears with name, page count, 0% progress.
- [ ] Import the same PDF again (same file, or a renamed copy of it):
      a "This PDF is already in your library" message appears, still
      one entry, and the existing document (with its progress) is
      untouched. The picked copy is deleted, not the original entry.
- [ ] Import a *different* PDF that happens to have the same filename:
      both entries appear (the check is by file content, not by name).
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

## 9. Tap navigation and vertical mode (v2.2.3)
- [ ] Horizontal mode: tap the right third of the page -> next page;
      tap the left third -> previous page; tap the centre -> the
      controls show or hide, as before.
- [ ] First page: a left tap does nothing (no crash, no document
      switch). Last page: a right tap does nothing (the Next Document
      button / volume key still switch documents, taps never do).
- [ ] Tap navigation is off in panel/frame modes and in the text view:
      there, a tap only shows or hides the controls.
- [ ] Long-press still zooms into the pressed area, and pinch zoom
      still works after tapping; a tap never turns a page while zoomed
      out or in.
- [ ] Reading style -> Vertical scrolling: pages flow down in one
      continuous scroll; scrolling through many pages updates the
      saved page. Switch back to Horizontal: you land on the same
      page you were reading, not page 1.
- [ ] Reading style sheet on a short screen (e.g. landscape): the
      sheet scrolls instead of overflowing.

## 10. Comics & manga (v2.3.0)
- [ ] Import a real `.cbz` (ZIP of JPG/PNG pages): it appears in the
      library with its page count; pages open in order, including
      `page10` after `page2` (natural sort, also inside subfolders).
- [ ] Import a real `.cb7` (7z) and a `.cbt` (tar, and a `.tar.gz`):
      all three open and read the same way as the CBZ.
- [ ] Import a single image (JPG, PNG, WEBP, GIF) and a single BMP:
      each becomes a one-page book; the BMP reads (it is converted
      to JPEG on import).
- [ ] Import the same CBZ twice: the second import shows "already in
      your library" and no second card appears. Import a different
      comic with the same filename: it is added normally.
- [ ] Import a `.cbr`: the app refuses it with the RAR message
      (suggesting CBZ conversion) and does not add a card.
- [ ] Import a corrupt archive (truncated CBZ) and an archive with no
      images: each shows a clear message, adds no card, and leaves
      no half-extracted folder behind.
- [ ] Import a password-protected ZIP if you have one: it is refused
      with the password message (there is no password prompt).
- [ ] Open a manga CBZ, tap the menu (⋮) -> "Read right to left
      (manga)": left tap now turns forward, right tap turns back,
      and the bottom-bar arrows swap. Volume Up still turns forward
      in reading order. Turn RTL off: LTR behaviour returns.
- [ ] In a comic: volume keys turn pages; at the last page Volume Up
      opens the next document, at the first page Volume Down opens
      the previous one; progress is remembered per book.
- [ ] Vertical scrolling mode works for a comic; switching between
      Horizontal and Vertical keeps the page.
- [ ] Panel/frame modes work on comic pages (panel detection is the
      same bordered-panel detector as for PDFs; borderless pages
      fall back to the grid).
- [ ] Brightness slider, screenshot shortcut, and the text-view
      button: brightness and screenshots work; the text-view button
      is hidden for comics (there is no text layer) and still
      present for PDFs.
- [ ] Delete a comic from the library: its extracted pages folder
      goes with it (check storage before/after — a comic uses about
      twice its archive size while it is in the library).
- [ ] Known quirk to confirm, not fix on the phone: in vertical mode
      a very short book (2–3 tall pages) may not register its last
      page as read when you scroll to the very bottom; page-by-page
      mode records it fine.

## 11. Multiple file selection (v2.3.1)

- [ ] Tap **Import files**. The SYSTEM Documents picker opens (NOT
      Mi File Explorer — if you see Mi Explorer's screen with the
      OK/Cancel buttons at the bottom, the fix did not take). Long-press
      the first file, then tap 4 more (a mix: 2 PDFs, 1 CBZ, 1 CB7,
      1 image), then the tick to confirm. The picker must let you
      select all 5 at once — if it only lets you pick one, the fix
      did not take.
- [ ] While they import, a dialog shows "Importing 2 of 5…" and counts
      up. When it finishes, the SnackBar says "Added 5 files to your
      library" and all 5 appear in the library, in the order picked.
- [ ] Pick 5 again with one corrupt file among them (e.g. a CBZ that
      is only half a file): the other 4 import, and the summary lists
      the broken one by name with its reason.
- [ ] Pick 5 with one file that is already in the library: it is
      reported as "Already in your library", the other 4 import.
- [ ] Pick just one file: it imports exactly as before, with the
      "Added to your library" message.
- [ ] Open the picker and press back without choosing: nothing
      happens, no message, no empty entry.

## 12. In-app file browser (v2.3.3)

v2.3.2's Documents-picker fix did not work on this phone: the video
the user sent shows Mi File Explorer opening in browse mode (tapping a
file asks "Open with"; long-press select has no usable confirm button)
and nothing comes back into the app. The in-app browser replaces the
system picker as the main import flow, so multi-select no longer
depends on MIUI's picker at all.

- [ ] Tap **Import files**: the first time, a screen explains why the
      app needs to see your files, with an **Allow access to all
      files** button. Tap it, turn the switch ON in the settings
      screen that opens, then come back — the file list appears
      without tapping anything else.
- [ ] The list starts at the phone's storage: folders first (tap one
      to go inside), then PDFs, comics and images in natural order.
      Open **Sbi wallet** and tick Ch-35, Ch-36, Ch-37 with the
      checkboxes on the right (tapping the whole row also toggles).
- [ ] **Select all** ticks every file in the folder; tapping it again
      unticks them.
- [ ] The bottom button reads **Import 3 selected** (or however many
      are ticked). Tap it: the progress dialog counts up, then the
      home list shows all 3 books. The originals are still in
      Sbi wallet — the app keeps its own copies.
- [ ] Tick 5 files including one that is already in the library and
      one broken file: the summary lists the duplicate and the broken
      one by name, the other 3 import.
- [ ] The three-dot menu in the browser has **Use system picker** —
      the old flow, kept as a fallback.
- [ ] Deny the permission (back out of the settings screen without
      turning it on): the browser stays on the explanation screen,
      no crash, and the button can be tried again.

## 13. Manga mode (v2.3.4)

A manga spread is one image running across two pages, so one page at
a time left-to-right splits it. Manga mode flows top to bottom.

- [ ] Open a manga (CBZ/CB7): tap the screen to show the controls,
      tap the **Reading style** button, pick **Manga mode** (top of
      the list). The pages now flow down: scroll and you see the end
      of one page and the start of the next at the same time.
- [ ] Find a two-page spread (one image across two pages): both
      pages show together on screen, one above the other, so the
      whole image is visible without turning a page.
- [ ] In the same style sheet, under Manga mode, pick **Single
      page**: now one page fills the screen; swipe up for the next
      page, down for the previous. Tap the bottom of the screen for
      the next page, the top for the previous, the middle for the
      controls.
- [ ] From the reader's three-dot menu, **Manga: one page at a
      time** flips between the strip and single page without leaving
      the reader.
- [ ] Volume Up / Down turn pages in both views. In the strip, the
      saved page must not jump back mid-turn (fixed in this version).
- [ ] Close the book and reopen it: Manga mode is remembered, and
      the book opens on the page you left.
- [ ] A PDF opened in Manga mode works the same way (strip and
      single page); the text view is still available for PDFs.

## 14. Manga mode improvements (v2.3.5)

### 14a. No gaps in the strip

- [ ] Open a manga in Manga mode (strip): the pages touch — the
      bottom of one page meets the top of the next with no black band
      between them, even where two pages have different sizes.
- [ ] A two-page spread reads as one continuous image.
- [ ] Open the same book in Vertical scrolling: the 8px gap between
      pages is still there (normal reading is unchanged).

### 14b. Smooth scrolling

- [ ] Scroll a long manga fast, up and down: no jumps, no flicker,
      no page suddenly changing size as its image loads.
- [ ] Volume Up / Down in the strip: the turn glides smoothly, and
      the saved page never jumps back mid-turn.
- [ ] While a volume-key turn is animating, grab the list and drag
      it: the drag wins at once, no fight, no crash, and the next
      volume press still turns exactly one page.

### 14c. Auto-scroll

- [ ] In Manga mode, open the three-dot menu → **Auto-scroll…**.
      The sheet shows the current speed and **Start**.
- [ ] Pick **1 second per page**, tap Start: the pages turn by
      themselves every second. The status bar at the bottom shows
      `Auto-scroll • 1s / page • Scrolling` with Pause and Stop.
- [ ] Try **2**, **3**, **5** and **10 seconds per page**: each turns
      at that speed. Pick **Custom…**, enter 7, Save: the sheet shows
      `Custom: 7 seconds per page`, and it is remembered the next
      time you open the sheet.
- [ ] While it is scrolling, tap **Pause**: the pages stop. Wait
      several seconds: nothing moves. Tap **Resume**: it starts again.
      Tap **Stop**: it stops and the status bar goes away.
- [ ] While it is scrolling, turn a page yourself (volume key or
      tap): the next automatic turn waits a full interval from your
      turn, it does not fire straight after it.
- [ ] Start auto-scroll, then press the Home button to send the app
      to the background, then come back: it is Paused, not scrolling.
      Tap Resume to start it again. It never starts by itself.
- [ ] Leave the reader (back to the library) while auto-scroll is
      running, then reopen the book: auto-scroll is off.

### 14d. Auto-next document

- [ ] Have two manga in the library. Open the first in Manga mode
      (strip): scroll to the very bottom of the last page and wait a
      moment — the second manga opens by itself, in Manga mode, from
      its first page. No popup, no button to tap.
- [ ] In Single page: on the last page, tap the bottom of the screen
      (or press Volume Up, or swipe down past the last page) — the
      next document opens the same way.
- [ ] With auto-scroll running, let it reach the end of the first
      book: it carries on into the next book and keeps scrolling.
- [ ] On the last book in the library, reach the end: nothing opens,
      no loop, no restart of the same book. Auto-scroll stops with
      `End of library — auto-scroll stopped`.
- [ ] Do the same in Vertical scrolling (not Manga mode): reaching
      the bottom does NOT open the next document.
