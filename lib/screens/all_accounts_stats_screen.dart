import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/all_stats_prefs.dart';
import '../services/period_stats.dart';
import 'all_stats_customize_screen.dart';

class AllAccountsStatsScreen extends StatefulWidget {
  const AllAccountsStatsScreen({super.key});

  @override
  State<AllAccountsStatsScreen> createState() => _AllAccountsStatsScreenState();
}

class _AllAccountsStatsScreenState extends State<AllAccountsStatsScreen> {
  final GlobalKey _shotKey = GlobalKey();

  static const double _exportScale = 3.0;
  static const double _maxCanvasWidth = 900.0;

  DateTime _anchor = DateTime.now();

  /// التخصيص (محفوظ — الصفحة بترجع متل ما تركتها)
  AllStatsPrefs _prefs = AllStatsPrefsStore.load();

  bool _busy = false;

  /// أثناء حفظ/مشاركة الصورة
  bool _exporting = false;

  AllStatsPeriod get _period => _prefs.period;
  set _period(AllStatsPeriod v) => _update(_prefs.copyWith(period: v));

  AccountSortMode get _sortMode => _prefs.sortMode;
  set _sortMode(AccountSortMode v) => _update(_prefs.copyWith(sortMode: v));

  AccountType get _accountTypeFilter => _prefs.accountType;
  set _accountTypeFilter(AccountType v) =>
      _update(_prefs.copyWith(accountType: v));

  bool get _showHeader =>
      _prefs.showHeader && !(_exporting && _prefs.hideHeaderInExport);
  bool get _showQuickStats => _prefs.showQuickStats;
  bool get _showGlobalCards => _prefs.showGlobalCards;
  bool get _showAccountCards => _prefs.showAccountCards;
  bool get _showCurrencyRows => _prefs.showCurrencyRows;
  bool get _showDeltaStrip => _prefs.showDelta;
  bool get _showAccountsInsideQuickCards => _prefs.showAccountsInQuick;

  /// الأقسام الظاهرة بالترتيب المختار (حسب نوع الحسابات)
  List<StatsMetric> get _metrics => _prefs.visibleMetrics(_accountTypeFilter);

  void _update(AllStatsPrefs p) {
    _prefs = p;
    AllStatsPrefsStore.save(p);
  }

  @override
  void initState() {
    super.initState();
    AllStatsPrefsStore.prefs.addListener(_onPrefsChanged);
  }

