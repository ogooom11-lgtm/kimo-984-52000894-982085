package com.mylist.floating_notes;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

/**
 * تخزين الملاحظات (الحافظة) في SharedPreferences بصيغة JSON (بترتيب وقت
 * الإضافة) مع خيارات التخصيص، وإشعار المستمعين (الفقاعة و Dart) عند أي
 * تغيير. كل الاستدعاءات على الخيط الرئيسي.
 */
final class NotesStore {
  static final String TYPE_ADD = "add";
  static final String TYPE_EDIT = "edit";
  static final String TYPE_CANCEL = "cancel";
  static final String TYPE_DELIVER = "deliver";

  /** ترتيب الأنواع بالواجهة (من اليسار لليمين). */
  static final String[] ALL_TYPES = {TYPE_DELIVER, TYPE_CANCEL, TYPE_EDIT, TYPE_ADD};

  private static final String PREFS = "my_list_floating_notes";
  private static final String KEY_NOTES = "notes";
  private static final String KEY_X = "bubble_x";
  private static final String KEY_Y = "bubble_y";
  private static final String KEY_TYPE = "last_type";

  // ---- خيارات التخصيص (نفس الأسماء بـ Dart) ----
  static final String P_BUBBLE_SIZE = "bubbleSize"; // 0 صغير، 1 متوسط، 2 كبير
  static final String P_BUBBLE_COLOR = "bubbleColor"; // رقم لوحة الألوان
  static final String P_BUBBLE_ALPHA = "bubbleAlpha"; // 30..100 (%)
  static final String P_THEME = "theme"; // 0 تلقائي، 1 فاتح، 2 داكن
  static final String P_FONT = "fontSize"; // 0 صغير، 1 عادي، 2 كبير
  static final String P_PANEL_POS = "panelPosition"; // 0 فوق، 1 وسط، 2 تحت
  static final String P_LONG_PRESS = "longPress"; // 0 فتح ولصق، 1 إخفاء، 2 ولا شي
  static final String P_CLOSE_AFTER_COPY = "closeAfterCopy";
  static final String P_COPY_NUMBERS = "copyNumbers";
  static final String P_COPY_TYPES = "copyTypes";
  static final String P_SHOW_TIME = "showTime";
  static final String P_SNAP = "snapToEdge";
  static final String P_TITLE = "title";
  static final String P_HIDDEN_TYPES = "hiddenTypes"; // "edit,deliver"
  static final String P_LABEL_PREFIX = "label_"; // label_add ...

  static final int PALETTE_SIZE = 7;

  interface Listener {
    void onNotesChanged();

    void onPrefsChanged();
  }

  private static final List<Listener> listeners = new ArrayList<Listener>();
  private static final Handler main = new Handler(Looper.getMainLooper());

  /** سياق التطبيق (لتحديث زر لوحة الإشعارات عند أي تغيير). */
  private static volatile Context appContext;

  private NotesStore() {}

  private static SharedPreferences prefs(Context c) {
    Context app = c.getApplicationContext();
    if (appContext == null) {
      appContext = app;
    }
    return app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
  }

  static Context appContext() {
    return appContext;
  }

  // ===========================================================
  // الملاحظات
  // ===========================================================

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

