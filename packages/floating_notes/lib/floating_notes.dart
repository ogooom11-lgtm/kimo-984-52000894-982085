// packages/floating_notes/lib/floating_notes.dart
// -------------------------------------------------------------
// «الحافظة»: فقاعة ملاحظات عائمة فوق كل التطبيقات (أندرويد فقط): دائرة
// قابلة للسحب، والضغط عليها يفتح لوحة لإضافة ملاحظة مع نوعها
// (إضافة/تعديل/إلغاء/تسليم)، مع لصق المنسوخ ونسخ/تعديل/«تم»/حذف.
// الملاحظات محفوظة في الجهاز بترتيب وقت إضافتها. وفي زر «الحافظة» بلوحة
// الإعدادات السريعة (الستارة) بيفتحها من أي مكان.
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

  /// انعلّمت «تم» (منجزة)
  final bool done;

  const FloatingNote({
    required this.id,
    required this.text,
    required this.type,
    required this.at,
    this.done = false,
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
      done: m['done'] == true,
    );
  }
}

/// خيارات تخصيص الحافظة (نفس المفاتيح بالأندرويد)
class FloatingNotesPrefs {
  /// 0 صغيرة، 1 متوسطة، 2 كبيرة
  final int bubbleSize;

  /// رقم لون الفقاعة (0..6) — شوف [palettes]
  final int bubbleColor;

  /// وضوح الفقاعة وهي واقفة (30..100 %)
  final int bubbleAlpha;

  /// 0 تلقائي، 1 فاتح، 2 داكن
  final int theme;

  /// 0 صغير، 1 عادي، 2 كبير
  final int fontSize;

  /// 0 فوق، 1 بالنص، 2 تحت
  final int panelPosition;

  /// الضغطة المطوّلة على الفقاعة: 0 فتح ولصق، 1 إخفاء، 2 ولا شي
  final int longPress;
  final bool closeAfterCopy;
  final bool copyNumbers;
  final bool copyTypes;
  final bool showTime;
  final bool snapToEdge;

  /// اسم الحافظة (فاضي = «الحافظة»)
  final String title;

  /// أسماء الأنواع المخصصة (فاضي = الاسم الافتراضي)
  final Map<FloatingNoteType, String> labels;

  /// الأنواع المخفية من لوحة الإضافة
  final Set<FloatingNoteType> hiddenTypes;

  const FloatingNotesPrefs({
    this.bubbleSize = 1,
    this.bubbleColor = 0,
    this.bubbleAlpha = 100,
    this.theme = 0,
    this.fontSize = 1,
    this.panelPosition = 0,
    this.longPress = 0,
    this.closeAfterCopy = false,
    this.copyNumbers = true,
    this.copyTypes = true,
    this.showTime = true,
    this.snapToEdge = true,
    this.title = '',
    this.labels = const {},
    this.hiddenTypes = const {},
  });

  /// ألوان الفقاعة (بداية/نهاية التدرّج) بنفس ترتيب الأندرويد
  static const List<List<int>> palettes = [
    [0xFF3F51B5, 0xFF26A69A],
    [0xFF1565C0, 0xFF00ACC1],
    [0xFF6A1B9A, 0xFFEC407A],
    [0xFFE65100, 0xFFFFB300],
    [0xFF2E7D32, 0xFF66BB6A],
    [0xFF263238, 0xFF607D8B],
    [0xFFC62828, 0xFFF06292],
  ];

  String get displayTitle => title.trim().isEmpty ? 'الحافظة' : title.trim();

  String labelOf(FloatingNoteType t) {
    final v = labels[t]?.trim() ?? '';
    return v.isEmpty ? t.label : v;
  }

  factory FloatingNotesPrefs.fromMap(Map<dynamic, dynamic> m) {
    int i(String k, int d, int min, int max) {
      final v = m[k];
      final n = v is num ? v.toInt() : int.tryParse('$v');
      return (n ?? d).clamp(min, max);
    }

    bool b(String k, bool d) {
      final v = m[k];
      return v is bool ? v : d;
    }

    final hidden = <FloatingNoteType>{};
    for (final raw in '${m['hiddenTypes'] ?? ''}'.split(',')) {
      for (final t in FloatingNoteType.values) {
        if (t.name == raw.trim()) hidden.add(t);
      }
    }
    return FloatingNotesPrefs(
      bubbleSize: i('bubbleSize', 1, 0, 2),
      bubbleColor: i('bubbleColor', 0, 0, palettes.length - 1),
      bubbleAlpha: i('bubbleAlpha', 100, 30, 100),
      theme: i('theme', 0, 0, 2),
      fontSize: i('fontSize', 1, 0, 2),
      panelPosition: i('panelPosition', 0, 0, 2),
      longPress: i('longPress', 0, 0, 2),
      closeAfterCopy: b('closeAfterCopy', false),
      copyNumbers: b('copyNumbers', true),
      copyTypes: b('copyTypes', true),
      showTime: b('showTime', true),
      snapToEdge: b('snapToEdge', true),
      title: m['title']?.toString() ?? '',
      labels: {
        for (final t in FloatingNoteType.values)
          if ((m['label_${t.name}']?.toString().trim() ?? '').isNotEmpty)
            t: m['label_${t.name}'].toString().trim(),
      },
      hiddenTypes: hidden,
    );
  }

