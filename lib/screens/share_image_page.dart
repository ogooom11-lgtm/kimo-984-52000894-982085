import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_saver/file_saver.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// تأكد من مسار هذا الاستيراد في مشروعك أو احذفه إذا لم تستخدم الويب
import '../utils/web_saver.dart' as web_saver;
import '../database_service.dart';
import '../utils/amount_format.dart';

/// بيانات الإحصائية
class ShareStatsData {
  final String accountName;
  final String dateLabel;
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

  final Map<String, int>? countsAddedByCurrency;
  final Map<String, int>? countsReceivedByCurrency;
  final Map<String, int>? countsCancelledByCurrency;
  final Map<String, int>? countsUnreceivedByCurrency;

  /// تسميات الأقسام (المكاتب افتراضيًا، والشركات: إرسال/استقبال/إلغاء...)
  final String addedLabel;
  final String receivedLabel;
  final String cancelledLabel;
  final String unreceivedLabel;

  /// حساب شركة: الأقسام إرسال / استقبال / إلغاء مرسل / إلغاء استقبال
  /// (ألوان وأيقونات خاصة بها، وخيارات عرض محفوظة منفصلة عن المكاتب)
  final bool isCompany;

  const ShareStatsData({
    required this.accountName,
    required this.dateLabel,
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
    this.countsAddedByCurrency,
    this.countsReceivedByCurrency,
    this.countsCancelledByCurrency,
    this.countsUnreceivedByCurrency,
    this.addedLabel = 'مضافة',
    this.receivedLabel = 'مستلمة',
    this.cancelledLabel = 'ملغاة',
    this.unreceivedLabel = 'غير مستلمة',
    this.isCompany = false,
  });
}

/// قسم من أقسام الإحصائية: فقاعة في الملخص السريع وبطاقة في التفاصيل
class _ShareSection {
  final String label;
  final int count;
  final int yesterday;
  final Map<String, double> totals;
  final Map<String, int>? counts;
  final IconData icon;
  final IconData quickIcon;
  final List<Color> gradient;

  const _ShareSection({
    required this.label,
    required this.count,
    required this.yesterday,
    required this.totals,
    required this.counts,
    required this.icon,
    required this.quickIcon,
    required this.gradient,
  });
}

class ShareImagePage extends StatefulWidget {
  final ShareStatsData data;
  const ShareImagePage({super.key, required this.data});

  @override
  State<ShareImagePage> createState() => _ShareImagePageState();
}

class _ShareImagePageState extends State<ShareImagePage> {
  final GlobalKey _shotKey = GlobalKey();
  static const double _exportScale = 3.0;
  static const double _maxCanvasWidth = 900.0;

  bool _busy = false;

  // التحكم العام
  bool _showHeader = true;

  // الملخص السريع: إظهار/إخفاء كامل + كل فقاعة لوحدها
  bool _showQuickStats = true;
  final List<bool> _quickShow = [true, true, true, true];

  // التفاصيل: إظهار/إخفاء كامل + كل بطاقة لوحدها
  bool _showDetails = true;
  final List<bool> _cardShow = [true, true, true, true];
  bool _showCurrencyRows = true;
  bool _showDeltaStrip = true;

  @override
  void initState() {
    super.initState();
    _loadDisplayPrefs();
  }

