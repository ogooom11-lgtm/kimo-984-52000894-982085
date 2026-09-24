// lib/services/operation_log_service.dart
// سجل العمليات: يحفظ كل عملية (إضافة/إلغاء/تغيير حالة/نقل/حذف/تعديل) مع
// لقطة للحركات قبل وبعد، حتى يمكن التراجع عن أي عملية لاحقًا أو فتح الحساب
// وتحديد حركات العملية فيه.

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';

enum OperationKind {
  bubbleAdd,
  bubbleCancel,
  statusChange,
  move,
  delete,
  manualAdd,
  manualEdit,
}

extension OperationKindInfo on OperationKind {
  String get label {
    switch (this) {
      case OperationKind.bubbleAdd:
        return 'إضافة من الفقاعات';
      case OperationKind.bubbleCancel:
        return 'إلغاء من الفقاعات';
      case OperationKind.statusChange:
        return 'تغيير حالة';
      case OperationKind.move:
        return 'نقل حركات';
      case OperationKind.delete:
        return 'حذف حركات';
      case OperationKind.manualAdd:
        return 'إضافة يدوية';
      case OperationKind.manualEdit:
        return 'تعديل حركة';
    }
  }

  /// عمليات تُنشئ حركات جديدة (التراجع = حذفها)
  bool get createsTransactions =>
      this == OperationKind.bubbleAdd || this == OperationKind.manualAdd;

  static OperationKind parse(String? raw) {
    for (final k in OperationKind.values) {
      if (k.name == raw) return k;
    }
    return OperationKind.manualEdit;
  }
}

/// لقطة حركة واحدة ضمن عملية
class OperationTxRecord {
  final int txId;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  const OperationTxRecord({required this.txId, this.before, this.after});

  Map<String, dynamic> get _data => after ?? before ?? const {};

  String get beneficiary => _data['beneficiary']?.toString() ?? '';
  double get amount => _toDouble(_data['amount']);
  String get currency => _data['currency']?.toString() ?? '';
  int get accountId => _toInt(_data['accountId']);
  int? get beforeAccountId =>
      before == null ? null : _toInt(before!['accountId']);

  Map<String, dynamic> toMap() => {
    'txId': txId,
    'before': before,
    'after': after,
  };

  factory OperationTxRecord.fromMap(Map<dynamic, dynamic> map) {
    Map<String, dynamic>? asMap(dynamic v) => v is Map
        ? v.map((key, value) => MapEntry(key.toString(), value))
        : null;
    return OperationTxRecord(
      txId: _toInt(map['txId']),
      before: asMap(map['before']),
      after: asMap(map['after']),
    );
  }
}

class OperationLogEntry {
  final String id;
  final OperationKind kind;
  final DateTime createdAt;
  final String title;
  final String? subtitle;
  final List<OperationTxRecord> records;
  final bool undone;
  final DateTime? undoneAt;

  const OperationLogEntry({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.title,
    this.subtitle,
    required this.records,
    this.undone = false,
    this.undoneAt,
  });

  Set<int> get txIds => records.map((r) => r.txId).toSet();

  Set<int> get accountIds => records.map((r) => r.accountId).toSet();

  /// مجموع المبالغ لكل عملة
  Map<String, double> get totalsByCurrency {
    final out = <String, double>{};
    for (final r in records) {
      if (r.currency.isEmpty) continue;
      out[r.currency] = (out[r.currency] ?? 0) + r.amount;
    }
    return out;
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'kind': kind.name,
    'createdAt': createdAt.toIso8601String(),
    'title': title,
    'subtitle': subtitle,
    'records': records.map((r) => r.toMap()).toList(),
    'undone': undone,
    'undoneAt': undoneAt?.toIso8601String(),
  };

