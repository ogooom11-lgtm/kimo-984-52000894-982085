// lib/bubble_prefs.dart
// تفضيلات تصميم شاشة الفقاعات (BubbleScreen) القابلة للتخصيص من الإعدادات.
// تُخزَّن داخل Settings.bubbleUiPrefs كخريطة بسيطة حتى تبقى متوافقة مع Hive
// ومع النسخ الاحتياطي دون الحاجة لمحوّل (Adapter) جديد.

import 'package:flutter/material.dart';

import 'models.dart';

class BubbleUiPrefs {
  /// حجم خط فقاعات الكلمات.
  final double tokenFontSize;

  /// فقاعات أصغر ومسافات أقل لعرض رسائل أكثر في الشاشة.
  final bool compact;

  /// إظهار سطر المرسل والوقت أعلى كل فقاعة.
  final bool showSenderHeader;

  /// إظهار دليل الألوان أعلى الشاشة.
  final bool showLegend;

  /// إظهار الأزرار السريعة المعرفة في الإعدادات داخل كل فقاعة.
  final bool showQuickActions;

  /// عرض الفقاعات غير المكتملة أولًا (وإلا تبقى بترتيبها الزمني).
  final bool incompleteFirst;

  /// عند الضغط على كلمة لتحديد الاسم: يمتد الاسم تلقائيًا حتى نهاية السطر
  /// أو حتى أول كلمة ممنوعة/رقم/كلمة إيقاف.
  final bool autoExtendName;

  /// طلب تأكيد قبل الحفظ إذا احتوت رسالة على جملة ممنوعة.
  final bool confirmForbiddenPhrase;

  /// عدد الأيام التي يُبحث فيها عن حركات بنفس الاسم + المبلغ + العملة.
  final int duplicateDays;

  /// ألوان الأدوار.
  final int nameColor;
  final int amountColor;
  final int currencyColor;

  const BubbleUiPrefs({
    this.tokenFontSize = 14,
    this.compact = false,
    this.showSenderHeader = true,
    this.showLegend = true,
    this.showQuickActions = true,
    this.incompleteFirst = true,
    this.autoExtendName = true,
    this.confirmForbiddenPhrase = true,
    this.duplicateDays = 30,
    this.nameColor = defaultNameColor,
    this.amountColor = defaultAmountColor,
    this.currencyColor = defaultCurrencyColor,
  });

  static const int defaultNameColor = 0xFF5C6BC0; // indigo
  static const int defaultAmountColor = 0xFFF08006; // orange
  static const int defaultCurrencyColor = 0xFF42A5F5; // blue

  static const double minFontSize = 11;
  static const double maxFontSize = 22;
  static const int minDuplicateDays = 1;
  static const int maxDuplicateDays = 365;

  /// ألوان جاهزة للاختيار من الإعدادات.
  static const List<int> palette = [
    0xFF5C6BC0, // indigo
    0xFF3949AB,
    0xFF8E24AA, // purple
    0xFFD81B60, // pink
    0xFFE53935, // red
    0xFFF08006, // orange
    0xFFF9A825, // amber
    0xFF43A047, // green
    0xFF00897B, // teal
    0xFF42A5F5, // blue
    0xFF1E88E5,
    0xFF6D4C41, // brown
    0xFF546E7A, // blue grey
  ];

  Color get nameColorValue => Color(nameColor);
  Color get amountColorValue => Color(amountColor);
  Color get currencyColorValue => Color(currencyColor);

  static double _toDouble(dynamic v, double fallback) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  static int _toInt(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static bool _toBool(dynamic v, bool fallback) {
    if (v is bool) return v;
    if (v is String) {
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return fallback;
  }

  factory BubbleUiPrefs.fromMap(Map<dynamic, dynamic>? map) {
    const d = BubbleUiPrefs();
    if (map == null || map.isEmpty) return d;
    return BubbleUiPrefs(
      tokenFontSize: _toDouble(
        map['tokenFontSize'],
        d.tokenFontSize,
      ).clamp(minFontSize, maxFontSize).toDouble(),
      compact: _toBool(map['compact'], d.compact),
      showSenderHeader: _toBool(map['showSenderHeader'], d.showSenderHeader),
      showLegend: _toBool(map['showLegend'], d.showLegend),
      showQuickActions: _toBool(map['showQuickActions'], d.showQuickActions),
      incompleteFirst: _toBool(map['incompleteFirst'], d.incompleteFirst),
      autoExtendName: _toBool(map['autoExtendName'], d.autoExtendName),
      confirmForbiddenPhrase: _toBool(
        map['confirmForbiddenPhrase'],
        d.confirmForbiddenPhrase,
      ),
      duplicateDays: _toInt(
        map['duplicateDays'],
        d.duplicateDays,
      ).clamp(minDuplicateDays, maxDuplicateDays).toInt(),
      nameColor: _toInt(map['nameColor'], d.nameColor),
      amountColor: _toInt(map['amountColor'], d.amountColor),
      currencyColor: _toInt(map['currencyColor'], d.currencyColor),
    );
  }

  factory BubbleUiPrefs.fromSettings(Settings? settings) =>
      BubbleUiPrefs.fromMap(settings?.bubbleUiPrefs);

  Map<String, dynamic> toMap() => <String, dynamic>{
    'tokenFontSize': tokenFontSize,
    'compact': compact,
    'showSenderHeader': showSenderHeader,
    'showLegend': showLegend,
    'showQuickActions': showQuickActions,
    'incompleteFirst': incompleteFirst,
    'autoExtendName': autoExtendName,
    'confirmForbiddenPhrase': confirmForbiddenPhrase,
    'duplicateDays': duplicateDays,
    'nameColor': nameColor,
    'amountColor': amountColor,
    'currencyColor': currencyColor,
  };

  BubbleUiPrefs copyWith({
    double? tokenFontSize,
    bool? compact,
    bool? showSenderHeader,
    bool? showLegend,
    bool? showQuickActions,
    bool? incompleteFirst,
    bool? autoExtendName,
    bool? confirmForbiddenPhrase,
    int? duplicateDays,
    int? nameColor,
    int? amountColor,
    int? currencyColor,
  }) {
    return BubbleUiPrefs(
      tokenFontSize: tokenFontSize ?? this.tokenFontSize,
      compact: compact ?? this.compact,
      showSenderHeader: showSenderHeader ?? this.showSenderHeader,
      showLegend: showLegend ?? this.showLegend,
      showQuickActions: showQuickActions ?? this.showQuickActions,
      incompleteFirst: incompleteFirst ?? this.incompleteFirst,
      autoExtendName: autoExtendName ?? this.autoExtendName,
      confirmForbiddenPhrase:
          confirmForbiddenPhrase ?? this.confirmForbiddenPhrase,
      duplicateDays: duplicateDays ?? this.duplicateDays,
      nameColor: nameColor ?? this.nameColor,
      amountColor: amountColor ?? this.amountColor,
      currencyColor: currencyColor ?? this.currencyColor,
    );
  }
}
