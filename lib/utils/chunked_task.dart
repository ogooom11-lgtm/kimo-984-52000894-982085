// lib/utils/chunked_task.dart
// تنفيذ الأعمال الثقيلة على دفعات صغيرة مع إعطاء الواجهة فرصة للرسم بين
// الدفعات، حتى لا يتجمد التطبيق (يعمل على الويب والموبايل وسطح المكتب).

import 'dart:async';

import 'package:flutter/foundation.dart';

/// حالة عملية جارية لعرضها في شريط التقدم.
@immutable
class OperationProgress {
  final String label;
  final int done;
  final int total;

  const OperationProgress({
    required this.label,
    required this.done,
    required this.total,
  });

  /// من 0 إلى 1 (أو null إذا كان الإجمالي غير معروف)
  double? get fraction {
    if (total <= 0) return null;
    final f = done / total;
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
  }

  int get percent => ((fraction ?? 0) * 100).round();

  OperationProgress copyWith({String? label, int? done, int? total}) =>
      OperationProgress(
        label: label ?? this.label,
        done: done ?? this.done,
        total: total ?? this.total,
      );
}

/// يمنح حلقة الأحداث فرصة لرسم إطار جديد.
Future<void> yieldToUi() =>
    Future<void>.delayed(const Duration(milliseconds: 1));

/// ينفّذ [work] لكل عنصر من 0 إلى total-1 على شرائح زمنية قصيرة.
/// بين كل شريحة وأخرى يتم استدعاء [onProgress] ثم إعطاء الواجهة فرصة للرسم.
Future<void> runTimeSliced({
  required int total,
  required FutureOr<void> Function(int index) work,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
  Duration budget = const Duration(milliseconds: 12),
}) async {
  final sw = Stopwatch()..start();
  onProgress?.call(0, total);
  for (var i = 0; i < total; i++) {
    if (isCancelled?.call() ?? false) return;
    final r = work(i);
    if (r is Future) await r;
    if (sw.elapsed >= budget) {
      onProgress?.call(i + 1, total);
      await yieldToUi();
      sw
        ..reset()
        ..start();
    }
  }
  onProgress?.call(total, total);
}