  factory OperationLogEntry.fromMap(Map<dynamic, dynamic> map) {
    final rawRecords = map['records'];
    return OperationLogEntry(
      id: map['id']?.toString() ?? '',
      kind: OperationKindInfo.parse(map['kind']?.toString()),
      createdAt:
          DateTime.tryParse(map['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      title: map['title']?.toString() ?? '',
      subtitle: map['subtitle']?.toString(),
      records: rawRecords is List
          ? rawRecords
                .whereType<Map>()
                .map((m) => OperationTxRecord.fromMap(m))
                .toList()
          : const [],
      undone: map['undone'] == true,
      undoneAt: DateTime.tryParse(map['undoneAt']?.toString() ?? ''),
    );
  }

  OperationLogEntry copyWith({bool? undone, DateTime? undoneAt}) =>
      OperationLogEntry(
        id: id,
        kind: kind,
        createdAt: createdAt,
        title: title,
        subtitle: subtitle,
        records: records,
        undone: undone ?? this.undone,
        undoneAt: undoneAt ?? this.undoneAt,
      );
}

/// نتيجة فحص ما قبل التراجع
class UndoPreview {
  final int total;
  final int missing; // حركات لم تعد موجودة
  final int changed; // حركات تغيّرت بعد العملية

  const UndoPreview({
    required this.total,
    required this.missing,
    required this.changed,
  });

  int get applicable => total - missing;
}

class OperationLogService {
  static const int maxEntries = 400;
  static int _counter = 0;

  static String get boxName => DatabaseService.operationLogBoxName;

  static bool get isReady => Hive.isBoxOpen(boxName);

  static Box<dynamic> get _box => Hive.box<dynamic>(boxName);

  static ValueListenable<Box<dynamic>> listenable() => _box.listenable();

  // ---------------- لقطات الحركات ----------------

  static Map<String, dynamic> snapshot(TransactionModel t) => {
    'id': t.id,
    'accountId': t.accountId,
    'beneficiary': t.beneficiary,
    'amount': t.amount,
    'currency': t.currency,
    'notes': t.notes,
    'status': t.status.name,
    'date': t.date.toIso8601String(),
    'receivedAt': t.receivedAt?.toIso8601String(),
    'cancelledAt': t.cancelledAt?.toIso8601String(),
    'secondAmount': t.secondAmount,
    'secondCurrency': t.secondCurrency,
    'companyMovementType': t.companyMovementType?.name,
  };

  static TransactionStatus _statusFrom(dynamic raw) {
    for (final s in TransactionStatus.values) {
      if (s.name == raw) return s;
    }
    return TransactionStatus.added;
  }

  static CompanyMovementType? _movementFrom(dynamic raw) {
    if (raw == null) return null;
    for (final m in CompanyMovementType.values) {
      if (m.name == raw) return m;
    }
    return null;
  }

  static DateTime? _date(dynamic raw) =>
      raw == null ? null : DateTime.tryParse(raw.toString());

  static TransactionModel fromSnapshot(Map<String, dynamic> m) {
    return TransactionModel(
      id: _toInt(m['id']),
      accountId: _toInt(m['accountId']),
      beneficiary: m['beneficiary']?.toString() ?? '',
      amount: _toDouble(m['amount']),
      currency: m['currency']?.toString() ?? '',
      notes: m['notes']?.toString() ?? '',
      status: _statusFrom(m['status']),
      date: _date(m['date']) ?? DateTime.now(),
      receivedAt: _date(m['receivedAt']),
      cancelledAt: _date(m['cancelledAt']),
      secondAmount: m['secondAmount'] == null
          ? null
          : _toDouble(m['secondAmount']),
      secondCurrency: m['secondCurrency']?.toString(),
      companyMovementType: _movementFrom(m['companyMovementType']),
    );
  }

  static void _applySnapshot(TransactionModel t, Map<String, dynamic> m) {
    t
      ..accountId = _toInt(m['accountId'])
      ..beneficiary = m['beneficiary']?.toString() ?? t.beneficiary
      ..amount = _toDouble(m['amount'])
      ..currency = m['currency']?.toString() ?? t.currency
      ..notes = m['notes']?.toString() ?? ''
      ..status = _statusFrom(m['status'])
      ..date = _date(m['date']) ?? t.date
      ..receivedAt = _date(m['receivedAt'])
      ..cancelledAt = _date(m['cancelledAt'])
      ..secondAmount = m['secondAmount'] == null
          ? null
          : _toDouble(m['secondAmount'])
      ..secondCurrency = m['secondCurrency']?.toString()
      ..companyMovementType = _movementFrom(m['companyMovementType']);
  }

  static bool _sameAsSnapshot(TransactionModel t, Map<String, dynamic>? m) {
    if (m == null) return true;
    final now = snapshot(t);
    for (final key in const [
      'accountId',
      'beneficiary',
      'amount',
      'currency',
      'status',
      'receivedAt',
      'cancelledAt',
      'secondAmount',
      'secondCurrency',
      'companyMovementType',
    ]) {
      final a = now[key];
      final b = m[key];
      if (a is num && b is num) {
        if ((a - b).abs() > 0.0001) return false;
      } else if ((a?.toString() ?? '') != (b?.toString() ?? '')) {
        return false;
      }
    }
    return true;
  }

  // ---------------- التسجيل ----------------

  static Future<OperationLogEntry?> log({
    required OperationKind kind,
    required String title,
    String? subtitle,
    required List<OperationTxRecord> records,
  }) async {
    if (!isReady || records.isEmpty) return null;
    try {
      final now = DateTime.now();
      _counter = (_counter + 1) % 100000;
      final id =
          'op_${now.millisecondsSinceEpoch.toString().padLeft(15, '0')}'
          '_${_counter.toString().padLeft(5, '0')}';
      final entry = OperationLogEntry(
        id: id,
        kind: kind,
        createdAt: now,
        title: title,
        subtitle: subtitle,
        records: records,
      );
      await _box.put(id, entry.toMap());
      await _prune();
      return entry;
    } catch (e) {
      debugPrint('OperationLogService.log error: $e');
      return null;
    }
  }

  static Future<void> _prune() async {
    if (_box.length <= maxEntries) return;
    final keys = _box.keys.map((k) => k.toString()).toList()..sort();
    final extra = keys.length - maxEntries;
    if (extra <= 0) return;
    await _box.deleteAll(keys.take(extra));
  }

  // ---------------- القراءة ----------------

  static List<OperationLogEntry> entries() {
    if (!isReady) return const [];
    final list = <OperationLogEntry>[];
    for (final v in _box.values) {
      if (v is Map) {
        try {
          list.add(OperationLogEntry.fromMap(v));
        } catch (_) {}
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static Map<int, TransactionModel> _txById() => {
    for (final t in DatabaseService.transactionsBox.values) t.id: t,
  };

  /// الحركات الموجودة حاليًا من حركات العملية
  static List<TransactionModel> currentTransactions(OperationLogEntry e) {
    final byId = _txById();
    return [
      for (final id in e.txIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  // ---------------- التراجع ----------------

  static UndoPreview previewUndo(OperationLogEntry e) {
    final byId = _txById();
    int missing = 0;
    int changed = 0;
    for (final r in e.records) {
      final tx = byId[r.txId];
      if (e.kind == OperationKind.delete) {
        if (tx != null) missing++; // موجودة أصلًا، لا حاجة لاستعادتها
        continue;
      }
      if (tx == null) {
        missing++;
        continue;
      }
      if (!_sameAsSnapshot(tx, r.after)) changed++;
    }
    return UndoPreview(
      total: e.records.length,
      missing: missing,
      changed: changed,
    );
  }

  /// ينفّذ التراجع ويعيد عدد الحركات التي تأثرت
  static Future<int> undo(
    OperationLogEntry e, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (e.undone) return 0;
    final stored = _box.get(e.id);
    if (stored is Map && stored['undone'] == true) return 0;
    final byId = _txById();
    int affected = 0;
    final total = e.records.length;
    for (int i = 0; i < total; i++) {
      final r = e.records[i];
      final tx = byId[r.txId];
      if (e.kind.createsTransactions) {
        if (tx != null) {
          await tx.delete();
          affected++;
        }
      } else if (e.kind == OperationKind.delete) {
        if (tx == null && r.before != null) {
          await DatabaseService.addTransaction(fromSnapshot(r.before!));
          affected++;
        }
      } else {
        if (tx != null && r.before != null) {
          _applySnapshot(tx, r.before!);
          await tx.save();
          affected++;
        }
      }
      onProgress?.call(i + 1, total);
    }
    await _box.put(
      e.id,
      e.copyWith(undone: true, undoneAt: DateTime.now()).toMap(),
    );
    return affected;
  }

  static Future<void> deleteEntry(String id) async {
    if (!isReady) return;
    await _box.delete(id);
  }

  static Future<void> clear() async {
    if (!isReady) return;
    await _box.clear();
  }
}

double _toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0.0;
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}
