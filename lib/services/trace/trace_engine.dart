// lib/services/trace/trace_engine.dart
// -------------------------------------------------------------
// تتبّع مصدر ووجهة الحركة: «شركة ABC ← مكتب X».
//
// كل حركة بحساب مكتب إلها مصدر: حركة «استقبال» بحساب شركة، أو «مجهول».
// المحرك بيربط تلقائيًا حسب:
//  • الاسم: لازم يكون مطابق تمامًا (بعد توحيد الهمزات والتاء المربوطة
//    و«عبد الله» = «عبدالله»). الاسم المشابه = «محتمل» وبدو اختيار.
//  • المبلغ والعملة: نفسهم. نفس الاسم بمبلغ أو عملة مختلفة = «محتمل».
//  • الوقت: رسالة الشركة قبل حركة المكتب (مع سماحية صغيرة). حتى «الوقت
//    العادي» بدون تحذير، وبعده حتى «أقصى وقت» مع تحذير، وبعده مستحيل.
//  • سجل التعديل: الأسماء والمبالغ القديمة كمان بتنحسب.
//  • ربط واحد لواحد: حركة الشركة لحركة مكتب وحدة بنفس الوقت. إذا انلغت
//    حركة المكتب بتصير حركة الشركة متاحة لمكتب تاني (سلسلة)، والوقت
//    بينحسب من وقت الإلغاء.
//  • التعادل ما منخمّن فيه، إلا إذا كانت الحركات توائم من نفس الشركة (نفس
//    الاسم والمبلغ والعملة): بتتوزع حسب الترتيب الزمني.
//  • قرارات المستخدم (تأكيد/تغيير/مجهول/مو هي/تجاهل) ثابتة وما بتتغير
//    تلقائيًا.
//
// ملف Dart نقي (بدون Flutter) حتى يمكن اختباره مباشرة.
// -------------------------------------------------------------

import '../../models.dart';
import '../detection/receive_matching.dart' show CurrencyMatcher, nameKeysOf;
import '../detection/text_tokens.dart' show normalizeText;
import '../tx_history.dart';

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}');
}

String _two(int v) => v.toString().padLeft(2, '0');

String _dateTime(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

/// 1250000 → 1.250.000 ، 1250000.5 → 1.250.000,5
String traceAmount(double v) {
  if (!v.isFinite) return '0';
  final fixed = v.abs().toStringAsFixed(2);
  final dot = fixed.indexOf('.');
  final intPart = dot < 0 ? fixed : fixed.substring(0, dot);
  final dec = dot < 0
      ? ''
      : fixed.substring(dot + 1).replaceFirst(RegExp(r'0+$'), '');
  final b = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) b.write('.');
    b.write(intPart[i]);
  }
  final s = dec.isEmpty ? b.toString() : '$b,$dec';
  return v < 0 ? '-$s' : s;
}

/// مدة مقروءة: «25 دقيقة»، «3 ساعات»، «يومين و4 ساعات».
String traceDuration(Duration d) {
  var mins = d.inMinutes.abs();
  if (mins < 1) return 'أقل من دقيقة';
  String unit(int n, String one, String two, String few, String many) {
    if (n == 1) return one;
    if (n == 2) return two;
    if (n >= 3 && n <= 10) return '$n $few';
    return '$n $many';
  }

  if (mins < 60) return unit(mins, 'دقيقة', 'دقيقتين', 'دقائق', 'دقيقة');
  final hours = mins ~/ 60;
  mins = mins % 60;
  if (hours < 24) {
    final h = unit(hours, 'ساعة', 'ساعتين', 'ساعات', 'ساعة');
    if (mins == 0 || hours >= 6) return h;
    return '$h و${unit(mins, 'دقيقة', 'دقيقتين', 'دقائق', 'دقيقة')}';
  }
  final days = hours ~/ 24;
  final rem = hours % 24;
  final dd = unit(days, 'يوم', 'يومين', 'أيام', 'يومًا');
  if (rem == 0) return dd;
  return '$dd و${unit(rem, 'ساعة', 'ساعتين', 'ساعات', 'ساعة')}';
}

String _hours(int h) {
  if (h == 1) return 'ساعة';
  if (h == 2) return 'ساعتين';
  if (h >= 3 && h <= 10) return '$h ساعات';
  return '$h ساعة';
}

/// هاش ثابت قصير (FNV-1a) لتوقيعات التحذيرات.
String _hash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36);
}

// =============================================================
// الإعدادات
// =============================================================

class TracePrefs {
  /// حتى هالوقت بين رسالة الشركة وحركة المكتب: عادي بدون تحذير (ساعات).
  final int normalHours;

  /// بعد الوقت العادي وحتى هالحد: ممكن بس مع تحذير. بعده: مستحيل، وما
  /// بيظهر تحذير (ساعات).
  final int maxHours;

  /// سماحية إذا انسجلت حركة المكتب قبل رسالة الشركة بشوي (دقائق).
  final int earlyMinutes;

  /// تنبيه «ما راحت لمكتب» بعد هالوقت (ساعات).
  final int alertAfterHours;

  /// الكلمة يلي بتظهر لما يكون المصدر غير معروف.
  final String unknownLabel;

  /// حركات الشركة يلي فيها وحدة من هالكلمات لازم تروح لمكتب.
  final List<String> mustReachWords;

  /// حركات الشركة «المرسلة» كمان بتنحسب مصدر (افتراضيًا: الاستقبال بس).
  final bool includeSent;

  /// التحذيرات بس لحركات آخر هالعدد من الأيام (0 = كل الحركات)، حتى ما
  /// تغرق الصفحة بحركات قديمة مسكّرة.
  final int warnDays;

  const TracePrefs({
    this.normalHours = 24,
    this.maxHours = 48,
    this.earlyMinutes = 15,
    this.alertAfterHours = 2,
    this.unknownLabel = defaultUnknownLabel,
    this.mustReachWords = const [],
    this.includeSent = false,
    this.warnDays = 30,
  });

  /// خيارات «التحذيرات لآخر» (0 = الكل)
  static const List<int> warnDayChoices = [7, 14, 30, 60, 90, 180, 365, 0];

  static const String defaultUnknownLabel = 'مجهول';

  int get normalHoursSafe => normalHours.clamp(1, 24 * 30);

  int get maxHoursSafe {
    final n = normalHoursSafe;
    final m = maxHours < n ? n : maxHours;
    return m.clamp(1, 24 * 60);
  }

  Duration get normalWindow => Duration(hours: normalHoursSafe);
  Duration get maxWindow => Duration(hours: maxHoursSafe);
  Duration get earlyTolerance => Duration(minutes: earlyMinutes.clamp(0, 1440));
  Duration get alertAfter => Duration(hours: alertAfterHours.clamp(0, 720));

  String get unknown {
    final t = unknownLabel.trim();
    return t.isEmpty ? defaultUnknownLabel : t;
  }

  Map<String, dynamic> toMap() => {
    'normalHours': normalHours,
    'maxHours': maxHours,
    'earlyMinutes': earlyMinutes,
    'alertAfterHours': alertAfterHours,
    'unknownLabel': unknownLabel,
    'mustReachWords': mustReachWords,
    'includeSent': includeSent,
    'warnDays': warnDays,
  };

  factory TracePrefs.fromMap(Object? raw) {
    if (raw is! Map) return const TracePrefs();
    int i(Object? v, int d) => _asInt(v) ?? d;
    final words = raw['mustReachWords'];
    return TracePrefs(
      normalHours: i(raw['normalHours'], 24),
      maxHours: i(raw['maxHours'], 48),
      earlyMinutes: i(raw['earlyMinutes'], 15),
      alertAfterHours: i(raw['alertAfterHours'], 2),
      unknownLabel: raw['unknownLabel']?.toString() ?? defaultUnknownLabel,
      mustReachWords: words is List
          ? [
              for (final w in words)
                if ('$w'.trim().isNotEmpty) '$w'.trim(),
            ]
          : const [],
      includeSent: raw['includeSent'] == true,
      warnDays: i(raw['warnDays'], 30).clamp(0, 3650),
    );
  }

  TracePrefs copyWith({
    int? normalHours,
    int? maxHours,
    int? earlyMinutes,
    int? alertAfterHours,
    String? unknownLabel,
    List<String>? mustReachWords,
    bool? includeSent,
    int? warnDays,
  }) => TracePrefs(
    normalHours: normalHours ?? this.normalHours,
    maxHours: maxHours ?? this.maxHours,
    earlyMinutes: earlyMinutes ?? this.earlyMinutes,
    alertAfterHours: alertAfterHours ?? this.alertAfterHours,
    unknownLabel: unknownLabel ?? this.unknownLabel,
    mustReachWords: mustReachWords ?? this.mustReachWords,
    includeSent: includeSent ?? this.includeSent,
    warnDays: warnDays ?? this.warnDays,
  );
}

// =============================================================
// قرارات المستخدم
// =============================================================

enum TraceDecisionKind { link, unknown }

/// قرار يدوي لحركة مكتب: ربطها بحركة شركة معيّنة، أو «مجهول».
class TraceDecision {
  final int officeId;
  final TraceDecisionKind kind;
  final int? companyId;
  final DateTime at;

  /// قيم الحركتين وقت التأكيد (لاكتشاف أي تعديل بعده)
  final String? officeSnap;
  final String? companySnap;

  const TraceDecision({
    required this.officeId,
    required this.kind,
    required this.at,
    this.companyId,
    this.officeSnap,
    this.companySnap,
  });

