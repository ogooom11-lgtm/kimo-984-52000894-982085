// lib/services/period_stats.dart
// -------------------------------------------------------------
// منطق موحّد لحساب إحصائيات فترة (يوم/شهر/سنة) لحسابات المكاتب والشركات.
//
// القاعدة (نفس منطق المكاتب للنوعين):
//  • الإضافة تُحسب بتاريخ إضافة الحركة، حتى لو أُلغيت أو سُلّمت لاحقًا.
//  • الإلغاء يُحسب بتاريخ الإلغاء، مهما كان تاريخ إضافة الحركة.
//  => الحركة التي أُضيفت ثم أُلغيت تُحسب «إضافة» في يوم إضافتها و«إلغاء»
//     في يوم إلغائها (وإذا كانا في نفس اليوم تُحسب إضافة وإلغاء معًا).
//
// المكاتب : مضافة / مستلمة / ملغاة / غير مستلمة (لقطة حتى نهاية الفترة)
// الشركات : إرسال / استقبال / إلغاء مرسل / إلغاء استقبال
// -------------------------------------------------------------

import '../models.dart';

/// المؤشرات الأربعة بنفس الترتيب في كل الشاشات.
enum PeriodMetric {
  /// مكتب: مضافة — شركة: إرسال
  added,

  /// مكتب: مستلمة — شركة: استقبال
  received,

  /// مكتب: ملغاة — شركة: إلغاء مرسل
  cancelled,

  /// مكتب: غير مستلمة — شركة: إلغاء استقبال
  fourth,
}

/// فترة زمنية مغلقة من الطرفين.
class StatsPeriod {
  final DateTime start;
  final DateTime end;

  const StatsPeriod(this.start, this.end);

  factory StatsPeriod.day(DateTime d) => StatsPeriod(
    DateTime(d.year, d.month, d.day),
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999),
  );

  bool contains(DateTime? d) {
    if (d == null) return false;
    final t = d.millisecondsSinceEpoch;
    return t >= start.millisecondsSinceEpoch && t <= end.millisecondsSinceEpoch;
  }
}

/// نتيجة التقسيم إلى المؤشرات الأربعة.
class PeriodBuckets {
  final List<TransactionModel> added;
  final List<TransactionModel> received;
  final List<TransactionModel> cancelled;
  final List<TransactionModel> fourth;

  const PeriodBuckets({
    required this.added,
    required this.received,
    required this.cancelled,
    required this.fourth,
  });

  List<TransactionModel> of(PeriodMetric m) {
    switch (m) {
      case PeriodMetric.added:
        return added;
      case PeriodMetric.received:
        return received;
      case PeriodMetric.cancelled:
        return cancelled;
      case PeriodMetric.fourth:
        return fourth;
    }
  }
}

class PeriodStats {
  PeriodStats._();

  // ---------------- أدوات الحركة ----------------

  /// هل الحركة حركة إرسال (مرسلة أو مرسلة ملغية)؟
  static bool isCompanySent(TransactionModel t) =>
      t.companyMovementType?.isSent ?? false;

  /// هل الحركة حركة استقبال (استقبال أو استقبال ملغي)؟
  static bool isCompanyReceived(TransactionModel t) {
    final m = t.companyMovementType;
    return m != null && !m.isSent;
  }

  /// لحظة إلغاء حركة الشركة (الحركات القديمة بدون تاريخ إلغاء نعتمد تاريخها).
  static DateTime? companyCancelMoment(TransactionModel t) {
    if (!(t.effectiveCompanyMovement?.isCancelled ?? false)) return null;
    return t.cancelledAt ?? t.date;
  }

  /// غير مستلمة حتى نهاية [end] (لقطة تاريخية — للمكاتب فقط).
  static bool isUnreceivedAsOf(TransactionModel t, DateTime end) {
    if (t.date.isAfter(end)) return false;
    final receivedBefore = t.receivedAt != null && !t.receivedAt!.isAfter(end);
    final cancelledBefore =
        t.cancelledAt != null && !t.cancelledAt!.isAfter(end);
    return !receivedBefore && !cancelledBefore;
  }

