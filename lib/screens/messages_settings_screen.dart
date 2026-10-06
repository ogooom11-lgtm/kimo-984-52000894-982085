// lib/screens/messages_settings_screen.dart
// -------------------------------------------------------------
// تخصيص رسائل النجاح والخطأ (الرسائل الصغيرة يلي بتطلع بعد أي عملية):
// المكان (فوق/تحت)، المدة، الشكل، الأيقونة، حجم الخط، وزر الإغلاق — مع
// أزرار تجربة لكل نوع.
// -------------------------------------------------------------

import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/app_messages.dart';

class MessagesSettingsScreen extends StatelessWidget {
  const MessagesSettingsScreen({super.key});

  static const _samples = <AppMessageKind, String>{
    AppMessageKind.success: 'تم حفظ 3 حركات ✓',
    AppMessageKind.error: 'تعذّر الحفظ: الملف مو مقروء',
    AppMessageKind.warning: 'لا توجد إضافات مكتملة للتنفيذ',
    AppMessageKind.info: 'اسحب الفقاعة لأي مكان بالشاشة',
  };

  void _set(AppMessagePrefs p) => unawaited(AppMessages.save(p));

  void _try(BuildContext context, AppMessageKind kind) {
    AppMessages.show(
      context,
      _samples[kind]!,
      kind: kind,
      action: kind == AppMessageKind.success
          ? SnackBarAction(label: 'تراجع', onPressed: () {})
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: dark ? null : const Color(0xFFF6F8FC),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          title: const Text(
            'رسائل النجاح والخطأ',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19),
          ),
        ),
        body: ValueListenableBuilder<AppMessagePrefs>(
          valueListenable: AppMessages.prefs,
          builder: (context, p, _) {
            Widget card(Widget child) => Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: dark ? cs.surfaceContainer : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: .4),
                ),
              ),
              child: child,
            );
            Widget title(String t) => Padding(
              padding: const EdgeInsetsDirectional.only(
                start: 4,
                bottom: 8,
                top: 18,
              ),
              child: Text(
                t,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14.5,
                  color: cs.onSurfaceVariant,
                ),
              ),
            );
            Widget seg(
              List<String> labels,
              int selected,
              ValueChanged<int> f,
            ) => SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (var i = 0; i < labels.length; i++)
                    ButtonSegment(value: i, label: Text(labels[i])),
                ],
                selected: {selected},
                onSelectionChanged: (s) => f(s.first),
              ),
            );
            Widget sw(String t, String sub, bool v, ValueChanged<bool> f) =>
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: v,
                  onChanged: f,
                  title: Text(
                    t,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
                );

            return ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                4,
                16,
                32 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                card(
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(Icons.chat_rounded, color: cs.primary),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'الرسائل الصغيرة يلي بتطلع بعد أي عملية بكل التطبيق: '
                          'النجاح أخضر، الخطأ أحمر، التنبيه برتقالي، والمعلومة '
                          'أزرق. البرنامج بيعرف النوع لحاله من نص الرسالة.',
                          style: TextStyle(height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
                title('جرّب'),
                card(
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final k in AppMessageKind.values)
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            foregroundColor: k.color,
                            backgroundColor: k.color.withValues(alpha: .12),
                          ),
                          onPressed: () => _try(context, k),
                          icon: Icon(k.icon, size: 18),
                          label: Text(k.label),
                        ),
                    ],
                  ),
                ),
                title('المكان'),
                card(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      seg(
                        const ['فوق الشاشة', 'تحت الشاشة'],
                        p.top ? 0 : 1,
                        (i) => _set(p.copyWith(top: i == 0)),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        p.top
                            ? 'فوق: ما بتغطي أزرار الحفظ والتنفيذ يلي تحت. '
                                  'اسحبها لفوق أو اضغط عليها لتختفي.'
                            : 'تحت: متل قبل (فوق الأزرار العائمة إن وجدت).',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                title('المدة'),
                card(
                  seg(
                    const ['قصيرة', 'عادية', 'طويلة'],
                    p.duration,
                    (i) => _set(p.copyWith(duration: i)),
                  ),
                ),
                title('الشكل'),
                card(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      seg(
                        const ['ملوّنة', 'ناعمة', 'داكنة'],
                        p.style,
                        (i) => _set(p.copyWith(style: i)),
                      ),
                      sw(
                        'أيقونة جنب الرسالة',
                        '✓ للنجاح، ! للخطأ والتنبيه',
                        p.showIcon,
                        (v) => _set(p.copyWith(showIcon: v)),
                      ),
                      sw(
                        'خط أكبر',
                        'أوضح للقراءة',
                        p.largeText,
                        (v) => _set(p.copyWith(largeText: v)),
                      ),
                      sw(
                        'زر إغلاق ✕',
                        'لتسكير الرسالة قبل ما تخلص مدتها',
                        p.showClose,
                        (v) => _set(p.copyWith(showClose: v)),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
