import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/period_stats.dart';
import 'share_image_page.dart';

class AccountStatsScreen extends StatefulWidget {
  final Account account;

  const AccountStatsScreen({
    super.key,
    required this.account,
  });

  @override
  State<AccountStatsScreen> createState() => _AccountStatsScreenState();
}

class _AccountStatsScreenState extends State<AccountStatsScreen> {
  DateTime _selected = DateTime.now();

  bool get _isCompany => widget.account.type.isCompany;

  /// نص الحالة المعروض على بطاقة الحركة
  String _statusTextOf(TransactionModel t) {
    final m = t.effectiveCompanyMovement;
    if (_isCompany && m != null) return m.label;
    switch (t.status) {
      case TransactionStatus.added:
        return 'مضافة';
      case TransactionStatus.received:
        return 'مستلمة';
      case TransactionStatus.cancelled:
        return 'ملغاة';
    }
  }

  /// توضيح إضافي لحركة ظهرت في قسم الإضافة لكنها أُلغيت لاحقًا
  String? _laterCancelNote(TransactionModel t) {
    final cancelAt = PeriodStats.companyCancelMoment(t);
    if (cancelAt == null) return null;
    return 'أُلغيت بتاريخ ${_fmtYmdHm(cancelAt)} — تُحسب هنا كإضافة وفي قسم الإلغاء كإلغاء';
  }

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
  DateTime _endOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

  String _fmtYmd(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  String _fmtHm(DateTime d) =>
      "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";

  String _fmtYmdHm(DateTime d) => "${_fmtYmd(d)}  ${_fmtHm(d)}";

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dd = DateTime(d.year, d.month, d.day);

    if (dd == today) return "اليوم";
    if (dd == today.subtract(const Duration(days: 1))) return "أمس";
    return _fmtYmd(d);
  }

  bool _canGoNext(DateTime d) {
    final today = _startOfDay(DateTime.now());
    return _startOfDay(d).isBefore(today);
  }

