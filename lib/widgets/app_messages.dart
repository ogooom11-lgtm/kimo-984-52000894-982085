// lib/widgets/app_messages.dart
// -------------------------------------------------------------
// رسائل النجاح والخطأ (SnackBar) بشكل موحّد بكل التطبيق:
//  • كل رسالة بتنعرف لحالها: نجاح (أخضر)، خطأ (أحمر)، تنبيه (برتقالي)،
//    أو معلومة — حسب نصها («تم…»، «تعذّر…»، «لا توجد…») أو لونها.
//  • بأعلى الشاشة (افتراضيًا) حتى ما تغطي أزرار الحفظ تحت، أو تحت.
//  • قابلة للتخصيص من الإعدادات: المكان، المدة، الشكل، الأيقونة، حجم الخط،
//    وزر الإغلاق.
// ما في داعي نغيّر أي مكان بيعرض رسالة: [StyledScaffoldMessenger] بأعلى
// التطبيق بيعيد تنسيق كل SnackBar قبل ما يظهر.
// -------------------------------------------------------------

import 'dart:async';

import 'package:flutter/material.dart';

import '../database_service.dart';

enum AppMessageKind { success, error, warning, info }

extension AppMessageKindInfo on AppMessageKind {
  String get label {
    switch (this) {
      case AppMessageKind.success:
        return 'نجاح';
      case AppMessageKind.error:
        return 'خطأ';
      case AppMessageKind.warning:
        return 'تنبيه';
      case AppMessageKind.info:
        return 'معلومة';
    }
  }

  Color get color {
    switch (this) {
      case AppMessageKind.success:
        return const Color(0xFF059669);
      case AppMessageKind.error:
        return const Color(0xFFDC2626);
      case AppMessageKind.warning:
        return const Color(0xFFD97706);
      case AppMessageKind.info:
        return const Color(0xFF2563EB);
    }
  }

  IconData get icon {
    switch (this) {
      case AppMessageKind.success:
        return Icons.check_circle_rounded;
      case AppMessageKind.error:
        return Icons.error_rounded;
      case AppMessageKind.warning:
        return Icons.warning_amber_rounded;
      case AppMessageKind.info:
        return Icons.info_rounded;
    }
  }
}

/// تخصيص الرسائل
class AppMessagePrefs {
  /// فوق الشاشة (افتراضي) أو تحت
  final bool top;

  /// 0 قصيرة، 1 عادية، 2 طويلة
  final int duration;

  /// 0 ملوّنة، 1 ناعمة (فاتحة مع إطار ملوّن)، 2 داكنة
  final int style;
  final bool showIcon;
  final bool largeText;
  final bool showClose;

  const AppMessagePrefs({
    this.top = true,
    this.duration = 1,
    this.style = 0,
    this.showIcon = true,
    this.largeText = false,
    this.showClose = false,
  });

  static const List<Duration> durations = [
    Duration(milliseconds: 2500),
    Duration(seconds: 4),
    Duration(milliseconds: 6500),
  ];

  Duration get displayDuration => durations[duration.clamp(0, 2)];

  factory AppMessagePrefs.fromMap(Object? raw) {
    if (raw is! Map) return const AppMessagePrefs();
    int i(String k, int d, int max) {
      final v = raw[k];
      return (v is num ? v.toInt() : d).clamp(0, max);
    }

    bool b(String k, bool d) {
      final v = raw[k];
      return v is bool ? v : d;
    }

    return AppMessagePrefs(
      top: b('top', true),
      duration: i('duration', 1, 2),
      style: i('style', 0, 2),
      showIcon: b('showIcon', true),
      largeText: b('largeText', false),
      showClose: b('showClose', false),
    );
  }

  Map<String, dynamic> toMap() => {
    'top': top,
    'duration': duration,
    'style': style,
    'showIcon': showIcon,
    'largeText': largeText,
    'showClose': showClose,
  };

  AppMessagePrefs copyWith({
    bool? top,
    int? duration,
    int? style,
    bool? showIcon,
    bool? largeText,
    bool? showClose,
  }) => AppMessagePrefs(
    top: top ?? this.top,
    duration: duration ?? this.duration,
    style: style ?? this.style,
    showIcon: showIcon ?? this.showIcon,
    largeText: largeText ?? this.largeText,
    showClose: showClose ?? this.showClose,
  );
}

