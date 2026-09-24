package com.mylist.share_intake;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * يربط قائمة انتظار المشاركات بـ Dart:
 * - MethodChannel "my_list/share_intake": takePending / hasPending
 * - EventChannel "my_list/share_intake/events": حدث "pending" عند وصول مشاركة
 */
public class ShareIntakePlugin
    implements FlutterPlugin,
        MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler,
        ShareIntakeStore.Listener {

  private static final String METHOD_CHANNEL = "my_list/share_intake";
  private static final String EVENT_CHANNEL = "my_list/share_intake/events";

  private MethodChannel channel;
  private EventChannel eventChannel;
  private EventChannel.EventSink sink;

  @Override
  public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
    channel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
    channel.setMethodCallHandler(this);
    eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
    eventChannel.setStreamHandler(this);
    ShareIntakeStore.addListener(this);
  }

  @Override
  public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {
    ShareIntakeStore.removeListener(this);
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
    if ("takePending".equals(call.method)) {
      result.success(ShareIntakeStore.takeAll());
    } else if ("hasPending".equals(call.method)) {
      result.success(Boolean.valueOf(ShareIntakeStore.count() > 0));
    } else {
      result.notImplemented();
    }
  }

  @Override
  public void onListen(Object arguments, EventChannel.EventSink events) {
    sink = events;
    if (ShareIntakeStore.count() > 0) {
      events.success("pending");
    }
  }

  @Override
  public void onCancel(Object arguments) {
    sink = null;
  }

  @Override
  public void onShareAvailable() {
    EventChannel.EventSink current = sink;
    if (current != null) {
      current.success("pending");
    }
  }
}