  Map<String, dynamic> toMap() => {
    'o': officeId,
    'k': kind.name,
    if (companyId != null) 'c': companyId,
    'at': at.toIso8601String(),
    if (officeSnap != null) 'os': officeSnap,
    if (companySnap != null) 'cs': companySnap,
  };

  static TraceDecision? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final o = _asInt(raw['o']);
    if (o == null) return null;
    final k = raw['k'] == 'link'
        ? TraceDecisionKind.link
        : (raw['k'] == 'unknown' ? TraceDecisionKind.unknown : null);
    if (k == null) return null;
    final c = _asInt(raw['c']);
    if (k == TraceDecisionKind.link && c == null) return null;
    return TraceDecision(
      officeId: o,
      kind: k,
      companyId: c,
      at:
          DateTime.tryParse('${raw['at']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      officeSnap: raw['os']?.toString(),
      companySnap: raw['cs']?.toString(),
    );
  }
}

class TraceDecisions {
  final Map<int, TraceDecision> byOffice;

  /// «مو هي»: حركات شركة استبعدها المستخدم لحركة مكتب
  final Map<int, Set<int>> rejected;

  /// توقيعات التحذيرات المتجاهلة
  final Set<String> dismissed;

  const TraceDecisions({
    this.byOffice = const {},
    this.rejected = const {},
    this.dismissed = const {},
  });
}

/// قيم الحركة المختصرة (الاسم|المبلغ|العملة).
String traceSnapOf(TransactionModel t) =>
    '${TraceEngine.keysOf(t.beneficiary).join(' ')}|'
    '${t.amount.toStringAsFixed(2)}|${normalizeText(t.currency)}';

// =============================================================
// النتائج
// =============================================================

enum TraceNameFit { exact, similar, different }

enum TraceIssue { tie, nameNotExact, amountDiffers, currencyDiffers }

extension TraceIssueInfo on TraceIssue {
  String get label {
    switch (this) {
      case TraceIssue.tie:
        return 'أكتر من احتمال';
      case TraceIssue.nameNotExact:
        return 'الاسم مو مطابق';
      case TraceIssue.amountDiffers:
        return 'المبلغ مختلف';
      case TraceIssue.currencyDiffers:
        return 'العملة مختلفة';
    }
  }
}

enum TraceStatus { manual, auto, autoOrder, possible, unknownManual, unknown }

extension TraceStatusInfo on TraceStatus {
  bool get linked =>
      this == TraceStatus.manual ||
      this == TraceStatus.auto ||
      this == TraceStatus.autoOrder;

  bool get isUnknown =>
      this == TraceStatus.unknown || this == TraceStatus.unknownManual;
}

/// تقييم حركة مكتب مقابل حركة شركة.
class TraceMatch {
  final int officeId;
  final int companyId;
  final TraceNameFit nameFit;

  /// الاسمان المستخدمان بالمقارنة (قد يكون أحدهما اسمًا سابقًا)
  final String officeName;
  final String companyName;
  final bool officeNamePast;
  final bool companyNamePast;

  /// وصف الفرق بالاسم (للأسماء المتشابهة)
  final String? nameNote;
  final bool amountSame;
  final double officeAmount;
  final double companyAmount;
  final bool officeAmountPast;
  final bool companyAmountPast;

  /// true = نفس العملة، false = مختلفة، null = غير معروفة بأحد الطرفين
  final bool? currencySame;
  final String officeCurrency;
  final String companyCurrency;

  /// وقت حركة المكتب ناقص وقت المرجع (رسالة الشركة أو إلغاء مكتب سابق)
  final Duration gap;
  final bool late;
  final bool tooEarly;
  final bool tooOld;

  /// الوقت محسوب من إلغاء هالحركة بمكتب سابق
  final int? rerouteFrom;

  /// حركة الشركة انلغت قبل حركة المكتب
  final bool companyCancelledBefore;

  const TraceMatch({
    required this.officeId,
    required this.companyId,
    required this.nameFit,
    required this.officeName,
    required this.companyName,
    required this.officeNamePast,
    required this.companyNamePast,
    required this.nameNote,
    required this.amountSame,
    required this.officeAmount,
    required this.companyAmount,
    required this.officeAmountPast,
    required this.companyAmountPast,
    required this.currencySame,
    required this.officeCurrency,
    required this.companyCurrency,
    required this.gap,
    required this.late,
    required this.tooEarly,
    required this.tooOld,
    required this.rerouteFrom,
    required this.companyCancelledBefore,
  });

  bool get exactName => nameFit == TraceNameFit.exact;
  bool get strong => exactName && amountSame && currencySame != false;
  bool get inWindow => !tooEarly && !tooOld;
  bool get usesPast =>
      officeNamePast ||
      companyNamePast ||
      officeAmountPast ||
      companyAmountPast;

  Set<TraceIssue> get issues => {
    if (!exactName) TraceIssue.nameNotExact,
    if (!amountSame) TraceIssue.amountDiffers,
    if (currencySame == false) TraceIssue.currencyDiffers,
  };

  /// للترتيب: الأقوى أولًا
  int get quality =>
      (exactName ? 8 : (nameFit == TraceNameFit.similar ? 3 : 0)) +
      (amountSame ? 4 : 0) +
      (currencySame != false ? 1 : 0) -
      (companyCancelledBefore ? 1 : 0);
}

class OfficeTrace {
  final int officeId;
  final TraceStatus status;

  /// الربط (يدوي أو تلقائي)
  final TraceMatch? link;

  /// للمحتمل: المرشحين (الأقوى أولًا)
  final List<TraceMatch> candidates;
  final Set<TraceIssue> issues;

  /// ربط يدوي لحركة ما عادت موجودة (أو ما عادت حركة استقبال)
  final int? brokenCompanyId;

  const OfficeTrace({
    required this.officeId,
    required this.status,
    this.link,
    this.candidates = const [],
    this.issues = const {},
    this.brokenCompanyId,
  });

  int? get companyId => link?.companyId;
}

class CompanyTrace {
  final int companyId;

  /// حركات المكاتب المربوطة فيها بالترتيب الزمني (مع الملغاة)
  final List<int> officeIds;
  final int? activeOfficeId;

  /// حركات مكتب ممكن تكون وجهتها (بدها اختيار)
  final List<int> possibleOfficeIds;
  final bool mustReach;
  final String? mustReachWord;

  /// من إيمتى عم تستنى مكتب (رسالة الشركة أو آخر إلغاء)
  final DateTime waitingSince;
  final bool overdue;
  final bool cancelled;

  const CompanyTrace({
    required this.companyId,
    required this.officeIds,
    required this.activeOfficeId,
    required this.possibleOfficeIds,
    required this.mustReach,
    required this.mustReachWord,
    required this.waitingSince,
    required this.overdue,
    required this.cancelled,
  });

  bool get reached => activeOfficeId != null;
}

enum TraceWarningKind {
  choose,
  late,
  editedOneSide,
  valuesDiffer,
  confirmedChanged,
  companyCancelled,
  notReached,
  brokenLink,
}

class TraceWarning {
  final TraceWarningKind kind;
  final Set<TraceIssue> issues;
  final int? officeId;
  final int? companyId;
  final String sig;
  final String title;
  final String detail;

  /// للترتيب (وقت الحركة)
  final DateTime at;

  const TraceWarning({
    required this.kind,
    required this.sig,
    required this.title,
    required this.detail,
    required this.at,
    this.issues = const {},
    this.officeId,
    this.companyId,
  });

  bool get dismissable => kind != TraceWarningKind.choose;

  bool involves(int txId) => officeId == txId || companyId == txId;
}

enum TraceReasonTone { good, warn, bad, info }

class TraceReason {
  final TraceReasonTone tone;
  final String text;
  const TraceReason(this.tone, this.text);
}

/// مرشح ما انختار، مع السبب
class TraceRejected {
  final int txId;
  final String reason;
  final TraceMatch? match;
  const TraceRejected(this.txId, this.reason, [this.match]);
}

class TraceExplanation {
  final List<TraceReason> reasons;
  final List<TraceRejected> rejected;
  const TraceExplanation(this.reasons, this.rejected);
}

/// خيار بقائمة «تغيير المصدر/الوجهة»
class TraceOption {
  final int txId;
  final TraceMatch match;

  /// حركة المكتب يلي ماسكة هالحركة حاليًا (إن وجدت)
  final int? heldBy;
  final bool heldManually;

  const TraceOption(this.txId, this.match, this.heldBy, this.heldManually);
}

class TraceResult {
  final TracePrefs prefs;
  final Map<int, OfficeTrace> office;
  final Map<int, CompanyTrace> company;
  final List<TraceWarning> warnings;
  final Set<String> dismissed;
  final DateTime computedAt;
  final _Ctx? _ctx;

  const TraceResult._({
    required this.prefs,
    required this.office,
    required this.company,
    required this.warnings,
    required this.dismissed,
    required this.computedAt,
    required _Ctx? ctx,
  }) : _ctx = ctx;

  bool isDismissed(TraceWarning w) => dismissed.contains(w.sig);

  /// نفس النتيجة مع قائمة تجاهل جديدة (بدون إعادة حساب)
  TraceResult withDismissed(Set<String> d) => TraceResult._(
    prefs: prefs,
    office: office,
    company: company,
    warnings: warnings,
    dismissed: d,
    computedAt: computedAt,
    ctx: _ctx,
  );

