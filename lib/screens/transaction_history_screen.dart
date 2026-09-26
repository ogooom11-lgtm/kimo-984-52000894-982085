// lib/screens/transaction_history_screen.dart
// -------------------------------------------------------------
// صفحة «سجل التعديلات» لحركة واحدة: خط زمني لكل تعديل على الحركة (المبلغ،
// الاسم، العملة، الحالة، النقل بين الحسابات...) بصيغة «من ... إلى ...» مع
// التاريخ والوقت، مجمّع حسب اليوم ويتحدث مباشرة.
// -------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/tx_history_service.dart';

/// افتح صفحة سجل تعديلات الحركة
Future<void> openTransactionHistory(BuildContext context, TransactionModel tx) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TransactionHistoryScreen(txId: tx.id, initialTx: tx),
    ),
  );
}

enum _HistoryFilter { all, data, status }

class _DayLabel {
  final String text;
  final int count;
  const _DayLabel(this.text, this.count);
}

class TransactionHistoryScreen extends StatefulWidget {
  final int txId;

  /// الحركة عند فتح الصفحة (تبقى معروضة إن حُذفت الحركة لاحقًا)
  final TransactionModel? initialTx;

  const TransactionHistoryScreen({
    super.key,
    required this.txId,
    this.initialTx,
  });

  @override
  State<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState extends State<TransactionHistoryScreen> {
  _HistoryFilter _filter = _HistoryFilter.all;
  dynamic _hiveKey;

  /// الإدخالات (null = أول تحميل لم ينتهِ)
  List<TxHistoryEntry>? _entries;
  bool _loading = false;
  bool _dirty = false;

  late final Listenable _changes = Listenable.merge([
    DatabaseService.transactionsBox.listenable(),
    DatabaseService.accountsBox.listenable(),
    TxHistoryService.revision,
  ]);

  static const List<String> _weekdays = [
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];

  @override
  void initState() {
    super.initState();
    final t = widget.initialTx;
    if (t != null && t.isInBox) _hiveKey = t.key;
    _changes.addListener(_onChanged);
    _reload();
  }

  @override
  void dispose() {
    _changes.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    _reload();
  }

  /// تحميل السجل (القراءة من القرص غير متزامنة؛ التغييرات المتلاحقة تُدمج)
  Future<void> _reload() async {
    if (_loading) {
      _dirty = true;
      return;
    }
    _loading = true;
    try {
      do {
        _dirty = false;
        // حسب الوقت: التعديل من رسالة يحمل وقت الرسالة لا وقت الحفظ
        final list = sortEntriesByTime(
          await TxHistoryService.entriesFor(widget.txId),
        );
        if (!mounted) return;
        setState(() => _entries = list);
      } while (_dirty);
    } finally {
      _loading = false;
    }
  }

  /// الحركة الحالية من الصندوق (null إن حُذفت)
  TransactionModel? _liveTx() {
    final box = DatabaseService.transactionsBox;
    final k = _hiveKey;
    if (k != null) {
      final t = box.get(k);
      if (t != null && t.id == widget.txId) return t;
    }
    for (final key in box.keys) {
      final t = box.get(key);
      if (t != null && t.id == widget.txId) {
        _hiveKey = key;
        return t;
      }
    }
    _hiveKey = null;
    return null;
  }

  bool _matches(TxHistoryEntry e) {
    switch (_filter) {
      case _HistoryFilter.all:
        return true;
      case _HistoryFilter.data:
        return e.touchesData;
      case _HistoryFilter.status:
        return e.touchesStatus;
    }
  }

  // ===========================
  // تنسيقات
  // ===========================

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = (today.difference(d).inHours / 24).round();
    if (diff == 0) return 'اليوم';
    if (diff == 1) return 'أمس';
    return '${_weekdays[d.weekday - 1]} ${TxHistoryFormatter.day(d)}';
  }

  static String _plural(
    int n,
    String one,
    String two,
    String few,
    String many,
  ) {
    if (n == 1) return one;
    if (n == 2) return two;
    if (n >= 3 && n <= 10) return '$n $few';
    return '$n $many';
  }

