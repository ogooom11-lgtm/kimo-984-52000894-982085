// packages/share_intake/lib/share_intake.dart
// -------------------------------------------------------------
// استقبال الملفات والنصوص التي يشاركها المستخدم مع التطبيق من تطبيقات أخرى
// (قائمة «مشاركة» أو «فتح باستخدام») — أندرويد فقط.
// الجانب الأصلي ينسخ كل ملف إلى مجلد الكاش ويحفظه في قائمة انتظار،
// ثم يُعلم Dart عبر [ShareIntake.onPending]، ويأخذها Dart عبر [ShareIntake.takePending].
// -------------------------------------------------------------

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// ملف تمت مشاركته (نسخة محلية داخل مجلد الكاش الخاص بالتطبيق)
class SharedIntakeFile {
  final String path;
  final String name;
  final String? mimeType;
  final int size;

  const SharedIntakeFile({
    required this.path,
    required this.name,
    this.mimeType,
    this.size = 0,
  });
}

/// مشاركة واحدة (قد تحتوي عدة ملفات و/أو نصًا)
class SharedIntake {
  final String action;
  final List<SharedIntakeFile> files;
  final String? text;
  final String? subject;

  /// ملفات تعذر نسخها (الاسم: السبب)
  final List<String> errors;

  const SharedIntake({
    this.action = '',
    this.files = const [],
    this.text,
    this.subject,
    this.errors = const [],
  });

  bool get hasText => (text ?? '').trim().isNotEmpty;

  bool get isEmpty => files.isEmpty && !hasText && errors.isEmpty;
}

class ShareIntake {
  ShareIntake._();

  static const MethodChannel _channel = MethodChannel('my_list/share_intake');
  static const EventChannel _events = EventChannel(
    'my_list/share_intake/events',
  );

  /// المشاركة من التطبيقات الأخرى مدعومة على أندرويد فقط
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Stream<void>? _pending;

  /// يصدر حدثًا كلما وصلت مشاركة جديدة (ثم استدعِ [takePending])
  static Stream<void> get onPending {
    if (!isSupported) return const Stream<void>.empty();
    return _pending ??= _events
        .receiveBroadcastStream()
        .handleError((Object _) {})
        .map<void>((_) {});
  }

  /// يأخذ كل المشاركات المنتظرة ويفرّغ قائمة الانتظار
  static Future<List<SharedIntake>> takePending() async {
    if (!isSupported) return const [];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('takePending');
      return [
        for (final item in raw ?? const <Object?>[])
          if (item is Map) _parse(item),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  static SharedIntake _parse(Map<Object?, Object?> m) {
    String? str(Object? v) => v is String ? v : null;
    final files = <SharedIntakeFile>[];
    final rawFiles = m['files'];
    if (rawFiles is List) {
      for (final f in rawFiles) {
        if (f is! Map) continue;
        final path = str(f['path']);
        if (path == null || path.isEmpty) continue;
        final size = f['size'];
        files.add(
          SharedIntakeFile(
            path: path,
            name: str(f['name']) ?? path.split('/').last,
            mimeType: str(f['mimeType']),
            size: size is int ? size : 0,
          ),
        );
      }
    }
    final rawErrors = m['errors'];
    return SharedIntake(
      action: str(m['action']) ?? '',
      files: files,
      text: str(m['text']),
      subject: str(m['subject']),
      errors: [
        if (rawErrors is List)
          for (final e in rawErrors)
            if (e is String && e.isNotEmpty) e,
      ],
    );
  }
}