  @override
  void dispose() {
    AllStatsPrefsStore.prefs.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onPrefsChanged() {
    final p = AllStatsPrefsStore.prefs.value;
    if (!mounted || identical(p, _prefs)) return;
    setState(() => _prefs = p);
  }

  Future<void> _openCustomize() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            AllStatsCustomizeScreen(initialType: _accountTypeFilter),
      ),
    );
    if (mounted) setState(() => _prefs = AllStatsPrefsStore.prefs.value);
  }

  int _compareManual(_AccountStats a, _AccountStats b) {
    final order = _prefs.orderFor(_accountTypeFilter);
    final ia = order.indexOf(a.account.id);
    final ib = order.indexOf(b.account.id);
    if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
    if (ia >= 0) return -1;
    if (ib >= 0) return 1;
    return a.account.name.compareTo(b.account.name);
  }

  // ==========================
  // Date helpers
  // ==========================

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime _endOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

  DateTime _startOfMonth(DateTime d) => DateTime(d.year, d.month, 1);

  DateTime _endOfMonth(DateTime d) => DateTime(
    d.year,
    d.month + 1,
    1,
  ).subtract(const Duration(milliseconds: 1));

  DateTime _startOfYear(DateTime d) => DateTime(d.year, 1, 1);

  DateTime _endOfYear(DateTime d) =>
      DateTime(d.year + 1, 1, 1).subtract(const Duration(milliseconds: 1));

  _Range _currentRange() {
    switch (_period) {
      case AllStatsPeriod.daily:
        return _Range(_startOfDay(_anchor), _endOfDay(_anchor));
      case AllStatsPeriod.monthly:
        return _Range(_startOfMonth(_anchor), _endOfMonth(_anchor));
      case AllStatsPeriod.yearly:
        return _Range(_startOfYear(_anchor), _endOfYear(_anchor));
    }
  }

  _Range _previousRange() {
    switch (_period) {
      case AllStatsPeriod.daily:
        final prev = _anchor.subtract(const Duration(days: 1));
        return _Range(_startOfDay(prev), _endOfDay(prev));
      case AllStatsPeriod.monthly:
        final prev = DateTime(_anchor.year, _anchor.month - 1, 1);
        return _Range(_startOfMonth(prev), _endOfMonth(prev));
      case AllStatsPeriod.yearly:
        final prev = DateTime(_anchor.year - 1, 1, 1);
        return _Range(_startOfYear(prev), _endOfYear(prev));
    }
  }

  bool _canGoNext() {
    final now = DateTime.now();
    final current = _currentRange();

    switch (_period) {
      case AllStatsPeriod.daily:
        return current.start.isBefore(_startOfDay(now));
      case AllStatsPeriod.monthly:
        return current.start.isBefore(_startOfMonth(now));
      case AllStatsPeriod.yearly:
        return current.start.isBefore(_startOfYear(now));
    }
  }

  void _shiftPeriod(int delta) {
    setState(() {
      switch (_period) {
        case AllStatsPeriod.daily:
          _anchor = _anchor.add(Duration(days: delta));
          break;
        case AllStatsPeriod.monthly:
          _anchor = DateTime(_anchor.year, _anchor.month + delta, 1);
          break;
        case AllStatsPeriod.yearly:
          _anchor = DateTime(_anchor.year + delta, 1, 1);
          break;
      }
    });
  }

  Future<void> _pickAnchorDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now(),
      helpText: 'اختر التاريخ المرجعي',
      confirmText: 'اختيار',
      cancelText: 'إلغاء',
    );

    if (picked != null) {
      setState(() => _anchor = picked);
    }
  }

  String _periodLabel() {
    switch (_period) {
      case AllStatsPeriod.daily:
        return "يومي";
      case AllStatsPeriod.monthly:
        return "شهري";
      case AllStatsPeriod.yearly:
        return "سنوي";
    }
  }

  String _formatPeriodDate() {
    switch (_period) {
      case AllStatsPeriod.daily:
        return "${_anchor.year}-${_anchor.month.toString().padLeft(2, '0')}-${_anchor.day.toString().padLeft(2, '0')}";
      case AllStatsPeriod.monthly:
        return "${_anchor.year}-${_anchor.month.toString().padLeft(2, '0')}";
      case AllStatsPeriod.yearly:
        return "${_anchor.year}";
    }
  }

  String _sortModeLabel() {
    switch (_sortMode) {
      case AccountSortMode.priority:
        return 'ترتيب ذكي';
      case AccountSortMode.name:
        return 'حسب الاسم';
      case AccountSortMode.operations:
        return 'حسب العمليات';
      case AccountSortMode.trend:
        return 'حسب التغير';
      case AccountSortMode.amount:
        return 'حسب المبالغ';
      case AccountSortMode.manual:
        return 'ترتيب يدوي';
    }
  }

  // ==========================
  // Money helpers
  // ==========================

  String _secondCurrencyOf(TransactionModel t) {
    try {
      final value = (t as dynamic).secondCurrency;
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    } catch (_) {}
    return t.currency;
  }

  List<_MoneyPart> _moneyPartsOf(TransactionModel t) {
    final parts = <_MoneyPart>[
      _MoneyPart(currency: t.currency, amount: t.amount),
    ];

    if (t.secondAmount != null && t.secondAmount! > 0) {
      parts.add(
        _MoneyPart(currency: _secondCurrencyOf(t), amount: t.secondAmount!),
      );
    }

    return parts;
  }

  Map<String, double> _totalsByCurrency(Iterable<TransactionModel> items) {
    final out = <String, double>{};
    for (final t in items) {
      for (final p in _moneyPartsOf(t)) {
        out.update(p.currency, (v) => v + p.amount, ifAbsent: () => p.amount);
      }
    }
    return out;
  }

  Map<String, int> _countsByCurrency(Iterable<TransactionModel> items) {
    final out = <String, int>{};
    for (final t in items) {
      for (final p in _moneyPartsOf(t)) {
        out.update(p.currency, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    return out;
  }

  /// 1250000 → 1.250.000 ، 1250.5 → 1.250,5 (بدون ,00)
  String _formatAmount(double v) {
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

  // ==========================
  // Stats logic
  // ==========================

  _AccountStats _buildStatsForAccount(
    Account account,
    Iterable<TransactionModel> allTx,
    _Range current,
    _Range previous,
  ) {
    final tx = allTx.where((t) => t.accountId == account.id).toList();
    final isCompany = account.type == AccountType.company;

    // نفس منطق المكاتب للشركات أيضًا: الإضافة بتاريخ الإضافة (حتى لو أُلغيت
    // لاحقًا) والإلغاء بتاريخ الإلغاء، فالحركة التي أُضيفت ثم أُلغيت تُحسب
    // إضافة وإلغاء معًا.
    final now = PeriodStats.compute(
      tx,
      StatsPeriod(current.start, current.end),
      company: isCompany,
    );
    final prev = PeriodStats.compute(
      tx,
      StatsPeriod(previous.start, previous.end),
      company: isCompany,
    );

    final addedNow = now.added;
    final receivedNow = now.received;
    final cancelledNow = now.cancelled;
    final unreceivedNow = now.fourth;

    final addedPrev = prev.added;
    final receivedPrev = prev.received;
    final cancelledPrev = prev.cancelled;
    final unreceivedPrev = prev.fourth;

    return _AccountStats(
      account: account,
      addedNow: addedNow,
      receivedNow: receivedNow,
      cancelledNow: cancelledNow,
      unreceivedNow: unreceivedNow,
      addedPrev: addedPrev,
      receivedPrev: receivedPrev,
      cancelledPrev: cancelledPrev,
      unreceivedPrev: unreceivedPrev,
      totalsAddedNow: _totalsByCurrency(addedNow),
      totalsReceivedNow: _totalsByCurrency(receivedNow),
      totalsCancelledNow: _totalsByCurrency(cancelledNow),
      totalsUnreceivedNow: _totalsByCurrency(unreceivedNow),
      totalsAddedPrev: _totalsByCurrency(addedPrev),
      totalsReceivedPrev: _totalsByCurrency(receivedPrev),
      totalsCancelledPrev: _totalsByCurrency(cancelledPrev),
      totalsUnreceivedPrev: _totalsByCurrency(unreceivedPrev),
      countsAddedNow: _countsByCurrency(addedNow),
      countsReceivedNow: _countsByCurrency(receivedNow),
      countsCancelledNow: _countsByCurrency(cancelledNow),
      countsUnreceivedNow: _countsByCurrency(unreceivedNow),
    );
  }

  // ==========================
  // Design helpers
  // ==========================

  (IconData, String, Color, String) _deltaParts(int today, int yesterday) {
    if (yesterday == 0 && today == 0) {
      return (Icons.remove, "0%", Colors.grey, "0");
    }
    if (yesterday == 0 && today > 0) {
      return (Icons.trending_up, "+100%", Colors.green, "+$today");
    }

    final diff = today - yesterday;
    final ratio = diff / (yesterday == 0 ? 1 : yesterday);
    final pctStr = "${(ratio * 100).round()}%";

    if (diff > 0) {
      return (Icons.trending_up, "+$pctStr", Colors.green, "+$diff");
    }
    if (diff < 0) {
      return (Icons.trending_down, "$pctStr", Colors.red, "$diff");
    }

    return (Icons.trending_flat, "0%", Colors.grey, "0");
  }

  Color _bestOnColor(Color bg) {
    final d = 0.299 * bg.red + 0.587 * bg.green + 0.114 * bg.blue;
    return d > 150 ? Colors.black : Colors.white;
  }

  Widget _deltaLabel({
    required int today,
    required int yesterday,
    required Color stripColor,
    String prefix = "عن السابق",
  }) {
    final (ic, pct, stateColor, diffLabel) = _deltaParts(today, yesterday);
    final on = _bestOnColor(stripColor);

    final blended = Color.fromARGB(
      255,
      ((on.red * 0.2) + (stateColor.red * 0.8)).round(),
      ((on.green * 0.2) + (stateColor.green * 0.8)).round(),
      ((on.blue * 0.2) + (stateColor.blue * 0.8)).round(),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(ic, size: 16, color: blended),
        const SizedBox(width: 6),
        Text(
          "$prefix: $pct ($diffLabel)",
          style: TextStyle(
            color: on,
            fontWeight: FontWeight.w900,
            fontSize: 12.5,
          ),
        ),
      ],
    );
  }

  (IconData, String, Color) _amountTrendOf(double current, double previous) {
    if (previous == 0 && current == 0) {
      return (Icons.remove_rounded, '0%', Colors.grey);
    }
    if (previous == 0 && current > 0) {
      return (Icons.trending_up_rounded, '+100%', Colors.green);
    }

    final diff = current - previous;
    final ratio = diff / (previous == 0 ? 1 : previous);
    final pct = (ratio * 100).round();

    if (diff > 0) {
      return (Icons.trending_up_rounded, '+$pct%', Colors.green);
    }
    if (diff < 0) {
      return (Icons.trending_down_rounded, '$pct%', Colors.red);
    }
    return (Icons.trending_flat_rounded, '0%', Colors.grey);
  }

  int _compareStatsByPriority(_AccountStats a, _AccountStats b) {
    final c1 = b.unreceivedNow.length.compareTo(a.unreceivedNow.length);
    if (c1 != 0) return c1;

    final c2 = b.addedNow.length.compareTo(a.addedNow.length);
    if (c2 != 0) return c2;

    final c3 = b.receivedNow.length.compareTo(a.receivedNow.length);
    if (c3 != 0) return c3;

    final c4 = a.cancelledNow.length.compareTo(b.cancelledNow.length);
    if (c4 != 0) return c4;

    return a.account.name.compareTo(b.account.name);
  }

  Widget _buildHeader(ColorScheme cs, String title, String subtitle) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withOpacity(.18)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.primary.withOpacity(.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.insights_rounded, color: cs.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.outlineVariant.withOpacity(.18)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_rounded, color: cs.onSurface, size: 18),
                const SizedBox(width: 6),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _moneyRow({
    required String currency,
    required double total,
    required ColorScheme cs,
    int? count,
    String? trailingBadge,
    Color? trailingBadgeColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withOpacity(.20)),
      ),
      child: Row(
        children: [
          if (trailingBadge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: (trailingBadgeColor ?? cs.primary).withOpacity(.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                trailingBadge,
                style: TextStyle(
                  color: trailingBadgeColor ?? cs.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 11.5,
                ),
              ),
            ),
          if (trailingBadge != null) const SizedBox(width: 8),
          if (count != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: cs.primary.withOpacity(.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "$count",
                style: TextStyle(
                  color: cs.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          if (count != null) const SizedBox(width: 10),
          Expanded(
            child: Text(
              currency,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            ),
          ),
          Text(
            _formatAmount(total),
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _cardHeader({
    required String title,
    required int count,
    required IconData icon,
    required List<Color> gradient,
    required ColorScheme cs,
    required int yesterday,
  }) {
    final (_, __, stateColor, ___) = _deltaParts(count, yesterday);

    final stripColor = (stateColor == Colors.green)
        ? const Color(0xFF1E7D32)
        : (stateColor == Colors.red)
        ? const Color(0xFFB71C1C)
        : const Color(0xFF616161);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: gradient,
            ),
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(20),
              bottom: _showDeltaStrip ? Radius.zero : const Radius.circular(20),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surface.withOpacity(.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
              ),
              Text(
                "$count",
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 28,
                ),
              ),
            ],
          ),
        ),
        if (_showDeltaStrip)
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: stripColor,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _deltaLabel(
                today: count,
                yesterday: yesterday,
                stripColor: stripColor,
              ),
            ),
          ),
      ],
    );
  }

  Widget _categoryCard({
    required String title,
    required int count,
    required Map<String, double> totals,
    required IconData icon,
    required List<Color> gradient,
    required ColorScheme cs,
    required int yesterday,
    Map<String, int>? countsByCurrency,
    Map<String, double>? prevTotals,
    bool showAmountIndicators = false,
  }) {
    final keys = totals.keys.toList()..sort();

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withOpacity(.28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.10),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          _cardHeader(
            title: title,
            count: count,
            icon: icon,
            gradient: gradient,
            cs: cs,
            yesterday: yesterday,
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: !_showCurrencyRows
                ? Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      "تفاصيل العملات مخفية",
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  )
                : keys.isEmpty
                ? Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      "لا يوجد مبالغ",
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  )
                : Column(
                    children: keys.map((cur) {
                      final now = totals[cur] ?? 0.0;
                      final prev = prevTotals?[cur] ?? 0.0;
                      final amountTrend = _amountTrendOf(now, prev);

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _moneyRow(
                          currency: cur,
                          total: now,
                          cs: cs,
                          count: countsByCurrency?[cur],
                          trailingBadge: showAmountIndicators
                              ? amountTrend.$2
                              : null,
                          trailingBadgeColor: showAmountIndicators
                              ? amountTrend.$3
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  // ==========================
  // Quick cards with accounts inside
  // ==========================

  int _metricNowCount(_AccountStats s, StatsMetric type) {
    switch (type) {
      case StatsMetric.added:
        return s.addedNow.length;
      case StatsMetric.received:
        return s.receivedNow.length;
      case StatsMetric.cancelled:
        return s.cancelledNow.length;
      case StatsMetric.unreceived:
        return s.unreceivedNow.length;
    }
  }

  int _metricPrevCount(_AccountStats s, StatsMetric type) {
    switch (type) {
      case StatsMetric.added:
        return s.addedPrev.length;
      case StatsMetric.received:
        return s.receivedPrev.length;
      case StatsMetric.cancelled:
        return s.cancelledPrev.length;
      case StatsMetric.unreceived:
        return s.unreceivedPrev.length;
    }
  }

  bool get _isCompanyStatsView => _accountTypeFilter == AccountType.company;

  String _metricLabel(StatsMetric type) =>
      _prefs.labelOf(type, _accountTypeFilter);

  IconData _metricIcon(StatsMetric type) =>
      statsMetricIcon(type, company: _isCompanyStatsView);

  List<Color> _metricGradient(StatsMetric type) =>
      _prefs.gradientOf(type, _accountTypeFilter);

  List<_QuickAccountEntry> _topAccountsForMetric(
    List<_AccountStats> stats,
    StatsMetric type,
  ) {
    final items = stats
        .map(
          (s) => _QuickAccountEntry(
            name: s.account.name,
            nowCount: _metricNowCount(s, type),
            prevCount: _metricPrevCount(s, type),
          ),
        )
        .where(
          (e) =>
              e.nowCount > 0 || (!_prefs.hideZeroAccounts && e.prevCount > 0),
        )
        .toList();

    items.sort((a, b) {
      final c1 = b.nowCount.compareTo(a.nowCount);
      if (c1 != 0) return c1;

      final aDiff = a.nowCount - a.prevCount;
      final bDiff = b.nowCount - b.prevCount;
      final c2 = bDiff.compareTo(aDiff);
      if (c2 != 0) return c2;

      return a.name.compareTo(b.name);
    });

    return items;
  }

  Widget _quickAccountCountBox(int count) {
    final compact = _prefs.compact;
    return Container(
      constraints: BoxConstraints(minWidth: compact ? 40 : 54),
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(.18)),
      ),
      child: Text(
        "$count",
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: compact ? 14 : 16,
        ),
      ),
    );
  }

  Widget _quickAccountTrendBox(int now, int prev) {
    final (icon, pct, _, diff) = _deltaParts(now, prev);

    return Container(
      padding: _prefs.compact
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            pct,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 13,
              height: 1.2,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            diff,
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickAccountRow(_QuickAccountEntry entry, {bool narrow = false}) {
    final compact = _prefs.compact || narrow;
    return Container(
      margin: EdgeInsets.only(bottom: compact ? 6 : 10),
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 6, 10, 6)
          : const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.08),
        borderRadius: BorderRadius.circular(compact ? 14 : 18),
        border: Border.all(color: Colors.white.withOpacity(.16)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              entry.name,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: compact ? 13.5 : 15,
              ),
            ),
          ),
          if (_showDeltaStrip && !narrow) ...[
            SizedBox(width: compact ? 6 : 10),
            _quickAccountTrendBox(entry.nowCount, entry.prevCount),
          ],
          SizedBox(width: compact ? 6 : 10),
          _quickAccountCountBox(entry.nowCount),
        ],
      ),
    );
  }

  Widget _quickSummaryCard({
    required String label,
    required int count,
    required int yesterday,
    required List<Color> gradient,
    required IconData icon,
    required List<_QuickAccountEntry> accounts,
    Map<String, double> totals = const {},

    /// بطاقة ضيقة (عمودين على شاشة صغيرة): خطوط أصغر وبدون تفاصيل زايدة
    bool narrow = false,
  }) {
    final (trendIcon, pct, _, diffLabel) = _deltaParts(count, yesterday);
    final compact = _prefs.compact;
    final horizontal = compact && !narrow;
    final limit = _prefs.quickAccountsLimit;
    final shownAccounts = limit > 0 && accounts.length > limit
        ? accounts.take(limit).toList()
        : accounts;
    final moreAccounts = accounts.length - shownAccounts.length;
    final currencies = totals.keys.toList()
      ..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
    final labelSize = narrow ? (compact ? 15.0 : 18.0) : 24.0;
    final countSize = narrow ? (compact ? 28.0 : 34.0) : 44.0;
    final small = compact || narrow;

    return Container(
      padding: EdgeInsets.all(small ? 12 : 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: gradient,
        ),
        borderRadius: BorderRadius.circular(small ? 22 : 30),
        boxShadow: [
          BoxShadow(
            color: gradient.last.withOpacity(0.28),
            blurRadius: small ? 12 : 18,
            offset: Offset(0, small ? 6 : 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (horizontal)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(.14)),
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  "$count",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 30,
                    height: 1,
                  ),
                ),
              ],
            )
          else ...[
            Center(
              child: Container(
                padding: EdgeInsets.all(small ? 8 : 11),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.12),
                  borderRadius: BorderRadius.circular(small ? 12 : 16),
                  border: Border.all(color: Colors.white.withOpacity(.14)),
                ),
                child: Icon(icon, color: Colors.white, size: small ? 20 : 24),
              ),
            ),
            SizedBox(height: small ? 8 : 14),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: labelSize,
                height: 1.2,
              ),
            ),
            SizedBox(height: small ? 10 : 18),
            Text(
              "$count",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: countSize,
                height: 1,
              ),
            ),
          ],
          if (_showDeltaStrip) ...[
            SizedBox(height: small ? 8 : 12),
            Center(
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: small ? 10 : 14,
                  vertical: small ? 5 : 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white.withOpacity(.16)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(trendIcon, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      pct,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (!narrow) ...[
                      const SizedBox(width: 8),
                      Text(
                        diffLabel,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_prefs.quickShowAmounts) ...[
            SizedBox(height: small ? 8 : 12),
            if (currencies.isEmpty)
              const Text(
                "لا يوجد مبالغ",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              )
            else
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in currencies)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.14),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withOpacity(.18),
                        ),
                      ),
                      child: Text(
                        '${_formatAmount(totals[c] ?? 0)} $c',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                ],
              ),
          ],
          if (_showAccountsInsideQuickCards) ...[
            SizedBox(height: small ? 12 : 18),
            Container(height: 1.2, color: Colors.white.withOpacity(.22)),
            SizedBox(height: small ? 10 : 14),
            if (accounts.isEmpty)
              Container(
                padding: EdgeInsets.symmetric(
                  vertical: small ? 10 : 16,
                  horizontal: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.08),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withOpacity(.14)),
                ),
                child: const Text(
                  "لا توجد حسابات ضمن هذا القسم",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              )
            else ...[
              for (final e in shownAccounts)
                _quickAccountRow(e, narrow: narrow),
              if (moreAccounts > 0)
                Text(
                  moreAccounts == 1
                      ? '+ حساب تاني'
                      : '+ $moreAccounts حسابات تانية',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }

  String _categoryTitle(StatsMetric type, [String? accountName]) {
    final label = _metricLabel(type);
    return accountName == null
        ? '$label — كل الحسابات'
        : '$label — $accountName';
  }

  Widget _buildQuickStats(List<_AccountStats> stats, _GlobalData g) {
    final metrics = _metrics;
    if (metrics.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cols = _prefs.columns == 0
            ? (width >= 760 ? 2 : 1)
            : _prefs.columns;
        final cardWidth = cols <= 1 ? width : (width - 12 * (cols - 1)) / cols;
        // عمودين على شاشة موبايل: بطاقات ضيقة
        final narrow = cardWidth < 250;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final m in metrics)
              SizedBox(
                width: cardWidth,
                child: _quickSummaryCard(
                  label: _metricLabel(m),
                  count: g.countOf(m),
                  yesterday: g.prevCountOf(m),
                  gradient: _metricGradient(m),
                  icon: _metricIcon(m),
                  accounts: _topAccountsForMetric(stats, m),
                  totals: g.totalsOf(m),
                  narrow: narrow,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _hiddenAccountsNote(ColorScheme cs, int hiddenCount) {
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _openCustomize,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.visibility_off_rounded,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hiddenCount == 1
                      ? 'في حساب مخفي — ما بينحسب هون'
                      : 'في $hiddenCount حسابات مخفية — ما بتنحسب هون',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
              Text(
                'تخصيص',
                style: TextStyle(
                  color: cs.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _export({required bool alsoShare}) async {
    if (_busy) return;
    setState(() => _exporting = true);
    await Future.delayed(const Duration(milliseconds: 100));
    try {
      await _saveAndMaybeShare(alsoShare: alsoShare);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ==========================
  // Bottom sheets
  // ==========================

  Future<void> _openPeriodAndSortSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setSheet) {
              final cs = Theme.of(context).colorScheme;

              Widget sectionTitle(String title, IconData icon) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: cs.primary.withOpacity(.10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, size: 18, color: cs.primary),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15.5,
                        ),
                      ),
                    ],
                  ),
                );
              }

              Widget actionTile({
                required String title,
                required String subtitle,
                required IconData icon,
                required VoidCallback? onTap,
                bool selected = false,
                Color? iconColor,
              }) {
                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: onTap,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: selected
                            ? cs.primary.withOpacity(.30)
                            : cs.outlineVariant.withOpacity(.18),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: (iconColor ?? cs.primary).withOpacity(.10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(icon, color: iconColor ?? cs.primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                style: TextStyle(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (selected)
                          Icon(Icons.check_circle_rounded, color: cs.primary),
                        if (onTap == null)
                          Icon(
                            Icons.block_rounded,
                            color: cs.onSurfaceVariant.withOpacity(.5),
                          ),
                      ],
                    ),
                  ),
                );
              }

              return SafeArea(
                top: false,
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.88,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(.18),
                        blurRadius: 30,
                        offset: const Offset(0, -10),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topRight,
                                end: Alignment.bottomLeft,
                                colors: [
                                  cs.primary.withOpacity(.12),
                                  cs.secondary.withOpacity(.08),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: cs.primary.withOpacity(.14),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: cs.primary.withOpacity(.12),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Icon(
                                        Icons.calendar_month_rounded,
                                        color: cs.primary,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    const Expanded(
                                      child: Text(
                                        'الفترة والترتيب',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 17,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _infoChip(
                                      label: "الفترة: ${_periodLabel()}",
                                      icon: Icons.date_range_rounded,
                                      cs: cs,
                                    ),
                                    _infoChip(
                                      label: "التاريخ: ${_formatPeriodDate()}",
                                      icon: Icons.event_rounded,
                                      cs: cs,
                                    ),
                                    _infoChip(
                                      label: "الترتيب: ${_sortModeLabel()}",
                                      icon: Icons.sort_rounded,
                                      cs: cs,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),

                          sectionTitle(
                            'نوع الفترة',
                            Icons.calendar_view_month_rounded,
                          ),
                          actionTile(
                            title: 'عرض يومي',
                            subtitle: 'يعرض إحصائيات يوم واحد',
                            icon: Icons.today_rounded,
                            selected: _period == AllStatsPeriod.daily,
                            onTap: () {
                              setState(() => _period = AllStatsPeriod.daily);
                              Navigator.pop(context);
                            },
                          ),
                          actionTile(
                            title: 'عرض شهري',
                            subtitle: 'يعرض إحصائيات الشهر المحدد',
                            icon: Icons.calendar_view_month_rounded,
                            selected: _period == AllStatsPeriod.monthly,
                            onTap: () {
                              setState(() => _period = AllStatsPeriod.monthly);
                              Navigator.pop(context);
                            },
                          ),
                          actionTile(
                            title: 'عرض سنوي',
                            subtitle: 'يعرض إحصائيات السنة المحددة',
                            icon: Icons.calendar_today_rounded,
                            selected: _period == AllStatsPeriod.yearly,
                            onTap: () {
                              setState(() => _period = AllStatsPeriod.yearly);
                              Navigator.pop(context);
                            },
                          ),

                          const SizedBox(height: 8),
                          sectionTitle(
                            'التنقل بالتاريخ',
                            Icons.swap_horiz_rounded,
                          ),
                          actionTile(
                            title: 'اختيار التاريخ',
                            subtitle: 'افتح التقويم واختر تاريخًا مرجعيًا',
                            icon: Icons.edit_calendar_rounded,
                            onTap: () async {
                              Navigator.pop(context);
                              await Future.delayed(
                                const Duration(milliseconds: 120),
                              );
                              await _pickAnchorDate();
                            },
                          ),
                          actionTile(
                            title: 'الفترة السابقة',
                            subtitle:
                                'انتقل إلى اليوم أو الشهر أو السنة السابقة',
                            icon: Icons.chevron_right_rounded,
                            onTap: () {
                              _shiftPeriod(-1);
                              Navigator.pop(context);
                            },
                          ),
                          actionTile(
                            title: 'الفترة التالية',
                            subtitle: 'انتقل إلى الفترة التالية إن كانت متاحة',
                            icon: Icons.chevron_left_rounded,
                            onTap: _canGoNext()
                                ? () {
                                    _shiftPeriod(1);
                                    Navigator.pop(context);
                                  }
                                : null,
                          ),

                          const SizedBox(height: 8),
                          sectionTitle('الترتيب', Icons.leaderboard_rounded),
                          actionTile(
                            title: 'ترتيب ذكي حسب الأهمية',
                            subtitle:
                                'غير المستلمة ثم المضافة ثم المستلمة ثم الأقل إلغاء',
                            icon: Icons.auto_awesome_rounded,
                            selected: _sortMode == AccountSortMode.priority,
                            onTap: () {
                              setState(
                                () => _sortMode = AccountSortMode.priority,
                              );
                              Navigator.pop(context);
                            },
                          ),
                          actionTile(
                            title: 'ترتيب حسب العمليات',
                            subtitle: 'الأكثر إجماليًا في الأعلى',
                            icon: Icons.bar_chart_rounded,
                            selected: _sortMode == AccountSortMode.operations,
                            onTap: () {
                              setState(
                                () => _sortMode = AccountSortMode.operations,
                              );
                              Navigator.pop(context);
                            },
                          ),
                          actionTile(
                            title: 'ترتيب حسب التغير',
                            subtitle: 'الأعلى تغيرًا مقارنة بالفترة السابقة',
                            icon: Icons.trending_up_rounded,
                            selected: _sortMode == AccountSortMode.trend,
                            onTap: () {
                              setState(() => _sortMode = AccountSortMode.trend);
                              Navigator.pop(context);
                            },
                          ),
                          actionTile(
                            title: 'ترتيب حسب المبالغ',
                            subtitle: 'الأعلى مجموعًا في الأعلى',
                            icon: Icons.payments_rounded,
                            selected: _sortMode == AccountSortMode.amount,
                            onTap: () {
                              setState(
                                () => _sortMode = AccountSortMode.amount,
                              );
                              Navigator.pop(context);
                            },
                          ),
                          actionTile(
                            title: 'ترتيب حسب الاسم',
                            subtitle: 'ترتيب أبجدي',
                            icon: Icons.sort_by_alpha_rounded,
                            selected: _sortMode == AccountSortMode.name,
                            onTap: () {
                              setState(() => _sortMode = AccountSortMode.name);
                              Navigator.pop(context);
                            },
                          ),
                          actionTile(
                            title: 'ترتيب يدوي',
                            subtitle: 'حسب الترتيب يلي حددته بـ«تخصيص الصفحة»',
                            icon: Icons.low_priority_rounded,
                            selected: _sortMode == AccountSortMode.manual,
                            onTap: () {
                              setState(
                                () => _sortMode = AccountSortMode.manual,
                              );
                              Navigator.pop(context);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _infoChip({
    required String label,
    required IconData icon,
    required ColorScheme cs,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withOpacity(.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  // ==========================
  // Capture / save
  // ==========================

  Future<Uint8List?> _capturePng() async {
    try {
      await Future.delayed(const Duration(milliseconds: 200));
      if (mounted) {
        WidgetsBinding.instance.handleBeginFrame(Duration.zero);
        WidgetsBinding.instance.handleDrawFrame();
      }
      await Future.delayed(const Duration(milliseconds: 150));

      final ctx = _shotKey.currentContext;
      if (ctx == null) return null;

      final ro = ctx.findRenderObject();
      if (ro is! RenderRepaintBoundary) return null;

      final image = await ro.toImage(pixelRatio: _exportScale);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) return null;

      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveAndMaybeShare({required bool alsoShare}) async {
    if (_busy) return;

    setState(() => _busy = true);

    void showSnack(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }

    try {
      final png = await _capturePng();
      if (png == null) {
        showSnack('تعذّر إنشاء الصورة');
        return;
      }

      final fileName =
          'all_accounts_stats_${DateTime.now().millisecondsSinceEpoch}';

      try {
        await FileSaver.instance.saveFile(
          name: fileName,
          bytes: png,
          ext: 'png',
          mimeType: MimeType.png,
        );
        showSnack('تم حفظ الصورة');
      } catch (e) {
        showSnack('فشل الحفظ: $e');
        return;
      }

      if (alsoShare && !kIsWeb) {
        try {
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/$fileName.png');
          await file.writeAsBytes(png, flush: true);

          await Share.shareXFiles([
            XFile(file.path, mimeType: 'image/png', name: '$fileName.png'),
          ]);
        } catch (e) {
          showSnack('تم الحفظ لكن فشلت المشاركة: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = _currentRange();
    final previous = _previousRange();

    return ValueListenableBuilder(
      valueListenable: DatabaseService.accountsBox.listenable(),
      builder: (context, Box<Account> accountsBox, _) {
        final allOfType = accountsBox.values
            .where((a) => a.type == _accountTypeFilter)
            .toList();
        // الحسابات المخفية بالتخصيص ما بتنعرض وما بتنحسب
        final accounts = allOfType
            .where((a) => !_prefs.isHidden(a.id))
            .toList();
        final hiddenCount = allOfType.length - accounts.length;

        return ValueListenableBuilder(
          valueListenable: DatabaseService.transactionsBox.listenable(),
          builder: (context, Box<TransactionModel> txBox, __) {
            final allTx = txBox.values.toList();

            final stats = accounts
                .map(
                  (acc) => _buildStatsForAccount(acc, allTx, current, previous),
                )
                .toList();

            stats.sort((a, b) {
              switch (_sortMode) {
                case AccountSortMode.priority:
                  return _compareStatsByPriority(a, b);
                case AccountSortMode.name:
                  return a.account.name.compareTo(b.account.name);
                case AccountSortMode.operations:
                  return b.totalNow.compareTo(a.totalNow);
                case AccountSortMode.trend:
                  final aDiff = a.totalNow - a.totalPrev;
                  final bDiff = b.totalNow - b.totalPrev;
                  return bDiff.compareTo(aDiff);
                case AccountSortMode.amount:
                  return b.totalAmountNow.compareTo(a.totalAmountNow);
                case AccountSortMode.manual:
                  return _compareManual(a, b);
              }
            });

            final global = _GlobalData.fromStats(stats);

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                appBar: AppBar(
                  title: const Text('إحصائيات كل الحسابات'),
                  centerTitle: true,
                  actions: [
                    PopupMenuButton<AccountType>(
                      tooltip: 'نوع الحسابات',
                      initialValue: _accountTypeFilter,
                      onSelected: (value) =>
                          setState(() => _accountTypeFilter = value),
                      itemBuilder: (_) => AccountType.values
                          .map(
                            (type) => PopupMenuItem(
                              value: type,
                              child: Text(type.label),
                            ),
                          )
                          .toList(),
                      icon: Icon(
                        _accountTypeFilter.isCompany
                            ? Icons.business_rounded
                            : Icons.account_balance_wallet_rounded,
                      ),
                    ),
                    IconButton(
                      tooltip: 'الفترة والترتيب',
                      onPressed: _openPeriodAndSortSheet,
                      icon: const Icon(Icons.calendar_month_rounded),
                    ),
                    IconButton(
                      tooltip: 'تخصيص الصفحة',
                      onPressed: _openCustomize,
                      icon: const Icon(Icons.tune_rounded),
                    ),
                    IconButton(
                      tooltip: _busy ? 'جارٍ التنفيذ...' : 'حفظ الصورة',
                      onPressed: _busy ? null : () => _export(alsoShare: false),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_rounded),
                    ),
                    IconButton(
                      tooltip: _busy ? 'جارٍ التنفيذ...' : 'حفظ ومشاركة',
                      onPressed: _busy ? null : () => _export(alsoShare: true),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.ios_share_rounded),
                    ),
                  ],
                ),
                body: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [cs.surface, cs.surfaceContainerLowest],
                    ),
                  ),
                  child: SafeArea(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: _maxCanvasWidth,
                          ),
                          child: RepaintBoundary(
                            key: _shotKey,
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: cs.surface,
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(
                                  color: cs.outlineVariant.withOpacity(.18),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (_showHeader)
                                    _buildHeader(
                                      cs,
                                      _prefs.title.isNotEmpty
                                          ? _prefs.title
                                          : 'إحصائيات ${_accountTypeFilter.label}',
                                      "${_periodLabel()} — ${_formatPeriodDate()}",
                                    ),

                                  if (_showHeader) const SizedBox(height: 12),

                                  if (hiddenCount > 0 && !_exporting) ...[
                                    _hiddenAccountsNote(cs, hiddenCount),
                                    const SizedBox(height: 12),
                                  ],

                                  if (_showQuickStats) ...[
                                    _buildQuickStats(stats, global),
                                    const SizedBox(height: 14),
                                  ],

                                  if (_showGlobalCards)
                                    for (final m in _metrics) ...[
                                      _categoryCard(
                                        title: _categoryTitle(m),
                                        count: global.countOf(m),
                                        totals: global.totalsOf(m),
                                        prevTotals: global.prevTotalsOf(m),
                                        icon: _metricIcon(m),
                                        gradient: _metricGradient(m),
                                        cs: cs,
                                        yesterday: global.prevCountOf(m),
                                        countsByCurrency: global.countsOf(m),
                                        showAmountIndicators: true,
                                      ),
                                      const SizedBox(height: 14),
                                    ],

                                  if (_showGlobalCards && _showAccountCards)
                                    const SizedBox(height: 18),

                                  if (_showAccountCards)
                                    for (final s in stats)
                                      if (!_prefs.hideZeroAccounts ||
                                          s.totalNow > 0) ...[
                                        for (final m in _metrics) ...[
                                          _categoryCard(
                                            title: _categoryTitle(
                                              m,
                                              s.account.name,
                                            ),
                                            count: s.nowOf(m).length,
                                            totals: s.totalsNowOf(m),
                                            prevTotals: s.totalsPrevOf(m),
                                            icon: _metricIcon(m),
                                            gradient: _metricGradient(m),
                                            cs: cs,
                                            yesterday: s.prevOf(m).length,
                                            countsByCurrency: s.countsNowOf(m),
                                            showAmountIndicators: true,
                                          ),
                                          const SizedBox(height: 12),
                                        ],
                                        const SizedBox(height: 18),
                                      ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Range {
  final DateTime start;
  final DateTime end;

  _Range(this.start, this.end);
}

class _MoneyPart {
  final String currency;
  final double amount;

  const _MoneyPart({required this.currency, required this.amount});
}

class _QuickAccountEntry {
  final String name;
  final int nowCount;
  final int prevCount;

  const _QuickAccountEntry({
    required this.name,
    required this.nowCount,
    required this.prevCount,
  });
}

class _AccountStats {
  final Account account;

  final List<TransactionModel> addedNow;
  final List<TransactionModel> receivedNow;
  final List<TransactionModel> cancelledNow;
  final List<TransactionModel> unreceivedNow;

  final List<TransactionModel> addedPrev;
  final List<TransactionModel> receivedPrev;
  final List<TransactionModel> cancelledPrev;
  final List<TransactionModel> unreceivedPrev;

  final Map<String, double> totalsAddedNow;
  final Map<String, double> totalsReceivedNow;
  final Map<String, double> totalsCancelledNow;
  final Map<String, double> totalsUnreceivedNow;

  final Map<String, double> totalsAddedPrev;
  final Map<String, double> totalsReceivedPrev;
  final Map<String, double> totalsCancelledPrev;
  final Map<String, double> totalsUnreceivedPrev;

  final Map<String, int> countsAddedNow;
  final Map<String, int> countsReceivedNow;
  final Map<String, int> countsCancelledNow;
  final Map<String, int> countsUnreceivedNow;

  const _AccountStats({
    required this.account,
    required this.addedNow,
    required this.receivedNow,
    required this.cancelledNow,
    required this.unreceivedNow,
    required this.addedPrev,
    required this.receivedPrev,
    required this.cancelledPrev,
    required this.unreceivedPrev,
    required this.totalsAddedNow,
    required this.totalsReceivedNow,
    required this.totalsCancelledNow,
    required this.totalsUnreceivedNow,
    required this.totalsAddedPrev,
    required this.totalsReceivedPrev,
    required this.totalsCancelledPrev,
    required this.totalsUnreceivedPrev,
    required this.countsAddedNow,
    required this.countsReceivedNow,
    required this.countsCancelledNow,
    required this.countsUnreceivedNow,
  });

  List<TransactionModel> nowOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return addedNow;
      case StatsMetric.received:
        return receivedNow;
      case StatsMetric.cancelled:
        return cancelledNow;
      case StatsMetric.unreceived:
        return unreceivedNow;
    }
  }

  List<TransactionModel> prevOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return addedPrev;
      case StatsMetric.received:
        return receivedPrev;
      case StatsMetric.cancelled:
        return cancelledPrev;
      case StatsMetric.unreceived:
        return unreceivedPrev;
    }
  }

  Map<String, double> totalsNowOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return totalsAddedNow;
      case StatsMetric.received:
        return totalsReceivedNow;
      case StatsMetric.cancelled:
        return totalsCancelledNow;
      case StatsMetric.unreceived:
        return totalsUnreceivedNow;
    }
  }

  Map<String, double> totalsPrevOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return totalsAddedPrev;
      case StatsMetric.received:
        return totalsReceivedPrev;
      case StatsMetric.cancelled:
        return totalsCancelledPrev;
      case StatsMetric.unreceived:
        return totalsUnreceivedPrev;
    }
  }

  Map<String, int> countsNowOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return countsAddedNow;
      case StatsMetric.received:
        return countsReceivedNow;
      case StatsMetric.cancelled:
        return countsCancelledNow;
      case StatsMetric.unreceived:
        return countsUnreceivedNow;
    }
  }

  int get totalNow =>
      addedNow.length +
      receivedNow.length +
      cancelledNow.length +
      unreceivedNow.length;

  int get totalPrev =>
      addedPrev.length +
      receivedPrev.length +
      cancelledPrev.length +
      unreceivedPrev.length;

  Map<String, double> get totalAllByCurrencyNow => _mergeMaps([
    totalsAddedNow,
    totalsReceivedNow,
    totalsCancelledNow,
    totalsUnreceivedNow,
  ]);

  Map<String, double> get totalAllByCurrencyPrev => _mergeMaps([
    totalsAddedPrev,
    totalsReceivedPrev,
    totalsCancelledPrev,
    totalsUnreceivedPrev,
  ]);

  double get totalAmountNow =>
      totalAllByCurrencyNow.values.fold(0.0, (a, b) => a + b);

  double get totalAmountPrev =>
      totalAllByCurrencyPrev.values.fold(0.0, (a, b) => a + b);

  static Map<String, double> _mergeMaps(List<Map<String, double>> maps) {
    final out = <String, double>{};
    for (final m in maps) {
      m.forEach((k, v) {
        out.update(k, (old) => old + v, ifAbsent: () => v);
      });
    }
    return out;
  }
}

class _GlobalData {
  final int addedCount;
  final int receivedCount;
  final int cancelledCount;
  final int unreceivedCount;

  final int yesterdayAddedCount;
  final int yesterdayReceivedCount;
  final int yesterdayCancelledCount;
  final int yesterdayUnreceivedCount;

  final Map<String, double> totalsAdded;
  final Map<String, double> totalsReceived;
  final Map<String, double> totalsCancelled;
  final Map<String, double> totalsUnreceived;

  final Map<String, double> prevTotalsAdded;
  final Map<String, double> prevTotalsReceived;
  final Map<String, double> prevTotalsCancelled;
  final Map<String, double> prevTotalsUnreceived;

  final Map<String, int> countsAdded;
  final Map<String, int> countsReceived;
  final Map<String, int> countsCancelled;
  final Map<String, int> countsUnreceived;

  final Map<String, double> totalAllByCurrencyNow;
  final Map<String, double> totalAllByCurrencyPrev;

  final double totalAmountNow;
  final double totalAmountPrev;

  const _GlobalData({
    required this.addedCount,
    required this.receivedCount,
    required this.cancelledCount,
    required this.unreceivedCount,
    required this.yesterdayAddedCount,
    required this.yesterdayReceivedCount,
    required this.yesterdayCancelledCount,
    required this.yesterdayUnreceivedCount,
    required this.totalsAdded,
    required this.totalsReceived,
    required this.totalsCancelled,
    required this.totalsUnreceived,
    required this.prevTotalsAdded,
    required this.prevTotalsReceived,
    required this.prevTotalsCancelled,
    required this.prevTotalsUnreceived,
    required this.countsAdded,
    required this.countsReceived,
    required this.countsCancelled,
    required this.countsUnreceived,
    required this.totalAllByCurrencyNow,
    required this.totalAllByCurrencyPrev,
    required this.totalAmountNow,
    required this.totalAmountPrev,
  });

  int countOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return addedCount;
      case StatsMetric.received:
        return receivedCount;
      case StatsMetric.cancelled:
        return cancelledCount;
      case StatsMetric.unreceived:
        return unreceivedCount;
    }
  }

  int prevCountOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return yesterdayAddedCount;
      case StatsMetric.received:
        return yesterdayReceivedCount;
      case StatsMetric.cancelled:
        return yesterdayCancelledCount;
      case StatsMetric.unreceived:
        return yesterdayUnreceivedCount;
    }
  }

  Map<String, double> totalsOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return totalsAdded;
      case StatsMetric.received:
        return totalsReceived;
      case StatsMetric.cancelled:
        return totalsCancelled;
      case StatsMetric.unreceived:
        return totalsUnreceived;
    }
  }

  Map<String, double> prevTotalsOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return prevTotalsAdded;
      case StatsMetric.received:
        return prevTotalsReceived;
      case StatsMetric.cancelled:
        return prevTotalsCancelled;
      case StatsMetric.unreceived:
        return prevTotalsUnreceived;
    }
  }

  Map<String, int> countsOf(StatsMetric m) {
    switch (m) {
      case StatsMetric.added:
        return countsAdded;
      case StatsMetric.received:
        return countsReceived;
      case StatsMetric.cancelled:
        return countsCancelled;
      case StatsMetric.unreceived:
        return countsUnreceived;
    }
  }

  static _GlobalData fromStats(List<_AccountStats> stats) {
    Map<String, double> mergeD(List<Map<String, double>> maps) {
      final out = <String, double>{};
      for (final m in maps) {
        m.forEach((k, v) {
          out.update(k, (old) => old + v, ifAbsent: () => v);
        });
      }
      return out;
    }

    Map<String, int> mergeI(List<Map<String, int>> maps) {
      final out = <String, int>{};
      for (final m in maps) {
        m.forEach((k, v) {
          out.update(k, (old) => old + v, ifAbsent: () => v);
        });
      }
      return out;
    }

    final totalsAdded = mergeD(stats.map((e) => e.totalsAddedNow).toList());
    final totalsReceived = mergeD(
      stats.map((e) => e.totalsReceivedNow).toList(),
    );
    final totalsCancelled = mergeD(
      stats.map((e) => e.totalsCancelledNow).toList(),
    );
    final totalsUnreceived = mergeD(
      stats.map((e) => e.totalsUnreceivedNow).toList(),
    );

    final prevTotalsAdded = mergeD(
      stats.map((e) => e.totalsAddedPrev).toList(),
    );
    final prevTotalsReceived = mergeD(
      stats.map((e) => e.totalsReceivedPrev).toList(),
    );
    final prevTotalsCancelled = mergeD(
      stats.map((e) => e.totalsCancelledPrev).toList(),
    );
    final prevTotalsUnreceived = mergeD(
      stats.map((e) => e.totalsUnreceivedPrev).toList(),
    );

    final totalAllNow = mergeD([
      totalsAdded,
      totalsReceived,
      totalsCancelled,
      totalsUnreceived,
    ]);

    final totalAllPrev = mergeD([
      prevTotalsAdded,
      prevTotalsReceived,
      prevTotalsCancelled,
      prevTotalsUnreceived,
    ]);

    return _GlobalData(
      addedCount: stats.fold(0, (p, e) => p + e.addedNow.length),
      receivedCount: stats.fold(0, (p, e) => p + e.receivedNow.length),
      cancelledCount: stats.fold(0, (p, e) => p + e.cancelledNow.length),
      unreceivedCount: stats.fold(0, (p, e) => p + e.unreceivedNow.length),
      yesterdayAddedCount: stats.fold(0, (p, e) => p + e.addedPrev.length),
      yesterdayReceivedCount: stats.fold(
        0,
        (p, e) => p + e.receivedPrev.length,
      ),
      yesterdayCancelledCount: stats.fold(
        0,
        (p, e) => p + e.cancelledPrev.length,
      ),
      yesterdayUnreceivedCount: stats.fold(
        0,
        (p, e) => p + e.unreceivedPrev.length,
      ),
      totalsAdded: totalsAdded,
      totalsReceived: totalsReceived,
      totalsCancelled: totalsCancelled,
      totalsUnreceived: totalsUnreceived,
      prevTotalsAdded: prevTotalsAdded,
      prevTotalsReceived: prevTotalsReceived,
      prevTotalsCancelled: prevTotalsCancelled,
      prevTotalsUnreceived: prevTotalsUnreceived,
      countsAdded: mergeI(stats.map((e) => e.countsAddedNow).toList()),
      countsReceived: mergeI(stats.map((e) => e.countsReceivedNow).toList()),
      countsCancelled: mergeI(stats.map((e) => e.countsCancelledNow).toList()),
      countsUnreceived: mergeI(
        stats.map((e) => e.countsUnreceivedNow).toList(),
      ),
      totalAllByCurrencyNow: totalAllNow,
      totalAllByCurrencyPrev: totalAllPrev,
      totalAmountNow: totalAllNow.values.fold(0.0, (a, b) => a + b),
      totalAmountPrev: totalAllPrev.values.fold(0.0, (a, b) => a + b),
    );
  }
}

class _TotalAmountCard extends StatelessWidget {
  final String title;
  final double currentAmount;
  final double previousAmount;
  final (IconData, String, Color) trend;
  final Map<String, double> totalsByCurrency;
  final Map<String, double> previousTotalsByCurrency;
  final String Function(double) formatAmount;
  final bool showCurrencyRows;
  final Widget Function({
    required String currency,
    required double total,
    required ColorScheme cs,
    int? count,
    String? trailingBadge,
    Color? trailingBadgeColor,
  })
  moneyRowBuilder;

  const _TotalAmountCard({
    required this.title,
    required this.currentAmount,
    required this.previousAmount,
    required this.trend,
    required this.totalsByCurrency,
    required this.previousTotalsByCurrency,
    required this.formatAmount,
    required this.showCurrencyRows,
    required this.moneyRowBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final keys = totalsByCurrency.keys.toList()..sort();

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withOpacity(.28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.10),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF37474F), Color(0xFF607D8B)],
              ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.payments_rounded,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                ),
                Text(
                  formatAmount(currentAmount),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: trend.$3 == Colors.green
                  ? const Color(0xFF1E7D32)
                  : trend.$3 == Colors.red
                  ? const Color(0xFFB71C1C)
                  : const Color(0xFF616161),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(trend.$1, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    "عن السابق: ${trend.$2}",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: !showCurrencyRows
                ? Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      "تفاصيل العملات مخفية",
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  )
                : keys.isEmpty
                ? Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      "لا يوجد مبالغ",
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  )
                : Column(
                    children: keys.map((cur) {
                      final now = totalsByCurrency[cur] ?? 0.0;
                      final prev = previousTotalsByCurrency[cur] ?? 0.0;
                      final diff = now - prev;

                      String badge;
                      Color badgeColor;

                      if (diff > 0) {
                        badge = "↑";
                        badgeColor = Colors.green;
                      } else if (diff < 0) {
                        badge = "↓";
                        badgeColor = Colors.red;
                      } else {
                        badge = "=";
                        badgeColor = Colors.grey;
                      }

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: moneyRowBuilder(
                          currency: cur,
                          total: now,
                          cs: cs,
                          trailingBadge: badge,
                          trailingBadgeColor: badgeColor,
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}
