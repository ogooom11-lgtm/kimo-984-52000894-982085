import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:excel/excel.dart' as xls;
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'unreceived_reconcile_screen.dart'; // 👈 جديد

import '../database_service.dart';
import '../models.dart';
import '../services/operation_log_service.dart';
import '../services/tx_history_service.dart';
import 'add_edit_transaction_screen.dart';
import 'account_stats_screen.dart';
import 'transaction_details_screen.dart';
import 'transaction_history_screen.dart';

enum SortField { date, name, status, amount }

enum ExportFileType { excel, pdf }

class _ExportFields {
  bool name;
  bool amount1;
  bool currency1;
  bool amount2;
  bool currency2;
  bool total;
  bool day;
  bool time;
  bool status;
  bool statusStamp;

  _ExportFields({
    this.name = true,
    this.amount1 = true,
    this.currency1 = true,
    this.amount2 = true,
    this.currency2 = true,
    this.total = false,
    this.day = false,
    this.time = false,
    this.status = false,
    this.statusStamp = false,
  });

  bool get hasAny =>
      name ||
      amount1 ||
      currency1 ||
      amount2 ||
      currency2 ||
      total ||
      day ||
      time ||
      status ||
      statusStamp;
}

class _ExportColumn {
  final String title;
  final String value;
  const _ExportColumn(this.title, this.value);
}

class AccountScreen extends StatefulWidget {
  final Account account;

  /// حركات تُحدَّد تلقائيًا عند فتح الحساب (مثلًا من سجل العمليات)
  final Set<int>? initialSelectedTxIds;

  /// عنوان يوضح مصدر التحديد (مثل عنوان العملية في السجل)
  final String? selectionTitle;

  const AccountScreen({
    super.key,
    required this.account,
    this.initialSelectedTxIds,
    this.selectionTitle,
  });

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

  /// عند الفتح من سجل العمليات: نعرض حركات العملية فقط (مع إمكانية عرض الكل)
  final Set<int> _focusTxIds = {};
  bool _showOnlyFocused = false;

  bool get _selectionMode => _selectedTxIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSelectedTxIds;
    if (initial != null && initial.isNotEmpty) {
      _selectedTxIds.addAll(initial);
      _focusTxIds.addAll(initial);
      _showOnlyFocused = true;
      for (final k in _expanded.keys.toList()) {
        _expanded[k] = true;
      }
      for (final k in _companyExpanded.keys.toList()) {
        _companyExpanded[k] = true;
      }
    }
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