  void _goToToday() => setState(() => _selected = DateTime.now());

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selected,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now(),
      helpText: 'اختر التاريخ',
      confirmText: 'اختيار',
      cancelText: 'إلغاء',
    );
    if (picked != null) {
      setState(() => _selected = picked);
    }
  }

  void _shiftDay(int delta) {
    final target = _selected.add(Duration(days: delta));
    if (delta > 0 && !_canGoNext(_selected)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("لا يمكن الانتقال إلى تاريخ قادم بعد اليوم."),
        ),
      );
      return;
    }
    setState(() => _selected = target);
  }

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
        _MoneyPart(
          currency: _secondCurrencyOf(t),
          amount: t.secondAmount!,
        ),
      );
    }

    return parts;
  }

  Map<String, double> _totalsByCurrency(Iterable<TransactionModel> list) {
    final out = <String, double>{};
    for (final t in list) {
      for (final p in _moneyPartsOf(t)) {
        final cur = p.currency.trim();
        if (cur.isEmpty) continue;
        out.update(cur, (v) => v + p.amount, ifAbsent: () => p.amount);
      }
    }
    return out;
  }

  Map<String, int> _countsByCurrency(Iterable<TransactionModel> list) {
    final out = <String, int>{};
    for (final t in list) {
      for (final p in _moneyPartsOf(t)) {
        final cur = p.currency.trim();
        if (cur.isEmpty) continue;
        out.update(cur, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    return out;
  }

  double _sumTotals(Map<String, double> m) =>
      m.values.fold(0.0, (a, b) => a + b);

  String _formatAmount(double v) {
    final s = v.toStringAsFixed(2);
    final parts = s.split('.');
    final intPart = parts[0];
    final dec = parts.length > 1 ? parts[1] : '00';

    final chars = intPart.split('').reversed.toList();
    final out = <String>[];
    for (int i = 0; i < chars.length; i++) {
      out.add(chars[i]);
      if ((i + 1) % 3 == 0 && i != chars.length - 1) {
        out.add(',');
      }
    }
    return '${out.reversed.join()}.$dec';
  }

  String _formatMoneyParts(TransactionModel t) {
    final parts = _moneyPartsOf(t);
    return parts
        .map((p) => '${_formatAmount(p.amount)} ${p.currency}')
        .join('\n');
  }

  String _shortMoneyParts(TransactionModel t) {
    final parts = _moneyPartsOf(t);
    return parts
        .map((p) => '${_formatAmount(p.amount)} ${p.currency}')
        .join('  •  ');
  }

  (IconData, String, Color, int) _deltaParts(int today, int yesterday) {
    if (yesterday == 0 && today == 0) {
      return (Icons.remove_rounded, "0%", Colors.grey, 0);
    }
    if (yesterday == 0 && today > 0) {
      return (Icons.trending_up_rounded, "+100%", Colors.green, today);
    }

    final diff = today - yesterday;
    final ratio = diff / (yesterday == 0 ? 1 : yesterday);
    final pct = (ratio * 100).toStringAsFixed(0);

    if (diff > 0) {
      return (Icons.trending_up_rounded, "+$pct%", Colors.green, diff);
    }
    if (diff < 0) {
      return (Icons.trending_down_rounded, "$pct%", Colors.red, diff);
    }
    return (Icons.trending_flat_rounded, "0%", Colors.grey, 0);
  }

  void _openBucketDetails(_StatsBucket bucket) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) {
        final cs = Theme.of(context).colorScheme;

        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: .88,
              minChildSize: .55,
              maxChildSize: .96,
              builder: (context, controller) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: bucket.color.withOpacity(.12),
                            child: Icon(bucket.icon, color: bucket.color),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              bucket.title,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: bucket.color.withOpacity(.10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: bucket.color.withOpacity(.25),
                              ),
                            ),
                            child: Text(
                              '${bucket.items.length}',
                              style: TextStyle(
                                color: bucket.color,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: _BucketBreakdownCard(
                        title: 'ملخص العملات',
                        accent: bucket.color,
                        totals: bucket.totals,
                        counts: bucket.counts,
                        grandTotalLabel:
                        '${_formatAmount(_sumTotals(bucket.totals))}',
                      ),
                    ),
                    Expanded(
                      child: bucket.items.isEmpty
                          ? Center(
                        child: Text(
                          'لا توجد حركات في هذا القسم',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                          : ListView.separated(
                        controller: controller,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        itemCount: bucket.items.length,
                        separatorBuilder: (_, __) =>
                        const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final t = bucket.items[index];
                          return TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: 1),
                            duration: Duration(
                              milliseconds: 240 + (index * 35),
                            ),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, child) {
                              return Transform.translate(
                                offset: Offset(0, (1 - value) * 18),
                                child: Opacity(
                                  opacity: value,
                                  child: child,
                                ),
                              );
                            },
                            child: _TransactionDetailCard(
                              tx: t,
                              title: t.beneficiary,
                              accent: bucket.color,
                              statusText: _statusTextOf(t),
                              moneyText: _shortMoneyParts(t),
                              fullMoneyText: _formatMoneyParts(t),
                              timeLabel: bucket.timeLabel,
                              timeValue:
                              _fmtYmdHm(bucket.timeOf(t) ?? t.date),
                              statsNote: bucket.noteOf?.call(t),
                              note: t.notes.trim().isEmpty ? null : t.notes,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final rangeStart = _startOfDay(_selected);
    final rangeEnd = _endOfDay(_selected);

    final yDate = _selected.subtract(const Duration(days: 1));
    final yesterdayStart = _startOfDay(yDate);
    final yesterdayEnd = _endOfDay(yDate);
    final isCompany = _isCompany;

    return ValueListenableBuilder(
      valueListenable: DatabaseService.transactionsBox.listenable(),
      builder: (context, Box<TransactionModel> box, _) {
        final allForAccount = box.values
            .where((t) => t.accountId == widget.account.id)
            .toList();

        // نفس المنطق للمكاتب والشركات: الإضافة تُحسب بتاريخ إضافتها (حتى لو
        // أُلغيت لاحقًا) والإلغاء يُحسب بتاريخ إلغائه، فالحركة التي أُضيفت ثم
        // أُلغيت تُحسب إضافة وإلغاء معًا.
        final today = PeriodStats.compute(
          allForAccount,
          StatsPeriod(rangeStart, rangeEnd),
          company: isCompany,
        );
        final yesterday = PeriodStats.compute(
          allForAccount,
          StatsPeriod(yesterdayStart, yesterdayEnd),
          company: isCompany,
        );

        final createdToday = today.added;
        final receivedToday = today.received;
        final cancelledToday = today.cancelled;
        final unreceivedAsOfSelected = today.fourth;

        final createdYesterday = yesterday.added.length;
        final receivedYesterday = yesterday.received.length;
        final cancelledYesterday = yesterday.cancelled.length;
        final unreceivedYesterday = yesterday.fourth.length;

        final totalsCreated = _totalsByCurrency(createdToday);
        final totalsReceived = _totalsByCurrency(receivedToday);
        final totalsCancelled = _totalsByCurrency(cancelledToday);
        final totalsUnreceived = _totalsByCurrency(unreceivedAsOfSelected);

        final countsAddedByCurrency = _countsByCurrency(createdToday);
        final countsReceivedByCurrency = _countsByCurrency(receivedToday);
        final countsCancelledByCurrency = _countsByCurrency(cancelledToday);
        final countsUnreceivedByCurrency =
        _countsByCurrency(unreceivedAsOfSelected);

        final shareData = ShareStatsData(
          accountName: widget.account.name,
          dateLabel: _dayLabel(_selected),
          addedCount: createdToday.length,
          receivedCount: receivedToday.length,
          cancelledCount: cancelledToday.length,
          unreceivedCount: unreceivedAsOfSelected.length,
          yesterdayAddedCount: createdYesterday,
          yesterdayReceivedCount: receivedYesterday,
          yesterdayCancelledCount: cancelledYesterday,
          yesterdayUnreceivedCount: unreceivedYesterday,
          totalsAdded: totalsCreated,
          totalsReceived: totalsReceived,
          totalsCancelled: totalsCancelled,
          totalsUnreceived: totalsUnreceived,
          countsAddedByCurrency: countsAddedByCurrency,
          countsReceivedByCurrency: countsReceivedByCurrency,
          countsCancelledByCurrency: countsCancelledByCurrency,
          countsUnreceivedByCurrency: countsUnreceivedByCurrency,
          addedLabel: PeriodStats.label(PeriodMetric.added, company: isCompany),
          receivedLabel:
              PeriodStats.label(PeriodMetric.received, company: isCompany),
          cancelledLabel:
              PeriodStats.label(PeriodMetric.cancelled, company: isCompany),
          unreceivedLabel:
              PeriodStats.label(PeriodMetric.fourth, company: isCompany),
        );

        final buckets = isCompany
            ? <_StatsBucket>[
                _StatsBucket(
                  title: 'الإرسال (أُضيفت في هذا اليوم)',
                  subtitle:
                      'كل حركة إرسال أُضيفت في هذا اليوم حتى لو أُلغيت لاحقًا',
                  color: const Color(0xFF5E35B1),
                  icon: Icons.call_made_rounded,
                  items: createdToday,
                  todayCount: createdToday.length,
                  yesterdayCount: createdYesterday,
                  totals: totalsCreated,
                  counts: countsAddedByCurrency,
                  timeLabel: 'تاريخ الإضافة',
                  timeOf: (t) => t.date,
                  noteOf: _laterCancelNote,
                ),
                _StatsBucket(
                  title: 'الاستقبال (أُضيفت في هذا اليوم)',
                  subtitle:
                      'كل حركة استقبال أُضيفت في هذا اليوم حتى لو أُلغيت لاحقًا',
                  color: const Color(0xFF00897B),
                  icon: Icons.call_received_rounded,
                  items: receivedToday,
                  todayCount: receivedToday.length,
                  yesterdayCount: receivedYesterday,
                  totals: totalsReceived,
                  counts: countsReceivedByCurrency,
                  timeLabel: 'تاريخ الإضافة',
                  timeOf: (t) => t.date,
                  noteOf: _laterCancelNote,
                ),
                _StatsBucket(
                  title: 'إلغاء مرسل (أُلغيت في هذا اليوم)',
                  subtitle:
                      'حركات الإرسال التي أُلغيت في هذا اليوم مهما كان تاريخ إضافتها',
                  color: const Color(0xFFEF6C00),
                  icon: Icons.cancel_schedule_send_rounded,
                  items: cancelledToday,
                  todayCount: cancelledToday.length,
                  yesterdayCount: cancelledYesterday,
                  totals: totalsCancelled,
                  counts: countsCancelledByCurrency,
                  timeLabel: 'تاريخ الإلغاء',
                  timeOf: PeriodStats.companyCancelMoment,
                ),
                _StatsBucket(
                  title: 'إلغاء استقبال (أُلغيت في هذا اليوم)',
                  subtitle:
                      'حركات الاستقبال التي أُلغيت في هذا اليوم مهما كان تاريخ إضافتها',
                  color: const Color(0xFFD84315),
                  icon: Icons.cancel_rounded,
                  items: unreceivedAsOfSelected,
                  todayCount: unreceivedAsOfSelected.length,
                  yesterdayCount: unreceivedYesterday,
                  totals: totalsUnreceived,
                  counts: countsUnreceivedByCurrency,
                  timeLabel: 'تاريخ الإلغاء',
                  timeOf: PeriodStats.companyCancelMoment,
                ),
              ]
            : <_StatsBucket>[
          _StatsBucket(
            title: 'المضافة (إنشاء اليوم)',
            subtitle: 'الحركات التي أُنشئت في هذا اليوم',
            color: Colors.blue,
            icon: Icons.add_circle_rounded,
            items: createdToday,
            todayCount: createdToday.length,
            yesterdayCount: createdYesterday,
            totals: totalsCreated,
            counts: countsAddedByCurrency,
            timeLabel: 'تاريخ الإضافة',
            timeOf: (t) => t.date,
          ),
          _StatsBucket(
            title: 'المستلمة (اليوم)',
            subtitle: 'الحركات التي تم تسليمها اليوم',
            color: Colors.green,
            icon: Icons.download_done_rounded,
            items: receivedToday,
            todayCount: receivedToday.length,
            yesterdayCount: receivedYesterday,
            totals: totalsReceived,
            counts: countsReceivedByCurrency,
            timeLabel: 'تاريخ التسليم',
            timeOf: (t) => t.receivedAt,
          ),
          _StatsBucket(
            title: 'الملغاة (اليوم)',
            subtitle: 'الحركات التي أُلغيت اليوم',
            color: Colors.red,
            icon: Icons.cancel_rounded,
            items: cancelledToday,
            todayCount: cancelledToday.length,
            yesterdayCount: cancelledYesterday,
            totals: totalsCancelled,
            counts: countsCancelledByCurrency,
            timeLabel: 'تاريخ الإلغاء',
            timeOf: (t) => t.cancelledAt,
          ),
          _StatsBucket(
            title: 'غير مستلمة (حتى نهاية اليوم)',
            subtitle: 'لقطة تاريخية للحركات غير المستلمة حتى نهاية هذا اليوم',
            color: Colors.indigo,
            icon: Icons.hourglass_top_rounded,
            items: unreceivedAsOfSelected,
            todayCount: unreceivedAsOfSelected.length,
            yesterdayCount: unreceivedYesterday,
            totals: totalsUnreceived,
            counts: countsUnreceivedByCurrency,
            timeLabel: 'تاريخ الحركة',
            timeOf: (t) => t.date,
          ),
        ];

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor: isDark ? cs.surface : cs.background,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              centerTitle: true,
              title: Text("إحصائيات — ${widget.account.name}"),
              actions: [
                IconButton(
                  tooltip: 'مشاركة التصميم',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ShareImagePage(data: shareData),
                      ),
                    );
                  },
                  icon: const Icon(Icons.wallpaper_rounded),
                ),
              ],
            ),
            body: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [cs.surface, cs.surfaceContainerHighest]
                      : [cs.background, cs.surface],
                ),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: _HeroHeaderCard(
                        accountName: widget.account.name,
                        dayLabel: _dayLabel(_selected),
                        onTapShare: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ShareImagePage(data: shareData),
                            ),
                          );
                        },
                        onTapToday: _goToToday,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _DayNavigatorBar(
                        label: _dayLabel(_selected),
                        fullDate: _fmtYmd(_selected),
                        onPick: _pickDate,
                        onPrevious: () => _shiftDay(-1),
                        onNext: _canGoNext(_selected)
                            ? () => _shiftDay(1)
                            : null,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        children: [
                          if (isCompany) ...[
                            const _RuleNoteCard(
                              text: PeriodStats.companyRuleText,
                            ),
                            const SizedBox(height: 12),
                          ],
                          _AnimatedStatsGrid(
                            buckets: buckets,
                            onTapBucket: _openBucketDetails,
                          ),
                          const SizedBox(height: 14),
                          ...buckets.asMap().entries.map((entry) {
                            final i = entry.key;
                            final bucket = entry.value;
                            return TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0, end: 1),
                              duration: Duration(milliseconds: 280 + (i * 60)),
                              curve: Curves.easeOutCubic,
                              builder: (context, value, child) {
                                return Transform.translate(
                                  offset: Offset(0, (1 - value) * 20),
                                  child: Opacity(opacity: value, child: child),
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _BucketBreakdownCard(
                                  title: bucket.title,
                                  subtitle: bucket.subtitle,
                                  accent: bucket.color,
                                  icon: bucket.icon,
                                  totals: bucket.totals,
                                  counts: bucket.counts,
                                  grandTotalLabel:
                                  _formatAmount(_sumTotals(bucket.totals)),
                                  onOpenDetails: () => _openBucketDetails(bucket),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: _goToToday,
              label: const Text('اليوم'),
              icon: const Icon(Icons.today_rounded),
            ),
          ),
        );
      },
    );
  }
}

