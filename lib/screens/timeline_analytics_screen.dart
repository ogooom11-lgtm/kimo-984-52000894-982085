import 'dart:io';
import 'dart:math' as math;
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

enum TimelineGraphPeriod { minute, hour, day, week, month, year }

enum TimelineGraphMetric { count, amount }

enum TimelineGraphSeries { added, received, cancelled, unreceived }

class TimelineAnalyticsScreen extends StatefulWidget {
  const TimelineAnalyticsScreen({super.key});

  @override
  State<TimelineAnalyticsScreen> createState() =>
      _TimelineAnalyticsScreenState();
}

class _TimelineAnalyticsScreenState extends State<TimelineAnalyticsScreen> {
  final GlobalKey _shotKey = GlobalKey();

  static const double _exportScale = 3.0;
  static const double _maxCanvasWidth = 980.0;

  TimelineGraphPeriod _period = TimelineGraphPeriod.hour;
  TimelineGraphMetric _metric = TimelineGraphMetric.count;

  DateTimeRange _dateRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 1)),
    end: DateTime.now(),
  );

  int? _selectedAccountId;
  String? _selectedCurrency;

  bool _busy = false;

  // show/hide
  bool _showHeader = false;
  bool _showMetaBar = false;
  bool _showSummaryCards = true;
  bool _showLegend = false;
  bool _showGrid = true;
  bool _showXAxis = true;
  bool _showYAxis = true;
  bool _showPoints = true;
  bool _showArea = true;
  bool _showMaxBadge = true;
  bool _showMaxGuide = true;
  bool _smoothLines = true;
  bool _trimEmptyEdges = true;

  bool _showAdded = true;
  bool _showReceived = false;
  bool _showCancelled = false;
  bool _showUnreceived = false;

  // ==========================
  // Time / date helpers
  // ==========================

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

  String _formatTimeOfDay(TimeOfDay t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _monthName(int m) {
    const names = [
      'يناير',
      'فبراير',
      'مارس',
      'أبريل',
      'مايو',
      'يونيو',
      'يوليو',
      'أغسطس',
      'سبتمبر',
      'أكتوبر',
      'نوفمبر',
      'ديسمبر',
    ];
    return names[m - 1];
  }

  String _monthShortName(int m) {
    const names = [
      'ينا',
      'فبر',
      'مار',
      'أبر',
      'ماي',
      'يون',
      'يول',
      'أغس',
      'سبت',
      'أكت',
      'نوف',
      'ديس',
    ];
    return names[m - 1];
  }

  String _periodLabel(TimelineGraphPeriod p) {
    switch (p) {
      case TimelineGraphPeriod.minute:
        return 'كل دقيقة';
      case TimelineGraphPeriod.hour:
        return 'كل ساعة';
      case TimelineGraphPeriod.day:
        return 'كل يوم';
      case TimelineGraphPeriod.week:
        return 'كل أسبوع';
      case TimelineGraphPeriod.month:
        return 'كل شهر';
      case TimelineGraphPeriod.year:
        return 'كل سنة';
    }
  }

  String _metricLabel() {
    switch (_metric) {
      case TimelineGraphMetric.count:
        return 'عدد الحركات';
      case TimelineGraphMetric.amount:
        return 'المبالغ';
    }
  }

  String _dateRangeLabel() {
    switch (_period) {
      case TimelineGraphPeriod.year:
        return '${_dateRange.start.year} → ${_dateRange.end.year}';
      case TimelineGraphPeriod.month:
        return '${_monthShortName(_dateRange.start.month)} ${_dateRange.start.year} → ${_monthShortName(_dateRange.end.month)} ${_dateRange.end.year}';
      case TimelineGraphPeriod.minute:
      case TimelineGraphPeriod.hour:
        return '${_formatDay(_dateRange.start)} ${_formatTime(_dateRange.start)} → ${_formatDay(_dateRange.end)} ${_formatTime(_dateRange.end)}';
      case TimelineGraphPeriod.day:
      case TimelineGraphPeriod.week:
        return '${_formatDay(_dateRange.start)} → ${_formatDay(_dateRange.end)}';
    }
  }

  String _datePickerTitle() {
    switch (_period) {
      case TimelineGraphPeriod.year:
        return 'السنوات';
      case TimelineGraphPeriod.month:
        return 'الأشهر';
      case TimelineGraphPeriod.minute:
      case TimelineGraphPeriod.hour:
        return 'التاريخ والساعة';
      case TimelineGraphPeriod.day:
      case TimelineGraphPeriod.week:
        return 'التاريخ';
    }
  }

  IconData _datePickerIcon() {
    switch (_period) {
      case TimelineGraphPeriod.year:
        return Icons.calendar_view_month_rounded;
      case TimelineGraphPeriod.month:
        return Icons.calendar_view_week_rounded;
      case TimelineGraphPeriod.minute:
      case TimelineGraphPeriod.hour:
        return Icons.more_time_rounded;
      case TimelineGraphPeriod.day:
      case TimelineGraphPeriod.week:
        return Icons.date_range_rounded;
    }
  }

  DateTime _startOfDay(DateTime d) {
    return DateTime(d.year, d.month, d.day);
  }

  DateTime _endOfDay(DateTime d) {
    return DateTime(d.year, d.month, d.day, 23, 59, 59, 999);
  }

  DateTime _endOfMonthDate(int year, int month) {
    return DateTime(year, month + 1, 0, 23, 59, 59, 999);
  }

  DateTime _endOfYearDate(int year) {
    return DateTime(year, 12, 31, 23, 59, 59, 999);
  }

  DateTimeRange _snapRangeToPeriod(
    DateTimeRange range,
    TimelineGraphPeriod period,
  ) {
    switch (period) {
      case TimelineGraphPeriod.year:
        return DateTimeRange(
          start: DateTime(range.start.year, 1, 1),
          end: _endOfYearDate(range.end.year),
        );
      case TimelineGraphPeriod.month:
        return DateTimeRange(
          start: DateTime(range.start.year, range.start.month, 1),
          end: _endOfMonthDate(range.end.year, range.end.month),
        );
      case TimelineGraphPeriod.minute:
      case TimelineGraphPeriod.hour:
        final start = range.start;
        final end = range.end.isAfter(start)
            ? range.end
            : start.add(const Duration(hours: 1));
        return DateTimeRange(start: start, end: end);
      case TimelineGraphPeriod.day:
        final start = _startOfDay(range.start);
        final end = range.end.isAfter(start)
            ? _endOfDay(range.end)
            : _endOfDay(start);
        return DateTimeRange(start: start, end: end);
      case TimelineGraphPeriod.week:
        return DateTimeRange(
          start: _startOfDay(range.start),
          end: _endOfDay(range.end),
        );
    }
  }

  DateTime _alignStart(DateTime d, TimelineGraphPeriod period) {
    switch (period) {
      case TimelineGraphPeriod.minute:
        return DateTime(d.year, d.month, d.day, d.hour, d.minute);
      case TimelineGraphPeriod.hour:
        return DateTime(d.year, d.month, d.day, d.hour);
      case TimelineGraphPeriod.day:
        return DateTime(d.year, d.month, d.day);
      case TimelineGraphPeriod.week:
        final normalized = DateTime(d.year, d.month, d.day);
        return normalized.subtract(Duration(days: normalized.weekday - 1));
      case TimelineGraphPeriod.month:
        return DateTime(d.year, d.month, 1);
      case TimelineGraphPeriod.year:
        return DateTime(d.year, 1, 1);
    }
  }

  DateTime _nextStep(DateTime d, TimelineGraphPeriod period) {
    switch (period) {
      case TimelineGraphPeriod.minute:
        return d.add(const Duration(minutes: 1));
      case TimelineGraphPeriod.hour:
        return d.add(const Duration(hours: 1));
      case TimelineGraphPeriod.day:
        return d.add(const Duration(days: 1));
      case TimelineGraphPeriod.week:
        return d.add(const Duration(days: 7));
      case TimelineGraphPeriod.month:
        return DateTime(d.year, d.month + 1, 1);
      case TimelineGraphPeriod.year:
        return DateTime(d.year + 1, 1, 1);
    }
  }

  List<_TimelineBucket> _buildBuckets() {
    final start = _alignStart(_dateRange.start, _period);
    final end = _dateRange.end;

    final buckets = <_TimelineBucket>[];
    DateTime current = start;

    while (!current.isAfter(end)) {
      final next = _nextStep(current, _period);
      final bucketEnd = next.subtract(const Duration(milliseconds: 1));

      buckets.add(
        _TimelineBucket(
          start: current,
          end: bucketEnd,
          label: _bucketFullLabel(current),
          shortLabel: _bucketShortLabel(current),
        ),
      );

      current = next;
    }

    return buckets;
  }

  String _bucketFullLabel(DateTime d) {
    switch (_period) {
      case TimelineGraphPeriod.minute:
        return '${_formatDay(d)} ${_formatTime(d)}';
      case TimelineGraphPeriod.hour:
        return '${_formatDay(d)} ${d.hour.toString().padLeft(2, '0')}:00';
      case TimelineGraphPeriod.day:
        return _formatDay(d);
      case TimelineGraphPeriod.week:
        final weekNo = _weekNumber(d);
        return 'الأسبوع $weekNo';
      case TimelineGraphPeriod.month:
        return '${_monthName(d.month)} ${d.year}';
      case TimelineGraphPeriod.year:
        return '${d.year}';
    }
  }

  String _bucketShortLabel(DateTime d) {
    switch (_period) {
      case TimelineGraphPeriod.minute:
        return _formatTime(d);
      case TimelineGraphPeriod.hour:
        return '${d.hour.toString().padLeft(2, '0')}:00';
      case TimelineGraphPeriod.day:
        return '${d.day}';
      case TimelineGraphPeriod.week:
        return 'أ${_weekNumber(d)}';
      case TimelineGraphPeriod.month:
        return _monthShortName(d.month);
      case TimelineGraphPeriod.year:
        return '${d.year}';
    }
  }

  int _weekNumber(DateTime d) {
    final firstDay = DateTime(d.year, 1, 1);
    final diff = d.difference(firstDay).inDays;
    return ((diff + firstDay.weekday) / 7).ceil();
  }

  bool _withinBucket(DateTime? d, _TimelineBucket bucket) {
    if (d == null) return false;
    final ms = d.millisecondsSinceEpoch;
    return ms >= bucket.start.millisecondsSinceEpoch &&
        ms <= bucket.end.millisecondsSinceEpoch;
  }

  bool _withinDateRange(DateTime d) {
    final ms = d.millisecondsSinceEpoch;
    return ms >= _dateRange.start.millisecondsSinceEpoch &&
        ms <= _dateRange.end.millisecondsSinceEpoch;
  }

  // ==========================
  // Data helpers
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

  List<String> _availableCurrencies(List<TransactionModel> allTx) {
    final set = <String>{};
    for (final t in allTx) {
      for (final part in _moneyPartsOf(t)) {
        final c = part.currency.trim();
        if (c.isNotEmpty) set.add(c);
      }
    }
    final out = set.toList()..sort();
    return out;
  }

  bool _matchesCurrency(TransactionModel t) {
    if (_selectedCurrency == null) return true;

    return _moneyPartsOf(
      t,
    ).any((p) => p.currency == _selectedCurrency && p.amount > 0);
  }

  double _amountOf(TransactionModel t) {
    double total = 0;
    for (final p in _moneyPartsOf(t)) {
      if (_selectedCurrency == null || p.currency == _selectedCurrency) {
        total += p.amount;
      }
    }
    return total;
  }

  List<TransactionModel> _baseTransactions(List<TransactionModel> allTx) {
    return allTx.where((t) {
      if (_selectedAccountId != null && t.accountId != _selectedAccountId) {
        return false;
      }

      if (!_matchesCurrency(t)) return false;
      return true;
    }).toList();
  }

  bool _isUnreceivedAsOf(TransactionModel t, DateTime end) {
    if (t.date.isAfter(end)) return false;

    if (!_withinDateRange(t.date)) return false;

    final receivedBefore = t.receivedAt != null && !t.receivedAt!.isAfter(end);
    final cancelledBefore =
        t.cancelledAt != null && !t.cancelledAt!.isAfter(end);

    return !receivedBefore && !cancelledBefore;
  }

  double _valueOfIterable(Iterable<TransactionModel> items) {
    if (_metric == TimelineGraphMetric.count) {
      return items.length.toDouble();
    }

    double total = 0;
    for (final t in items) {
      total += _amountOf(t);
    }
    return total;
  }

  _TimelineGraphData _buildGraphData({
    required List<Account> accounts,
    required List<TransactionModel> allTx,
  }) {
    final tx = _baseTransactions(allTx);
    final buckets = _buildBuckets();

    final addedValues = <double>[];
    final receivedValues = <double>[];
    final cancelledValues = <double>[];
    final unreceivedValues = <double>[];

    for (final bucket in buckets) {
      final added = tx.where(
        (t) => _withinDateRange(t.date) && _withinBucket(t.date, bucket),
      );

      final received = tx.where(
        (t) =>
            t.receivedAt != null &&
            _withinDateRange(t.receivedAt!) &&
            _withinBucket(t.receivedAt, bucket),
      );

      final cancelled = tx.where(
        (t) =>
            t.cancelledAt != null &&
            _withinDateRange(t.cancelledAt!) &&
            _withinBucket(t.cancelledAt, bucket),
      );

      final unreceived = tx.where((t) => _isUnreceivedAsOf(t, bucket.end));

      addedValues.add(_valueOfIterable(added));
      receivedValues.add(_valueOfIterable(received));
      cancelledValues.add(_valueOfIterable(cancelled));
      unreceivedValues.add(_valueOfIterable(unreceived));
    }

    final graphData = _TimelineGraphData(
      buckets: buckets,
      series: [
        _TimelineSeriesData(
          type: TimelineGraphSeries.added,
          label: 'مضافة',
          color: const Color(0xFF2563EB),
          visible: _showAdded,
          values: addedValues,
        ),
        _TimelineSeriesData(
          type: TimelineGraphSeries.received,
          label: 'مستلمة',
          color: const Color(0xFF059669),
          visible: _showReceived,
          values: receivedValues,
        ),
        _TimelineSeriesData(
          type: TimelineGraphSeries.cancelled,
          label: 'ملغاة',
          color: const Color(0xFFE11D48),
          visible: _showCancelled,
          values: cancelledValues,
        ),
        _TimelineSeriesData(
          type: TimelineGraphSeries.unreceived,
          label: 'باقي',
          color: const Color(0xFF7C3AED),
          visible: _showUnreceived,
          values: unreceivedValues,
        ),
      ],
    );

    final shouldTrimEmptyEdges =
        _trimEmptyEdges && _period != TimelineGraphPeriod.month;
    return shouldTrimEmptyEdges ? _trimEmptyEdgeBuckets(graphData) : graphData;
  }

  _TimelineGraphData _trimEmptyEdgeBuckets(_TimelineGraphData data) {
    if (data.buckets.isEmpty || data.visibleSeries.isEmpty) return data;

    bool hasValueAt(int index) {
      return data.visibleSeries.any(
        (s) => index < s.values.length && s.values[index] > 0,
      );
    }

    int first = 0;
    int last = data.buckets.length - 1;

    while (first <= last && !hasValueAt(first)) {
      first++;
    }
    while (last >= first && !hasValueAt(last)) {
      last--;
    }

    if (first > last) return data;
    if (first == 0 && last == data.buckets.length - 1) return data;

    return _TimelineGraphData(
      buckets: data.buckets.sublist(first, last + 1),
      series: data.series
          .map(
            (s) => _TimelineSeriesData(
              type: s.type,
              label: s.label,
              color: s.color,
              visible: s.visible,
              values: s.values.sublist(first, last + 1),
            ),
          )
          .toList(),
    );
  }

  _MaxPoint? _findMaxPoint(_TimelineGraphData data) {
    _MaxPoint? best;

    for (final series in data.visibleSeries) {
      for (int i = 0; i < series.values.length; i++) {
        final value = series.values[i];
        if (best == null || value > best.value) {
          best = _MaxPoint(series: series, index: i, value: value);
        }
      }
    }
    return best;
  }

  double _summaryValue(_TimelineSeriesData s) {
    if (s.values.isEmpty) return 0;
    if (s.type == TimelineGraphSeries.unreceived) {
      return s.values.last;
    }
    return s.values.fold(0.0, (a, b) => a + b);
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

  String _formatValue(double value) {
    if (_metric == TimelineGraphMetric.count) {
      return value.round().toString();
    }

    if (value.abs() >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value.abs() >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return _formatAmount(value);
  }

  // ==========================
  // Export
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

    void snack(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }

    try {
      final png = await _capturePng();
      if (png == null) {
        snack('تعذّر إنشاء الصورة');
        return;
      }

      final fileName =
          'timeline_graph_${DateTime.now().millisecondsSinceEpoch}';

      try {
        await FileSaver.instance.saveFile(
          name: fileName,
          bytes: png,
          ext: 'png',
          mimeType: MimeType.png,
        );
        snack('تم حفظ الصورة');
      } catch (e) {
        snack('فشل الحفظ: $e');
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
          snack('تم الحفظ لكن فشلت المشاركة: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ==========================
  // Pickers / Settings
  // ==========================

  Future<void> _pickDateRange() async {
    switch (_period) {
      case TimelineGraphPeriod.year:
        await _pickYearRange();
        return;
      case TimelineGraphPeriod.month:
        await _pickMonthRange();
        return;
      case TimelineGraphPeriod.minute:
      case TimelineGraphPeriod.hour:
        await _pickDateTimeRange(maxHours: 24);
        return;
      case TimelineGraphPeriod.day:
        await _pickLimitedDayRange(maxDays: 31);
        return;
      case TimelineGraphPeriod.week:
        break;
    }

    final now = DateTime.now();
    final firstDate = DateTime(
      math.min(2020, math.min(_dateRange.start.year, _dateRange.end.year)),
      1,
      1,
    );

    DateTime initialStart = _dateRange.start;
    DateTime initialEnd = _dateRange.end;

    if (initialStart.isBefore(firstDate)) initialStart = firstDate;
    if (initialEnd.isAfter(now)) initialEnd = now;
    if (initialStart.isAfter(initialEnd)) {
      initialStart = now.subtract(const Duration(days: 1));
      initialEnd = now;
    }

    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(
        start: _startOfDay(initialStart),
        end: _startOfDay(initialEnd),
      ),
      firstDate: firstDate,
      lastDate: now,
      helpText: 'اختر المدة',
      confirmText: 'اعتماد',
      cancelText: 'إلغاء',
      saveText: 'اعتماد',
    );

    if (picked != null) {
      setState(() {
        _dateRange = DateTimeRange(
          start: _startOfDay(picked.start),
          end: _endOfDay(picked.end),
        );
      });
    }
  }

  Future<void> _pickLimitedDayRange({required int maxDays}) async {
    final now = DateTime.now();
    final firstDate = DateTime(
      math.min(2020, math.min(_dateRange.start.year, _dateRange.end.year)),
      1,
      1,
    );

    DateTime startValue = _startOfDay(_dateRange.start);
    DateTime endValue = _startOfDay(_dateRange.end);

    if (startValue.isBefore(firstDate)) startValue = firstDate;
    if (endValue.isAfter(now)) endValue = _startOfDay(now);
    if (startValue.isAfter(endValue)) {
      startValue = _startOfDay(now);
      endValue = _startOfDay(now);
    }

    String fmt(DateTime d) => _formatDay(d);

    final picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setDialog) {
              final cs = Theme.of(context).colorScheme;

              String? validateRange() {
                if (startValue.isAfter(now)) {
                  return 'تاريخ البداية لا يمكن أن يكون في المستقبل';
                }
                if (endValue.isAfter(now)) {
                  return 'تاريخ النهاية لا يمكن أن يكون في المستقبل';
                }
                if (endValue.isBefore(startValue)) {
                  return 'تاريخ النهاية يجب أن يكون بعد تاريخ البداية';
                }

                final selectedDays = endValue.difference(startValue).inDays + 1;
                if (selectedDays > maxDays) {
                  return 'الفترة اليومية لا يمكن أن تتجاوز $maxDays يوم';
                }
                return null;
              }

              Future<void> pickDate({required bool isStart}) async {
                final current = isStart ? startValue : endValue;
                final safeInitial = current.isBefore(firstDate)
                    ? firstDate
                    : current.isAfter(now)
                    ? _startOfDay(now)
                    : current;

                final selected = await showDatePicker(
                  context: context,
                  initialDate: safeInitial,
                  firstDate: firstDate,
                  lastDate: now,
                  helpText: isStart ? 'تاريخ البداية' : 'تاريخ النهاية',
                  confirmText: 'اعتماد',
                  cancelText: 'إلغاء',
                );

                if (selected == null) return;
                setDialog(() {
                  final updated = _startOfDay(selected);
                  if (isStart) {
                    startValue = updated;
                  } else {
                    endValue = updated;
                  }
                });
              }

              Widget rangeCard({
                required String title,
                required DateTime value,
                required bool isStart,
                required IconData icon,
              }) {
                return Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                      colors: [
                        cs.primary.withOpacity(isStart ? .095 : .055),
                        cs.secondary.withOpacity(isStart ? .040 : .075),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: cs.outlineVariant.withOpacity(.16),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: cs.primary.withOpacity(.10),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Icon(icon, color: cs.primary, size: 18),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        fmt(value),
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => pickDate(isStart: isStart),
                        icon: const Icon(
                          Icons.calendar_month_rounded,
                          size: 18,
                        ),
                        label: const Text('اختيار التاريخ'),
                      ),
                    ],
                  ),
                );
              }

              final selectedDays = endValue.difference(startValue).inDays + 1;
              final rangeText = selectedDays > 0
                  ? '$selectedDays يوم'
                  : 'غير صالح';
              final validationMessage = validateRange();
              final canApply = validationMessage == null;

              return AlertDialog(
                backgroundColor: cs.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
                title: const Text(
                  'اختر الفترة اليومية',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                content: SizedBox(
                  width: 430,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: canApply
                              ? cs.primary.withOpacity(.08)
                              : cs.error.withOpacity(.08),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: canApply
                                ? cs.primary.withOpacity(.12)
                                : cs.error.withOpacity(.18),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.date_range_rounded,
                              color: canApply ? cs.primary : cs.error,
                              size: 17,
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                'المدة الحالية: $rangeText — الحد الأقصى $maxDays يوم',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: canApply ? cs.primary : cs.error,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      rangeCard(
                        title: 'من تاريخ',
                        value: startValue,
                        isStart: true,
                        icon: Icons.login_rounded,
                      ),
                      const SizedBox(height: 12),
                      rangeCard(
                        title: 'إلى تاريخ',
                        value: endValue,
                        isStart: false,
                        icon: Icons.logout_rounded,
                      ),
                      if (validationMessage != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          validationMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: cs.error,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('إلغاء'),
                  ),
                  FilledButton.icon(
                    onPressed: canApply
                        ? () {
                            Navigator.pop(
                              dialogContext,
                              DateTimeRange(
                                start: _startOfDay(startValue),
                                end: _endOfDay(endValue),
                              ),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('اعتماد'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (picked != null) {
      setState(() => _dateRange = picked);
    }
  }

  Future<void> _pickDateTimeRange({required int maxHours}) async {
    final now = DateTime.now();
    final firstDate = DateTime(
      math.min(2020, math.min(_dateRange.start.year, _dateRange.end.year)),
      1,
      1,
    );

    DateTime startValue = _dateRange.start;
    DateTime endValue = _dateRange.end;

    if (startValue.isBefore(firstDate)) startValue = firstDate;
    if (startValue.isAfter(now)) startValue = now;
    if (endValue.isAfter(now)) endValue = now;
    if (!endValue.isAfter(startValue)) {
      endValue = startValue.add(const Duration(hours: 1));
      if (endValue.isAfter(now)) endValue = now;
    }

    String fmt(DateTime d) => '${_formatDay(d)} ${_formatTime(d)}';
    final modeLabel = _period == TimelineGraphPeriod.minute
        ? 'بالدقيقة'
        : 'بالساعة';

    final picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setDialog) {
              final cs = Theme.of(context).colorScheme;

              String? validateRange() {
                if (startValue.isBefore(firstDate)) {
                  return 'وقت البداية خارج الفترة المتاحة';
                }
                if (startValue.isAfter(now)) {
                  return 'وقت البداية لا يمكن أن يكون في المستقبل';
                }
                if (endValue.isAfter(now)) {
                  return 'وقت النهاية لا يمكن أن يكون في المستقبل';
                }

                final minutes = endValue.difference(startValue).inMinutes;
                if (minutes <= 0) {
                  return 'وقت النهاية يجب أن يكون بعد وقت البداية';
                }
                if (minutes > maxHours * 60) {
                  return 'لا يمكن اختيار أكثر من $maxHours ساعة في العرض $modeLabel';
                }
                return null;
              }

              Future<void> pickDate({required bool isStart}) async {
                final current = isStart ? startValue : endValue;
                final safeInitial = current.isBefore(firstDate)
                    ? firstDate
                    : current.isAfter(now)
                    ? now
                    : current;

                final selected = await showDatePicker(
                  context: context,
                  initialDate: safeInitial,
                  firstDate: firstDate,
                  lastDate: now,
                  helpText: isStart ? 'تاريخ البداية' : 'تاريخ النهاية',
                  confirmText: 'اعتماد',
                  cancelText: 'إلغاء',
                );

                if (selected == null) return;
                setDialog(() {
                  final old = isStart ? startValue : endValue;
                  final updated = DateTime(
                    selected.year,
                    selected.month,
                    selected.day,
                    old.hour,
                    old.minute,
                  );
                  if (isStart) {
                    startValue = updated;
                  } else {
                    endValue = updated;
                  }
                });
              }

              Future<void> pickTime({required bool isStart}) async {
                final current = isStart ? startValue : endValue;
                final selected = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.fromDateTime(current),
                  helpText: isStart
                      ? 'ساعة البداية - نظام 24 ساعة'
                      : 'ساعة النهاية - نظام 24 ساعة',
                  confirmText: 'اعتماد',
                  cancelText: 'إلغاء',
                  builder: (context, child) {
                    return MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(alwaysUse24HourFormat: true),
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                );

                if (selected == null) return;
                setDialog(() {
                  final old = isStart ? startValue : endValue;
                  final updated = DateTime(
                    old.year,
                    old.month,
                    old.day,
                    selected.hour,
                    selected.minute,
                  );
                  if (isStart) {
                    startValue = updated;
                  } else {
                    endValue = updated;
                  }
                });
              }

              Widget rangeCard({
                required String title,
                required DateTime value,
                required bool isStart,
                required IconData icon,
              }) {
                return Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                      colors: [
                        cs.primary.withOpacity(isStart ? .095 : .055),
                        cs.secondary.withOpacity(isStart ? .040 : .075),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: cs.outlineVariant.withOpacity(.16),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: cs.primary.withOpacity(.10),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Icon(icon, color: cs.primary, size: 18),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        fmt(value),
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => pickDate(isStart: isStart),
                              icon: const Icon(
                                Icons.calendar_month_rounded,
                                size: 18,
                              ),
                              label: const Text('التاريخ'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => pickTime(isStart: isStart),
                              icon: const Icon(
                                Icons.schedule_rounded,
                                size: 18,
                              ),
                              label: const Text('الساعة'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }

              final totalMinutes = endValue.difference(startValue).inMinutes;
              final hoursText = totalMinutes > 0
                  ? '${(totalMinutes / 60).toStringAsFixed(totalMinutes % 60 == 0 ? 0 : 1)} ساعة'
                  : 'غير صالح';
              final validationMessage = validateRange();
              final canApply = validationMessage == null;

              return AlertDialog(
                backgroundColor: cs.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
                title: Text(
                  'اختر الفترة $modeLabel',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                content: SizedBox(
                  width: 430,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: canApply
                              ? cs.primary.withOpacity(.08)
                              : cs.error.withOpacity(.08),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: canApply
                                ? cs.primary.withOpacity(.12)
                                : cs.error.withOpacity(.18),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.timer_rounded,
                              color: canApply ? cs.primary : cs.error,
                              size: 17,
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                'المدة الحالية: $hoursText — الحد الأقصى $maxHours ساعة',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: canApply ? cs.primary : cs.error,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      rangeCard(
                        title: 'من تاريخ وساعة',
                        value: startValue,
                        isStart: true,
                        icon: Icons.login_rounded,
                      ),
                      const SizedBox(height: 12),
                      rangeCard(
                        title: 'إلى تاريخ وساعة',
                        value: endValue,
                        isStart: false,
                        icon: Icons.logout_rounded,
                      ),
                      if (validationMessage != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          validationMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: cs.error,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('إلغاء'),
                  ),
                  FilledButton.icon(
                    onPressed: canApply
                        ? () {
                            Navigator.pop(
                              dialogContext,
                              DateTimeRange(start: startValue, end: endValue),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('اعتماد'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (picked != null) {
      setState(() => _dateRange = picked);
    }
  }

  Future<void> _pickYearRange() async {
    final now = DateTime.now();
    final firstYear = math.min(
      2020,
      math.min(_dateRange.start.year, _dateRange.end.year),
    );

    int fromYear = _dateRange.start.year.clamp(firstYear, now.year).toInt();
    int toYear = _dateRange.end.year.clamp(firstYear, now.year).toInt();

    if (fromYear > toYear) {
      final temp = fromYear;
      fromYear = toYear;
      toYear = temp;
    }

    final years = [for (int y = firstYear; y <= now.year; y++) y];

    final picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setDialog) {
              final cs = Theme.of(context).colorScheme;

              DropdownButtonFormField<int> yearPicker({
                required String label,
                required int value,
                required ValueChanged<int> onChanged,
              }) {
                return DropdownButtonFormField<int>(
                  value: value,
                  decoration: InputDecoration(
                    labelText: label,
                    prefixIcon: const Icon(Icons.event_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  items: years
                      .map(
                        (y) =>
                            DropdownMenuItem<int>(value: y, child: Text('$y')),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) onChanged(v);
                  },
                );
              }

              return AlertDialog(
                backgroundColor: cs.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: const Text(
                  'اختر السنوات',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                content: SizedBox(
                  width: 340,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      yearPicker(
                        label: 'من سنة',
                        value: fromYear,
                        onChanged: (v) {
                          setDialog(() {
                            fromYear = v;
                            if (fromYear > toYear) toYear = fromYear;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      yearPicker(
                        label: 'إلى سنة',
                        value: toYear,
                        onChanged: (v) {
                          setDialog(() {
                            toYear = v;
                            if (toYear < fromYear) fromYear = toYear;
                          });
                        },
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('إلغاء'),
                  ),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(
                        dialogContext,
                        DateTimeRange(
                          start: DateTime(fromYear, 1, 1),
                          end: _endOfYearDate(toYear),
                        ),
                      );
                    },
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('اعتماد'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (picked != null) {
      setState(() => _dateRange = picked);
    }
  }

  Future<void> _pickMonthRange() async {
    final now = DateTime.now();
    final firstYear = math.min(
      2020,
      math.min(_dateRange.start.year, _dateRange.end.year),
    );

    int fromYear = _dateRange.start.year.clamp(firstYear, now.year).toInt();
    int toYear = _dateRange.end.year.clamp(firstYear, now.year).toInt();
    int fromMonth = _dateRange.start.month;
    int toMonth = _dateRange.end.month;

    if (fromYear == now.year && fromMonth > now.month) fromMonth = now.month;
    if (toYear == now.year && toMonth > now.month) toMonth = now.month;

    DateTime fromDate() => DateTime(fromYear, fromMonth, 1);
    DateTime toDate() => DateTime(toYear, toMonth, 1);

    if (fromDate().isAfter(toDate())) {
      toYear = fromYear;
      toMonth = fromMonth;
    }

    final years = [for (int y = firstYear; y <= now.year; y++) y];

    final picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (dialogContext) {
        String? error;

        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setDialog) {
              final cs = Theme.of(context).colorScheme;

              List<int> monthsForYear(int year) {
                final maxMonth = year == now.year ? now.month : 12;
                return [for (int m = 1; m <= maxMonth; m++) m];
              }

              void normalizeMonths() {
                final fromMonths = monthsForYear(fromYear);
                final toMonths = monthsForYear(toYear);
                if (!fromMonths.contains(fromMonth)) {
                  fromMonth = fromMonths.last;
                }
                if (!toMonths.contains(toMonth)) {
                  toMonth = toMonths.last;
                }
              }

              DropdownButtonFormField<int> yearPicker({
                required String label,
                required int value,
                required ValueChanged<int> onChanged,
              }) {
                return DropdownButtonFormField<int>(
                  value: value,
                  decoration: InputDecoration(
                    labelText: label,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  items: years
                      .map(
                        (y) =>
                            DropdownMenuItem<int>(value: y, child: Text('$y')),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) onChanged(v);
                  },
                );
              }

              DropdownButtonFormField<int> monthPicker({
                required String label,
                required int year,
                required int value,
                required ValueChanged<int> onChanged,
              }) {
                final months = monthsForYear(year);
                final safeValue = months.contains(value) ? value : months.last;

                return DropdownButtonFormField<int>(
                  value: safeValue,
                  decoration: InputDecoration(
                    labelText: label,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  items: months
                      .map(
                        (m) => DropdownMenuItem<int>(
                          value: m,
                          child: Text(_monthName(m)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) onChanged(v);
                  },
                );
              }

              Widget rangeBlock({
                required String title,
                required int year,
                required int month,
                required ValueChanged<int> onYear,
                required ValueChanged<int> onMonth,
              }) {
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh.withOpacity(
                      cs.brightness == Brightness.dark ? .55 : .82,
                    ),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: cs.outlineVariant.withOpacity(.18),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: monthPicker(
                              label: 'الشهر',
                              year: year,
                              value: month,
                              onChanged: onMonth,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: yearPicker(
                              label: 'السنة',
                              value: year,
                              onChanged: onYear,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }

              return AlertDialog(
                backgroundColor: cs.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: const Text(
                  'اختر الأشهر',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                content: SizedBox(
                  width: 430,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      rangeBlock(
                        title: 'من شهر',
                        year: fromYear,
                        month: fromMonth,
                        onYear: (v) {
                          setDialog(() {
                            fromYear = v;
                            normalizeMonths();
                            error = null;
                          });
                        },
                        onMonth: (v) {
                          setDialog(() {
                            fromMonth = v;
                            error = null;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      rangeBlock(
                        title: 'إلى شهر',
                        year: toYear,
                        month: toMonth,
                        onYear: (v) {
                          setDialog(() {
                            toYear = v;
                            normalizeMonths();
                            error = null;
                          });
                        },
                        onMonth: (v) {
                          setDialog(() {
                            toMonth = v;
                            error = null;
                          });
                        },
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          error!,
                          style: TextStyle(
                            color: cs.error,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('إلغاء'),
                  ),
                  FilledButton.icon(
                    onPressed: () {
                      final start = DateTime(fromYear, fromMonth, 1);
                      final endAsMonth = DateTime(toYear, toMonth, 1);

                      if (start.isAfter(endAsMonth)) {
                        setDialog(() {
                          error = 'تاريخ البداية يجب أن يكون قبل تاريخ النهاية';
                        });
                        return;
                      }

                      Navigator.pop(
                        dialogContext,
                        DateTimeRange(
                          start: start,
                          end: _endOfMonthDate(toYear, toMonth),
                        ),
                      );
                    },
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('اعتماد'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (picked != null) {
      setState(() => _dateRange = picked);
    }
  }

  Future<void> _openSettings({
    required List<Account> accounts,
    required List<TransactionModel> allTx,
  }) async {
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
              final currencies = _availableCurrencies(allTx);

              void sync(void Function() fn) {
                setState(fn);
                setSheet(() {});
              }

              Widget sectionTitle(String title, IconData icon) {
                return Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 10),
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

              Widget switchTile({
                required String title,
                required String subtitle,
                required bool value,
                required ValueChanged<bool> onChanged,
                required IconData icon,
                Color? color,
              }) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: value
                          ? (color ?? cs.primary).withOpacity(.28)
                          : cs.outlineVariant.withOpacity(.18),
                    ),
                  ),
                  child: SwitchListTile.adaptive(
                    value: value,
                    onChanged: onChanged,
                    contentPadding: EdgeInsets.zero,
                    secondary: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: (color ?? cs.primary).withOpacity(.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: color ?? cs.primary),
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
                  ),
                );
              }

              Widget choiceWrap<T>({
                required List<T> values,
                required T selected,
                required String Function(T v) labelBuilder,
                required ValueChanged<T> onChange,
              }) {
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: values.map((v) {
                    return ChoiceChip(
                      selected: v == selected,
                      label: Text(labelBuilder(v)),
                      onSelected: (_) => onChange(v),
                    );
                  }).toList(),
                );
              }

              return SafeArea(
                top: false,
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.90,
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
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
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
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'إعدادات الغرافيك',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 17,
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      Text(
                                        'تحكم كامل بالفترة والبيانات والمظهر',
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

                          sectionTitle(
                            'الفترة وطريقة العرض',
                            Icons.timeline_rounded,
                          ),
                          choiceWrap<TimelineGraphPeriod>(
                            values: TimelineGraphPeriod.values,
                            selected: _period,
                            labelBuilder: _periodLabel,
                            onChange: (v) => sync(() {
                              _period = v;
                              _dateRange = _snapRangeToPeriod(_dateRange, v);
                            }),
                          ),
                          const SizedBox(height: 12),
                          choiceWrap<TimelineGraphMetric>(
                            values: TimelineGraphMetric.values,
                            selected: _metric,
                            labelBuilder: (v) => v == TimelineGraphMetric.count
                                ? 'عدد الحركات'
                                : 'المبالغ',
                            onChange: (v) => sync(() => _metric = v),
                          ),

                          sectionTitle(
                            'اختيار الفترة',
                            Icons.date_range_rounded,
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () async {
                              Navigator.pop(context);
                              await Future.delayed(
                                const Duration(milliseconds: 120),
                              );
                              await _pickDateRange();
                            },
                            icon: Icon(_datePickerIcon()),
                            label: Text(
                              'تحديد ${_datePickerTitle()}: ${_dateRangeLabel()}',
                            ),
                          ),
                          const SizedBox(height: 10),

                          sectionTitle(
                            'الحساب والعملة',
                            Icons.filter_alt_rounded,
                          ),
                          DropdownButtonFormField<int?>(
                            value: _selectedAccountId,
                            decoration: InputDecoration(
                              labelText: 'الحساب',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text('كل الحسابات'),
                              ),
                              ...accounts.map(
                                (a) => DropdownMenuItem<int?>(
                                  value: a.id,
                                  child: Text(a.name),
                                ),
                              ),
                            ],
                            onChanged: (v) =>
                                sync(() => _selectedAccountId = v),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String?>(
                            value: _selectedCurrency,
                            decoration: InputDecoration(
                              labelText: 'العملة',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            items: [
                              const DropdownMenuItem<String?>(
                                value: null,
                                child: Text('كل العملات'),
                              ),
                              ...currencies.map(
                                (c) => DropdownMenuItem<String?>(
                                  value: c,
                                  child: Text(c),
                                ),
                              ),
                            ],
                            onChanged: (v) => sync(() => _selectedCurrency = v),
                          ),

                          sectionTitle(
                            'السلاسل',
                            Icons.multiline_chart_rounded,
                          ),
                          switchTile(
                            title: 'المضافة',
                            subtitle: 'إظهار / إخفاء خط المضافة',
                            value: _showAdded,
                            onChanged: (v) => sync(() => _showAdded = v),
                            icon: Icons.add_circle_rounded,
                            color: const Color(0xFF3B82F6),
                          ),
                          switchTile(
                            title: 'المستلمة',
                            subtitle: 'إظهار / إخفاء خط المستلمة',
                            value: _showReceived,
                            onChanged: (v) => sync(() => _showReceived = v),
                            icon: Icons.check_circle_rounded,
                            color: const Color(0xFF10B981),
                          ),
                          switchTile(
                            title: 'الملغاة',
                            subtitle: 'إظهار / إخفاء خط الملغاة',
                            value: _showCancelled,
                            onChanged: (v) => sync(() => _showCancelled = v),
                            icon: Icons.cancel_rounded,
                            color: const Color(0xFFF43F5E),
                          ),
                          switchTile(
                            title: 'الباقي',
                            subtitle: 'إظهار / إخفاء خط الباقي',
                            value: _showUnreceived,
                            onChanged: (v) => sync(() => _showUnreceived = v),
                            icon: Icons.hourglass_bottom_rounded,
                            color: const Color(0xFF8B5CF6),
                          ),

                          sectionTitle(
                            'إظهار / إخفاء',
                            Icons.visibility_rounded,
                          ),
                          switchTile(
                            title: 'الهيدر',
                            subtitle: 'إظهار اسم الحساب ومعلومات الفترة',
                            value: _showHeader,
                            onChanged: (v) => sync(() => _showHeader = v),
                            icon: Icons.view_agenda_rounded,
                          ),
                          switchTile(
                            title: 'شريط المعلومات',
                            subtitle: 'إظهار التاريخ والفترة والوقت',
                            value: _showMetaBar,
                            onChanged: (v) => sync(() => _showMetaBar = v),
                            icon: Icons.badge_rounded,
                          ),
                          switchTile(
                            title: 'بطاقات الملخص',
                            subtitle: 'إظهار بطاقات المضافة والمستلمة وغيرها',
                            value: _showSummaryCards,
                            onChanged: (v) => sync(() => _showSummaryCards = v),
                            icon: Icons.space_dashboard_rounded,
                          ),
                          switchTile(
                            title: 'دليل الألوان',
                            subtitle: 'إظهار أسماء الخطوط أسفل الرسم',
                            value: _showLegend,
                            onChanged: (v) => sync(() => _showLegend = v),
                            icon: Icons.label_rounded,
                          ),
                          switchTile(
                            title: 'شبكة الرسم',
                            subtitle: 'إظهار خطوط الخلفية',
                            value: _showGrid,
                            onChanged: (v) => sync(() => _showGrid = v),
                            icon: Icons.grid_4x4_rounded,
                          ),
                          switchTile(
                            title: 'محور أفقي',
                            subtitle: 'إظهار تسميات المحور الأفقي',
                            value: _showXAxis,
                            onChanged: (v) => sync(() => _showXAxis = v),
                            icon: Icons.swap_horiz_rounded,
                          ),
                          switchTile(
                            title: 'محور عمودي',
                            subtitle: 'إظهار تسميات المحور العمودي',
                            value: _showYAxis,
                            onChanged: (v) => sync(() => _showYAxis = v),
                            icon: Icons.swap_vert_rounded,
                          ),
                          switchTile(
                            title: 'أرقام النقاط',
                            subtitle: 'إظهار رقم كل نقطة على المخطط',
                            value: _showPoints,
                            onChanged: (v) => sync(() => _showPoints = v),
                            icon: Icons.bubble_chart_rounded,
                          ),
                          switchTile(
                            title: 'تعبئة أسفل الخط',
                            subtitle: 'تأثير بصري أنيق أسفل الخطوط',
                            value: _showArea,
                            onChanged: (v) => sync(() => _showArea = v),
                            icon: Icons.waterfall_chart_rounded,
                          ),
                          switchTile(
                            title: 'خطوط ناعمة',
                            subtitle: 'يجعل الرسم أكثر نعومة',
                            value: _smoothLines,
                            onChanged: (v) => sync(() => _smoothLines = v),
                            icon: Icons.auto_graph_rounded,
                          ),
                          switchTile(
                            title: 'تجاهل الفراغ في الأطراف',
                            subtitle:
                                'يقصّ الفترات الفارغة من بداية ونهاية المخطط فقط',
                            value: _trimEmptyEdges,
                            onChanged: (v) => sync(() => _trimEmptyEdges = v),
                            icon: Icons.compress_rounded,
                          ),
                          switchTile(
                            title: 'بادج أعلى قيمة',
                            subtitle: 'إظهار القيمة الأعلى بشكل مميز',
                            value: _showMaxBadge,
                            onChanged: (v) => sync(() => _showMaxBadge = v),
                            icon: Icons.star_rounded,
                          ),
                          switchTile(
                            title: 'خط إرشادي لأعلى قيمة',
                            subtitle: 'إظهار خط عمودي عند أعلى نقطة',
                            value: _showMaxGuide,
                            onChanged: (v) => sync(() => _showMaxGuide = v),
                            icon: Icons.straighten_rounded,
                          ),

                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: () {
                              sync(() {
                                _period = TimelineGraphPeriod.hour;
                                _metric = TimelineGraphMetric.count;
                                _selectedAccountId = null;
                                _selectedCurrency = null;

                                _showHeader = false;
                                _showMetaBar = false;
                                _showSummaryCards = true;
                                _showLegend = false;
                                _showGrid = true;
                                _showXAxis = true;
                                _showYAxis = true;
                                _showPoints = true;
                                _showArea = true;
                                _showMaxBadge = true;
                                _showMaxGuide = true;
                                _smoothLines = true;
                                _trimEmptyEdges = true;

                                _showAdded = true;
                                _showReceived = false;
                                _showCancelled = false;
                                _showUnreceived = false;
                              });
                            },
                            icon: const Icon(Icons.restart_alt_rounded),
                            label: const Text('إعادة الافتراضي'),
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

  // ==========================
  // UI
  // ==========================

  List<Color> _gradientOfSeries(_TimelineSeriesData s) {
    switch (s.type) {
      case TimelineGraphSeries.added:
        return const [Color(0xFF2563EB), Color(0xFF60A5FA)];
      case TimelineGraphSeries.received:
        return const [Color(0xFF059669), Color(0xFF34D399)];
      case TimelineGraphSeries.cancelled:
        return const [Color(0xFFE11D48), Color(0xFFFB7185)];
      case TimelineGraphSeries.unreceived:
        return const [Color(0xFF7C3AED), Color(0xFFA78BFA)];
    }
  }

  Color _softColorOfSeries(_TimelineSeriesData s) {
    switch (s.type) {
      case TimelineGraphSeries.added:
        return const Color(0xFF2563EB);
      case TimelineGraphSeries.received:
        return const Color(0xFF059669);
      case TimelineGraphSeries.cancelled:
        return const Color(0xFFE11D48);
      case TimelineGraphSeries.unreceived:
        return const Color(0xFF7C3AED);
    }
  }

  Widget _buildHeader({
    required ColorScheme cs,
    required List<Account> accounts,
  }) {
    final selectedAccount = accounts
        .where((a) => a.id == _selectedAccountId)
        .cast<Account?>()
        .firstOrNull;

    final title = selectedAccount?.name ?? 'كل الحسابات';

    if (!_showHeader && !_showMetaBar) {
      return const SizedBox.shrink();
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh.withOpacity(
          cs.brightness == Brightness.dark ? .74 : .88,
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: cs.outlineVariant.withOpacity(.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
              cs.brightness == Brightness.dark ? .18 : .045,
            ),
            blurRadius: 26,
            spreadRadius: -16,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showHeader)
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(.10),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: cs.primary.withOpacity(.10)),
                  ),
                  child: Icon(
                    Icons.auto_graph_rounded,
                    color: cs.primary,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'غرافيك الحركات',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          height: 1.12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(.09),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: cs.primary.withOpacity(.12)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _metric == TimelineGraphMetric.count
                            ? Icons.tag_rounded
                            : Icons.payments_outlined,
                        color: cs.primary,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _metricLabel(),
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          if (_showHeader && _showMetaBar) const SizedBox(height: 14),
          if (_showMetaBar)
            Wrap(
              alignment: WrapAlignment.start,
              spacing: 8,
              runSpacing: 8,
              children: [
                _metaPill(
                  label: _periodLabel(_period),
                  icon: Icons.timeline_rounded,
                ),
                _metaPill(
                  label: _dateRangeLabel(),
                  icon: Icons.calendar_month_rounded,
                ),
                if (_selectedCurrency != null)
                  _metaPill(
                    label: _selectedCurrency!,
                    icon: Icons.payments_rounded,
                  ),
                if (_trimEmptyEdges && _period != TimelineGraphPeriod.month)
                  _metaPill(
                    label: 'بدون أطراف فارغة',
                    icon: Icons.compress_rounded,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _metaPill({required String label, required IconData icon}) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(
          cs.brightness == Brightness.dark ? .58 : .78,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withOpacity(.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.primary.withOpacity(.86)),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: cs.onSurface.withOpacity(.88),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    final cs = Theme.of(context).colorScheme;

    Widget action({
      required String label,
      required String value,
      required IconData icon,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh.withOpacity(
                  cs.brightness == Brightness.dark ? .66 : .82,
                ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: cs.outlineVariant.withOpacity(.16)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: cs.primary.withOpacity(.09),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: cs.primary, size: 19),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w800,
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        action(
          label: _datePickerTitle(),
          value: _dateRangeLabel(),
          icon: _datePickerIcon(),
          onTap: _pickDateRange,
        ),
      ],
    );
  }

  Widget _buildSummaryCards(_TimelineGraphData data) {
    if (!_showSummaryCards) return const SizedBox.shrink();

    final visible = data.visibleSeries;
    if (visible.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    Widget card(_TimelineSeriesData s) {
      final value = _summaryValue(s);
      final color = _softColorOfSeries(s);

      return AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              color.withOpacity(cs.brightness == Brightness.dark ? .16 : .105),
              cs.surfaceContainerHigh.withOpacity(
                cs.brightness == Brightness.dark ? .66 : .90,
              ),
              cs.surfaceContainerHighest.withOpacity(
                cs.brightness == Brightness.dark ? .42 : .34,
              ),
            ],
            stops: const [0.0, .54, 1.0],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: color.withOpacity(.22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(
                cs.brightness == Brightness.dark ? .14 : .035,
              ),
              blurRadius: 18,
              spreadRadius: -14,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [Color.lerp(color, Colors.white, .18)!, color],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(.20)),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(.20),
                    blurRadius: 14,
                    spreadRadius: -8,
                    offset: const Offset(0, 9),
                  ),
                ],
              ),
              child: Icon(_iconOfSeries(s.type), color: Colors.white, size: 22),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 5),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      _formatValue(value),
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                        height: 1,
                        letterSpacing: -.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final twoCols = width >= 430;
        final itemWidth = twoCols ? (width - 10) / 2 : width;

        return Column(
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: visible
                  .map((s) => SizedBox(width: itemWidth, child: card(s)))
                  .toList(),
            ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }

  Widget _valueCapsule({required String text, required Color color}) {
    return Container(
      constraints: const BoxConstraints(minWidth: 64),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(.16)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 13.5,
          height: 1,
        ),
      ),
    );
  }

  IconData _iconOfSeries(TimelineGraphSeries s) {
    switch (s) {
      case TimelineGraphSeries.added:
        return Icons.add_rounded;
      case TimelineGraphSeries.received:
        return Icons.done_rounded;
      case TimelineGraphSeries.cancelled:
        return Icons.close_rounded;
      case TimelineGraphSeries.unreceived:
        return Icons.pending_actions_rounded;
    }
  }

  Widget _buildChartCard(_TimelineGraphData data, ColorScheme cs) {
    final hasData = data.visibleSeries.any((s) => s.values.any((v) => v > 0));

    if (!hasData) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withOpacity(
            cs.brightness == Brightness.dark ? .62 : .84,
          ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: cs.outlineVariant.withOpacity(.16)),
        ),
        child: Column(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary.withOpacity(.09),
              ),
              child: Icon(
                Icons.show_chart_rounded,
                size: 32,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'لا توجد بيانات ضمن هذه الفلاتر',
              style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              'جرّب تغيير الفترة أو الحساب أو العملة أو الوقت',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh.withOpacity(
          cs.brightness == Brightness.dark ? .62 : .84,
        ),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: cs.outlineVariant.withOpacity(.16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
              cs.brightness == Brightness.dark ? .18 : .045,
            ),
            blurRadius: 24,
            spreadRadius: -15,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(.09),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.stacked_line_chart_rounded,
                  color: cs.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'المخطط الزمني',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w900,
                        fontSize: 16.5,
                      ),
                    ),
                  ],
                ),
              ),
              _valueCapsule(text: _metricLabel(), color: cs.primary),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            clipBehavior: Clip.antiAlias,
            height: 335,
            decoration: BoxDecoration(
              color: cs.surface.withOpacity(
                cs.brightness == Brightness.dark ? .72 : .86,
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: cs.outlineVariant.withOpacity(.14)),
            ),
            child: TweenAnimationBuilder<double>(
              key: ValueKey(
                '${_period.index}-${_metric.index}-${_dateRange.start.millisecondsSinceEpoch}-${_dateRange.end.millisecondsSinceEpoch}-${_selectedAccountId ?? -1}-${_selectedCurrency ?? 'all'}-${_showAdded ? 1 : 0}-${_showReceived ? 1 : 0}-${_showCancelled ? 1 : 0}-${_showUnreceived ? 1 : 0}-${_trimEmptyEdges ? 1 : 0}',
              ),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 720),
              curve: Curves.easeOutCubic,
              builder: (context, progress, _) {
                return CustomPaint(
                  size: Size.infinite,
                  painter: _TimelineChartPainter(
                    data: data,
                    progress: progress,
                    showGrid: _showGrid,
                    showXAxis: _showXAxis,
                    showYAxis: _showYAxis,
                    showPoints: _showPoints,
                    showArea: _showArea,
                    showMaxBadge: _showMaxBadge,
                    showMaxGuide: _showMaxGuide,
                    smoothLines: _smoothLines,
                    forceAllMonthPointBubbles:
                        _period == TimelineGraphPeriod.month,
                    valueFormatter: _formatValue,
                    axisTextColor: cs.onSurfaceVariant.withOpacity(.68),
                    gridColor: cs.outlineVariant.withOpacity(.22),
                    chartTextColor: cs.onSurface,
                    chartSurfaceTopColor: cs.brightness == Brightness.dark
                        ? cs.surfaceContainerHighest.withOpacity(.66)
                        : cs.surface.withOpacity(.94),
                    chartSurfaceBottomColor: cs.brightness == Brightness.dark
                        ? cs.surface.withOpacity(.72)
                        : cs.surfaceContainerLowest.withOpacity(.92),
                    chartSurfaceBorderColor: cs.outlineVariant.withOpacity(
                      cs.brightness == Brightness.dark ? .22 : .12,
                    ),
                    isDarkMode: cs.brightness == Brightness.dark,
                  ),
                );
              },
            ),
          ),
          if (_showLegend) ...[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: data.visibleSeries.map((s) {
                final color = _softColorOfSeries(s);

                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: color.withOpacity(.075),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: color.withOpacity(.14)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        s.label,
                        style: TextStyle(
                          color: cs.onSurface.withOpacity(.90),
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ValueListenableBuilder(
      valueListenable: DatabaseService.accountsBox.listenable(),
      builder: (context, Box<Account> accountsBox, _) {
        final accounts =
            accountsBox.values
                .where((account) => account.type == AccountType.office)
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));

        return ValueListenableBuilder(
          valueListenable: DatabaseService.transactionsBox.listenable(),
          builder: (context, Box<TransactionModel> txBox, __) {
            final officeAccountIds = accounts
                .map((account) => account.id)
                .toSet();
            final allTx = txBox.values
                .where((tx) => officeAccountIds.contains(tx.accountId))
                .toList();
            final data = _buildGraphData(accounts: accounts, allTx: allTx);

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                backgroundColor: cs.surfaceContainerLowest,
                appBar: AppBar(
                  backgroundColor: cs.surfaceContainerLowest,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  title: const Text(
                    'غرافيك الحركات',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  centerTitle: true,
                  actions: [
                    IconButton(
                      tooltip: 'الإعدادات',
                      onPressed: () =>
                          _openSettings(accounts: accounts, allTx: allTx),
                      icon: const Icon(Icons.tune_rounded),
                    ),
                    IconButton(
                      tooltip: _busy ? 'جارٍ الحفظ...' : 'حفظ صورة',
                      onPressed: _busy
                          ? null
                          : () => _saveAndMaybeShare(alsoShare: false),
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
                          : () => _saveAndMaybeShare(alsoShare: true),
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
                      colors: [cs.surfaceContainerLowest, cs.surface],
                    ),
                  ),
                  child: SafeArea(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: _maxCanvasWidth,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildActionBar(),
                              const SizedBox(height: 12),
                              RepaintBoundary(
                                key: _shotKey,
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        cs.surface.withOpacity(
                                          cs.brightness == Brightness.dark
                                              ? .62
                                              : .86,
                                        ),
                                        cs.surfaceContainerLowest.withOpacity(
                                          cs.brightness == Brightness.dark
                                              ? .78
                                              : .96,
                                        ),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(30),
                                    border: Border.all(
                                      color: cs.outlineVariant.withOpacity(.12),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(
                                          cs.brightness == Brightness.dark
                                              ? .16
                                              : .045,
                                        ),
                                        blurRadius: 28,
                                        spreadRadius: -14,
                                        offset: const Offset(0, 16),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _buildHeader(cs: cs, accounts: accounts),
                                      const SizedBox(height: 14),
                                      _buildSummaryCards(data),
                                      _buildChartCard(data, cs),
                                    ],
                                  ),
                                ),
                              ),
                            ],
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

// ==========================
// Painter
// ==========================

class _TimelineChartPainter extends CustomPainter {
  final _TimelineGraphData data;
  final double progress;

  final bool showGrid;
  final bool showXAxis;
  final bool showYAxis;
  final bool showPoints;
  final bool showArea;
  final bool showMaxBadge;
  final bool showMaxGuide;
  final bool smoothLines;
  final bool forceAllMonthPointBubbles;

  final String Function(double value) valueFormatter;

  final Color axisTextColor;
  final Color gridColor;
  final Color chartTextColor;
  final Color chartSurfaceTopColor;
  final Color chartSurfaceBottomColor;
  final Color chartSurfaceBorderColor;
  final bool isDarkMode;

  const _TimelineChartPainter({
    required this.data,
    required this.progress,
    required this.showGrid,
    required this.showXAxis,
    required this.showYAxis,
    required this.showPoints,
    required this.showArea,
    required this.showMaxBadge,
    required this.showMaxGuide,
    required this.smoothLines,
    required this.forceAllMonthPointBubbles,
    required this.valueFormatter,
    required this.axisTextColor,
    required this.gridColor,
    required this.chartTextColor,
    required this.chartSurfaceTopColor,
    required this.chartSurfaceBottomColor,
    required this.chartSurfaceBorderColor,
    required this.isDarkMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final visible = data.visibleSeries;
    if (visible.isEmpty || data.buckets.isEmpty) return;

    const left = 48.0;
    const right = 18.0;
    const top = 34.0;
    const bottom = 58.0;

    final chartRect = Rect.fromLTWH(
      left,
      top,
      math.max(1, size.width - left - right),
      math.max(1, size.height - top - bottom),
    );

    final maxY = _maxY(visible);
    final maxPoint = _findMaxPoint(visible);

    _drawChartSurface(canvas, chartRect);

    if (showGrid) {
      _drawGrid(canvas, chartRect);
    }

    if (showYAxis) {
      _drawYAxisLabels(canvas, chartRect, maxY);
    }

    if (showXAxis) {
      _drawXAxisLabels(canvas, chartRect);
    }

    if (showMaxGuide && maxPoint != null && maxPoint.value > 0) {
      final guideX = _xOf(
        maxPoint.index,
        maxPoint.series.values.length,
        chartRect,
      );

      _drawDashedLine(
        canvas,
        Offset(guideX, chartRect.top + 8),
        Offset(guideX, chartRect.bottom),
        maxPoint.series.color.withOpacity(.24),
      );
    }

    for (final s in visible) {
      _drawSeries(canvas, chartRect, s, maxY, maxPoint);
    }
  }

  void _drawChartSurface(Canvas canvas, Rect chartRect) {
    final surface = RRect.fromRectAndRadius(
      chartRect.inflate(8),
      const Radius.circular(24),
    );

    final bg = Paint()
      ..isAntiAlias = true
      ..shader = ui.Gradient.linear(chartRect.topLeft, chartRect.bottomRight, [
        chartSurfaceTopColor,
        chartSurfaceBottomColor,
      ]);

    final border = Paint()
      ..isAntiAlias = true
      ..color = chartSurfaceBorderColor
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    canvas.drawRRect(surface, bg);
    canvas.drawRRect(surface, border);
  }

  void _drawGrid(Canvas canvas, Rect chartRect) {
    final horizontal = Paint()
      ..isAntiAlias = true
      ..color = gridColor
      ..strokeWidth = .65;

    for (int i = 0; i <= 5; i++) {
      final y = chartRect.top + chartRect.height * (i / 5);
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        horizontal,
      );
    }

    final count = data.buckets.length;
    final showEachGridLine = count <= 24;
    final interval = showEachGridLine ? 1 : _labelInterval(count);

    for (int i = 0; i < count; i += interval) {
      final x = _xOf(i, count, chartRect);
      canvas.drawLine(
        Offset(x, chartRect.top),
        Offset(x, chartRect.bottom),
        Paint()
          ..isAntiAlias = true
          ..color = gridColor.withOpacity(.32)
          ..strokeWidth = .60,
      );
    }

    final axis = Paint()
      ..isAntiAlias = true
      ..color = gridColor.withOpacity(.55)
      ..strokeWidth = .9;

    canvas.drawLine(
      Offset(chartRect.left, chartRect.bottom),
      Offset(chartRect.right, chartRect.bottom),
      axis,
    );
  }

  void _drawYAxisLabels(Canvas canvas, Rect chartRect, double maxY) {
    for (int i = 0; i <= 5; i++) {
      final y = chartRect.top + chartRect.height * (i / 5);
      final value = maxY * (1 - i / 5);

      _drawText(
        canvas,
        valueFormatter(value),
        Offset(6, y - 7),
        axisTextColor,
        10,
        FontWeight.w800,
        maxWidth: 39,
      );
    }
  }

  void _drawXAxisLabels(Canvas canvas, Rect chartRect) {
    final count = data.buckets.length;
    final forceAllLabels = forceAllMonthPointBubbles;
    final showEachLabel = forceAllLabels || count <= 24;
    final interval = showEachLabel ? 1 : _labelInterval(count);
    final fontSize = forceAllLabels && count > 24
        ? 8.0
        : showEachLabel
        ? 9.2
        : 10.0;
    final available = count <= 1 ? 54.0 : chartRect.width / (count - 1);
    final labelWidth = forceAllLabels
        ? math.max(28.0, math.min(46.0, available + 14))
        : showEachLabel
        ? 38.0
        : 54.0;

    for (int i = 0; i < count; i += interval) {
      final x = _xOf(i, count, chartRect);
      final yOffset = forceAllLabels && count > 18 && i.isOdd ? 31.0 : 16.0;

      _drawTextCentered(
        canvas,
        data.buckets[i].shortLabel,
        Offset(x, chartRect.bottom + yOffset),
        axisTextColor,
        fontSize,
        FontWeight.w800,
        maxWidth: labelWidth,
      );
    }
  }

  void _drawSeries(
    Canvas canvas,
    Rect chartRect,
    _TimelineSeriesData s,
    double maxY,
    _MaxPoint? maxPoint,
  ) {
    final points = <Offset>[];

    for (int i = 0; i < s.values.length; i++) {
      final x = _xOf(i, s.values.length, chartRect);
      final targetY = _yOf(s.values[i], maxY, chartRect);
      final animatedY =
          chartRect.bottom - ((chartRect.bottom - targetY) * progress);

      points.add(Offset(x, animatedY));
    }

    if (points.isEmpty) return;

    if (showArea && points.length >= 2 && s.values.any((v) => v > 0)) {
      final areaPath = _buildPath(points, smooth: smoothLines);
      final fillPath = Path.from(areaPath)
        ..lineTo(points.last.dx, chartRect.bottom)
        ..lineTo(points.first.dx, chartRect.bottom)
        ..close();

      final gradient = ui.Gradient.linear(
        Offset(0, chartRect.top),
        Offset(0, chartRect.bottom),
        [
          s.color.withOpacity(.105),
          s.color.withOpacity(.045),
          s.color.withOpacity(.00),
        ],
        const [0.0, .55, 1.0],
      );

      canvas.drawPath(
        fillPath,
        Paint()
          ..isAntiAlias = true
          ..shader = gradient
          ..style = PaintingStyle.fill,
      );
    }

    final linePath = _buildPath(points, smooth: smoothLines);
    final isPeakSeries = maxPoint != null && identical(maxPoint.series, s);

    final shadowLine = Paint()
      ..isAntiAlias = true
      ..color = s.color.withOpacity(
        isPeakSeries ? (isDarkMode ? .26 : .18) : (isDarkMode ? .16 : .10),
      )
      ..strokeWidth = isPeakSeries ? 6.6 : 5.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        isPeakSeries ? 3.2 : 2.4,
      );

    final linePaint = Paint()
      ..isAntiAlias = true
      ..color = s.color.withOpacity(isPeakSeries ? 1.0 : .92)
      ..strokeWidth = isPeakSeries ? 3.2 : 2.55
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    canvas.drawPath(linePath, shadowLine);
    canvas.drawPath(linePath, linePaint);

    for (int i = 0; i < points.length; i++) {
      final value = s.values[i];
      final showThisPointEvenIfZero = forceAllMonthPointBubbles;
      if (value <= 0 && !showThisPointEvenIfZero) continue;

      final isMax =
          maxPoint != null &&
          identical(maxPoint.series, s) &&
          maxPoint.index == i &&
          maxPoint.value > 0;

      final shouldDrawPointMarker =
          showPoints || isMax || showThisPointEvenIfZero;
      if (!shouldDrawPointMarker) continue;

      final p = points[i];
      final isZero = value <= 0;
      final outerRadius = isMax ? 8.0 : (isZero ? 4.4 : 4.8);
      final middleRadius = isMax ? 5.2 : (isZero ? 2.9 : 3.2);
      final innerRadius = isMax ? 3.4 : (isZero ? 2.0 : 2.25);
      final markerOpacity = isMax ? .24 : (isZero ? .09 : .11);

      canvas.drawCircle(
        p,
        outerRadius,
        Paint()
          ..isAntiAlias = true
          ..color = s.color.withOpacity(markerOpacity),
      );

      if (isMax) {
        canvas.drawCircle(
          p,
          outerRadius + 1.8,
          Paint()
            ..isAntiAlias = true
            ..color = s.color.withOpacity(.10)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2,
        );
      }

      canvas.drawCircle(
        p,
        middleRadius,
        Paint()
          ..isAntiAlias = true
          ..color = isDarkMode ? chartSurfaceTopColor : Colors.white,
      );

      canvas.drawCircle(
        p,
        innerRadius,
        Paint()
          ..isAntiAlias = true
          ..color = s.color,
      );

      final shouldDrawBubble =
          showPoints || (isMax && showMaxBadge) || showThisPointEvenIfZero;
      if (shouldDrawBubble) {
        _drawValueBubble(
          canvas,
          chartRect: chartRect,
          point: p,
          color: s.color,
          label: valueFormatter(value),
          isMax: isMax && showMaxBadge,
          preferBelow: _shouldPlaceBubbleBelow(
            index: i,
            points: points,
            bubbleWidthEstimate: _estimateBubbleWidth(
              valueFormatter(value),
              isMax && showMaxBadge,
            ),
          ),
        );
      }
    }
  }

  Path _buildPath(List<Offset> points, {required bool smooth}) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);

    if (points.length == 1) return path;

    if (!smooth) {
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      return path;
    }

    for (int i = 1; i < points.length; i++) {
      final previous = points[i - 1];
      final current = points[i];

      final distance = current.dx - previous.dx;
      final controlOffset = math.max(8.0, distance * .38);

      path.cubicTo(
        previous.dx + controlOffset,
        previous.dy,
        current.dx - controlOffset,
        current.dy,
        current.dx,
        current.dy,
      );
    }

    return path;
  }

  double _estimateBubbleWidth(String label, bool isMax) {
    final labelLength = label.trim().runes.length;
    final textFontSize = labelLength <= 3
        ? 12.2
        : labelLength <= 5
        ? 11.2
        : labelLength <= 7
        ? 10.0
        : 8.9;
    final horizontalPadding = isMax ? 25.0 : 18.0;
    final minBubbleWidth = isMax ? 42.0 : 34.0;
    final maxBubbleWidth = isMax ? 84.0 : 76.0;

    return math.max(
      minBubbleWidth,
      math.min(
        labelLength * textFontSize * .64 + horizontalPadding,
        maxBubbleWidth,
      ),
    );
  }

  bool _shouldPlaceBubbleBelow({
    required int index,
    required List<Offset> points,
    required double bubbleWidthEstimate,
  }) {
    if (points.length <= 1) return false;

    final current = points[index];
    final minGap = math.max(34.0, bubbleWidthEstimate * .78);

    bool closeToPrevious = false;
    bool closeToNext = false;

    if (index > 0) {
      final previous = points[index - 1];
      closeToPrevious =
          (current.dx - previous.dx).abs() < minGap &&
          (current.dy - previous.dy).abs() < 42;
    }

    if (index < points.length - 1) {
      final next = points[index + 1];
      closeToNext =
          (next.dx - current.dx).abs() < minGap &&
          (next.dy - current.dy).abs() < 42;
    }

    if (!closeToPrevious && !closeToNext) return false;
    return index.isOdd;
  }

  void _drawValueBubble(
    Canvas canvas, {
    required Rect chartRect,
    required Offset point,
    required Color color,
    required String label,
    required bool isMax,
    required bool preferBelow,
  }) {
    final labelLength = label.trim().runes.length;
    final textFontSize = labelLength <= 3
        ? 12.2
        : labelLength <= 5
        ? 11.2
        : labelLength <= 7
        ? 10.0
        : 8.9;
    final bubbleWidth = _estimateBubbleWidth(label, isMax);
    const bubbleHeight = 26.0;
    const starDiameter = 17.0;

    final canPlaceBelow = point.dy + 36 + bubbleHeight <= chartRect.bottom - 4;
    final placeBelow = preferBelow && canPlaceBelow;
    final bubbleTop = placeBelow
        ? math.min(chartRect.bottom - bubbleHeight - 4, point.dy + 10)
        : math.max(chartRect.top + 6, point.dy - 36);
    final centerX = point.dx
        .clamp(
          chartRect.left + bubbleWidth / 2,
          chartRect.right - bubbleWidth / 2,
        )
        .toDouble();
    final centerY = bubbleTop + bubbleHeight / 2;

    final rect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: bubbleWidth,
      height: bubbleHeight,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(999));

    canvas.drawRRect(
      rrect.shift(const Offset(0, 2.5)),
      Paint()
        ..isAntiAlias = true
        ..color = Colors.black.withOpacity(isDarkMode ? .18 : .08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    final accent = Color.lerp(color, Colors.white, .16)!;
    final deep = Color.lerp(color, const Color(0xFF312E81), .34)!;
    final glowRect = rrect.outerRect.inflate(5);

    canvas.drawRRect(
      RRect.fromRectAndRadius(glowRect, const Radius.circular(999)),
      Paint()
        ..isAntiAlias = true
        ..color = color.withOpacity(isDarkMode ? .24 : .16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    final fillPaint = Paint()
      ..isAntiAlias = true
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        [
          accent.withOpacity(.98),
          color.withOpacity(.98),
          deep.withOpacity(.98),
        ],
        const [0.0, .46, 1.0],
      );

    canvas.drawRRect(rrect, fillPaint);
    canvas.drawRRect(
      rrect.deflate(.7),
      Paint()
        ..isAntiAlias = true
        ..color = Colors.white.withOpacity(.23)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final shineRect = Rect.fromLTWH(
      rect.left + 7,
      rect.top + 4,
      rect.width * .42,
      4.2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(shineRect, const Radius.circular(999)),
      Paint()
        ..isAntiAlias = true
        ..color = Colors.white.withOpacity(.20),
    );

    _drawTextCentered(
      canvas,
      label,
      Offset(rect.center.dx, rect.center.dy + .4),
      Colors.white,
      textFontSize,
      FontWeight.w900,
      maxWidth: rect.width - (isMax ? 24 : 14),
    );

    if (isMax) {
      final starCenter = Offset(rect.right - 2.5, rect.top + 1.5);
      canvas.drawCircle(
        starCenter,
        starDiameter / 2,
        Paint()
          ..isAntiAlias = true
          ..color = Colors.black.withOpacity(isDarkMode ? .20 : .10)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawCircle(
        starCenter,
        starDiameter / 2,
        Paint()
          ..isAntiAlias = true
          ..shader = ui.Gradient.linear(
            Offset(starCenter.dx - 8, starCenter.dy - 8),
            Offset(starCenter.dx + 8, starCenter.dy + 8),
            const [Color(0xFFFFF7B0), Color(0xFFFBBF24)],
          ),
      );
      canvas.drawCircle(
        starCenter,
        starDiameter / 2,
        Paint()
          ..isAntiAlias = true
          ..color = const Color(0xFFF59E0B).withOpacity(.32)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final starPath = _buildRoundedStarPath(
        starCenter,
        outerRadius: 5.1,
        innerRadius: 2.45,
        cornerRatio: .25,
      );
      canvas.drawPath(
        starPath,
        Paint()
          ..isAntiAlias = true
          ..color = Colors.white,
      );
    }
  }

  Path _buildRoundedStarPath(
    Offset center, {
    required double outerRadius,
    required double innerRadius,
    required double cornerRatio,
  }) {
    final vertices = <Offset>[];
    const total = 10;
    const startAngle = -math.pi / 2;

    for (int i = 0; i < total; i++) {
      final radius = i.isEven ? outerRadius : innerRadius;
      final angle = startAngle + (math.pi * 2 * i / total);
      vertices.add(
        Offset(
          center.dx + math.cos(angle) * radius,
          center.dy + math.sin(angle) * radius,
        ),
      );
    }

    Offset pointTowards(Offset from, Offset to, double ratio) {
      return Offset(
        from.dx + (to.dx - from.dx) * ratio,
        from.dy + (to.dy - from.dy) * ratio,
      );
    }

    final path = Path();

    for (int i = 0; i < total; i++) {
      final current = vertices[i];
      final previous = vertices[(i - 1 + total) % total];
      final next = vertices[(i + 1) % total];

      final p1 = pointTowards(current, previous, cornerRatio);
      final p2 = pointTowards(current, next, cornerRatio);

      if (i == 0) {
        path.moveTo(p1.dx, p1.dy);
      } else {
        path.lineTo(p1.dx, p1.dy);
      }

      path.quadraticBezierTo(current.dx, current.dy, p2.dx, p2.dy);
    }

    path.close();
    return path;
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Color color) {
    final paint = Paint()
      ..isAntiAlias = true
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    const dash = 5.0;
    const space = 5.0;

    final total = (end.dy - start.dy).abs();
    double current = 0;

    while (current < total) {
      final from = start.dy + current;
      final to = math.min(from + dash, end.dy);

      canvas.drawLine(Offset(start.dx, from), Offset(start.dx, to), paint);

      current += dash + space;
    }
  }

  double _maxY(List<_TimelineSeriesData> series) {
    double max = 0;
    for (final s in series) {
      for (final v in s.values) {
        if (v > max) max = v;
      }
    }

    if (max <= 0) return 10;
    if (max < 5) return max + 2;
    return max * 1.20;
  }

  _MaxPoint? _findMaxPoint(List<_TimelineSeriesData> series) {
    _MaxPoint? best;
    for (final s in series) {
      for (int i = 0; i < s.values.length; i++) {
        final v = s.values[i];
        if (best == null || v > best.value) {
          best = _MaxPoint(series: s, index: i, value: v);
        }
      }
    }
    return best;
  }

  double _xOf(int index, int count, Rect chartRect) {
    if (count <= 1) return chartRect.center.dx;
    return chartRect.left + (chartRect.width * index / (count - 1));
  }

  double _yOf(double value, double maxY, Rect chartRect) {
    final ratio = maxY <= 0 ? 0.0 : (value / maxY).clamp(0.0, 1.0);
    return chartRect.bottom - (chartRect.height * ratio);
  }

  int _labelInterval(int count) {
    if (count <= 8) return 1;
    if (count <= 16) return 2;
    if (count <= 30) return 3;
    if (count <= 60) return 5;
    if (count <= 120) return 10;
    return 15;
  }

  int _pointInterval(int count) {
    if (count <= 42) return 1;
    if (count <= 80) return 2;
    if (count <= 150) return 4;
    return 7;
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double fontSize,
    FontWeight weight, {
    double maxWidth = 100,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);

    tp.paint(canvas, offset);
  }

  void _drawTextCentered(
    Canvas canvas,
    String text,
    Offset center,
    Color color,
    double fontSize,
    FontWeight weight, {
    double maxWidth = 120,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
      textAlign: TextAlign.center,
    )..layout(maxWidth: maxWidth);

    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _TimelineChartPainter oldDelegate) {
    return oldDelegate.data != data ||
        oldDelegate.progress != progress ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.showXAxis != showXAxis ||
        oldDelegate.showYAxis != showYAxis ||
        oldDelegate.showPoints != showPoints ||
        oldDelegate.showArea != showArea ||
        oldDelegate.showMaxBadge != showMaxBadge ||
        oldDelegate.showMaxGuide != showMaxGuide ||
        oldDelegate.smoothLines != smoothLines ||
        oldDelegate.forceAllMonthPointBubbles != forceAllMonthPointBubbles ||
        oldDelegate.axisTextColor != axisTextColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.chartTextColor != chartTextColor ||
        oldDelegate.chartSurfaceTopColor != chartSurfaceTopColor ||
        oldDelegate.chartSurfaceBottomColor != chartSurfaceBottomColor ||
        oldDelegate.chartSurfaceBorderColor != chartSurfaceBorderColor ||
        oldDelegate.isDarkMode != isDarkMode;
  }
}

// ==========================
// Models / helpers
// ==========================

class _MoneyPart {
  final String currency;
  final double amount;

  const _MoneyPart({required this.currency, required this.amount});
}

class _TimelineBucket {
  final DateTime start;
  final DateTime end;
  final String label;
  final String shortLabel;

  const _TimelineBucket({
    required this.start,
    required this.end,
    required this.label,
    required this.shortLabel,
  });
}

class _TimelineGraphData {
  final List<_TimelineBucket> buckets;
  final List<_TimelineSeriesData> series;

  const _TimelineGraphData({required this.buckets, required this.series});

  List<_TimelineSeriesData> get visibleSeries =>
      series.where((s) => s.visible).toList();
}

class _TimelineSeriesData {
  final TimelineGraphSeries type;
  final String label;
  final Color color;
  final bool visible;
  final List<double> values;

  const _TimelineSeriesData({
    required this.type,
    required this.label,
    required this.color,
    required this.visible,
    required this.values,
  });
}

class _MaxPoint {
  final _TimelineSeriesData series;
  final int index;
  final double value;

  const _MaxPoint({
    required this.series,
    required this.index,
    required this.value,
  });
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
