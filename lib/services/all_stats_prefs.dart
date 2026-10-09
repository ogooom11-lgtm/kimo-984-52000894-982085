// lib/services/all_stats_prefs.dart
// -------------------------------------------------------------
// تخصيص صفحة «إحصائيات كل الحسابات» — بينحفظ بصندوق ui_prefs والصفحة
// بترجع متل ما تركتها كل مرة بتفتحها:
//  • الأقسام (مضافة/مستلمة/ملغاة/غير مستلمة — وللشركات إرسال/استقبال/…):
//    الترتيب، الإظهار، اسم مخصص، لون — لكل نوع حسابات لحالو.
//  • الحسابات: إخفاء حسابات من الصفحة (وما بتنحسب بالمجاميع) + ترتيب يدوي.
//  • الملخص السريع: الحسابات جوّا البطاقات (كم واحد)، المبالغ حسب العملة،
//    إخفاء الحسابات يلي ما إلها حركات، التغيّر عن الفترة السابقة.
//  • الشكل: عدد الأعمدة، الحجم، الهيدر، البطاقات الإجمالية، العنوان…
//  • آخر فترة/ترتيب/نوع حسابات اخترتهن.
// -------------------------------------------------------------

import 'package:flutter/material.dart';

import '../database_service.dart';
import '../models.dart';

enum AllStatsPeriod { daily, monthly }

enum AccountSortMode { priority, name, operations, trend, amount, manual }

/// أقسام الإحصائيات (للشركات: إرسال، استقبال، إلغاء مرسل، إلغاء استقبال)
enum StatsMetric { added, received, cancelled, unreceived }

/// لون من لوحة ألوان البطاقات (تدرّج من لونين)
class StatsPaletteColor {
  final String name;
  final List<Color> colors;
  const StatsPaletteColor(this.name, this.colors);
}

const List<StatsPaletteColor> kStatsPalette = [
  StatsPaletteColor('أزرق', [Color(0xFF1E88E5), Color(0xFF42A5F5)]),
  StatsPaletteColor('أخضر', [Color(0xFF2E7D32), Color(0xFF66BB6A)]),
  StatsPaletteColor('أحمر', [Color(0xFFC62828), Color(0xFFEF5350)]),
  StatsPaletteColor('بنفسجي', [Color(0xFF6A1B9A), Color(0xFFAB47BC)]),
  StatsPaletteColor('نيلي', [Color(0xFF4338CA), Color(0xFF7C3AED)]),
  StatsPaletteColor('فيروزي', [Color(0xFF0F766E), Color(0xFF14B8A6)]),
  StatsPaletteColor('برتقالي', [Color(0xFF9A3412), Color(0xFFF97316)]),
  StatsPaletteColor('وردي', [Color(0xFFBE123C), Color(0xFFF43F5E)]),
  StatsPaletteColor('ذهبي', [Color(0xFFB45309), Color(0xFFF59E0B)]),
  StatsPaletteColor('سماوي', [Color(0xFF0369A1), Color(0xFF38BDF8)]),
  StatsPaletteColor('رمادي', [Color(0xFF334155), Color(0xFF64748B)]),
  StatsPaletteColor('بني', [Color(0xFF5D4037), Color(0xFF8D6E63)]),
  StatsPaletteColor('ليلي', [Color(0xFF111827), Color(0xFF374151)]),
];

/// رقم اللون الأصلي لكل قسم حسب نوع الحسابات
int statsDefaultColor(StatsMetric m, {required bool company}) {
  switch (m) {
    case StatsMetric.added:
      return company ? 4 : 0;
    case StatsMetric.received:
      return company ? 5 : 1;
    case StatsMetric.cancelled:
      return company ? 7 : 2;
    case StatsMetric.unreceived:
      return company ? 6 : 3;
  }
}