  List<TraceWarning> get activeWarnings => [
    for (final w in warnings)
      if (!dismissed.contains(w.sig)) w,
  ];

  List<TraceWarning> warningsFor(int txId) => [
    for (final w in warnings)
      if (w.involves(txId)) w,
  ];

  bool isTraced(int txId) =>
      office.containsKey(txId) || company.containsKey(txId);

  /// حركة الشركة المرتبطة بحركة المكتب (إن وجدت)
  int? companyOf(int officeId) => office[officeId]?.companyId;

  /// اسم حساب الحركة كما كان وقت الحساب
  String? accountNameOf(int txId) => _ctx?.nodes[txId]?.account.name;

  TraceExplanation explain(int txId) {
    final ctx = _ctx;
    if (ctx == null) return const TraceExplanation([], []);
    if (office.containsKey(txId)) return ctx.explainOffice(txId, this);
    if (company.containsKey(txId)) return ctx.explainCompany(txId, this);
    return const TraceExplanation([], []);
  }

  /// خيارات «تغيير المصدر» لحركة مكتب (أو «ربط بحركة مكتب» لحركة شركة)
  List<TraceOption> optionsFor(
    int txId, {
    Duration back = const Duration(days: 7),
    Duration ahead = const Duration(days: 7),
  }) {
    final ctx = _ctx;
    if (ctx == null) return const [];
    if (office.containsKey(txId)) {
      return ctx.companyOptions(
        txId,
        back: back,
        ahead: const Duration(days: 1),
      );
    }
    if (company.containsKey(txId)) {
      return ctx.officeOptions(txId, ahead: ahead);
    }
    return const [];
  }

  /// تقييم زوج (حركة مكتب، حركة شركة) بدون شروط الوقت
  TraceMatch? evaluatePair(int officeId, int companyId) {
    final ctx = _ctx;
    if (ctx == null) return null;
    final o = ctx.nodes[officeId];
    final c = ctx.nodes[companyId];
    if (o == null || c == null || !o.isOffice || c.isOffice) return null;
    return ctx.evaluate(o, c, force: true);
  }

  static final TraceResult empty = TraceResult._(
    prefs: const TracePrefs(),
    office: const {},
    company: const {},
    warnings: const [],
    dismissed: const {},
    computedAt: DateTime.fromMillisecondsSinceEpoch(0),
    ctx: null,
  );
}

// =============================================================
// تشابه الأسماء
// =============================================================

int _levenshtein(String a, String b, int max) {
  if ((a.length - b.length).abs() > max) return max + 1;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    var rowMin = cur[0];
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[j] + 1;
      if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1;
      if (prev[j - 1] + cost < v) v = prev[j - 1] + cost;
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > max) return max + 1;
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}

/// كلمتان متقاربتان: فرق حرف (أو حرفين للكلمات الطويلة). الكلمات القصيرة
/// (أقل من 3 أحرف) لازم تكون متطابقة.
bool _fuzzyWord(String a, String b) {
  if (a == b) return true;
  if (a.length < 3 || b.length < 3) return false;
  final shorter = a.length < b.length ? a.length : b.length;
  final max = shorter >= 7 ? 2 : 1;
  return _levenshtein(a, b, max) <= max;
}

/// وصف الفرق بين اسمين متشابهين (null = مو متشابهين، أو متطابقين).
/// [a] و[b] مفاتيح الاسم بعد التطبيع.
String? similarNameNote(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return null;
  final shortL = a.length <= b.length ? a : b;
  final longL = identical(shortL, a) ? b : a;
  final used = List<bool>.filled(longL.length, false);
  var matched = 0;
  final fuzzyPairs = <String>[];
  for (final w in shortL) {
    var idx = -1;
    for (var i = 0; i < longL.length; i++) {
      if (!used[i] && longL[i] == w) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      for (var i = 0; i < longL.length; i++) {
        if (!used[i] && _fuzzyWord(w, longL[i])) {
          idx = i;
          fuzzyPairs.add('«$w» و«${longL[i]}»');
          break;
        }
      }
    }
    if (idx >= 0) {
      used[idx] = true;
      matched++;
    }
  }
  if (matched < shortL.length) return null;
  final extra = [
    for (var i = 0; i < longL.length; i++)
      if (!used[i]) longL[i],
  ];
  if (fuzzyPairs.isEmpty && extra.isEmpty) {
    // نفس الكلمات: إما متطابق أو بترتيب مختلف
    return a.join(' ') == b.join(' ') ? null : 'نفس الكلمات بترتيب تاني';
  }
  if (shortL.length == 1) {
    final ok =
        (longL.length == 1 && fuzzyPairs.length == 1) ||
        (longL.length == 2 && fuzzyPairs.isEmpty);
    if (!ok) return null;
  } else if (fuzzyPairs.length > 1 || extra.length > 2) {
    return null;
  }
  final parts = <String>[
    if (fuzzyPairs.isNotEmpty) 'فرق حرف بين ${fuzzyPairs.join('، ')}',
    if (extra.length == 1) 'كلمة زيادة: «${extra.first}»',
    if (extra.length > 1) 'كلمات زيادة: «${extra.join(' ')}»',
  ];
  return parts.join(' • ');
}

// =============================================================
// المحرك
// =============================================================

class _St {
  final String name;
  final List<String> keys;
  final String key;
  final double amount;
  final int amountKey;
  final String currency;
  final bool namePast;
  final bool amountPast;
  final Set<String> words;

  _St._(
    this.name,
    this.keys,
    this.amount,
    this.currency,
    this.namePast,
    this.amountPast,
  ) : key = keys.join(' '),
      words = keys.toSet(),
      amountKey = amount.isFinite ? (amount * 100).round() : -1;

  factory _St(String name, double amount, String currency) => _St._(
    name.trim(),
    TraceEngine.keysOf(name),
    amount,
    currency.trim(),
    false,
    false,
  );

  _St flagged({required bool namePast, required bool amountPast}) =>
      _St._(name, keys, amount, currency, namePast, amountPast);

  bool get past => namePast || amountPast;
}

class _Node {
  final TransactionModel tx;
  final Account account;
  final bool isOffice;
  final CompanyMovementType? movement;
  final List<_St> states;
  final List<TxHistoryEntry> keyEdits;

  _Node({
    required this.tx,
    required this.account,
    required this.isOffice,
    required this.movement,
    required this.states,
    required this.keyEdits,
  });

  int get id => tx.id;
  DateTime get date => tx.date;
  _St get current => states.first;

  bool get officeCancelled =>
      isOffice && tx.status == TransactionStatus.cancelled;

  bool get companyCancelled => !isOffice && (movement?.isCancelled ?? false);

  /// فترة «مسك» حركة الشركة: من وقت حركة المكتب حتى إلغائها
  DateTime get holdStart => tx.date;
  DateTime? get holdEnd => officeCancelled ? (tx.cancelledAt ?? tx.date) : null;

  DateTime? get lastKeyEditAt {
    DateTime? last;
    for (final e in keyEdits) {
      if (last == null || e.at.isAfter(last)) last = e.at;
    }
    return last;
  }
}

int _byDate(_Node a, _Node b) {
  final c = a.date.compareTo(b.date);
  return c != 0 ? c : a.id.compareTo(b.id);
}

class _Reroute {
  final _Node company;
  final DateTime cancelledAt;
  final int officeId;
  const _Reroute(this.company, this.cancelledAt, this.officeId);
}

class TraceEngine {
  final TracePrefs prefs;
  final CurrencyMatcher currency;
  final TraceDecisions decisions;
  final DateTime now;

  TraceEngine({
    required this.prefs,
    required this.currency,
    this.decisions = const TraceDecisions(),
    DateTime? now,
  }) : now = now ?? DateTime.now();

  static final Map<String, List<String>> _keyCache = {};

  /// مفاتيح الاسم (مع ذاكرة مؤقتة لأن نفس الأسماء بتتكرر بكل حساب)
  static List<String> keysOf(String name) {
    final cached = _keyCache[name];
    if (cached != null) return cached;
    if (_keyCache.length > 60000) _keyCache.clear();
    final keys = List<String>.unmodifiable(nameKeysOf(name));
    _keyCache[name] = keys;
    return keys;
  }

  /// نوع حركة الشركة الفعلي (الحركات القديمة بدون نوع = استقبال)
  static CompanyMovementType movementOf(TransactionModel t) =>
      t.effectiveCompanyMovement ??
      (t.status == TransactionStatus.cancelled
          ? CompanyMovementType.receivedCancelled
          : CompanyMovementType.received);

  bool isSourceMovement(CompanyMovementType m) =>
      m == CompanyMovementType.received ||
      m == CompanyMovementType.receivedCancelled ||
      (prefs.includeSent &&
          (m == CompanyMovementType.sent ||
              m == CompanyMovementType.sentCancelled));

  TraceResult run({
    required Iterable<TransactionModel> transactions,
    required Map<int, Account> accounts,
    Map<int, List<TxHistoryEntry>> keyEdits = const {},
    Map<int, String> messages = const {},
  }) {
    final ctx = _Ctx(this);
    ctx.build(transactions, accounts, keyEdits);
    ctx.resolve();
    final companyTraces = ctx.companyTraces(messages);
    final warnings = ctx.warnings(companyTraces);
    return TraceResult._(
      prefs: prefs,
      office: ctx.officeTraces,
      company: companyTraces,
      warnings: warnings,
      dismissed: decisions.dismissed,
      computedAt: now,
      ctx: ctx,
    );
  }
}