    if (items.length > 1) {
      TxHistoryService.annotate(items.map((t) => t.id), 'نقل جماعي');
    }
    final records = <OperationTxRecord>[];
    for (final tx in items) {
      final before = OperationLogService.snapshot(tx);
      tx.accountId = target.id;
      await tx.save();
      records.add(
        OperationTxRecord(
          txId: tx.id,
          before: before,
          after: OperationLogService.snapshot(tx),
        ),
      );
    }
    await OperationLogService.log(
      kind: OperationKind.move,
      title:
          'نقل ${items.length} حركة من «${widget.account.name}» إلى «${target.name}»',
      records: records,
    );

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
    TxHistoryService.annotate(items.map((t) => t.id), 'إجراء جماعي');
    final records = <OperationTxRecord>[];
    for (final tx in items) {
      final before = OperationLogService.snapshot(tx);
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
        tx.applyStatus(status, at: now);
      }
      await tx.save();
      records.add(
        OperationTxRecord(
          txId: tx.id,
          before: before,
          after: OperationLogService.snapshot(tx),
        ),
      );
    }
    await OperationLogService.log(
      kind: OperationKind.statusChange,
      title:
          'تحويل ${items.length} حركة إلى «$label» في «${widget.account.name}»',
      records: records,
    );

    if (!mounted) return;
    _clearSelection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('تم تحديث ${items.length} حركة')));
  }

  Future<void> _deleteTransactions(List<TransactionModel> items) async {
    if (items.isEmpty) return;
    final ok = await _confirmBulkAction(
      'تأكيد الحذف',
      'سيتم حذف ${items.length} حركة نهائيًا. هل تريد المتابعة؟',
    );
    if (!ok) return;

    final records = <OperationTxRecord>[
      for (final tx in items)
        OperationTxRecord(
          txId: tx.id,
          before: OperationLogService.snapshot(tx),
        ),
    ];
    TxHistoryService.annotate(items.map((t) => t.id), 'حذف جماعي');
    for (final tx in items) {
      await tx.delete();
    }
    await OperationLogService.log(
      kind: OperationKind.delete,
      title: 'حذف ${items.length} حركة من «${widget.account.name}»',
      records: records,
    );

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

  String _statusStampLabel(TransactionModel t) {
    switch (t.status) {
      case TransactionStatus.received:
        return 'تاريخ التسليم';
      case TransactionStatus.cancelled:
        return 'تاريخ الإلغاء';
      case TransactionStatus.added:
        return 'تاريخ الحركة';
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
                    subtitle: Text("اختر الحقل واتجاه الفرز"),
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

  List<_ExportColumn> _buildExportColumns(
    TransactionModel t,
    _ExportFields fields,
  ) {
    final columns = <_ExportColumn>[];

    if (fields.name) {
      columns.add(_ExportColumn('الاسم', t.beneficiary));
    }
    if (fields.amount1) {
      columns.add(_ExportColumn('المبلغ 1', _formatAmount(t.amount)));
    }
    if (fields.currency1) {
      columns.add(_ExportColumn('العملة 1', t.currency));
    }
    if (fields.amount2) {
      columns.add(
        _ExportColumn(
          'المبلغ 2',
          t.hasSecondAmount ? _formatAmount(t.secondAmount!) : '',
        ),
      );
    }
    if (fields.currency2) {
      columns.add(
        _ExportColumn(
          'العملة 2',
          t.hasSecondAmount ? (t.secondCurrency ?? t.currency) : '',
        ),
      );
    }
    if (fields.total) {
      columns.add(_ExportColumn('الإجمالي', _formatAmount(t.totalAmount)));
    }
    if (fields.day) {
      columns.add(_ExportColumn('التاريخ', _formatDayLabel(t.date)));
    }
    if (fields.time) {
      columns.add(_ExportColumn('الوقت', _formatRelativeOrExactTime(t.date)));
    }
    if (fields.status) {
      columns.add(_ExportColumn('الحالة', _statusLabel(t.status)));
    }
    if (fields.statusStamp) {
      final stamp = _statusStamp(t) ?? t.date;
      columns.add(
        _ExportColumn(_statusStampLabel(t), _formatExactDateTime(stamp)),
      );
    }

    return columns;
  }

  String _buildCopyLine(TransactionModel t, _ExportFields fields) {
    return _buildExportColumns(
      t,
      fields,
    ).map((c) => c.value).where((value) => value.trim().isNotEmpty).join(' | ');
  }

  String _buildCopyText(List<TransactionModel> items, _ExportFields fields) {
    return items.map((t) => _buildCopyLine(t, fields)).join('\n');
  }

  List<String> _buildExportHeaders(
    List<TransactionModel> items,
    _ExportFields fields,
  ) {
    if (items.isEmpty) return const [];
    return _buildExportColumns(
      items.first,
      fields,
    ).map((c) => c.title).toList();
  }

  List<List<String>> _buildExportRows(
    List<TransactionModel> items,
    _ExportFields fields,
  ) {
    return items
        .map((t) => _buildExportColumns(t, fields).map((c) => c.value).toList())
        .toList();
  }

  String _safeFileName(String value) {
    final cleaned = value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'export' : cleaned;
  }

  String _exportBaseName(String sectionTitle) {
    final now = DateTime.now();
    final stamp =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    return _safeFileName('${widget.account.name}_${sectionTitle}_$stamp');
  }

  Future<String?> _saveExportFile({
    required String baseName,
    required Uint8List bytes,
    required String extension,
    required MimeType mimeType,
  }) async {
    // ملاحظة مهمة:
    // FileSaver.saveFile على Android يحفظ داخل مجلد التطبيق:
    // Android/data/<package>/files
    // لذلك نستخدم saveAs على Android حتى تظهر نافذة النظام
    // ويستطيع المستخدم اختيار مجلد Downloads مباشرة.
    if (!kIsWeb && Platform.isAndroid) {
      return FileSaver.instance.saveAs(
        name: baseName,
        bytes: bytes,
        ext: extension,
        mimeType: mimeType,
      );
    }

    return FileSaver.instance.saveFile(
      name: baseName,
      bytes: bytes,
      ext: extension,
      mimeType: mimeType,
    );
  }

  Future<String?> _exportSectionToExcel({
    required String sectionTitle,
    required List<TransactionModel> items,
    required _ExportFields fields,
  }) async {
    final headers = _buildExportHeaders(items, fields);
    final rows = _buildExportRows(items, fields);

    final book = xls.Excel.createExcel();
    const sheetName = 'التقرير';
    final sheet = book[sheetName];

    sheet.appendRow(headers.map((h) => xls.TextCellValue(h)).toList());
    for (final row in rows) {
      sheet.appendRow(row.map((v) => xls.TextCellValue(v)).toList());
    }

    final bytes = book.encode();
    if (bytes == null) {
      throw Exception('تعذر إنشاء ملف Excel');
    }

    return _saveExportFile(
      baseName: _exportBaseName(sectionTitle),
      bytes: Uint8List.fromList(bytes),
      extension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
  }

  Future<String?> _exportSectionToPdf({
    required String sectionTitle,
    required List<TransactionModel> items,
    required _ExportFields fields,
  }) async {
    final headers = _buildExportHeaders(items, fields);
    final rows = _buildExportRows(items, fields);
    final regularFont = await PdfGoogleFonts.cairoRegular();
    final boldFont = await PdfGoogleFonts.cairoBold();

    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
    );

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(22),
        build: (ctx) => [
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Text(
                  'تقرير $sectionTitle - ${widget.account.name}',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(font: boldFont, fontSize: 18),
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  'عدد الحركات: ${items.length}',
                  textAlign: pw.TextAlign.right,
                  style: const pw.TextStyle(fontSize: 10),
                ),
                pw.SizedBox(height: 12),
                pw.TableHelper.fromTextArray(
                  headers: headers,
                  data: rows,
                  border: pw.TableBorder.all(
                    color: PdfColors.grey400,
                    width: .4,
                  ),
                  headerAlignment: pw.Alignment.centerRight,
                  cellAlignment: pw.Alignment.centerRight,
                  headerDecoration: const pw.BoxDecoration(
                    color: PdfColors.blueGrey800,
                  ),
                  headerStyle: pw.TextStyle(
                    font: boldFont,
                    color: PdfColors.white,
                    fontSize: 9,
                  ),
                  cellStyle: pw.TextStyle(font: regularFont, fontSize: 8),
                  cellPadding: const pw.EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return _saveExportFile(
      baseName: _exportBaseName(sectionTitle),
      bytes: await document.save(),
      extension: 'pdf',
      mimeType: MimeType.pdf,
    );
  }

  Future<void> _runExport({
    required String sectionTitle,
    required List<TransactionModel> items,
    required _ExportFields fields,
    required ExportFileType fileType,
  }) async {
    if (items.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لا يوجد عناصر لتصديرها')));
      return;
    }

    if (!fields.hasAny) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر حقلاً واحداً على الأقل')),
      );
      return;
    }

    try {
      final savedPath = fileType == ExportFileType.excel
          ? await _exportSectionToExcel(
              sectionTitle: sectionTitle,
              items: items,
              fields: fields,
            )
          : await _exportSectionToPdf(
              sectionTitle: sectionTitle,
              items: items,
              fields: fields,
            );

      if (!mounted) return;
      if (savedPath == null || savedPath.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم إلغاء حفظ الملف')));
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            fileType == ExportFileType.excel
                ? 'تم تصدير ملف Excel بنجاح إلى: $savedPath'
                : 'تم تصدير ملف PDF بنجاح إلى: $savedPath',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('حدث خطأ أثناء التصدير: $e')));
    }
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
  }) async {
    final fields = _ExportFields();
    ExportFileType fileType = ExportFileType.excel;

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
              top: 8,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: StatefulBuilder(
              builder: (ctx, setSheet) {
                final preview = _buildCopyText(items.take(5).toList(), fields);

                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.ios_share_rounded),
                        title: Text('نسخ / تصدير — $sectionTitle'),
                        subtitle: const Text(
                          'اختر المعلومات المطلوبة ثم اختر نوع الملف واضغط تصدير',
                        ),
                      ),
                      const Divider(),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          'المعلومات داخل الملف',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
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
                            label: 'العملة 1',
                            selected: fields.currency1,
                            onSelected: (v) =>
                                setSheet(() => fields.currency1 = v),
                          ),
                          _fieldChip(
                            label: 'المبلغ 2',
                            selected: fields.amount2,
                            onSelected: (v) =>
                                setSheet(() => fields.amount2 = v),
                          ),
                          _fieldChip(
                            label: 'العملة 2',
                            selected: fields.currency2,
                            onSelected: (v) =>
                                setSheet(() => fields.currency2 = v),
                          ),
                          _fieldChip(
                            label: 'الإجمالي',
                            selected: fields.total,
                            onSelected: (v) => setSheet(() => fields.total = v),
                          ),
                          _fieldChip(
                            label: 'التاريخ',
                            selected: fields.day,
                            onSelected: (v) => setSheet(() => fields.day = v),
                          ),
                          _fieldChip(
                            label: 'الوقت',
                            selected: fields.time,
                            onSelected: (v) => setSheet(() => fields.time = v),
                          ),
                          _fieldChip(
                            label: 'الحالة',
                            selected: fields.status,
                            onSelected: (v) =>
                                setSheet(() => fields.status = v),
                          ),
                          _fieldChip(
                            label: 'تاريخ الحالة',
                            selected: fields.statusStamp,
                            onSelected: (v) =>
                                setSheet(() => fields.statusStamp = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          'نوع الملف',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              avatar: const Icon(
                                Icons.table_chart_rounded,
                                size: 18,
                              ),
                              label: const Text('Excel'),
                              selected: fileType == ExportFileType.excel,
                              onSelected: (_) => setSheet(
                                () => fileType = ExportFileType.excel,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ChoiceChip(
                              avatar: const Icon(
                                Icons.picture_as_pdf_rounded,
                                size: 18,
                              ),
                              label: const Text('PDF'),
                              selected: fileType == ExportFileType.pdf,
                              onSelected: (_) =>
                                  setSheet(() => fileType = ExportFileType.pdf),
                            ),
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
                            preview.isEmpty ? 'لا توجد معاينة' : preview,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await _runExport(
                                  sectionTitle: sectionTitle,
                                  items: items,
                                  fields: fields,
                                  fileType: fileType,
                                );
                              },
                              icon: const Icon(Icons.file_download_rounded),
                              label: const Text('تصدير'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: () async {
                              if (!fields.hasAny) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'اختر حقلاً واحداً على الأقل',
                                    ),
                                  ),
                                );
                                return;
                              }
                              await Clipboard.setData(
                                ClipboardData(
                                  text: _buildCopyText(items, fields),
                                ),
                              );
                              if (mounted) {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: cs.primary,
                                    content: const Text('تم النسخ إلى الحافظة'),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.content_copy_rounded),
                            label: const Text('نسخ'),
                          ),
                        ],
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

  // نسخ عنصر واحد
  Future<void> _showCopyOptionsForItem(TransactionModel t) async {
    final fields = _ExportFields(total: true, statusStamp: true);

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: StatefulBuilder(
              builder: (ctx, setSheet) => SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ListTile(
                      leading: Icon(Icons.copy_rounded),
                      title: Text('خيارات النسخ — عنصر'),
                      subtitle: Text('اختر الحقول المراد نسخها'),
                    ),
                    const Divider(),
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
                          onSelected: (v) => setSheet(() => fields.amount1 = v),
                        ),
                        _fieldChip(
                          label: 'العملة 1',
                          selected: fields.currency1,
                          onSelected: (v) =>
                              setSheet(() => fields.currency1 = v),
                        ),
                        _fieldChip(
                          label: 'المبلغ 2',
                          selected: fields.amount2,
                          onSelected: (v) => setSheet(() => fields.amount2 = v),
                        ),
                        _fieldChip(
                          label: 'العملة 2',
                          selected: fields.currency2,
                          onSelected: (v) =>
                              setSheet(() => fields.currency2 = v),
                        ),
                        _fieldChip(
                          label: 'الإجمالي',
                          selected: fields.total,
                          onSelected: (v) => setSheet(() => fields.total = v),
                        ),
                        _fieldChip(
                          label: 'التاريخ',
                          selected: fields.day,
                          onSelected: (v) => setSheet(() => fields.day = v),
                        ),
                        _fieldChip(
                          label: 'الوقت',
                          selected: fields.time,
                          onSelected: (v) => setSheet(() => fields.time = v),
                        ),
                        _fieldChip(
                          label: 'الحالة',
                          selected: fields.status,
                          onSelected: (v) => setSheet(() => fields.status = v),
                        ),
                        _fieldChip(
                          label: 'تاريخ الحالة',
                          selected: fields.statusStamp,
                          onSelected: (v) =>
                              setSheet(() => fields.statusStamp = v),
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
                      child: Text(
                        _buildCopyLine(t, fields),
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () async {
                              if (!fields.hasAny) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'اختر حقلاً واحداً على الأقل',
                                    ),
                                  ),
                                );
                                return;
                              }
                              await Clipboard.setData(
                                ClipboardData(text: _buildCopyLine(t, fields)),
                              );
                              if (mounted) {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: cs.primary,
                                    content: const Text('تم نسخ العنصر'),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.content_copy),
                            label: const Text('نسخ'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close),
                          label: const Text('إلغاء'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
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

  Widget _buildFocusBanner(BuildContext context, bool focusActive) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: .35)),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  focusActive
                      ? 'حركات من سجل العمليات (${_focusTxIds.length})'
                      : 'تم تحديد حركات العملية ضمن كل الحركات',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                if ((widget.selectionTitle ?? '').isNotEmpty)
                  Text(
                    widget.selectionTitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onPrimaryContainer.withValues(alpha: .8),
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () =>
                setState(() => _showOnlyFocused = !_showOnlyFocused),
            child: Text(focusActive ? 'عرض كل الحركات' : 'عرضها فقط'),
          ),
          IconButton(
            tooltip: 'إغلاق',
            onPressed: () => setState(() {
              _focusTxIds.clear();
              _showOnlyFocused = false;
            }),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
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
        // (أو نعرض حركات العملية القادمة من سجل العمليات فقط)
        final focusActive = _showOnlyFocused && _focusTxIds.isNotEmpty;
        final filteredByDay = focusActive
            ? allRaw.where((t) => _focusTxIds.contains(t.id)).toList()
            : _filterBySelectedDay(allRaw);

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
                        tooltip: "إحصائيات الحساب",
                        icon: const Icon(Icons.bar_chart_rounded),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                AccountStatsScreen(account: widget.account),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: "مطابقة غير المستلمة (Excel)",
                        icon: const Icon(Icons.compare_arrows_rounded),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UnreceivedReconcileScreen(
                              account: widget.account,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
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
                                          hintText:
                                              "ابحث بالاسم أو العملة أو التاريخ أو المبلغ…",
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

                              if (_focusTxIds.isNotEmpty)
                                _buildFocusBanner(context, focusActive),

                              // 🔹 اختيار التاريخ (اليوم / يوم آخر)
                              if (!focusActive)
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
                  Tooltip(
                    message: "نسخ / تصدير هذه الفئة",
                    child: IconButton(
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      onPressed: onCopyRequested,
                    ),
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
                        "سحب لليمين: إلغاء",
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
                        "سحب لليسار: تعديل",
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
                      onOpenDetails: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => TransactionDetailsScreen(
                              account:
                                  account ??
                                  Account(id: t.accountId, name: accountName),
                              transactionHiveKey: t.key,
                            ),
                          ),
                        );
                      },
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
                        t.applyStatus(TransactionStatus.received);
                        await t.save();
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
  final VoidCallback onOpenDetails;
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
    required this.onOpenDetails,
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

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: selectionMode ? onToggleSelected : onOpenDetails,
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
                        IconButton(
                          tooltip: "تفاصيل الحركة",
                          onPressed: onOpenDetails,
                          icon: Icon(
                            Icons.article_outlined,
                            color: cs.onSurfaceVariant,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 4),
                        PopupMenuButton<String>(
                          tooltip: "خيارات",
                          onSelected: (val) async {
                            switch (val) {
                              case 'deliver':
                                await onSetReceived();
                                break;
                              case 'cancel':
                                await onSetCancelled(confirmCancel);
                                break;
                              case 'edit':
                                onEdit();
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
                              case 'details':
                                onOpenDetails();
                                break;
                              case 'history':
                                await openTransactionHistory(context, t);
                                break;
                            }
                          },
                          itemBuilder: (ctx) {
                            final isCompany = t.companyMovementType != null;
                            return [
                              if (!isCompany)
                                const PopupMenuItem(
                                  value: 'deliver',
                                  child: Text("تمييز كـ مستلمة"),
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
                              const PopupMenuItem(
                                value: 'details',
                                child: Text("تفاصيل الحركة"),
                              ),
                              const PopupMenuItem(
                                value: 'history',
                                child: Text("سجل التعديلات"),
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
