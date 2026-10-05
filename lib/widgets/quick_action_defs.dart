// lib/widgets/quick_action_defs.dart
// -------------------------------------------------------------
// تعريف «الأزرار السريعة» بشاشة الفقاعات: أنواع الأوامر، الأيقونات، القوالب،
// وشكل الزر نفسه — مشتركة بين شاشة الفقاعات وصفحة الإعدادات (المعاينة).
// -------------------------------------------------------------

import 'package:flutter/material.dart';

import '../models.dart';

/// نوع أمر زر سريع
class QuickActionType {
  final String id;
  final String title;

  /// شرح قصير يظهر تحت النوع
  final String description;
  final String icon;
  final String defaultLabel;

  /// تلميح خانة القيمة ('' = بدون قيمة)
  final String valueHint;

  /// قيمة افتراضية تنحط بالخانة
  final String defaultValue;

  /// القيمة ضرورية؟
  final bool valueRequired;

  /// القيمة رقم؟
  final bool numeric;

  /// لحسابات الشركات بس
  final bool companyOnly;

  const QuickActionType({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.defaultLabel,
    this.valueHint = '',
    this.defaultValue = '',
    this.valueRequired = false,
    this.numeric = false,
    this.companyOnly = false,
  });

  bool get hasValue => valueHint.isNotEmpty;
}

/// العناصر يلي بتنحط بقوالب النسخ والحافظة
const List<String> quickTemplateTokens = [
  '{الاسم}',
  '{المبلغ}',
  '{العملة}',
  '{المبلغ2}',
  '{العملة2}',
  '{الوجهة}',
  '{الحساب}',
  '{التاريخ}',
  '{الوقت}',
];

const String defaultCopyTemplate = '{الاسم} - {المبلغ} {العملة}';
const String defaultNoteTemplate = '{الاسم} {المبلغ} {العملة}';