class AppMessages {
  AppMessages._();

  static const String _prefsKey = 'app_messages';
  static const String _kindKeyPrefix = 'app_msg:';

  static final ValueNotifier<AppMessagePrefs> prefs =
      ValueNotifier<AppMessagePrefs>(const AppMessagePrefs());

  /// يقرأ التخصيص المحفوظ (بعد فتح صناديق Hive)
  static void load() {
    try {
      prefs.value = AppMessagePrefs.fromMap(
        DatabaseService.uiPrefsBoxOrNull?.get(_prefsKey),
      );
    } catch (_) {}
  }

  static Future<void> save(AppMessagePrefs p) async {
    prefs.value = p;
    try {
      await DatabaseService.uiPrefsBoxOrNull?.put(_prefsKey, p.toMap());
    } catch (_) {}
  }

  /// يعرض رسالة بنوع محدد (للأماكن الجديدة). الأماكن القديمة بتنعرف لحالها.
  static void show(
    BuildContext context,
    String text, {
    AppMessageKind? kind,
    SnackBarAction? action,
    Duration? duration,
  }) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: kind == null
              ? null
              : ValueKey<String>('$_kindKeyPrefix${kind.name}'),
          content: Text(text),
          action: action,
          duration: duration ?? const Duration(milliseconds: 4000),
        ),
      );
  }

  static AppMessageKind? _kindFromKey(Key? key) {
    if (key is! ValueKey<String>) return null;
    final v = key.value;
    if (!v.startsWith(_kindKeyPrefix)) return null;
    final name = v.substring(_kindKeyPrefix.length);
    for (final k in AppMessageKind.values) {
      if (k.name == name) return k;
    }
    return null;
  }

  static final RegExp _done = RegExp(
    '(?<![\u0600-\u06FF])(تمت?|أُضيف|أضيف|اضيف|انضاف|انضافت|انحفظ|انحفظت|'
    'نُسخ|نسخت|نُسخت|انعملت|انعمل|انمسح|انمسحت|انحذف|انحذفت|حُذف|حذفت|'
    'صار|صارت|رجعت|رجع|تحدّث|تحدث|تحدّثت|انخفت)(?![\u0600-\u06FF])',
  );

  /// نوع الرسالة من نصها (ولونها إذا محدد)
  static AppMessageKind classify(String text, {Color? background}) {
    final t = text.trim();
    if (background != null && _isReddish(background)) {
      return AppMessageKind.error;
    }
    bool has(List<String> words) => words.any(t.contains);
    if (t.contains('❌') ||
        has(const [
          'تعذر',
          'تعذّر',
          'خطأ',
          'فشل',
          'فشلت',
          'Exception',
          'Error',
          'error',
          'لم يتم الحفظ',
        ])) {
      return AppMessageKind.error;
    }
    if (t.contains('⚠') ||
        has(const [
          'لا توجد',
          'لا يوجد',
          'لم يتم العثور',
          'لم يعد',
          'ما عاد',
          'ما عادت',
          'ما في ',
          'مو صحيح',
          'غير صحيح',
          'مو موجود',
          'غير موجود',
          'موجودة مسبق',
          'موجود مسبق',
          'أدخل',
          'ادخل',
          'حدد ',
          'اختر ',
          'اختار ',
          'أضف ',
          'انتظر',
          'لازم',
          'فارغة',
          'فاضية',
          'فارغ',
          'فاضي',
          'متاحة على أندرويد',
          'متوفرة على أندرويد',
          'ما قدرنا',
          'ما انضاف',
          'مو جاهزة',
          'لسا مو',
          'انتبه',
          'تنبيه',
        ])) {
      return AppMessageKind.warning;
    }
    if (t.contains('✓') ||
        t.contains('✅') ||
        t.contains('بنجاح') ||
        _done.hasMatch(t)) {
      return AppMessageKind.success;
    }
    return AppMessageKind.info;
  }

  static bool _isReddish(Color c) {
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    return r > 150 && g < 110 && b < 110;
  }

  /// النص داخل محتوى الرسالة (إذا كان نص)
  static String? textOf(Widget content) {
    if (content is Text) return content.data ?? content.textSpan?.toPlainText();
    if (content is RichText) return content.text.toPlainText();
    return null;
  }
}