/// الاسم الأصلي لكل قسم حسب نوع الحسابات
String statsDefaultLabel(StatsMetric m, {required bool company}) {
  switch (m) {
    case StatsMetric.added:
      return company ? 'إرسال' : 'مضافة';
    case StatsMetric.received:
      return company ? 'استقبال' : 'مستلمة';
    case StatsMetric.cancelled:
      return company ? 'إلغاء مرسل' : 'ملغاة';
    case StatsMetric.unreceived:
      return company ? 'إلغاء استقبال' : 'غير مستلمة';
  }
}

IconData statsMetricIcon(StatsMetric m, {required bool company}) {
  switch (m) {
    case StatsMetric.added:
      return company ? Icons.outbox_rounded : Icons.add_circle_outline_rounded;
    case StatsMetric.received:
      return company
          ? Icons.move_to_inbox_rounded
          : Icons.check_circle_outline_rounded;
    case StatsMetric.cancelled:
      return company ? Icons.cancel_rounded : Icons.cancel_outlined;
    case StatsMetric.unreceived:
      return company ? Icons.cancel_rounded : Icons.hourglass_empty_rounded;
  }
}

/// إعداد قسم واحد
class StatsMetricPref {
  final StatsMetric metric;
  final bool visible;

  /// اسم مخصص ('' = الاسم الأصلي)
  final String label;

  /// رقم اللون من [kStatsPalette] (-1 = اللون الأصلي)
  final int color;

  const StatsMetricPref(
    this.metric, {
    this.visible = true,
    this.label = '',
    this.color = -1,
  });

  StatsMetricPref copyWith({bool? visible, String? label, int? color}) =>
      StatsMetricPref(
        metric,
        visible: visible ?? this.visible,
        label: label ?? this.label,
        color: color ?? this.color,
      );

  Map<String, dynamic> toMap() => {
    'm': metric.name,
    'on': visible,
    'label': label,
    'color': color,
  };

  static StatsMetricPref? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['m'];
    StatsMetric? metric;
    for (final m in StatsMetric.values) {
      if (m.name == name) metric = m;
    }
    if (metric == null) return null;
    final c = raw['color'];
    final color = c is num ? c.toInt() : -1;
    return StatsMetricPref(
      metric,
      visible: raw['on'] is bool ? raw['on'] as bool : true,
      label: raw['label'] is String ? (raw['label'] as String).trim() : '',
      color: color >= 0 && color < kStatsPalette.length ? color : -1,
    );
  }
}

const List<StatsMetricPref> _kDefaultMetrics = [
  StatsMetricPref(StatsMetric.added),
  StatsMetricPref(StatsMetric.received),
  StatsMetricPref(StatsMetric.cancelled),
  StatsMetricPref(StatsMetric.unreceived),
];

/// كل القسم مرة وحدة، والناقص بينضاف بالآخر بالإعداد الأصلي
List<StatsMetricPref> normalizeStatsMetrics(Iterable<StatsMetricPref> list) {
  final out = <StatsMetricPref>[];
  for (final p in list) {
    if (out.any((e) => e.metric == p.metric)) continue;
    out.add(p);
  }
  for (final m in StatsMetric.values) {
    if (!out.any((e) => e.metric == m)) out.add(StatsMetricPref(m));
  }
  return List.unmodifiable(out);
}

class AllStatsPrefs {
  final List<StatsMetricPref> officeMetrics;
  final List<StatsMetricPref> companyMetrics;

  /// حسابات مخفية من الصفحة (وما بتنحسب بالمجاميع)
  final Set<int> hiddenAccounts;

  /// الترتيب اليدوي (لما يكون الترتيب «يدوي»)
  final List<int> officeOrder;
  final List<int> companyOrder;

  final bool showHeader;
  final bool showQuickStats;
  final bool showGlobalCards;
  final bool showAccountCards;
  final bool showCurrencyRows;

  /// التغيّر عن الفترة السابقة (بكل البطاقات)
  final bool showDelta;
  final bool showAccountsInQuick;
  final bool hideHeaderInExport;

  /// كم حساب جوّا كل بطاقة بالملخص السريع (0 = الكل)
  final int quickAccountsLimit;

