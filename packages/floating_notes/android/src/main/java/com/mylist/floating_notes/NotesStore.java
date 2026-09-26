package com.mylist.floating_notes;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * تخزين الملاحظات في SharedPreferences بصيغة JSON (بترتيب وقت الإضافة)، مع
 * إشعار المستمعين (الفقاعة و Dart) عند أي تغيير. كل الاستدعاءات على الخيط
 * الرئيسي.
 */
final class NotesStore {
  static final String TYPE_ADD = "add";
  static final String TYPE_EDIT = "edit";
  static final String TYPE_CANCEL = "cancel";
  static final String TYPE_DELIVER = "deliver";

  private static final String PREFS = "my_list_floating_notes";
  private static final String KEY_NOTES = "notes";
  private static final String KEY_X = "bubble_x";
  private static final String KEY_Y = "bubble_y";
  private static final String KEY_TYPE = "last_type";

  interface Listener {
    void onNotesChanged();
  }

  private static final List<Listener> listeners = new ArrayList<Listener>();
  private static final Handler main = new Handler(Looper.getMainLooper());

  private NotesStore() {}

  private static SharedPreferences prefs(Context c) {
    return c.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
  }

  static synchronized JSONArray load(Context c) {
    String raw = prefs(c).getString(KEY_NOTES, "[]");
    try {
      return new JSONArray(raw);
    } catch (JSONException e) {
      return new JSONArray();
    }
  }

  static synchronized String json(Context c) {
    return load(c).toString();
  }

  static synchronized int count(Context c) {
    return load(c).length();
  }

  /** يضيف ملاحظة في آخر القائمة ويعيد معرّفها (-1 إذا كان النص فارغًا). */
  static synchronized long add(Context c, String text, String type) {
    String t = text == null ? "" : text.trim();
    if (t.length() == 0) {
      return -1;
    }
    JSONArray arr = load(c);
    long now = System.currentTimeMillis();
    long id = now;
    for (int i = 0; i < arr.length(); i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o != null && o.optLong("id") >= id) {
        id = o.optLong("id") + 1;
      }
    }
    JSONObject note = new JSONObject();
    try {
      note.put("id", id);
      note.put("text", t);
      note.put("type", normalizeType(type));
      note.put("at", now);
    } catch (JSONException e) {
      return -1;
    }
    arr.put(note);
    save(c, arr);
    return id;
  }

  static synchronized boolean delete(Context c, long id) {
    JSONArray arr = load(c);
    JSONArray out = new JSONArray();
    boolean removed = false;
    for (int i = 0; i < arr.length(); i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null) {
        continue;
      }
      if (!removed && o.optLong("id") == id) {
        removed = true;
        continue;
      }
      out.put(o);
    }
    if (removed) {
      save(c, out);
    }
    return removed;
  }

  static synchronized void clear(Context c) {
    save(c, new JSONArray());
  }

  private static void save(Context c, JSONArray arr) {
    prefs(c).edit().putString(KEY_NOTES, arr.toString()).apply();
    notifyChanged();
  }

  static String normalizeType(String type) {
    if (TYPE_EDIT.equals(type) || TYPE_CANCEL.equals(type) || TYPE_DELIVER.equals(type)) {
      return type;
    }
    return TYPE_ADD;
  }

  static int[] loadPosition(Context c, int defX, int defY) {
    SharedPreferences p = prefs(c);
    return new int[] {p.getInt(KEY_X, defX), p.getInt(KEY_Y, defY)};
  }

  static void savePosition(Context c, int x, int y) {
    prefs(c).edit().putInt(KEY_X, x).putInt(KEY_Y, y).apply();
  }

  static String lastType(Context c) {
    return normalizeType(prefs(c).getString(KEY_TYPE, TYPE_ADD));
  }

  static void saveLastType(Context c, String type) {
    prefs(c).edit().putString(KEY_TYPE, normalizeType(type)).apply();
  }

  static void addListener(Listener l) {
    synchronized (listeners) {
      if (!listeners.contains(l)) {
        listeners.add(l);
      }
    }
  }

  static void removeListener(Listener l) {
    synchronized (listeners) {
      listeners.remove(l);
    }
  }

  static void notifyChanged() {
    final List<Listener> copy;
    synchronized (listeners) {
      copy = new ArrayList<Listener>(listeners);
    }
    main.post(
        new Runnable() {
          @Override
          public void run() {
            for (int i = 0; i < copy.size(); i++) {
              ((Listener) copy.get(i)).onNotesChanged();
            }
          }
        });
  }
}