// =============================================================
// شكل الرسالة
// =============================================================

/// ألوان الرسالة حسب النوع والشكل
class _Palette {
  final Color background;
  final Color foreground;
  final Color iconColor;
  final Color iconBackground;
  final Color? border;

  const _Palette({
    required this.background,
    required this.foreground,
    required this.iconColor,
    required this.iconBackground,
    this.border,
  });

  factory _Palette.of(BuildContext context, AppMessageKind kind, int style) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = kind.color;
    switch (style) {
      case 1: // ناعمة
        return _Palette(
          background: dark
              ? Color.alphaBlend(
                  c.withValues(alpha: .20),
                  const Color(0xFF1E2230),
                )
              : Color.alphaBlend(c.withValues(alpha: .09), Colors.white),
          foreground: dark ? Colors.white : const Color(0xFF1E293B),
          iconColor: dark ? Color.lerp(c, Colors.white, .25)! : c,
          iconBackground: c.withValues(alpha: dark ? .28 : .14),
          border: c.withValues(alpha: dark ? .55 : .40),
        );
      case 2: // داكنة
        return _Palette(
          background: const Color(0xFF1F2937),
          foreground: Colors.white,
          iconColor: Color.lerp(c, Colors.white, .15)!,
          iconBackground: c.withValues(alpha: .25),
        );
      default: // ملوّنة
        return _Palette(
          background: dark ? Color.lerp(c, Colors.black, .15)! : c,
          foreground: Colors.white,
          iconColor: Colors.white,
          iconBackground: Colors.white.withValues(alpha: .20),
        );
    }
  }
}

/// محتوى الرسالة: أيقونة + النص
class _MessageBody extends StatelessWidget {
  final AppMessageKind kind;
  final String? text;
  final Widget content;
  final AppMessagePrefs prefs;
  final _Palette palette;

  const _MessageBody({
    required this.kind,
    required this.text,
    required this.content,
    required this.prefs,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: palette.foreground,
      fontSize: prefs.largeText ? 16 : 14,
      fontWeight: FontWeight.w700,
      height: 1.35,
    );
    final body = text != null
        ? Text(text!, style: style)
        : DefaultTextStyle.merge(style: style, child: content);
    if (!prefs.showIcon) return body;
    return Row(
      children: [
        Container(
          width: prefs.largeText ? 34 : 30,
          height: prefs.largeText ? 34 : 30,
          decoration: BoxDecoration(
            color: palette.iconBackground,
            shape: BoxShape.circle,
          ),
          child: Icon(
            kind.icon,
            size: prefs.largeText ? 21 : 19,
            color: palette.iconColor,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: body),
      ],
    );
  }
}

// =============================================================
// المرسال: يعيد تنسيق كل SnackBar
// =============================================================

/// بديل ScaffoldMessenger بأعلى التطبيق (MaterialApp.builder): كل رسالة
/// بتنعرض بالشكل والمكان المختارين بالإعدادات.
class StyledScaffoldMessenger extends ScaffoldMessenger {
  const StyledScaffoldMessenger({super.key, required super.child});

  @override
  ScaffoldMessengerState createState() => _StyledMessengerState();
}

class _Toast {
  /// false = رسالة تحت (SnackBar عادي)، بس منسجلها حتى يضل الطابور متطابق
  final bool top;
  final AppMessageKind kind;
  final String? text;
  final Widget content;
  final SnackBarAction? action;
  final Duration duration;
  final bool showClose;

  _Toast({
    required this.top,
    required this.kind,
    required this.text,
    required this.content,
    required this.action,
    required this.duration,
    required this.showClose,
  });
}

class _StyledMessengerState extends ScaffoldMessengerState {
  /// الرسالة الظاهرة فوق الشاشة (null = ما في)
  final ValueNotifier<_Toast?> _toast = ValueNotifier<_Toast?>(null);

  /// نفس ترتيب طابور SnackBar الداخلي: الأولى هي الحالية
  final List<_Toast> _queue = [];

  /// رسائل انطلب إغلاقها وعم تتسكّر
  final Set<_Toast> _closing = <_Toast>{};

