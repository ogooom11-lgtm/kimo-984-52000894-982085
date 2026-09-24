import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:excel/excel.dart' as xls;
import 'package:file_saver/file_saver.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';

enum _TriggerStatusFilter { all, received, cancelled }

enum _WatchSortMode {
  newestTrigger,
  oldestTrigger,
  mostOpen,
  highestAmount,
  name,
}

enum _ChartMetric { alerts, openMovements, openAmount }

class TransactionWatchScreen extends StatefulWidget {
  const TransactionWatchScreen({super.key});

  @override
  State<TransactionWatchScreen> createState() => _TransactionWatchScreenState();
}

class _TransactionWatchScreenState extends State<TransactionWatchScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  String _query = '';
  int? _selectedAccountId;
  bool _useDateRange = false;
  DateTimeRange _dateRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 30)),
    end: DateTime.now(),
  );

  _TriggerStatusFilter _statusFilter = _TriggerStatusFilter.all;
  _WatchSortMode _sortMode = _WatchSortMode.newestTrigger;
  _ChartMetric _chartMetric = _ChartMetric.alerts;

  bool _showChart = true;
  bool _showDetails = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final value = _searchCtrl.text.trim();
      if (value == _query) return;
      setState(() => _query = value);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ==========================
  // Helpers
  // ==========================

  String _cleanName(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  String _normalizeName(String value) {
    var text = _cleanName(value);
    text = text.replaceAll(
      RegExp(r'[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED]'),
      '',
    );

    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      switch (ch) {
        case 'أ':
        case 'إ':
        case 'آ':
          buffer.write('ا');
          break;
        case 'ة':
          buffer.write('ه');
          break;
        case 'ى':
          buffer.write('ي');
          break;
        case 'ؤ':
          buffer.write('و');
          break;
        case 'ئ':
          buffer.write('ي');
          break;
        default:
          buffer.write(ch);
      }
    }

    return buffer.toString().toLowerCase().trim();
  }

  String _formatDay(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  String _formatTime(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _formatDateTime(DateTime d) => '${_formatDay(d)} ${_formatTime(d)}';

  String _formatAmount(double value) {
    if (!value.isFinite) return '0,00';
    final fixed = value.toStringAsFixed(2);
    final parts = fixed.split('.');
    final sign = parts[0].startsWith('-') ? '-' : '';
    final intPart = parts[0].replaceFirst('-', '');
    final dec = parts.length > 1 ? parts[1] : '00';
    final buf = StringBuffer();

    for (var i = 0; i < intPart.length; i++) {
      final index = intPart.length - 1 - i;
      buf.write(intPart[index]);
      if (i % 3 == 2 && index != 0) buf.write('.');
    }

    return '$sign${buf.toString().split('').reversed.join()},$dec';
  }

  String _statusLabel(TransactionStatus status) {
    switch (status) {
      case TransactionStatus.added:
        return 'مضافة';
      case TransactionStatus.received:
        return 'مستلمة';
      case TransactionStatus.cancelled:
        return 'ملغاة';
    }
  }

  Color _statusColor(TransactionStatus status) {
    switch (status) {
      case TransactionStatus.added:
        return const Color(0xFF2F80ED);
      case TransactionStatus.received:
        return const Color(0xFF00A76F);
      case TransactionStatus.cancelled:
        return const Color(0xFFE5484D);
    }
  }

  DateTime _statusMoment(TransactionModel tx) {
    switch (tx.status) {
      case TransactionStatus.received:
        return tx.receivedAt ?? tx.date;
      case TransactionStatus.cancelled:
        return tx.cancelledAt ?? tx.date;
      case TransactionStatus.added:
        return tx.date;
    }
  }

  String _statusMomentLabel(TransactionModel tx) {
    switch (tx.status) {
      case TransactionStatus.received:
        return 'تاريخ التسليم';
      case TransactionStatus.cancelled:
        return 'تاريخ الإلغاء';
      case TransactionStatus.added:
        return 'تاريخ الحركة';
    }
  }

  bool _isTrigger(TransactionModel tx) {
    if (tx.status != TransactionStatus.received &&
        tx.status != TransactionStatus.cancelled) {
      return false;
    }

    switch (_statusFilter) {
      case _TriggerStatusFilter.all:
        return true;
      case _TriggerStatusFilter.received:
        return tx.status == TransactionStatus.received;
      case _TriggerStatusFilter.cancelled:
        return tx.status == TransactionStatus.cancelled;
    }
  }

  bool _matchesDateRange(DateTime d) {
    if (!_useDateRange) return true;
    final start = DateTime(
      _dateRange.start.year,
      _dateRange.start.month,
      _dateRange.start.day,
    );
    final end = DateTime(
      _dateRange.end.year,
      _dateRange.end.month,
      _dateRange.end.day,
      23,
      59,
      59,
      999,
    );
    return !d.isBefore(start) && !d.isAfter(end);
  }

  String _accountName(Map<int, String> accounts, int id) =>
      accounts[id] ?? 'حساب #$id';

  String _txKey(TransactionModel tx) {
    return '${tx.id}_${tx.accountId}_${tx.date.microsecondsSinceEpoch}_${tx.amount}_${tx.status.index}_${tx.beneficiary}';
  }

  double _txTotal(TransactionModel tx) => tx.amount + (tx.secondAmount ?? 0.0);

  String _txAmountLabel(TransactionModel tx) {
    final main = '${_formatAmount(tx.amount)} ${tx.currency}';
    if (tx.secondAmount != null && tx.secondAmount! > 0) {
      final secondCurrency = (tx.secondCurrency?.trim().isNotEmpty ?? false)
          ? tx.secondCurrency!.trim()
          : tx.currency;
      return '$main + ${_formatAmount(tx.secondAmount!)} $secondCurrency';
    }
    return main;
  }

  String _safeFileName(String value) {
    final cleaned = value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'transaction_watch' : cleaned;
  }

  String _exportName() {
    final now = DateTime.now();
    final stamp =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    return _safeFileName('transaction_watch_$stamp');
  }

  // ==========================
  // Detection
  // ==========================

  _WatchDataset _buildDataset({
    required List<TransactionModel> transactions,
    required List<Account> accounts,
  }) {
    final accountMap = {for (final a in accounts) a.id: a.name};
    final groups = <String, List<TransactionModel>>{};
    final displayNames = <String, String>{};

    for (final tx in transactions) {
      final normalized = _normalizeName(tx.beneficiary);
      if (normalized.isEmpty) continue;
      groups.putIfAbsent(normalized, () => <TransactionModel>[]).add(tx);
      displayNames.putIfAbsent(normalized, () => _cleanName(tx.beneficiary));
    }

    final cases = <_WatchCase>[];

    for (final entry in groups.entries) {
      final sorted = entry.value.toList()
        ..sort((a, b) {
          final cmp = a.date.compareTo(b.date);
          if (cmp != 0) return cmp;
          return a.id.compareTo(b.id);
        });

      final openMap = <String, TransactionModel>{};
      final triggerMap = <String, TransactionModel>{};

      for (final trigger in sorted.where(_isTrigger)) {
        final triggerMoment = _statusMoment(trigger);
        if (!_matchesDateRange(triggerMoment)) continue;

        final priorOpen = sorted.where((candidate) {
          if (candidate.status != TransactionStatus.added) return false;
          if (candidate.id == trigger.id &&
              candidate.accountId == trigger.accountId)
            return false;
          return candidate.date.isBefore(trigger.date) ||
              candidate.date.isAtSameMomentAs(trigger.date);
        }).toList();

        if (priorOpen.isEmpty) continue;
        triggerMap[_txKey(trigger)] = trigger;
        for (final item in priorOpen) {
          openMap[_txKey(item)] = item;
        }
      }

      if (openMap.isEmpty || triggerMap.isEmpty) continue;

      final openItems = openMap.values.toList()
        ..sort((a, b) => a.date.compareTo(b.date));
      final triggers = triggerMap.values.toList()
        ..sort((a, b) => _statusMoment(b).compareTo(_statusMoment(a)));

      final item = _WatchCase(
        normalizedName: entry.key,
        displayName: displayNames[entry.key] ?? entry.key,
        openAdded: openItems,
        triggers: triggers,
      );

      if (_selectedAccountId != null &&
          !item.allTransactions.any(
            (tx) => tx.accountId == _selectedAccountId,
          )) {
        continue;
      }

      if (_query.isNotEmpty) {
        final normalizedQuery = _normalizeName(_query);
        final blob =
            '${item.normalizedName} ${item.displayName} '
            '${item.allTransactions.map((tx) => accountMap[tx.accountId] ?? '').join(' ')}';
        if (!blob.contains(normalizedQuery)) continue;
      }

      cases.add(item);
    }

    cases.sort((a, b) {
      switch (_sortMode) {
        case _WatchSortMode.newestTrigger:
          return b.lastTriggerDate.compareTo(a.lastTriggerDate);
        case _WatchSortMode.oldestTrigger:
          return a.lastTriggerDate.compareTo(b.lastTriggerDate);
        case _WatchSortMode.mostOpen:
          return b.openAdded.length.compareTo(a.openAdded.length);
        case _WatchSortMode.highestAmount:
          return b.totalOpenAmount.compareTo(a.totalOpenAmount);
        case _WatchSortMode.name:
          return a.displayName.compareTo(b.displayName);
      }
    });

    return _WatchDataset(
      cases: cases,
      accounts: accountMap,
      chartMetric: _chartMetric,
    );
  }

  // ==========================
  // Export / Copy
  // ==========================

  String _buildCopyText(_WatchDataset dataset) {
    final sb = StringBuffer();
    sb.writeln('تقرير مراقبة الحركات');
    sb.writeln('عدد الحالات: ${dataset.cases.length}');
    sb.writeln('الحركات القديمة المضافة: ${dataset.totalOpenMovements}');
    sb.writeln(
      'الحركات اللاحقة المستلمة/الملغاة: ${dataset.totalTriggerMovements}',
    );
    if (_useDateRange) {
      sb.writeln(
        'الفترة: ${_formatDay(_dateRange.start)} إلى ${_formatDay(_dateRange.end)}',
      );
    }
    sb.writeln('');

    for (var i = 0; i < dataset.cases.length; i++) {
      final item = dataset.cases[i];
      sb.writeln('${i + 1}) ${item.displayName}');
      sb.writeln(
        'الحسابات: ${item.accountIds.map((id) => _accountName(dataset.accounts, id)).join('، ')}',
      );
      sb.writeln('الحركات القديمة التي ما زالت مضافة:');
      for (var j = 0; j < item.openAdded.length; j++) {
        final tx = item.openAdded[j];
        sb.writeln(
          '- حركة ${j + 1}: ${_txAmountLabel(tx)} | ${_formatDateTime(tx.date)} | ${_accountName(dataset.accounts, tx.accountId)}',
        );
      }
      sb.writeln('الحركات اللاحقة:');
      for (var j = 0; j < item.triggers.length; j++) {
        final tx = item.triggers[j];
        sb.writeln(
          '- حركة ${j + 1}: ${_statusLabel(tx.status)} | ${_txAmountLabel(tx)} | تاريخ الحركة ${_formatDateTime(tx.date)} | ${_statusMomentLabel(tx)} ${_formatDateTime(_statusMoment(tx))} | ${_accountName(dataset.accounts, tx.accountId)}',
        );
      }
      sb.writeln('');
    }

    return sb.toString().trim();
  }

  Future<void> _copyReport(_WatchDataset dataset) async {
    await Clipboard.setData(ClipboardData(text: _buildCopyText(dataset)));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم نسخ تقرير المراقبة كنص')));
  }

  Future<void> _exportExcel(_WatchDataset dataset) async {
    if (_exporting) return;
    setState(() => _exporting = true);

    try {
      final book = xls.Excel.createExcel();
      final summary = book['الملخص'];
      summary.appendRow([
        xls.TextCellValue('البند'),
        xls.TextCellValue('القيمة'),
      ]);
      summary.appendRow([
        xls.TextCellValue('عدد الحالات'),
        xls.IntCellValue(dataset.cases.length),
      ]);
      summary.appendRow([
        xls.TextCellValue('الحركات القديمة المضافة'),
        xls.IntCellValue(dataset.totalOpenMovements),
      ]);
      summary.appendRow([
        xls.TextCellValue('الحركات اللاحقة'),
        xls.IntCellValue(dataset.totalTriggerMovements),
      ]);
      summary.appendRow([
        xls.TextCellValue('إجمالي مبلغ الحركات القديمة'),
        xls.DoubleCellValue(dataset.totalOpenAmount),
      ]);
      summary.appendRow([
        xls.TextCellValue('عدد الحسابات المتأثرة'),
        xls.IntCellValue(dataset.accountIds.length),
      ]);
      if (_useDateRange) {
        summary.appendRow([
          xls.TextCellValue('الفترة'),
          xls.TextCellValue(
            '${_formatDay(_dateRange.start)} إلى ${_formatDay(_dateRange.end)}',
          ),
        ]);
      }

      final casesSheet = book['الحالات'];
      casesSheet.appendRow(
        [
          'الاسم',
          'عدد الحركات القديمة المضافة',
          'عدد الحركات اللاحقة',
          'إجمالي مبالغ الحركات القديمة',
          'آخر تاريخ تسليم/إلغاء',
          'الحسابات',
        ].map((v) => xls.TextCellValue(v)).toList(),
      );

      for (final item in dataset.cases) {
        casesSheet.appendRow([
          xls.TextCellValue(item.displayName),
          xls.IntCellValue(item.openAdded.length),
          xls.IntCellValue(item.triggers.length),
          xls.DoubleCellValue(item.totalOpenAmount),
          xls.TextCellValue(_formatDateTime(item.lastTriggerDate)),
          xls.TextCellValue(
            item.accountIds
                .map((id) => _accountName(dataset.accounts, id))
                .join('، '),
          ),
        ]);
      }

      final rowsSheet = book['تفاصيل الحركات'];
      rowsSheet.appendRow(
        [
          'الاسم',
          'نوع الحركة في التقرير',
          'الحساب',
          'رقم الحركة',
          'الحالة',
          'المبلغ الأول',
          'العملة الأولى',
          'المبلغ الثاني',
          'العملة الثانية',
          'تاريخ الحركة',
          'تاريخ التسليم',
          'تاريخ الإلغاء',
          'ملاحظة',
        ].map((v) => xls.TextCellValue(v)).toList(),
      );

      for (final item in dataset.cases) {
        for (final tx in item.openAdded) {
          rowsSheet.appendRow(
            _excelTransactionRow(
              dataset: dataset,
              name: item.displayName,
              type: 'حركة قديمة ما زالت مضافة',
              tx: tx,
            ),
          );
        }
        for (final tx in item.triggers) {
          rowsSheet.appendRow(
            _excelTransactionRow(
              dataset: dataset,
              name: item.displayName,
              type: 'حركة لاحقة ${_statusLabel(tx.status)}',
              tx: tx,
            ),
          );
        }
      }

      final chartSheet = book['المخطط'];
      chartSheet.appendRow([
        xls.TextCellValue('التاريخ'),
        xls.TextCellValue(_chartMetricLabel(_chartMetric)),
      ]);
      for (final point in dataset.chartPoints) {
        chartSheet.appendRow([
          xls.TextCellValue(point.label),
          xls.DoubleCellValue(point.value),
        ]);
      }

      final bytes = book.encode();
      if (bytes == null) throw Exception('تعذر إنشاء ملف Excel');

      final fileBaseName = _exportName();
      String savedMessage;

      final savedPath = await _saveExcelReport(
        baseName: fileBaseName,
        bytes: Uint8List.fromList(bytes),
      );

      if (savedPath == null || savedPath.trim().isEmpty) {
        savedMessage = 'تم تصدير تقرير المراقبة إلى Excel';
      } else {
        savedMessage = 'تم حفظ تقرير المراقبة في: $savedPath';
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(savedMessage)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('فشل التصدير: $e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<String?> _saveExcelReport({
    required String baseName,
    required Uint8List bytes,
  }) async {
    if (kIsWeb) {
      return FileSaver.instance.saveFile(
        name: baseName,
        bytes: bytes,
        ext: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
    }

    return FileSaver.instance.saveAs(
      name: baseName,
      bytes: bytes,
      ext: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
  }

  List<xls.CellValue> _excelTransactionRow({
    required _WatchDataset dataset,
    required String name,
    required String type,
    required TransactionModel tx,
  }) {
    return [
      xls.TextCellValue(name),
      xls.TextCellValue(type),
      xls.TextCellValue(_accountName(dataset.accounts, tx.accountId)),
      xls.IntCellValue(tx.id),
      xls.TextCellValue(_statusLabel(tx.status)),
      xls.DoubleCellValue(tx.amount),
      xls.TextCellValue(tx.currency),
      tx.secondAmount == null
          ? xls.TextCellValue('')
          : xls.DoubleCellValue(tx.secondAmount!),
      xls.TextCellValue(tx.secondCurrency ?? ''),
      xls.TextCellValue(_formatDateTime(tx.date)),
      xls.TextCellValue(
        tx.receivedAt == null ? '' : _formatDateTime(tx.receivedAt!),
      ),
      xls.TextCellValue(
        tx.cancelledAt == null ? '' : _formatDateTime(tx.cancelledAt!),
      ),
      xls.TextCellValue(tx.notes),
    ];
  }

  // ==========================
  // Pickers
  // ==========================

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _dateRange,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'اختر فترة المراقبة',
      confirmText: 'اعتماد',
      cancelText: 'إلغاء',
      saveText: 'اعتماد',
    );

    if (picked != null) {
      setState(() {
        _dateRange = picked;
        _useDateRange = true;
      });
    }
  }

  // ==========================
  // UI
  // ==========================

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<TransactionModel>>(
      valueListenable: DatabaseService.transactionsBox.listenable(),
      builder: (context, txBox, _) {
        return ValueListenableBuilder<Box<Account>>(
          valueListenable: DatabaseService.accountsBox.listenable(),
          builder: (context, accountBox, __) {
            final officeAccounts =
                accountBox.values
                    .where((account) => account.type == AccountType.office)
                    .toList()
                  ..sort((a, b) => a.name.compareTo(b.name));
            final officeAccountIds = officeAccounts
                .map((account) => account.id)
                .toSet();
            final dataset = _buildDataset(
              transactions: txBox.values
                  .where((tx) => officeAccountIds.contains(tx.accountId))
                  .toList(),
              accounts: officeAccounts,
            );

            return _buildScaffold(
              context: context,
              dataset: dataset,
              accounts: officeAccounts,
            );
          },
        );
      },
    );
  }

  Widget _buildScaffold({
    required BuildContext context,
    required _WatchDataset dataset,
    required List<Account> accounts,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(cs.primaryContainer, cs.surface, isDark ? .86 : .72) ??
                  cs.surface,
              cs.surface,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  child: _buildHeader(dataset),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: _buildSearchAndFilters(accounts),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                  child: _buildStats(dataset),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _showChart
                        ? _buildChartCard(dataset)
                        : _buildCollapsedChartCard(),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                  child: _buildActions(dataset),
                ),
              ),
              if (dataset.cases.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyState(),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 100),
                  sliver: SliverList.separated(
                    itemCount: dataset.cases.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = dataset.cases[index];
                      return TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: Duration(
                          milliseconds: 220 + math.min(index, 8) * 35,
                        ),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, child) {
                          return Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(0, 14 * (1 - value)),
                              child: child,
                            ),
                          );
                        },
                        child: _buildCaseCard(item, dataset.accounts, index),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(_WatchDataset dataset) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [
                cs.primary.withOpacity(isDark ? .30 : .16),
                cs.tertiary.withOpacity(isDark ? .22 : .12),
                cs.surface.withOpacity(isDark ? .66 : .88),
              ],
            ),
            border: Border.all(
              color: Colors.white.withOpacity(isDark ? .08 : .7),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? .28 : .07),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          cs.primary,
                          Color.lerp(cs.primary, cs.tertiary, .45) ??
                              cs.primary,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: cs.primary.withOpacity(.26),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.radar_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'مراقبة الحركات',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                            height: 1.05,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'تكتشف الاسم الذي لديه حركة قديمة مضافة ثم ظهرت له حركة لاحقة مستلمة أو ملغاة.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _HeaderPill(
                    icon: Icons.warning_amber_rounded,
                    label: '${dataset.cases.length} حالة',
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  _HeaderPill(
                    icon: Icons.pending_actions_rounded,
                    label: '${dataset.totalOpenMovements} مضافة',
                    color: const Color(0xFF2F80ED),
                  ),
                  const SizedBox(width: 8),
                  _HeaderPill(
                    icon: Icons.done_all_rounded,
                    label: '${dataset.totalTriggerMovements} لاحقة',
                    color: const Color(0xFF00A76F),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchAndFilters(List<Account> accounts) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        TextField(
          controller: _searchCtrl,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'ابحث بالاسم أو الحساب...',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'مسح البحث',
                    onPressed: () => _searchCtrl.clear(),
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              _FilterChipButton(
                label: _selectedAccountId == null
                    ? 'كل الحسابات'
                    : accounts
                          .firstWhere(
                            (a) => a.id == _selectedAccountId,
                            orElse: () => Account(
                              id: _selectedAccountId!,
                              name: 'حساب #$_selectedAccountId',
                            ),
                          )
                          .name,
                icon: Icons.account_circle_outlined,
                selected: _selectedAccountId != null,
                onTap: () => _showAccountSheet(accounts),
              ),
              const SizedBox(width: 8),
              _FilterChipButton(
                label: _statusFilterLabel(_statusFilter),
                icon: Icons.task_alt_rounded,
                selected: _statusFilter != _TriggerStatusFilter.all,
                onTap: _showStatusSheet,
              ),
              const SizedBox(width: 8),
              _FilterChipButton(
                label: _useDateRange
                    ? '${_formatDay(_dateRange.start)} → ${_formatDay(_dateRange.end)}'
                    : 'كل التواريخ',
                icon: Icons.date_range_rounded,
                selected: _useDateRange,
                onTap: _showDateSheet,
              ),
              const SizedBox(width: 8),
              _FilterChipButton(
                label: _sortLabel(_sortMode),
                icon: Icons.sort_rounded,
                selected: true,
                onTap: _showSortSheet,
              ),
              const SizedBox(width: 8),
              _FilterChipButton(
                label: _showDetails ? 'التفاصيل ظاهرة' : 'التفاصيل مخفية',
                icon: _showDetails
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                selected: _showDetails,
                onTap: () => setState(() => _showDetails = !_showDetails),
              ),
              const SizedBox(width: 8),
              _FilterChipButton(
                label: _showChart ? 'الغرافيك ظاهر' : 'الغرافيك مخفي',
                icon: Icons.area_chart_rounded,
                selected: _showChart,
                onTap: () => setState(() => _showChart = !_showChart),
              ),
            ],
          ),
        ),
        if (_selectedAccountId != null ||
            _statusFilter != _TriggerStatusFilter.all ||
            _useDateRange)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    _selectedAccountId = null;
                    _statusFilter = _TriggerStatusFilter.all;
                    _useDateRange = false;
                  });
                },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('إزالة الفلاتر'),
                style: TextButton.styleFrom(foregroundColor: cs.primary),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStats(_WatchDataset dataset) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = math.max((constraints.maxWidth - 10) / 2, 150.0);
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: itemWidth,
              child: _StatCard(
                title: 'الحالات المكتشفة',
                value: '${dataset.cases.length}',
                subtitle: 'أسماء تحتاج متابعة',
                icon: Icons.manage_search_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: _StatCard(
                title: 'مضافة قديمة',
                value: '${dataset.totalOpenMovements}',
                subtitle: 'لم تصبح مستلمة بعد',
                icon: Icons.pending_actions_rounded,
                color: const Color(0xFF2F80ED),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: _StatCard(
                title: 'حركات لاحقة',
                value: '${dataset.totalTriggerMovements}',
                subtitle: 'مستلمة أو ملغاة',
                icon: Icons.bolt_rounded,
                color: const Color(0xFF8B5CF6),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: _StatCard(
                title: 'مبلغ المضافة',
                value: _formatAmount(dataset.totalOpenAmount),
                subtitle: '${dataset.accountIds.length} حساب متأثر',
                icon: Icons.payments_rounded,
                color: const Color(0xFFFF8A00),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActions(_WatchDataset dataset) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: dataset.cases.isEmpty || _exporting
                ? null
                : () => _exportExcel(dataset),
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.table_chart_rounded),
            label: const Text('Excel'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: dataset.cases.isEmpty
                ? null
                : () => _copyReport(dataset),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('نسخ كنص'),
          ),
        ),
      ],
    );
  }

  Widget _buildCollapsedChartCard() {
    final cs = Theme.of(context).colorScheme;
    return _GlassCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.area_chart_rounded, color: cs.primary),
        title: const Text('الغرافيك مخفي'),
        subtitle: const Text('اضغط من الفلاتر لإظهاره مرة ثانية'),
      ),
    );
  }

  Widget _buildChartCard(_WatchDataset dataset) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final points = dataset.chartPoints;

    return _GlassCard(
      key: const ValueKey('chart_visible'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ارتفاع الحالات حسب التاريخ',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'يعرض فقط التواريخ التي تحتوي على حركات من هذه الحالة.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_ChartMetric>(
                tooltip: 'نوع الغرافيك',
                initialValue: _chartMetric,
                onSelected: (value) => setState(() => _chartMetric = value),
                itemBuilder: (context) => _ChartMetric.values
                    .map(
                      (item) => PopupMenuItem(
                        value: item,
                        child: Text(_chartMetricLabel(item)),
                      ),
                    )
                    .toList(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune_rounded, size: 18, color: cs.primary),
                      const SizedBox(width: 5),
                      Text(
                        _chartMetricLabel(_chartMetric),
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (points.isEmpty)
            Container(
              height: 190,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withOpacity(.35),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Text(
                'لا توجد بيانات كافية للرسم',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            )
          else
            SizedBox(height: 220, child: LineChart(_chartData(points))),
          const SizedBox(height: 8),
          if (points.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniInfoPill(
                  icon: Icons.auto_graph_rounded,
                  text:
                      'أعلى قيمة: ${_formatChartValue(points.map((e) => e.value).reduce(math.max))}',
                  color: cs.primary,
                ),
                _MiniInfoPill(
                  icon: Icons.event_available_rounded,
                  text: '${points.length} تاريخ فقط',
                  color: const Color(0xFF8B5CF6),
                ),
              ],
            ),
        ],
      ),
    );
  }

  LineChartData _chartData(List<_ChartPoint> points) {
    final cs = Theme.of(context).colorScheme;
    final maxY = math.max(1.0, points.map((e) => e.value).reduce(math.max));
    final spots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].value),
    ];

    final maxIndex = points.indexWhere((p) => p.value == maxY);

    return LineChartData(
      minX: 0,
      maxX: math.max(0, points.length - 1).toDouble(),
      minY: 0,
      maxY: maxY + (maxY * .28),
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: math.max(1.0, maxY / 4),
        getDrawingHorizontalLine: (_) =>
            FlLine(color: cs.outlineVariant.withOpacity(.45), strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 34,
            interval: math.max(1.0, maxY / 4),
            getTitlesWidget: (value, meta) {
              if (value < 0) return const SizedBox.shrink();
              return Text(
                value.toInt().toString(),
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              );
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 34,
            interval: points.length <= 5
                ? 1
                : math.max(1, (points.length / 4).floor()).toDouble(),
            getTitlesWidget: (value, meta) {
              final index = value.round();
              if (index < 0 || index >= points.length)
                return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  points[index].shortLabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              );
            },
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        handleBuiltInTouches: true,
        touchTooltipData: LineTouchTooltipData(
          tooltipRoundedRadius: 14,
          getTooltipItems: (items) => items.map((item) {
            final index = item.x.round();
            final label = index >= 0 && index < points.length
                ? points[index].label
                : '';
            return LineTooltipItem(
              '$label\n${_formatChartValue(item.y)}',
              TextStyle(
                color: cs.onInverseSurface,
                fontWeight: FontWeight.w800,
              ),
            );
          }).toList(),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: points.length > 2,
          curveSmoothness: .25,
          barWidth: 3.2,
          color: cs.primary,
          belowBarData: BarAreaData(
            show: true,
            color: cs.primary.withOpacity(.12),
          ),
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, bar, index) {
              final isMax = index == maxIndex;
              return FlDotCirclePainter(
                radius: isMax ? 5.6 : 3.8,
                color: isMax ? const Color(0xFF8B5CF6) : cs.primary,
                strokeWidth: isMax ? 3 : 2,
                strokeColor: Theme.of(context).colorScheme.surface,
              );
            },
          ),
        ),
      ],
      extraLinesData: ExtraLinesData(
        horizontalLines: [
          HorizontalLine(
            y: maxY,
            color: const Color(0xFF8B5CF6).withOpacity(.45),
            strokeWidth: 1,
            dashArray: [6, 5],
          ),
        ],
      ),
    );
  }

  Widget _buildCaseCard(_WatchCase item, Map<int, String> accounts, int index) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final firstTrigger = item.triggers.isNotEmpty ? item.triggers.first : null;

    return _GlassCard(
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
                  shape: BoxShape.circle,
                  color: cs.primary.withOpacity(.12),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: cs.primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      item.accountIds
                          .map((id) => _accountName(accounts, id))
                          .join('، '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (firstTrigger != null)
                _StatusBadge(
                  label: _statusLabel(firstTrigger.status),
                  color: _statusColor(firstTrigger.status),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MiniInfoPill(
                icon: Icons.pending_rounded,
                text: '${item.openAdded.length} مضافة قديمة',
                color: const Color(0xFF2F80ED),
              ),
              _MiniInfoPill(
                icon: Icons.bolt_rounded,
                text: '${item.triggers.length} لاحقة',
                color: const Color(0xFF8B5CF6),
              ),
              _MiniInfoPill(
                icon: Icons.payments_rounded,
                text: _formatAmount(item.totalOpenAmount),
                color: const Color(0xFFFF8A00),
              ),
              _MiniInfoPill(
                icon: Icons.schedule_rounded,
                text: _formatDay(item.lastTriggerDate),
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
          if (_showDetails) ...[
            const SizedBox(height: 14),
            _SectionTitle(
              title: 'الحركات القديمة التي ما زالت مضافة',
              icon: Icons.pending_actions_rounded,
              color: const Color(0xFF2F80ED),
            ),
            const SizedBox(height: 8),
            ...item.openAdded.asMap().entries.map(
              (entry) => _buildMovementRow(
                tx: entry.value,
                accounts: accounts,
                index: entry.key + 1,
                accent: const Color(0xFF2F80ED),
                prefix: 'حركة قديمة',
              ),
            ),
            const SizedBox(height: 12),
            _SectionTitle(
              title: 'الحركات اللاحقة التي سببت التنبيه',
              icon: Icons.done_all_rounded,
              color: const Color(0xFF8B5CF6),
            ),
            const SizedBox(height: 8),
            ...item.triggers.asMap().entries.map(
              (entry) => _buildMovementRow(
                tx: entry.value,
                accounts: accounts,
                index: entry.key + 1,
                accent: _statusColor(entry.value.status),
                prefix: 'حركة لاحقة',
                showStatusMoment: true,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMovementRow({
    required TransactionModel tx,
    required Map<int, String> accounts,
    required int index,
    required Color accent,
    required String prefix,
    bool showStatusMoment = false,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(.42),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withOpacity(.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withOpacity(.13),
            ),
            alignment: Alignment.center,
            child: Text(
              '$index',
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$prefix • ${_statusLabel(tx.status)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      _txAmountLabel(tx),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  _accountName(accounts, tx.accountId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      'تاريخ الحركة: ${_formatDateTime(tx.date)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    if (showStatusMoment)
                      Text(
                        '${_statusMomentLabel(tx)}: ${_formatDateTime(_statusMoment(tx))}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                if (tx.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    tx.notes.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 120),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primary.withOpacity(.10),
            ),
            child: Icon(Icons.verified_rounded, size: 42, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(
            'لا توجد حالات مراقبة حالياً',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'لم يتم العثور على اسم لديه حركة قديمة حالتها مضافة وبعدها حركة أحدث مستلمة أو ملغاة ضمن الفلاتر الحالية.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================
  // Bottom sheets
  // ==========================

  Future<void> _showAccountSheet(List<Account> accounts) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            children: [
              _SheetTitle(
                title: 'فلترة حسب الحساب',
                icon: Icons.account_circle_outlined,
              ),
              ListTile(
                leading: const Icon(Icons.all_inclusive_rounded),
                title: const Text('كل الحسابات'),
                trailing: _selectedAccountId == null
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  setState(() => _selectedAccountId = null);
                  Navigator.pop(context);
                },
              ),
              ...accounts.map(
                (account) => ListTile(
                  leading: const Icon(Icons.account_balance_wallet_outlined),
                  title: Text(account.name),
                  trailing: _selectedAccountId == account.id
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () {
                    setState(() => _selectedAccountId = account.id);
                    Navigator.pop(context);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showStatusSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            children: [
              _SheetTitle(
                title: 'نوع الحركة اللاحقة',
                icon: Icons.task_alt_rounded,
              ),
              for (final item in _TriggerStatusFilter.values)
                ListTile(
                  title: Text(_statusFilterLabel(item)),
                  trailing: _statusFilter == item
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () {
                    setState(() => _statusFilter = item);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSortSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            children: [
              _SheetTitle(title: 'ترتيب النتائج', icon: Icons.sort_rounded),
              for (final item in _WatchSortMode.values)
                ListTile(
                  title: Text(_sortLabel(item)),
                  trailing: _sortMode == item
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () {
                    setState(() => _sortMode = item);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showDateSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SheetTitle(
                  title: 'فترة المراقبة',
                  icon: Icons.date_range_rounded,
                ),
                ListTile(
                  leading: const Icon(Icons.all_inclusive_rounded),
                  title: const Text('كل التواريخ'),
                  trailing: !_useDateRange
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () {
                    setState(() => _useDateRange = false);
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.edit_calendar_rounded),
                  title: Text(
                    '${_formatDay(_dateRange.start)} → ${_formatDay(_dateRange.end)}',
                  ),
                  subtitle: const Text('اختيار فترة مخصصة'),
                  trailing: _useDateRange
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    await _pickDateRange();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _statusFilterLabel(_TriggerStatusFilter value) {
    switch (value) {
      case _TriggerStatusFilter.all:
        return 'مستلمة وملغاة';
      case _TriggerStatusFilter.received:
        return 'مستلمة فقط';
      case _TriggerStatusFilter.cancelled:
        return 'ملغاة فقط';
    }
  }

  String _sortLabel(_WatchSortMode value) {
    switch (value) {
      case _WatchSortMode.newestTrigger:
        return 'الأحدث أولاً';
      case _WatchSortMode.oldestTrigger:
        return 'الأقدم أولاً';
      case _WatchSortMode.mostOpen:
        return 'الأكثر حركات مضافة';
      case _WatchSortMode.highestAmount:
        return 'الأعلى مبلغاً';
      case _WatchSortMode.name:
        return 'حسب الاسم';
    }
  }

  String _chartMetricLabel(_ChartMetric value) {
    switch (value) {
      case _ChartMetric.alerts:
        return 'عدد التنبيهات';
      case _ChartMetric.openMovements:
        return 'عدد المضافة القديمة';
      case _ChartMetric.openAmount:
        return 'مبالغ المضافة';
    }
  }

  String _formatChartValue(double value) {
    if (_chartMetric == _ChartMetric.openAmount) return _formatAmount(value);
    return value.toInt().toString();
  }
}

class _WatchCase {
  final String normalizedName;
  final String displayName;
  final List<TransactionModel> openAdded;
  final List<TransactionModel> triggers;

  const _WatchCase({
    required this.normalizedName,
    required this.displayName,
    required this.openAdded,
    required this.triggers,
  });

  List<TransactionModel> get allTransactions => [...openAdded, ...triggers];

  List<int> get accountIds {
    final ids = allTransactions.map((tx) => tx.accountId).toSet().toList();
    ids.sort();
    return ids;
  }

  DateTime get lastTriggerDate {
    if (triggers.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    DateTime moment(TransactionModel tx) {
      switch (tx.status) {
        case TransactionStatus.received:
          return tx.receivedAt ?? tx.date;
        case TransactionStatus.cancelled:
          return tx.cancelledAt ?? tx.date;
        case TransactionStatus.added:
          return tx.date;
      }
    }

    return triggers.map(moment).reduce((a, b) => a.isAfter(b) ? a : b);
  }

  double get totalOpenAmount => openAdded.fold<double>(
    0,
    (sum, tx) => sum + tx.amount + (tx.secondAmount ?? 0.0),
  );
}

class _WatchDataset {
  final List<_WatchCase> cases;
  final Map<int, String> accounts;
  final _ChartMetric chartMetric;

  const _WatchDataset({
    required this.cases,
    required this.accounts,
    required this.chartMetric,
  });

  int get totalOpenMovements =>
      cases.fold<int>(0, (sum, item) => sum + item.openAdded.length);
  int get totalTriggerMovements =>
      cases.fold<int>(0, (sum, item) => sum + item.triggers.length);
  double get totalOpenAmount =>
      cases.fold<double>(0, (sum, item) => sum + item.totalOpenAmount);

  List<int> get accountIds {
    final ids = <int>{};
    for (final item in cases) {
      ids.addAll(item.accountIds);
    }
    final list = ids.toList()..sort();
    return list;
  }

  DateTime _statusMoment(TransactionModel tx) {
    switch (tx.status) {
      case TransactionStatus.received:
        return tx.receivedAt ?? tx.date;
      case TransactionStatus.cancelled:
        return tx.cancelledAt ?? tx.date;
      case TransactionStatus.added:
        return tx.date;
    }
  }

  String _dayKey(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  String _shortDayKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return key;
    return '${parts[2]}/${parts[1]}';
  }

  List<_ChartPoint> get chartPoints {
    final values = <String, double>{};

    for (final item in cases) {
      for (final trigger in item.triggers) {
        final key = _dayKey(_statusMoment(trigger));
        switch (chartMetric) {
          case _ChartMetric.alerts:
            values[key] = (values[key] ?? 0) + 1;
            break;
          case _ChartMetric.openMovements:
            values[key] = (values[key] ?? 0) + item.openAdded.length;
            break;
          case _ChartMetric.openAmount:
            values[key] = (values[key] ?? 0) + item.totalOpenAmount;
            break;
        }
      }
    }

    final keys = values.keys.toList()..sort();
    return [
      for (final key in keys)
        _ChartPoint(
          label: key,
          shortLabel: _shortDayKey(key),
          value: values[key] ?? 0,
        ),
    ];
  }
}

class _ChartPoint {
  final String label;
  final String shortLabel;
  final double value;

  const _ChartPoint({
    required this.label,
    required this.shortLabel,
    required this.value,
  });
}

class _GlassCard extends StatelessWidget {
  final Widget child;

  const _GlassCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: cs.surface.withOpacity(isDark ? .72 : .92),
        border: Border.all(color: Colors.white.withOpacity(isDark ? .07 : .7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? .20 : .06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _HeaderPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _HeaderPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withOpacity(.15)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChipButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? cs.primary.withOpacity(.12)
                : cs.surfaceContainerHighest.withOpacity(.75),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? cs.primary.withOpacity(.24)
                  : cs.outlineVariant.withOpacity(.45),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: cs.surface.withOpacity(isDark ? .68 : .95),
        border: Border.all(color: color.withOpacity(.13)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? .16 : .045),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(.12),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniInfoPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _MiniInfoPill({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              color: color,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(.16)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;

  const _SectionTitle({
    required this.title,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            style: TextStyle(fontWeight: FontWeight.w900, color: color),
          ),
        ),
      ],
    );
  }
}

class _SheetTitle extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SheetTitle({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          Icon(icon, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}
