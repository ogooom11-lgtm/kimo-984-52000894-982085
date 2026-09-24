package com.mylist.share_intake;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * قائمة انتظار المشاركات في الذاكرة.
 *
 * <p>النشاط الشفاف يضيف المشاركة هنا ثم يفتح التطبيق، والإضافة (Plugin) تُعلم
 * Dart فورًا إن كان يستمع، وإلا يأخذها Dart عند جاهزيته عبر takePending.
 */
final class ShareIntakeStore {

  interface Listener {
    void onShareAvailable();
  }

  private static final List<Map<String, Object>> PENDING =
      new ArrayList<Map<String, Object>>();
  private static final List<Listener> LISTENERS = new ArrayList<Listener>();

  private ShareIntakeStore() {}

  static void add(Map<String, Object> payload) {
    List<Listener> copy;
    synchronized (ShareIntakeStore.class) {
      PENDING.add(payload);
      copy = new ArrayList<Listener>(LISTENERS);
    }
    for (Listener listener : copy) {
      try {
        listener.onShareAvailable();
      } catch (RuntimeException ignored) {
        // لا نسمح لمستمع واحد بإيقاف البقية
      }
    }
  }

  static synchronized List<Map<String, Object>> takeAll() {
    List<Map<String, Object>> out = new ArrayList<Map<String, Object>>(PENDING);
    PENDING.clear();
    return out;
  }

  static synchronized int count() {
    return PENDING.size();
  }

  static synchronized void addListener(Listener listener) {
    if (!LISTENERS.contains(listener)) {
      LISTENERS.add(listener);
    }
  }

  static synchronized void removeListener(Listener listener) {
    LISTENERS.remove(listener);
  }
}
