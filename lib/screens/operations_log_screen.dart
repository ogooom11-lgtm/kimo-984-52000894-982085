// lib/screens/operations_log_screen.dart
// صفحة سجل العمليات: عرض كل العمليات المنفذة مع إمكانية التراجع عن أي عملية،
// وفتح الحساب مع تحديد حركات العملية فيه.

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/operation_log_service.dart';
import '../utils/chunked_task.dart';
import '../widgets/operation_progress_bar.dart';
import 'account_screen.dart';

enum _LogFilter { all, adds, cancels, edits, undone }

class OperationsLogScreen extends StatefulWidget {
  const OperationsLogScreen({super.key});

  @override
  State<OperationsLogScreen> createState() => _OperationsLogScreenState();
}

class _OperationsLogScreenState extends State<OperationsLogScreen> {
  _LogFilter _filter = _LogFilter.all;
  final ValueNotifier<OperationProgress?> _progress =
      ValueNotifier<OperationProgress?>(null);
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text.trim();
      if (q != _query) setState(() => _query = q);
    });
  }

  @override
  void dispose() {
    _progress.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ---------------- أدوات ----------------

  void _setProgress(OperationProgress? p) {
    if (mounted) _progress.value = p;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  String _fmtTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  String _fmtDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return 'اليوم';
    if (day == today.subtract(const Duration(days: 1))) return 'أمس';
    return _fmtDate(d);
  }

  String _fmtAmount(double v) {
    final isInt = v == v.roundToDouble();
    final fixed = isInt ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    final parts = fixed.split('.');
    final intPart = parts.first;
    final buf = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      final fromEnd = intPart.length - i;
      buf.write(intPart[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1 && intPart[i] != '-') buf.write(',');
    }
    return parts.length > 1 ? '$buf.${parts[1]}' : buf.toString();
  }

  Color _kindColor(OperationKind k) {
    switch (k) {
      case OperationKind.bubbleAdd:
      case OperationKind.manualAdd:
        return const Color(0xFF43A047);
      case OperationKind.bubbleCancel:
        return const Color(0xFFE53935);
      case OperationKind.statusChange:
        return const Color(0xFF1E88E5);
      case OperationKind.move:
        return const Color(0xFF8E24AA);
      case OperationKind.delete:
        return const Color(0xFF6D4C41);
      case OperationKind.manualEdit:
      case OperationKind.bubbleEdit:
        return const Color(0xFFF08006);
    }
  }

  IconData _kindIcon(OperationKind k) {
    switch (k) {
      case OperationKind.bubbleAdd:
        return Icons.add_task_rounded;
      case OperationKind.manualAdd:
        return Icons.add_circle_rounded;
      case OperationKind.bubbleCancel:
        return Icons.cancel_schedule_send_rounded;
      case OperationKind.statusChange:
        return Icons.published_with_changes_rounded;
      case OperationKind.move:
        return Icons.drive_file_move_rounded;
      case OperationKind.delete:
        return Icons.delete_sweep_rounded;
      case OperationKind.manualEdit:
        return Icons.edit_note_rounded;
      case OperationKind.bubbleEdit:
        return Icons.mark_chat_read_rounded;
    }
  }

  String _snapshotStatus(Map<String, dynamic>? m) {
    if (m == null) return '-';
    final movement = m['companyMovementType'];
    if (movement != null) {
      for (final t in CompanyMovementType.values) {
        if (t.name == movement) return t.label;
      }
    }
    switch (m['status']) {
      case 'received':
        return 'مستلمة';
      case 'cancelled':
        return 'ملغية';
      default:
        return 'مضافة';
    }
  }

  bool _matchesFilter(OperationLogEntry e) {
    switch (_filter) {
      case _LogFilter.all:
        return true;
      case _LogFilter.adds:
        return e.kind.createsTransactions;
      case _LogFilter.cancels:
        return e.kind == OperationKind.bubbleCancel ||
            (e.kind == OperationKind.statusChange &&
                e.records.any(
                  (r) =>
                      r.after?['status'] == 'cancelled' ||
                      (r.after?['companyMovementType']?.toString() ?? '')
                          .endsWith('Cancelled'),
                ));
      case _LogFilter.edits:
        return e.kind == OperationKind.statusChange ||
            e.kind == OperationKind.move ||
            e.kind == OperationKind.delete ||
            e.kind == OperationKind.manualEdit ||
            e.kind == OperationKind.bubbleEdit;
      case _LogFilter.undone:
        return e.undone;
    }
  }

  bool _matchesQuery(OperationLogEntry e) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    final blob = [
      e.title,
      e.subtitle ?? '',
      e.kind.label,
      ...e.records.map((r) => '${r.beneficiary} ${r.amount} ${r.currency}'),
    ].join(' ').toLowerCase();
    return blob.contains(q);
  }

  // ---------------- الإجراءات ----------------

  Future<void> _openInAccount(OperationLogEntry e) async {
    final current = OperationLogService.currentTransactions(e);
    if (current.isEmpty) {
      _snack('حركات هذه العملية لم تعد موجودة (ربما تم التراجع عنها أو حذفها)');
      return;
    }

    final byAccount = <int, List<TransactionModel>>{};
    for (final t in current) {
      (byAccount[t.accountId] ??= []).add(t);
    }
    final accounts = <int, Account>{
      for (final a in DatabaseService.accountsBox.values) a.id: a,
    };

    int? accountId;
    if (byAccount.length == 1) {
      accountId = byAccount.keys.first;
    } else {
      accountId = await showDialog<int>(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: SimpleDialog(
            title: const Text('الحركات موزعة على عدة حسابات'),
            children: byAccount.entries
                .map(
                  (entry) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, entry.key),
                    child: Row(
                      children: [
                        const Icon(Icons.account_balance_wallet_rounded),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            accounts[entry.key]?.name ?? 'حساب #${entry.key}',
                          ),
                        ),
                        Text('${entry.value.length} حركة'),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      );
    }
    if (accountId == null || !mounted) return;

    final account = accounts[accountId];
    if (account == null) {
      _snack('الحساب لم يعد موجودًا');
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountScreen(
          account: account,
          initialSelectedTxIds: byAccount[accountId]!.map((t) => t.id).toSet(),
          selectionTitle: e.title,
        ),
      ),
    );
  }

  Future<void> _undo(OperationLogEntry e) async {
    if (_busy || e.undone) return;
    final preview = OperationLogService.previewUndo(e);
    if (preview.applicable <= 0) {
      _snack(
        e.kind == OperationKind.delete
            ? 'كل الحركات المحذوفة موجودة حاليًا، لا يوجد ما يُستعاد'
            : 'حركات هذه العملية لم تعد موجودة',
      );
      return;
    }

    final lines = <String>[
      if (e.kind.createsTransactions)
        'سيتم حذف ${preview.applicable} حركة أضيفت في هذه العملية.'
      else if (e.kind == OperationKind.delete)
        'سيتم استعادة ${preview.applicable} حركة محذوفة.'
      else
        'سيتم إرجاع ${preview.applicable} حركة إلى حالتها قبل العملية.',
      if (preview.missing > 0)
        e.kind == OperationKind.delete
            ? '${preview.missing} حركة موجودة أصلًا ولن تُستعاد.'
            : '${preview.missing} حركة لم تعد موجودة وسيتم تجاهلها.',
      if (preview.changed > 0)
        '⚠️ ${preview.changed} حركة تغيّرت بعد هذه العملية (مثل تسليم أو تعديل)، وسيُلغى هذا التغيير أيضًا.',
    ];

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              icon: const Icon(Icons.undo_rounded, size: 34),
              title: const Text('تأكيد التراجع'),
              content: Text('${e.title}\n\n${lines.join('\n')}'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.undo_rounded),
                  label: const Text('تراجع'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    int affected = 0;
    try {
      affected = await OperationLogService.undo(
        e,
        onProgress: (done, total) => _setProgress(
          OperationProgress(
            label: 'جارٍ التراجع عن العملية...',
            done: done,
            total: total,
          ),
        ),
      );
    } catch (err) {
      _snack('تعذر التراجع: $err');
    } finally {
      _setProgress(null);
      if (mounted) setState(() => _busy = false);
    }
    _snack('تم التراجع عن العملية ($affected حركة)');
  }

  Future<void> _deleteEntry(OperationLogEntry e) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('حذف من السجل'),
              content: const Text(
                'سيتم حذف هذه العملية من السجل فقط (الحركات نفسها لن تتأثر)، ولن يمكن التراجع عنها بعد ذلك.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('حذف'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (ok) await OperationLogService.deleteEntry(e.id);
  }

  Future<void> _clearAll() async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('مسح السجل بالكامل'),
              content: const Text(
                'سيتم حذف كل العمليات من السجل (الحركات نفسها لن تتأثر). هل تريد المتابعة؟',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('مسح الكل'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (ok) await OperationLogService.clear();
  }

  void _showDetails(OperationLogEntry e) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final accounts = <int, String>{
          for (final a in DatabaseService.accountsBox.values) a.id: a.name,
        };
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * .8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      e.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: e.records.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final r = e.records[i];
                        final before = _snapshotStatus(r.before);
                        final after = _snapshotStatus(r.after);
                        final moved =
                            r.beforeAccountId != null &&
                            r.after != null &&
                            r.beforeAccountId != r.accountId;
                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest.withValues(
                              alpha: .55,
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.beneficiary.isEmpty
                                    ? 'بدون اسم'
                                    : r.beneficiary,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${_fmtAmount(r.amount)} ${r.currency} • ${accounts[r.accountId] ?? 'حساب #${r.accountId}'}',
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                              if (r.before != null &&
                                  r.after != null &&
                                  before != after) ...[
                                const SizedBox(height: 3),
                                Text(
                                  '$before ← $after',
                                  style: TextStyle(
                                    color: cs.primary,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                              if (moved)
                                Text(
                                  'من ${accounts[r.beforeAccountId] ?? 'حساب #${r.beforeAccountId}'} إلى ${accounts[r.accountId] ?? 'حساب #${r.accountId}'}',
                                  style: TextStyle(
                                    color: cs.primary,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------- الواجهة ----------------

  Widget _filterChip(_LogFilter f, String label, IconData icon) {
    final selected = _filter == f;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        selected: selected,
        avatar: Icon(icon, size: 17),
        label: Text(label),
        onSelected: (_) => setState(() => _filter = f),
      ),
    );
  }

  Widget _entryCard(OperationLogEntry e) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = _kindColor(e.kind);
    final readable = Color.lerp(
      color,
      dark ? Colors.white : Colors.black,
      dark ? .28 : .2,
    )!;
    final names = e.records
        .map((r) => r.beneficiary)
        .where((n) => n.trim().isNotEmpty)
        .toSet()
        .toList();
    final totals = e.totalsByCurrency;

    return Opacity(
      opacity: e.undone ? .62 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: dark ? cs.surfaceContainer : cs.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: .30)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .2 : .05),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openInAccount(e),
          onLongPress: () => _showDetails(e),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .13),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(_kindIcon(e.kind), color: color),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14.5,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              e.kind.label,
                              _fmtTime(e.createdAt),
                              if ((e.subtitle ?? '').isNotEmpty) e.subtitle!,
                            ].join(' • '),
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (e.undone)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'تم التراجع${e.undoneAt == null ? '' : ' ${_fmtTime(e.undoneAt!)}'}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                  ],
                ),
                if (names.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    names.take(4).join('، ') +
                        (names.length > 4 ? ' و${names.length - 4} آخرين' : ''),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
                if (totals.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: totals.entries
                        .map(
                          (t) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${_fmtAmount(t.value)} ${t.key}',
                              style: TextStyle(
                                color: readable,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 4),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: () => _openInAccount(e),
                      icon: const Icon(Icons.checklist_rounded, size: 18),
                      label: Text('تحديد في الحساب (${e.records.length})'),
                    ),
                    TextButton.icon(
                      onPressed: () => _showDetails(e),
                      icon: const Icon(Icons.list_alt_rounded, size: 18),
                      label: const Text('التفاصيل'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: e.undone || _busy ? null : () => _undo(e),
                      icon: const Icon(Icons.undo_rounded, size: 18),
                      label: Text(e.undone ? 'متراجع عنها' : 'تراجع'),
                    ),
                    IconButton(
                      tooltip: 'حذف من السجل',
                      onPressed: _busy ? null : () => _deleteEntry(e),
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: cs.onSurfaceVariant,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<OperationLogEntry> entries) {
    final cs = Theme.of(context).colorScheme;
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.history_toggle_off_rounded,
                size: 56,
                color: cs.onSurfaceVariant.withValues(alpha: .6),
              ),
              const SizedBox(height: 12),
              Text(
                _query.isEmpty && _filter == _LogFilter.all
                    ? 'لا توجد عمليات مسجلة بعد.\nكل إضافة أو إلغاء أو تعديل جماعي سيظهر هنا ويمكن التراجع عنه.'
                    : 'لا توجد نتائج لهذا الفلتر أو البحث.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final children = <Widget>[];
    String? lastDay;
    for (final e in entries) {
      final day = _dayLabel(e.createdAt);
      if (day != lastDay) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
            child: Text(
              day,
              style: TextStyle(fontWeight: FontWeight.w900, color: cs.primary),
            ),
          ),
        );
        lastDay = day;
      }
      children.add(_entryCard(e));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: children,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('سجل العمليات'),
          centerTitle: true,
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'clear') _clearAll();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'clear',
                  child: Row(
                    children: [
                      Icon(Icons.delete_forever_rounded, color: Colors.red),
                      SizedBox(width: 10),
                      Text('مسح السجل بالكامل'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: OperationProgressBar(
            progress: _progress,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          ),
        ),
        body: !OperationLogService.isReady
            ? const Center(child: Text('السجل غير متاح حاليًا'))
            : ValueListenableBuilder<Box<dynamic>>(
                valueListenable: OperationLogService.listenable(),
                builder: (context, box, _) {
                  final all = OperationLogService.entries();
                  final filtered = all
                      .where(_matchesFilter)
                      .where(_matchesQuery)
                      .toList();
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: InputDecoration(
                            hintText: 'ابحث بالاسم أو الحساب أو المبلغ...',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    onPressed: _searchCtrl.clear,
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                            filled: true,
                            fillColor: cs.surfaceContainerHighest,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 48,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          children: [
                            _filterChip(
                              _LogFilter.all,
                              'الكل (${all.length})',
                              Icons.all_inclusive_rounded,
                            ),
                            _filterChip(
                              _LogFilter.adds,
                              'إضافات',
                              Icons.add_task_rounded,
                            ),
                            _filterChip(
                              _LogFilter.cancels,
                              'إلغاءات',
                              Icons.cancel_rounded,
                            ),
                            _filterChip(
                              _LogFilter.edits,
                              'تعديلات',
                              Icons.published_with_changes_rounded,
                            ),
                            _filterChip(
                              _LogFilter.undone,
                              'متراجع عنها',
                              Icons.undo_rounded,
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: _buildList(filtered)),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