  /// المبالغ حسب العملة جوّا بطاقات الملخص السريع
  final bool quickShowAmounts;

  /// إخفاء الحسابات يلي ما إلها حركات بالفترة
  final bool hideZeroAccounts;

  /// أعمدة الملخص السريع: 0 تلقائي، 1، 2
  final int columns;

  /// بطاقات أصغر
  final bool compact;

  /// عنوان الصفحة بالهيدر والصورة ('' = الأصلي)
  final String title;

  final AllStatsPeriod period;
  final AccountSortMode sortMode;
  final AccountType accountType;

  static const List<int> accountLimits = [0, 3, 5, 10];

  const AllStatsPrefs({
    this.officeMetrics = _kDefaultMetrics,
    this.companyMetrics = _kDefaultMetrics,
    this.hiddenAccounts = const {},
    this.officeOrder = const [],
    this.companyOrder = const [],
    this.showHeader = true,
    this.showQuickStats = true,
    this.showGlobalCards = false,
    this.showAccountCards = false,
    this.showCurrencyRows = true,
    this.showDelta = true,
    this.showAccountsInQuick = true,
    this.hideHeaderInExport = false,
    this.quickAccountsLimit = 0,
    this.quickShowAmounts = false,
    this.hideZeroAccounts = false,
    this.columns = 0,
    this.compact = false,
    this.title = '',
    this.period = AllStatsPeriod.daily,
    this.sortMode = AccountSortMode.priority,
    this.accountType = AccountType.office,
  });

  List<StatsMetricPref> metricsFor(AccountType t) =>
      t.isCompany ? companyMetrics : officeMetrics;

  List<int> orderFor(AccountType t) => t.isCompany ? companyOrder : officeOrder;

  /// الأقسام الظاهرة بالترتيب
  List<StatsMetric> visibleMetrics(AccountType t) => [
    for (final m in metricsFor(t))
      if (m.visible) m.metric,
  ];

  StatsMetricPref prefOf(StatsMetric m, AccountType t) => metricsFor(
    t,
  ).firstWhere((p) => p.metric == m, orElse: () => StatsMetricPref(m));

  String labelOf(StatsMetric m, AccountType t) {
    final custom = prefOf(m, t).label.trim();
    return custom.isEmpty ? statsDefaultLabel(m, company: t.isCompany) : custom;
  }

  int colorIndexOf(StatsMetric m, AccountType t) {
    final c = prefOf(m, t).color;
    return c >= 0 && c < kStatsPalette.length
        ? c
        : statsDefaultColor(m, company: t.isCompany);
  }

  List<Color> gradientOf(StatsMetric m, AccountType t) =>
      kStatsPalette[colorIndexOf(m, t)].colors;

  bool isHidden(int accountId) => hiddenAccounts.contains(accountId);

  /// عدد الأشياء المغيّرة عن الأصل (للعرض بالإعدادات)
  int get customizedCount {
    var n = 0;
    for (final list in [officeMetrics, companyMetrics]) {
      for (var i = 0; i < list.length; i++) {
        final p = list[i];
        if (!p.visible || p.label.isNotEmpty || p.color >= 0) n++;
        if (p.metric != StatsMetric.values[i]) n++;
      }
    }
    if (hiddenAccounts.isNotEmpty) n++;
    if (sortMode == AccountSortMode.manual) n++;
    if (quickAccountsLimit != 0) n++;
    if (quickShowAmounts) n++;
    if (hideZeroAccounts) n++;
    if (columns != 0) n++;
    if (compact) n++;
    if (title.isNotEmpty) n++;
    if (!showHeader || !showQuickStats || showGlobalCards) n++;
    if (showAccountCards || !showCurrencyRows || !showDelta) n++;
    if (!showAccountsInQuick || hideHeaderInExport) n++;
    return n;
  }

