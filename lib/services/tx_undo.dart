// lib/services/tx_undo.dart
// -------------------------------------------------------------
// التراجع عن آخر تعديل للحركة وعن التسليم والإلغاء.
//  • شكل الحركة قبل آخر تعديل (من صفحة التعديل) بينحفظ بصندوق صغير
//    (tx_undo) مفتاحه رقم الحركة، فالتراجع بيضل متاح حتى لو تسكّر التطبيق،
//    ومرة وحدة لكل تعديل.
//  • التسليم والإلغاء: بعدهن مباشرة التراجع بيرجّع الحالة متل ما كانت
//    بالضبط، ولاحقًا «تراجع عن التسليم/الإلغاء» بيرجّع الحركة مضافة (وحركة
//    الشركة لنوعها: إرسال أو استقبال).
// -------------------------------------------------------------

import 'package:hive/hive.dart';

import '../database_service.dart';
import '../models.dart';

/// حقول الحركة اللي بتتغير من صفحة التعديل
class TxEditSnapshot {
  final String beneficiary;
  final double amount;
  final String currency;
  final double? secondAmount;
  final String? secondCurrency;
  final DateTime date;
  final CompanyMovementType? companyMovementType;
  final String? destination;

  const TxEditSnapshot({
    required this.beneficiary,
    required this.amount,
    required this.currency,
    this.secondAmount,
    this.secondCurrency,
    required this.date,
    this.companyMovementType,
    this.destination,
  });

  factory TxEditSnapshot.of(TransactionModel t) => TxEditSnapshot(
    beneficiary: t.beneficiary,
    amount: t.amount,
    currency: t.currency,
    secondAmount: t.secondAmount,
    secondCurrency: t.secondCurrency,
    date: t.date,
    companyMovementType: t.companyMovementType,
    destination: t.destination,
  );

  void applyTo(TransactionModel t) {
    t.beneficiary = beneficiary;
    t.amount = amount;
    t.currency = currency;
    t.secondAmount = secondAmount;
    t.secondCurrency = secondCurrency;
    t.date = date;
    t.companyMovementType = companyMovementType;
    t.destination = destination;
  }

  /// نفس القيم؟ (عملة المبلغ الثاني ما إلها معنى بدون مبلغ ثاني)
  bool sameAs(TxEditSnapshot o) =>
      beneficiary == o.beneficiary &&
      amount == o.amount &&
      currency == o.currency &&
      secondAmount == o.secondAmount &&
      (secondAmount == null || secondCurrency == o.secondCurrency) &&
      date.millisecondsSinceEpoch == o.date.millisecondsSinceEpoch &&
      companyMovementType == o.companyMovementType &&
      (destination ?? '') == (o.destination ?? '');

  Map<String, dynamic> toMap() => {
    'b': beneficiary,
    'a': amount,
    'c': currency,
    'a2': secondAmount,
    'c2': secondCurrency,
    'd': date.millisecondsSinceEpoch,
    'm': companyMovementType?.name,
    'dest': destination,
  };

  static TxEditSnapshot? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final b = raw['b'];
    final a = raw['a'];
    final c = raw['c'];
    final d = raw['d'];
    if (b is! String || a is! num || c is! String || d is! int) return null;

    CompanyMovementType? movement;
    final m = raw['m'];
    if (m != null) {
      for (final v in CompanyMovementType.values) {
        if (v.name == m) movement = v;
      }
      // نوع غير معروف: ما منرجّع شي غلط
      if (movement == null) return null;
    }

    final a2 = raw['a2'];
    final c2 = raw['c2'];
    final dest = raw['dest'];
    return TxEditSnapshot(
      beneficiary: b,
      amount: a.toDouble(),
      currency: c,
      secondAmount: a2 is num ? a2.toDouble() : null,
      secondCurrency: c2 is String ? c2 : null,
      date: DateTime.fromMillisecondsSinceEpoch(d),
      companyMovementType: movement,
      destination: dest is String ? dest : null,
    );
  }
}

/// حالة الحركة قبل التسليم أو الإلغاء (للتراجع الفوري)
class TxStatusSnapshot {
  final TransactionStatus status;
  final DateTime? receivedAt;
  final DateTime? cancelledAt;

  /// حركات الشركات: الإلغاء جزء من نوع الحركة
  final CompanyMovementType? companyMovementType;

  const TxStatusSnapshot(
    this.status,
    this.receivedAt,
    this.cancelledAt, [
    this.companyMovementType,
  ]);

  factory TxStatusSnapshot.of(TransactionModel t) => TxStatusSnapshot(
    t.status,
    t.receivedAt,
    t.cancelledAt,
    t.companyMovementType,
  );

  void applyTo(TransactionModel t) {
    t.status = status;
    t.receivedAt = receivedAt;
    t.cancelledAt = cancelledAt;
    t.companyMovementType = companyMovementType;
  }
}

class TxUndo {
  TxUndo._();

  /// أقصى عدد حركات محفوظ إلها تراجع عن التعديل (الأقدم بينحذف)
  static const int maxEntries = 300;

