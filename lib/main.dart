import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/all_accounts_stats_screen.dart';
import 'database_service.dart';
import 'models.dart';
import 'theme/app_theme.dart';
import 'screens/timeline_analytics_screen.dart';
import 'services/tx_history_service.dart';
import 'widgets/app_messages.dart';

/// من هاليوم وطالع التطبيق ما بيفتح (صفحة بيضا مع رسالة خطأ)
final DateTime _kLockDate = DateTime(2026, 10, 18);

bool get _appLocked => !DateTime.now().isBefore(_kLockDate);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_appLocked) {
    runApp(const AppErrorScreen());
    return;
  }

  try {
    await Hive.initFlutter();

    Hive.registerAdapter(TransactionStatusAdapter());
    Hive.registerAdapter(AccountTypeAdapter());
    Hive.registerAdapter(CompanyMovementTypeAdapter());
    Hive.registerAdapter(AccountAdapter());
    Hive.registerAdapter(TransactionModelAdapter());
    Hive.registerAdapter(BubbleQuickActionConfigAdapter());
    Hive.registerAdapter(SettingsAdapter());
    Hive.registerAdapter(ParsedTextAdapter());

    await DatabaseService.init();

    // سجل تعديلات الحركات: يراقب كل تغيير على الحركات من أي شاشة
    try {
      TxHistoryService.start();
    } catch (e) {
      debugPrint('TxHistory start error: $e');
    }

    runApp(const MyApp());
  } catch (e, s) {
    debugPrint('Startup error: $e');
    debugPrintStack(stackTrace: s);
    rethrow;
  }
}

/// صفحة بيضا مع رسالة خطأ (بعد تاريخ القفل)
class AppErrorScreen extends StatelessWidget {
  const AppErrorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFD32F2F),
                    size: 56,
                  ),
                  SizedBox(height: 18),
                  Text(
                    'Error',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF212121),
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    "A malfunction has occurred in the application's "
                    'functions.\nThe application cannot be opened.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF424242),
                      fontSize: 16,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: MaterialApp(
        title: 'مدير الحسابات',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.system,
        debugShowCheckedModeBanner: false,
        // كل رسائل النجاح والخطأ بتنعرض بشكل موحّد
        builder: (context, child) =>
            StyledScaffoldMessenger(child: child ?? const SizedBox.shrink()),
        home: const StartupSignatureScreen(),
      ),
    );
  }
}

class StartupSignatureScreen extends StatefulWidget {
  const StartupSignatureScreen({super.key});

  @override
  State<StartupSignatureScreen> createState() => _StartupSignatureScreenState();
}