  /** عدد الملاحظات يلي لسا ما انعلّمت «تم». */
  static synchronized int pendingCount(Context c) {
    JSONArray arr = load(c);
    int n = 0;
    for (int i = 0; i < arr.length(); i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o != null && !o.optBoolean("done", false)) {
        n++;
      }
    }
    return n;
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
      note.put("done", false);
    } catch (JSONException e) {
      return -1;
    }
    arr.put(note);
    save(c, arr);
    return id;
  }

  /** يعدّل نص الملاحظة ونوعها (type = null يعني نفس النوع). */
  static synchronized boolean update(Context c, long id, String text, String type) {
    String t = text == null ? null : text.trim();
    if (t != null && t.length() == 0) {
      return false;
    }
    JSONArray arr = load(c);
    boolean changed = false;
    for (int i = 0; i < arr.length(); i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null || o.optLong("id") != id) {
        continue;
      }
      try {
        if (t != null) {
          o.put("text", t);
        }
        if (type != null) {
          o.put("type", normalizeType(type));
        }
        changed = true;
      } catch (JSONException ignored) {
      }
      break;
    }
    if (changed) {
      save(c, arr);
    }
    return changed;
  }

  static synchronized boolean setDone(Context c, long id, boolean done) {
    JSONArray arr = load(c);
    boolean changed = false;
    for (int i = 0; i < arr.length(); i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null || o.optLong("id") != id) {
        continue;
      }
      try {
        o.put("done", done);
        changed = true;
      } catch (JSONException ignored) {
      }
      break;
    }
    if (changed) {
      save(c, arr);
    }
    return changed;
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

  /** يحذف الملاحظات المعلّمة «تم» ويعيد عددها. */
  static synchronized int clearDone(Context c) {
    JSONArray arr = load(c);
    JSONArray out = new JSONArray();
    int removed = 0;
    for (int i = 0; i < arr.length(); i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null) {
        continue;
      }
      if (o.optBoolean("done", false)) {
        removed++;
        continue;
      }
      out.put(o);
    }
    if (removed > 0) {
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

  // ===========================================================
  // خيارات التخصيص
  // ===========================================================

  static int intPref(Context c, String key, int def, int min, int max) {
    int v;
    try {
      v = prefs(c).getInt(key, def);
    } catch (ClassCastException e) {
      v = def;
    }
    return Math.max(min, Math.min(max, v));
  }

  static boolean boolPref(Context c, String key, boolean def) {
    try {
      return prefs(c).getBoolean(key, def);
    } catch (ClassCastException e) {
      return def;
    }
  }

  static String stringPref(Context c, String key, String def) {
    try {
      String v = prefs(c).getString(key, def);
      return v == null ? def : v;
    } catch (ClassCastException e) {
      return def;
    }
  }

  static int bubbleSize(Context c) {
    return intPref(c, P_BUBBLE_SIZE, 1, 0, 2);
  }

  static int bubbleColor(Context c) {
    return intPref(c, P_BUBBLE_COLOR, 0, 0, PALETTE_SIZE - 1);
  }

  static int bubbleAlpha(Context c) {
    return intPref(c, P_BUBBLE_ALPHA, 100, 30, 100);
  }

  static int theme(Context c) {
    return intPref(c, P_THEME, 0, 0, 2);
  }

  static int fontSize(Context c) {
    return intPref(c, P_FONT, 1, 0, 2);
  }

  static int panelPosition(Context c) {
    return intPref(c, P_PANEL_POS, 0, 0, 2);
  }

  static int longPress(Context c) {
    return intPref(c, P_LONG_PRESS, 0, 0, 2);
  }

  static boolean closeAfterCopy(Context c) {
    return boolPref(c, P_CLOSE_AFTER_COPY, false);
  }

  static boolean copyNumbers(Context c) {
    return boolPref(c, P_COPY_NUMBERS, true);
  }

  static boolean copyTypes(Context c) {
    return boolPref(c, P_COPY_TYPES, true);
  }

  static boolean showTime(Context c) {
    return boolPref(c, P_SHOW_TIME, true);
  }

  static boolean snapToEdge(Context c) {
    return boolPref(c, P_SNAP, true);
  }

  static String title(Context c) {
    String t = stringPref(c, P_TITLE, "").trim();
    return t.length() == 0 ? "الحافظة" : t;
  }

  static String defaultLabel(String type) {
    if (TYPE_EDIT.equals(type)) {
      return "تعديل";
    }
    if (TYPE_CANCEL.equals(type)) {
      return "إلغاء";
    }
    if (TYPE_DELIVER.equals(type)) {
      return "تسليم";
    }
    return "إضافة";
  }

  static String label(Context c, String type) {
    String t = normalizeType(type);
    String v = stringPref(c, P_LABEL_PREFIX + t, "").trim();
    return v.length() == 0 ? defaultLabel(t) : v;
  }

  static boolean isTypeHidden(Context c, String type) {
    String raw = "," + stringPref(c, P_HIDDEN_TYPES, "") + ",";
    return raw.contains("," + normalizeType(type) + ",");
  }

  /** الأنواع الظاهرة بلوحة الإضافة (نوع واحد على الأقل). */
  static List<String> visibleTypes(Context c) {
    List<String> out = new ArrayList<String>();
    for (int i = 0; i < ALL_TYPES.length; i++) {
      if (!isTypeHidden(c, ALL_TYPES[i])) {
        out.add(ALL_TYPES[i]);
      }
    }
    if (out.isEmpty()) {
      out.add(TYPE_ADD);
    }
    return out;
  }

  /** كل الخيارات كـ JSON (لـ Dart). */
  static synchronized String prefsJson(Context c) {
    JSONObject o = new JSONObject();
    try {
      o.put(P_BUBBLE_SIZE, bubbleSize(c));
      o.put(P_BUBBLE_COLOR, bubbleColor(c));
      o.put(P_BUBBLE_ALPHA, bubbleAlpha(c));
      o.put(P_THEME, theme(c));
      o.put(P_FONT, fontSize(c));
      o.put(P_PANEL_POS, panelPosition(c));
      o.put(P_LONG_PRESS, longPress(c));
      o.put(P_CLOSE_AFTER_COPY, closeAfterCopy(c));
      o.put(P_COPY_NUMBERS, copyNumbers(c));
      o.put(P_COPY_TYPES, copyTypes(c));
      o.put(P_SHOW_TIME, showTime(c));
      o.put(P_SNAP, snapToEdge(c));
      o.put(P_TITLE, stringPref(c, P_TITLE, ""));
      o.put(P_HIDDEN_TYPES, stringPref(c, P_HIDDEN_TYPES, ""));
      for (int i = 0; i < ALL_TYPES.length; i++) {
        String k = P_LABEL_PREFIX + ALL_TYPES[i];
        o.put(k, stringPref(c, k, ""));
      }
    } catch (JSONException ignored) {
    }
    return o.toString();
  }

  /** يحفظ خيارات (من Dart أو من اللوحة). القيم: رقم أو true/false أو نص. */
  static synchronized void savePrefs(Context c, Map<?, ?> values) {
    if (values == null || values.isEmpty()) {
      return;
    }
    SharedPreferences.Editor e = prefs(c).edit();
    Iterator<?> it = values.entrySet().iterator();
    while (it.hasNext()) {
      Map.Entry<?, ?> entry = (Map.Entry<?, ?>) it.next();
      if (entry.getKey() == null) {
        continue;
      }
      String key = entry.getKey().toString();
      Object v = entry.getValue();
      if (!isPrefKey(key)) {
        continue;
      }
      if (v == null) {
        e.remove(key);
      } else if (v instanceof Boolean) {
        e.putBoolean(key, ((Boolean) v).booleanValue());
      } else if (v instanceof Number) {
        e.putInt(key, ((Number) v).intValue());
      } else {
        e.putString(key, v.toString());
      }
    }
    e.apply();
    notifyPrefsChanged();
  }

  static void putInt(Context c, String key, int value) {
    prefs(c).edit().putInt(key, value).apply();
    notifyPrefsChanged();
  }

  static void putBool(Context c, String key, boolean value) {
    prefs(c).edit().putBoolean(key, value).apply();
    notifyPrefsChanged();
  }

  private static boolean isPrefKey(String key) {
    return P_BUBBLE_SIZE.equals(key)
        || P_BUBBLE_COLOR.equals(key)
        || P_BUBBLE_ALPHA.equals(key)
        || P_THEME.equals(key)
        || P_FONT.equals(key)
        || P_PANEL_POS.equals(key)
        || P_LONG_PRESS.equals(key)
        || P_CLOSE_AFTER_COPY.equals(key)
        || P_COPY_NUMBERS.equals(key)
        || P_COPY_TYPES.equals(key)
        || P_SHOW_TIME.equals(key)
        || P_SNAP.equals(key)
        || P_TITLE.equals(key)
        || P_HIDDEN_TYPES.equals(key)
        || key.startsWith(P_LABEL_PREFIX);
  }

  // ===========================================================
  // المستمعين
  // ===========================================================

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
            NotesTileService.refresh(appContext);
          }
        });
  }

  static void notifyPrefsChanged() {
    final List<Listener> copy;
    synchronized (listeners) {
      copy = new ArrayList<Listener>(listeners);
    }
    main.post(
        new Runnable() {
          @Override
          public void run() {
            for (int i = 0; i < copy.size(); i++) {
              ((Listener) copy.get(i)).onPrefsChanged();
            }
          }
        });
  }
}