const List<QuickActionType> quickActionTypes = [
  QuickActionType(
    id: 'appendZeros',
    title: 'إضافة أصفار للمبلغ',
    description: 'مثلًا 50 تصير 50.000 بضغطة',
    icon: 'zeros',
    defaultLabel: '000',
    valueHint: 'عدد الأصفار (من 1 إلى 6)',
    defaultValue: '3',
    valueRequired: true,
    numeric: true,
  ),
  QuickActionType(
    id: 'removeZeros',
    title: 'حذف أصفار من المبلغ',
    description: 'مثلًا 50.000 تصير 50',
    icon: 'divide',
    defaultLabel: '÷1000',
    valueHint: 'عدد الأصفار (من 1 إلى 6)',
    defaultValue: '3',
    valueRequired: true,
    numeric: true,
  ),
  QuickActionType(
    id: 'setAmount',
    title: 'مبلغ ثابت',
    description: 'يحط مبلغ محدد للفقاعة',
    icon: 'money',
    defaultLabel: 'مبلغ',
    valueHint: 'المبلغ، مثل: 100',
    valueRequired: true,
    numeric: true,
  ),
  QuickActionType(
    id: 'setName',
    title: 'اعتماد اسم جاهز',
    description: 'اسم محدد، أو قائمة الأسماء الجاهزة',
    icon: 'person',
    defaultLabel: 'اسم جاهز',
    valueHint: 'اسم محدد (فاضي = قائمة الأسماء الجاهزة)',
  ),
  QuickActionType(
    id: 'pasteName',
    title: 'لصق الاسم من الحافظة',
    description: 'النص المنسوخ بيصير اسم الحركة',
    icon: 'paste',
    defaultLabel: 'لصق الاسم',
  ),
  QuickActionType(
    id: 'setCurrency',
    title: 'تغيير العملة',
    description: 'يعتمد عملة محددة للفقاعة',
    icon: 'currency',
    defaultLabel: 'دولار',
    valueHint: 'اسم العملة، مثل: دولار',
    valueRequired: true,
  ),
  QuickActionType(
    id: 'setDestination',
    title: 'تحديد الوجهة',
    description: 'وجهة محددة، أو قائمة الوجهات (للشركات)',
    icon: 'place',
    defaultLabel: 'الوجهة',
    valueHint: 'اسم الوجهة (فاضي = قائمة الوجهات)',
    companyOnly: true,
  ),
  QuickActionType(
    id: 'setMovement',
    title: 'نوع حركة الشركة',
    description: 'مرسلة أو استقبال (للشركات)',
    icon: 'swap',
    defaultLabel: 'مرسلة',
    valueHint: 'sent = مرسلة • received = استقبال',
    defaultValue: 'sent',
    valueRequired: true,
    companyOnly: true,
  ),
  QuickActionType(
    id: 'setMode',
    title: 'نوع الفقاعة',
    description: 'تحويلها لإضافة أو تعديل أو إلغاء',
    icon: 'cancel',
    defaultLabel: 'إلغاء',
    valueHint: 'add = إضافة • edit = تعديل • cancel = إلغاء',
    defaultValue: 'cancel',
    valueRequired: true,
  ),
  QuickActionType(
    id: 'copySummary',
    title: 'نسخ ملخص',
    description: 'ينسخ الاسم والمبلغ حسب قالب بتختاره',
    icon: 'copy',
    defaultLabel: 'نسخ',
    valueHint: 'القالب، مثل: {الاسم} - {المبلغ} {العملة}',
    defaultValue: defaultCopyTemplate,
  ),
  QuickActionType(
    id: 'copyMessage',
    title: 'نسخ نص الرسالة',
    description: 'ينسخ الرسالة كاملة كما هي',
    icon: 'message',
    defaultLabel: 'نسخ الرسالة',
  ),
  QuickActionType(
    id: 'addToNotes',
    title: 'إضافة للحافظة',
    description: 'يحط ملخص الفقاعة بالحافظة العائمة (بنوع الفقاعة)',
    icon: 'note',
    defaultLabel: 'للحافظة',
    valueHint: 'القالب، مثل: {الاسم} {المبلغ} {العملة}',
    defaultValue: defaultNoteTemplate,
  ),
  QuickActionType(
    id: 'saveNow',
    title: 'حفظ هالفقاعة بس',
    description: 'يحفظ (أو يلغي) هالفقاعة لحالها بدون الباقي',
    icon: 'save',
    defaultLabel: 'حفظ',
  ),
  QuickActionType(
    id: 'clearStage',
    title: 'مسح المختار',
    description: 'يمسح المرحلة الحالية (الاسم/المبلغ/العملة)',
    icon: 'clear',
    defaultLabel: 'مسح',
  ),
  QuickActionType(
    id: 'clearAll',
    title: 'إعادة الفقاعة من جديد',
    description: 'يرجّع الفقاعة متل ما انقرت أول مرة',
    icon: 'refresh',
    defaultLabel: 'من جديد',
  ),
  QuickActionType(
    id: 'deleteBubble',
    title: 'حذف الفقاعة',
    description: 'يشيل الفقاعة من القائمة (مع تأكيد)',
    icon: 'delete',
    defaultLabel: 'حذف',
  ),
];

QuickActionType quickActionTypeOf(String id) => quickActionTypes.firstWhere(
  (t) => t.id == id,
  orElse: () => quickActionTypes.firstWhere((t) => t.id == 'clearStage'),
);

const List<String> quickActionIconKeys = [
  'zeros',
  'divide',
  'money',
  'person',
  'paste',
  'currency',
  'place',
  'swap',
  'add',
  'edit',
  'cancel',
  'copy',
  'message',
  'note',
  'save',
  'clear',
  'refresh',
  'delete',
  'flash',
  'check',
  'star',
  'send',
];

IconData quickActionIcon(String key) {
  switch (key) {
    case 'zeros':
      return Icons.exposure_zero_rounded;
    case 'divide':
      return Icons.percent_rounded;
    case 'money':
      return Icons.payments_rounded;
    case 'person':
      return Icons.person_add_alt_1_rounded;
    case 'paste':
      return Icons.content_paste_go_rounded;
    case 'clear':
      return Icons.backspace_rounded;
    case 'currency':
      return Icons.currency_exchange_rounded;
    case 'place':
      return Icons.place_rounded;
    case 'swap':
      return Icons.swap_horiz_rounded;
    case 'add':
      return Icons.add_circle_rounded;
    case 'edit':
      return Icons.edit_rounded;
    case 'cancel':
      return Icons.cancel_rounded;
    case 'copy':
      return Icons.copy_all_rounded;
    case 'message':
      return Icons.chat_rounded;
    case 'note':
      return Icons.sticky_note_2_rounded;
    case 'save':
      return Icons.save_rounded;
    case 'refresh':
      return Icons.restart_alt_rounded;
    case 'delete':
      return Icons.delete_outline_rounded;
    case 'flash':
      return Icons.bolt_rounded;
    case 'check':
      return Icons.task_alt_rounded;
    case 'star':
      return Icons.star_rounded;
    case 'send':
      return Icons.send_rounded;
    default:
      return Icons.tune_rounded;
  }
}