  /// الرسالة المعروضة حاليًا (فوق أو تحت)
  _Toast? _displayed;
  Timer? _toastTimer;

  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    final p = AppMessages.prefs.value;
    final text = AppMessages.textOf(snackBar.content);
    final kind =
        AppMessages._kindFromKey(snackBar.key) ??
        AppMessages.classify(text ?? '', background: snackBar.backgroundColor);
    // المدة الافتراضية (4 ثواني) بتتبع الإعدادات، والمدة المخصصة بتضل متل ما هي
    final duration = snackBar.duration == const Duration(milliseconds: 4000)
        ? p.displayDuration
        : snackBar.duration;
    final entry = _Toast(
      top: p.top,
      kind: kind,
      text: text,
      content: snackBar.content,
      action: snackBar.action,
      duration: duration,
      showClose: snackBar.showCloseIcon ?? p.showClose,
    );

    final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller;
    if (!p.top) {
      controller = super.showSnackBar(
        _styledBottom(snackBar, kind, text, duration, p),
        snackBarAnimationStyle: snackBarAnimationStyle,
      );
    } else {
      // فوق: الرسالة بتنرسم بأعلى الشاشة، ومعها SnackBar مخفي (بدون حجم)
      // حتى يضل الإغلاق والتراجع والطابور متل ما هم بكل الشاشات.
      controller = super.showSnackBar(
        SnackBar(
          content: const SizedBox.shrink(),
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          margin: EdgeInsets.zero,
          behavior: SnackBarBehavior.floating,
          duration: duration,
          dismissDirection: DismissDirection.none,
          hitTestBehavior: HitTestBehavior.deferToChild,
          onVisible: snackBar.onVisible,
        ),
        snackBarAnimationStyle: snackBarAnimationStyle,
      );
    }
    _queue.add(entry);
    _showNextIfIdle();
    controller.closed.then((_) => _onClosed(entry));
    return controller;
  }

  SnackBar _styledBottom(
    SnackBar s,
    AppMessageKind kind,
    String? text,
    Duration duration,
    AppMessagePrefs p,
  ) {
    final palette = _Palette.of(context, kind, p.style);
    final action = s.action;
    return SnackBar(
      key: s.key,
      content: _MessageBody(
        kind: kind,
        text: text,
        content: s.content,
        prefs: p,
        palette: palette,
      ),
      backgroundColor: palette.background,
      elevation: 6,
      behavior: SnackBarBehavior.floating,
      width: s.width,
      margin: s.width == null ? const EdgeInsets.fromLTRB(12, 0, 12, 12) : null,
      padding: const EdgeInsetsDirectional.fromSTEB(14, 2, 8, 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: palette.border == null
            ? BorderSide.none
            : BorderSide(color: palette.border!),
      ),
      action: action == null
          ? null
          : SnackBarAction(
              label: action.label,
              onPressed: action.onPressed,
              textColor: palette.foreground,
            ),
      actionOverflowThreshold: s.actionOverflowThreshold,
      showCloseIcon: s.showCloseIcon ?? p.showClose,
      closeIconColor: palette.foreground,
      duration: duration,
      onVisible: s.onVisible,
      dismissDirection: s.dismissDirection,
      hitTestBehavior: s.hitTestBehavior,
      clipBehavior: s.clipBehavior,
    );
  }

  /// يعرض أول رسالة منتظرة إذا ما في وحدة معروضة
  void _showNextIfIdle() {
    final d = _displayed;
    if (d != null && !_closing.contains(d)) return;
    for (final t in _queue) {
      if (_closing.contains(t)) continue;
      _display(t);
      return;
    }
  }

  void _display(_Toast t) {
    _toastTimer?.cancel();
    _displayed = t;
    if (!t.top) {
      if (_toast.value != null) _toast.value = null;
      return;
    }
    _toast.value = t;
    // احتياط: الرسالة بتختفي بعد مدتها حتى لو ما في شاشة تعرض المخفي
    _toastTimer = Timer(t.duration + const Duration(milliseconds: 900), () {
      if (identical(_toast.value, t)) _toast.value = null;
    });
  }

  void _hideDisplayed() {
    _toastTimer?.cancel();
    _displayed = null;
    if (_toast.value != null) _toast.value = null;
  }