class _MoneyPart {
  final String currency;
  final double amount;

  const _MoneyPart({
    required this.currency,
    required this.amount,
  });
}

class _StatsBucket {
  final String title;
  final String subtitle;
  final Color color;
  final IconData icon;
  final List<TransactionModel> items;
  final int todayCount;
  final int yesterdayCount;
  final Map<String, double> totals;
  final Map<String, int> counts;
  final String timeLabel;
  final DateTime? Function(TransactionModel) timeOf;

  /// ملاحظة إضافية اختيارية تظهر على بطاقة الحركة داخل التفاصيل
  final String? Function(TransactionModel)? noteOf;

  const _StatsBucket({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.icon,
    required this.items,
    required this.todayCount,
    required this.yesterdayCount,
    required this.totals,
    required this.counts,
    required this.timeLabel,
    required this.timeOf,
    this.noteOf,
  });
}

class _RuleNoteCard extends StatelessWidget {
  final String text;

  const _RuleNoteCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroHeaderCard extends StatelessWidget {
  final String accountName;
  final String dayLabel;
  final VoidCallback onTapShare;
  final VoidCallback onTapToday;

  const _HeroHeaderCard({
    required this.accountName,
    required this.dayLabel,
    required this.onTapShare,
    required this.onTapToday,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            cs.primary.withOpacity(.18),
            cs.secondary.withOpacity(.10),
            cs.surfaceContainerHigh,
          ],
        ),
        border: Border.all(color: cs.primary.withOpacity(.18)),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withOpacity(.10),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: cs.primary.withOpacity(.14),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.query_stats_rounded,
              color: cs.primary,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  accountName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Text(
                    dayLabel,
                    key: ValueKey(dayLabel),
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            onPressed: onTapToday,
            icon: const Icon(Icons.today_rounded),
          ),
          const SizedBox(width: 6),
          IconButton.filled(
            onPressed: onTapShare,
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
    );
  }
}