  static Box<dynamic>? get _box => Hive.isBoxOpen(DatabaseService.txUndoBoxName)
      ? Hive.box<dynamic>(DatabaseService.txUndoBoxName)
      : null;

  static String _key(int txId) => '$txId';

  // ===========================
  // التعديل
  // ===========================

  /// في تعديل فينا نتراجع عنه؟
  static bool canUndoEdit(int txId) => _box?.containsKey(_key(txId)) ?? false;

  /// يحفظ شكل الحركة قبل آخر تعديل
  static Future<void> rememberEdit(int txId, TxEditSnapshot before) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(_key(txId), {
        'at': DateTime.now().millisecondsSinceEpoch,
        'edit': before.toMap(),
      });
      if (box.length > maxEntries) await _trim(box);
    } catch (_) {}
  }

  static Future<void> _trim(Box<dynamic> box) async {
    int atOf(dynamic key) {
      final v = box.get(key);
      final at = v is Map ? v['at'] : null;
      return at is int ? at : 0;
    }

    final keys = box.keys.toList()..sort((a, b) => atOf(a).compareTo(atOf(b)));
    final extra = keys.length - maxEntries;
    if (extra > 0) await box.deleteAll(keys.take(extra));
  }

  /// يرجّع الحركة متل ما كانت قبل آخر تعديل (مرة وحدة)
  static Future<bool> undoEdit(TransactionModel t) async {
    final box = _box;
    if (box == null) return false;
    final key = _key(t.id);
    final raw = box.get(key);
    final before = raw is Map ? TxEditSnapshot.fromMap(raw['edit']) : null;
    if (before == null || !t.isInBox) {
      await box.delete(key);
      return false;
    }
    before.applyTo(t);
    await t.save();
    await box.delete(key);
    return true;
  }

  // ===========================
  // التسليم
  // ===========================

  /// حركة مكتب مسلّمة؟
  static bool isDelivered(TransactionModel t) =>
      t.companyMovementType == null && t.status == TransactionStatus.received;

  /// يسلّم الحركة ويرجّع حالتها قبل التسليم (للتراجع الفوري)
  static Future<TxStatusSnapshot> deliver(
    TransactionModel t, {
    DateTime? at,
  }) async {
    final before = TxStatusSnapshot.of(t);
    t.applyStatus(TransactionStatus.received, at: at);
    await t.save();
    return before;
  }

  /// التراجع الفوري: الحالة بترجع متل ما كانت بالضبط
  static Future<void> restoreStatus(
    TransactionModel t,
    TxStatusSnapshot before,
  ) async {
    if (!t.isInBox) return;
    before.applyTo(t);
    await t.save();
  }

  /// «تراجع عن التسليم» لاحقًا: الحركة بترجع مضافة
  static Future<void> undoDelivery(TransactionModel t) async {
    if (!t.isInBox) return;
    t.applyStatus(TransactionStatus.added);
    await t.save();
  }

  // ===========================
  // الإلغاء
  // ===========================

  /// الحركة ملغاة؟ (مكتب أو شركة)
  static bool isCancelled(TransactionModel t) => t.companyMovementType != null
      ? (t.effectiveCompanyMovement?.isCancelled ?? false)
      : t.status == TransactionStatus.cancelled;

  /// يلغي الحركة ويرجّع حالتها قبل الإلغاء (للتراجع الفوري). [company] =
  /// الحركة بحساب شركة: الإلغاء بيصير جزء من نوع الحركة حتى تنحسب
  /// بالإحصائيات بتاريخ إلغائها.
  static Future<TxStatusSnapshot> cancel(
    TransactionModel t, {
    required bool company,
  }) async {
    final before = TxStatusSnapshot.of(t);
    final movement = t.companyMovementType;
    if (company && movement != null) {
      // ما منغيّر تاريخ الإلغاء لحركة ملغاة من قبل
      if (!(t.effectiveCompanyMovement?.isCancelled ?? false) ||
          t.cancelledAt == null) {
        t.cancelledAt = DateTime.now();
      }
      t.companyMovementType = movement.cancelled;
    } else if (t.status != TransactionStatus.cancelled ||
        t.cancelledAt == null) {
      // نفس الشي: حركة ملغاة من قبل بيضل تاريخ إلغائها
      t.applyStatus(TransactionStatus.cancelled);
    }
    await t.save();
    return before;
  }

  /// «تراجع عن الإلغاء» لاحقًا: المكتب بترجع مضافة، والشركة بترجع لنوعها
  /// (إرسال أو استقبال)
  static Future<void> undoCancel(TransactionModel t) async {
    if (!t.isInBox) return;
    final movement = t.companyMovementType;
    if (movement != null) {
      t.companyMovementType = movement.isSent
          ? CompanyMovementType.sent
          : CompanyMovementType.received;
      t.status = TransactionStatus.added;
      t.receivedAt = null;
      t.cancelledAt = null;
    } else {
      t.applyStatus(TransactionStatus.added);
    }
    await t.save();
  }
}
