// packages/floating_notes/lib/floating_notes.dart
// -------------------------------------------------------------
// فقاعة ملاحظات عائمة فوق كل التطبيقات (أندرويد فقط): دائرة قابلة للسحب،
// والضغط عليها يفتح لوحة لإضافة ملاحظة مع أيقونة (إضافة/تعديل/إلغاء/تسليم).
// الملاحظات محفوظة في الجهاز بترتيب وقت إضافتها.
// -------------------------------------------------------------

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum FloatingNoteType { add, edit, cancel, deliver }

extension FloatingNoteTypeInfo on FloatingNoteType {
  String get label {
    switch (this) {
      case FloatingNoteType.add:
        return 'إضافة';
      case FloatingNoteType.edit:
        return 'تعديل';
      case FloatingNoteType.cancel:
        return 'إلغاء';
      case FloatingNoteType.deliver:
        return 'تسليم';
    }
  }

  static FloatingNoteType parse(Object? raw) {
    for (final t in FloatingNoteType.values) {
      if (t.name == raw) return t;
    }
    return FloatingNoteType.add;
  }
}

class FloatingNote {
  final int id;
  final String text;
  final FloatingNoteType type;
  final DateTime at;

  const FloatingNote({
    required this.id,
    required this.text,
    required this.type,
    required this.at,
  });

  factory FloatingNote.fromMap(Map<dynamic, dynamic> m) {
    final at = m['at'];
    return FloatingNote(
      id: (m['id'] as num?)?.toInt() ?? 0,
      text: m['text']?.toString() ?? '',
      type: FloatingNoteTypeInfo.parse(m['type']),
      at: at is num
          ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class FloatingNotes {
  FloatingNotes._();

  static const MethodChannel _channel = MethodChannel('my_list/floating_notes');
  static const EventChannel _events = EventChannel(
    'my_list/floating_notes/events',
  );

  /// الفقاعة العائمة تعمل على أندرويد فقط
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Stream<String>? _changes;

  /// يصدر "notes" عند تغيّر الملاحظات، و"state" عند ظهور الفقاعة أو إخفائها
  static Stream<String> get changes {
    if (!isSupported) return const Stream<String>.empty();
    return _changes ??= _events
        .receiveBroadcastStream()
        .map((e) => '$e')
        .handleError((Object _) {});
  }

  /// هل منح المستخدم إذن «الظهور فوق التطبيقات الأخرى»؟
  static Future<bool> canDrawOverlays() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// يفتح صفحة الإذن في إعدادات أندرويد
  static Future<void> openPermissionSettings() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('openPermissionSettings');
    } catch (_) {}
  }

  /// يُظهر الفقاعة (false إذا لم يُمنح الإذن أو تعذر ذلك)
  static Future<bool> show({bool openPanel = false}) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('show', {'open': openPanel}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> hide() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('hide');
    } catch (_) {}
  }

  static Future<bool> isShowing() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isShowing') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// الملاحظات بترتيب وقت إضافتها (الأقدم أولًا)
  static Future<List<FloatingNote>> getNotes() async {
    if (!isSupported) return const [];
    try {
      final raw = await _channel.invokeMethod<String>('getNotes');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final notes = [
        for (final m in decoded)
          if (m is Map) FloatingNote.fromMap(m),
      ];
      notes.sort((a, b) => a.at.compareTo(b.at));
      return notes;
    } catch (_) {
      return const [];
    }
  }

  static Future<int> addNote(String text, FloatingNoteType type) async {
    if (!isSupported) return -1;
    try {
      final id = await _channel.invokeMethod<int>('addNote', {
        'text': text,
        'type': type.name,
      });
      return id ?? -1;
    } catch (_) {
      return -1;
    }
  }

  static Future<bool> deleteNote(int id) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('deleteNote', {'id': id}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clear() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('clearNotes');
    } catch (_) {}
  }
}
