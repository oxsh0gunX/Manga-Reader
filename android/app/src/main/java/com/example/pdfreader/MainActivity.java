package com.example.pdfreader;

import android.app.Activity;
import android.content.ClipData;
import android.content.ContentValues;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.provider.Settings;
import android.view.KeyEvent;
import android.view.WindowManager;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import org.apache.commons.compress.archivers.sevenz.SevenZArchiveEntry;
import org.apache.commons.compress.archivers.sevenz.SevenZFile;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * PDF Reader host (Phase 1 MVP, plugin-free Dart).
 * Native duties only: SAF file picking (copied into filesDir/pdfs),
 * PdfRenderer page rendering to JPEG cache files, volume-key interception,
 * window brightness, MediaStore screenshot saving, text sharing, 7z
 * extraction (Commons Compress SevenZFile) and image size / BMP
 * conversion (BitmapFactory) for comic pages. All UI, state, ordering
 * and progress live in Dart.
 */
public class MainActivity extends FlutterActivity {
    private static final int PICK_FILE = 201;
    private MethodChannel nativeChannel;
    private MethodChannel eventsChannel;
    private MethodChannel.Result pendingPick;
    private boolean volumeEnabled = false;
    private boolean screenshotShortcutEnabled = true;
    // Volume-key buffering for the screenshot shortcut: a lone volume key
    // is held for 180ms so a second, different volume key arriving in that
    // window can turn the pair into a screenshot instead of a page turn.
    private final Handler volumeHandler = new Handler(Looper.getMainLooper());
    private Runnable pendingVolumeRunnable = null;
    private String pendingVolumeMethod = null;
    private float originalBrightness = -1f;
    private boolean brightnessSaved = false;
    // Heavy native work (PdfRenderer counting/rendering, panel pixel
    // scanning) runs here, not on the UI thread, so opening a large PDF
    // or a dense comic page cannot freeze the reader. One thread keeps
    // PdfRenderer instances serialized; results are posted back to the
    // main thread because MethodChannel results belong there.
    private final ExecutorService pdfWorker = Executors.newSingleThreadExecutor();

    private void runPdfTask(Callable<Object> task, MethodChannel.Result result) {
        pdfWorker.execute(() -> {
            try {
                Object value = task.call();
                volumeHandler.post(() -> result.success(value));
            } catch (Exception e) {
                volumeHandler.post(() -> result.error("PDF_ERROR", e.getMessage(), null));
            }
        });
    }

