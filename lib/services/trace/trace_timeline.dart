// lib/services/trace/trace_timeline.dart
// -------------------------------------------------------------
// أحداث الحركة بـ«مسار الحركة»: كل تغيير بسطر لحالو مع تاريخه، مثلًا:
//   • وصلت للمكتب      2026-10-01 14:20
//   • انعدل المبلغ     من 900 دولار إلى 1.000 دولار
//   • التغت            2026-10-02 09:10 (بعد 19 ساعة من الوصول)
// المصدر: حقول الحركة (التاريخ، تاريخ التسليم/الإلغاء) + سجل الحركة
// (التسليم/الإلغاء/الإرجاع والتعديلات). الحالة الحالية بتنضاف إذا السجل ما
// بيغطيها (حركات أقدم من السجل أو انحفظت مباشرة كمستلمة/ملغية).
//
// ملف Dart نقي (بدون Flutter) حتى يمكن اختباره مباشرة.
// -------------------------------------------------------------

import '../../models.dart';
import '../tx_history.dart';

/// مصدر تعديلات «التوحيد» من «مسار الحركة» (بيظهر بسجل الحركة)
const String kTraceAlignNameSource = 'توحيد الاسم من مسار الحركة';
const String kTraceAlignAmountSource = 'توحيد المبلغ من مسار الحركة';

/// التعديل انعمل من «مسار الحركة» (توحيد الاسم/المبلغ مع الحركة التانية)؟
bool isTraceAlignSource(String? source) =>
    source == kTraceAlignNameSource || source == kTraceAlignAmountSource;

enum TraceEventKind {
  /// وصلت (للمكتب/للشركة)
  arrived,

  /// انبعتت من الشركة (حركة إرسال)
  sent,

  /// تسلّمت
  delivered,

  /// التغت
  cancelled,

  /// انشال التسليم/الإلغاء (رجعت فعّالة)
  reopened,

  /// انحذفت
  deleted,

  /// رجعت بعد الحذف
  restored,

  /// تعديل الاسم/المبلغ/العملة/التاريخ…
  edited,

  /// انقلت لحساب تاني
  moved,

  /// تحديد/تعديل الوجهة
  destination,

  /// تحديد المصدر/الوجهة يدويًا بمسار الحركة
  linked,
}

extension TraceEventKindInfo on TraceEventKind {
  /// حدث حالة (وصول/تسليم/إلغاء/إرجاع/حذف/استعادة) — بينعرض دايمًا
  bool get isStatus => index <= TraceEventKind.restored.index;
}

/// حدث واحد بحياة الحركة
class TraceTxEvent {
  final TraceEventKind kind;

  /// وقت الحدث (null = مو معروف)
  final DateTime? at;
  final String label;

  /// تفاصيل (مثل «من 900 دولار إلى 1.000 دولار»)
  final String? detail;

  const TraceTxEvent(this.kind, this.at, this.label, {this.detail});

  @override
  String toString() =>
      '$label${detail == null ? '' : ' ($detail)'} @ ${at?.toIso8601String()}';
}

/// اسم حدث الوصول حسب نوع الحركة
String traceArrivalLabel(TransactionModel t, {required bool isCompany}) {
  if (!isCompany) return 'وصلت للمكتب';
  return (t.companyMovementType?.isSent ?? false)
      ? 'انبعتت من الشركة'
      : 'وصلت للشركة';
}

DateTime? _date(Object? raw) => TxHistoryFormatter.parseDate(raw);

bool _cancelledMovement(Object? raw) =>
    TxHistoryFormatter.movementOf(raw)?.isCancelled ?? false;

/// «من X إلى Y» (أو القيمة الوحيدة الموجودة) + المعلومة الإضافية
String? _fromTo(TxChangeRow r) {
  final from = r.from;
  final to = r.to;
  String? s;
  if (from != null && to != null) {
    s = 'من $from إلى $to';
  } else {
    s = to ?? from;
  }
  final extra = r.extra;
  if (extra != null && extra.trim().isNotEmpty) {
    s = s == null ? extra : '$s ($extra)';
  }
  return s;
}

