import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/tx_undo.dart';
import '../widgets/app_messages.dart';
import 'add_edit_transaction_screen.dart';
import 'share_image_page.dart';

enum SortField { date, name, status, amount }

/// رسالة قصيرة مكان الرسالة الحالية
void _say(ScaffoldMessengerState messenger, String text) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// الحقول يلي بتنسخ: الاسم، المبلغ 1 والمبلغ 2 (مع العملات)، والتاريخ
class _CopyFields {
  bool name = true;
  bool amount1 = true;
  bool amount2 = true;
  bool day = true;

  bool get hasAny => name || amount1 || amount2 || day;
}

class AccountScreen extends StatefulWidget {
  final Account account;

  const AccountScreen({super.key, required this.account});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  SortField _sortField = SortField.date;
  bool _ascending = false; // الأحدث أولًا
  final _expanded = <TransactionStatus, bool>{
    TransactionStatus.received: false,
    TransactionStatus.cancelled: false,
    TransactionStatus.added: true,
  };
  final _companyExpanded = <CompanyMovementType, bool>{
    CompanyMovementType.received: true,
    CompanyMovementType.sent: true,
    CompanyMovementType.receivedCancelled: false,
    CompanyMovementType.sentCancelled: false,
  };

  bool get _isCompanyAccount => widget.account.type.isCompany;

  String _movementLabel(TransactionModel tx) =>
      _isCompanyAccount && tx.effectiveCompanyMovement != null
      ? tx.effectiveCompanyMovement!.label
      : _statusLabel(tx.status);

  Color _companyMovementColor(CompanyMovementType type) {
    switch (type) {
      case CompanyMovementType.received:
        return const Color(0xFF00897B);
      case CompanyMovementType.sent:
        return const Color(0xFF5E35B1);
      case CompanyMovementType.receivedCancelled:
        return const Color(0xFFD84315);
      case CompanyMovementType.sentCancelled:
        return const Color(0xFFEF6C00);
    }
  }

  IconData _companyMovementIcon(CompanyMovementType type) {
    switch (type) {
      case CompanyMovementType.received:
        return Icons.call_received_rounded;
      case CompanyMovementType.sent:
        return Icons.call_made_rounded;
      case CompanyMovementType.receivedCancelled:
      case CompanyMovementType.sentCancelled:
        return Icons.cancel_rounded;
    }
  }

  // 🔹 اليوم/التاريخ المحدد لتصفية الحركات
  DateTime _selectedDay = DateTime.now();

  // بحث
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  final FocusNode _searchFocus = FocusNode();
  bool _searchFocused = false;
  final Set<int> _selectedTxIds = {};