class _Ctx {
  final TraceEngine e;
  _Ctx(this.e);

  TracePrefs get prefs => e.prefs;

  final Map<int, _Node> nodes = {};
  final List<_Node> offices = [];
  final List<_Node> companies = [];
  final Map<String, List<_Node>> byName = {};
  final Map<int, List<_Node>> byAmount = {};
  final Map<String, List<_Reroute>> rerouteByKey = {};

  /// حركات المكاتب يلي ماسكة كل حركة شركة (يدوي + تلقائي)
  final Map<int, List<_Node>> holders = {};
  final Map<int, TraceMatch> links = {};
  final Map<int, TraceStatus> linkStatus = {};
  final Set<int> manualUnknown = {};
  final Map<int, int> broken = {};
  final Map<int, List<TraceMatch>> strong = {};
  final Map<int, List<TraceMatch>> weak = {};
  final Map<int, OfficeTrace> officeTraces = {};

  // ---------------------------------------------------------
  // البناء
  // ---------------------------------------------------------

  void build(
    Iterable<TransactionModel> txs,
    Map<int, Account> accounts,
    Map<int, List<TxHistoryEntry>> keyEdits,
  ) {
    for (final t in txs) {
      final acc = accounts[t.accountId];
      if (acc == null) continue;
      final isOffice = !acc.type.isCompany;
      CompanyMovementType? mv;
      if (!isOffice) {
        mv = TraceEngine.movementOf(t);
        if (!e.isSourceMovement(mv)) continue;
      }
      final edits = keyEdits[t.id] ?? const <TxHistoryEntry>[];
      final cur = _St(t.beneficiary, t.amount, t.currency);
      final states = <_St>[cur];
      if (edits.isNotEmpty) {
        for (final p in txPastStates(
          edits,
          name: t.beneficiary,
          amount: t.amount,
          currency: t.currency,
        )) {
          final s = _St(p.name, p.amount, p.currency);
          states.add(
            s.flagged(
              namePast: s.key != cur.key,
              amountPast: (p.amount - cur.amount).abs() >= 0.005,
            ),
          );
        }
      }
      final n = _Node(
        tx: t,
        account: acc,
        isOffice: isOffice,
        movement: mv,
        states: states,
        keyEdits: edits,
      );
      nodes[t.id] = n;
      (isOffice ? offices : companies).add(n);
    }
    companies.sort(_byDate);
    offices.sort(_byDate);
    for (final c in companies) {
      final seenK = <String>{};
      final seenA = <int>{};
      for (final s in c.states) {
        if (s.key.isNotEmpty && seenK.add(s.key)) {
          (byName[s.key] ??= []).add(c);
        }
        if (s.amountKey >= 0 && seenA.add(s.amountKey)) {
          (byAmount[s.amountKey] ??= []).add(c);
        }
      }
    }
  }

  /// أول عنصر بالقائمة (مرتبة بالتاريخ) تاريخه مو قبل [from]
  static int lowerBound(List<_Node> list, DateTime from) {
    var lo = 0;
    var hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].date.isBefore(from)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// عناصر القائمة (مرتبة بالتاريخ) يلي تاريخها بين [from] و[to]
  static List<_Node> inRange(List<_Node> list, DateTime from, DateTime to) {
    final out = <_Node>[];
    for (var i = lowerBound(list, from); i < list.length; i++) {
      final n = list[i];
      if (n.date.isAfter(to)) break;
      out.add(n);
    }
    return out;
  }

  final Map<String, Set<String>> _currencyIds = {};

  /// مقارنة العملتين (مع ذاكرة مؤقتة): true نفسها، false مختلفة، null مجهولة
  bool? compareCurrency(String a, String b) {
    final ia = _currencyIds[a] ??= e.currency.idsOf(a);
    final ib = _currencyIds[b] ??= e.currency.idsOf(b);
    if (ia.isEmpty || ib.isEmpty) return null;
    for (final x in ia) {
      if (ib.contains(x)) return true;
    }
    return false;
  }

  /// فحص سريع قبل حساب التشابه: كلمة مشتركة على الأقل (أو اسمين من كلمة
  /// وحدة لكل منهما)
  static bool mightBeSimilar(_Node o, _Node c) {
    for (final so in o.states) {
      for (final sc in c.states) {
        if (so.keys.length == 1 && sc.keys.length == 1) return true;
        for (final w in so.keys) {
          if (sc.words.contains(w)) return true;
        }
      }
    }
    return false;
  }

  // ---------------------------------------------------------
  // تقييم زوج
  // ---------------------------------------------------------

  TraceMatch? evaluate(
    _Node o,
    _Node c, {
    DateTime? ref,
    int? rerouteFrom,
    bool force = false,
  }) {
    final r = ref ?? c.date;
    final gap = o.date.difference(r);
    final tooEarly = gap < -prefs.earlyTolerance;
    final tooOld = gap > prefs.maxWindow;
    if (!force && (tooEarly || tooOld)) return null;

    _St? bo;
    _St? bc;
    var bestScore = -1;
    var bestFit = TraceNameFit.different;
    String? bestNote;
    var bestAmount = false;
    bool? bestCurrency;
    for (final so in o.states) {
      for (final sc in c.states) {
        final amountSame = (so.amount - sc.amount).abs() < 0.005;
        TraceNameFit fit;
        String? note;
        if (so.key.isNotEmpty && so.key == sc.key) {
          fit = TraceNameFit.exact;
        } else if (amountSame || force) {
          note = similarNameNote(so.keys, sc.keys);
          fit = note == null ? TraceNameFit.different : TraceNameFit.similar;
        } else {
          fit = TraceNameFit.different;
        }
        if (fit == TraceNameFit.different && !force) continue;
        final cur = compareCurrency(so.currency, sc.currency);
        final score =
            (fit == TraceNameFit.exact
                ? 400
                : (fit == TraceNameFit.similar ? 200 : 0)) +
            (amountSame ? 100 : 0) +
            (cur != false ? 20 : 0) -
            (so.past ? 2 : 0) -
            (sc.past ? 2 : 0);
        if (score > bestScore) {
          bestScore = score;
          bo = so;
          bc = sc;
          bestFit = fit;
          bestNote = note;
          bestAmount = amountSame;
          bestCurrency = cur;
        }
      }
    }
    if (bo == null || bc == null) return null;
    if (!force && bestFit == TraceNameFit.similar && !bestAmount) return null;
    final cancelledAt = c.tx.cancelledAt;
    final cancelledBefore =
        c.companyCancelled &&
        cancelledAt != null &&
        cancelledAt.isBefore(o.date);
    return TraceMatch(
      officeId: o.id,
      companyId: c.id,
      nameFit: bestFit,
      officeName: bo.name,
      companyName: bc.name,
      officeNamePast: bo.namePast,
      companyNamePast: bc.namePast,
      nameNote: bestNote,
      amountSame: bestAmount,
      officeAmount: bo.amount,
      companyAmount: bc.amount,
      officeAmountPast: bo.amountPast,
      companyAmountPast: bc.amountPast,
      currencySame: bestCurrency,
      officeCurrency: bo.currency,
      companyCurrency: bc.currency,
      gap: gap,
      late: gap > prefs.normalWindow,
      tooEarly: tooEarly,
      tooOld: tooOld,
      rerouteFrom: rerouteFrom,
      companyCancelledBefore: cancelledBefore,
    );
  }

  List<TraceMatch> candidatesOf(_Node o, {required bool reroute}) {
    final from = o.date.subtract(prefs.maxWindow);
    final to = o.date.add(prefs.earlyTolerance);
    final seen = <int>{};
    final out = <TraceMatch>[];
    void scan(List<_Node>? list, {required bool byAmountOnly}) {
      if (list == null) return;
      for (var i = lowerBound(list, from); i < list.length; i++) {
        final c = list[i];
        if (c.date.isAfter(to)) break;
        if (seen.contains(c.id)) continue;
        if (byAmountOnly && !mightBeSimilar(o, c)) continue;
        seen.add(c.id);
        final m = evaluate(o, c);
        if (m != null) out.add(m);
      }
    }

    for (final s in o.states) {
      if (s.key.isNotEmpty) scan(byName[s.key], byAmountOnly: false);
    }
    for (final s in o.states) {
      if (s.amountKey >= 0) scan(byAmount[s.amountKey], byAmountOnly: true);
    }
    if (reroute && rerouteByKey.isNotEmpty) {
      final limit = o.date.add(prefs.earlyTolerance);
      for (final s in o.states) {
        if (s.key.isEmpty) continue;
        final refs = rerouteByKey[s.key];
        if (refs == null) continue;
        for (final r in refs) {
          if (r.officeId == o.id || seen.contains(r.company.id)) continue;
          if (r.cancelledAt.isAfter(limit)) continue;
          final m = evaluate(
            o,
            r.company,
            ref: r.cancelledAt,
            rerouteFrom: r.officeId,
          );
          if (m != null) {
            seen.add(r.company.id);
            out.add(m);
          }
        }
      }
    }
    return out;
  }

  int _compareMatches(TraceMatch a, TraceMatch b) {
    final q = b.quality.compareTo(a.quality);
    if (q != 0) return q;
    final g = a.gap.abs().compareTo(b.gap.abs());
    if (g != 0) return g;
    return a.companyId.compareTo(b.companyId);
  }