class _DayNavigatorBar extends StatelessWidget {
  final String label;
  final String fullDate;
  final VoidCallback onPick;
  final VoidCallback onPrevious;
  final VoidCallback? onNext;

  const _DayNavigatorBar({
    required this.label,
    required this.fullDate,
    required this.onPick,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withOpacity(.20)),
      ),
      child: Row(
        children: [
          IconButton.filledTonal(
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onPick,
              child: Padding(
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Column(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        label,
                        key: ValueKey(label),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fullDate,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
        ],
      ),
    );
  }
}

class _AnimatedStatsGrid extends StatelessWidget {
  final List<_StatsBucket> buckets;
  final ValueChanged<_StatsBucket> onTapBucket;

  const _AnimatedStatsGrid({
    required this.buckets,
    required this.onTapBucket,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 12) / 2;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: buckets.asMap().entries.map((entry) {
            final i = entry.key;
            final bucket = entry.value;

            return SizedBox(
              width: itemWidth,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: Duration(milliseconds: 220 + (i * 60)),
                curve: Curves.easeOutBack,
                builder: (context, value, child) {
                  return Transform.scale(
                    scale: 0.94 + (value * .06),
                    child: Opacity(opacity: value, child: child),
                  );
                },
                child: _SummaryCard(
                  bucket: bucket,
                  onTap: () => onTapBucket(bucket),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final _StatsBucket bucket;
  final VoidCallback onTap;

  const _SummaryCard({
    required this.bucket,
    required this.onTap,
  });

  (IconData, String, Color, int) _deltaParts(int today, int yesterday) {
    if (yesterday == 0 && today == 0) {
      return (Icons.remove_rounded, '0%', Colors.grey, 0);
    }
    if (yesterday == 0 && today > 0) {
      return (Icons.trending_up_rounded, '+100%', Colors.green, today);
    }

    final diff = today - yesterday;
    final ratio = diff / (yesterday == 0 ? 1 : yesterday);
    final pct = (ratio * 100).toStringAsFixed(0);

    if (diff > 0) {
      return (Icons.trending_up_rounded, '+$pct%', Colors.green, diff);
    }
    if (diff < 0) {
      return (Icons.trending_down_rounded, '$pct%', Colors.red, diff);
    }
    return (Icons.trending_flat_rounded, '0%', Colors.grey, 0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final delta = _deltaParts(bucket.todayCount, bucket.yesterdayCount);

    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              bucket.color.withOpacity(.18),
              cs.surfaceContainerHigh,
            ],
          ),
          border: Border.all(color: bucket.color.withOpacity(.22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: bucket.color.withOpacity(.12),
                  child: Icon(bucket.icon, color: bucket.color),
                ),
                const Spacer(),
                Icon(Icons.open_in_full_rounded,
                    size: 18, color: cs.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              bucket.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '${bucket.todayCount}',
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 28,
                height: 1,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(delta.$1, size: 16, color: delta.$3),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'عن أمس: ${delta.$2} (${delta.$4 >= 0 ? '+' : ''}${delta.$4})',
                    style: TextStyle(
                      color: delta.$3,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BucketBreakdownCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Color accent;
  final IconData? icon;
  final Map<String, double> totals;
  final Map<String, int> counts;
  final String grandTotalLabel;
  final VoidCallback? onOpenDetails;

  const _BucketBreakdownCard({
    required this.title,
    this.subtitle,
    required this.accent,
    this.icon,
    required this.totals,
    required this.counts,
    required this.grandTotalLabel,
    this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final keys = totals.keys.toList()..sort();

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accent.withOpacity(.20)),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(.08),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: accent.withOpacity(.12),
                    child: Icon(icon, color: accent, size: 18),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      if ((subtitle ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onOpenDetails != null)
                  TextButton.icon(
                    onPressed: onOpenDetails,
                    icon: const Icon(Icons.visibility_rounded, size: 18),
                    label: const Text('تفاصيل'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (keys.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  'لا توجد مبالغ في هذا القسم',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              )
            else
              Column(
                children: keys.map((cur) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _CurrencyRow(
                      accent: accent,
                      currency: cur,
                      total: totals[cur] ?? 0.0,
                      count: counts[cur] ?? 0,
                    ),
                  );
                }).toList(),
              ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: accent.withOpacity(.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: accent.withOpacity(.18)),
              ),
              child: Row(
                children: [
                  Icon(Icons.functions_rounded, color: accent, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'إجمالي كل العملات',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    grandTotalLabel,
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrencyRow extends StatelessWidget {
  final Color accent;
  final String currency;
  final double total;
  final int count;

  const _CurrencyRow({
    required this.accent,
    required this.currency,
    required this.total,
    required this.count,
  });

  String _formatAmount(double v) {
    final s = v.toStringAsFixed(2);
    final parts = s.split('.');
    final intPart = parts[0];
    final dec = parts.length > 1 ? parts[1] : '00';

    final chars = intPart.split('').reversed.toList();
    final out = <String>[];
    for (int i = 0; i < chars.length; i++) {
      out.add(chars[i]);
      if ((i + 1) % 3 == 0 && i != chars.length - 1) {
        out.add(',');
      }
    }
    return '${out.reversed.join()}.$dec';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(.15)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: accent.withOpacity(.10),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              currency,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            _formatAmount(total),
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionDetailCard extends StatelessWidget {
  final TransactionModel tx;
  final String title;
  final Color accent;
  final String statusText;
  final String moneyText;
  final String fullMoneyText;
  final String timeLabel;
  final String timeValue;
  final String? statsNote;
  final String? note;

  const _TransactionDetailCard({
    required this.tx,
    required this.title,
    required this.accent,
    required this.statusText,
    required this.moneyText,
    required this.fullMoneyText,
    required this.timeLabel,
    required this.timeValue,
    this.statsNote,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(.18)),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(.08),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: accent.withOpacity(.12),
                child: Icon(Icons.person_rounded, color: accent, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: accent.withOpacity(.10),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              fullMoneyText,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(
                '$timeLabel: ',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Expanded(child: Text(timeValue)),
            ],
          ),
          if ((statsNote ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.error.withValues(alpha: .22)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      statsNote!,
                      style: const TextStyle(fontSize: 12.5, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if ((note ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.amber.withOpacity(.25),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.sticky_note_2_rounded,
                      color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note!,
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}