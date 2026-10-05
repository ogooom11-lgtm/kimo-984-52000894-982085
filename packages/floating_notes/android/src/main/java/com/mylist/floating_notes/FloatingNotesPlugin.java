package com.mylist.floating_notes;

import android.app.StatusBarManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * يربط الحافظة العائمة بـ Dart:
 * - MethodChannel "my_list/floating_notes": canDrawOverlays / openPermissionSettings /
 *   show / hide / isShowing / getNotes / addNote / updateNote / setDone / deleteNote /
 *   clearNotes / clearDone / getPrefs / setPrefs / canRequestTile / requestAddTile
 * - EventChannel "my_list/floating_notes/events": "notes" عند تغيّر الملاحظات،
 *   و"state" عند ظهور الفقاعة أو إخفائها، و"prefs" عند تغيّر الخيارات
 */
public class FloatingNotesPlugin
    implements FlutterPlugin,
        MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler,
        NotesStore.Listener {

  private static final String METHOD_CHANNEL = "my_list/floating_notes";
  private static final String EVENT_CHANNEL = "my_list/floating_notes/events";

  private static final List<FloatingNotesPlugin> instances = new ArrayList<FloatingNotesPlugin>();

  private Context context;
  private MethodChannel channel;
  private EventChannel eventChannel;
  private EventChannel.EventSink sink;

  @Override
  public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
    channel.setMethodCallHandler(this);
    eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
    eventChannel.setStreamHandler(this);
    NotesStore.addListener(this);
    synchronized (instances) {
      instances.add(this);
    }
  }

  @Override
  public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {
    NotesStore.removeListener(this);
    synchronized (instances) {
      instances.remove(this);
    }
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
    if (eventChannel != null) {
      eventChannel.setStreamHandler(null);
      eventChannel = null;
    }
    sink = null;
  }

  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    String method = call.method;
    try {
      if ("canDrawOverlays".equals(method)) {
        result.success(Boolean.valueOf(FloatingNotesService.canDraw(context)));
      } else if ("openPermissionSettings".equals(method)) {
        openPermissionSettings();
        result.success(Boolean.TRUE);
      } else if ("show".equals(method)) {
        if (!FloatingNotesService.canDraw(context)) {
          result.success(Boolean.FALSE);
          return;
        }
        Object open = call.argument("open");
        FloatingNotesService.start(
            context,
            Boolean.TRUE.equals(open)
                ? FloatingNotesService.ACTION_OPEN
                : FloatingNotesService.ACTION_SHOW);
        result.success(Boolean.TRUE);
      } else if ("hide".equals(method)) {
        context.stopService(new Intent(context, FloatingNotesService.class));
        result.success(null);
      } else if ("isShowing".equals(method)) {
        result.success(Boolean.valueOf(FloatingNotesService.isRunning()));
      } else if ("getNotes".equals(method)) {
        result.success(NotesStore.json(context));
      } else if ("addNote".equals(method)) {
        Object text = call.argument("text");
        Object type = call.argument("type");
        long id =
            NotesStore.add(
                context,
                text == null ? "" : text.toString(),
                type == null ? NotesStore.TYPE_ADD : type.toString());
        result.success(Long.valueOf(id));
      } else if ("updateNote".equals(method)) {
        Object id = call.argument("id");
        Object text = call.argument("text");
        Object type = call.argument("type");
        boolean ok =
            id instanceof Number
                && NotesStore.update(
                    context,
                    ((Number) id).longValue(),
                    text == null ? null : text.toString(),
                    type == null ? null : type.toString());
        result.success(Boolean.valueOf(ok));
      } else if ("setDone".equals(method)) {
        Object id = call.argument("id");
        Object done = call.argument("done");
        boolean ok =
            id instanceof Number
                && NotesStore.setDone(
                    context, ((Number) id).longValue(), Boolean.TRUE.equals(done));
        result.success(Boolean.valueOf(ok));
      } else if ("clearDone".equals(method)) {
        result.success(Integer.valueOf(NotesStore.clearDone(context)));
      } else if ("getPrefs".equals(method)) {
        result.success(NotesStore.prefsJson(context));
      } else if ("setPrefs".equals(method)) {
        Object values = call.argument("values");
        if (values instanceof Map) {
          NotesStore.savePrefs(context, (Map<?, ?>) values);
        }
        result.success(Boolean.TRUE);
      } else if ("canRequestTile".equals(method)) {
        result.success(Boolean.valueOf(Build.VERSION.SDK_INT >= 33));
      } else if ("requestAddTile".equals(method)) {
        requestAddTile(result);
      } else if ("deleteNote".equals(method)) {
        Object id = call.argument("id");
        boolean removed = id instanceof Number && NotesStore.delete(context, ((Number) id).longValue());
        result.success(Boolean.valueOf(removed));
      } else if ("clearNotes".equals(method)) {
        NotesStore.clear(context);
        result.success(null);
      } else {
        result.notImplemented();
      }
    } catch (Exception e) {
      result.error("floating_notes", e.getMessage(), null);
    }
  }

  /**
   * يطلب من النظام إضافة زر «الحافظة» للوحة الإعدادات السريعة (أندرويد 13+):
   * بيطلع مربع من النظام والمستخدم بيوافق. النتيجة: added / already /
   * notAdded / unsupported / error.
   */
  private void requestAddTile(final MethodChannel.Result result) {
    if (Build.VERSION.SDK_INT < 33) {
      result.success("unsupported");
      return;
    }
    try {
      StatusBarManager sbm = context.getSystemService(StatusBarManager.class);
      if (sbm == null) {
        result.success("unsupported");
        return;
      }
      final boolean[] answered = {false};
      sbm.requestAddTileService(
          new ComponentName(context, NotesTileService.class),
          NotesStore.title(context),
          Icon.createWithResource(context, R.drawable.ic_floating_notes_tile),
          context.getMainExecutor(),
          new Consumer<Integer>() {
            @Override
            public void accept(Integer code) {
              if (answered[0]) {
                return;
              }
              answered[0] = true;
              int c = code == null ? -1 : code.intValue();
              if (c == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED) {
                result.success("added");
              } else if (c == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED) {
                result.success("already");
              } else if (c == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED) {
                result.success("notAdded");
              } else {
                result.success("error");
              }
            }
          });
    } catch (Exception e) {
      result.success("error");
    }
  }

  /** صفحة إذن «الظهور فوق التطبيقات الأخرى». */
  private void openPermissionSettings() {
    Intent i =
        new Intent(
            Build.VERSION.SDK_INT >= 23
                ? Settings.ACTION_MANAGE_OVERLAY_PERMISSION
                : Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:" + context.getPackageName()));
    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
    context.startActivity(i);
  }

  @Override
  public void onListen(Object arguments, EventChannel.EventSink events) {
    sink = events;
  }

  @Override
  public void onCancel(Object arguments) {
    sink = null;
  }

  @Override
  public void onNotesChanged() {
    emit("notes");
  }

  @Override
  public void onPrefsChanged() {
    emit("prefs");
  }

  /** تستدعيها الخدمة عند ظهور الفقاعة أو إخفائها (على الخيط الرئيسي). */
  static void notifyStateChanged() {
    List<FloatingNotesPlugin> copy;
    synchronized (instances) {
      copy = new ArrayList<FloatingNotesPlugin>(instances);
    }
    for (int i = 0; i < copy.size(); i++) {
      ((FloatingNotesPlugin) copy.get(i)).emit("state");
    }
  }

  private void emit(String what) {
    EventChannel.EventSink current = sink;
    if (current != null) {
      current.success(what);
    }
  }
}