  AllStatsPrefs copyWith({
    List<StatsMetricPref>? officeMetrics,
    List<StatsMetricPref>? companyMetrics,
    Set<int>? hiddenAccounts,
    List<int>? officeOrder,
    List<int>? companyOrder,
    bool? showHeader,
    bool? showQuickStats,
    bool? showGlobalCards,
    bool? showAccountCards,
    bool? showCurrencyRows,
    bool? showDelta,
    bool? showAccountsInQuick,
    bool? hideHeaderInExport,
    int? quickAccountsLimit,
    bool? quickShowAmounts,
    bool? hideZeroAccounts,
    int? columns,
    bool? compact,
    String? title,
    AllStatsPeriod? period,
    AccountSortMode? sortMode,
    AccountType? accountType,
  }) => AllStatsPrefs(
    officeMetrics: officeMetrics ?? this.officeMetrics,
    companyMetrics: companyMetrics ?? this.companyMetrics,
    hiddenAccounts: hiddenAccounts ?? this.hiddenAccounts,
    officeOrder: officeOrder ?? this.officeOrder,
    companyOrder: companyOrder ?? this.companyOrder,
    showHeader: showHeader ?? this.showHeader,
    showQuickStats: showQuickStats ?? this.showQuickStats,
    showGlobalCards: showGlobalCards ?? this.showGlobalCards,
    showAccountCards: showAccountCards ?? this.showAccountCards,
    showCurrencyRows: showCurrencyRows ?? this.showCurrencyRows,
    showDelta: showDelta ?? this.showDelta,
    showAccountsInQuick: showAccountsInQuick ?? this.showAccountsInQuick,
    hideHeaderInExport: hideHeaderInExport ?? this.hideHeaderInExport,
    quickAccountsLimit: quickAccountsLimit ?? this.quickAccountsLimit,
    quickShowAmounts: quickShowAmounts ?? this.quickShowAmounts,
    hideZeroAccounts: hideZeroAccounts ?? this.hideZeroAccounts,
    columns: columns ?? this.columns,
    compact: compact ?? this.compact,
    title: title ?? this.title,
    period: period ?? this.period,
    sortMode: sortMode ?? this.sortMode,
    accountType: accountType ?? this.accountType,
  );

  AllStatsPrefs withMetrics(AccountType t, List<StatsMetricPref> list) {
    final norm = normalizeStatsMetrics(list);
    return t.isCompany
        ? copyWith(companyMetrics: norm)
        : copyWith(officeMetrics: norm);
  }

  /// يغيّر إعداد قسم واحد
  AllStatsPrefs updateMetric(
    AccountType t,
    StatsMetric m,
    StatsMetricPref Function(StatsMetricPref p) fn,
  ) => withMetrics(t, [
    for (final p in metricsFor(t)) p.metric == m ? fn(p) : p,
  ]);

  AllStatsPrefs withOrder(AccountType t, List<int> ids) => t.isCompany
      ? copyWith(companyOrder: List.unmodifiable(ids))
      : copyWith(officeOrder: List.unmodifiable(ids));

  AllStatsPrefs withAccountHidden(int id, bool hidden) {
    final next = {...hiddenAccounts};
    hidden ? next.add(id) : next.remove(id);
    return copyWith(hiddenAccounts: Set.unmodifiable(next));
  }

  Map<String, dynamic> toMap() => {
    'v': 1,
    'officeMetrics': [for (final m in officeMetrics) m.toMap()],
    'companyMetrics': [for (final m in companyMetrics) m.toMap()],
    'hidden': hiddenAccounts.toList(),
    'officeOrder': officeOrder,
    'companyOrder': companyOrder,
    'showHeader': showHeader,
    'showQuickStats': showQuickStats,
    'showGlobalCards': showGlobalCards,
    'showAccountCards': showAccountCards,
    'showCurrencyRows': showCurrencyRows,
    'showDelta': showDelta,
    'showAccountsInQuick': showAccountsInQuick,
    'hideHeaderInExport': hideHeaderInExport,
    'quickAccountsLimit': quickAccountsLimit,
    'quickShowAmounts': quickShowAmounts,
    'hideZeroAccounts': hideZeroAccounts,
    'columns': columns,
    'compact': compact,
    'title': title,
    'period': period.name,
    'sortMode': sortMode.name,
    'accountType': accountType.name,
  };