  void partition(_Node o, List<TraceMatch> all) {
    final rej = e.decisions.rejected[o.id] ?? const <int>{};
    final s = <TraceMatch>[];
    final w = <TraceMatch>[];
    for (final m in all) {
      if (rej.contains(m.companyId)) continue;
      (m.strong ? s : w).add(m);
    }
    // حركة شركة ملغاة قبل حركة المكتب ما بتنحسب إذا في بديل فعّال
    if (s.any((m) => !m.companyCancelledBefore)) {
      s.removeWhere((m) => m.companyCancelledBefore);
    }
    s.sort(_compareMatches);
    w.sort(_compareMatches);
    strong[o.id] = s;
    weak[o.id] = w;
  }

  /// هل حركتا المكتب ماسكتين حركة الشركة بنفس الوقت؟ الملغاة بتمسكها لحد
  /// وقت إلغائها (مع سماحية صغيرة: أحيانًا بينسجل الإلغاء بعد الحركة الجديدة
  /// بدقائق).
  bool overlap(_Node a, _Node b) {
    final tol = prefs.earlyTolerance;
    final aEnd = a.holdEnd?.subtract(tol);
    final bEnd = b.holdEnd?.subtract(tol);
    final aStartsBeforeBEnds = bEnd == null || a.holdStart.isBefore(bEnd);
    final bStartsBeforeAEnds = aEnd == null || b.holdStart.isBefore(aEnd);
    return aStartsBeforeBEnds && bStartsBeforeAEnds;
  }

  bool busy(int companyId, _Node o) {
    final hs = holders[companyId];
    if (hs == null) return false;
    for (final h in hs) {
      if (h.id != o.id && overlap(h, o)) return true;
    }
    return false;
  }

  _Node? holderOf(int companyId, _Node o) {
    final hs = holders[companyId];
    if (hs == null) return null;
    for (final h in hs) {
      if (h.id != o.id && overlap(h, o)) return h;
    }
    return null;
  }

  // ---------------------------------------------------------
  // الحل
  // ---------------------------------------------------------

  void resolve() {
    // 1) قرارات المستخدم
    for (final o in offices) {
      final d = e.decisions.byOffice[o.id];
      if (d == null) continue;
      if (d.kind == TraceDecisionKind.unknown) {
        manualUnknown.add(o.id);
        continue;
      }
      final c = nodes[d.companyId];
      if (c == null || c.isOffice) {
        broken[o.id] = d.companyId ?? 0;
        continue;
      }
      final m = evaluate(o, c, force: true);
      if (m == null) continue;
      links[o.id] = m;
      linkStatus[o.id] = TraceStatus.manual;
      (holders[c.id] ??= []).add(o);
    }

    bool open(_Node o) =>
        !links.containsKey(o.id) && !manualUnknown.contains(o.id);

    // 2) المرشحين: الملغاة أولًا (لحساب وقت «الرجوع بعد الإلغاء»)
    for (final o in offices) {
      if (o.officeCancelled && open(o)) {
        partition(o, candidatesOf(o, reroute: false));
      }
    }
    void addReroute(_Node o, _Node c) {
      final at = o.tx.cancelledAt ?? o.date;
      final r = _Reroute(c, at, o.id);
      final keys = <String>{for (final s in c.states) s.key};
      for (final k in keys) {
        if (k.isNotEmpty) (rerouteByKey[k] ??= []).add(r);
      }
    }

    for (final o in offices) {
      if (!o.officeCancelled) continue;
      final l = links[o.id];
      if (l != null) {
        final c = nodes[l.companyId];
        if (c != null) addReroute(o, c);
        continue;
      }
      for (final m in strong[o.id] ?? const <TraceMatch>[]) {
        final c = nodes[m.companyId];
        if (c != null) addReroute(o, c);
      }
    }
    for (final o in offices) {
      if (!o.officeCancelled && open(o)) {
        partition(o, candidatesOf(o, reroute: true));
      }
    }

    // 3) الإجباري: حركة مكتب إلها خيار واحد بس
    final pending = <_Node>[
      for (final o in offices)
        if (open(o) && (strong[o.id]?.isNotEmpty ?? false)) o,
    ];
    final opts = <int, List<TraceMatch>>{
      for (final o in pending) o.id: List<TraceMatch>.of(strong[o.id]!),
    };
    var guard = 0;
    while (pending.isNotEmpty && guard++ < 100000) {
      for (final o in pending) {
        opts[o.id]!.removeWhere((m) => busy(m.companyId, o));
      }
      final singles = <int, List<_Node>>{};
      for (final o in pending) {
        final l = opts[o.id]!;
        if (l.length == 1) (singles[l.first.companyId] ??= []).add(o);
      }
      var changed = false;
      for (final entry in singles.entries) {
        final list = entry.value..sort(_byDate);
        var ok = true;
        for (var i = 0; i < list.length && ok; i++) {
          for (var j = i + 1; j < list.length; j++) {
            if (overlap(list[i], list[j])) {
              ok = false;
              break;
            }
          }
        }
        if (!ok) continue;
        for (final o in list) {
          if (busy(entry.key, o)) continue;
          links[o.id] = opts[o.id]!.first;
          linkStatus[o.id] = TraceStatus.auto;
          (holders[entry.key] ??= []).add(o);
          changed = true;
        }
      }
      if (!changed) break;
      pending.removeWhere((o) => links.containsKey(o.id));
    }

    // 4) التوائم: حركات متطابقة من نفس الشركة بتتوزع حسب الترتيب
    for (final o in pending) {
      opts[o.id]!.removeWhere((m) => busy(m.companyId, o));
    }
    final rest = [
      for (final o in pending)
        if (opts[o.id]!.isNotEmpty) o,
    ];
    final officesByCompany = <int, List<_Node>>{};
    for (final o in rest) {
      for (final m in opts[o.id]!) {
        (officesByCompany[m.companyId] ??= []).add(o);
      }
    }
    final visited = <int>{};
    for (final start in rest) {
      if (!visited.add(start.id)) continue;
      final compOffices = <_Node>[];
      final compCompanies = <int>{};
      final queue = <_Node>[start];
      while (queue.isNotEmpty) {
        final o = queue.removeLast();
        compOffices.add(o);
        for (final m in opts[o.id]!) {
          if (!compCompanies.add(m.companyId)) continue;
          for (final o2 in officesByCompany[m.companyId]!) {
            if (visited.add(o2.id)) queue.add(o2);
          }
        }
      }
      if (compOffices.length > compCompanies.length) continue;
      if (!_twins(compCompanies)) continue;
      compOffices.sort(_byDate);
      for (final o in compOffices) {
        final options = opts[o.id]!.toList()
          ..sort((a, b) => _byDate(nodes[a.companyId]!, nodes[b.companyId]!));
        for (final m in options) {
          if (busy(m.companyId, o)) continue;
          links[o.id] = m;
          linkStatus[o.id] = TraceStatus.autoOrder;
          (holders[m.companyId] ??= []).add(o);
          break;
        }
      }
    }

    // 5) النتيجة لكل حركة مكتب
    for (final o in offices) {
      final l = links[o.id];
      if (l != null) {
        officeTraces[o.id] = OfficeTrace(
          officeId: o.id,
          status: linkStatus[o.id] ?? TraceStatus.auto,
          link: l,
          brokenCompanyId: broken[o.id],
        );
        continue;
      }
      if (manualUnknown.contains(o.id)) {
        officeTraces[o.id] = OfficeTrace(
          officeId: o.id,
          status: TraceStatus.unknownManual,
        );
        continue;
      }
      final strongLeft = [
        for (final m in strong[o.id] ?? const <TraceMatch>[])
          if (!busy(m.companyId, o)) m,
      ];
      if (strongLeft.isNotEmpty) {
        officeTraces[o.id] = OfficeTrace(
          officeId: o.id,
          status: TraceStatus.possible,
          candidates: strongLeft,
          issues: const {TraceIssue.tie},
          brokenCompanyId: broken[o.id],
        );
        continue;
      }
      final weakLeft = [
        for (final m in weak[o.id] ?? const <TraceMatch>[])
          if (!busy(m.companyId, o)) m,
      ];
      if (weakLeft.isNotEmpty) {
        officeTraces[o.id] = OfficeTrace(
          officeId: o.id,
          status: TraceStatus.possible,
          candidates: weakLeft,
          issues: {for (final m in weakLeft) ...m.issues},
          brokenCompanyId: broken[o.id],
        );
        continue;
      }
      officeTraces[o.id] = OfficeTrace(
        officeId: o.id,
        status: TraceStatus.unknown,
        brokenCompanyId: broken[o.id],
      );
    }
  }

  bool _twins(Set<int> companyIds) {
    _Node? first;
    for (final id in companyIds) {
      final c = nodes[id];
      if (c == null) return false;
      if (first == null) {
        first = c;
        continue;
      }
      if (c.account.id != first.account.id) return false;
      if (c.current.key != first.current.key) return false;
      if (c.current.amountKey != first.current.amountKey) return false;
      if (compareCurrency(c.current.currency, first.current.currency) ==
          false) {
        return false;
      }
    }
    return first != null;
  }

  // ---------------------------------------------------------
  // حركات الشركات
  // ---------------------------------------------------------

  String? mustReachWordOf(_Node c, Map<int, String> messages) {
    if (prefs.mustReachWords.isEmpty) return null;
    final text = normalizeText(
      '${c.tx.beneficiary} ${c.tx.notes} ${messages[c.id] ?? ''}',
    );
    if (text.isEmpty) return null;
    for (final w in prefs.mustReachWords) {
      final k = normalizeText(w);
      if (k.isNotEmpty && text.contains(k)) return w;
    }
    return null;
  }

