package com.mylist.floating_notes;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.util.ArrayList;
import java.util.List;

/**
 * يربط فقاعة الملاحظات بـ Dart:
 * - MethodChannel "my_list/floating_notes": canDrawOverlays / openPermissionSettings /
 *   show / hide / isShowing / getNotes / addNote / deleteNote / clearNotes
 * - EventChannel "my_list/floating_notes/events": "notes" عند تغيّر الملاحظات،
 *   و"state" عند ظهور الفقاعة أو إخفائها
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
        startService(
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

  private void startService(String action) {
    Intent i = new Intent(context, FloatingNotesService.class);
    i.setAction(action);
    if (Build.VERSION.SDK_INT >= 26) {
      context.startForegroundService(i);
    } else {
      context.startService(i);
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
