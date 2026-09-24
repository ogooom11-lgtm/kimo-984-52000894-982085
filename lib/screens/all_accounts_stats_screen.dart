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
import '../services/period_stats.dart';

enum AllStatsPeriod { daily, monthly, yearly }

enum AccountSortMode { priority, name, operations, trend, amount }

enum _QuickMetricType { added, received, cancelled, unreceived }

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
  AllStatsPeriod _period = AllStatsPeriod.daily;
  AccountSortMode _sortMode = AccountSortMode.priority;
  AccountType _accountTypeFilter = AccountType.office;

  bool _busy = false;

  bool _showHeader = true;
  bool _showQuickStats = true;
  bool _showGlobalCards = false;
  bool _showAccountCards = false;
  bool _showCurrencyRows = true;
  bool _showDeltaStrip = true;
  bool _showAddedCard = true;
  bool _showReceivedCard = true;
  bool _showCancelledCard = true;
  bool _showUnreceivedCard = true;
  bool _hidePeriodBarInExport = false;
  bool _showAccountsInsideQuickCards = true;

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

  String _formatAmount(double v) {
    final s = v.toStringAsFixed(2);
    final parts = s.split('.');
    final intPart = parts[0];
    final dec = parts.length > 1 ? parts[1] : '00';

    final rev = intPart.split('').reversed.toList();
    final out = <String>[];
    for (int i = 0; i < rev.length; i++) {
      out.add(rev[i]);
      if ((i + 1) % 3 == 0 && i != rev.length - 1) {
        out.add(',');
      }
    }

    return '${out.reversed.join()}.$dec';
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

  /// توضيح طريقة حساب الشركات (نفس منطق المكاتب)
  Widget _companyRuleNote(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.secondary.withValues(alpha: .20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: cs.secondary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              PeriodStats.companyRuleText,
              style: TextStyle(fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
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

  int _metricNowCount(_AccountStats s, _QuickMetricType type) {
    switch (type) {
      case _QuickMetricType.added:
        return s.addedNow.length;
      case _QuickMetricType.received:
        return s.receivedNow.length;
      case _QuickMetricType.cancelled:
        return s.cancelledNow.length;
      case _QuickMetricType.unreceived:
        return s.unreceivedNow.length;
    }
  }

  int _metricPrevCount(_AccountStats s, _QuickMetricType type) {
    switch (type) {
      case _QuickMetricType.added:
        return s.addedPrev.length;
      case _QuickMetricType.received:
        return s.receivedPrev.length;
      case _QuickMetricType.cancelled:
        return s.cancelledPrev.length;
      case _QuickMetricType.unreceived:
        return s.unreceivedPrev.length;
    }
  }

  bool get _isCompanyStatsView => _accountTypeFilter == AccountType.company;

  String _metricLabel(_QuickMetricType type) {
    if (_isCompanyStatsView) {
      switch (type) {
        case _QuickMetricType.added:
          return 'إرسال';
        case _QuickMetricType.received:
          return 'استقبال';
        case _QuickMetricType.cancelled:
          return 'إلغاء مرسل';
        case _QuickMetricType.unreceived:
          return 'إلغاء استقبال';
      }
    }

    switch (type) {
      case _QuickMetricType.added:
        return "مضافة";
      case _QuickMetricType.received:
        return "مستلمة";
      case _QuickMetricType.cancelled:
        return "ملغاة";
      case _QuickMetricType.unreceived:
        return "غير مستلمة";
    }
  }

  IconData _metricIcon(_QuickMetricType type) {
    if (_isCompanyStatsView) {
      switch (type) {
        case _QuickMetricType.added:
          return Icons.outbox_rounded;
        case _QuickMetricType.received:
          return Icons.move_to_inbox_rounded;
        case _QuickMetricType.cancelled:
          return Icons.cancel_rounded;
        case _QuickMetricType.unreceived:
          return Icons.cancel_rounded;
      }
    }

    switch (type) {
      case _QuickMetricType.added:
        return Icons.add_circle_outline_rounded;
      case _QuickMetricType.received:
        return Icons.check_circle_outline_rounded;
      case _QuickMetricType.cancelled:
        return Icons.cancel_outlined;
      case _QuickMetricType.unreceived:
        return Icons.hourglass_empty_rounded;
    }
  }

  List<Color> _metricGradient(_QuickMetricType type) {
    if (_isCompanyStatsView) {
      switch (type) {
        case _QuickMetricType.added:
          return const [Color(0xFF4338CA), Color(0xFF7C3AED)];
        case _QuickMetricType.received:
          return const [Color(0xFF0F766E), Color(0xFF14B8A6)];
        case _QuickMetricType.cancelled:
          return const [Color(0xFFBE123C), Color(0xFFF43F5E)];
        case _QuickMetricType.unreceived:
          return const [Color(0xFF9A3412), Color(0xFFF97316)];
      }
    }

    switch (type) {
      case _QuickMetricType.added:
        return const [Color(0xFF1E88E5), Color(0xFF42A5F5)];
      case _QuickMetricType.received:
        return const [Color(0xFF2E7D32), Color(0xFF66BB6A)];
      case _QuickMetricType.cancelled:
        return const [Color(0xFFC62828), Color(0xFFEF5350)];
      case _QuickMetricType.unreceived:
        return const [Color(0xFF6A1B9A), Color(0xFFAB47BC)];
    }
  }

  List<_QuickAccountEntry> _topAccountsForMetric(
    List<_AccountStats> stats,
    _QuickMetricType type,
  ) {
    final items = stats
        .map(
          (s) => _QuickAccountEntry(
            name: s.account.name,
            nowCount: _metricNowCount(s, type),
            prevCount: _metricPrevCount(s, type),
          ),
        )
        .where((e) => e.nowCount > 0 || e.prevCount > 0)
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
    return Container(
      constraints: const BoxConstraints(minWidth: 54),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(.18)),
      ),
      child: Text(
        "$count",
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 16,
        ),
      ),
    );
  }

  Widget _quickAccountTrendBox(int now, int prev) {
    final (icon, pct, _, diff) = _deltaParts(now, prev);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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

  Widget _quickAccountRow(_QuickAccountEntry entry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(.16)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              entry.name,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _quickAccountTrendBox(entry.nowCount, entry.prevCount),
          const SizedBox(width: 10),
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
  }) {
    final (trendIcon, pct, _, diffLabel) = _deltaParts(count, yesterday);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: gradient,
        ),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: gradient.last.withOpacity(0.28),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(.14)),
              ),
              child: Icon(icon, color: Colors.white),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 24,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            "$count",
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 44,
              height: 1,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
              ),
            ),
          ),
          if (_showAccountsInsideQuickCards) ...[
            const SizedBox(height: 18),
            Container(height: 1.2, color: Colors.white.withOpacity(.22)),
            const SizedBox(height: 14),
            if (accounts.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
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
            else
              ...accounts.map(_quickAccountRow),
          ],
        ],
      ),
    );
  }

  String _categoryTitle(_QuickMetricType type, [String? accountName]) {
    final label = _metricLabel(type);
    return accountName == null
        ? '$label — كل الحسابات'
        : '$label — $accountName';
  }

  Widget _buildQuickStats(List<_AccountStats> stats, _GlobalData g) {
    final cards = <Widget>[];

    if (_showAddedCard) {
      cards.add(
        _quickSummaryCard(
          label: _metricLabel(_QuickMetricType.added),
          count: g.addedCount,
          yesterday: g.yesterdayAddedCount,
          gradient: _metricGradient(_QuickMetricType.added),
          icon: _metricIcon(_QuickMetricType.added),
          accounts: _topAccountsForMetric(stats, _QuickMetricType.added),
        ),
      );
    }

    if (_showReceivedCard) {
      cards.add(
        _quickSummaryCard(
          label: _metricLabel(_QuickMetricType.received),
          count: g.receivedCount,
          yesterday: g.yesterdayReceivedCount,
          gradient: _metricGradient(_QuickMetricType.received),
          icon: _metricIcon(_QuickMetricType.received),
          accounts: _topAccountsForMetric(stats, _QuickMetricType.received),
        ),
      );
    }

    if (_showCancelledCard) {
      cards.add(
        _quickSummaryCard(
          label: _metricLabel(_QuickMetricType.cancelled),
          count: g.cancelledCount,
          yesterday: g.yesterdayCancelledCount,
          gradient: _metricGradient(_QuickMetricType.cancelled),
          icon: _metricIcon(_QuickMetricType.cancelled),
          accounts: _topAccountsForMetric(stats, _QuickMetricType.cancelled),
        ),
      );
    }

    if (_showUnreceivedCard) {
      cards.add(
        _quickSummaryCard(
          label: _metricLabel(_QuickMetricType.unreceived),
          count: g.unreceivedCount,
          yesterday: g.yesterdayUnreceivedCount,
          gradient: _metricGradient(_QuickMetricType.unreceived),
          icon: _metricIcon(_QuickMetricType.unreceived),
          accounts: _topAccountsForMetric(stats, _QuickMetricType.unreceived),
        ),
      );
    }

    if (cards.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isWide = width >= 760;
        final cardWidth = isWide ? (width - 12) / 2 : width;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: cards
              .map((card) => SizedBox(width: cardWidth, child: card))
              .toList(),
        );
      },
    );
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

  Future<void> _openDisplayOptions() async {
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

              void sync(void Function() fn) {
                setState(fn);
                setSheet(() {});
              }

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

              Widget optionTile({
                required String title,
                required String subtitle,
                required bool value,
                required ValueChanged<bool> onChanged,
                required IconData icon,
                Color? iconColor,
              }) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: value
                          ? cs.primary.withOpacity(.28)
                          : cs.outlineVariant.withOpacity(.18),
                    ),
                  ),
                  child: SwitchListTile.adaptive(
                    value: value,
                    onChanged: onChanged,
                    secondary: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: (iconColor ?? cs.primary).withOpacity(.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: iconColor ?? cs.primary),
                    ),
                    title: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                      ),
                    ),
                    subtitle: Text(
                      subtitle,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                    ),
                    contentPadding: EdgeInsets.zero,
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
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: cs.primary.withOpacity(.12),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(
                                    Icons.tune_rounded,
                                    color: cs.primary,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'خيارات العرض والتصدير',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 17,
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      Text(
                                        'فعّل أو أخفِ الأقسام بالطريقة التي تناسبك',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),

                          sectionTitle(
                            'العرض العام',
                            Icons.dashboard_customize_rounded,
                          ),
                          optionTile(
                            title: 'إظهار الهيدر',
                            subtitle: 'عنوان الصفحة والفترة المختارة في الأعلى',
                            value: _showHeader,
                            onChanged: (v) => sync(() => _showHeader = v),
                            icon: Icons.view_headline_rounded,
                          ),
                          optionTile(
                            title: 'إظهار الملخص السريع',
                            subtitle: 'البطاقات الكبيرة في أعلى الشاشة',
                            value: _showQuickStats,
                            onChanged: (v) => sync(() => _showQuickStats = v),
                            icon: Icons.space_dashboard_rounded,
                          ),
                          optionTile(
                            title: 'إظهار بطاقات كل الحسابات',
                            subtitle: 'البطاقات الإجمالية العامة',
                            value: _showGlobalCards,
                            onChanged: (v) => sync(() => _showGlobalCards = v),
                            icon: Icons.widgets_rounded,
                          ),
                          optionTile(
                            title: 'إظهار بطاقات الحسابات',
                            subtitle: 'تفاصيل كل حساب على حدة',
                            value: _showAccountCards,
                            onChanged: (v) => sync(() => _showAccountCards = v),
                            icon: Icons.account_balance_wallet_rounded,
                          ),
                          optionTile(
                            title: 'إظهار الحسابات داخل الفقاعات',
                            subtitle:
                                'يعرض أسماء الحسابات داخل الملخص السريع نفسه',
                            value: _showAccountsInsideQuickCards,
                            onChanged: (v) =>
                                sync(() => _showAccountsInsideQuickCards = v),
                            icon: Icons.bubble_chart_rounded,
                          ),

                          const SizedBox(height: 8),
                          sectionTitle(
                            'تفاصيل البطاقات',
                            Icons.auto_awesome_rounded,
                          ),
                          optionTile(
                            title: 'إظهار صفوف العملات',
                            subtitle: 'يعرض تفاصيل العملات داخل كل بطاقة',
                            value: _showCurrencyRows,
                            onChanged: (v) => sync(() => _showCurrencyRows = v),
                            icon: Icons.payments_rounded,
                          ),
                          optionTile(
                            title: 'إظهار شريط التغير',
                            subtitle:
                                'السهم والنسبة والفرق مقارنة بالفترة السابقة',
                            value: _showDeltaStrip,
                            onChanged: (v) => sync(() => _showDeltaStrip = v),
                            icon: Icons.trending_up_rounded,
                          ),

                          const SizedBox(height: 8),
                          sectionTitle('الأقسام', Icons.filter_alt_rounded),
                          optionTile(
                            title:
                                'قسم ' + _metricLabel(_QuickMetricType.added),
                            subtitle:
                                'عرض أو إخفاء بطاقات ' +
                                _metricLabel(_QuickMetricType.added),
                            value: _showAddedCard,
                            onChanged: (v) => sync(() => _showAddedCard = v),
                            icon: Icons.add_circle_rounded,
                            iconColor: const Color(0xFF1E88E5),
                          ),
                          optionTile(
                            title:
                                'قسم ' +
                                _metricLabel(_QuickMetricType.received),
                            subtitle:
                                'عرض أو إخفاء بطاقات ' +
                                _metricLabel(_QuickMetricType.received),
                            value: _showReceivedCard,
                            onChanged: (v) => sync(() => _showReceivedCard = v),
                            icon: Icons.check_circle_rounded,
                            iconColor: const Color(0xFF2E7D32),
                          ),
                          optionTile(
                            title:
                                'قسم ' +
                                _metricLabel(_QuickMetricType.cancelled),
                            subtitle:
                                'عرض أو إخفاء بطاقات ' +
                                _metricLabel(_QuickMetricType.cancelled),
                            value: _showCancelledCard,
                            onChanged: (v) =>
                                sync(() => _showCancelledCard = v),
                            icon: Icons.cancel_rounded,
                            iconColor: const Color(0xFFC62828),
                          ),
                          optionTile(
                            title:
                                'قسم ' +
                                _metricLabel(_QuickMetricType.unreceived),
                            subtitle:
                                'عرض أو إخفاء بطاقات ' +
                                _metricLabel(_QuickMetricType.unreceived),
                            value: _showUnreceivedCard,
                            onChanged: (v) =>
                                sync(() => _showUnreceivedCard = v),
                            icon: Icons.hourglass_bottom_rounded,
                            iconColor: const Color(0xFF6A1B9A),
                          ),

                          const SizedBox(height: 8),
                          sectionTitle('التصدير', Icons.ios_share_rounded),
                          optionTile(
                            title: 'إخفاء الهيدر عند التصدير',
                            subtitle:
                                'عند حفظ الصورة أو مشاركتها يتم إخفاء الهيدر',
                            value: _hidePeriodBarInExport,
                            onChanged: (v) =>
                                sync(() => _hidePeriodBarInExport = v),
                            icon: Icons.image_rounded,
                          ),

                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () {
                                    sync(() {
                                      _showHeader = true;
                                      _showQuickStats = true;
                                      _showGlobalCards = false;
                                      _showAccountCards = false;
                                      _showCurrencyRows = true;
                                      _showDeltaStrip = true;
                                      _showAddedCard = true;
                                      _showReceivedCard = true;
                                      _showCancelledCard = true;
                                      _showUnreceivedCard = true;
                                      _hidePeriodBarInExport = false;
                                      _showAccountsInsideQuickCards = true;
                                    });
                                  },
                                  icon: const Icon(Icons.restart_alt_rounded),
                                  label: const Text('إعادة الافتراضي'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
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
        final accounts = accountsBox.values
            .where((a) => a.type == _accountTypeFilter)
            .toList();

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
              }
            });

            final global = _GlobalData.fromStats(stats);
            final exportHideHeaderLine = _hidePeriodBarInExport;

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
                      tooltip: 'الخيارات',
                      onPressed: _openDisplayOptions,
                      icon: const Icon(Icons.tune_rounded),
                    ),
                    IconButton(
                      tooltip: _busy ? 'جارٍ التنفيذ...' : 'حفظ الصورة',
                      onPressed: _busy
                          ? null
                          : () async {
                              final prevHeader = _showHeader;
                              if (exportHideHeaderLine) {
                                setState(() {
                                  _showHeader = false;
                                });
                                await Future.delayed(
                                  const Duration(milliseconds: 100),
                                );
                              }

                              await _saveAndMaybeShare(alsoShare: false);

                              if (mounted) {
                                setState(() {
                                  _showHeader = prevHeader;
                                });
                              }
                            },
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
                      onPressed: _busy
                          ? null
                          : () async {
                              final prevHeader = _showHeader;
                              if (exportHideHeaderLine) {
                                setState(() {
                                  _showHeader = false;
                                });
                                await Future.delayed(
                                  const Duration(milliseconds: 100),
                                );
                              }

                              await _saveAndMaybeShare(alsoShare: true);

                              if (mounted) {
                                setState(() {
                                  _showHeader = prevHeader;
                                });
                              }
                            },
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
                                      'إحصائيات ${_accountTypeFilter.label}',
                                      "${_periodLabel()} — ${_formatPeriodDate()}",
                                    ),

                                  if (_showHeader) const SizedBox(height: 12),

                                  if (_isCompanyStatsView) ...[
                                    _companyRuleNote(cs),
                                    const SizedBox(height: 12),
                                  ],

                                  if (_showQuickStats) ...[
                                    _buildQuickStats(stats, global),
                                    const SizedBox(height: 14),
                                  ],

                                  if (_showGlobalCards) ...[
                                    if (_showAddedCard)
                                      _categoryCard(
                                        title: _categoryTitle(
                                          _QuickMetricType.added,
                                        ),
                                        count: global.addedCount,
                                        totals: global.totalsAdded,
                                        prevTotals: global.prevTotalsAdded,
                                        icon: _metricIcon(
                                          _QuickMetricType.added,
                                        ),
                                        gradient: _metricGradient(
                                          _QuickMetricType.added,
                                        ),
                                        cs: cs,
                                        yesterday: global.yesterdayAddedCount,
                                        countsByCurrency: global.countsAdded,
                                        showAmountIndicators: true,
                                      ),
                                    if (_showAddedCard)
                                      const SizedBox(height: 14),

                                    if (_showReceivedCard)
                                      _categoryCard(
                                        title: _categoryTitle(
                                          _QuickMetricType.received,
                                        ),
                                        count: global.receivedCount,
                                        totals: global.totalsReceived,
                                        prevTotals: global.prevTotalsReceived,
                                        icon: _metricIcon(
                                          _QuickMetricType.received,
                                        ),
                                        gradient: _metricGradient(
                                          _QuickMetricType.received,
                                        ),
                                        cs: cs,
                                        yesterday:
                                            global.yesterdayReceivedCount,
                                        countsByCurrency: global.countsReceived,
                                        showAmountIndicators: true,
                                      ),
                                    if (_showReceivedCard)
                                      const SizedBox(height: 14),

                                    if (_showCancelledCard)
                                      _categoryCard(
                                        title: _categoryTitle(
                                          _QuickMetricType.cancelled,
                                        ),
                                        count: global.cancelledCount,
                                        totals: global.totalsCancelled,
                                        prevTotals: global.prevTotalsCancelled,
                                        icon: _metricIcon(
                                          _QuickMetricType.cancelled,
                                        ),
                                        gradient: _metricGradient(
                                          _QuickMetricType.cancelled,
                                        ),
                                        cs: cs,
                                        yesterday:
                                            global.yesterdayCancelledCount,
                                        countsByCurrency:
                                            global.countsCancelled,
                                        showAmountIndicators: true,
                                      ),
                                    if (_showCancelledCard)
                                      const SizedBox(height: 14),

                                    if (_showUnreceivedCard)
                                      _categoryCard(
                                        title: _categoryTitle(
                                          _QuickMetricType.unreceived,
                                        ),
                                        count: global.unreceivedCount,
                                        totals: global.totalsUnreceived,
                                        prevTotals: global.prevTotalsUnreceived,
                                        icon: _metricIcon(
                                          _QuickMetricType.unreceived,
                                        ),
                                        gradient: _metricGradient(
                                          _QuickMetricType.unreceived,
                                        ),
                                        cs: cs,
                                        yesterday:
                                            global.yesterdayUnreceivedCount,
                                        countsByCurrency:
                                            global.countsUnreceived,
                                        showAmountIndicators: true,
                                      ),
                                    if (_showUnreceivedCard)
                                      const SizedBox(height: 14),
                                  ],

                                  if (_showGlobalCards && _showAccountCards)
                                    const SizedBox(height: 18),

                                  if (_showAccountCards)
                                    ...stats.expand((s) {
                                      final widgets = <Widget>[];

                                      if (_showAddedCard) {
                                        widgets.add(
                                          _categoryCard(
                                            title: _categoryTitle(
                                              _QuickMetricType.added,
                                              s.account.name,
                                            ),
                                            count: s.addedNow.length,
                                            totals: s.totalsAddedNow,
                                            prevTotals: s.totalsAddedPrev,
                                            icon: Icons.add_circle_rounded,
                                            gradient: const [
                                              Color(0xFF1E88E5),
                                              Color(0xFF42A5F5),
                                            ],
                                            cs: cs,
                                            yesterday: s.addedPrev.length,
                                            countsByCurrency: s.countsAddedNow,
                                            showAmountIndicators: true,
                                          ),
                                        );
                                        widgets.add(const SizedBox(height: 12));
                                      }

                                      if (_showReceivedCard) {
                                        widgets.add(
                                          _categoryCard(
                                            title: _categoryTitle(
                                              _QuickMetricType.received,
                                              s.account.name,
                                            ),
                                            count: s.receivedNow.length,
                                            totals: s.totalsReceivedNow,
                                            prevTotals: s.totalsReceivedPrev,
                                            icon: Icons.check_circle_rounded,
                                            gradient: const [
                                              Color(0xFF2E7D32),
                                              Color(0xFF66BB6A),
                                            ],
                                            cs: cs,
                                            yesterday: s.receivedPrev.length,
                                            countsByCurrency:
                                                s.countsReceivedNow,
                                            showAmountIndicators: true,
                                          ),
                                        );
                                        widgets.add(const SizedBox(height: 12));
                                      }

                                      if (_showCancelledCard) {
                                        widgets.add(
                                          _categoryCard(
                                            title: _categoryTitle(
                                              _QuickMetricType.cancelled,
                                              s.account.name,
                                            ),
                                            count: s.cancelledNow.length,
                                            totals: s.totalsCancelledNow,
                                            prevTotals: s.totalsCancelledPrev,
                                            icon: Icons.cancel_rounded,
                                            gradient: const [
                                              Color(0xFFC62828),
                                              Color(0xFFEF5350),
                                            ],
                                            cs: cs,
                                            yesterday: s.cancelledPrev.length,
                                            countsByCurrency:
                                                s.countsCancelledNow,
                                            showAmountIndicators: true,
                                          ),
                                        );
                                        widgets.add(const SizedBox(height: 12));
                                      }

                                      if (_showUnreceivedCard) {
                                        widgets.add(
                                          _categoryCard(
                                            title: _categoryTitle(
                                              _QuickMetricType.unreceived,
                                              s.account.name,
                                            ),
                                            count: s.unreceivedNow.length,
                                            totals: s.totalsUnreceivedNow,
                                            prevTotals: s.totalsUnreceivedPrev,
                                            icon:
                                                Icons.hourglass_bottom_rounded,
                                            gradient: const [
                                              Color(0xFF6A1B9A),
                                              Color(0xFFAB47BC),
                                            ],
                                            cs: cs,
                                            yesterday: s.unreceivedPrev.length,
                                            countsByCurrency:
                                                s.countsUnreceivedNow,
                                            showAmountIndicators: true,
                                          ),
                                        );
                                        widgets.add(const SizedBox(height: 12));
                                      }

                                      widgets.add(const SizedBox(height: 18));
                                      return widgets;
                                    }),
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