/// ألوان جاهزة للأزرار
const List<int> quickActionPalette = [
  0xFF3F51B5,
  0xFF1E88E5,
  0xFF00897B,
  0xFF43A047,
  0xFFF08006,
  0xFFE53935,
  0xFFD81B60,
  0xFF8E24AA,
  0xFF6D4C41,
  0xFF546E7A,
];

const Map<String, String> quickActionStyles = {
  'outlined': 'إطار',
  'tonal': 'ناعم',
  'filled': 'معبّى',
  'text': 'نص بس',
};

const Map<String, String> quickActionModeLabels = {
  'add': 'إضافة',
  'edit': 'تعديل',
  'cancel': 'إلغاء',
};

/// يعبّي القالب بالقيم ({الاسم} ...) ويشيل الفراغات الزايدة
String fillQuickTemplate(String template, Map<String, String> values) {
  var out = template.trim().isEmpty ? defaultCopyTemplate : template;
  values.forEach((k, v) => out = out.replaceAll(k, v));
  return out
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .join('\n')
      .trim();
}

/// شكل الزر السريع حسب إعداداته (اللون، الشكل، العرض، الحجم)
class QuickActionButton extends StatelessWidget {
  final BubbleQuickActionConfig action;
  final VoidCallback? onPressed;

  /// 0 صغير، 1 عادي، 2 كبير
  final int size;

  const QuickActionButton({
    super.key,
    required this.action,
    required this.onPressed,
    this.size = 1,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = action.colorValue != null
        ? Color(action.colorValue!)
        : cs.primary;
    final color = dark && action.colorValue != null
        ? Color.lerp(base, Colors.white, .25)!
        : base;
    final s = size.clamp(0, 2);
    final iconSize = const [15.0, 18.0, 22.0][s];
    final fontSize = const [12.0, 13.5, 15.0][s];
    final padH = const [9.0, 12.0, 15.0][s];
    final padV = const [6.0, 10.0, 13.0][s];
    final showIcon = action.display != 'text';
    final showLabel = action.display != 'icon' || action.label.trim().isEmpty;
    final label = action.label.trim().isEmpty
        ? quickActionTypeOf(action.actionType).defaultLabel
        : action.label;

    final style = action.style;
    final fg = style == 'filled'
        ? (ThemeData.estimateBrightnessForColor(base) == Brightness.dark
              ? Colors.white
              : Colors.black87)
        : color;
    final icon = Icon(quickActionIcon(action.iconKey), size: iconSize);
    final text = Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontWeight: FontWeight.w800, fontSize: fontSize),
    );
    final Widget child;
    if (showIcon && showLabel) {
      child = action.iconAbove
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [icon, const SizedBox(height: 2), text],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(width: 6),
                Flexible(child: text),
              ],
            );
    } else if (showIcon) {
      child = icon;
    } else {
      child = text;
    }

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(const [11.0, 14.0, 16.0][s]),
    );
    final padding = EdgeInsets.symmetric(
      horizontal: showLabel ? padH : padV,
      vertical: padV,
    );
    final Widget button;
    switch (style) {
      case 'filled':
        button = FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: base,
            foregroundColor: fg,
            padding: padding,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: shape,
          ),
          child: child,
        );
      case 'tonal':
        button = FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: base.withValues(alpha: dark ? .24 : .13),
            foregroundColor: fg,
            padding: padding,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: shape,
            elevation: 0,
          ),
          child: child,
        );
      case 'text':
        button = TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: fg,
            padding: padding,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: shape,
          ),
          child: child,
        );
      default:
        button = OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: fg,
            side: BorderSide(color: color.withValues(alpha: .35)),
            padding: padding,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: shape,
          ),
          child: child,
        );
    }
    return Tooltip(
      message: label.isEmpty
          ? quickActionTypeOf(action.actionType).title
          : '$label — ${quickActionTypeOf(action.actionType).title}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: button,
      ),
    );
  }
}
