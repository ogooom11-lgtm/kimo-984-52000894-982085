// lib/widgets/scroll_edge_buttons.dart
// زرّا «إلى الأعلى» و«إلى الأسفل» فوق قائمة طويلة (صفحة التسليم وصفحة الإضافة).

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// يضع زرّين صغيرين فوق [child] للقفز إلى أول القائمة أو آخرها.
///
/// - يظهران فقط إذا كانت القائمة أطول من الشاشة بشكل واضح.
/// - يخفت كل زر ويتعطّل عندما تكون القائمة عند طرفه.
/// - يعملان مع القوائم الكسولة (ListView.builder): طول العناصر غير المبنية
///   تقديري، فعند النزول نكرر القفز إلى آخر القائمة حتى يثبت طولها.
/// - [controller] يجب أن يكون هو نفسه المربوط بالقائمة. إذا ارتبط مؤقتًا بأكثر
///   من قائمة (أثناء تبديل متحرك مثلًا) نستخدم أحدثها.
class ScrollEdgeButtons extends StatefulWidget {
  final ScrollController controller;
  final Widget child;

  /// المسافة من أسفل المنطقة.
  final double bottom;

  /// المسافة من طرف النهاية (يسار الشاشة في الواجهة العربية).
  final double end;

  const ScrollEdgeButtons({
    super.key,
    required this.controller,
    required this.child,
    this.bottom = 16,
    this.end = 12,
  });

  @override
  State<ScrollEdgeButtons> createState() => _ScrollEdgeButtonsState();
}

class _ScrollEdgeButtonsState extends State<ScrollEdgeButtons> {
  /// أقل طول قابل للتمرير حتى تظهر الأزرار.
  static const double _minScrollable = 400;

  /// هامش اعتبار القائمة عند طرفها.
  static const double _edge = 24;

  bool _scrollable = false;
  bool _atTop = true;
  bool _atBottom = true;
  bool _jumping = false;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant ScrollEdgeButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _scheduleSync();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  /// أحدث قائمة مربوطة بالمتحكم (أو null).
  ScrollPosition? get _position {
    final positions = widget.controller.positions;
    return positions.isEmpty ? null : positions.last;
  }

  /// نؤجل الفحص لما بعد الإطار: تغيّر طول القائمة يصل أثناء البناء/التخطيط.
  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      _sync();
    });
  }

  void _sync() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // أثناء البناء/التخطيط لا يجوز setState: نعيد الفحص بعد الإطار
      _scheduleSync();
      return;
    }
    final p = _position;
    var scrollable = false;
    var atTop = true;
    var atBottom = true;
    if (p != null && p.hasContentDimensions && p.hasPixels) {
      scrollable = p.maxScrollExtent - p.minScrollExtent > _minScrollable;
      atTop = p.pixels <= p.minScrollExtent + _edge;
      atBottom = p.pixels >= p.maxScrollExtent - _edge;
    }
    if (scrollable == _scrollable && atTop == _atTop && atBottom == _atBottom) {
      return;
    }
    setState(() {
      _scrollable = scrollable;
      _atTop = atTop;
      _atBottom = atBottom;
    });
  }

  Future<void> _toTop() async {
    final p = _position;
    if (p == null || !p.hasContentDimensions) return;
    final distance = p.pixels - p.minScrollExtent;
    if (distance <= 0) return;
    if (distance > p.viewportDimension * 3) {
      // مسافة طويلة: قفزة مباشرة بدل بناء كل العناصر أثناء الحركة
      p.jumpTo(p.minScrollExtent);
    } else {
      await p.animateTo(
        p.minScrollExtent,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _toBottom() async {
    if (_jumping) return;
    _jumping = true;
    try {
      var p = _position;
      if (p == null || !p.hasContentDimensions) return;
      if (p.maxScrollExtent - p.pixels <= p.viewportDimension * 2) {
        await p.animateTo(
          p.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      // القوائم الكسولة: بعد كل قفزة تُبنى عناصر جديدة وقد يزيد الطول الحقيقي
      for (var i = 0; i < 12; i++) {
        if (!mounted) return;
        p = _position;
        if (p == null || !p.hasContentDimensions) return;
        final target = p.maxScrollExtent;
        if ((target - p.pixels).abs() < 1) break;
        p.jumpTo(target);
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      _jumping = false;
      _sync();
    }
  }

  Widget _button({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      opacity: enabled ? 1 : .35,
      duration: const Duration(milliseconds: 160),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: cs.secondaryContainer.withValues(alpha: .94),
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: Colors.black38,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? onTap : null,
            child: SizedBox(
              width: 42,
              height: 42,
              child: Icon(icon, size: 24, color: cs.onSecondaryContainer),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      // تغيّر طول القائمة (فقاعات جديدة، فلترة...) بدون تمرير
      onNotification: (n) {
        if (n.depth == 0) _scheduleSync();
        return false;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          PositionedDirectional(
            end: widget.end,
            bottom: widget.bottom,
            child: IgnorePointer(
              ignoring: !_scrollable,
              child: AnimatedOpacity(
                opacity: _scrollable ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _button(
                      icon: Icons.keyboard_double_arrow_up_rounded,
                      tooltip: 'إلى الأعلى',
                      enabled: !_atTop,
                      onTap: _toTop,
                    ),
                    const SizedBox(height: 8),
                    _button(
                      icon: Icons.keyboard_double_arrow_down_rounded,
                      tooltip: 'إلى الأسفل',
                      enabled: !_atBottom,
                      onTap: _toBottom,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
