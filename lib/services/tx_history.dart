// lib/services/tx_history.dart
// -------------------------------------------------------------
// سجل تعديلات الحركة: النماذج + حساب الفروقات بين حالتين للحركة + صياغة
// أسطر العرض والنسخ بالعربية («تم تعديل المبلغ من 100 دولار إلى 150 دولار»).
//
// ملف Dart نقي (بدون Flutter) حتى يمكن اختباره مباشرة. الربط مع Hive ومراقبة
// صندوق الحركات في tx_history_service.dart.
// -------------------------------------------------------------

import '../models.dart';

/// حقول الحركة التي يتابعها السجل (الترتيب = ترتيب اللقطة).
enum TxField {
  beneficiary,
  amount,
  currency,
  secondAmount,
  secondCurrency,
  notes,
  date,
  status,
  receivedAt,
  cancelledAt,
  accountId,
  companyMovementType,
}

extension TxFieldInfo on TxField {
  /// حقول تخص الحالة (تسليم/إلغاء/نوع حركة الشركة)
  bool get isStatusField =>
      this == TxField.status ||
      this == TxField.receivedAt ||
      this == TxField.cancelledAt ||
      this == TxField.companyMovementType;

  bool get isDateField =>
      this == TxField.date ||
      this == TxField.receivedAt ||
      this == TxField.cancelledAt;

  static TxField? parse(Object? raw) {
    for (final f in TxField.values) {
      if (f.name == raw) return f;
    }
    return null;
  }
}

enum TxHistoryKind { edit, deleted, restored }

TxHistoryKind _kindFrom(Object? raw) {
  for (final k in TxHistoryKind.values) {
    if (k.name == raw) return k;
  }
  return TxHistoryKind.edit;
}

/// تغيير حقل واحد: القيمة القديمة والجديدة (قيم خام: نص/رقم/تاريخ ISO/اسم حالة).
class TxFieldChange {
  final TxField field;
  final Object? oldValue;
  final Object? newValue;

  /// أسماء للعرض وقت التسجيل (مثل اسم الحساب قبل النقل وبعده)
  final String? oldLabel;
  final String? newLabel;

  const TxFieldChange(
    this.field,
    this.oldValue,
    this.newValue, {
    this.oldLabel,
    this.newLabel,
  });

  Map<String, dynamic> toMap() => {
    'f': field.name,
    'o': oldValue,
    'n': newValue,
    if (oldLabel != null) 'ol': oldLabel,
    if (newLabel != null) 'nl': newLabel,
  };

  static TxFieldChange? fromMap(Map<dynamic, dynamic> m) {
    final f = TxFieldInfo.parse(m['f']);
    if (f == null) return null;
    return TxFieldChange(
      f,
      m['o'],
      m['n'],
      oldLabel: m['ol']?.toString(),
      newLabel: m['nl']?.toString(),
    );
  }

  @override
  String toString() => 'TxFieldChange(${field.name}: $oldValue → $newValue)';
}

/// إدخال واحد في سجل الحركة.
class TxHistoryEntry {
  final DateTime at;
  final TxHistoryKind kind;

  /// مصدر التعديل إن عُرف (تعديل يدوي، صفحة التسليم، تراجع...)
  final String? source;
  final List<TxFieldChange> changes;

  /// سياق للعرض: العملة بعد التعديل (c) وعملة المبلغ الثاني (c2)، أو ملخص
  /// الحركة عند الحذف (name / amount).
  final Map<String, dynamic> ctx;

  const TxHistoryEntry({
    required this.at,
    required this.kind,
    this.source,
    this.changes = const [],
    this.ctx = const {},
  });

  Map<String, dynamic> toMap() => {
    'at': at.toIso8601String(),
    'k': kind.name,
    if (source != null) 's': source,
    if (changes.isNotEmpty) 'ch': [for (final c in changes) c.toMap()],
    if (ctx.isNotEmpty) 'ctx': ctx,
  };