  Map<String, Object> toMap() => {
    'bubbleSize': bubbleSize,
    'bubbleColor': bubbleColor,
    'bubbleAlpha': bubbleAlpha,
    'theme': theme,
    'fontSize': fontSize,
    'panelPosition': panelPosition,
    'longPress': longPress,
    'closeAfterCopy': closeAfterCopy,
    'copyNumbers': copyNumbers,
    'copyTypes': copyTypes,
    'showTime': showTime,
    'snapToEdge': snapToEdge,
    'title': title.trim(),
    'hiddenTypes': [for (final t in hiddenTypes) t.name].join(','),
    for (final t in FloatingNoteType.values)
      'label_${t.name}': labels[t]?.trim() ?? '',
  };

  FloatingNotesPrefs copyWith({
    int? bubbleSize,
    int? bubbleColor,
    int? bubbleAlpha,
    int? theme,
    int? fontSize,
    int? panelPosition,
    int? longPress,
    bool? closeAfterCopy,
    bool? copyNumbers,
    bool? copyTypes,
    bool? showTime,
    bool? snapToEdge,
    String? title,
    Map<FloatingNoteType, String>? labels,
    Set<FloatingNoteType>? hiddenTypes,
  }) => FloatingNotesPrefs(
    bubbleSize: bubbleSize ?? this.bubbleSize,
    bubbleColor: bubbleColor ?? this.bubbleColor,
    bubbleAlpha: bubbleAlpha ?? this.bubbleAlpha,
    theme: theme ?? this.theme,
    fontSize: fontSize ?? this.fontSize,
    panelPosition: panelPosition ?? this.panelPosition,
    longPress: longPress ?? this.longPress,
    closeAfterCopy: closeAfterCopy ?? this.closeAfterCopy,
    copyNumbers: copyNumbers ?? this.copyNumbers,
    copyTypes: copyTypes ?? this.copyTypes,
    showTime: showTime ?? this.showTime,
    snapToEdge: snapToEdge ?? this.snapToEdge,
    title: title ?? this.title,
    labels: labels ?? this.labels,
    hiddenTypes: hiddenTypes ?? this.hiddenTypes,
  );
}

/// نتيجة طلب إضافة زر «الحافظة» للوحة الإعدادات السريعة
enum FloatingTileResult { added, already, notAdded, unsupported, error }

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

  /// يصدر "notes" عند تغيّر الملاحظات، و"state" عند ظهور الفقاعة أو إخفائها،
  /// و"prefs" عند تغيّر الخيارات
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

  static Future<bool> updateNote(
    int id, {
    String? text,
    FloatingNoteType? type,
  }) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('updateNote', {
            'id': id,
            if (text != null) 'text': text,
            if (type != null) 'type': type.name,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setDone(int id, bool done) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('setDone', {
            'id': id,
            'done': done,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// يحذف الملاحظات المنجزة ويعيد عددها
  static Future<int> clearDone() async {
    if (!isSupported) return 0;
    try {
      return await _channel.invokeMethod<int>('clearDone') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<FloatingNotesPrefs> getPrefs() async {
    if (!isSupported) return const FloatingNotesPrefs();
    try {
      final raw = await _channel.invokeMethod<String>('getPrefs');
      if (raw == null || raw.isEmpty) return const FloatingNotesPrefs();
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? FloatingNotesPrefs.fromMap(decoded)
          : const FloatingNotesPrefs();
    } catch (_) {
      return const FloatingNotesPrefs();
    }
  }

  static Future<void> setPrefs(FloatingNotesPrefs prefs) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('setPrefs', {'values': prefs.toMap()});
    } catch (_) {}
  }

  /// أندرويد 13+ بيقدر يطلب إضافة الزر للوحة الإعدادات السريعة بمربع من النظام
  static Future<bool> canRequestTile() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('canRequestTile') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// يطلب من النظام إضافة زر «الحافظة» للوحة الإعدادات السريعة
  static Future<FloatingTileResult> requestAddTile() async {
    if (!isSupported) return FloatingTileResult.unsupported;
    try {
      final r = await _channel.invokeMethod<String>('requestAddTile');
      for (final v in FloatingTileResult.values) {
        if (v.name == r) return v;
      }
      return FloatingTileResult.error;
    } catch (_) {
      return FloatingTileResult.error;
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