class _StartupSignatureScreenState extends State<StartupSignatureScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _write;
  late final Animation<double> _titleFade;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _write = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.04, 0.86, curve: Curves.easeInOutCubic),
    );
    _titleFade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.62, 1.0, curve: Curves.easeOutCubic),
    );

    _controller.forward();
    Future<void>.delayed(const Duration(milliseconds: 2750), () {
      if (!mounted) return;
      setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark
        ? const Color(0xFF222426)
        : const Color(0xFFE7E7E4);
    final ink = isDark ? const Color(0xFFEFEFEB) : const Color(0xFF242526);
    final mutedInk = isDark ? const Color(0xFFBEBEB8) : const Color(0xFF686A6B);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 520),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: _done
          ? const MainLayout()
          : Scaffold(
              key: const ValueKey('startup-signature'),
              backgroundColor: background,
              body: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return Center(
                    child: SizedBox(
                      width: 400,
                      height: 290,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ScaleTransition(
                            scale: Tween<double>(begin: 0.78, end: 1).animate(
                              CurvedAnimation(
                                parent: _controller,
                                curve: Curves.easeOutBack,
                              ),
                            ),
                            child: FadeTransition(
                              opacity: _titleFade,
                              child: Container(
                                width: 240,
                                height: 240,

                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(50),
                                  child: Image.asset(
                                    'assets/icons/app_icon.png',
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          FadeTransition(
                            opacity: _titleFade,
                            child: Text(
                              'مدير الحسابات',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: mutedInk,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class _StartupSignaturePainter extends CustomPainter {
  final double progress;
  final Color ink;
  final Color mutedInk;

  const _StartupSignaturePainter({
    required this.progress,
    required this.ink,
    required this.mutedInk,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 330;
    canvas.save();
    canvas.scale(scale, scale);

    final paths = _signaturePaths();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 7.2
      ..color = ink;

    _drawPartialPaths(canvas, paths, progress.clamp(0.0, 1.0), stroke);

    final tip = _pointAt(paths, progress.clamp(0.0, 1.0));
    if (tip != null && progress < .98) {
      canvas.drawCircle(
        tip,
        5.2,
        Paint()
          ..style = PaintingStyle.fill
          ..color = ink,
      );
      canvas.drawCircle(
        tip,
        12,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = mutedInk.withOpacity(.35),
      );
    }

    if (progress > .78) {
      final dotOpacity = ((progress - .78) / .22).clamp(0.0, 1.0);
      final dotPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = ink.withOpacity(dotOpacity);
      canvas.drawCircle(const Offset(238, 36), 4.4, dotPaint);
      canvas.drawCircle(const Offset(254, 31), 3.2, dotPaint);
    }

    canvas.restore();
  }

  List<Path> _signaturePaths() {
    final first = Path()
      ..moveTo(24, 96)
      ..cubicTo(55, 58, 90, 48, 111, 78)
      ..cubicTo(130, 105, 99, 128, 80, 102)
      ..cubicTo(57, 70, 110, 35, 158, 55)
      ..cubicTo(203, 74, 184, 125, 137, 111)
      ..cubicTo(187, 136, 254, 105, 304, 48);

    final second = Path()
      ..moveTo(43, 119)
      ..cubicTo(97, 135, 179, 137, 288, 116);

    final third = Path()
      ..moveTo(197, 87)
      ..cubicTo(218, 66, 241, 60, 264, 72)
      ..cubicTo(284, 82, 275, 102, 251, 98);

    return [first, third, second];
  }

  void _drawPartialPaths(
    Canvas canvas,
    List<Path> paths,
    double value,
    Paint paint,
  ) {
    final metrics = paths.expand((path) => path.computeMetrics()).toList();
    final totalLength = metrics.fold<double>(
      0,
      (sum, metric) => sum + metric.length,
    );
    var remaining = totalLength * value;

    for (final metric in metrics) {
      if (remaining <= 0) break;
      final length = remaining.clamp(0.0, metric.length);
      canvas.drawPath(metric.extractPath(0, length), paint);
      remaining -= metric.length;
    }
  }

  Offset? _pointAt(List<Path> paths, double value) {
    final metrics = paths.expand((path) => path.computeMetrics()).toList();
    final totalLength = metrics.fold<double>(
      0,
      (sum, metric) => sum + metric.length,
    );
    var remaining = totalLength * value;

    for (final metric in metrics) {
      if (remaining <= metric.length) {
        return metric
            .getTangentForOffset(remaining.clamp(0.0, metric.length))
            ?.position;
      }
      remaining -= metric.length;
    }

    if (metrics.isEmpty) return null;
    final last = metrics.last;
    return last.getTangentForOffset(last.length)?.position;
  }

  @override
  bool shouldRepaint(covariant _StartupSignaturePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.ink != ink ||
        oldDelegate.mutedInk != mutedInk;
  }
}

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> with WidgetsBindingObserver {
  int _currentIndex = 0;

  static const List<Widget> _pages = [
    HomeScreen(),
    AllAccountsStatsScreen(),
    SettingsScreen(),
    TimelineAnalyticsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // التطبيق كان بالخلفية ورجع بعد تاريخ القفل
    if (state == AppLifecycleState.resumed && _appLocked) {
      runApp(const AppErrorScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(opacity: animation, child: child);
        },
        child: KeyedSubtree(
          key: ValueKey(_currentIndex),
          child: _pages[_currentIndex],
        ),
      ),
      bottomNavigationBar: _CompactBottomBar(
        currentIndex: _currentIndex,
        onSelect: (i) => setState(() => _currentIndex = i),
      ),
    );
  }
}

class _CompactBottomBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelect;

  const _CompactBottomBar({required this.currentIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    const items = <(String, IconData, IconData)>[
      ('الرئيسية', Icons.home_outlined, Icons.home_rounded),
      ('الإحصائيات', Icons.bar_chart_rounded, Icons.insert_chart_rounded),
      ('الإعدادات', Icons.settings_outlined, Icons.settings_rounded),
      ('زمنية', Icons.timeline, Icons.timeline_sharp),
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              height: 74,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [
                    cs.surface.withOpacity(isDark ? 0.92 : 0.97),
                    cs.surfaceContainerHighest.withOpacity(
                      isDark ? 0.82 : 0.93,
                    ),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withOpacity(isDark ? 0.08 : 0.7),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.22 : 0.08),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _BottomItem(
                        label: items[i].$1,
                        icon: items[i].$2,
                        selectedIcon: items[i].$3,
                        selected: currentIndex == i,
                        onTap: () => onSelect(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  const _BottomItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: selected ? 22 : 0,
                height: 3,
                margin: const EdgeInsets.only(bottom: 5),
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Icon(
                selected ? selectedIcon : icon,
                color: selected ? cs.primary : cs.onSurfaceVariant,
                size: 20,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.2,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
