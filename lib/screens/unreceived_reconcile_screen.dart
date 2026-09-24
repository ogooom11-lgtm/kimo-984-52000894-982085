import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database_service.dart';
import '../models.dart';

class UnreceivedReconcileScreen extends StatefulWidget {
  final Account? account;
  final bool enableFuzzy;

  const UnreceivedReconcileScreen({
    super.key,
    this.account,
    this.enableFuzzy = true,
  });

  @override
  State<UnreceivedReconcileScreen> createState() =>
      _UnreceivedReconcileScreenState();
}

class _UnreceivedReconcileScreenState extends State<UnreceivedReconcileScreen> {
  int _currentStep = 0;
  bool _loading = false;
  bool _isManualMode = false;

  final List<String> _headers = [];
  final List<Map<String, dynamic>> _rows = [];

  final List<String> _selectedNameCols = [];
  final List<String> _selectedAmountCols = [];
  DateTimeRange? _selectedDateRange;

  final List<_PairedRow> _results = [];

  final List<_Item> _manualExcelItems = [];
  final List<_Item> _manualSysItems = [];

  final Map<String, Timer> _undoTimers = {};
  final Map<String, _Item> _pendingMatches = {};

  final Map<String, String> _excelDupNotes = {};
  final Map<String, String> _sysDupNotes = {};