  Map<int, CompanyTrace> companyTraces(Map<int, String> messages) {
    final possibleByCompany = <int, List<int>>{};
    for (final t in officeTraces.values) {
      if (t.status != TraceStatus.possible) continue;
      for (final m in t.candidates) {
        (possibleByCompany[m.companyId] ??= []).add(t.officeId);
      }
    }
    final out = <int, CompanyTrace>{};
    for (final c in companies) {
      final hs = [...?holders[c.id]]..sort(_byDate);
      int? active;
      var since = c.date;
      for (final o in hs) {
        if (o.officeCancelled) {
          final at = o.tx.cancelledAt ?? o.date;
          if (at.isAfter(since)) since = at;
        } else {
          active = o.id;
        }
      }
      final word = mustReachWordOf(c, messages);
      final overdue =
          word != null &&
          !c.companyCancelled &&
          active == null &&
          e.now.difference(since) > prefs.alertAfter;
      out[c.id] = CompanyTrace(
        companyId: c.id,
        officeIds: [for (final o in hs) o.id],
        activeOfficeId: active,
        possibleOfficeIds: possibleByCompany[c.id] ?? const [],
        mustReach: word != null,
        mustReachWord: word,
        waitingSince: since,
        overdue: overdue,
        cancelled: c.companyCancelled,
      );
    }
    return out;
  }

  // ---------------------------------------------------------
  // التحذيرات
  // ---------------------------------------------------------

  String _snapOf(_Node n) =>
      '${n.current.key}|${n.current.amount.toStringAsFixed(2)}|'
      '${normalizeText(n.current.currency)}';

  String _who(_Node n) => n.isOffice ? 'بالمكتب' : 'بالشركة';

  static String describeEdit(TxHistoryEntry e) {
    final parts = <String>[];
    for (final c in e.changes) {
      switch (c.field) {
        case TxField.beneficiary:
          parts.add('الاسم من «${c.oldValue ?? ''}» لـ «${c.newValue ?? ''}»');
        case TxField.amount:
          final o = c.oldValue;
          final n = c.newValue;
          parts.add(
            'المبلغ من ${o is num ? traceAmount(o.toDouble()) : '$o'} '
            'لـ ${n is num ? traceAmount(n.toDouble()) : '$n'}',
          );
        case TxField.currency:
          parts.add('العملة من «${c.oldValue ?? ''}» لـ «${c.newValue ?? ''}»');
        default:
          break;
      }
    }
    return parts.join('، ');
  }

  String _lastEditText(_Node n) {
    if (n.keyEdits.isEmpty) return '';
    final e = n.keyEdits.first;
    return 'انعدل ${describeEdit(e)} بتاريخ ${_dateTime(e.at)}';
  }

  String _companyLabel(_Node c) => 'شركة ${c.account.name}';

  String _officeLabel(_Node o) => o.account.name;

  List<TraceWarning> warnings(Map<int, CompanyTrace> companyTraces) {
    final out = <TraceWarning>[];
    for (final t in officeTraces.values) {
      final o = nodes[t.officeId]!;
      final brokenId = broken[o.id];
      if (brokenId != null) {
        out.add(
          TraceWarning(
            kind: TraceWarningKind.brokenLink,
            officeId: o.id,
            sig: 'brk:${o.id}:$brokenId',
            title: 'ربط يدوي لحركة ما عادت موجودة',
            detail:
                'كنت رابط حركة «${o.tx.beneficiary}» بـ ${_officeLabel(o)} '
                'بحركة شركة انحذفت أو ما عادت حركة استقبال.',
            at: o.date,
          ),
        );
      }
      if (o.officeCancelled) continue;

      if (t.status == TraceStatus.possible) {
        final issues = t.issues;
        final String title;
        if (issues.contains(TraceIssue.tie)) {
          title = 'في أكتر من احتمال للمصدر';
        } else if (issues.contains(TraceIssue.nameNotExact)) {
          title = 'الاسم مو مطابق تمامًا';
        } else if (issues.contains(TraceIssue.amountDiffers)) {
          title = 'نفس الاسم بس المبلغ مختلف';
        } else {
          title = 'نفس الاسم والمبلغ بس العملة مختلفة';
        }
        final first = t.candidates.first;
        final c = nodes[first.companyId]!;
        final more = t.candidates.length > 1
            ? ' (و${t.candidates.length - 1} احتمال تاني)'
            : '';
        final String detail;
        if (issues.contains(TraceIssue.tie) && t.candidates.length == 1) {
          detail =
              'حركة «${o.tx.beneficiary}» بـ ${_officeLabel(o)} بتطابق حركة '
              '«${c.tx.beneficiary}» بـ ${_companyLabel(c)}، بس في حركة تانية '
              'بالمكاتب بتطابقها كمان، وما منخمّن. اختار أنت.';
        } else if (issues.contains(TraceIssue.tie)) {
          detail =
              'حركة «${o.tx.beneficiary}» بـ ${_officeLabel(o)} بتطابق '
              '${t.candidates.length} حركات بالشركات، وما منخمّن. اختار المصدر '
              'الصح.';
        } else {
          detail =
              'حركة «${o.tx.beneficiary}» بـ ${_officeLabel(o)} ← الأقرب: '
              '«${c.tx.beneficiary}» بـ ${_companyLabel(c)}'
              '${first.nameNote == null ? '' : ' (${first.nameNote})'}'
              '${first.amountSame ? '' : ' • المبلغ ${traceAmount(first.companyAmount)} بدل ${traceAmount(first.officeAmount)}'}'
              '$more';
        }
        out.add(
          TraceWarning(
            kind: TraceWarningKind.choose,
            issues: issues,
            officeId: o.id,
            sig: 'ch:${o.id}',
            title: title,
            detail: detail,
            at: o.date,
          ),
        );
        continue;
      }

      final l = t.link;
      if (l == null || !t.status.linked) continue;
      final c = nodes[l.companyId]!;

      // ملغاة بالشركة بس فعّالة/مسلّمة بالمكتب
      if (c.companyCancelled) {
        final delivered = o.tx.status == TransactionStatus.received;
        out.add(
          TraceWarning(
            kind: TraceWarningKind.companyCancelled,
            officeId: o.id,
            companyId: c.id,
            sig: 'cxl:${o.id}:${c.id}:${o.tx.status.name}',
            title: delivered
                ? 'ملغاة بالشركة بس مسلّمة بالمكتب'
                : 'ملغاة بالشركة بس لسا فعّالة بالمكتب',
            detail:
                'حركة «${c.tx.beneficiary}» انلغت بـ ${_companyLabel(c)}'
                '${c.tx.cancelledAt == null ? '' : ' بتاريخ ${_dateTime(c.tx.cancelledAt!)}'}'
                '، بس بـ ${_officeLabel(o)} ${delivered ? 'انسلمت' : 'لسا مضافة'}.',
            at: o.date,
          ),
        );
      }

      if (t.status == TraceStatus.manual) {
        final d = e.decisions.byOffice[o.id];
        final oChanged = d?.officeSnap != null && d!.officeSnap != _snapOf(o);
        final cChanged = d?.companySnap != null && d!.companySnap != _snapOf(c);
        if (oChanged || cChanged) {
          final sides = oChanged && cChanged
              ? 'الحركتين'
              : (oChanged ? 'حركة المكتب' : 'حركة الشركة');
          final edited = oChanged ? o : c;
          final last = _lastEditText(edited);
          out.add(
            TraceWarning(
              kind: TraceWarningKind.confirmedChanged,
              officeId: o.id,
              companyId: c.id,
              sig:
                  'chg:${o.id}:${c.id}:${_hash('${_snapOf(o)}#${_snapOf(c)}')}',
              title: 'انعدلت $sides بعد ما أكدت الربط',
              detail:
                  '${_companyLabel(c)} ← ${_officeLabel(o)}: '
                  '«${c.tx.beneficiary}» / «${o.tx.beneficiary}».'
                  '${last.isEmpty ? '' : ' $last.'}',
              at: o.date,
            ),
          );
        }
        continue;
      }

      // تلقائي: قديمة؟
      if (l.late) {
        out.add(
          TraceWarning(
            kind: TraceWarningKind.late,
            officeId: o.id,
            companyId: c.id,
            sig: 'late:${o.id}:${c.id}',
            title: 'حركة قديمة',
            detail:
                '${l.rerouteFrom != null ? 'من إلغاء الحركة بالمكتب السابق' : 'من رسالة ${_companyLabel(c)}'} '
                'لحركة ${_officeLabel(o)} مرّ ${traceDuration(l.gap)}، '
                'أكتر من الوقت العادي (${_hours(prefs.normalHoursSafe)}).',
            at: o.date,
          ),
        );
      }

      // تعديل بطرف واحد
      final oe = o.keyEdits.isNotEmpty;
      final ce = c.keyEdits.isNotEmpty;
      if (oe != ce) {
        final edited = oe ? o : c;
        final other = oe ? c : o;
        out.add(
          TraceWarning(
            kind: TraceWarningKind.editedOneSide,
            officeId: o.id,
            companyId: c.id,
            sig:
                'eos:${o.id}:${c.id}:${oe ? 'o' : 'c'}:'
                '${edited.lastKeyEditAt?.millisecondsSinceEpoch ?? 0}',
            title: 'انعدلت ${_who(edited)} بس مو ${_who(other)}',
            detail:
                '${_lastEditText(edited)}. ${_who(other)}: '
                        '«${other.tx.beneficiary}» ${traceAmount(other.tx.amount)} '
                        '${other.tx.currency}'
                    .trim(),
            at: o.date,
          ),
        );
      } else if (oe && ce) {
        final differs =
            o.current.key != c.current.key ||
            o.current.amountKey != c.current.amountKey ||
            compareCurrency(o.current.currency, c.current.currency) == false;
        if (differs) {
          out.add(
            TraceWarning(
              kind: TraceWarningKind.valuesDiffer,
              officeId: o.id,
              companyId: c.id,
              sig:
                  'dif:${o.id}:${c.id}:${_hash('${_snapOf(o)}#${_snapOf(c)}')}',
              title: 'انعدلت الحركتين بس صاروا مختلفين',
              detail:
                  'بالشركة: «${c.tx.beneficiary}» ${traceAmount(c.tx.amount)} '
                  '${c.tx.currency} • بالمكتب: «${o.tx.beneficiary}» '
                  '${traceAmount(o.tx.amount)} ${o.tx.currency}',
              at: o.date,
            ),
          );
        }
      }
    }

    for (final ct in companyTraces.values) {
      if (!ct.overdue) continue;
      final c = nodes[ct.companyId]!;
      final hadCancelled = ct.officeIds.isNotEmpty;
      final lastOffice = hadCancelled ? nodes[ct.officeIds.last] : null;
      out.add(
        TraceWarning(
          kind: TraceWarningKind.notReached,
          companyId: c.id,
          sig: 'nr:${c.id}:${ct.waitingSince.millisecondsSinceEpoch}',
          title: 'ما راحت لمكتب',
          detail:
              '«${c.tx.beneficiary}» ${traceAmount(c.tx.amount)} ${c.tx.currency} '
              'بـ ${_companyLabel(c)} فيها «${ct.mustReachWord}» '
              '${lastOffice != null ? 'وانلغت من ${_officeLabel(lastOffice)} ' : ''}'
              'وصار إلها ${traceDuration(e.now.difference(ct.waitingSince))} '
              'ما انربطت بحركة مكتب.',
          at: c.date,
        ),
      );
    }
    if (prefs.warnDays > 0) {
      final from = e.now.subtract(Duration(days: prefs.warnDays));
      out.removeWhere((w) => w.at.isBefore(from));
    }
    out.sort((a, b) {
      final x = b.at.compareTo(a.at);
      return x != 0 ? x : a.sig.compareTo(b.sig);
    });
    return out;
  }

