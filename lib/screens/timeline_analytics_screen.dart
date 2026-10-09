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

  /// أقصى مدة يمكن اختيارها
  static const int _maxHours = 24;

  static const Color _addedColor = Color(0xFF2563EB);

  DateTimeRange _dateRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 1)),
    end: DateTime.now(),
  );

  bool _busy = false;

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

  String _formatDateTime(DateTime d) => '${_formatDay(d)} ${_formatTime(d)}';

  String _dateRangeLabel() =>
      '${_formatDateTime(_dateRange.start)} → ${_formatDateTime(_dateRange.end)}';

  bool _within(DateTime d, DateTime start, DateTime end) {
    final ms = d.millisecondsSinceEpoch;
    return ms >= start.millisecondsSinceEpoch &&
        ms <= end.millisecondsSinceEpoch;
  }

  /// خانة لكل ساعة ضمن المدة المختارة
  List<_TimelineBucket> _buildBuckets() {
    final s = _dateRange.start;
    final end = _dateRange.end;

    final buckets = <_TimelineBucket>[];
    DateTime current = DateTime(s.year, s.month, s.day, s.hour);

    while (!current.isAfter(end)) {
      final next = current.add(const Duration(hours: 1));
      final hour = '${current.hour.toString().padLeft(2, '0')}:00';

      buckets.add(
        _TimelineBucket(
          start: current,
          end: next.subtract(const Duration(milliseconds: 1)),
          label: '${_formatDay(current)} $hour',
          shortLabel: hour,
        ),
      );

      current = next;
    }

    return buckets;
  }

  // ==========================
  // Data
  // ==========================

  /// عدد الحركات المضافة بكل ساعة
  _TimelineGraphData _buildGraphData(List<TransactionModel> allTx) {
    final buckets = _buildBuckets();
    final dates = allTx
        .map((t) => t.date)
        .where((d) => _within(d, _dateRange.start, _dateRange.end))
        .toList();

    final values = <double>[
      for (final bucket in buckets)
        dates
            .where((d) => _within(d, bucket.start, bucket.end))
            .length
            .toDouble(),
    ];

    return _trimEmptyEdgeBuckets(
      _TimelineGraphData(
        buckets: buckets,
        series: [
          _TimelineSeriesData(
            type: TimelineGraphSeries.added,
            label: 'مضافة',
            color: _addedColor,
            visible: true,
            values: values,
          ),
        ],
      ),
    );
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

  double _summaryValue(_TimelineSeriesData s) =>
      s.values.fold(0.0, (a, b) => a + b);

  String _formatValue(double value) => value.round().toString();

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
  // Date picker (خلال 24 ساعة)
  // ==========================

  Future<void> _pickDateTimeRange() async {
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
                if (minutes > _maxHours * 60) {
                  return 'لا يمكن اختيار أكثر من $_maxHours ساعة';
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
                  helpText: isStart ? 'ساعة البداية' : 'ساعة النهاية',
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
                        _formatDateTime(value),
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

              final validationMessage = validateRange();
              final canApply = validationMessage == null;

              return AlertDialog(
                backgroundColor: cs.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
                title: const Text(
                  'اختر الوقت',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                content: SizedBox(
                  width: 430,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      rangeCard(
                        title: 'من',
                        value: startValue,
                        isStart: true,
                        icon: Icons.login_rounded,
                      ),
                      const SizedBox(height: 12),
                      rangeCard(
                        title: 'إلى',
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

  // ==========================
  // UI
  // ==========================

  Widget _buildDateBar() {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: _pickDateTimeRange,
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
                child: Icon(
                  Icons.more_time_rounded,
                  color: cs.primary,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'التاريخ والساعة',
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
                      _dateRangeLabel(),
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
    );
  }

  Widget _buildSummaryCard(_TimelineGraphData data) {
    final visible = data.visibleSeries;
    if (visible.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final s = visible.first;
    final value = _summaryValue(s);
    final color = s.color;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
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
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 22,
              ),
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
      ),
    );
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
              'لا توجد حركات مضافة',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w900),
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
                child: Text(
                  'المخطط الزمني',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w900,
                    fontSize: 16.5,
                  ),
                ),
              ),
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
                '${_dateRange.start.millisecondsSinceEpoch}-${_dateRange.end.millisecondsSinceEpoch}',
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
                    showGrid: true,
                    showXAxis: true,
                    showYAxis: true,
                    showPoints: true,
                    showArea: true,
                    showMaxBadge: true,
                    showMaxGuide: true,
                    smoothLines: true,
                    forceAllMonthPointBubbles: false,
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
        final officeAccountIds = accountsBox.values
            .where((account) => account.type == AccountType.office)
            .map((account) => account.id)
            .toSet();

        return ValueListenableBuilder(
          valueListenable: DatabaseService.transactionsBox.listenable(),
          builder: (context, Box<TransactionModel> txBox, __) {
            final allTx = txBox.values
                .where((tx) => officeAccountIds.contains(tx.accountId))
                .toList();
            final data = _buildGraphData(allTx);

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
                              _buildDateBar(),
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
                                      _buildSummaryCard(data),
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