  /// الأقسام الأربعة بالترتيب (مكتب: مضافة/مستلمة/ملغاة/غير مستلمة،
  /// شركة: إرسال/استقبال/إلغاء مرسل/إلغاء استقبال)
  List<_ShareSection> _sections() {
    final d = widget.data;
    final company = d.isCompany;
    return [
      _ShareSection(
        label: d.addedLabel,
        count: d.addedCount,
        yesterday: d.yesterdayAddedCount,
        totals: d.totalsAdded,
        counts: d.countsAddedByCurrency,
        icon: company ? Icons.call_made_rounded : Icons.add_circle_rounded,
        quickIcon: company
            ? Icons.call_made_rounded
            : Icons.add_circle_outline_rounded,
        gradient: company
            ? const [Color(0xFF5E35B1), Color(0xFF9575CD)]
            : const [Colors.blue, Colors.blueAccent],
      ),
      _ShareSection(
        label: d.receivedLabel,
        count: d.receivedCount,
        yesterday: d.yesterdayReceivedCount,
        totals: d.totalsReceived,
        counts: d.countsReceivedByCurrency,
        icon: company
            ? Icons.call_received_rounded
            : Icons.check_circle_rounded,
        quickIcon: company
            ? Icons.call_received_rounded
            : Icons.check_circle_outline_rounded,
        gradient: company
            ? const [Color(0xFF00897B), Color(0xFF4DB6AC)]
            : const [Colors.green, Colors.lightGreen],
      ),
      _ShareSection(
        label: d.cancelledLabel,
        count: d.cancelledCount,
        yesterday: d.yesterdayCancelledCount,
        totals: d.totalsCancelled,
        counts: d.countsCancelledByCurrency,
        icon: company
            ? Icons.cancel_schedule_send_rounded
            : Icons.cancel_rounded,
        quickIcon: company
            ? Icons.cancel_schedule_send_rounded
            : Icons.cancel_outlined,
        gradient: company
            ? const [Color(0xFFEF6C00), Color(0xFFFFB74D)]
            : const [Colors.red, Colors.orange],
      ),
      _ShareSection(
        label: d.unreceivedLabel,
        count: d.unreceivedCount,
        yesterday: d.yesterdayUnreceivedCount,
        totals: d.totalsUnreceived,
        counts: d.countsUnreceivedByCurrency,
        icon: company ? Icons.cancel_rounded : Icons.hourglass_bottom_rounded,
        quickIcon: company
            ? Icons.cancel_outlined
            : Icons.hourglass_empty_rounded,
        gradient: company
            ? const [Color(0xFFD84315), Color(0xFFFF8A65)]
            : const [Colors.indigo, Colors.deepPurple],
      ),
    ];
  }

  /// =================== حفظ خيارات العرض ===================
  /// تُحفظ منفصلة للمكاتب وللشركات لأن أقسامهما مختلفة.
  String get _prefsKey =>
      widget.data.isCompany ? 'share_design_company' : 'share_design_office';

  void _loadDisplayPrefs() {
    final raw = DatabaseService.uiPrefsBoxOrNull?.get(_prefsKey);
    if (raw is! Map) return;
    bool read(String key, bool fallback) {
      final v = raw[key];
      return v is bool ? v : fallback;
    }

    _showHeader = read('header', true);
    _showQuickStats = read('quick', true);
    _showDetails = read('details', true);
    _showCurrencyRows = read('rows', true);
    _showDeltaStrip = read('delta', true);
    for (var i = 0; i < _quickShow.length; i++) {
      _quickShow[i] = read('q$i', true);
    }
    for (var i = 0; i < _cardShow.length; i++) {
      _cardShow[i] = read('c$i', true);
    }
  }

  void _saveDisplayPrefs() {
    final box = DatabaseService.uiPrefsBoxOrNull;
    if (box == null) return;
    box.put(_prefsKey, <String, bool>{
      'header': _showHeader,
      'quick': _showQuickStats,
      'details': _showDetails,
      'rows': _showCurrencyRows,
      'delta': _showDeltaStrip,
      for (var i = 0; i < _quickShow.length; i++) 'q$i': _quickShow[i],
      for (var i = 0; i < _cardShow.length; i++) 'c$i': _cardShow[i],
    });
  }

  void _resetDisplay() {
    _showHeader = true;
    _showQuickStats = true;
    _showDetails = true;
    _showCurrencyRows = true;
    _showDeltaStrip = true;
    _quickShow.fillRange(0, _quickShow.length, true);
    _cardShow.fillRange(0, _cardShow.length, true);
  }