  // ---------------------------------------------------------
  // الشرح «ليش؟»
  // ---------------------------------------------------------

  String _gapText(TraceMatch m) {
    if (m.gap.isNegative) {
      return 'حركة المكتب قبل ${m.rerouteFrom != null ? 'الإلغاء' : 'رسالة الشركة'} '
          'بـ ${traceDuration(m.gap)}';
    }
    return 'حركة المكتب بعد ${m.rerouteFrom != null ? 'إلغاء المكتب السابق' : 'رسالة الشركة'} '
        'بـ ${traceDuration(m.gap)}';
  }

  List<TraceReason> matchReasons(TraceMatch m, {required bool manual}) {
    final out = <TraceReason>[];
    // الاسم
    if (m.exactName) {
      final past = <String>[
        if (m.officeNamePast) 'حركة المكتب',
        if (m.companyNamePast) 'حركة الشركة',
      ];
      out.add(
        TraceReason(
          TraceReasonTone.good,
          past.isEmpty
              ? 'الاسم مطابق تمامًا: «${m.companyName}»'
              : 'الاسم مطابق بالاسم السابق لـ ${past.join(' و')}: «${m.officeName}»',
        ),
      );
      if (m.officeName != m.companyName && past.isEmpty) {
        out.add(
          TraceReason(
            TraceReasonTone.info,
            'نفس الاسم بس مكتوب بشكل مختلف شوي: «${m.officeName}» / «${m.companyName}»',
          ),
        );
      }
    } else if (m.nameFit == TraceNameFit.similar) {
      out.add(
        TraceReason(
          TraceReasonTone.warn,
          'الاسم مو مطابق تمامًا: «${m.officeName}» / «${m.companyName}»'
          '${m.nameNote == null ? '' : ' — ${m.nameNote}'}'
          '${manual ? ' (أكدته أنت)' : ''}',
        ),
      );
    } else {
      out.add(
        TraceReason(
          TraceReasonTone.bad,
          'الاسم مختلف: «${m.officeName}» / «${m.companyName}»'
          '${manual ? ' (أكدته أنت)' : ''}',
        ),
      );
    }
    // المبلغ
    final amountPast = <String>[
      if (m.officeAmountPast) 'حركة المكتب',
      if (m.companyAmountPast) 'حركة الشركة',
    ];
    if (m.amountSame) {
      out.add(
        TraceReason(
          TraceReasonTone.good,
          amountPast.isEmpty
              ? 'المبلغ نفسه: ${traceAmount(m.companyAmount)}'
              : 'المبلغ نفسه بالمبلغ السابق لـ ${amountPast.join(' و')}: ${traceAmount(m.companyAmount)}',
        ),
      );
    } else {
      out.add(
        TraceReason(
          TraceReasonTone.warn,
          'المبلغ مختلف: بالشركة ${traceAmount(m.companyAmount)} وبالمكتب ${traceAmount(m.officeAmount)}',
        ),
      );
    }
    // العملة
    if (m.currencySame == true) {
      out.add(
        TraceReason(
          TraceReasonTone.good,
          'العملة نفسها: ${m.companyCurrency.isEmpty ? m.officeCurrency : m.companyCurrency}',
        ),
      );
    } else if (m.currencySame == false) {
      out.add(
        TraceReason(
          TraceReasonTone.warn,
          'العملة مختلفة: ${m.companyCurrency} / ${m.officeCurrency}',
        ),
      );
    } else {
      out.add(
        const TraceReason(
          TraceReasonTone.info,
          'العملة مو معروفة بأحد الطرفين، فما منعت الربط',
        ),
      );
    }
    // الوقت
    final TraceReasonTone timeTone;
    String timeNote = '';
    if (m.tooEarly || m.tooOld) {
      timeTone = TraceReasonTone.bad;
      timeNote = m.tooOld
          ? ' (أكتر من أقصى وقت ${_hours(prefs.maxHoursSafe)})'
          : ' (أكتر من السماحية ${traceDuration(prefs.earlyTolerance)})';
    } else if (m.late) {
      timeTone = TraceReasonTone.warn;
      timeNote =
          ' (أكتر من الوقت العادي ${_hours(prefs.normalHoursSafe)}، '
          'بس ضمن أقصى وقت ${_hours(prefs.maxHoursSafe)})';
    } else if (m.gap.isNegative) {
      timeTone = TraceReasonTone.info;
      timeNote = ' (ضمن السماحية)';
    } else {
      timeTone = TraceReasonTone.good;
      timeNote = ' (ضمن الوقت العادي ${_hours(prefs.normalHoursSafe)})';
    }
    out.add(TraceReason(timeTone, '${_gapText(m)}$timeNote'));
    if (m.rerouteFrom != null) {
      final prev = nodes[m.rerouteFrom!];
      out.add(
        TraceReason(
          TraceReasonTone.info,
          'رجعت بعد ما انلغت${prev == null ? '' : ' من ${_officeLabel(prev)}'}، '
          'فالوقت محسوب من وقت الإلغاء',
        ),
      );
    }
    if (m.companyCancelledBefore) {
      out.add(
        const TraceReason(
          TraceReasonTone.bad,
          'حركة الشركة كانت ملغاة قبل حركة المكتب',
        ),
      );
    }
    return out;
  }

  String _rejectReason(_Node o, _Node c, TraceMatch m) {
    final rej = e.decisions.rejected[o.id]?.contains(c.id) ?? false;
    if (rej) return 'استبعدتها أنت («مو هي»)';
    if (m.tooEarly) {
      return 'رسالة الشركة بعد حركة المكتب بـ ${traceDuration(m.gap)}';
    }
    if (m.tooOld) {
      return 'أقدم من أقصى وقت: ${traceDuration(m.gap)} '
          '(الحد ${_hours(prefs.maxHoursSafe)})';
    }
    final h = holderOf(c.id, o);
    if (h != null) {
      return 'مربوطة بحركة تانية: ${_officeLabel(h)} («${h.tx.beneficiary}»)';
    }
    if (m.companyCancelledBefore) return 'ملغاة بالشركة قبل حركة المكتب';
    if (m.nameFit == TraceNameFit.different) return 'الاسم مختلف';
    final issues = m.issues.map((i) => i.label).join(' و');
    return issues.isEmpty ? 'بتطابق بس في احتمال أقوى' : issues;
  }

