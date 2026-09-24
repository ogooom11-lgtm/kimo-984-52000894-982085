package com.mylist.share_intake;

import android.app.Activity;
import android.content.ClipData;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.Parcelable;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;

import java.io.Closeable;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * نشاط شفاف يستقبل ما يشاركه المستخدم (ملفات Excel / CSV / نص):
 * ينسخ الملفات إلى مجلد الكاش في خيط خلفي، يضعها في {@link ShareIntakeStore}،
 * ثم يفتح التطبيق (أو يعيده للواجهة إن كان مفتوحًا) وينتهي.
 */
public class ShareIntakeActivity extends Activity {

  private static final long MAX_BYTES = 30L * 1024L * 1024L;
  private static final int MAX_FILES = 10;
  private static final long MAX_AGE_MS = 24L * 60L * 60L * 1000L;
  private static final String CACHE_DIR = "share_intake";

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    final Intent intent = getIntent();
    if (savedInstanceState != null || intent == null) {
      openApp();
      finish();
      return;
    }
    final Context appContext = getApplicationContext();
    final ContentResolver resolver = getContentResolver();
    Thread worker =
        new Thread(
            new Runnable() {
              @Override
              public void run() {
                Map<String, Object> payload;
                try {
                  payload = readIntent(appContext, resolver, intent);
                } catch (Throwable error) {
                  payload = errorPayload(intent, String.valueOf(error.getMessage()));
                }
                final Map<String, Object> result = payload;
                runOnUiThread(
                    new Runnable() {
                      @Override
                      public void run() {
                        if (result != null) {
                          ShareIntakeStore.add(result);
                        }
                        openApp();
                        finish();
                      }
                    });
              }
            },
            "share_intake");
    worker.start();
  }

  private void openApp() {
    try {
      Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
      if (launch == null) {
        return;
      }
      launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
      startActivity(launch);
    } catch (RuntimeException ignored) {
      // لا شيء: المشاركة محفوظة وسيأخذها التطبيق عند فتحه
    }
  }

  // ===================== قراءة الـ Intent =====================

  static Map<String, Object> readIntent(Context context, ContentResolver resolver, Intent intent) {
    String action = intent.getAction();
    List<Uri> uris = collectUris(intent, action);

    List<Map<String, Object>> files = new ArrayList<Map<String, Object>>();
    List<String> errors = new ArrayList<String>();
    if (!uris.isEmpty()) {
      File dir = new File(context.getCacheDir(), CACHE_DIR);
      if (!dir.exists() && !dir.mkdirs()) {
        errors.add("cache: mkdirs failed");
      }
      cleanup(dir);
      String privateDir = context.getApplicationInfo().dataDir;
      for (int i = 0; i < uris.size() && i < MAX_FILES; i++) {
        Uri uri = (Uri) uris.get(i);
        try {
          files.add(copyUri(resolver, uri, intent.getType(), dir, i, privateDir));
        } catch (Exception error) {
          String name = displayName(resolver, uri);
          errors.add((name == null ? String.valueOf(uri) : name) + ": " + error.getMessage());
        }
      }
    }

    String text = null;
    CharSequence extraText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
    if (extraText != null) {
      text = String.valueOf(extraText);
    }
    Map<String, Object> payload = new HashMap<String, Object>();
    payload.put("action", action == null ? "" : action);
    payload.put("files", files);
    payload.put("text", text);
    payload.put("subject", intent.getStringExtra(Intent.EXTRA_SUBJECT));
    payload.put("errors", errors);
    payload.put("time", Long.valueOf(System.currentTimeMillis()));
    return payload;
  }

  static Map<String, Object> errorPayload(Intent intent, String message) {
    List<String> errors = new ArrayList<String>();
    errors.add(message);
    Map<String, Object> payload = new HashMap<String, Object>();
    payload.put("action", intent.getAction() == null ? "" : intent.getAction());
    payload.put("files", new ArrayList<Map<String, Object>>());
    payload.put("text", null);
    payload.put("subject", null);
    payload.put("errors", errors);
    payload.put("time", Long.valueOf(System.currentTimeMillis()));
    return payload;
  }

  @SuppressWarnings("deprecation")
  static List<Uri> collectUris(Intent intent, String action) {
    List<Uri> uris = new ArrayList<Uri>();
    if (Intent.ACTION_SEND.equals(action)) {
      Parcelable stream = intent.getParcelableExtra(Intent.EXTRA_STREAM);
      if (stream instanceof Uri) {
        uris.add((Uri) stream);
      }
    } else if (Intent.ACTION_SEND_MULTIPLE.equals(action)) {
      ArrayList<Parcelable> list = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
      if (list != null) {
        for (Parcelable item : list) {
          if (item instanceof Uri) {
            uris.add((Uri) item);
          }
        }
      }
    } else if (Intent.ACTION_VIEW.equals(action)) {
      Uri data = intent.getData();
      if (data != null) {
        uris.add(data);
      }
    }
    if (uris.isEmpty()) {
      ClipData clip = intent.getClipData();
      if (clip != null) {
        for (int i = 0; i < clip.getItemCount(); i++) {
          Uri uri = clip.getItemAt(i).getUri();
          if (uri != null) {
            uris.add(uri);
          }
        }
      }
    }
    List<Uri> unique = new ArrayList<Uri>();
    for (Uri uri : uris) {
      if (!unique.contains(uri)) {
        unique.add(uri);
      }
    }
    return unique;
  }

  static Map<String, Object> copyUri(
      ContentResolver resolver,
      Uri uri,
      String intentType,
      File dir,
      int index,
      String privateDir)
      throws IOException {
    if (ContentResolver.SCHEME_FILE.equals(uri.getScheme())) {
      // لا نقبل مسارات تشير إلى ملفات التطبيق الخاصة
      String path = uri.getPath();
      if (path == null) {
        throw new IOException("cannot open");
      }
      String canonical = new File(path).getCanonicalPath();
      if (privateDir != null && canonical.startsWith(new File(privateDir).getCanonicalPath())) {
        throw new IOException("blocked");
      }
    }
    String mime = null;
    try {
      mime = resolver.getType(uri);
    } catch (RuntimeException ignored) {
      mime = null;
    }
    if (mime == null) {
      mime = intentType;
    }
    String name = displayName(resolver, uri);
    if (name == null || name.trim().length() == 0) {
      name = "shared_" + (index + 1) + extensionFor(mime);
    }
    File out = new File(dir, System.currentTimeMillis() + "_" + index + "_" + sanitize(name));

    InputStream in = null;
    OutputStream os = null;
    long total = 0;
    boolean ok = false;
    try {
      in = resolver.openInputStream(uri);
      if (in == null) {
        throw new IOException("cannot open");
      }
      os = new FileOutputStream(out);
      byte[] buffer = new byte[64 * 1024];
      int read;
      while ((read = in.read(buffer)) != -1) {
        total += read;
        if (total > MAX_BYTES) {
          throw new IOException("too_large");
        }
        os.write(buffer, 0, read);
      }
      os.flush();
      ok = true;
    } finally {
      closeQuietly(in);
      closeQuietly(os);
      if (!ok && out.exists() && !out.delete()) {
        out.deleteOnExit();
      }
    }

    Map<String, Object> file = new HashMap<String, Object>();
    file.put("path", out.getAbsolutePath());
    file.put("name", name);
    file.put("mimeType", mime);
    file.put("size", Long.valueOf(total));
    return file;
  }

  static String displayName(ContentResolver resolver, Uri uri) {
    String name = null;
    if (ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())) {
      Cursor cursor = null;
      try {
        cursor = resolver.query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null);
        if (cursor != null && cursor.moveToFirst()) {
          int column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
          if (column >= 0) {
            name = cursor.getString(column);
          }
        }
      } catch (RuntimeException ignored) {
        name = null;
      } finally {
        if (cursor != null) {
          cursor.close();
        }
      }
    }
    if (name == null) {
      String last = uri.getLastPathSegment();
      if (last != null) {
        int slash = last.lastIndexOf('/');
        name = slash >= 0 ? last.substring(slash + 1) : last;
      }
    }
    return name;
  }

  static String extensionFor(String mime) {
    if (mime == null) {
      return "";
    }
    String ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime);
    return ext == null ? "" : "." + ext;
  }

  static String sanitize(String name) {
    String safe = name.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_").trim();
    if (safe.length() == 0) {
      safe = "file";
    }
    if (safe.length() > 100) {
      int dot = safe.lastIndexOf('.');
      String ext = dot > 0 && safe.length() - dot <= 10 ? safe.substring(dot) : "";
      safe = safe.substring(0, 100 - ext.length()) + ext;
    }
    return safe;
  }

  static void cleanup(File dir) {
    File[] list = dir.listFiles();
    if (list == null) {
      return;
    }
    long cutoff = System.currentTimeMillis() - MAX_AGE_MS;
    for (File file : list) {
      if (file.isFile() && file.lastModified() < cutoff && !file.delete()) {
        file.deleteOnExit();
      }
    }
  }

  static void closeQuietly(Closeable closeable) {
    if (closeable == null) {
      return;
    }
    try {
      closeable.close();
    } catch (IOException ignored) {
      // تجاهل
    }
  }
}