  /// =================== التقاط الصورة ===================
  Future<Uint8List?> _capturePng() async {
    try {
      await Future.delayed(const Duration(milliseconds: 200));
      if (mounted) {
        WidgetsBinding.instance.handleBeginFrame(Duration.zero);
        WidgetsBinding.instance.handleDrawFrame();
      }
      await Future.delayed(const Duration(milliseconds: 150));

      final ctx = _shotKey.currentContext;
      if (ctx == null) {
        debugPrint("⚠️ Context null");
        return null;
      }

      final ro = ctx.findRenderObject();
      if (ro is! RenderRepaintBoundary) {
        debugPrint("⚠️ RenderObject ليس RepaintBoundary");
        return null;
      }

      final image = await ro.toImage(pixelRatio: _exportScale);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) {
        debugPrint("⚠️ لم يتم إنشاء أي بايت من الصورة");
        return null;
      }
      return bytes;
    } catch (e, st) {
      debugPrint("❌ capturePng error: $e\n$st");
      return null;
    }
  }

  Future<String?> _saveImageToDownloads({
    required Uint8List bytes,
    required String filenameBase,
  }) async {
    try {
      if (kIsWeb) {
        await web_saver.saveBytes(
          filename: '$filenameBase.png',
          bytes: bytes,
          mimeType: 'image/png',
        );
        return '$filenameBase.png';
      }

      if (Platform.isAndroid) {
        PermissionStatus status = await Permission.storage.request();

        if (!status.isGranted) {
          status = await Permission.manageExternalStorage.request();
        }

        if (!status.isGranted) {
          return null;
        }

        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }

        final file = File('${downloadsDir.path}/$filenameBase.png');
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      }

      // fallback لغير أندرويد
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filenameBase.png');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e, st) {
      debugPrint("❌ saveImageToDownloads error: $e\n$st");
      return null;
    }
  }

  /// =================== حفظ ومشاركة ===================
  Future<void> _saveAndMaybeShare({required bool alsoShare}) async {
    if (_busy) return;
    setState(() => _busy = true);

    void showSnack(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }

    try {
      final png = await _capturePng();
      if (png == null) {
        showSnack('تعذّر إنشاء الصورة');
        return;
      }

      final ts = DateTime.now().millisecondsSinceEpoch;
      final mode = _showDetails ? "full" : "summary";
      final filenameBase = "stats_${mode}_$ts";

      final savedPath = await _saveImageToDownloads(
        bytes: png,
        filenameBase: filenameBase,
      );

      if (savedPath == null) {
        // fallback أخير باستخدام FileSaver
        try {
          if (kIsWeb) {
            await web_saver.saveBytes(
              filename: "$filenameBase.png",
              bytes: png,
              mimeType: 'image/png',
            );
          } else {
            await FileSaver.instance.saveFile(
              name: filenameBase,
              bytes: png,
              ext: 'png',
              mimeType: MimeType.png,
            );
          }
          showSnack('✅ تم حفظ الصورة');
        } catch (e) {
          showSnack('❌ فشل الحفظ: $e');
          return;
        }
      } else {
        showSnack('✅ تم الحفظ في التنزيلات');
      }

      if (alsoShare) {
        try {
          final dir = await getTemporaryDirectory();
          final f = File('${dir.path}/$filenameBase.png');
          await f.writeAsBytes(png, flush: true);

          await Share.shareXFiles([
            XFile(
              f.path,
              mimeType: 'image/png',
              name: '$filenameBase.png',
            )
          ]);
        } catch (e, st) {
          debugPrint("❌ Share error: $e\n$st");
          showSnack('تم الحفظ لكن فشلت المشاركة: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// =================== خيارات العرض ===================
  /// أزرار منفصلة: الملخص السريع (كل فقاعة لوحدها) والتفاصيل (كل بطاقة
  /// لوحدها)، والاختيارات تُحفظ للمرة القادمة.
  Future<void> _openDisplayOptions() async {
    final sections = _sections();
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setSheet) {
              final cs = Theme.of(context).colorScheme;

              void sync(void Function() fn) {
                setState(fn);
                setSheet(() {});
                _saveDisplayPrefs();
              }

              Widget tile({
                required String title,
                required bool value,
                required ValueChanged<bool>? onChanged,
                String? subtitle,
                IconData? icon,
                Color? iconColor,
                bool nested = false,
              }) {
                return Padding(
                  padding: EdgeInsetsDirectional.only(start: nested ? 18 : 0),
                  child: SwitchListTile.adaptive(
                    value: value,
                    onChanged: onChanged,
                    dense: nested,
                    secondary: icon == null
                        ? null
                        : Icon(
                            icon,
                            color: onChanged == null ? null : iconColor,
                          ),
                    title: Text(title),
                    subtitle: subtitle == null ? null : Text(subtitle),
                    contentPadding: EdgeInsets.zero,
                  ),
                );
              }

              Widget groupTitle(String text, IconData icon) {
                return Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: cs.primary),
                      const SizedBox(width: 8),
                      Text(
                        text,
                        style: TextStyle(
                          color: cs.primary,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'خيارات إظهار وإخفاء',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.data.isCompany
                              ? 'حساب شركة — الاختيارات تُحفظ لحسابات الشركات'
                              : 'حساب مكتب — الاختيارات تُحفظ لحسابات المكاتب',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 8),

                        tile(
                          title: 'إظهار الهيدر',
                          value: _showHeader,
                          onChanged: (v) => sync(() => _showHeader = v),
                          icon: Icons.view_headline_rounded,
                        ),

                        const Divider(height: 24),
                        groupTitle('الملخص السريع', Icons.dashboard_rounded),
                        tile(
                          title: 'إظهار الملخص السريع',
                          subtitle: 'الفقاعات الصغيرة في أعلى الصورة',
                          value: _showQuickStats,
                          onChanged: (v) => sync(() => _showQuickStats = v),
                          icon: Icons.dashboard_rounded,
                        ),
                        for (var i = 0; i < sections.length; i++)
                          tile(
                            title: 'فقاعة ${sections[i].label}',
                            subtitle: 'العدد: ${sections[i].count}',
                            value: _quickShow[i],
                            onChanged: _showQuickStats
                                ? (v) => sync(() => _quickShow[i] = v)
                                : null,
                            icon: sections[i].quickIcon,
                            iconColor: sections[i].gradient.first,
                            nested: true,
                          ),

                        const Divider(height: 24),
                        groupTitle('التفاصيل', Icons.view_agenda_rounded),
                        tile(
                          title: 'عرض التفاصيل',
                          subtitle: 'بطاقات الأقسام مع مبالغ كل عملة',
                          value: _showDetails,
                          onChanged: (v) => sync(() => _showDetails = v),
                          icon: Icons.tune_rounded,
                        ),
                        for (var i = 0; i < sections.length; i++)
                          tile(
                            title: 'بطاقة ${sections[i].label}',
                            subtitle: 'العدد: ${sections[i].count}',
                            value: _cardShow[i],
                            onChanged: _showDetails
                                ? (v) => sync(() => _cardShow[i] = v)
                                : null,
                            icon: sections[i].icon,
                            iconColor: sections[i].gradient.first,
                            nested: true,
                          ),
                        tile(
                          title: 'إظهار صفوف العملات',
                          value: _showCurrencyRows,
                          onChanged: _showDetails
                              ? (v) => sync(() => _showCurrencyRows = v)
                              : null,
                          icon: Icons.payments_rounded,
                          nested: true,
                        ),
                        tile(
                          title: 'إظهار شريط عن أمس',
                          value: _showDeltaStrip,
                          onChanged: _showDetails
                              ? (v) => sync(() => _showDeltaStrip = v)
                              : null,
                          icon: Icons.trending_up_rounded,
                          nested: true,
                        ),

                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => sync(_resetDisplay),
                                icon: const Icon(Icons.restart_alt_rounded),
                                label: const Text('إعادة الافتراضي'),
                              ),
                            ),
                          ],
                        ),
                      ],
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

  /// =================== دوال التصميم المساعدة ===================
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
          "عن أمس: $pct ($diffLabel)",
          style: TextStyle(
            color: on,
            fontWeight: FontWeight.w900,
            fontSize: 12.5,
          ),
        ),
      ],
    );
  }

  /// =================== الكارت التفصيلي ===================
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
              bottom: _showDeltaStrip
                  ? Radius.zero
                  : const Radius.circular(20),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surface.withOpacity(.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 22, color: cs.onPrimary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    shadows: const [
                      Shadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                ),
              ),
              Text(
                "$count",
                style: TextStyle(
                  color: cs.onPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  shadows: const [
                    Shadow(color: Colors.black38, blurRadius: 4),
                  ],
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

  Widget _moneyRow({
    required String currency,
    required double total,
    required ColorScheme cs,
    int? count,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withOpacity(.22)),
      ),
      child: Row(
        children: [
          if (count != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          Text(
            AmountFormat.display(total),
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
        ],
      ),
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
          )
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
              children: keys
                  .map(
                    (cur) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _moneyRow(
                    currency: cur,
                    total: totals[cur] ?? 0.0,
                    cs: cs,
                    count: countsByCurrency?[cur],
                  ),
                ),
              )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    final d = widget.data;
    return Row(
      children: [
        Icon(
          d.isCompany ? Icons.business_rounded : Icons.insights_rounded,
          color: cs.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            d.isCompany
                ? "إحصائيات الشركة — ${d.accountName}"
                : "إحصائيات — ${d.accountName}",
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Icon(Icons.event_rounded, color: cs.onSurface),
        const SizedBox(width: 6),
        Text(
          d.dateLabel,
          style: TextStyle(
            color: cs.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  /// =================== تصميم الملخص السريع ===================
  Widget _buildQuickStats(List<_ShareSection> sections) {
    Widget quickCard({
      required String label,
      required int count,
      required List<Color> gradient,
      required IconData icon,
    }) {
      return Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: gradient,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: gradient.last.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white.withOpacity(0.8), size: 20),
              const SizedBox(height: 4),
              Text(
                "$count",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  shadows: [Shadow(color: Colors.black26, blurRadius: 4)],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(color: Colors.black26, blurRadius: 2)],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final widgets = <Widget>[
      for (var i = 0; i < sections.length; i++)
        if (_quickShow[i])
          quickCard(
            label: sections[i].label,
            count: sections[i].count,
            gradient: sections[i].gradient,
            icon: sections[i].quickIcon,
          ),
    ];

    if (widgets.isEmpty) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: widgets,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sections = _sections();

    final cards = <Widget>[
      for (var i = 0; i < sections.length; i++)
        if (_cardShow[i])
          _categoryCard(
            title: sections[i].label,
            count: sections[i].count,
            totals: sections[i].totals,
            icon: sections[i].icon,
            gradient: sections[i].gradient,
            cs: cs,
            yesterday: sections[i].yesterday,
            countsByCurrency: sections[i].counts,
          ),
    ];

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تصميم صورة المشاركة'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'خيارات العرض',
              onPressed: _openDisplayOptions,
              icon: const Icon(Icons.tune_rounded),
            ),
            IconButton(
              tooltip: _busy ? "جارٍ التنفيذ..." : "حفظ",
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
              tooltip: _busy ? "جارٍ التنفيذ..." : "حفظ + مشاركة",
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
        body: AbsorbPointer(
          absorbing: _busy,
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ConstrainedBox(
                      constraints:
                      const BoxConstraints(maxWidth: _maxCanvasWidth),
                      child: Material(
                        color: Colors.transparent,
                        child: RepaintBoundary(
                          key: _shotKey,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: cs.outlineVariant.withOpacity(.28),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(.16),
                                  blurRadius: 24,
                                  offset: const Offset(0, 10),
                                )
                              ],
                            ),
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_showHeader) _buildHeader(cs),

                                if (_showQuickStats &&
                                    _quickShow.contains(true)) ...[
                                  const SizedBox(height: 20),
                                  _buildQuickStats(sections),
                                ],

                                if (_showDetails && cards.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  const Divider(),
                                  const SizedBox(height: 10),
                                  ...cards.map(
                                        (c) => Padding(
                                      padding:
                                      const EdgeInsets.only(bottom: 16),
                                      child: c,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}