/// صياغة عامية لعناوين سطور السجل
const Map<String, String> _colloquial = {
  'تم تعديل الاسم': 'انعدل الاسم',
  'تم تعديل المبلغ والعملة': 'انعدل المبلغ والعملة',
  'تم تعديل المبلغ': 'انعدل المبلغ',
  'تم تعديل العملة': 'انعدلت العملة',
  'تم تعديل عملة المبلغ الثاني': 'انعدلت عملة المبلغ التاني',
  'تمت إضافة مبلغ ثانٍ': 'انضاف مبلغ تاني',
  'تم حذف المبلغ الثاني': 'انشال المبلغ التاني',
  'تم تعديل المبلغ الثاني وعملته': 'انعدل المبلغ التاني وعملته',
  'تم تعديل المبلغ الثاني': 'انعدل المبلغ التاني',
  'تم تعديل تاريخ الحركة': 'انعدل تاريخ الحركة',
  'تم تعديل تاريخ التسليم': 'انعدل تاريخ التسليم',
  'تم تعديل تاريخ الإلغاء': 'انعدل تاريخ الإلغاء',
  'تم تحديد الوجهة': 'تحددت الوجهة',
  'تم حذف الوجهة': 'انشالت الوجهة',
  'تم تعديل الوجهة': 'انعدلت الوجهة',
};

/// ترتيب ثابت حسب الوقت (اللي وقتها مو معروف بالآخر)
List<TraceTxEvent> _sortedByTime(List<TraceTxEvent> list) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final x = a.$2.at;
    final y = b.$2.at;
    if (x != null && y != null) {
      final c = x.compareTo(y);
      if (c != 0) return c;
    } else if (x == null && y != null) {
      return 1;
    } else if (x != null && y == null) {
      return -1;
    }
    return a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// أحداث الحركة بالترتيب: الوصول أولًا، وبعدين التسليم/الإلغاء/الإرجاع