  /// التاريخ الذي تُحسب به الحركة داخل مؤشر معيّن (للعرض في التفاصيل).
  static DateTime momentFor(
    PeriodMetric metric,
    TransactionModel t, {
    required bool company,
  }) {
    if (company) {
      switch (metric) {
        case PeriodMetric.added:
        case PeriodMetric.received:
          return t.date;
        case PeriodMetric.cancelled:
        case PeriodMetric.fourth:
          return companyCancelMoment(t) ?? t.date;
      }
    }
    switch (metric) {
      case PeriodMetric.added:
      case PeriodMetric.fourth:
        return t.date;
      case PeriodMetric.received:
        return t.receivedAt ?? t.date;
      case PeriodMetric.cancelled:
        return t.cancelledAt ?? t.date;
    }
  }

  // ---------------- الحساب ----------------

  /// يقسّم حركات حساب واحد (أو أكثر من نفس النوع) إلى المؤشرات الأربعة.
  static PeriodBuckets compute(
    Iterable<TransactionModel> txs,
    StatsPeriod period, {
    required bool company,
  }) {
    final added = <TransactionModel>[];
    final received = <TransactionModel>[];
    final cancelled = <TransactionModel>[];
    final fourth = <TransactionModel>[];

    if (company) {
      for (final t in txs) {
        final m = t.effectiveCompanyMovement;
        if (m == null) continue; // ليست حركة شركة (بيانات قديمة)

        // الإضافة: بتاريخ الإضافة حتى لو أُلغيت لاحقًا
        if (period.contains(t.date)) {
          if (m.isSent) {
            added.add(t);
          } else {
            received.add(t);
          }
        }

        // الإلغاء: بتاريخ الإلغاء
        if (m.isCancelled && period.contains(companyCancelMoment(t))) {
          if (m.isSent) {
            cancelled.add(t);
          } else {
            fourth.add(t);
          }
        }
      }
    } else {
      for (final t in txs) {
        if (period.contains(t.date)) added.add(t);
        if (t.receivedAt != null && period.contains(t.receivedAt)) {
          received.add(t);
        }
        if (t.cancelledAt != null && period.contains(t.cancelledAt)) {
          cancelled.add(t);
        }
        if (isUnreceivedAsOf(t, period.end)) fourth.add(t);
      }
    }

    int newestFirst(
      PeriodMetric metric,
      TransactionModel a,
      TransactionModel b,
    ) => momentFor(
      metric,
      b,
      company: company,
    ).compareTo(momentFor(metric, a, company: company));

    added.sort((a, b) => newestFirst(PeriodMetric.added, a, b));
    received.sort((a, b) => newestFirst(PeriodMetric.received, a, b));
    cancelled.sort((a, b) => newestFirst(PeriodMetric.cancelled, a, b));
    fourth.sort((a, b) => newestFirst(PeriodMetric.fourth, a, b));

    return PeriodBuckets(
      added: added,
      received: received,
      cancelled: cancelled,
      fourth: fourth,
    );
  }

  // ---------------- التسميات ----------------

  static String label(PeriodMetric m, {required bool company}) {
    if (company) {
      switch (m) {
        case PeriodMetric.added:
          return 'إرسال';
        case PeriodMetric.received:
          return 'استقبال';
        case PeriodMetric.cancelled:
          return 'إلغاء مرسل';
        case PeriodMetric.fourth:
          return 'إلغاء استقبال';
      }
    }
    switch (m) {
      case PeriodMetric.added:
        return 'مضافة';
      case PeriodMetric.received:
        return 'مستلمة';
      case PeriodMetric.cancelled:
        return 'ملغاة';
      case PeriodMetric.fourth:
        return 'غير مستلمة';
    }
  }
}