  factory AllStatsPrefs.fromMap(Object? raw) {
    if (raw is! Map) return const AllStatsPrefs();
    const d = AllStatsPrefs();
    bool b(String k, bool def) {
      final v = raw[k];
      return v is bool ? v : def;
    }

    int i(String k, int def, int min, int max) {
      final v = raw[k];
      if (v is! num) return def;
      final n = v.toInt();
      return n < min || n > max ? def : n;
    }

    List<int> ids(String k) {
      final v = raw[k];
      if (v is! List) return const [];
      final out = <int>[];
      for (final x in v) {
        final n = x is num ? x.toInt() : int.tryParse('$x');
        if (n != null && !out.contains(n)) out.add(n);
      }
      return List.unmodifiable(out);
    }

    List<StatsMetricPref> metrics(String k) {
      final v = raw[k];
      if (v is! List) return _kDefaultMetrics;
      return normalizeStatsMetrics([
        for (final x in v)
          if (StatsMetricPref.fromMap(x) case final p?) p,
      ]);
    }

    T byName<T extends Enum>(List<T> values, String k, T def) {
      final v = raw[k];
      for (final e in values) {
        if (e.name == v) return e;
      }
      return def;
    }

    final limit = i('quickAccountsLimit', 0, 0, 100);
    return AllStatsPrefs(
      officeMetrics: metrics('officeMetrics'),
      companyMetrics: metrics('companyMetrics'),
      hiddenAccounts: Set.unmodifiable(ids('hidden')),
      officeOrder: ids('officeOrder'),
      companyOrder: ids('companyOrder'),
      showHeader: b('showHeader', d.showHeader),
      showQuickStats: b('showQuickStats', d.showQuickStats),
      showGlobalCards: b('showGlobalCards', d.showGlobalCards),
      showAccountCards: b('showAccountCards', d.showAccountCards),
      showCurrencyRows: b('showCurrencyRows', d.showCurrencyRows),
      showDelta: b('showDelta', d.showDelta),
      showAccountsInQuick: b('showAccountsInQuick', d.showAccountsInQuick),
      hideHeaderInExport: b('hideHeaderInExport', d.hideHeaderInExport),
      quickAccountsLimit: accountLimits.contains(limit) ? limit : 0,
      quickShowAmounts: b('quickShowAmounts', d.quickShowAmounts),
      hideZeroAccounts: b('hideZeroAccounts', d.hideZeroAccounts),
      columns: i('columns', 0, 0, 2),
      compact: b('compact', d.compact),
      title: raw['title'] is String ? (raw['title'] as String).trim() : '',
      period: byName(AllStatsPeriod.values, 'period', d.period),
      sortMode: byName(AccountSortMode.values, 'sortMode', d.sortMode),
      accountType: byName(AccountType.values, 'accountType', d.accountType),
    );
  }
}

/// حفظ وتحميل التخصيص (الصفحة بتسمع للتغييرات)
class AllStatsPrefsStore {
  AllStatsPrefsStore._();

  static const String _key = 'all_accounts_stats';
  static bool _loaded = false;

  static final ValueNotifier<AllStatsPrefs> prefs =
      ValueNotifier<AllStatsPrefs>(const AllStatsPrefs());

  /// يقرأ التخصيص المحفوظ (مرة وحدة)
  static AllStatsPrefs load() {
    if (!_loaded) {
      try {
        final box = DatabaseService.uiPrefsBoxOrNull;
        if (box != null) {
          prefs.value = AllStatsPrefs.fromMap(box.get(_key));
          _loaded = true;
        }
      } catch (_) {}
    }
    return prefs.value;
  }

  static Future<void> save(AllStatsPrefs p) async {
    prefs.value = p;
    _loaded = true;
    try {
      await DatabaseService.uiPrefsBoxOrNull?.put(_key, p.toMap());
    } catch (_) {}
  }
}
