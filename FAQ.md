# Manga Reader — FAQ

Short answers to the questions that come up most. Longer detail lives in the README and in Discussions Q&A.

## Import

**Which files can I import?**
PDFs, CBZ/ZIP, CBT/TAR (including .tar.gz / .tgz / .tar.bz2 / .tar.xz), CB7/7Z, and single images (JPG, PNG, WEBP, GIF, BMP converted to JPEG).

**Why was my file refused?**
CBR/RAR is not supported — convert it to CBZ on a computer first. Encrypted archives are refused, and 7z files using PPMd compression are refused too.

**The system file picker returns nothing on my phone. What do I do?**
Use the in-app file browser (Import files). It needs All files access once. Tick several files and tap Import. The system picker is kept as a fallback in the browser menu.

## Reading

**A manga image runs across two pages. How do I read it as one image?**
Use Manga mode: Reading style → Manga mode. Strip (the default) scrolls vertically so both pages of a spread show together. Single page shows one page at a time.

**How do I turn pages?**
In horizontal page mode, tap left third for previous, right third for next, centre to toggle controls. In vertical modes, scroll. Volume keys also turn pages.

**The last page of a short book is not marked as read. Why?**
In vertical mode the scroll tracker watches a point 60 px below the top of the screen, and a short book cannot scroll far enough for that point to pass the last page. Page-by-page mode, volume keys, and mode switching still record the page correctly.

## Storage

**Why does a comic use twice its size on disk?**
Comic pages are extracted next to the archive copy until you delete the book. Deleting the book removes its extracted pages too.

## Questions?

Ask in [Discussions](https://github.com/oxsh0gunX/Manga-Reader/discussions) — Q&A category.