  TraceExplanation explainOffice(int id, TraceResult r) {
    final o = nodes[id]!;
    final t = officeTraces[id]!;
    final reasons = <TraceReason>[];
    final skip = <int>{};
    switch (t.status) {
      case TraceStatus.manual:
        final d = e.decisions.byOffice[id];
        reasons.add(
          TraceReason(
            TraceReasonTone.info,
            'أنت حددت هالمصدر يدويًا${d == null ? '' : ' بتاريخ ${_dateTime(d.at)}'}، '
            'وما بيتغير تلقائيًا.',
          ),
        );
        reasons.addAll(matchReasons(t.link!, manual: true));
        skip.add(t.link!.companyId);
      case TraceStatus.auto:
        reasons.add(
          const TraceReason(
            TraceReasonTone.good,
            'انربطت تلقائيًا لأنها الحركة الوحيدة يلي بتطابق الاسم والمبلغ والوقت.',
          ),
        );
        reasons.addAll(matchReasons(t.link!, manual: false));
        skip.add(t.link!.companyId);
      case TraceStatus.autoOrder:
        reasons.add(
          const TraceReason(
            TraceReasonTone.info,
            'في حركات متطابقة تمامًا من نفس الشركة (نفس الاسم والمبلغ)، '
            'فانربطت حسب الترتيب الزمني. الشركة نفسها بكل الأحوال.',
          ),
        );
        reasons.addAll(matchReasons(t.link!, manual: false));
        skip.add(t.link!.companyId);
      case TraceStatus.possible:
        reasons.add(
          TraceReason(
            TraceReasonTone.warn,
            t.issues.contains(TraceIssue.tie)
                ? 'في ${t.candidates.length == 1 ? 'حركة بتطابق بس في حركة تانية بالمكتب بتطابقها كمان' : '${t.candidates.length} حركات بتطابق'}، وما منخمّن: اختار أنت.'
                : 'ما في تطابق تام. الأقرب: ${t.candidates.first.issues.map((i) => i.label).join(' و')}. اختار أنت.',
          ),
        );
        reasons.addAll(matchReasons(t.candidates.first, manual: false));
        for (final m in t.candidates) {
          skip.add(m.companyId);
        }
      case TraceStatus.unknownManual:
        reasons.add(
          TraceReason(
            TraceReasonTone.info,
            'أنت حددت المصدر «${prefs.unknown}» يدويًا.',
          ),
        );
      case TraceStatus.unknown:
        reasons.add(
          TraceReason(
            TraceReasonTone.info,
            'ما في حركة استقبال بحساب شركة بنفس الاسم والمبلغ خلال '
            '${_hours(prefs.maxHoursSafe)} قبل حركة المكتب.',
          ),
        );
    }
    if (t.brokenCompanyId != null) {
      reasons.add(
        const TraceReason(
          TraceReasonTone.bad,
          'كان في ربط يدوي لحركة شركة انحذفت أو ما عادت حركة استقبال.',
        ),
      );
    }

    // مرشحين ما انختاروا
    final rejected = <TraceRejected>[];
    final from = o.date.subtract(const Duration(days: 7));
    final to = o.date.add(const Duration(days: 1));
    final seen = <int>{...skip};
    for (final s in o.states) {
      if (s.key.isNotEmpty) {
        for (final c in inRange(byName[s.key] ?? const [], from, to)) {
          if (!seen.add(c.id)) continue;
          final m = evaluate(o, c, force: true);
          if (m != null) {
            rejected.add(TraceRejected(c.id, _rejectReason(o, c, m), m));
          }
        }
      }
      if (s.amountKey >= 0) {
        for (final c in inRange(byAmount[s.amountKey] ?? const [], from, to)) {
          if (seen.contains(c.id)) continue;
          final m = evaluate(o, c, force: true);
          if (m == null || m.nameFit == TraceNameFit.different) continue;
          seen.add(c.id);
          rejected.add(TraceRejected(c.id, _rejectReason(o, c, m), m));
        }
      }
    }
    rejected.sort((a, b) => a.match!.gap.abs().compareTo(b.match!.gap.abs()));
    return TraceExplanation(reasons, rejected.take(10).toList());
  }

  TraceExplanation explainCompany(int id, TraceResult r) {
    final c = nodes[id]!;
    final ct = r.company[id]!;
    final reasons = <TraceReason>[];
    if (ct.officeIds.isEmpty) {
      reasons.add(
        TraceReason(
          ct.overdue ? TraceReasonTone.bad : TraceReasonTone.info,
          'لسا ما في حركة بحساب مكتب مربوطة فيها.',
        ),
      );
    }
    for (final oid in ct.officeIds) {
      final o = nodes[oid]!;
      final t = officeTraces[oid]!;
      final m = t.link!;
      final how = t.status == TraceStatus.manual
          ? 'يدويًا'
          : (t.status == TraceStatus.autoOrder ? 'بالترتيب' : 'تلقائيًا');
      reasons.add(
        TraceReason(
          o.officeCancelled ? TraceReasonTone.warn : TraceReasonTone.good,
          'راحت لـ ${_officeLabel(o)} ($how) بعد ${traceDuration(m.gap)}'
          '${o.officeCancelled ? ' وانلغت هناك${o.tx.cancelledAt == null ? '' : ' بتاريخ ${_dateTime(o.tx.cancelledAt!)}'}' : ''}',
        ),
      );
      if (!m.strong) {
        reasons.add(
          TraceReason(
            TraceReasonTone.warn,
            '  ${m.issues.map((i) => i.label).join(' و')}',
          ),
        );
      }
    }
    if (ct.possibleOfficeIds.isNotEmpty) {
      reasons.add(
        TraceReason(
          TraceReasonTone.warn,
          'في ${ct.possibleOfficeIds.length == 1 ? 'حركة مكتب محتملة' : '${ct.possibleOfficeIds.length} حركات مكتب محتملة'} بدها تأكيد.',
        ),
      );
    }
    if (ct.mustReach) {
      reasons.add(
        TraceReason(
          TraceReasonTone.info,
          'فيها كلمة «${ct.mustReachWord}» من كلمات «لازم تروح لمكتب».',
        ),
      );
    }
    if (ct.overdue) {
      reasons.add(
        TraceReason(
          TraceReasonTone.bad,
          'صار إلها ${traceDuration(e.now.difference(ct.waitingSince))} وما راحت '
          'لمكتب (التنبيه بعد ${_hours(prefs.alertAfter.inHours)}).',
        ),
      );
    }
    if (c.companyCancelled) {
      reasons.add(
        const TraceReason(TraceReasonTone.warn, 'هالحركة ملغاة بالشركة.'),
      );
    }

    // حركات مكاتب قريبة ما انربطت
    final rejected = <TraceRejected>[];
    final skip = <int>{...ct.officeIds};
    final from = c.date.subtract(prefs.earlyTolerance);
    final to = c.date.add(const Duration(days: 7));
    for (final o in inRange(offices, from, to)) {
      if (skip.contains(o.id)) continue;
      final m = evaluate(o, c, force: true);
      if (m == null) continue;
      if (!m.exactName &&
          !(m.nameFit == TraceNameFit.similar && m.amountSame)) {
        continue;
      }
      final t = officeTraces[o.id];
      String reason;
      if (t != null && t.status.linked && t.link!.companyId != c.id) {
        final other = nodes[t.link!.companyId];
        reason =
            'مربوطة بحركة شركة تانية${other == null ? '' : ': ${_companyLabel(other)} (${_dateTime(other.date)})'}';
      } else if (t != null && t.status == TraceStatus.unknownManual) {
        reason = 'أنت حددت مصدرها «${prefs.unknown}»';
      } else if (t != null &&
          t.status == TraceStatus.possible &&
          t.candidates.any((x) => x.companyId == c.id)) {
        reason = 'محتملة — بدها تأكيد';
      } else if (e.decisions.rejected[o.id]?.contains(c.id) ?? false) {
        reason = 'استبعدتها أنت («مو هي»)';
      } else if (m.tooOld) {
        reason = 'بعد أقصى وقت: ${traceDuration(m.gap)}';
      } else if (m.tooEarly) {
        reason = 'حركة المكتب قبل رسالة الشركة بـ ${traceDuration(m.gap)}';
      } else {
        final issues = m.issues.map((i) => i.label).join(' و');
        reason = issues.isEmpty ? 'بتطابق بس في احتمال أقوى' : issues;
      }
      rejected.add(TraceRejected(o.id, reason, m));
      if (rejected.length >= 10) break;
    }
    return TraceExplanation(reasons, rejected);
  }

  // ---------------------------------------------------------
  // خيارات «تغيير»
  // ---------------------------------------------------------

  List<TraceOption> companyOptions(
    int officeId, {
    required Duration back,
    required Duration ahead,
  }) {
    final o = nodes[officeId];
    if (o == null) return const [];
    final out = <TraceOption>[];
    for (final c in inRange(
      companies,
      o.date.subtract(back),
      o.date.add(ahead),
    )) {
      final m = evaluate(o, c, force: true);
      if (m == null) continue;
      final h = holderOf(c.id, o);
      out.add(
        TraceOption(
          c.id,
          m,
          h?.id,
          h != null && linkStatus[h.id] == TraceStatus.manual,
        ),
      );
    }
    out.sort((a, b) => _compareMatches(a.match, b.match));
    return out;
  }

  List<TraceOption> officeOptions(int companyId, {required Duration ahead}) {
    final c = nodes[companyId];
    if (c == null) return const [];
    final out = <TraceOption>[];
    for (final o in inRange(
      offices,
      c.date.subtract(prefs.earlyTolerance),
      c.date.add(ahead),
    )) {
      final m = evaluate(o, c, force: true);
      if (m == null) continue;
      final l = links[o.id];
      // «ماسكة» هون: حركة المكتب مربوطة بحركة شركة تانية
      final heldBy = l != null && l.companyId != companyId ? l.companyId : null;
      out.add(
        TraceOption(
          o.id,
          m,
          heldBy,
          heldBy != null && linkStatus[o.id] == TraceStatus.manual,
        ),
      );
    }
    out.sort((a, b) => _compareMatches(a.match, b.match));
    return out;
  }
}