  bool get _selectionMode => _selectedTxIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim());
    });
    _searchFocus.addListener(() {
      setState(() => _searchFocused = _searchFocus.hasFocus);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool _matchesQuery(TransactionModel t) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();

    final fields = <String>[
      t.beneficiary,
      t.currency,
      _movementLabel(t),
      _formatDayLabel(t.date),
      _formatRelativeOrExactTime(t.date),
      t.amount.toString(),
      if (t.hasSecondAmount) t.secondAmount!.toString(),
      t.totalAmount.toString(),
      _formatTransactionAmounts(t),
      _formatTransactionTotal(t),
      if (_statusStamp(t) != null) _formatExactDateTime(_statusStamp(t)!),
    ].join(' ').toLowerCase();

    return fields.contains(q);
  }

  void _clearSelection() {
    setState(() => _selectedTxIds.clear());
  }

  void _toggleTransactionSelection(TransactionModel tx) {
    setState(() {
      if (_selectedTxIds.contains(tx.id)) {
        _selectedTxIds.remove(tx.id);
      } else {
        _selectedTxIds.add(tx.id);
      }
    });
  }

  bool _isSelected(TransactionModel tx) => _selectedTxIds.contains(tx.id);

  List<TransactionModel> _selectedTransactions() {
    return DatabaseService.transactionsBox.values
        .where((tx) => _selectedTxIds.contains(tx.id))
        .toList();
  }

  Future<bool> _confirmBulkAction(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('تأكيد'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<Account?> _pickTargetAccount({required int excludeAccountId}) async {
    final accounts =
        DatabaseService.accountsBox.values
            .where(
              (account) =>
                  account.id != excludeAccountId &&
                  account.type == widget.account.type,
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    if (accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد حساب آخر للنقل إليه')),
      );
      return null;
    }

    return showDialog<Account>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SimpleDialog(
          title: const Text('اختر الحساب الهدف'),
          children: accounts
              .map(
                (account) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, account),
                  child: Text(account.name),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Future<void> _moveTransactions(List<TransactionModel> items) async {
    if (items.isEmpty) return;
    final target = await _pickTargetAccount(
      excludeAccountId: widget.account.id,
    );
    if (target == null) return;

    final ok = await _confirmBulkAction(
      'تأكيد النقل',
      'سيتم نقل ${items.length} حركة إلى حساب "${target.name}".',
    );
    if (!ok) return;

    for (final tx in items) {
      tx.accountId = target.id;
      await tx.save();
    }

    if (!mounted) return;
    _clearSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم نقل ${items.length} حركة إلى ${target.name}')),
    );
  }

  Future<void> _setTransactionsStatus(
    List<TransactionModel> items,
    TransactionStatus status,
  ) async {
    if (items.isEmpty) return;
    final label = _statusLabel(status);
    final ok = await _confirmBulkAction(
      'تأكيد تغيير الحالة',
      'سيتم تحويل ${items.length} حركة إلى "$label".',
    );
    if (!ok) return;

    final now = DateTime.now();
    // حالة الحركات قبل التسليم، للتراجع
    final delivered = <(TransactionModel, TxStatusSnapshot)>[];
    for (final tx in items) {
      final movement = tx.companyMovementType;
      if (_isCompanyAccount && movement != null) {
        // حركات الشركات: الإلغاء جزء من نوع الحركة (مثل الإلغاء الفردي)،
        // حتى تُحسب في الإحصائيات بتاريخ إلغائها.
        final base = movement.isSent
            ? CompanyMovementType.sent
            : CompanyMovementType.received;
        if (status == TransactionStatus.cancelled) {
          if (!(tx.effectiveCompanyMovement?.isCancelled ?? false) ||
              tx.cancelledAt == null) {
            tx.cancelledAt = now;
          }
          tx.companyMovementType = base.cancelled;
        } else if (status == TransactionStatus.added) {
          tx.companyMovementType = base;
          tx.cancelledAt = null;
        }
        tx.status = TransactionStatus.added;
        tx.receivedAt = null;
      } else {
        if (status == TransactionStatus.received) {
          delivered.add((tx, TxStatusSnapshot.of(tx)));
        }
        tx.applyStatus(status, at: now);
      }
      await tx.save();
    }

    if (!mounted) return;
    _clearSelection();
    final messenger = ScaffoldMessenger.of(context);
    if (delivered.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text('تم تحديث ${items.length} حركة')),
      );
      return;
    }
    AppMessages.showWithUndo(
      messenger,
      'تم تسليم ${delivered.length} حركة',
      () async {
        for (final (tx, before) in delivered) {
          await TxUndo.restoreStatus(tx, before);
        }
        _say(messenger, 'تم التراجع عن التسليم');
      },
    );
  }

  Future<void> _deleteTransactions(List<TransactionModel> items) async {
    if (items.isEmpty) return;
    final ok = await _confirmBulkAction(
      'تأكيد الحذف',
      'سيتم حذف ${items.length} حركة نهائيًا. هل تريد المتابعة؟',
    );
    if (!ok) return;

    for (final tx in items) {
      await tx.delete();
    }

    if (!mounted) return;
    _clearSelection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('تم حذف ${items.length} حركة')));
  }

  Future<void> _moveOneTransaction(TransactionModel tx) async {
    await _moveTransactions([tx]);
  }

  // 🔹 مقارنة يومين بدون مراعاة الساعة
  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  // 🔹 تصفية الحركات حسب اليوم المحدد
  // - كل "مضافة" تظهر دائمًا
  // - غير ذلك: فقط الحركات التي تاريخها = _selectedDay
  List<TransactionModel> _filterBySelectedDay(List<TransactionModel> all) {
    return all.where((t) {
      if (_isCompanyAccount) {
        final shownAt = t.effectiveCompanyMovement?.isCancelled == true
            ? (t.cancelledAt ?? t.date)
            : t.date;
        return _isSameDay(shownAt, _selectedDay);
      }
      if (t.status == TransactionStatus.added) return true;

      if (t.status == TransactionStatus.received && t.receivedAt != null) {
        return _isSameDay(t.receivedAt!, _selectedDay);
      }

      if (t.status == TransactionStatus.cancelled && t.cancelledAt != null) {
        return _isSameDay(t.cancelledAt!, _selectedDay);
      }

      return _isSameDay(t.date, _selectedDay);
    }).toList();
  }

  // تنسيقات التاريخ والوقت
  String _formatDayLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(dt.year, dt.month, dt.day);
    if (d == today) return "اليوم";
    if (d == today.subtract(const Duration(days: 1))) return "أمس";
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return "${dt.year}-$mm-$dd";
  }

  String _formatRelativeOrExactTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inHours >= 1) {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return "$hh:$mm";
    }
    if (diff.inSeconds < 10) return "الآن";
    if (diff.inMinutes < 1) return "الآن";
    if (diff.inMinutes == 1) return "قبل دقيقة";
    return "قبل ${diff.inMinutes} د";
  }

  String _formatAmount(double v) {
    // تنسيق موحد للعرض + النسخ + التصدير:
    // 1250000.00 => 1.250.000
    // 1250000.50 => 1.250.000,5
    final isNegative = v < 0;
    final abs = v.abs();
    final fixed = abs.toStringAsFixed(2);
    final parts = fixed.split('.');
    final intPart = parts.first;
    final decimals = parts.length > 1
        ? parts[1].replaceFirst(RegExp(r'0+$'), '')
        : '';

    final buf = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      final reversedIndex = intPart.length - 1 - i;
      buf.write(intPart[reversedIndex]);
      if (i % 3 == 2 && reversedIndex != 0) buf.write('.');
    }

    final separated = buf.toString().split('').reversed.join();
    final sign = isNegative ? '-' : '';
    return decimals.isEmpty ? '$sign$separated' : '$sign$separated,$decimals';
  }

  String _formatTransactionAmounts(TransactionModel t) {
    if (t.hasSecondAmount) {
      return '${_formatAmount(t.amount)} ${t.currency}'
          ' | '
          '${_formatAmount(t.secondAmount!)} ${t.secondCurrency ?? t.currency}';
    }
    return '${_formatAmount(t.amount)} ${t.currency}';
  }

  String _formatTransactionTotal(TransactionModel t) {
    return '${_formatAmount(t.totalAmount)} ${t.currency}';
  }

  DateTime? _statusStamp(TransactionModel t) {
    switch (t.status) {
      case TransactionStatus.received:
        return t.receivedAt;
      case TransactionStatus.cancelled:
        return t.cancelledAt;
      case TransactionStatus.added:
        return null;
    }
  }

  String _formatExactDateTime(DateTime dt) {
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$mm-$dd $hh:$mi';
  }

  // فرز
  List<TransactionModel> _applySort(Iterable<TransactionModel> list) {
    final l = list.toList();
    int cmp(TransactionModel a, TransactionModel b) {
      int r = 0;
      switch (_sortField) {
        case SortField.date:
          r = a.date.compareTo(b.date);
          break;
        case SortField.name:
          r = a.beneficiary.toLowerCase().compareTo(
            b.beneficiary.toLowerCase(),
          );
          break;
        case SortField.status:
          r = a.status.index.compareTo(b.status.index);
          break;
        case SortField.amount:
          r = a.totalAmount.compareTo(b.totalAmount);
          break;
      }
      return _ascending ? r : -r;
    }

    l.sort(cmp);
    return l;
  }

  Future<void> _showSortSheet() async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        SortField tempField = _sortField;
        bool tempAsc = _ascending;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (ctx, setS) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(
                    leading: Icon(Icons.sort_rounded),
                    title: Text("الفرز"),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<SortField>(
                    value: tempField,
                    items: const [
                      DropdownMenuItem(
                        value: SortField.date,
                        child: Text("التاريخ / الوقت"),
                      ),
                      DropdownMenuItem(
                        value: SortField.name,
                        child: Text("الاسم"),
                      ),
                      DropdownMenuItem(
                        value: SortField.status,
                        child: Text("الحالة"),
                      ),
                      DropdownMenuItem(
                        value: SortField.amount,
                        child: Text("المبلغ"),
                      ),
                    ],
                    onChanged: (v) => setS(() => tempField = v ?? tempField),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: "فرز حسب",
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: Text(tempAsc ? "تصاعدي" : "تنازلي")),
                      IconButton.filledTonal(
                        onPressed: () => setS(() => tempAsc = !tempAsc),
                        icon: Icon(
                          tempAsc
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() {
                              _sortField = tempField;
                              _ascending = tempAsc;
                            });
                          },
                          icon: const Icon(Icons.check_rounded),
                          label: const Text("تطبيق"),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text("إلغاء"),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _copyDate(DateTime dt) {
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$mm-$dd';
  }

  String _copyMoney(double amount, String currency) =>
      '${_formatAmount(amount)} ${currency.trim()}'.trim();

  String _buildCopyLine(TransactionModel t, _CopyFields fields) {
    final parts = <String>[
      if (fields.name) t.beneficiary.trim(),
      if (fields.amount1 && (t.amount != 0 || !t.hasSecondAmount))
        _copyMoney(t.amount, t.currency),
      if (fields.amount2 && t.hasSecondAmount)
        _copyMoney(t.secondAmount!, t.secondCurrency ?? t.currency),
      if (fields.day) _copyDate(t.date),
    ];
    return parts.where((v) => v.isNotEmpty).join(' | ');
  }

  String _buildCopyText(List<TransactionModel> items, _CopyFields fields) {
    return items.map((t) => _buildCopyLine(t, fields)).join('\n');
  }

  Widget _fieldChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
    );
  }

  // نسخ / تصدير قسم كامل
  Future<void> _showCopyOptionsForSection({
    required String sectionTitle,
    required List<TransactionModel> items,
  }) => _showCopySheet(title: 'نسخ — $sectionTitle', items: items);

  // نسخ عنصر واحد
  Future<void> _showCopyOptionsForItem(TransactionModel t) =>
      _showCopySheet(title: 'نسخ', items: [t]);

  /// نسخ فقط: الاسم، المبلغ 1، المبلغ 2 (مع العملات) والتاريخ
  Future<void> _showCopySheet({
    required String title,
    required List<TransactionModel> items,
  }) async {
    final fields = _CopyFields();

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 4,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: StatefulBuilder(
              builder: (ctx, setSheet) {
                final preview = _buildCopyText(items.take(5).toList(), fields);

                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _fieldChip(
                            label: 'الاسم',
                            selected: fields.name,
                            onSelected: (v) => setSheet(() => fields.name = v),
                          ),
                          _fieldChip(
                            label: 'المبلغ 1',
                            selected: fields.amount1,
                            onSelected: (v) =>
                                setSheet(() => fields.amount1 = v),
                          ),
                          _fieldChip(
                            label: 'المبلغ 2',
                            selected: fields.amount2,
                            onSelected: (v) =>
                                setSheet(() => fields.amount2 = v),
                          ),
                          _fieldChip(
                            label: 'التاريخ',
                            selected: fields.day,
                            onSelected: (v) => setSheet(() => fields.day = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: SingleChildScrollView(
                          child: Text(
                            preview,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: !fields.hasAny
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(
                                    text: _buildCopyText(items, fields),
                                  ),
                                );
                                if (!ctx.mounted) return;
                                Navigator.pop(ctx);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('تم النسخ')),
                                );
                              },
                        icon: const Icon(Icons.content_copy_rounded),
                        label: const Text('نسخ'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  // مساعدات الحالة
  String _statusLabel(TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return "مضافة";
      case TransactionStatus.received:
        return "مستلمة";
      case TransactionStatus.cancelled:
        return "ملغية";
    }
  }

  IconData _statusIcon(TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return Icons.add_circle_rounded;
      case TransactionStatus.received:
        return Icons.verified_rounded;
      case TransactionStatus.cancelled:
        return Icons.cancel_rounded;
    }
  }

  Color _statusColor(TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return Colors.blue;
      case TransactionStatus.received:
        return Colors.green;
      case TransactionStatus.cancelled:
        return Colors.red;
    }
  }

  List<Widget> _buildCompanySections({
    required List<TransactionModel> received,
    required List<TransactionModel> sent,
    required List<TransactionModel> receivedCancelled,
    required List<TransactionModel> sentCancelled,
  }) {
    return [
      _buildCompanySection(CompanyMovementType.received, received),
      _buildCompanySection(CompanyMovementType.sent, sent),
      _buildCompanySection(
        CompanyMovementType.receivedCancelled,
        receivedCancelled,
      ),
      _buildCompanySection(CompanyMovementType.sentCancelled, sentCancelled),
    ].whereType<Widget>().toList();
  }

  Widget _buildCompanySection(
    CompanyMovementType type,
    List<TransactionModel> items,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();
    return _StatusSection(
      title: type.label,
      color: _companyMovementColor(type),
      icon: _companyMovementIcon(type),
      items: items,
      account: widget.account,
      accountName: widget.account.name,
      expanded: _companyExpanded[type] ?? true,
      onToggleExpand: () => setState(() {
        _companyExpanded[type] = !(_companyExpanded[type] ?? true);
      }),
      onCopyRequested: () =>
          _showCopyOptionsForSection(sectionTitle: type.label, items: items),
      onCopyItemRequested: _showCopyOptionsForItem,
      formatDay: _formatDayLabel,
      formatSmartTime: _formatRelativeOrExactTime,
      formatAmount: _formatAmount,
      statusLabel: _movementLabel,
      selectionMode: _selectionMode,
      isSelected: _isSelected,
      onToggleSelected: _toggleTransactionSelection,
      onStartSelection: _toggleTransactionSelection,
      onMoveRequested: _moveOneTransaction,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: DatabaseService.transactionsBox.listenable(),
      builder: (context, Box<TransactionModel> box, _) {
        final allRaw = box.values
            .where((t) => t.accountId == widget.account.id)
            .toList();

        // 🔹 أولاً: نفلتر حسب اليوم + نبقي "مضافة" دائماً
        final filteredByDay = _filterBySelectedDay(allRaw);

        // 🔹 بعدها نطبق البحث
        final all = filteredByDay.where(_matchesQuery).toList();

        final received = _applySort(
          all.where(
            (t) => _isCompanyAccount
                ? t.effectiveCompanyMovement == CompanyMovementType.received
                : t.status == TransactionStatus.received,
          ),
        );
        final sent = _applySort(
          all.where(
            (t) => t.effectiveCompanyMovement == CompanyMovementType.sent,
          ),
        );
        final receivedCancelled = _applySort(
          all.where(
            (t) =>
                t.effectiveCompanyMovement ==
                CompanyMovementType.receivedCancelled,
          ),
        );
        final sentCancelled = _applySort(
          all.where(
            (t) =>
                t.effectiveCompanyMovement == CompanyMovementType.sentCancelled,
          ),
        );
        final cancelled = _applySort(
          all.where((t) => t.status == TransactionStatus.cancelled),
        );
        final added = _applySort(
          all.where((t) => t.status == TransactionStatus.added),
        );

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                _selectionMode
                    ? 'المحددة: ${_selectedTxIds.length}'
                    : "${widget.account.type.label}: ${widget.account.name}",
              ),
              leading: _selectionMode
                  ? IconButton(
                      tooltip: 'إلغاء التحديد',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _clearSelection,
                    )
                  : null,
              actions: _selectionMode
                  ? [
                      if (!_isCompanyAccount)
                        IconButton(
                          tooltip: 'تسليم المحدد',
                          icon: const Icon(Icons.verified_rounded),
                          onPressed: () => _setTransactionsStatus(
                            _selectedTransactions(),
                            TransactionStatus.received,
                          ),
                        ),
                      IconButton(
                        tooltip: 'إلغاء المحدد',
                        icon: const Icon(Icons.cancel_rounded),
                        onPressed: () => _setTransactionsStatus(
                          _selectedTransactions(),
                          TransactionStatus.cancelled,
                        ),
                      ),
                      IconButton(
                        tooltip: 'إرجاع كمضافة',
                        icon: const Icon(Icons.add_circle_rounded),
                        onPressed: () => _setTransactionsStatus(
                          _selectedTransactions(),
                          TransactionStatus.added,
                        ),
                      ),
                      IconButton(
                        tooltip: 'نقل المحدد',
                        icon: const Icon(Icons.drive_file_move_rounded),
                        onPressed: () =>
                            _moveTransactions(_selectedTransactions()),
                      ),
                      IconButton(
                        tooltip: 'حذف المحدد',
                        icon: const Icon(Icons.delete_rounded),
                        onPressed: () =>
                            _deleteTransactions(_selectedTransactions()),
                      ),
                    ]
                  : [
                      IconButton(
                        tooltip: "تفصيل الحساب",
                        icon: const Icon(Icons.bar_chart_rounded),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                ShareImagePage(account: widget.account),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
            ),
            floatingActionButton: _selectionMode
                ? null
                : FloatingActionButton.extended(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              AddEditTransactionScreen(account: widget.account),
                        ),
                      );
                    },
                    icon: const Icon(Icons.add_rounded),
                    label: const Text("إضافة حركة"),
                  ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                final cs = Theme.of(context).colorScheme;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: allRaw.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text("لا يوجد حركات بعد"),
                          )
                        : ListView(
                            padding: const EdgeInsets.all(12),
                            children: [
                              // البحث + الفرز
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // صندوق البحث (يتمدّد بصريًا عند التركيز)
                                  Expanded(
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      padding: EdgeInsets.symmetric(
                                        horizontal: _searchFocused ? 2 : 0,
                                      ),
                                      child: TextField(
                                        controller: _searchCtrl,
                                        focusNode: _searchFocus, // 👈 مهم
                                        textInputAction: TextInputAction.search,
                                        decoration: InputDecoration(
                                          hintText: "بحث",
                                          prefixIcon: const Icon(
                                            Icons.search_rounded,
                                          ),
                                          suffixIcon: _query.isEmpty
                                              ? null
                                              : IconButton(
                                                  tooltip: "مسح",
                                                  onPressed: () =>
                                                      _searchCtrl.clear(),
                                                  icon: const Icon(
                                                    Icons.close_rounded,
                                                  ),
                                                ),
                                          filled: true,
                                          fillColor: Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerHighest,
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // شريط الفرز / أيقونة الفرز
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 200),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    child: _searchFocused
                                        ? IconButton.filledTonal(
                                            key: const ValueKey('sort-icon'),
                                            onPressed: _showSortSheet,
                                            tooltip: "الفرز",
                                            icon: const Icon(
                                              Icons.sort_rounded,
                                            ),
                                          )
                                        : SizedBox(
                                            key: const ValueKey('sort-bar'),
                                            width: 260,
                                            child: _SortBar(
                                              sortField: _sortField,
                                              ascending: _ascending,
                                              onChangeField: (f) => setState(
                                                () => _sortField = f,
                                              ),
                                              onToggleAsc: () => setState(
                                                () => _ascending = !_ascending,
                                              ),
                                            ),
                                          ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 10),

                              // 🔹 اختيار التاريخ (اليوم / يوم آخر)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: () async {
                                    final picked = await showDatePicker(
                                      context: context,
                                      initialDate: _selectedDay,
                                      firstDate: DateTime(2020),
                                      lastDate: DateTime.now(),
                                    );
                                    if (picked != null) {
                                      setState(() {
                                        _selectedDay = picked;
                                      });
                                    }
                                  },
                                  icon: const Icon(Icons.calendar_month),
                                  label: Text(
                                    "التاريخ: ${_selectedDay.year}-${_selectedDay.month.toString().padLeft(2, '0')}-${_selectedDay.day.toString().padLeft(2, '0')}",
                                  ),
                                ),
                              ),

                              if (_query.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    'نتائج البحث: "${_query}" — ${all.length} عنصر',
                                    style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),

                              if (_isCompanyAccount)
                                ..._buildCompanySections(
                                  received: received,
                                  sent: sent,
                                  receivedCancelled: receivedCancelled,
                                  sentCancelled: sentCancelled,
                                ),

                              if (!_isCompanyAccount && received.isNotEmpty)
                                _StatusSection(
                                  title: "مستلمة",
                                  color: _statusColor(
                                    TransactionStatus.received,
                                  ),
                                  icon: _statusIcon(TransactionStatus.received),
                                  items: received,
                                  accountName: widget.account.name,
                                  expanded:
                                      _expanded[TransactionStatus.received] ??
                                      true,
                                  onToggleExpand: () => setState(() {
                                    _expanded[TransactionStatus.received] =
                                        !(_expanded[TransactionStatus
                                                .received] ??
                                            true);
                                  }),
                                  onCopyRequested: () =>
                                      _showCopyOptionsForSection(
                                        sectionTitle: "مستلمة",
                                        items: received,
                                      ),
                                  onCopyItemRequested: _showCopyOptionsForItem,
                                  formatDay: _formatDayLabel,
                                  formatSmartTime: _formatRelativeOrExactTime,
                                  formatAmount: _formatAmount,
                                  statusLabel: _movementLabel,
                                  selectionMode: _selectionMode,
                                  isSelected: _isSelected,
                                  onToggleSelected: _toggleTransactionSelection,
                                  onStartSelection: _toggleTransactionSelection,
                                  onMoveRequested: _moveOneTransaction,
                                ),

                              if (!_isCompanyAccount && cancelled.isNotEmpty)
                                _StatusSection(
                                  title: "ملغية",
                                  color: _statusColor(
                                    TransactionStatus.cancelled,
                                  ),
                                  icon: _statusIcon(
                                    TransactionStatus.cancelled,
                                  ),
                                  items: cancelled,
                                  accountName: widget.account.name,
                                  expanded:
                                      _expanded[TransactionStatus.cancelled] ??
                                      false,
                                  onToggleExpand: () => setState(() {
                                    _expanded[TransactionStatus.cancelled] =
                                        !(_expanded[TransactionStatus
                                                .cancelled] ??
                                            false);
                                  }),
                                  onCopyRequested: () =>
                                      _showCopyOptionsForSection(
                                        sectionTitle: "ملغية",
                                        items: cancelled,
                                      ),
                                  onCopyItemRequested: _showCopyOptionsForItem,
                                  formatDay: _formatDayLabel,
                                  formatSmartTime: _formatRelativeOrExactTime,
                                  formatAmount: _formatAmount,
                                  statusLabel: _movementLabel,
                                  selectionMode: _selectionMode,
                                  isSelected: _isSelected,
                                  onToggleSelected: _toggleTransactionSelection,
                                  onStartSelection: _toggleTransactionSelection,
                                  onMoveRequested: _moveOneTransaction,
                                ),

                              if (!_isCompanyAccount && added.isNotEmpty)
                                _StatusSection(
                                  title: "مضافة",
                                  color: _statusColor(TransactionStatus.added),
                                  icon: _statusIcon(TransactionStatus.added),
                                  items: added,
                                  accountName: widget.account.name,
                                  expanded:
                                      _expanded[TransactionStatus.added] ??
                                      true,
                                  onToggleExpand: () => setState(() {
                                    _expanded[TransactionStatus.added] =
                                        !(_expanded[TransactionStatus.added] ??
                                            true);
                                  }),
                                  onCopyRequested: () =>
                                      _showCopyOptionsForSection(
                                        sectionTitle: "مضافة",
                                        items: added,
                                      ),
                                  onCopyItemRequested: _showCopyOptionsForItem,
                                  formatDay: _formatDayLabel,
                                  formatSmartTime: _formatRelativeOrExactTime,
                                  formatAmount: _formatAmount,
                                  statusLabel: _movementLabel,
                                  selectionMode: _selectionMode,
                                  isSelected: _isSelected,
                                  onToggleSelected: _toggleTransactionSelection,
                                  onStartSelection: _toggleTransactionSelection,
                                  onMoveRequested: _moveOneTransaction,
                                ),

                              const SizedBox(height: 70),
                            ],
                          ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _SortBar extends StatelessWidget {
  final SortField sortField;
  final bool ascending;
  final ValueChanged<SortField> onChangeField;
  final VoidCallback onToggleAsc;
  const _SortBar({
    required this.sortField,
    required this.ascending,
    required this.onChangeField,
    required this.onToggleAsc,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.sort_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<SortField>(
              value: sortField,
              items: const [
                DropdownMenuItem(
                  value: SortField.date,
                  child: Text("التاريخ / الوقت"),
                ),
                DropdownMenuItem(value: SortField.name, child: Text("الاسم")),
                DropdownMenuItem(
                  value: SortField.status,
                  child: Text("الحالة"),
                ),
                DropdownMenuItem(
                  value: SortField.amount,
                  child: Text("المبلغ"),
                ),
              ],
              onChanged: (v) {
                if (v != null) onChangeField(v);
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "فرز حسب",
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: ascending ? "تصاعدي" : "تنازلي",
            child: IconButton.filledTonal(
              onPressed: onToggleAsc,
              icon: Icon(
                ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusSection extends StatelessWidget {
  final String title;
  final Color color;
  final IconData icon;
  final List<TransactionModel> items;
  final String accountName;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onCopyRequested;
  final void Function(TransactionModel) onCopyItemRequested;
  final bool selectionMode;
  final bool Function(TransactionModel) isSelected;
  final void Function(TransactionModel) onToggleSelected;
  final void Function(TransactionModel) onStartSelection;
  final Future<void> Function(TransactionModel) onMoveRequested;

  // منسّقات من الأعلى
  final String Function(DateTime) formatDay;
  final String Function(DateTime) formatSmartTime;
  final String Function(double) formatAmount;
  final String Function(TransactionModel) statusLabel;
  final Account? account;

  const _StatusSection({
    required this.title,
    required this.color,
    required this.icon,
    required this.items,
    required this.accountName,
    required this.expanded,
    required this.onToggleExpand,
    required this.onCopyRequested,
    required this.onCopyItemRequested,
    required this.selectionMode,
    required this.isSelected,
    required this.onToggleSelected,
    required this.onStartSelection,
    required this.onMoveRequested,
    required this.formatDay,
    required this.formatSmartTime,
    required this.formatAmount,
    required this.statusLabel,
    this.account,
  });

  Future<bool?> _confirmCancel(BuildContext context) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("تأكيد الإلغاء"),
        content: const Text("هل تريد بالتأكيد إلغاء هذه الحركة؟"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("لا"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("نعم، إلغاء"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double sum = 0;
    for (final t in items) {
      sum += t.totalAmount;
    }
    final cs = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          children: [
            ListTile(
              dense: true,
              leading: Icon(icon, color: color, size: 20),
              title: Text(
                title,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              subtitle: Text(
                "المجموع: ${formatAmount(sum)}",
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: "نسخ",
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    onPressed: onCopyRequested,
                  ),
                  IconButton(
                    tooltip: expanded ? "إخفاء العناصر" : "إظهار العناصر",
                    icon: Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                    ),
                    onPressed: onToggleExpand,
                  ),
                ],
              ),
            ),
            if (expanded) const Divider(height: 0),
            if (expanded)
              ...items.map((t) {
                // خلفيات السحب
                final cancelBg = Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.cancel_rounded, color: Colors.red, size: 20),
                      SizedBox(width: 6),
                      Text(
                        "إلغاء",
                        style: TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ],
                  ),
                );

                final editBg = Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: const [
                      Text(
                        "تعديل",
                        style: TextStyle(color: Colors.blue, fontSize: 12),
                      ),
                      SizedBox(width: 6),
                      Icon(Icons.edit_rounded, color: Colors.blue, size: 20),
                    ],
                  ),
                );

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Dismissible(
                    key: ValueKey(
                      "tx-${t.key}-${t.date.millisecondsSinceEpoch}",
                    ),
                    direction: selectionMode
                        ? DismissDirection.none
                        : DismissDirection.horizontal,
                    background: cancelBg, // يمين
                    secondaryBackground: editBg, // يسار
                    confirmDismiss: (dir) async {
                      if (dir == DismissDirection.startToEnd) {
                        final ok = await _confirmCancel(context);
                        if (ok == true) {
                          if (account?.type.isCompany == true &&
                              t.companyMovementType != null) {
                            // لا نغيّر تاريخ الإلغاء لحركة ملغية مسبقًا
                            if (!(t.effectiveCompanyMovement?.isCancelled ??
                                    false) ||
                                t.cancelledAt == null) {
                              t.cancelledAt = DateTime.now();
                            }
                            t.companyMovementType =
                                t.companyMovementType!.cancelled;
                          } else {
                            t.applyStatus(TransactionStatus.cancelled);
                          }
                          await t.save();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text("تم إلغاء الحركة"),
                                backgroundColor: cs.error,
                              ),
                            );
                          }
                        }
                        return false;
                      } else if (dir == DismissDirection.endToStart) {
                        if (context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AddEditTransactionScreen(
                                account:
                                    account ??
                                    Account(id: t.accountId, name: accountName),
                                existing: t,
                              ),
                            ),
                          );
                        }
                        return false;
                      }
                      return false;
                    },
                    child: _TxBubble(
                      t: t,
                      accountName: accountName,
                      colorScheme: cs,
                      formatDay: formatDay,
                      formatSmartTime: formatSmartTime,
                      formatAmount: formatAmount,
                      statusLabel: statusLabel,
                      selected: isSelected(t),
                      selectionMode: selectionMode,
                      onToggleSelected: () => onToggleSelected(t),
                      onStartSelection: () => onStartSelection(t),
                      onCopyItemRequested: onCopyItemRequested,
                      onMoveRequested: () => onMoveRequested(t),
                      onEdit: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AddEditTransactionScreen(
                              account:
                                  account ??
                                  Account(id: t.accountId, name: accountName),

                              existing: t,
                            ),
                          ),
                        );
                      },
                      onSetReceived: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final before = await TxUndo.deliver(t);
                        AppMessages.showWithUndo(
                          messenger,
                          'تم التسليم',
                          () async {
                            await TxUndo.restoreStatus(t, before);
                            _say(messenger, 'تم التراجع عن التسليم');
                          },
                        );
                      },
                      onSetCancelled: (Future<bool?> Function() confirm) async {
                        final ok = await confirm();
                        if (ok == true) {
                          if (account?.type.isCompany == true &&
                              t.companyMovementType != null) {
                            // لا نغيّر تاريخ الإلغاء لحركة ملغية مسبقًا
                            if (!(t.effectiveCompanyMovement?.isCancelled ??
                                    false) ||
                                t.cancelledAt == null) {
                              t.cancelledAt = DateTime.now();
                            }
                            t.companyMovementType =
                                t.companyMovementType!.cancelled;
                          } else {
                            t.applyStatus(TransactionStatus.cancelled);
                          }
                          await t.save();
                        }
                      },
                      onDelete: () async {
                        await t.delete();
                      },
                      confirmCancel: () => _confirmCancel(context),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

// ===== فقاعة الحركة (تصميم جميل وهادئ) =====
class _TxBubble extends StatelessWidget {
  final TransactionModel t;
  final String accountName;
  final ColorScheme colorScheme;
  final String Function(DateTime) formatDay;
  final String Function(DateTime) formatSmartTime;
  final String Function(double) formatAmount;
  final String Function(TransactionModel) statusLabel;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onToggleSelected;
  final VoidCallback onStartSelection;
  final void Function(TransactionModel) onCopyItemRequested;
  final Future<void> Function() onMoveRequested;
  final VoidCallback onEdit;
  final Future<void> Function() onSetReceived;
  final Future<void> Function(Future<bool?> Function() confirm) onSetCancelled;
  final Future<void> Function() onDelete;
  final Future<bool?> Function() confirmCancel;

  const _TxBubble({
    required this.t,
    required this.accountName,
    required this.colorScheme,
    required this.formatDay,
    required this.formatSmartTime,
    required this.formatAmount,
    required this.statusLabel,
    required this.selected,
    required this.selectionMode,
    required this.onToggleSelected,
    required this.onStartSelection,
    required this.onCopyItemRequested,
    required this.onMoveRequested,
    required this.onEdit,
    required this.onSetReceived,
    required this.onSetCancelled,
    required this.onDelete,
    required this.confirmCancel,
    super.key,
  });

  Color get _statusColor {
    switch (t.effectiveCompanyMovement) {
      case CompanyMovementType.received:
        return const Color(0xFF00897B);
      case CompanyMovementType.sent:
        return const Color(0xFF5E35B1);
      case CompanyMovementType.receivedCancelled:
        return const Color(0xFFD84315);
      case CompanyMovementType.sentCancelled:
        return const Color(0xFFEF6C00);
      case null:
        switch (t.status) {
          case TransactionStatus.added:
            return Colors.blue;
          case TransactionStatus.received:
            return Colors.green;
          case TransactionStatus.cancelled:
            return Colors.red;
        }
    }
  }

  IconData get _statusIcon {
    switch (t.effectiveCompanyMovement) {
      case CompanyMovementType.received:
        return Icons.call_received_rounded;
      case CompanyMovementType.sent:
        return Icons.call_made_rounded;
      case CompanyMovementType.receivedCancelled:
      case CompanyMovementType.sentCancelled:
        return Icons.cancel_rounded;
      case null:
        switch (t.status) {
          case TransactionStatus.added:
            return Icons.add_circle_rounded;
          case TransactionStatus.received:
            return Icons.verified_rounded;
          case TransactionStatus.cancelled:
            return Icons.cancel_rounded;
        }
    }
  }

  bool get _isCompany => t.companyMovementType != null;

  /// «تراجع عن التسليم»: الحركة بترجع مضافة
  Future<void> _undoDelivery(ScaffoldMessengerState messenger) async {
    await TxUndo.undoDelivery(t);
    _say(messenger, 'تم التراجع عن التسليم');
  }

  /// «تراجع عن التعديل»: الحركة بترجع متل ما كانت قبل آخر تعديل
  Future<void> _undoEdit(ScaffoldMessengerState messenger) async {
    final ok = await TxUndo.undoEdit(t);
    _say(messenger, ok ? 'تم التراجع عن التعديل' : 'تعذّر التراجع عن التعديل');
  }

  /// الضغط على الحركة: تسليم / إلغاء / تعديل، والتراجع عن التسليم والتعديل
  Future<void> _showActions(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final cancelled = _isCompany
        ? (t.effectiveCompanyMovement?.isCancelled ?? false)
        : t.status == TransactionStatus.cancelled;
    final received = !_isCompany && t.status == TransactionStatus.received;
    final canUndoEdit = TxUndo.canUndoEdit(t.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  t.beneficiary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (!_isCompany && !received)
                ListTile(
                  leading: const Icon(
                    Icons.verified_rounded,
                    color: Colors.green,
                  ),
                  title: const Text('تسليم'),
                  onTap: () => Navigator.pop(ctx, 'deliver'),
                ),
              if (received)
                ListTile(
                  leading: const Icon(Icons.undo_rounded, color: Colors.green),
                  title: const Text('تراجع عن التسليم'),
                  onTap: () => Navigator.pop(ctx, 'undeliver'),
                ),
              ListTile(
                enabled: !cancelled,
                leading: const Icon(Icons.cancel_rounded, color: Colors.red),
                title: const Text('إلغاء'),
                onTap: () => Navigator.pop(ctx, 'cancel'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_rounded, color: Colors.blue),
                title: const Text('تعديل'),
                onTap: () => Navigator.pop(ctx, 'edit'),
              ),
              if (canUndoEdit)
                ListTile(
                  leading: const Icon(Icons.undo_rounded, color: Colors.blue),
                  title: const Text('تراجع عن التعديل'),
                  onTap: () => Navigator.pop(ctx, 'undo_edit'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    switch (action) {
      case 'deliver':
        await onSetReceived();
        break;
      case 'undeliver':
        await _undoDelivery(messenger);
        break;
      case 'cancel':
        await onSetCancelled(confirmCancel);
        break;
      case 'edit':
        onEdit();
        break;
      case 'undo_edit':
        await _undoEdit(messenger);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    final destination = t.destination?.trim() ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: selectionMode ? onToggleSelected : () => _showActions(context),
        onLongPress: onStartSelection,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [cs.surfaceContainerHigh, cs.surface],
            ),
            border: Border.all(
              color: selected
                  ? cs.primary.withOpacity(0.70)
                  : cs.outlineVariant.withOpacity(0.25),
              width: selected ? 1.6 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            children: [
              // شريط الحالة الرفيع
              PositionedDirectional(
                start: 0,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: _statusColor,
                    borderRadius: const BorderRadiusDirectional.only(
                      topStart: Radius.circular(14),
                      bottomStart: Radius.circular(14),
                    ),
                  ),
                ),
              ),
              // المحتوى
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // السطر العلوي: اسم + مبلغ + حالة + قائمة
                    Row(
                      children: [
                        if (selectionMode) ...[
                          Checkbox(
                            value: selected,
                            onChanged: (_) => onToggleSelected(),
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 4),
                        ],
                        // الاسم + أيقونة حالة
                        Flexible(
                          fit: FlexFit.tight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_statusIcon, size: 16, color: _statusColor),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  t.beneficiary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: cs.onSurface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // المبلغ + العملة
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${formatAmount(t.amount)} ${t.currency}',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: cs.onSurface,
                              ),
                            ),
                            if (t.hasSecondAmount) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${formatAmount(t.secondAmount!)} ${t.secondCurrency ?? t.currency}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: cs.onSurface,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(width: 6),
                        // شارة الحالة
                        Container(
                          decoration: BoxDecoration(
                            color: _statusColor.withOpacity(.10),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: _statusColor.withOpacity(.25),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          child: Text(
                            statusLabel(t),
                            style: TextStyle(
                              fontSize: 11,
                              color: _statusColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        PopupMenuButton<String>(
                          tooltip: "خيارات",
                          onSelected: (val) async {
                            final messenger = ScaffoldMessenger.of(context);
                            switch (val) {
                              case 'deliver':
                                await onSetReceived();
                                break;
                              case 'undeliver':
                                await _undoDelivery(messenger);
                                break;
                              case 'cancel':
                                await onSetCancelled(confirmCancel);
                                break;
                              case 'edit':
                                onEdit();
                                break;
                              case 'undo_edit':
                                await _undoEdit(messenger);
                                break;
                              case 'move':
                                await onMoveRequested();
                                break;
                              case 'delete':
                                await onDelete();
                                break;
                              case 'copy':
                                onCopyItemRequested(t);
                                break;
                            }
                          },
                          itemBuilder: (ctx) {
                            final isCompany = t.companyMovementType != null;
                            final received =
                                !isCompany &&
                                t.status == TransactionStatus.received;
                            return [
                              if (!isCompany && !received)
                                const PopupMenuItem(
                                  value: 'deliver',
                                  child: Text("تمييز كـ مستلمة"),
                                ),
                              if (received)
                                const PopupMenuItem(
                                  value: 'undeliver',
                                  child: Text("تراجع عن التسليم"),
                                ),
                              if (!isCompany)
                                const PopupMenuItem(
                                  value: 'cancel',
                                  child: Text("إلغاء الحركة"),
                                ),
                              PopupMenuItem(
                                value: 'edit',
                                child: Text(
                                  isCompany
                                      ? 'تغيير النوع (مرسلة / استقبال)'
                                      : 'تعديل',
                                ),
                              ),
                              if (TxUndo.canUndoEdit(t.id))
                                const PopupMenuItem(
                                  value: 'undo_edit',
                                  child: Text("تراجع عن التعديل"),
                                ),
                              const PopupMenuItem(
                                value: 'move',
                                child: Text("نقل إلى حساب آخر"),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text(
                                  "حذف",
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'copy',
                                child: Text("نسخ…"),
                              ),
                            ];
                          },
                          child: Icon(
                            Icons.more_horiz_rounded,
                            color: cs.onSurfaceVariant,
                            size: 18,
                          ),
                        ),
                      ],
                    ),

                    // فاصل رفيع جدًا
                    Container(
                      height: 1,
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            cs.outlineVariant.withOpacity(.0),
                            cs.outlineVariant.withOpacity(.35),
                            cs.outlineVariant.withOpacity(.0),
                          ],
                        ),
                      ),
                    ),

                    // التاريخ + الوقت (chips صغيرة)
                    Theme(
                      data: Theme.of(context).copyWith(
                        chipTheme: ChipTheme.of(context).copyWith(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 0,
                          ),
                          labelStyle: const TextStyle(fontSize: 12),
                        ),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Chip(
                            label: Text(formatDay(t.date)),
                            avatar: const Icon(
                              Icons.calendar_today_rounded,
                              size: 14,
                              color: Colors.blue,
                            ),
                            labelStyle: const TextStyle(color: Colors.blue),
                            side: const BorderSide(color: Colors.blue),
                          ),
                          Chip(
                            label: Text(formatSmartTime(t.date)),
                            avatar: const Icon(
                              Icons.access_time_filled_rounded,
                              size: 14,
                              color: Colors.orange,
                            ),
                            labelStyle: const TextStyle(color: Colors.orange),
                            side: const BorderSide(color: Colors.orange),
                          ),
                          if (destination.isNotEmpty)
                            Chip(
                              label: Text(destination),
                              avatar: const Icon(
                                Icons.place_rounded,
                                size: 14,
                                color: Colors.purple,
                              ),
                              labelStyle: const TextStyle(color: Colors.purple),
                              side: const BorderSide(color: Colors.purple),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