  factory TxHistoryEntry.fromMap(Map<dynamic, dynamic> m) {
    final rawChanges = m['ch'];
    final rawCtx = m['ctx'];
    return TxHistoryEntry(
      at:
          TxHistoryFormatter.parseDate(m['at']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      kind: _kindFrom(m['k']),
      source: m['s']?.toString(),
      changes: rawChanges is List
          ? [
              for (final c in rawChanges)
                if (c is Map) ?TxFieldChange.fromMap(c),
            ]
          : const [],
      ctx: rawCtx is Map
          ? rawCtx.map((k, v) => MapEntry(k.toString(), v))
          : const {},
    );
  }

  bool has(TxField f) => changes.any((c) => c.field == f);

  /// يمس الحالة: تسليم/إلغاء/إرجاع/نوع حركة الشركة/حذف/استعادة
  bool get touchesStatus =>
      kind != TxHistoryKind.edit || changes.any((c) => c.field.isStatusField);

  /// يمس بيانات الحركة: الاسم/المبالغ/العملات/الملاحظات/التاريخ/الحساب
  bool get touchesData =>
      kind == TxHistoryKind.edit && changes.any((c) => !c.field.isStatusField);
}

/// الإدخالات من الأحدث إلى الأقدم حسب وقتها (قد يحمل الإدخال وقت الرسالة لا
/// وقت الحفظ)؛ عند تساوي الوقت يبقى ترتيب التسجيل.
List<TxHistoryEntry> sortEntriesByTime(List<TxHistoryEntry> newestFirst) {
  final indexed = [
    for (var i = 0; i < newestFirst.length; i++) (i, newestFirst[i]),
  ];
  indexed.sort((a, b) {
    final c = b.$2.at.compareTo(a.$2.at);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

// =============================================================
// القيم السابقة (البحث في سجل التعديل)
// =============================================================

/// حالة سابقة للحركة: الاسم والمبلغ والعملة كما كانت قبل تعديلٍ ما.
class TxPastState {
  final String name;
  final double amount;
  final String currency;

  /// وقت التعديل الذي غيّر هذه القيم
  final DateTime changedAt;

  const TxPastState({
    required this.name,
    required this.amount,
    required this.currency,
    required this.changedAt,
  });

  @override
  String toString() => 'TxPastState($name, $amount $currency)';
}

/// يعيد بناء الأسماء والمبالغ والعملات السابقة للحركة بالتراجع عن تعديلاتها
/// واحدًا واحدًا (من الأحدث إلى الأقدم) ابتداءً من قيمها الحالية.
/// [newestFirst] بترتيب التسجيل كما يعيده TxHistoryService.entriesFor.
/// لا تُعاد الحالة الحالية ولا الحالات المكررة.
List<TxPastState> txPastStates(
  List<TxHistoryEntry> newestFirst, {
  required String name,
  required double amount,
  required String currency,
}) {
  var n = name.trim();
  var a = amount;
  var c = currency.trim();
  String key() => '$n|${a.toStringAsFixed(4)}|$c';
  final seen = <String>{key()};
  final out = <TxPastState>[];
  for (final e in newestFirst) {
    if (e.kind != TxHistoryKind.edit) continue;
    var touched = false;
    for (final ch in e.changes) {
      switch (ch.field) {
        case TxField.beneficiary:
          final v = _text(ch.oldValue);
          if (v.isNotEmpty) {
            n = v;
            touched = true;
          }
        case TxField.amount:
          final v = ch.oldValue;
          if (v is num && v > 0) {
            a = v.toDouble();
            touched = true;
          }
        case TxField.currency:
          final v = _text(ch.oldValue);
          if (v.isNotEmpty) {
            c = v;
            touched = true;
          }
        default:
          break;
      }
    }
    if (!touched || !seen.add(key())) continue;
    out.add(TxPastState(name: n, amount: a, currency: c, changedAt: e.at));
  }
  return out;
}

// =============================================================
// اللقطات والفروقات
// =============================================================

/// لقطة مختصرة لحقول الحركة بترتيب [TxField] (القيم نفسها بدون نسخ: النصوص
/// والتواريخ غير قابلة للتغيير).
List<Object?> txSnapshot(TransactionModel t) => [
  t.beneficiary,
  t.amount,
  t.currency,
  t.secondAmount,
  t.secondCurrency,
  t.notes,
  t.date,
  t.status.name,
  t.receivedAt,
  t.cancelledAt,
  t.accountId,
  t.companyMovementType?.name,
];

/// التواريخ تُقارن بالميلي ثانية (Hive يحفظها بهذه الدقة)
int? _millis(Object? v) {
  if (v is DateTime) return v.millisecondsSinceEpoch;
  if (v is int) return v;
  return null;
}

bool _noAmount(Object? v) => v == null || (v is num && v.abs() < 1e-9);

String _text(Object? v) => v?.toString().trim() ?? '';

bool _sameValue(TxField f, Object? x, Object? y) {
  switch (f) {
    case TxField.amount:
    case TxField.secondAmount:
      if (_noAmount(x) && _noAmount(y)) return true;
      if (x is num && y is num) return (x - y).abs() < 1e-6;
      return false;
    case TxField.beneficiary:
    case TxField.currency:
    case TxField.secondCurrency:
    case TxField.notes:
      return _text(x) == _text(y);
    case TxField.date:
    case TxField.receivedAt:
    case TxField.cancelledAt:
      return _millis(x) == _millis(y);
    default:
      return x == y;
  }
}

Object? _exportValue(TxField f, Object? v) {
  if (v is DateTime) return v.toIso8601String();
  if (f.isDateField && v is int) {
    return DateTime.fromMillisecondsSinceEpoch(v).toIso8601String();
  }
  if (f == TxField.secondAmount && _noAmount(v)) return null;
  return v;
}

/// الفروقات بين لقطتين. [accountLabel] يعطي اسم الحساب لتسجيله مع النقل.
List<TxFieldChange> diffTxSnapshots(
  List<Object?> before,
  List<Object?> after, {
  String? Function(int accountId)? accountLabel,
}) {
  final out = <TxFieldChange>[];
  // عملة المبلغ الثاني لا معنى لها إذا لم يوجد مبلغ ثانٍ قبل التعديل ولا بعده
  final noSecond =
      _noAmount(before[TxField.secondAmount.index]) &&
      _noAmount(after[TxField.secondAmount.index]);
  for (final f in TxField.values) {
    final x = before[f.index];
    final y = after[f.index];
    if (f == TxField.secondCurrency && noSecond) continue;
    if (_sameValue(f, x, y)) continue;
    if (f == TxField.accountId) {
      out.add(
        TxFieldChange(
          f,
          x,
          y,
          oldLabel: x is int ? accountLabel?.call(x) : null,
          newLabel: y is int ? accountLabel?.call(y) : null,
        ),
      );
    } else {
      out.add(TxFieldChange(f, _exportValue(f, x), _exportValue(f, y)));
    }
  }
  return out;
}

/// وقت إنشاء الحركة من معرّفها (المعرّف = وقت الإنشاء بالميلي ثانية)، إن كان
/// المعرّف يبدو كذلك.
DateTime? txCreationTimeFromId(int id) {
  final min = DateTime(2015).millisecondsSinceEpoch;
  final max = DateTime.now()
      .add(const Duration(days: 2))
      .millisecondsSinceEpoch;
  if (id < min || id > max) return null;
  return DateTime.fromMillisecondsSinceEpoch(id);
}

// =============================================================
// الصياغة للعرض والنسخ
// =============================================================

enum TxRowKind {
  status,
  movement,
  account,
  name,
  money,
  secondMoney,
  date,
  receivedAt,
  cancelledAt,
  notes,
  deleted,
  restored,
}

/// طابع الإدخال (لاختيار اللون والأيقونة في الواجهة)
enum TxEntryTone {
  edit,
  received,
  cancelled,
  added,
  moved,
  movement,
  deleted,
  restored,
}

/// سطر عرض واحد: «تم تعديل المبلغ» من «100 دولار» إلى «150 دولار».
class TxChangeRow {
  final TxRowKind kind;
  final String label;
  final String? from;
  final String? to;

  /// معلومة إضافية (مثل تاريخ التسليم عند تغيير الحالة)
  final String? extra;

  /// القيم الخام للحالة/نوع الحركة (لتلوين الشارات)
  final String? fromTag;
  final String? toTag;

  const TxChangeRow({
    required this.kind,
    required this.label,
    this.from,
    this.to,
    this.extra,
    this.fromTag,
    this.toTag,
  });

  /// الجملة الكاملة للنسخ
  String get sentence {
    final b = StringBuffer(label);
    if (from != null) b.write(' من $from');
    if (to != null) b.write(' إلى $to');
    if (extra != null) b.write(' ($extra)');
    return b.toString();
  }

  @override
  String toString() => sentence;
}

class TxHistoryFormatter {
  /// اسم الحساب الحالي من معرّفه (احتياط إذا لم يُسجَّل الاسم وقت النقل)
  final String? Function(int accountId)? accountNameOf;

  const TxHistoryFormatter({this.accountNameOf});

  static const String none = 'لا يوجد';

  static String statusLabel(Object? raw) {
    switch (raw?.toString()) {
      case 'added':
        return 'مضافة';
      case 'received':
        return 'مستلمة';
      case 'cancelled':
        return 'ملغية';
    }
    return raw == null ? none : raw.toString();
  }

  static CompanyMovementType? movementOf(Object? raw) {
    for (final m in CompanyMovementType.values) {
      if (m.name == raw) return m;
    }
    return null;
  }

  static String movementLabel(Object? raw) =>
      movementOf(raw)?.label ?? (raw == null ? none : raw.toString());

  /// 1250000 → 1.250.000 ، 1250000.5 → 1.250.000,5 (نفس تنسيق شاشة الحساب)
  static String amount(Object? raw) {
    final v = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
    if (!v.isFinite) return '0';
    final fixed = v.abs().toStringAsFixed(2);
    final parts = fixed.split('.');
    final intPart = parts.first;
    final dec = parts.length > 1
        ? parts[1].replaceFirst(RegExp(r'0+$'), '')
        : '';
    final b = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) b.write('.');
      b.write(intPart[i]);
    }
    final s = dec.isEmpty ? b.toString() : '$b,$dec';
    return v < 0 ? '-$s' : s;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String day(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  static String dateTime(DateTime d) => '${day(d)} ${time(d)}';

  static DateTime? parseDate(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return DateTime.tryParse(raw.toString());
  }

  static String _dateOrNone(Object? raw) {
    final d = parseDate(raw);
    return d == null ? none : dateTime(d);
  }

  /// قيمتا تاريخ للعرض؛ إذا تطابقتا بالدقيقة نُظهر الثواني حتى يتضح الفرق
  static (String, String) _datePair(Object? a, Object? b) {
    final da = parseDate(a);
    final db = parseDate(b);
    final fa = da == null ? none : dateTime(da);
    final fb = db == null ? none : dateTime(db);
    if (fa == fb && da != null && db != null) {
      return ('$fa:${_two(da.second)}', '$fb:${_two(db.second)}');
    }
    return (fa, fb);
  }

  static String _textOr(Object? raw, String empty) {
    final t = _text(raw);
    return t.isEmpty ? empty : t;
  }

  static bool _isCancelledMovement(Object? raw) =>
      movementOf(raw)?.isCancelled ?? false;

  String _accountName(Object? id, String? label) {
    if (label != null && label.trim().isNotEmpty) return label;
    if (id is int) {
      final n = accountNameOf?.call(id);
      if (n != null && n.trim().isNotEmpty) return n;
      return 'حساب #$id';
    }
    return none;
  }

  /// أسطر العرض لإدخال واحد (مع دمج المبلغ وعملته، وطيّ تواريخ التسليم/الإلغاء
  /// داخل سطر تغيير الحالة).
  List<TxChangeRow> rows(TxHistoryEntry e) {
    switch (e.kind) {
      case TxHistoryKind.deleted:
        final name = _text(e.ctx['name']);
        final amt = e.ctx['amount'];
        final cur = _text(e.ctx['c']);
        return [
          TxChangeRow(
            kind: TxRowKind.deleted,
            label: 'تم حذف الحركة',
            extra: name.isEmpty
                ? null
                : '$name${amt is num ? ' • ${amount(amt)} $cur' : ''}',
          ),
        ];
      case TxHistoryKind.restored:
        return const [
          TxChangeRow(kind: TxRowKind.restored, label: 'تمت استعادة الحركة'),
        ];
      case TxHistoryKind.edit:
        break;
    }

    final by = {for (final c in e.changes) c.field: c};
    final out = <TxChangeRow>[];
    final curAfter = _text(e.ctx['c']);
    final cur2After = _text(e.ctx['c2']);

    // الحالة (مع تاريخ التسليم/الإلغاء المرافق)
    final st = by[TxField.status];
    final mv = by[TxField.companyMovementType];
    final received = by[TxField.receivedAt];
    final cancelled = by[TxField.cancelledAt];
    if (st != null) {
      final to = st.newValue?.toString();
      String? extra;
      if (to == 'received' && received?.newValue != null) {
        extra = 'تاريخ التسليم: ${_dateOrNone(received!.newValue)}';
      } else if (to == 'cancelled' && cancelled?.newValue != null) {
        extra = 'تاريخ الإلغاء: ${_dateOrNone(cancelled!.newValue)}';
      }
      out.add(
        TxChangeRow(
          kind: TxRowKind.status,
          label: 'تم تغيير الحالة',
          from: statusLabel(st.oldValue),
          to: statusLabel(to),
          extra: extra,
          fromTag: st.oldValue?.toString(),
          toTag: to,
        ),
      );
    }
    if (mv != null) {
      String? extra;
      if (_isCancelledMovement(mv.newValue) && cancelled?.newValue != null) {
        extra = 'تاريخ الإلغاء: ${_dateOrNone(cancelled!.newValue)}';
      }
      out.add(
        TxChangeRow(
          kind: TxRowKind.movement,
          label: 'تم تغيير نوع الحركة',
          from: movementLabel(mv.oldValue),
          to: movementLabel(mv.newValue),
          extra: extra,
          fromTag: mv.oldValue?.toString(),
          toTag: mv.newValue?.toString(),
        ),
      );
    }

    // النقل بين الحسابات
    final acc = by[TxField.accountId];
    if (acc != null) {
      out.add(
        TxChangeRow(
          kind: TxRowKind.account,
          label: 'تم نقل الحركة',
          from: _accountName(acc.oldValue, acc.oldLabel),
          to: _accountName(acc.newValue, acc.newLabel),
        ),
      );
    }

    // الاسم
    final name = by[TxField.beneficiary];
    if (name != null) {
      out.add(
        TxChangeRow(
          kind: TxRowKind.name,
          label: 'تم تعديل الاسم',
          from: _textOr(name.oldValue, none),
          to: _textOr(name.newValue, none),
        ),
      );
    }

    // المبلغ الأول وعملته
    final a1 = by[TxField.amount];
    final c1 = by[TxField.currency];
    if (a1 != null && c1 != null) {
      out.add(
        TxChangeRow(
          kind: TxRowKind.money,
          label: 'تم تعديل المبلغ والعملة',
          from: '${amount(a1.oldValue)} ${_text(c1.oldValue)}'.trim(),
          to: '${amount(a1.newValue)} ${_text(c1.newValue)}'.trim(),
        ),
      );
    } else if (a1 != null) {
      out.add(
        TxChangeRow(
          kind: TxRowKind.money,
          label: 'تم تعديل المبلغ',
          from: '${amount(a1.oldValue)} $curAfter'.trim(),
          to: '${amount(a1.newValue)} $curAfter'.trim(),
        ),
      );
    } else if (c1 != null) {
      out.add(
        TxChangeRow(
          kind: TxRowKind.money,
          label: 'تم تعديل العملة',
          from: _textOr(c1.oldValue, none),
          to: _textOr(c1.newValue, none),
        ),
      );
    }

    // المبلغ الثاني وعملته (بدون عملة ثانية = نفس عملة المبلغ الأول)
    final a2 = by[TxField.secondAmount];
    final c2 = by[TxField.secondCurrency];
    if (a2 != null || c2 != null) {
      final firstOld = c1 != null ? _text(c1.oldValue) : curAfter;
      final oldCur = c2 != null ? _text(c2.oldValue) : cur2After;
      final newCur = c2 != null ? _text(c2.newValue) : cur2After;
      String money2(Object? v, String cur, String fallback) => _noAmount(v)
          ? none
          : '${amount(v)} ${cur.isEmpty ? fallback : cur}'.trim();
      if (a2 == null) {
        out.add(
          TxChangeRow(
            kind: TxRowKind.secondMoney,
            label: 'تم تعديل عملة المبلغ الثاني',
            from: oldCur.isEmpty ? firstOld : oldCur,
            to: newCur.isEmpty ? curAfter : newCur,
          ),
        );
      } else {
        final oldNone = _noAmount(a2.oldValue);
        final newNone = _noAmount(a2.newValue);
        final label = oldNone && !newNone
            ? 'تمت إضافة مبلغ ثانٍ'
            : (!oldNone && newNone
                  ? 'تم حذف المبلغ الثاني'
                  : (c2 != null
                        ? 'تم تعديل المبلغ الثاني وعملته'
                        : 'تم تعديل المبلغ الثاني'));
        out.add(
          TxChangeRow(
            kind: TxRowKind.secondMoney,
            label: label,
            from: money2(a2.oldValue, oldCur, firstOld),
            to: money2(a2.newValue, newCur, curAfter),
          ),
        );
      }
    }

    // تاريخ الحركة
    final date = by[TxField.date];
    if (date != null) {
      final (from, to) = _datePair(date.oldValue, date.newValue);
      out.add(
        TxChangeRow(
          kind: TxRowKind.date,
          label: 'تم تعديل تاريخ الحركة',
          from: from,
          to: to,
        ),
      );
    }

    // تعديل تاريخ التسليم/الإلغاء بدون تغيير الحالة
    if (received != null && st == null) {
      final (from, to) = _datePair(received.oldValue, received.newValue);
      out.add(
        TxChangeRow(
          kind: TxRowKind.receivedAt,
          label: 'تم تعديل تاريخ التسليم',
          from: from,
          to: to,
        ),
      );
    }
    if (cancelled != null && st == null && mv == null) {
      final (from, to) = _datePair(cancelled.oldValue, cancelled.newValue);
      out.add(
        TxChangeRow(
          kind: TxRowKind.cancelledAt,
          label: 'تم تعديل تاريخ الإلغاء',
          from: from,
          to: to,
        ),
      );
    }

    // الملاحظات
    final notes = by[TxField.notes];
    if (notes != null) {
      out.add(
        TxChangeRow(
          kind: TxRowKind.notes,
          label: 'تم تعديل الملاحظات',
          from: _textOr(notes.oldValue, 'فارغة'),
          to: _textOr(notes.newValue, 'فارغة'),
        ),
      );
    }
    return out;
  }

  /// عنوان الإدخال
  String title(TxHistoryEntry e) {
    switch (e.kind) {
      case TxHistoryKind.deleted:
        return 'حذف الحركة';
      case TxHistoryKind.restored:
        return 'استعادة الحركة';
      case TxHistoryKind.edit:
        break;
    }
    // حركات الشركات: نوع الحركة هو ما يراه المستخدم، لذلك يسبق الحالة
    final mv = e.changes
        .where((c) => c.field == TxField.companyMovementType)
        .firstOrNull;
    if (mv != null) {
      final toCancelled = _isCancelledMovement(mv.newValue);
      final fromCancelled = _isCancelledMovement(mv.oldValue);
      if (toCancelled && !fromCancelled) return 'إلغاء حركة الشركة';
      if (fromCancelled && !toCancelled) return 'إعادة تفعيل حركة الشركة';
      return 'تغيير نوع الحركة';
    }
    final st = e.changes.where((c) => c.field == TxField.status).firstOrNull;
    if (st != null) {
      switch (st.newValue?.toString()) {
        case 'received':
          return 'تم التسليم';
        case 'cancelled':
          return 'تم الإلغاء';
        case 'added':
          return 'إرجاع إلى «مضافة»';
      }
    }
    final rs = rows(e);
    if (e.has(TxField.accountId)) {
      return rs.length <= 1 ? 'نقل إلى حساب آخر' : 'نقل وتعديل';
    }
    if (rs.length == 1) {
      return rs.first.label.replaceFirst(RegExp(r'^تمت? '), '');
    }
    final n = rs.length;
    if (n == 2) return 'تعديل حقلين';
    if (n <= 10) return 'تعديل $n حقول';
    return 'تعديل $n حقلًا';
  }

  /// طابع الإدخال للون والأيقونة
  TxEntryTone tone(TxHistoryEntry e) {
    switch (e.kind) {
      case TxHistoryKind.deleted:
        return TxEntryTone.deleted;
      case TxHistoryKind.restored:
        return TxEntryTone.restored;
      case TxHistoryKind.edit:
        break;
    }
    for (final c in e.changes) {
      if (c.field == TxField.companyMovementType) {
        return _isCancelledMovement(c.newValue)
            ? TxEntryTone.cancelled
            : TxEntryTone.movement;
      }
    }
    for (final c in e.changes) {
      if (c.field != TxField.status) continue;
      switch (c.newValue?.toString()) {
        case 'received':
          return TxEntryTone.received;
        case 'cancelled':
          return TxEntryTone.cancelled;
        case 'added':
          return TxEntryTone.added;
      }
    }
    if (e.has(TxField.accountId)) return TxEntryTone.moved;
    return TxEntryTone.edit;
  }

  /// نص السجل كاملًا للنسخ (الأحدث أولًا)
  String plainText(
    List<TxHistoryEntry> entries, {
    required String header,
    List<String> details = const [],
  }) {
    final b = StringBuffer()..writeln(header);
    for (final d in details) {
      b.writeln(d);
    }
    for (final e in entries) {
      b
        ..writeln()
        ..writeln('${dateTime(e.at)} — ${title(e)}');
      for (final r in rows(e)) {
        b.writeln('• ${r.sentence}');
      }
      if (e.source != null) b.writeln('(المصدر: ${e.source})');
    }
    return b.toString().trimRight();
  }
}