  void _onClosed(_Toast t) {
    if (!mounted) return;
    _queue.remove(t);
    _closing.remove(t);
    if (identical(_displayed, t)) _hideDisplayed();
    _showNextIfIdle();
  }

  /// الحالية عم تتسكّر: منخفيها فورًا حتى الرسالة الجاية تبين بدون تأخير
  void _markCurrentClosing() {
    if (_queue.isEmpty) return;
    final cur = _queue.first;
    _closing.add(cur);
    if (identical(_displayed, cur)) _hideDisplayed();
  }

  @override
  void hideCurrentSnackBar({
    SnackBarClosedReason reason = SnackBarClosedReason.hide,
  }) {
    _markCurrentClosing();
    super.hideCurrentSnackBar(reason: reason);
  }

  @override
  void removeCurrentSnackBar({
    SnackBarClosedReason reason = SnackBarClosedReason.remove,
  }) {
    _markCurrentClosing();
    super.removeCurrentSnackBar(reason: reason);
  }

  @override
  void clearSnackBars() {
    // المنتظرة بتنحذف بدون ما «تتسكّر»، فمنحذفها من طابورنا كمان
    if (_queue.length > 1) {
      for (final t in _queue.sublist(1)) {
        _closing.remove(t);
      }
      _queue.removeRange(1, _queue.length);
    }
    super.clearSnackBars();
  }

  /// إغلاق الرسالة الظاهرة من فوق (سحب أو ضغطة أو زر الإجراء)
  void _dismissToast(_Toast t, SnackBarClosedReason reason) {
    if (_queue.isNotEmpty && identical(_queue.first, t)) {
      hideCurrentSnackBar(reason: reason);
    } else if (identical(_toast.value, t)) {
      _hideDisplayed();
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _toast.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.rtl,
      fit: StackFit.expand,
      children: [
        super.build(context),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _TopToastLayer(notifier: _toast, onDismiss: _dismissToast),
        ),
      ],
    );
  }
}

/// طبقة الرسالة بأعلى الشاشة (فوق كل الصفحات)
class _TopToastLayer extends StatelessWidget {
  final ValueNotifier<_Toast?> notifier;
  final void Function(_Toast toast, SnackBarClosedReason reason) onDismiss;

  const _TopToastLayer({required this.notifier, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: ValueListenableBuilder<_Toast?>(
        valueListenable: notifier,
        builder: (context, toast, _) {
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            reverseDuration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.6),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, if (current != null) current],
            ),
            child: toast == null
                ? const SizedBox(key: ValueKey('no-toast'), width: 0, height: 0)
                : _TopToast(
                    key: ObjectKey(toast),
                    toast: toast,
                    onDismiss: (reason) => onDismiss(toast, reason),
                  ),
          );
        },
      ),
    );
  }
}

class _TopToast extends StatelessWidget {
  final _Toast toast;
  final ValueChanged<SnackBarClosedReason> onDismiss;

  const _TopToast({super.key, required this.toast, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final p = AppMessages.prefs.value;
    final palette = _Palette.of(context, toast.kind, p.style);
    final action = toast.action;
    final topInset = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, topInset + 8, 12, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Dismissible(
            key: ObjectKey(toast),
            direction: DismissDirection.up,
            onDismissed: (_) => onDismiss(SnackBarClosedReason.swipe),
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Material(
                color: palette.background,
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: .35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: palette.border == null
                      ? BorderSide.none
                      : BorderSide(color: palette.border!),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onDismiss(SnackBarClosedReason.hide),
                  child: Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(
                      12,
                      10,
                      action != null || toast.showClose ? 4 : 12,
                      10,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _MessageBody(
                            kind: toast.kind,
                            text: toast.text,
                            content: toast.content,
                            prefs: p,
                            palette: palette,
                          ),
                        ),
                        if (action != null)
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: palette.foreground,
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            onPressed: () {
                              action.onPressed();
                              onDismiss(SnackBarClosedReason.action);
                            },
                            child: Text(action.label),
                          ),
                        if (toast.showClose)
                          IconButton(
                            // بدون tooltip: ما في Overlay بهالمستوى
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                onDismiss(SnackBarClosedReason.dismiss),
                            icon: Icon(
                              Icons.close_rounded,
                              size: 19,
                              color: palette.foreground,
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
      ),
    );
  }
}