    @Override
    protected void onPause() {
        super.onPause();
        // The reader is not active while backgrounded: drop a volume
        // press still inside the 180ms screenshot window instead of
        // letting it turn a page (or screenshot) behind another app.
        if (pendingVolumeRunnable != null) {
            volumeHandler.removeCallbacks(pendingVolumeRunnable);
            pendingVolumeRunnable = null;
            pendingVolumeMethod = null;
        }
    }

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        eventsChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "pdfreader/events");
        nativeChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "pdfreader/native");
        nativeChannel.setMethodCallHandler(new MethodChannel.MethodCallHandler() {
            @Override
            public void onMethodCall(MethodCall call, MethodChannel.Result result) {
                try {
                    switch (call.method) {
                        case "getFilesDir":
                            result.success(getFilesDir().getAbsolutePath());
                            break;
                        case "getCacheDir":
                            result.success(getCacheDir().getAbsolutePath());
                            break;
                        case "isAllFilesAccess":
                            // "All files access" (MANAGE_EXTERNAL_STORAGE,
                            // Android 11+). The in-app browser needs it
                            // to list the shared storage itself, because
                            // the system picker on this phone will not
                            // return multi-select picks.
                            result.success(
                                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                                            && Environment.isExternalStorageManager());
                            break;
                        case "openAllFilesAccessSettings":
                            // Opens the system screen where the user
                            // turns on "Allow access to all files" for
                            // this app. Nothing is granted here — the
                            // user flips the switch themself.
                            Intent settingsIntent = new Intent(
                                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                            settingsIntent.setData(
                                    Uri.parse("package:" + getPackageName()));
                            startActivity(settingsIntent);
                            result.success(null);
                            break;
                        case "pickFiles": {
                            pendingPick = result;
                            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                            // Several files per pick: PDFs, comic archives
                            // or single images, in one picker session.
                            // EXTRA_ALLOW_MULTIPLE is what makes the
                            // picker offer multi-select (long-press /
                            // tap several files); without it Android
                            // only ever returns one file. The MIME list
                            // is a hint for the picker UI only — Dart
                            // validates each file by extension + magic
                            // bytes after it is copied.
                            intent.setType("*/*");
                            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                            intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{
                                    "application/pdf",
                                    "application/zip",
                                    "application/x-zip-compressed",
                                    "application/x-7z-compressed",
                                    "application/x-tar",
                                    "application/tar",
                                    "application/x-rar-compressed",
                                    "application/vnd.rar",
                                    "image/jpeg",
                                    "image/png",
                                    "image/webp",
                                    "image/gif",
                                    "image/bmp"
                            });
                            intent.addCategory(Intent.CATEGORY_OPENABLE);
                            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                            // Open the SYSTEM Documents picker directly,
                            // not through a chooser: on MIUI the chooser
                            // hands the pick to Mi File Explorer, whose
                            // multi-select does not stick — tapping a
                            // second file drops the first, so only one
                            // file ever comes back. DocumentsUI does
                            // real multi-select (long-press the first
                            // file, tap the rest, then the tick) and
                            // returns them all in ClipData. If
                            // DocumentsUI is missing on some device,
                            // fall back to the plain intent.
                            try {
                                intent.setPackage("com.android.documentsui");
                                startActivityForResult(intent, PICK_FILE);
                            } catch (Exception e) {
                                intent.setPackage(null);
                                startActivityForResult(intent, PICK_FILE);
                            }
                            break;
                        }
                        case "extractSevenZ": {
                            String path = call.argument("path");
                            String destDir = call.argument("destDir");
                            runPdfTask(() -> extractSevenZ(path, destDir), result);
                            break;
                        }
                        case "imageSize": {
                            String path = call.argument("path");
                            runPdfTask(() -> imageSize(path), result);
                            break;
                        }
                        case "convertToJpeg": {
                            String path = call.argument("path");
                            String destPath = call.argument("destPath");
                            runPdfTask(() -> convertToJpeg(path, destPath), result);
                            break;
                        }
                        case "getPageCount": {
                            String path = call.argument("path");
                            runPdfTask(() -> pageCount(path), result);
                            break;
                        }
                        case "renderPage": {
                            String path = call.argument("path");
                            int page = call.argument("page");
                            int width = call.argument("width");
                            String docId = call.argument("docId");
                            runPdfTask(() -> renderPage(path, page, width, docId), result);
                            break;
                        }
                        case "setVolumeEnabled":
                            volumeEnabled = Boolean.TRUE.equals(call.argument("enabled"));
                            if (!volumeEnabled && pendingVolumeRunnable != null) {
                                // Reader left while a press was still inside
                                // the 180ms screenshot window: drop it so no
                                // stray page turn fires after exit.
                                volumeHandler.removeCallbacks(pendingVolumeRunnable);
                                pendingVolumeRunnable = null;
                                pendingVolumeMethod = null;
                            }
                            result.success(null);
                            break;
                        case "setScreenshotShortcutEnabled":
                            screenshotShortcutEnabled = Boolean.TRUE.equals(call.argument("enabled"));
                            result.success(null);
                            break;
                        case "beginBrightness": {
                            if (!brightnessSaved) {
                                originalBrightness = getWindow().getAttributes().screenBrightness;
                                brightnessSaved = true;
                            }
                            result.success(currentBrightness());
                            break;
                        }
                        case "setBrightness": {
                            Double v = call.argument("value");
                            WindowManager.LayoutParams lp = getWindow().getAttributes();
                            lp.screenBrightness = (v == null || v < 0) ? -1f : v.floatValue();
                            getWindow().setAttributes(lp);
                            result.success(null);
                            break;
                        }
                        case "restoreBrightness": {
                            if (brightnessSaved) {
                                WindowManager.LayoutParams lp = getWindow().getAttributes();
                                lp.screenBrightness = originalBrightness;
                                getWindow().setAttributes(lp);
                                brightnessSaved = false;
                            }
                            result.success(null);
                            break;
                        }
                        case "saveScreenshot": {
                            String path = call.argument("path");
                            String name = call.argument("name");
                            result.success(saveToGallery(path, name));
                            break;
                        }
                        case "detectPanels": {
                            String path = call.argument("path");
                            runPdfTask(() -> detectPanels(path), result);
                            break;
                        }
                        case "mailto": {
                            String email = call.argument("email");
                            try {
                                try {
                                    startActivity(new Intent(Intent.ACTION_SENDTO,
                                            Uri.parse("mailto:" + email)));
                                } catch (android.content.ActivityNotFoundException e) {
                                    Intent web = new Intent(Intent.ACTION_VIEW,
                                            Uri.parse("https://mail.google.com/mail/?view=cm&to="
                                                    + Uri.encode(email)));
                                    web.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                                    startActivity(web);
                                }
                                result.success(null);
                            } catch (Exception e) {
                                result.error("MAILTO_FAILED", e.getMessage(), null);
                            }
                            break;
                        }
                        case "openUrl": {
                            String url = call.argument("url");
                            try {
                                Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                                startActivity(intent);
                                result.success(null);
                            } catch (Exception e) {
                                result.error("OPEN_URL_FAILED", e.getMessage(), null);
                            }
                            break;
                        }
                        case "shareImage": {
                            String uri = call.argument("uri");
                            Intent send = new Intent(Intent.ACTION_SEND);
                            send.setType("image/png");
                            send.putExtra(Intent.EXTRA_STREAM, Uri.parse(uri));
                            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                            startActivity(Intent.createChooser(send, "Share screenshot"));
                            result.success(null);
                            break;
                        }
                        case "shareText": {
                            String text = call.argument("text");
                            Intent send = new Intent(Intent.ACTION_SEND);
                            send.setType("text/plain");
                            send.putExtra(Intent.EXTRA_TEXT, text);
                            startActivity(Intent.createChooser(send, "Share text"));
                            result.success(null);
                            break;
                        }
                        default:
                            result.notImplemented();
                            break;
                    }
                } catch (Exception e) {
                    result.error("NATIVE_FAILED", e.getMessage(), null);
                }
            }
        });
    }

    private void scheduleVolume(String method) {
        final String m = method;
        pendingVolumeMethod = m;
        pendingVolumeRunnable = new Runnable() {
            @Override
            public void run() {
                pendingVolumeRunnable = null;
                if (eventsChannel != null) eventsChannel.invokeMethod(m, null);
            }
        };
        volumeHandler.postDelayed(pendingVolumeRunnable, 180);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (volumeEnabled && eventsChannel != null
                && (event.getKeyCode() == KeyEvent.KEYCODE_VOLUME_UP
                || event.getKeyCode() == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            // Consume both down and up so the system volume never changes
            // while the reader has volume navigation on.
            if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
                String method = event.getKeyCode() == KeyEvent.KEYCODE_VOLUME_UP
                        ? "volumeUp" : "volumeDown";
                if (screenshotShortcutEnabled) {
                    if (pendingVolumeRunnable != null) {
                        String first = pendingVolumeMethod;
                        volumeHandler.removeCallbacks(pendingVolumeRunnable);
                        pendingVolumeRunnable = null;
                        if (!first.equals(method)) {
                            // Up + Down together: screenshot, no page turn.
                            eventsChannel.invokeMethod("screenshotShortcut", null);
                        } else {
                            // Same key twice: flush the first turn, queue this one.
                            eventsChannel.invokeMethod(first, null);
                            scheduleVolume(method);
                        }
                    } else {
                        scheduleVolume(method);
                    }
                } else {
                    eventsChannel.invokeMethod(method, null);
                }
            }
            return true;
        }
        return super.dispatchKeyEvent(event);
    }

    private float currentBrightness() {
        float w = getWindow().getAttributes().screenBrightness;
        if (w >= 0) return w;
        try {
            int sys = Settings.System.getInt(
                    getContentResolver(), Settings.System.SCREEN_BRIGHTNESS);
            return Math.max(0.05f, Math.min(1f, sys / 255f));
        } catch (Exception e) {
            return 0.7f;
        }
    }

    private int pageCount(String path) throws Exception {
        File f = new File(path);
        if (!f.exists()) throw new Exception("File not found");
        ParcelFileDescriptor fd = null;
        PdfRenderer renderer = null;
        try {
            fd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
            renderer = new PdfRenderer(fd);
            return renderer.getPageCount();
        } finally {
            // A corrupt file throws inside the PdfRenderer constructor;
            // without this the fd leaked on every failed import.
            if (renderer != null) {
                try { renderer.close(); } catch (Exception ignored) {}
            }
            if (fd != null) {
                try { fd.close(); } catch (Exception ignored) {}
            }
        }
    }

    private Map<String, Object> renderPage(String path, int page, int width, String docId)
            throws Exception {
        File f = new File(path);
        if (!f.exists()) throw new Exception("File not found");
        File dir = new File(getCacheDir(), "pdf_pages");
        if (!dir.exists()) dir.mkdirs();
        String safeId = docId.replaceAll("[^A-Za-z0-9_-]", "_");
        File out = new File(dir, safeId + "_" + page + "_" + width + ".jpg");
        if (!out.exists()) {
            ParcelFileDescriptor fd = null;
            PdfRenderer renderer = null;
            PdfRenderer.Page p = null;
            Bitmap bitmap = null;
            FileOutputStream os = null;
            try {
                fd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
                renderer = new PdfRenderer(fd);
                if (page < 0 || page >= renderer.getPageCount()) {
                    throw new Exception("Page out of range");
                }
                p = renderer.openPage(page);
                int w = width > 0 ? width : 1080;
                if (p.getWidth() <= 0 || p.getHeight() <= 0) {
                    throw new Exception("Invalid page size");
                }
                int h = Math.round(w * (float) p.getHeight() / (float) p.getWidth());
                bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                p.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                os = new FileOutputStream(out);
                bitmap.compress(Bitmap.CompressFormat.JPEG, 88, os);
                os.close();
                os = null;
                bitmap.recycle();
                bitmap = null;
                prunePageCache(dir);
            } catch (Exception e) {
                // Never cache a half-written JPEG: the next open would
                // find out.exists() true and return the broken file.
                if (out.exists()) out.delete();
                throw e;
            } finally {
                if (os != null) {
                    try { os.close(); } catch (Exception ignored) {}
                }
                if (bitmap != null) bitmap.recycle();
                if (p != null) {
                    try { p.close(); } catch (Exception ignored) {}
                }
                if (renderer != null) {
                    try { renderer.close(); } catch (Exception ignored) {}
                }
                if (fd != null) {
                    try { fd.close(); } catch (Exception ignored) {}
                }
            }
        }
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(out.getAbsolutePath(), opts);
        Map<String, Object> m = new HashMap<>();
        m.put("path", out.getAbsolutePath());
        m.put("width", opts.outWidth);
        m.put("height", opts.outHeight);
        return m;
    }

    // Keep the newest 120 rendered pages; older ones are re-rendered on
    // demand (deterministic filenames), so a long book can never fill
    // storage with cached page images. Never throws: pruning must not
    // break rendering.
    private void prunePageCache(File dir) {
        try {
            File[] files = dir.listFiles();
            if (files == null || files.length <= 120) return;
            java.util.Arrays.sort(files, new java.util.Comparator<File>() {
                @Override
                public int compare(File a, File b) {
                    return Long.compare(a.lastModified(), b.lastModified());
                }
            });
            for (int i = 0; i < files.length - 120; i++) {
                files[i].delete();
            }
        } catch (Exception ignored) {
        }
    }

    // ---------- automatic panel detection (image-based, no OCR) ----------
    // Comics/manga separate panels with gutters: rows or columns that are
    // almost uniform (white gutter, black border, or blank space) have a
    // near-zero horizontal/vertical gradient, while rows through artwork
    // have a much higher gradient. The page is recursively split at the
    // largest such gutter band, which handles grid and irregular layouts
    // and different panel sizes without assuming a grid. A band only
    // counts as a gutter if it contains a mostly-dark row/column (a panel
    // border line): that is what stops blank sky/white areas inside a
    // panel from being mistaken for gutters. It is still a heuristic:
    // borderless / full-bleed panels have no border line to find, and a
    // tall panel beside stacked panels may be split at the neighbours'
    // gutter line, so those pages fall back to the grid layout or need
    // the manual editor in Dart. Returns fraction rects in Western
    // reading order (top-to-bottom, left-to-right within a row band), or
    // an empty list when fewer than 2 or more than 12 panels are found.
    private static final double GUTTER_GRADIENT = 4.0;

    private List<Map<String, Object>> detectPanels(String path) throws Exception {
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inPreferredConfig = Bitmap.Config.ARGB_8888;
        Bitmap decoded = BitmapFactory.decodeFile(path, opts);
        if (decoded == null) throw new Exception("Could not decode page image");
        int sw = 540;
        int sh = Math.round((float) decoded.getHeight() * 540 / decoded.getWidth());
        if (sh > 1600) {
            sh = 1600;
            sw = Math.round((float) decoded.getWidth() * 1600 / decoded.getHeight());
        }
        Bitmap bmp = Bitmap.createScaledBitmap(decoded, sw, sh, true);
        if (bmp != decoded) decoded.recycle();
        int W = bmp.getWidth();
        int H = bmp.getHeight();
        int[] px = new int[W * H];
        bmp.getPixels(px, 0, W, 0, 0, W, H);
        bmp.recycle();
        int[] gray = new int[W * H];
        for (int i = 0; i < px.length; i++) {
            int c = px[i];
            int r = (c >> 16) & 0xff;
            int g = (c >> 8) & 0xff;
            int b = c & 0xff;
            gray[i] = (r * 299 + g * 587 + b * 114) / 1000;
        }
        List<int[]> leaves = new ArrayList<>();
        splitRect(gray, W, H, 0, 0, W, H, 0, leaves);
        if (leaves.size() < 2 || leaves.size() > 12) return new ArrayList<>();
        // Western reading order: group by row (12% of page height tolerance),
        // then left-to-right inside each row.
        leaves.sort(new java.util.Comparator<int[]>() {
            @Override
            public int compare(int[] a, int[] b) {
                double cyA = (a[1] + a[3]) / 2.0;
                double cyB = (b[1] + b[3]) / 2.0;
                double tol = 0.12 * H;
                if (Math.abs(cyA - cyB) > tol) return Double.compare(cyA, cyB);
                double cxA = (a[0] + a[2]) / 2.0;
                double cxB = (b[0] + b[2]) / 2.0;
                return Double.compare(cxA, cxB);
            }
        });
        List<Map<String, Object>> out = new ArrayList<>();
        for (int[] r : leaves) {
            Map<String, Object> m = new HashMap<>();
            m.put("x", (double) r[0] / W);
            m.put("y", (double) r[1] / H);
            m.put("w", (double) (r[2] - r[0]) / W);
            m.put("h", (double) (r[3] - r[1]) / H);
            out.add(m);
        }
        return out;
    }

    // ---------- comic archives (7z) and image helpers ----------

    private static final java.util.Set<String> IMAGE_EXTS =
            new java.util.HashSet<>(java.util.Arrays.asList(
                    "jpg", "jpeg", "png", "webp", "gif", "bmp"));

    private static boolean isImageEntry(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        int dot = lower.lastIndexOf('.');
        if (dot < 0) return false;
        return IMAGE_EXTS.contains(lower.substring(dot + 1));
    }

    /**
     * Extracts the image pages of a 7z/CB7 archive into destDir.
     * Returns the written files' paths relative to destDir, in archive
     * order (Dart sorts them naturally and renames them). Only image
     * entries are written; directories and non-image files are skipped
     * without being read. A crafted entry name can never escape
     * destDir: every output path is checked against destDir's
     * canonical path. Runs on the pdfWorker thread.
     * Verified on the JVM against a real py7zr-made 7z (LZMA2, solid,
     * with subfolder + non-image entries): pages extract with correct
     * contents and CRCs. Throws IOException with a "7z: ..." message
     * for corrupt, encrypted, or unsupported-method archives — Dart
     * turns that into a plain-language message for the user.
     */
    private List<String> extractSevenZ(String path, String destDir) throws Exception {
        File dest = new File(destDir);
        if (!dest.exists()) dest.mkdirs();
        String canonDest = dest.getCanonicalPath();
        List<String> written = new ArrayList<>();
        SevenZFile in = null;
        try {
            in = new SevenZFile(new File(path));
            SevenZArchiveEntry entry;
            byte[] buf = new byte[8192];
            while ((entry = in.getNextEntry()) != null) {
                if (entry.isDirectory()) continue;
                String name = entry.getName();
                if (!isImageEntry(name)) continue;
                File out = new File(dest, name);
                String canonOut = out.getCanonicalPath();
                if (!canonOut.startsWith(canonDest + File.separator)) {
                    throw new java.io.IOException("7z: entry escapes the folder: " + name);
                }
                File parent = out.getParentFile();
                if (parent != null) parent.mkdirs();
                OutputStream os = null;
                try {
                    os = new FileOutputStream(out);
                    long remaining = entry.getSize();
                    while (remaining > 0) {
                        int n = in.read(buf, 0, (int) Math.min(buf.length, remaining));
                        if (n < 0) break;
                        os.write(buf, 0, n);
                        remaining -= n;
                    }
                } finally {
                    if (os != null) {
                        try { os.close(); } catch (Exception ignored) {}
                    }
                }
                written.add(name);
            }
        } catch (Exception e) {
            String m = e.getMessage() == null ? "" : e.getMessage();
            if (m.toLowerCase(Locale.ROOT).contains("password")) {
                throw new java.io.IOException(
                        "7z: this archive is password-protected");
            }
            if (m.startsWith("7z: ")) throw e;
            throw new java.io.IOException("7z: " + m);
        } finally {
            if (in != null) {
                try { in.close(); } catch (Exception ignored) {}
            }
        }
        return written;
    }

    /**
     * Width/height of an image file from its header only — the pixels
     * are never decoded, so this is cheap even for a big page. Null
     * when the file is not a readable image.
     */
    private Map<String, Object> imageSize(String path) {
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(path, opts);
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null;
        Map<String, Object> m = new HashMap<>();
        m.put("width", opts.outWidth);
        m.put("height", opts.outHeight);
        return m;
    }

    /**
     * Converts an image Flutter cannot decode (BMP) to a JPEG at
     * destPath. Files over 64MB are refused rather than decoded into
     * memory. Returns true on success.
     */
    private boolean convertToJpeg(String path, String destPath) throws Exception {
        File src = new File(path);
        if (!src.exists() || src.length() > 64L * 1024 * 1024) return false;
        Bitmap bmp = null;
        OutputStream os = null;
        try {
            bmp = BitmapFactory.decodeFile(path);
            if (bmp == null) return false;
            os = new FileOutputStream(destPath);
            return bmp.compress(Bitmap.CompressFormat.JPEG, 92, os);
        } finally {
            if (os != null) {
                try { os.close(); } catch (Exception ignored) {}
            }
            if (bmp != null) bmp.recycle();
        }
    }

    private void splitRect(int[] gray, int W, int H,
            int left, int top, int right, int bottom,
            int depth, List<int[]> leaves) {
        int rw = right - left;
        int rh = bottom - top;
        if (depth >= 4 || rw < (int) (0.08 * W) || rh < (int) (0.08 * H)) {
            leaves.add(new int[]{left, top, right, bottom});
            return;
        }
        int[] hBand = findGutterBandHorizontal(gray, W, H, left, top, right, bottom);
        if (hBand != null) {
            splitRect(gray, W, H, left, top, right, hBand[0], depth + 1, leaves);
            splitRect(gray, W, H, left, hBand[1], right, bottom, depth + 1, leaves);
            return;
        }
        int[] vBand = findGutterBandVertical(gray, W, H, left, top, right, bottom);
        if (vBand != null) {
            splitRect(gray, W, H, left, top, vBand[0], bottom, depth + 1, leaves);
            splitRect(gray, W, H, vBand[1], top, right, bottom, depth + 1, leaves);
            return;
        }
        leaves.add(new int[]{left, top, right, bottom});
    }

    private double darkFractionRow(int[] gray, int W, int y, int left, int right) {
        int dark = 0;
        for (int x = left; x < right; x++) {
            if (gray[y * W + x] < 100) dark++;
        }
        return right > left ? (double) dark / (right - left) : 0;
    }

    private double darkFractionCol(int[] gray, int W, int x, int top, int bottom) {
        int dark = 0;
        for (int y = top; y < bottom; y++) {
            if (gray[y * W + x] < 100) dark++;
        }
        return bottom > top ? (double) dark / (bottom - top) : 0;
    }

    // Returns {bandStart, bandEnd} (end exclusive) or null.
    private int[] findGutterBandHorizontal(int[] gray, int W, int H,
            int left, int top, int right, int bottom) {
        int minBand = Math.max(4, (int) (0.008 * H));
        int minEdge = (int) (0.05 * H);
        int bestStart = -1, bestEnd = -1, bestLen = 0, bestDist = Integer.MAX_VALUE;
        int center = (top + bottom) / 2;
        int runStart = -1;
        for (int y = top; y < bottom; y++) {
            double sum = 0;
            for (int x = left; x < right - 1; x++) {
                sum += Math.abs(gray[y * W + x + 1] - gray[y * W + x]);
            }
            double grad = (right - left > 1) ? sum / (right - left - 1) : 0;
            if (grad < GUTTER_GRADIENT) {
                if (runStart < 0) runStart = y;
            } else {
                if (runStart >= 0) {
                    int len = y - runStart;
                    if (len >= minBand && runStart - top >= minEdge
                            && bottom - y >= minEdge) {
                        // Border check: the band must contain a mostly-dark
                        // row (a panel border line). Interior blank areas
                        // inside a panel do not, so they are not gutters.
                        boolean hasBorder = false;
                        for (int by = runStart; by < y; by++) {
                            if (darkFractionRow(gray, W, by, left, right) >= 0.35) {
                                hasBorder = true;
                                break;
                            }
                        }
                        if (hasBorder) {
                            int mid = (runStart + y) / 2;
                            int dist = Math.abs(mid - center);
                            if (len > bestLen || (len == bestLen && dist < bestDist)) {
                                bestStart = runStart;
                                bestEnd = y;
                                bestLen = len;
                                bestDist = dist;
                            }
                        }
                    }
                    runStart = -1;
                }
            }
        }
        // A run reaching the bottom edge is a page margin, not a gutter,
        // so it is deliberately ignored here.
        return bestStart >= 0 ? new int[]{bestStart, bestEnd} : null;
    }

    private int[] findGutterBandVertical(int[] gray, int W, int H,
            int left, int top, int right, int bottom) {
        int minBand = Math.max(4, (int) (0.008 * W));
        int minEdge = (int) (0.05 * W);
        int bestStart = -1, bestEnd = -1, bestLen = 0, bestDist = Integer.MAX_VALUE;
        int center = (left + right) / 2;
        int runStart = -1;
        for (int x = left; x < right; x++) {
            double sum = 0;
            for (int y = top; y < bottom - 1; y++) {
                sum += Math.abs(gray[(y + 1) * W + x] - gray[y * W + x]);
            }
            double grad = (bottom - top > 1) ? sum / (bottom - top - 1) : 0;
            if (grad < GUTTER_GRADIENT) {
                if (runStart < 0) runStart = x;
            } else {
                if (runStart >= 0) {
                    int len = x - runStart;
                    if (len >= minBand && runStart - left >= minEdge
                            && right - x >= minEdge) {
                        boolean hasBorder = false;
                        for (int bx = runStart; bx < x; bx++) {
                            if (darkFractionCol(gray, W, bx, top, bottom) >= 0.35) {
                                hasBorder = true;
                                break;
                            }
                        }
                        if (hasBorder) {
                            int mid = (runStart + x) / 2;
                            int dist = Math.abs(mid - center);
                            if (len > bestLen || (len == bestLen && dist < bestDist)) {
                                bestStart = runStart;
                                bestEnd = x;
                                bestLen = len;
                                bestDist = dist;
                            }
                        }
                    }
                    runStart = -1;
                }
            }
        }
        return bestStart >= 0 ? new int[]{bestStart, bestEnd} : null;
    }

    private String saveToGallery(String path, String name) throws Exception {
        File src = new File(path);
        ContentValues values = new ContentValues();
        values.put(MediaStore.Images.Media.DISPLAY_NAME, name);
        values.put(MediaStore.Images.Media.MIME_TYPE, "image/png");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.put(MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/PDF Reader");
            values.put(MediaStore.Images.Media.IS_PENDING, 1);
        }
        Uri uri = getContentResolver().insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
        if (uri == null) throw new Exception("Could not create gallery entry");
        OutputStream os = null;
        InputStream in = null;
        try {
            os = getContentResolver().openOutputStream(uri);
            if (os == null) throw new Exception("Could not open gallery entry");
            in = new FileInputStream(src);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) os.write(buf, 0, n);
        } catch (Exception e) {
            // Otherwise the entry stays IS_PENDING forever: invisible in
            // the gallery, but occupying a MediaStore row.
            try { getContentResolver().delete(uri, null, null); } catch (Exception ignored) {}
            throw e;
        } finally {
            if (os != null) {
                try { os.close(); } catch (Exception ignored) {}
            }
            if (in != null) {
                try { in.close(); } catch (Exception ignored) {}
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContentValues done = new ContentValues();
            done.put(MediaStore.Images.Media.IS_PENDING, 0);
            getContentResolver().update(uri, done, null, null);
        }
        return uri.toString();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == PICK_FILE && pendingPick != null) {
            MethodChannel.Result r = pendingPick;
            pendingPick = null;
            // The whole picked set, in picker order. A cancelled pick
            // is an empty list (Dart treats it as "nothing chosen").
            // One Uri failing to copy must not lose the rest: each
            // result is either {name, path, size} or {name, error},
            // and Dart reports the failures in its import summary.
            List<Map<String, Object>> results = new ArrayList<>();
            if (resultCode == Activity.RESULT_OK && data != null) {
                List<Uri> uris = new ArrayList<>();
                ClipData clip = data.getClipData();
                if (clip != null) {
                    for (int i = 0; i < clip.getItemCount(); i++) {
                        Uri u = clip.getItemAt(i).getUri();
                        if (u != null) uris.add(u);
                    }
                } else if (data.getData() != null) {
                    // One file chosen: the picker returns it as the
                    // intent's data Uri, with no ClipData.
                    uris.add(data.getData());
                }
                for (Uri uri : uris) {
                    results.add(copyPickedUri(uri));
                }
            }
            r.success(results);
        }
    }

    /// Copies one picked document into filesDir/pdfs (unique name, so
    /// two picked files with the same name never clobber each other)
    /// and returns {name, path, size}. On failure returns
    /// {name, error} instead — the caller keeps the other files.
    private Map<String, Object> copyPickedUri(Uri uri) {
        String displayName = "document";
        long size = 0;
        Cursor c = null;
        try {
            c = getContentResolver().query(uri, null, null, null, null);
            if (c != null && c.moveToFirst()) {
                int ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (ni >= 0) displayName = c.getString(ni);
                int si = c.getColumnIndex(OpenableColumns.SIZE);
                if (si >= 0 && !c.isNull(si)) size = c.getLong(si);
            }
        } catch (Exception ignored) {
        } finally {
            if (c != null) c.close();
        }
        if (displayName == null || displayName.isEmpty()) displayName = "document";
        Map<String, Object> m = new HashMap<>();
        m.put("name", displayName);
        try {
            File dir = new File(getFilesDir(), "pdfs");
            if (!dir.exists()) dir.mkdirs();
            String safe = displayName.replaceAll("[^A-Za-z0-9._ -]", "_");
            File dest = uniqueFile(dir, safe);
            InputStream in = null;
            FileOutputStream os = null;
            long total = 0;
            try {
                in = getContentResolver().openInputStream(uri);
                if (in == null) throw new Exception("Could not open file");
                os = new FileOutputStream(dest);
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) != -1) {
                    os.write(buf, 0, n);
                    total += n;
                }
            } catch (Exception e) {
                // Dart never sees the path on this branch, so it
                // cannot clean up: delete the partial copy here.
                if (dest.exists()) dest.delete();
                throw e;
            } finally {
                if (os != null) {
                    try { os.close(); } catch (Exception ignored) {}
                }
                if (in != null) {
                    try { in.close(); } catch (Exception ignored) {}
                }
            }
            m.put("path", dest.getAbsolutePath());
            m.put("size", size > 0 ? size : total);
        } catch (Exception e) {
            m.put("error", e.getMessage() != null
                    ? e.getMessage()
                    : "Could not copy this file.");
        }
        return m;
    }

    private File uniqueFile(File dir, String name) {
        File f = new File(dir, name);
        if (!f.exists()) return f;
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        int i = 2;
        while (true) {
            File cand = new File(dir, base + " (" + i + ")" + ext);
            if (!cand.exists()) return cand;
            i++;
        }
    }
}