  static String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) {
      return 'قبل ${_plural(diff.inMinutes, 'دقيقة', 'دقيقتين', 'دقائق', 'دقيقة')}';
    }
    if (diff.inHours < 24) {
      return 'قبل ${_plural(diff.inHours, 'ساعة', 'ساعتين', 'ساعات', 'ساعة')}';
    }
    if (diff.inDays < 7) {
      return 'قبل ${_plural(diff.inDays, 'يوم', 'يومين', 'أيام', 'يومًا')}';
    }
    return TxHistoryFormatter.day(d);
  }

  static String _countLabel(int n) =>
      _plural(n, 'تعديل واحد', 'تعديلان', 'تعديلات', 'تعديلًا');

  static Color _toneColor(TxEntryTone t) {
    switch (t) {
      case TxEntryTone.edit:
        return const Color(0xFF3B82F6);
      case TxEntryTone.received:
        return const Color(0xFF00A76F);
      case TxEntryTone.cancelled:
        return const Color(0xFFE53935);
      case TxEntryTone.added:
        return const Color(0xFFF59E0B);
      case TxEntryTone.moved:
        return const Color(0xFF7C3AED);
      case TxEntryTone.movement:
        return const Color(0xFF0891B2);
      case TxEntryTone.deleted:
        return const Color(0xFFB91C1C);
      case TxEntryTone.restored:
        return const Color(0xFF0D9488);
    }
  }

  static IconData _toneIcon(TxEntryTone t) {
    switch (t) {
      case TxEntryTone.edit:
        return Icons.edit_rounded;
      case TxEntryTone.received:
        return Icons.check_rounded;
      case TxEntryTone.cancelled:
        return Icons.close_rounded;
      case TxEntryTone.added:
        return Icons.undo_rounded;
      case TxEntryTone.moved:
        return Icons.swap_horiz_rounded;
      case TxEntryTone.movement:
        return Icons.sync_alt_rounded;
      case TxEntryTone.deleted:
        return Icons.delete_outline_rounded;
      case TxEntryTone.restored:
        return Icons.restore_rounded;
    }
  }

  static IconData _rowIcon(TxRowKind k) {
    switch (k) {
      case TxRowKind.status:
        return Icons.flag_rounded;
      case TxRowKind.movement:
        return Icons.sync_alt_rounded;
      case TxRowKind.account:
        return Icons.account_balance_wallet_rounded;
      case TxRowKind.name:
        return Icons.person_rounded;
      case TxRowKind.money:
        return Icons.payments_rounded;
      case TxRowKind.secondMoney:
        return Icons.payments_outlined;
      case TxRowKind.date:
        return Icons.event_rounded;
      case TxRowKind.receivedAt:
        return Icons.event_available_rounded;
      case TxRowKind.cancelledAt:
        return Icons.event_busy_rounded;
      case TxRowKind.notes:
        return Icons.sticky_note_2_rounded;
      case TxRowKind.deleted:
        return Icons.delete_outline_rounded;
      case TxRowKind.restored:
        return Icons.restore_rounded;
    }
  }

  static Color? _statusTagColor(String? tag) {
    switch (tag) {
      case 'added':
        return const Color(0xFF1E88E5);
      case 'received':
        return const Color(0xFF00A76F);
      case 'cancelled':
        return const Color(0xFFE53935);
    }
    return null;
  }

  static Color? _movementColor(CompanyMovementType? m) {
    switch (m) {
      case CompanyMovementType.received:
        return const Color(0xFF00897B);
      case CompanyMovementType.sent:
        return const Color(0xFF5E35B1);
      case CompanyMovementType.receivedCancelled:
        return const Color(0xFFD84315);
      case CompanyMovementType.sentCancelled:
        return const Color(0xFFEF6C00);
      case null:
        return null;
    }
  }

  // ===========================
  // النسخ
  // ===========================

  void _copy(
    TransactionModel? tx,
    List<TxHistoryEntry> entries,
    TxHistoryFormatter fmt,
    Map<int, String> names,
  ) {
    final header =
        'سجل تعديلات الحركة: ${tx?.beneficiary ?? '#${widget.txId}'}';
    final details = <String>[
      if (tx != null) 'الحساب: ${names[tx.accountId] ?? '—'}',
      if (tx != null)
        'المبلغ الحالي: ${TxHistoryFormatter.amount(tx.amount)} ${tx.currency}',
    ];
    final text = fmt.plainText(entries, header: header, details: details);
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم نسخ سجل التعديلات')));
  }

  // ===========================
  // البناء
  // ===========================

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final live = _liveTx();
    final tx = live ?? widget.initialTx;
    final names = <int, String>{
      for (final a in DatabaseService.accountsBox.values) a.id: a.name,
    };
    final fmt = TxHistoryFormatter(accountNameOf: (id) => names[id]);
    final loaded = _entries != null;
    final entries = _entries ?? const <TxHistoryEntry>[];
    final shown = entries.where(_matches).toList();
    final since = TxHistoryService.trackingSince;
    final created = txCreationTimeFromId(widget.txId);
    final olderThanTracking =
        since != null && (created == null || created.isBefore(since));

    // عناصر الخط الزمني: عنوان اليوم ثم تعديلاته
    final items = <Object>[];
    for (int i = 0; i < shown.length; i++) {
      final e = shown[i];
      final d = DateTime(e.at.year, e.at.month, e.at.day);
      final prev = i == 0 ? null : shown[i - 1].at;
      if (prev == null ||
          prev.year != d.year ||
          prev.month != d.month ||
          prev.day != d.day) {
        int n = 0;
        for (int j = i; j < shown.length; j++) {
          final a = shown[j].at;
          if (a.year != d.year || a.month != d.month || a.day != d.day) break;
          n++;
        }
        items.add(_DayLabel(_dayLabel(d), n));
      }
      items.add(e);
    }
    final showOrigin = _filter == _HistoryFilter.all && shown.isNotEmpty;
    final lineColor = cs.outlineVariant.withValues(alpha: isDark ? .45 : .7);

    return Scaffold(
      backgroundColor: isDark ? null : const Color(0xFFF6F8FC),
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'سجل التعديلات',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            if (tx != null && tx.beneficiary.trim().isNotEmpty)
              Text(
                tx.beneficiary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          if (shown.isNotEmpty)
            IconButton(
              tooltip: 'نسخ السجل',
              icon: const Icon(Icons.copy_all_rounded),
              onPressed: () => _copy(tx, shown, fmt, names),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            sliver: SliverToBoxAdapter(
              child: _buildHeader(
                context,
                tx: tx,
                deleted: live == null,
                entries: entries,
                created: created,
                names: names,
              ),
            ),
          ),
          if (entries.isNotEmpty)
            SliverToBoxAdapter(child: _buildFilterBar(context, entries)),
          if (!loaded)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
              ),
            )
          else if (shown.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildEmpty(
                context,
                filtered: entries.isNotEmpty,
                since: olderThanTracking ? since : null,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 6, 16, 0),
              sliver: SliverList.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  final isLast = i == items.length - 1 && !showOrigin;
                  if (item is _DayLabel) {
                    return _TimelineRow(
                      lineColor: lineColor,
                      lineAbove: i > 0,
                      lineBelow: true,
                      markerTop: 10,
                      marker: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: cs.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: cs.outline, width: 2),
                        ),
                      ),
                      child: _buildDayHeader(context, item),
                    );
                  }
                  final e = item as TxHistoryEntry;
                  final tone = fmt.tone(e);
                  final color = _toneColor(tone);
                  return _TimelineRow(
                    lineColor: lineColor,
                    lineAbove: true,
                    lineBelow: !isLast,
                    markerTop: 8,
                    marker: _Marker(
                      icon: _toneIcon(tone),
                      color: color,
                      ringColor: isDark
                          ? theme.scaffoldBackgroundColor
                          : const Color(0xFFF6F8FC),
                    ),
                    child: _buildEntryCard(context, e, fmt, color),
                  );
                },
              ),
            ),
          if (showOrigin)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
              sliver: SliverToBoxAdapter(
                child: _TimelineRow(
                  lineColor: lineColor,
                  lineAbove: true,
                  lineBelow: false,
                  markerTop: 4,
                  marker: _Marker(
                    icon: Icons.add_rounded,
                    color: cs.onSurfaceVariant,
                    ringColor: isDark
                        ? theme.scaffoldBackgroundColor
                        : const Color(0xFFF6F8FC),
                    size: 28,
                  ),
                  child: _buildOrigin(
                    context,
                    created: created,
                    since: olderThanTracking ? since : null,
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: 28 + MediaQuery.paddingOf(context).bottom),
          ),
        ],
      ),
    );
  }

  // ---------------------------
  // بطاقة الحركة في الأعلى
  // ---------------------------
  Widget _buildHeader(
    BuildContext context, {
    required TransactionModel? tx,
    required bool deleted,
    required List<TxHistoryEntry> entries,
    required DateTime? created,
    required Map<int, String> names,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    if (tx == null) {
      return _softCard(
        context,
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, color: cs.error),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'الحركة غير موجودة (ربما حُذفت)',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }

    final movement = tx.effectiveCompanyMovement;
    final statusText =
        movement?.label ?? TxHistoryFormatter.statusLabel(tx.status.name);
    final statusColor =
        _movementColor(movement) ??
        _statusTagColor(tx.status.name) ??
        cs.primary;
    final account = names[tx.accountId];
    final hasSecond = tx.hasSecondAmount;
    final secondCur = (tx.secondCurrency?.trim().isNotEmpty ?? false)
        ? tx.secondCurrency!.trim()
        : tx.currency;
    final lastAt = entries.isEmpty ? null : entries.first.at;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: isDark
              ? [statusColor.withValues(alpha: .18), cs.surfaceContainerHigh]
              : [
                  Color.alphaBlend(
                    statusColor.withValues(alpha: .10),
                    Colors.white,
                  ),
                  Colors.white,
                ],
        ),
        border: Border.all(color: statusColor.withValues(alpha: .18)),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: const Color(0xFF1E293B).withValues(alpha: .06),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: .14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.history_rounded,
                  color: statusColor,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx.beneficiary.trim().isEmpty ? '—' : tx.beneficiary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: cs.onSurface,
                        height: 1.25,
                      ),
                    ),
                    if (account != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        account,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _Pill(text: statusText, color: statusColor, strong: true),
            ],
          ),
          if (deleted) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.delete_outline_rounded, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'هذه الحركة محذوفة — السجل محفوظ للاطلاع',
                      style: TextStyle(
                        color: cs.error,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(
                icon: Icons.payments_rounded,
                text: '${TxHistoryFormatter.amount(tx.amount)} ${tx.currency}',
              ),
              if (hasSecond)
                _InfoChip(
                  icon: Icons.payments_outlined,
                  text:
                      '${TxHistoryFormatter.amount(tx.secondAmount)} $secondCur',
                ),
              _InfoChip(
                icon: Icons.event_rounded,
                text: TxHistoryFormatter.dateTime(tx.date),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: isDark
                  ? cs.surface.withValues(alpha: .45)
                  : const Color(0xFFF6F8FC),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _Stat(label: 'التعديلات', value: '${entries.length}'),
                ),
                _statDivider(cs),
                Expanded(
                  child: _Stat(
                    label: 'آخر تعديل',
                    value: lastAt == null ? '—' : _ago(lastAt),
                  ),
                ),
                _statDivider(cs),
                Expanded(
                  child: _Stat(
                    label: 'أُضيفت',
                    value: created == null
                        ? '—'
                        : TxHistoryFormatter.day(created),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statDivider(ColorScheme cs) => Container(
    width: 1,
    height: 28,
    color: cs.outlineVariant.withValues(alpha: .6),
  );

  Widget _softCard(BuildContext context, {required Widget child}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? cs.outlineVariant.withValues(alpha: .35)
              : const Color(0xFFE7ECF4),
        ),
      ),
      child: child,
    );
  }

  // ---------------------------
  // شريط التصفية
  // ---------------------------
  Widget _buildFilterBar(BuildContext context, List<TxHistoryEntry> entries) {
    final data = entries.where((e) => e.touchesData).length;
    final status = entries.where((e) => e.touchesStatus).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _filterChip(context, 'الكل', entries.length, _HistoryFilter.all),
            const SizedBox(width: 8),
            _filterChip(context, 'البيانات', data, _HistoryFilter.data),
            const SizedBox(width: 8),
            _filterChip(context, 'الحالة', status, _HistoryFilter.status),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(
    BuildContext context,
    String label,
    int count,
    _HistoryFilter f,
  ) {
    final cs = Theme.of(context).colorScheme;
    final selected = _filter == f;
    final fg = selected ? cs.onPrimary : cs.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _filter = f),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? cs.primary : cs.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? cs.primary
                  : cs.outlineVariant.withValues(alpha: .7),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: fg,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: (selected ? cs.onPrimary : cs.primary).withValues(
                    alpha: .16,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: selected ? cs.onPrimary : cs.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------
  // عناصر الخط الزمني
  // ---------------------------
  Widget _buildDayHeader(BuildContext context, _DayLabel d) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: .7),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${d.text}  •  ${_countLabel(d.count)}',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntryCard(
    BuildContext context,
    TxHistoryEntry e,
    TxHistoryFormatter fmt,
    Color tone,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final rows = fmt.rows(e);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? cs.outlineVariant.withValues(alpha: .35)
              : const Color(0xFFE7ECF4),
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: const Color(0xFF1E293B).withValues(alpha: .05),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    fmt.title(e),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: isDark ? .18 : .10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.schedule_rounded, size: 13, color: tone),
                      const SizedBox(width: 4),
                      Text(
                        TxHistoryFormatter.time(e.at),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: tone,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (e.source != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.touch_app_rounded,
                        size: 13,
                        color: cs.onSecondaryContainer,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          e.source!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: cs.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          for (final r in rows) _buildChangeRow(context, r, tone),
          const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _buildChangeRow(BuildContext context, TxChangeRow r, Color tone) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final muted = cs.onSurfaceVariant;

    Color? fromColor;
    Color? toColor;
    var strike = false;
    switch (r.kind) {
      case TxRowKind.status:
        fromColor = _statusTagColor(r.fromTag);
        toColor = _statusTagColor(r.toTag);
        break;
      case TxRowKind.movement:
        fromColor = _movementColor(TxHistoryFormatter.movementOf(r.fromTag));
        toColor = _movementColor(TxHistoryFormatter.movementOf(r.toTag));
        break;
      case TxRowKind.account:
        toColor = const Color(0xFF7C3AED);
        break;
      default:
        strike = true;
        fromColor = const Color(0xFFE11D48);
        toColor = const Color(0xFF059669);
    }
    fromColor ??= muted;
    toColor ??= cs.primary;

    final hasValues = r.from != null || r.to != null;
    final short = (r.from?.length ?? 0) <= 26 && (r.to?.length ?? 0) <= 26;

    Widget values;
    if (!hasValues) {
      values = const SizedBox.shrink();
    } else if (short) {
      values = Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _Pill(text: r.from ?? '—', color: fromColor, strike: strike),
          Icon(Icons.arrow_forward_rounded, size: 16, color: muted),
          _Pill(text: r.to ?? '—', color: toColor, strong: true),
        ],
      );
    } else {
      values = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LabeledValue(
            label: 'من',
            text: r.from ?? '—',
            color: fromColor,
            strike: strike,
          ),
          const SizedBox(height: 6),
          _LabeledValue(
            label: 'إلى',
            text: r.to ?? '—',
            color: toColor,
            strong: true,
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: isDark
            ? cs.surfaceContainerHighest.withValues(alpha: .45)
            : const Color(0xFFF6F8FC),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_rowIcon(r.kind), size: 16, color: tone),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  r.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (hasValues) ...[const SizedBox(height: 8), values],
          if (r.extra != null) ...[
            SizedBox(height: hasValues ? 8 : 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: muted,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    r.extra!,
                    style: TextStyle(fontSize: 12, color: muted, height: 1.3),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOrigin(
    BuildContext context, {
    required DateTime? created,
    required DateTime? since,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'إضافة الحركة',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            created == null
                ? 'وقت الإضافة غير معروف'
                : TxHistoryFormatter.dateTime(created),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          if (since != null) ...[
            const SizedBox(height: 6),
            Text(
              'بدأ حفظ سجل التعديلات في ${TxHistoryFormatter.day(since)}؛ '
              'التعديلات الأقدم غير مسجلة.',
              style: TextStyle(
                fontSize: 11.5,
                color: cs.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmpty(
    BuildContext context, {
    required bool filtered,
    required DateTime? since,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: .08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              filtered
                  ? Icons.filter_alt_off_rounded
                  : Icons.history_toggle_off_rounded,
              size: 40,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            filtered ? 'لا توجد تعديلات من هذا النوع' : 'لا توجد تعديلات بعد',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            filtered
                ? 'جرّب تصفية أخرى لعرض باقي التعديلات.'
                : 'أي تعديل على هذه الحركة — المبلغ، الاسم، العملة، الحالة، '
                      'النقل بين الحسابات — سيُحفظ هنا تلقائيًا مع التاريخ '
                      'والوقت.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (!filtered && since != null) ...[
            const SizedBox(height: 8),
            Text(
              'بدأ حفظ السجل في ${TxHistoryFormatter.day(since)}.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================
// عناصر مساعدة
// =============================================================

/// صف في الخط الزمني: عمود الخط والعلامة، ثم المحتوى
class _TimelineRow extends StatelessWidget {
  final Widget marker;
  final Widget child;
  final bool lineAbove;
  final bool lineBelow;
  final double markerTop;
  final Color lineColor;

  const _TimelineRow({
    required this.marker,
    required this.child,
    required this.lineAbove,
    required this.lineBelow,
    required this.markerTop,
    required this.lineColor,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 44,
            child: Column(
              children: [
                Container(
                  width: 2,
                  height: markerTop,
                  color: lineAbove ? lineColor : Colors.transparent,
                ),
                marker,
                Expanded(
                  child: Container(
                    width: 2,
                    color: lineBelow ? lineColor : Colors.transparent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Marker extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color ringColor;
  final double size;

  const _Marker({
    required this.icon,
    required this.color,
    required this.ringColor,
    this.size = 34,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color.alphaBlend(color.withValues(alpha: .16), ringColor),
        border: Border.all(color: ringColor, width: 3),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: .18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, size: size * .5, color: color),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final bool strong;
  final bool strike;

  const _Pill({
    required this.text,
    required this.color,
    this.strong = false,
    this.strike = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? .18 : .10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
          color: strike ? color.withValues(alpha: .85) : color,
          decoration: strike ? TextDecoration.lineThrough : null,
          decorationColor: color.withValues(alpha: .7),
        ),
      ),
    );
  }
}

class _LabeledValue extends StatelessWidget {
  final String label;
  final String text;
  final Color color;
  final bool strong;
  final bool strike;

  const _LabeledValue({
    required this.label,
    required this.text,
    required this.color,
    this.strong = false,
    this.strike = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? .14 : .07),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 30,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                color: cs.onSurface.withValues(alpha: strike ? .7 : 1),
                decoration: strike ? TextDecoration.lineThrough : null,
                decorationColor: color.withValues(alpha: .7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? cs.surface.withValues(alpha: .5)
            : Colors.white.withValues(alpha: .85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;

  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}
