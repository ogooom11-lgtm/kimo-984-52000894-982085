import 'dart:async';
import 'dart:io' show Directory;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/all_accounts_stats_screen.dart';
import 'database_service.dart';
import 'models.dart';
import 'theme/app_theme.dart';
import 'screens/timeline_analytics_screen.dart';
import 'services/app_lock.dart';
import 'widgets/app_messages.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Hive.initFlutter();
  } catch (e, s) {
    debugPrint('Startup error: $e');
    debugPrintStack(stackTrace: s);
    if (AppLock.dateReached) {
      runApp(const AppErrorScreen());
      return;
    }
    rethrow;
  }

  // القفل (صفحة بيضا مع رسالة خطأ): التاريخ وصل هلق، أو وصل قبل وانسجّل
  // حتى لو رجّعوا تاريخ الموبايل لورا
  if (await AppLock.init(dir: await _appFilesDir())) {
    runApp(const AppErrorScreen());
    return;
  }

  try {
    Hive.registerAdapter(TransactionStatusAdapter());
    Hive.registerAdapter(AccountTypeAdapter());
    Hive.registerAdapter(CompanyMovementTypeAdapter());
    Hive.registerAdapter(AccountAdapter());
    Hive.registerAdapter(TransactionModelAdapter());
    Hive.registerAdapter(BubbleQuickActionConfigAdapter());
    Hive.registerAdapter(SettingsAdapter());
    Hive.registerAdapter(ParsedTextAdapter());

    await DatabaseService.init();

    runApp(const MyApp());
  } catch (e, s) {
    debugPrint('Startup error: $e');
    debugPrintStack(stackTrace: s);
    rethrow;
  }
}

/// مجلد ملفات التطبيق (فيه نسخة تانية من علامة القفل)
Future<Directory?> _appFilesDir() async {
  try {
    return await getApplicationSupportDirectory();
  } catch (_) {
    return null;
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
        home: const MainLayout(),
      ),
    );
  }
}

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> with WidgetsBindingObserver {
  int _currentIndex = 0;
  Timer? _lockTimer;

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
    // التاريخ ممكن يوصل والتطبيق مفتوح
    _lockTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _checkLock(),
    );
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // التطبيق كان بالخلفية ورجع بعد تاريخ القفل
    if (state == AppLifecycleState.resumed) _checkLock();
  }

  /// وصل تاريخ القفل؟ منسجّله ومنقفل
  void _checkLock() {
    if (!AppLock.check()) return;
    _lockTimer?.cancel();
    runApp(const AppErrorScreen());
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