  _ResultFilter _filter = _ResultFilter.all;
  final TextEditingController _resultsSearchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDateRange = DateTimeRange(
      start: now.subtract(const Duration(days: 1)),
      end: now,
    );
    _resultsSearchCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    for (final t in _undoTimers.values) {
      t.cancel();
    }
    _resultsSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickExcel() async {
    setState(() => _loading = true);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'xls', 'csv'],
        withData: true,
      );

      if (res == null || res.files.isEmpty) return;

      final bytes = res.files.first.bytes;
      final ext = res.files.first.extension?.toLowerCase() ?? '';
      if (bytes == null) return;

      await _parseFile(bytes, ext);
      if (!mounted) return;
      setState(() {
        _currentStep = 1;
      });
    } catch (e) {
      _showSnack('خطأ في قراءة الملف: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _parseFile(Uint8List bytes, String ext) async {
    _headers.clear();
    _rows.clear();
    _selectedNameCols.clear();
    _selectedAmountCols.clear();
    _results.clear();
    _manualExcelItems.clear();
    _manualSysItems.clear();
    _excelDupNotes.clear();
    _sysDupNotes.clear();
    _resultsSearchCtrl.clear();
    _filter = _ResultFilter.all;

    if (ext == 'csv') {
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter()
          .convert(text)
          .where((l) => l.trim().isNotEmpty)
          .toList();

      if (lines.isEmpty) return;

      _headers.addAll(lines.first.split(',').map((s) => s.trim()));
      for (int i = 1; i < lines.length; i++) {
        final cols = lines[i].split(',');
        final row = <String, dynamic>{};
        for (int c = 0; c < _headers.length; c++) {
          row[_headers[c]] = c < cols.length ? cols[c].trim() : null;
        }
        _rows.add(row);
      }
      return;
    }

    final excel = xls.Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) return;
    final table = excel.tables.values.first;
    if (table.maxRows <= 0) return;

    _headers.addAll(
      table.rows.first.map((e) => e?.value?.toString().trim() ?? ''),
    );

    for (int r = 1; r < table.rows.length; r++) {
      final cells = table.rows[r];
      final row = <String, dynamic>{};
      for (int c = 0; c < _headers.length; c++) {
        row[_headers[c]] = c < cells.length ? cells[c]?.value : null;
      }
      _rows.add(row);
    }
  }

  void _runReconcile() {
    setState(() => _loading = true);

    try {
      _results.clear();
      _manualExcelItems.clear();
      _manualSysItems.clear();
      _excelDupNotes.clear();
      _sysDupNotes.clear();

      final excelItems = _buildExcelItems();
      final pendingSystemItems = _buildSystemItems(onlyAdded: true);
      final historyItems = _buildSystemItems(onlyAdded: false);

      _detectExcelDuplicates(excelItems);
      _detectSystemDuplicates(pendingSystemItems);

      final usedPending = <String>{};
      final usedHistory = <String>{};

      for (final ex in excelItems) {
        final pendingExact = _findBestMatch(
          ex,
          pendingSystemItems,
          usedKeys: usedPending,
          requireMoneyExact: true,
          allowFuzzyName: widget.enableFuzzy,
        );

        if (pendingExact != null) {
          usedPending.add(pendingExact.identityKey);
          _results.add(
            _PairedRow(
              sys: pendingExact,
              excel: ex,
              kind: PairKind.matched,
              note: _mergeNotes(ex, pendingExact),
            ),
          );
          continue;
        }

        final pendingNameOnly = _findBestMatch(
          ex,
          pendingSystemItems,
          usedKeys: usedPending,
          requireMoneyExact: false,
          allowFuzzyName: widget.enableFuzzy,
        );

        if (pendingNameOnly != null) {
          usedPending.add(pendingNameOnly.identityKey);
          _results.add(
            _PairedRow(
              sys: pendingNameOnly,
              excel: ex,
              kind: PairKind.amountMismatch,
              note: _mergeNotes(ex, pendingNameOnly),
            ),
          );
          continue;
        }

        final histExact = _findBestMatch(
          ex,
          historyItems,
          usedKeys: usedHistory,
          requireMoneyExact: true,
          allowFuzzyName: widget.enableFuzzy,
        );

        if (histExact != null) {
          usedHistory.add(histExact.identityKey);
          final kind = histExact.ref?.status == TransactionStatus.cancelled
              ? PairKind.historyCancelled
              : PairKind.historyReceived;
          _results.add(
            _PairedRow(
              sys: histExact,
              excel: ex,
              kind: kind,
              note: _mergeNotes(ex, histExact),
            ),
          );
          continue;
        }

        _results.add(
          _PairedRow(
            sys: null,
            excel: ex,
            kind: PairKind.excelOnly,
            note: _excelDupNotes[ex.identityKey],
          ),
        );
      }

      for (final s in pendingSystemItems) {
        if (!usedPending.contains(s.identityKey)) {
          _results.add(
            _PairedRow(
              sys: s,
              excel: null,
              kind: PairKind.sysPending,
              note: _sysDupNotes[s.identityKey],
            ),
          );
        }
      }

      _results.sort((a, b) {
        final pa = a.priority;
        final pb = b.priority;
        if (pa != pb) return pa.compareTo(pb);

        final da = a.displayMoment;
        final db = b.displayMoment;
        return db.compareTo(da);
      });

      _manualExcelItems
        ..clear()
        ..addAll(
          _results
              .where((r) => r.kind == PairKind.excelOnly)
              .map((r) => r.excel!)
              .toList(),
        );

      _manualSysItems
        ..clear()
        ..addAll(
          _results
              .where((r) => r.kind == PairKind.sysPending)
              .map((r) => r.sys!)
              .toList(),
        );

      setState(() {
        _loading = false;
        _currentStep = 3;
        _isManualMode = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
      _showSnack('حدث خطأ أثناء المطابقة: $e', isError: true);
    }
  }

  List<_Item> _buildExcelItems() {
    final items = <_Item>[];

    for (int i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      String rawName = _selectedNameCols
          .map((h) => row[h]?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .join(' ')
          .trim();

      if (rawName.isEmpty) {
        rawName = 'بدون اسم';
      }

      final parts = <_MoneyPart>[];
      for (final amtCol in _selectedAmountCols) {
        final amount = _parseAmount(row[amtCol]);
        if (amount != null && amount > 0) {
          final rawCurrency = _extractCurrencyFromHeader(amtCol);
          parts.add(
            _MoneyPart(
              amount: amount,
              rawCurrency: rawCurrency,
              currency: _normCurrency(rawCurrency),
            ),
          );
        }
      }

      items.add(
        _Item(
          source: _ItemSource.excel,
          identityKey: 'excel:${i + 2}',
          name: _normName(rawName),
          rawName: rawName,
          amounts: parts,
          ref: null,
          rowNumber: i + 2,
        ),
      );
    }

    return items;
  }

  List<_Item> _buildSystemItems({required bool onlyAdded}) {
    final box = DatabaseService.transactionsBox;
    final accountId = widget.account?.id;

    bool inHistoryWindow(TransactionModel t) {
      if (_selectedDateRange == null) return true;
      final target = t.status == TransactionStatus.received
          ? (t.receivedAt ?? t.date)
          : t.status == TransactionStatus.cancelled
          ? (t.cancelledAt ?? t.date)
          : t.date;

      final start = DateTime(
        _selectedDateRange!.start.year,
        _selectedDateRange!.start.month,
        _selectedDateRange!.start.day,
      );
      final end = DateTime(
        _selectedDateRange!.end.year,
        _selectedDateRange!.end.month,
        _selectedDateRange!.end.day,
        23,
        59,
        59,
      );
      return !target.isBefore(start) && !target.isAfter(end);
    }

    return box.values.where((t) {
      final isAcct = accountId == null || t.accountId == accountId;
      final isAdded = t.status == TransactionStatus.added;
      if (onlyAdded) return isAcct && isAdded;
      return isAcct && !isAdded && inHistoryWindow(t);
    }).map((t) {
      final parts = <_MoneyPart>[
        _MoneyPart(
          amount: t.amount,
          rawCurrency: t.currency,
          currency: _normCurrency(t.currency),
        ),
      ];

      if (t.secondAmount != null && t.secondAmount! > 0) {
        final secondCurr = _secondCurrencyOf(t);
        parts.add(
          _MoneyPart(
            amount: t.secondAmount!,
            rawCurrency: secondCurr,
            currency: _normCurrency(secondCurr),
          ),
        );
      }

      return _Item(
        source: _ItemSource.system,
        identityKey: 'sys:${t.key ?? t.id}',
        name: _normName(t.beneficiary),
        rawName: t.beneficiary,
        amounts: parts,
        ref: t,
        rowNumber: -1,
      );
    }).toList();
  }

  void _detectExcelDuplicates(List<_Item> excelItems) {
    final groups = <String, List<_Item>>{};
    for (final item in excelItems) {
      groups.putIfAbsent(item.signatureKey, () => []).add(item);
    }

    for (final entry in groups.entries) {
      if (entry.value.length <= 1) continue;
      final rows = entry.value.map((e) => e.rowNumber).join('، ');
      for (final item in entry.value) {
        _excelDupNotes[item.identityKey] = 'مكرر في الملف في الصفوف: $rows';
      }
    }
  }

  void _detectSystemDuplicates(List<_Item> sysItems) {
    final groups = <String, List<_Item>>{};
    for (final item in sysItems) {
      groups.putIfAbsent(item.signatureKey, () => []).add(item);
    }

    for (final entry in groups.entries) {
      if (entry.value.length <= 1) continue;
      for (final item in entry.value) {
        _sysDupNotes[item.identityKey] =
        'مكرر في النظام بعدد ${entry.value.length}';
      }
    }
  }

  _Item? _findBestMatch(
      _Item excel,
      List<_Item> pool, {
        required Set<String> usedKeys,
        required bool requireMoneyExact,
        required bool allowFuzzyName,
      }) {
    final candidates = pool.where((sys) {
      if (usedKeys.contains(sys.identityKey)) return false;

      final nameScore = _nameSimilarity(excel.name, sys.name);
      if (nameScore < (allowFuzzyName ? 0.78 : 0.99)) return false;

      if (requireMoneyExact) {
        return _moneyListsExactlyMatch(excel.amounts, sys.amounts);
      }
      return true;
    }).toList();

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final an = _nameSimilarity(excel.name, a.name);
      final bn = _nameSimilarity(excel.name, b.name);
      if (bn != an) return bn.compareTo(an);

      final ad = _moneyDistance(excel.amounts, a.amounts);
      final bd = _moneyDistance(excel.amounts, b.amounts);
      return ad.compareTo(bd);
    });

    return candidates.first;
  }

  bool _moneyListsExactlyMatch(List<_MoneyPart> a, List<_MoneyPart> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].currency != b[i].currency) return false;
      if (!_sameMoney(a[i].amount, b[i].amount)) return false;
    }
    return true;
  }

  double _moneyDistance(List<_MoneyPart> a, List<_MoneyPart> b) {
    final maxLen = a.length > b.length ? a.length : b.length;
    double score = 0;
    for (int i = 0; i < maxLen; i++) {
      final av = i < a.length ? a[i].amount : 0.0;
      final bv = i < b.length ? b[i].amount : 0.0;
      score += (av - bv).abs();
    }
    return score;
  }

  bool _sameMoney(double a, double b) => (a - b).abs() < 0.05;

  String? _mergeNotes(_Item? excel, _Item? sys) {
    final notes = <String>[];
    if (excel != null && _excelDupNotes[excel.identityKey] != null) {
      notes.add(_excelDupNotes[excel.identityKey]!);
    }
    if (sys != null && _sysDupNotes[sys.identityKey] != null) {
      notes.add(_sysDupNotes[sys.identityKey]!);
    }
    return notes.isEmpty ? null : notes.join('\n');
  }

  void _onDropSystemOnExcel(_Item sys, _Item excel) {
    setState(() {
      _manualSysItems.removeWhere((e) => e.identityKey == sys.identityKey);
      _pendingMatches[excel.identityKey] = sys;
      _undoTimers[excel.identityKey]?.cancel();
      _undoTimers[excel.identityKey] = Timer(
        const Duration(seconds: 3),
            () => _finalizeMatch(excel, sys),
      );
    });
  }

  void _undoMatch(String excelKey) {
    final timer = _undoTimers[excelKey];
    if (timer != null && timer.isActive) {
      timer.cancel();
    }
    _undoTimers.remove(excelKey);

    final sys = _pendingMatches.remove(excelKey);
    if (sys != null) {
      setState(() {
        _manualSysItems.add(sys);
      });
    }
  }

  void _finalizeMatch(_Item excel, _Item sys) {
    if (!mounted) return;

    final kind = _moneyListsExactlyMatch(excel.amounts, sys.amounts)
        ? PairKind.matched
        : PairKind.amountMismatch;

    setState(() {
      _undoTimers.remove(excel.identityKey);
      _pendingMatches.remove(excel.identityKey);
      _manualExcelItems.removeWhere((e) => e.identityKey == excel.identityKey);
      _manualSysItems.removeWhere((e) => e.identityKey == sys.identityKey);

      _results.removeWhere(
            (r) =>
        (r.excel?.identityKey == excel.identityKey &&
            r.kind == PairKind.excelOnly) ||
            (r.sys?.identityKey == sys.identityKey &&
                r.kind == PairKind.sysPending),
      );

      _results.insert(
        0,
        _PairedRow(
          sys: sys,
          excel: excel,
          kind: kind,
          note: _mergeNotes(excel, sys),
        ),
      );
    });

    _showSnack(kind == PairKind.matched ? 'تمت المطابقة' : 'تمت مطابقة مع اختلاف');
  }

  String _normName(String s) {
    var t = s.trim().toLowerCase();

    const arabicFrom = ['أ', 'إ', 'آ', 'ة', 'ى', 'ؤ', 'ئ'];
    const arabicTo = ['ا', 'ا', 'ا', 'ه', 'ي', 'و', 'ي'];
    for (int i = 0; i < arabicFrom.length; i++) {
      t = t.replaceAll(arabicFrom[i], arabicTo[i]);
    }

    t = t.replaceAll(
      RegExp(r'[^\w\u0600-\u06FF\s]+', unicode: true),
      ' ',
    );
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  String _extractCurrencyFromHeader(String header) {
    var h = header.trim();
    final lower = h.toLowerCase();

    if (lower.contains('qar') || h.contains('قطري') || h.contains('ريال')) {
      return 'ريال قطري';
    }
    if (lower.contains('syp') || h.contains('سوري')) {
      return 'ليرة سورية';
    }
    if (lower.contains('usd') || h.contains('دولار')) {
      return 'دولار';
    }
    if (lower.contains('eur') || h.contains('يورو')) {
      return 'يورو';
    }
    if (lower.contains('try') || h.contains('تركي') || h.contains('ليرة تركية')) {
      return 'ليرة تركية';
    }

    h = h
        .replaceAll(RegExp(r'(?i)amount|amt|value|sum'), '')
        .replaceAll('المبلغ', '')
        .replaceAll('مبلغ', '')
        .trim();

    return h.isEmpty ? header.trim() : h;
  }

  String _normCurrency(String s) {
    final t = _normName(s);

    if (t.contains('ريال قطري') || t == 'qar' || t == 'qr' || t == 'قطري') {
      return 'qar';
    }
    if (t.contains('ليره سوريه') || t.contains('ليرة سورية') || t == 'syp') {
      return 'syp';
    }
    if (t.contains('دولار') || t == 'usd') {
      return 'usd';
    }
    if (t.contains('يورو') || t == 'eur') {
      return 'eur';
    }
    if (t.contains('ليره تركيه') || t == 'try' || t == 'tl') {
      return 'try';
    }

    return t;
  }

  String _secondCurrencyOf(TransactionModel t) {
    try {
      final value = (t as dynamic).secondCurrency;
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    } catch (_) {}
    return t.currency;
  }

  double? _parseAmount(dynamic v) {
    if (v == null) return null;
    String s = v.toString();
    const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    for (int i = 0; i < arabic.length; i++) {
      s = s.replaceAll(arabic[i], i.toString());
    }

    s = s.replaceAll('٬', '');
    s = s.replaceAll(' ', '');
    s = s.replaceAllMapped(RegExp(r'(?<=\d),(?=\d{2}$)'), (_) => '.');
    s = s.replaceAll(RegExp(r'[^\d\.\-]+'), '');

    return double.tryParse(s);
  }

  double _nameSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (a.contains(b) || b.contains(a)) return 0.90;

    final at = a.split(' ').where((e) => e.isNotEmpty).toSet();
    final bt = b.split(' ').where((e) => e.isNotEmpty).toSet();
    if (at.isEmpty || bt.isEmpty) return 0.0;

    final inter = at.intersection(bt).length.toDouble();
    final union = at.union(bt).length.toDouble();
    return union == 0 ? 0.0 : inter / union;
  }

  String _formatMoney(double amount) {
    final fixed = amount.toStringAsFixed(2);
    final parts = fixed.split('.');
    final intPart = parts[0];
    final dec = parts.length > 1 ? parts[1] : '00';

    final rev = intPart.split('').reversed.join();
    final chunks = <String>[];
    for (int i = 0; i < rev.length; i += 3) {
      final end = (i + 3 < rev.length) ? i + 3 : rev.length;
      chunks.add(rev.substring(i, end));
    }
    return '${chunks.join(',').split('').reversed.join()}.$dec';
  }

  String _formatDate(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  String _formatDateTime(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${_formatDate(d)}  $hh:$mm';
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade800 : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack('تم النسخ');
  }

  String _formatItemAmounts(_Item item) {
    if (item.amounts.isEmpty) return 'بدون مبلغ';
    return item.amounts
        .map((e) => '${_formatMoney(e.amount)} ${e.rawCurrency}')
        .join('\n');
  }

  void _handleCopyCategory(List<_PairedRow> items) {
    final sb = StringBuffer();

    for (final item in items) {
      switch (item.kind) {
        case PairKind.matched:
          sb.writeln(
            '${item.sys!.rawName} | ${_formatItemAmounts(item.sys!)} | مطابق',
          );
          break;
        case PairKind.amountMismatch:
          sb.writeln(
            '${item.excel?.rawName ?? item.sys?.rawName ?? ""} | '
                'ملف: ${item.excel != null ? _formatItemAmounts(item.excel!) : "-"} | '
                'نظام: ${item.sys != null ? _formatItemAmounts(item.sys!) : "-"} | '
                'اختلاف بالمبلغ',
          );
          break;
        case PairKind.historyReceived:
          sb.writeln(
            '${item.excel!.rawName} | ${_formatItemAmounts(item.excel!)} | '
                'موجود بالأرشيف كمستلم',
          );
          break;
        case PairKind.historyCancelled:
          sb.writeln(
            '${item.excel!.rawName} | ${_formatItemAmounts(item.excel!)} | '
                'موجود بالأرشيف كملغي',
          );
          break;
        case PairKind.sysPending:
          sb.writeln(
            '${item.sys!.rawName} | ${_formatItemAmounts(item.sys!)} | '
                'معلق في النظام وغير موجود بالملف',
          );
          break;
        case PairKind.excelOnly:
          sb.writeln(
            '${item.excel!.rawName} | ${_formatItemAmounts(item.excel!)} | '
                'غير موجود في النظام | صف ${item.excel!.rowNumber}',
          );
          break;
      }
      if ((item.note ?? '').trim().isNotEmpty) {
        sb.writeln('ملاحظة: ${item.note}');
      }
      sb.writeln('---');
    }

    if (sb.isNotEmpty) {
      _copyToClipboard(sb.toString());
    }
  }

  List<_PairedRow> _filteredResults() {
    final query = _normName(_resultsSearchCtrl.text);
    final list = _results.where((r) {
      switch (_filter) {
        case _ResultFilter.all:
          break;
        case _ResultFilter.matched:
          if (r.kind != PairKind.matched) return false;
          break;
        case _ResultFilter.mismatch:
          if (r.kind != PairKind.amountMismatch) return false;
          break;
        case _ResultFilter.history:
          if (!(r.kind == PairKind.historyReceived ||
              r.kind == PairKind.historyCancelled)) {
            return false;
          }
          break;
        case _ResultFilter.sysOnly:
          if (r.kind != PairKind.sysPending) return false;
          break;
        case _ResultFilter.excelOnly:
          if (r.kind != PairKind.excelOnly) return false;
          break;
        case _ResultFilter.duplicates:
          if (!r.hasDuplicate) return false;
          break;
      }

      if (query.isEmpty) return true;

      final blob = _normName(
        [
          r.sys?.rawName ?? '',
          r.excel?.rawName ?? '',
          r.sys?.amounts.map((e) => e.amount.toString()).join(' ') ?? '',
          r.excel?.amounts.map((e) => e.amount.toString()).join(' ') ?? '',
          r.sys?.amounts.map((e) => e.rawCurrency).join(' ') ?? '',
          r.excel?.amounts.map((e) => e.rawCurrency).join(' ') ?? '',
          r.note ?? '',
          r.kind.label,
        ].join(' '),
      );
      return blob.contains(query);
    }).toList();

    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isManualMode ? 'مطابقة يدوية' : 'المطابقة الذكية'),
        centerTitle: true,
        actions: [
          if (_currentStep == 3 && !_isManualMode)
            IconButton(
              tooltip: 'إعادة البدء',
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: () {
                setState(() {
                  _currentStep = 0;
                  _headers.clear();
                  _rows.clear();
                  _results.clear();
                  _manualExcelItems.clear();
                  _manualSysItems.clear();
                  _excelDupNotes.clear();
                  _sysDupNotes.clear();
                  _resultsSearchCtrl.clear();
                  _selectedAmountCols.clear();
                  _selectedNameCols.clear();
                  _filter = _ResultFilter.all;
                });
              },
            ),
        ],
        leading: (_currentStep > 0 || _isManualMode)
            ? IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () {
            if (_isManualMode) {
              setState(() => _isManualMode = false);
            } else {
              setState(() => _currentStep--);
            }
          },
        )
            : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _isManualMode
                    ? _buildManualReconcileView()
                    : KeyedSubtree(
                  key: ValueKey(_currentStep),
                  child: _buildBody(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_currentStep) {
      case 0:
        return _buildStepUpload();
      case 1:
        return _buildStepNameMapping();
      case 2:
        return _buildStepAmountAndDate();
      case 3:
        return _buildStepResults();
      default:
        return const SizedBox();
    }
  }

  Widget _buildStepUpload() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    cs.primary.withOpacity(.18),
                    cs.secondary.withOpacity(.14),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.compare_arrows_rounded,
                size: 42,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'مطابقة كشف الحركات',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.account == null
                  ? 'ارفع ملف Excel لمطابقة كل الحسابات'
                  : 'الحساب المحدد: ${widget.account!.name}',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 30),
            InkWell(
              borderRadius: BorderRadius.circular(26),
              onTap: _pickExcel,
              child: Ink(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: cs.primary.withOpacity(.25)),
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      cs.primary.withOpacity(.12),
                      cs.surfaceContainerHigh,
                    ],
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer.withOpacity(.65),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.upload_file_rounded,
                        size: 48,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'اختر ملف Excel أو CSV',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'XLSX / XLS / CSV',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 22),
            _buildInfoCard(
              icon: Icons.info_outline_rounded,
              color: Colors.blue,
              text:
              'الصفحة ستعرض كل العناصر: المطابقة، المختلفة، الموجودة فقط في الملف، والمعلقة في النظام، مع كشف التكرار.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepNameMapping() {
    return _buildSelectionStep(
      title: 'تحديد أعمدة الاسم',
      subtitle: 'اختر عمودًا واحدًا أو أكثر لتكوين اسم المستفيد.',
      items: _headers,
      selected: _selectedNameCols,
      onToggle: (h) {
        setState(() {
          if (_selectedNameCols.contains(h)) {
            _selectedNameCols.remove(h);
          } else {
            _selectedNameCols.add(h);
          }
        });
      },
      onNext: _selectedNameCols.isNotEmpty
          ? () => setState(() => _currentStep = 2)
          : null,
    );
  }

  Widget _buildStepAmountAndDate() {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'أعمدة المبالغ وفترة الأرشيف',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'اختر أعمدة المبالغ من الملف. ترتيبها مهم، فالأول سيقارن مع المبلغ الأول والثاني مع المبلغ الثاني.',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: InkWell(
            onTap: () async {
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 365)),
                initialDateRange: _selectedDateRange,
              );
              if (picked != null && mounted) {
                setState(() => _selectedDateRange = picked);
              }
            },
            borderRadius: BorderRadius.circular(18),
            child: Ink(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.secondaryContainer.withOpacity(.35),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: cs.secondary.withOpacity(.22)),
              ),
              child: Row(
                children: [
                  Icon(Icons.date_range_rounded, color: cs.secondary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'فترة فحص الأرشيف',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: cs.secondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _selectedDateRange == null
                              ? 'الكل'
                              : '${_formatDate(_selectedDateRange!.start)}  ←  ${_formatDate(_selectedDateRange!.end)}',
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.edit_calendar_rounded),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            itemCount: _headers.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (ctx, i) {
              final h = _headers[i];
              if (_selectedNameCols.contains(h)) {
                return const SizedBox.shrink();
              }
              final isSelected = _selectedAmountCols.contains(h);

              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  setState(() {
                    if (isSelected) {
                      _selectedAmountCols.remove(h);
                    } else {
                      _selectedAmountCols.add(h);
                    }
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.green.withOpacity(.10)
                        : cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSelected
                          ? Colors.green.withOpacity(.55)
                          : cs.outlineVariant.withOpacity(.18),
                    ),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: isSelected
                            ? Colors.green.withOpacity(.15)
                            : cs.surfaceContainerHighest,
                        child: Icon(
                          Icons.payments_rounded,
                          size: 18,
                          color: isSelected ? Colors.green : cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              h,
                              style:
                              const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'مثال: ${_getSampleData(h, isNum: true)} | العملة المستنتجة: ${_extractCurrencyFromHeader(h)}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isSelected)
                        Chip(
                          label: Text('#${_selectedAmountCols.indexOf(h) + 1}'),
                          avatar: const Icon(Icons.check, size: 16),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: FilledButton.icon(
            onPressed: _selectedAmountCols.isNotEmpty ? _runReconcile : null,
            icon: const Icon(Icons.bolt_rounded),
            label: const Text('بدء المطابقة'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStepResults() {
    final cs = Theme.of(context).colorScheme;
    final filtered = _filteredResults();

    final matchedCount =
        _results.where((r) => r.kind == PairKind.matched).length;
    final mismatchCount =
        _results.where((r) => r.kind == PairKind.amountMismatch).length;
    final historyCount = _results
        .where((r) =>
    r.kind == PairKind.historyReceived ||
        r.kind == PairKind.historyCancelled)
        .length;
    final sysOnlyCount =
        _results.where((r) => r.kind == PairKind.sysPending).length;
    final excelOnlyCount =
        _results.where((r) => r.kind == PairKind.excelOnly).length;
    final duplicateCount = _results.where((r) => r.hasDuplicate).length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: cs.outlineVariant.withOpacity(.18)),
                ),
                child: TextField(
                  controller: _resultsSearchCtrl,
                  decoration: InputDecoration(
                    hintText: 'ابحث داخل النتائج...',
                    border: InputBorder.none,
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _resultsSearchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                      onPressed: _resultsSearchCtrl.clear,
                      icon: const Icon(Icons.close_rounded),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterChip(_ResultFilter.all, 'الكل', _results.length),
                    _buildFilterChip(
                      _ResultFilter.matched,
                      'مطابق',
                      matchedCount,
                      color: Colors.green,
                    ),
                    _buildFilterChip(
                      _ResultFilter.mismatch,
                      'اختلاف',
                      mismatchCount,
                      color: Colors.orange,
                    ),
                    _buildFilterChip(
                      _ResultFilter.history,
                      'في الأرشيف',
                      historyCount,
                      color: Colors.blueGrey,
                    ),
                    _buildFilterChip(
                      _ResultFilter.sysOnly,
                      'في النظام',
                      sysOnlyCount,
                      color: Colors.blue,
                    ),
                    _buildFilterChip(
                      _ResultFilter.excelOnly,
                      'في الملف',
                      excelOnlyCount,
                      color: Colors.red,
                    ),
                    _buildFilterChip(
                      _ResultFilter.duplicates,
                      'مكرر',
                      duplicateCount,
                      color: Colors.deepPurple,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: Text(
                      '${filtered.length} نتيجة',
                      key: ValueKey(filtered.length),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const Spacer(),
                  if (_manualSysItems.isNotEmpty && _manualExcelItems.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => setState(() => _isManualMode = true),
                      icon: const Icon(Icons.pan_tool_alt_rounded, size: 18),
                      label: const Text('مطابقة يدوية'),
                    ),
                  TextButton.icon(
                    onPressed:
                    filtered.isEmpty ? null : () => _handleCopyCategory(filtered),
                    icon: const Icon(Icons.copy_all_rounded, size: 18),
                    label: const Text('نسخ'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
            child: _buildInfoCard(
              icon: Icons.inbox_rounded,
              color: Colors.grey,
              text: 'لا توجد نتائج لهذا الفلتر أو البحث.',
            ),
          )
              : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (ctx, i) => TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 220 + (i * 25)),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return Transform.translate(
                  offset: Offset(0, (1 - value) * 16),
                  child: Opacity(opacity: value, child: child),
                );
              },
              child: _buildResultCard(filtered[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildManualReconcileView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: _buildInfoCard(
            icon: Icons.touch_app_rounded,
            color: Colors.indigo,
            text:
            'اسحب عنصر النظام إلى عنصر الملف للمطابقة. بعد الإفلات ستظهر مهلة 3 ثوانٍ للتراجع.',
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: Column(
                  children: [
                    _sectionHeader(
                      title: 'حركات الملف غير الموجودة',
                      count: _manualExcelItems.length,
                      color: Colors.red,
                    ),
                    Expanded(
                      child: _manualExcelItems.isEmpty
                          ? const Center(child: Text('تمت مطابقة كل عناصر الملف'))
                          : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        itemCount: _manualExcelItems.length,
                        itemBuilder: (context, index) {
                          final item = _manualExcelItems[index];
                          if (_pendingMatches.containsKey(item.identityKey)) {
                            return _buildPendingUndoCard(
                              item,
                              _pendingMatches[item.identityKey]!,
                            );
                          }
                          return _buildExcelTargetCard(item);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Container(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerLow
                      .withOpacity(.65),
                  child: Column(
                    children: [
                      _sectionHeader(
                        title: 'حركات النظام المعلقة',
                        count: _manualSysItems.length,
                        color: Colors.blue,
                      ),
                      Expanded(
                        child: _manualSysItems.isEmpty
                            ? const Center(child: Text('لا توجد عناصر معلقة'))
                            : ListView.builder(
                          padding:
                          const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          itemCount: _manualSysItems.length,
                          itemBuilder: (context, index) {
                            return _buildSystemDraggableCard(
                              _manualSysItems[index],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader({
    required String title,
    required int count,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Icon(Icons.circle, color: color, size: 10),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 8),
          Text('($count)', style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildExcelTargetCard(_Item item) {
    return DragTarget<_Item>(
      onWillAccept: (_) => true,
      onAccept: (sysItem) => _onDropSystemOnExcel(sysItem, item),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: hovering
                ? Colors.green.withOpacity(.10)
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: hovering
                  ? Colors.green
                  : Colors.red.withOpacity(.25),
              width: hovering ? 1.6 : 1,
            ),
            boxShadow: hovering
                ? [
              BoxShadow(
                color: Colors.green.withOpacity(.16),
                blurRadius: 16,
                offset: const Offset(0, 8),
              )
            ]
                : null,
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.red.withOpacity(.12),
                child: const Icon(
                  Icons.table_rows_rounded,
                  color: Colors.red,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.rawName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _formatItemAmounts(item),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'صف ${item.rowNumber}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    if ((_excelDupNotes[item.identityKey] ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: _noteChip(
                          _excelDupNotes[item.identityKey]!,
                          Colors.deepPurple,
                        ),
                      ),
                  ],
                ),
              ),
              if (hovering)
                const Icon(Icons.check_circle_rounded, color: Colors.green),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSystemDraggableCard(_Item item) {
    return LongPressDraggable<_Item>(
      data: item,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: MediaQuery.of(context).size.width * .84,
          child: _buildSourceBubble(
            label: 'النظام',
            item: item,
            color: Colors.blue,
            compact: true,
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: .30,
        child: _buildSystemCardContent(item),
      ),
      child: _buildSystemCardContent(item),
    );
  }

  Widget _buildSystemCardContent(_Item item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: _buildSourceBubble(
        label: 'النظام',
        item: item,
        color: Colors.blue,
      ),
    );
  }

  Widget _buildPendingUndoCard(_Item excel, _Item sys) {
    final exact = _moneyListsExactlyMatch(excel.amounts, sys.amounts);
    final color = exact ? Colors.green : Colors.orange;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: const Duration(seconds: 3),
      builder: (context, value, _) {
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withOpacity(.14),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withOpacity(.40)),
          ),
          child: Column(
            children: [
              LinearProgressIndicator(
                value: value,
                minHeight: 4,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation(color),
                borderRadius: BorderRadius.circular(999),
              ),
              ListTile(
                leading: Icon(
                  exact ? Icons.check_circle_rounded : Icons.warning_rounded,
                  color: color,
                ),
                title: Text(
                  exact ? 'تطابق ممتاز' : 'مطابقة مع اختلاف',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: Text(
                  'ملف: ${_formatItemAmounts(excel)}\nنظام: ${_formatItemAmounts(sys)}',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                trailing: FilledButton.tonalIcon(
                  onPressed: () => _undoMatch(excel.identityKey),
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('تراجع'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSelectionStep({
    required String title,
    required String subtitle,
    required List<String> items,
    required List<String> selected,
    required ValueChanged<String> onToggle,
    required VoidCallback? onNext,
  }) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(subtitle, style: TextStyle(color: cs.onSurfaceVariant)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final item = items[index];
              final isSel = selected.contains(item);

              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onToggle(item),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isSel
                        ? cs.primaryContainer.withOpacity(.85)
                        : cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSel
                          ? cs.primary
                          : cs.outlineVariant.withOpacity(.18),
                    ),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor:
                        isSel ? cs.primary : cs.surfaceContainerHighest,
                        child: Text(
                          String.fromCharCode(65 + index),
                          style: TextStyle(
                            color: isSel ? cs.onPrimary : cs.onSurface,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item,
                              style:
                              const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _getSampleData(item),
                              style: TextStyle(
                                fontSize: 11.5,
                                color: cs.onSurfaceVariant,
                              ),
                              maxLines: 1,
                            ),
                          ],
                        ),
                      ),
                      if (isSel)
                        Icon(Icons.check_circle_rounded, color: cs.primary),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text('التالي'),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(
      _ResultFilter filter,
      String label,
      int count, {
        Color? color,
      }) {
    final isSelected = _filter == filter;
    final cs = Theme.of(context).colorScheme;
    final accent = color ?? cs.primary;

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: FilterChip(
        label: Text('$label ($count)'),
        selected: isSelected,
        showCheckmark: false,
        selectedColor: accent,
        backgroundColor: accent.withOpacity(.10),
        labelStyle: TextStyle(
          color: isSelected ? Colors.white : accent,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(color: accent.withOpacity(.28)),
        ),
        onSelected: (_) => setState(() => _filter = filter),
      ),
    );
  }

  Widget _buildResultCard(_PairedRow row) {
    final data = row.viewData;
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: data.color.withOpacity(.28)),
        boxShadow: [
          BoxShadow(
            color: data.color.withOpacity(.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: CircleAvatar(
            backgroundColor: data.color.withOpacity(.12),
            child: Icon(data.icon, color: data.color),
          ),
          title: Text(
            data.title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15.5,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Text(
                data.shortLine,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _statusBadge(data.statusText, data.color),
                  if (row.excel != null && row.excel!.rowNumber > 0)
                    _statusBadge('صف ${row.excel!.rowNumber}', Colors.indigo),
                  if (row.hasDuplicate)
                    _statusBadge('يوجد تكرار', Colors.deepPurple),
                ],
              ),
            ],
          ),
          trailing: IconButton(
            tooltip: 'نسخ',
            onPressed: () => _copyToClipboard(data.copyText),
            icon: const Icon(Icons.copy_rounded, size: 20),
          ),
          children: [
            if (row.sys != null)
              _buildSourceBubble(
                label: 'النظام',
                item: row.sys!,
                color: Colors.blue,
              ),
            if (row.sys != null && row.excel != null)
              const SizedBox(height: 10),
            if (row.excel != null)
              _buildSourceBubble(
                label: 'الملف',
                item: row.excel!,
                color: Colors.red,
              ),
            if ((row.note ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildInfoCard(
                icon: Icons.priority_high_rounded,
                color: Colors.deepPurple,
                text: row.note!,
                dense: true,
              ),
            ],
            if (row.sys?.ref != null &&
                (row.kind == PairKind.historyReceived ||
                    row.kind == PairKind.historyCancelled)) ...[
              const SizedBox(height: 12),
              _buildInfoCard(
                icon: row.kind == PairKind.historyReceived
                    ? Icons.inventory_2_rounded
                    : Icons.cancel_rounded,
                color: row.kind == PairKind.historyReceived
                    ? Colors.blueGrey
                    : Colors.brown,
                text:
                '${row.kind == PairKind.historyReceived ? "تاريخ التسليم" : "تاريخ الإلغاء"}: ${_formatDateTime(row.sys!.displayMoment)}',
                dense: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSourceBubble({
    required String label,
    required _Item item,
    required Color color,
    bool compact = false,
  }) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.all(compact ? 12 : 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            color.withOpacity(.10),
            cs.surfaceContainerHighest.withOpacity(.55),
          ],
        ),
        border: Border.all(color: color.withOpacity(.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: compact ? 16 : 18,
            backgroundColor: color.withOpacity(.13),
            child: Icon(
              label == 'النظام'
                  ? Icons.account_balance_wallet_rounded
                  : Icons.table_rows_rounded,
              color: color,
              size: compact ? 16 : 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (item.rowNumber > 0)
                      Text(
                        'صف ${item.rowNumber}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  item.rawName,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 13 : 14,
                  ),
                ),
                const SizedBox(height: 8),
                ...item.amounts.map(
                      (m) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.72),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: color.withOpacity(.16)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.payments_rounded, size: 16, color: color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _formatMoney(m.amount),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          Text(
                            m.rawCurrency,
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (item.amounts.isEmpty)
                  Text(
                    'بدون مبلغ',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(.22)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
  Widget _noteChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(.24)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required Color color,
    required String text,
    bool dense = false,
  }) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(dense ? 12 : 14),
      decoration: BoxDecoration(
        color: color.withOpacity(.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: dense ? 18 : 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: dense ? 12 : 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getSampleData(String header, {bool isNum = false}) {
    if (_rows.isEmpty) return 'فارغ';
    for (final r in _rows.take(6)) {
      final v = r[header]?.toString();
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return 'فارغ';
  }
}

enum _ItemSource { excel, system }

class _MoneyPart {
  final double amount;
  final String rawCurrency;
  final String currency;

  const _MoneyPart({
    required this.amount,
    required this.rawCurrency,
    required this.currency,
  });
}

class _Item {
  final _ItemSource source;
  final String identityKey;
  final String name;
  final String rawName;
  final List<_MoneyPart> amounts;
  final TransactionModel? ref;
  final int rowNumber;

  const _Item({
    required this.source,
    required this.identityKey,
    required this.name,
    required this.rawName,
    required this.amounts,
    required this.ref,
    required this.rowNumber,
  });

  double get totalAmount =>
      amounts.isEmpty ? 0 : amounts.fold(0.0, (p, e) => p + e.amount);

  String get signatureKey {
    final moneySig = amounts
        .map((e) => '${e.amount.toStringAsFixed(2)}:${e.currency}')
        .join('|');
    return '${name}__${moneySig}';
  }

  DateTime get displayMoment {
    final t = ref;
    if (t == null) return DateTime.fromMillisecondsSinceEpoch(0);

    switch (t.status) {
      case TransactionStatus.received:
        return t.receivedAt ?? t.date;
      case TransactionStatus.cancelled:
        return t.cancelledAt ?? t.date;
      case TransactionStatus.added:
        return t.date;
    }
  }
}

enum PairKind {
  matched,
  amountMismatch,
  sysPending,
  historyReceived,
  historyCancelled,
  excelOnly,
}

enum _ResultFilter {
  all,
  matched,
  mismatch,
  history,
  sysOnly,
  excelOnly,
  duplicates,
}

extension on PairKind {
  String get label {
    switch (this) {
      case PairKind.matched:
        return 'مطابق';
      case PairKind.amountMismatch:
        return 'اختلاف مبلغ';
      case PairKind.sysPending:
        return 'معلق في النظام';
      case PairKind.historyReceived:
        return 'موجود بالأرشيف كمستلم';
      case PairKind.historyCancelled:
        return 'موجود بالأرشيف كملغي';
      case PairKind.excelOnly:
        return 'غير موجود في النظام';
    }
  }
}

class _PairedRow {
  final _Item? sys;
  final _Item? excel;
  final PairKind kind;
  final String? note;

  const _PairedRow({
    required this.sys,
    required this.excel,
    required this.kind,
    this.note,
  });

  bool get hasDuplicate => (note ?? '').contains('مكرر');

  int get priority {
    switch (kind) {
      case PairKind.amountMismatch:
        return 0;
      case PairKind.excelOnly:
        return 1;
      case PairKind.sysPending:
        return 2;
      case PairKind.historyCancelled:
        return 3;
      case PairKind.historyReceived:
        return 4;
      case PairKind.matched:
        return 5;
    }
  }

  DateTime get displayMoment {
    return sys?.displayMoment ??
        excel?.displayMoment ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  _RowViewData get viewData {
    String title;
    String shortLine;
    String statusText;
    Color color;
    IconData icon;

    switch (kind) {
      case PairKind.matched:
        title = sys?.rawName ?? excel?.rawName ?? 'مطابقة';
        shortLine =
        'النظام: ${sys != null ? sys!.amounts.map((e) => '${e.amount.toStringAsFixed(2)} ${e.rawCurrency}').join(' | ') : "-"}';
        statusText = 'مطابق';
        color = Colors.green;
        icon = Icons.check_circle_rounded;
        break;

      case PairKind.amountMismatch:
        title = excel?.rawName ?? sys?.rawName ?? 'اختلاف';
        shortLine =
        'الملف: ${excel != null ? excel!.amounts.map((e) => '${e.amount.toStringAsFixed(2)} ${e.rawCurrency}').join(' | ') : "-"}'
            '\nالنظام: ${sys != null ? sys!.amounts.map((e) => '${e.amount.toStringAsFixed(2)} ${e.rawCurrency}').join(' | ') : "-"}';
        statusText = 'اختلاف مبلغ';
        color = Colors.orange;
        icon = Icons.warning_rounded;
        break;

      case PairKind.historyReceived:
        title = excel?.rawName ?? sys?.rawName ?? 'أرشيف';
        shortLine = 'موجود في الأرشيف كمستلم';
        statusText = 'مستلم سابقًا';
        color = Colors.blueGrey;
        icon = Icons.inventory_2_rounded;
        break;

      case PairKind.historyCancelled:
        title = excel?.rawName ?? sys?.rawName ?? 'أرشيف';
        shortLine = 'موجود في الأرشيف كملغي';
        statusText = 'ملغي سابقًا';
        color = Colors.brown;
        icon = Icons.cancel_outlined;
        break;

      case PairKind.sysPending:
        title = sys?.rawName ?? 'معلق';
        shortLine = 'هذه الحركة موجودة في النظام وغير موجودة في الملف';
        statusText = 'في النظام فقط';
        color = Colors.blue;
        icon = Icons.hourglass_bottom_rounded;
        break;

      case PairKind.excelOnly:
        title = excel?.rawName ?? 'غير موجود';
        shortLine = 'هذا السطر موجود في الملف وغير موجود في النظام';
        statusText = 'في الملف فقط';
        color = Colors.red;
        icon = Icons.error_outline_rounded;
        break;
    }

    final copy = StringBuffer()
      ..writeln(title)
      ..writeln(shortLine);
    if ((note ?? '').trim().isNotEmpty) {
      copy.writeln(note);
    }

    return _RowViewData(
      title: title,
      shortLine: shortLine,
      statusText: statusText,
      color: color,
      icon: icon,
      copyText: copy.toString(),
    );
  }
}

class _RowViewData {
  final String title;
  final String shortLine;
  final String statusText;
  final Color color;
  final IconData icon;
  final String copyText;

  const _RowViewData({
    required this.title,
    required this.shortLine,
    required this.statusText,
    required this.color,
    required this.icon,
    required this.copyText,
  });
}