/// والتعديلات حسب وقتها.
///
/// [history] بترتيب TxHistoryService.entriesFor (الأحدث تسجيلًا أولًا).
/// [includeEdits] = false: الحالة بس (وصلت/تسلّمت/التغت/رجعت).
List<TraceTxEvent> traceTxEvents(
  TransactionModel t, {
  required bool isCompany,
  List<TxHistoryEntry> history = const [],
  bool includeEdits = true,
  TxHistoryFormatter formatter = const TxHistoryFormatter(),
}) {
  final sent = isCompany && (t.companyMovementType?.isSent ?? false);
  final arrival = TraceTxEvent(
    sent ? TraceEventKind.sent : TraceEventKind.arrived,
    t.date,
    traceArrivalLabel(t, isCompany: isCompany),
  );
  final cancelLabel = isCompany ? 'التغت بالشركة' : 'التغت';
  final rest = <TraceTxEvent>[];

  // من الأقدم للأحدث
  final entries = sortEntriesByTime(history).reversed;
  for (final e in entries) {
    switch (e.kind) {
      case TxHistoryKind.deleted:
        rest.add(TraceTxEvent(TraceEventKind.deleted, e.at, 'انحذفت'));
        continue;
      case TxHistoryKind.restored:
        rest.add(TraceTxEvent(TraceEventKind.restored, e.at, 'رجعت بعد الحذف'));
        continue;
      case TxHistoryKind.link:
        if (!includeEdits) continue;
        final rows = formatter.rows(e);
        rest.add(
          TraceTxEvent(
            TraceEventKind.linked,
            e.at,
            formatter.title(e),
            detail: rows.isEmpty ? null : _fromTo(rows.first),
          ),
        );
        continue;
      case TxHistoryKind.edit:
        break;
    }

    final by = {for (final c in e.changes) c.field: c};
    final st = by[TxField.status];
    final mv = by[TxField.companyMovementType];
    final received = by[TxField.receivedAt];
    final cancelled = by[TxField.cancelledAt];
    final stTo = st?.newValue?.toString();
    final stFrom = st?.oldValue?.toString();

    if (st != null) {
      if (stTo == 'received') {
        rest.add(
          TraceTxEvent(
            TraceEventKind.delivered,
            _date(received?.newValue) ?? e.at,
            'تسلّمت',
          ),
        );
      } else if (stTo == 'cancelled') {
        rest.add(
          TraceTxEvent(
            TraceEventKind.cancelled,
            _date(cancelled?.newValue) ?? e.at,
            cancelLabel,
          ),
        );
      } else if (stTo == 'added') {
        rest.add(
          TraceTxEvent(
            TraceEventKind.reopened,
            e.at,
            stFrom == 'received'
                ? 'انشال التسليم (رجعت مضافة)'
                : (stFrom == 'cancelled'
                      ? 'انشال الإلغاء (رجعت مضافة)'
                      : 'رجعت مضافة'),
          ),
        );
      }
    }

    if (mv != null) {
      final toCancelled = _cancelledMovement(mv.newValue);
      final fromCancelled = _cancelledMovement(mv.oldValue);
      if (toCancelled && !fromCancelled) {
        // إلغاء الشركة مع تغيير الحالة لملغية بنفس التعديل = حدث واحد
        if (stTo != 'cancelled') {
          rest.add(
            TraceTxEvent(
              TraceEventKind.cancelled,
              _date(cancelled?.newValue) ?? e.at,
              cancelLabel,
            ),
          );
        }
      } else if (fromCancelled && !toCancelled) {
        if (stTo != 'added') {
          rest.add(
            TraceTxEvent(
              TraceEventKind.reopened,
              e.at,
              'رجعت فعّالة بالشركة (انشال الإلغاء)',
            ),
          );
        }
      } else if (includeEdits) {
        rest.add(
          TraceTxEvent(
            TraceEventKind.edited,
            e.at,
            'تغيّر نوع الحركة',
            detail:
                'من ${TxHistoryFormatter.movementLabel(mv.oldValue)} '
                'إلى ${TxHistoryFormatter.movementLabel(mv.newValue)}',
          ),
        );
      }
    }

    if (!includeEdits) continue;
    final aligned = isTraceAlignSource(e.source);
    for (final r in formatter.rows(e)) {
      switch (r.kind) {
        case TxRowKind.status:
        case TxRowKind.movement:
        case TxRowKind.notes:
        case TxRowKind.deleted:
        case TxRowKind.restored:
        case TxRowKind.link:
          continue;
        case TxRowKind.account:
          rest.add(
            TraceTxEvent(
              TraceEventKind.moved,
              e.at,
              'انقلت لحساب تاني',
              detail: _fromTo(r),
            ),
          );
        case TxRowKind.destination:
          final label = _colloquial[r.label] ?? r.label;
          final String? detail;
          if (r.label == 'تم تحديد الوجهة') {
            detail = r.to;
          } else if (r.label == 'تم حذف الوجهة') {
            detail = r.from;
          } else {
            detail = _fromTo(r);
          }
          rest.add(
            TraceTxEvent(
              TraceEventKind.destination,
              e.at,
              label,
              detail: detail,
            ),
          );
        case TxRowKind.name:
        case TxRowKind.money:
        case TxRowKind.secondMoney:
        case TxRowKind.date:
        case TxRowKind.receivedAt:
        case TxRowKind.cancelledAt:
          final label = _colloquial[r.label] ?? r.label;
          rest.add(
            TraceTxEvent(
              TraceEventKind.edited,
              e.at,
              aligned ? '$label (توحيد من المسار)' : label,
              detail: _fromTo(r),
            ),
          );
      }
    }
  }

  // الحالة الحالية إذا السجل ما بيغطيها (آخر حدث حالة لازم يطابقها)
  var sorted = _sortedByTime(rest);
  TraceEventKind? last;
  for (final ev in sorted) {
    if (ev.kind == TraceEventKind.delivered ||
        ev.kind == TraceEventKind.cancelled ||
        ev.kind == TraceEventKind.reopened) {
      last = ev.kind;
    }
  }
  TraceTxEvent? current;
  if (isCompany) {
    if (t.isCompanyCancelled && last != TraceEventKind.cancelled) {
      current = TraceTxEvent(
        TraceEventKind.cancelled,
        t.cancelledAt,
        cancelLabel,
      );
    }
  } else if (t.status == TransactionStatus.received &&
      last != TraceEventKind.delivered) {
    current = TraceTxEvent(TraceEventKind.delivered, t.receivedAt, 'تسلّمت');
  } else if (t.status == TransactionStatus.cancelled &&
      last != TraceEventKind.cancelled) {
    current = TraceTxEvent(
      TraceEventKind.cancelled,
      t.cancelledAt,
      cancelLabel,
    );
  }
  if (current != null) sorted = _sortedByTime([...sorted, current]);

  return [arrival, ...sorted];
}
