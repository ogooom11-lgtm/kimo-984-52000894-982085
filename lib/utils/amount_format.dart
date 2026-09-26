// lib/utils/amount_format.dart
// تنسيق المبالغ للعرض: نقطة بين كل 3 خانات، والفاصلة للكسور فقط إذا وُجدت.

/// تنسيق موحّد لعرض المبالغ (بنفس طريقة صفحة الحساب):
///
/// | القيمة     | العرض      |
/// |------------|------------|
/// | 250000     | 250.000    |
/// | 1250000    | 1.250.000  |
/// | 1234.5     | 1.234,5    |
/// | 1234.56    | 1.234,56   |
/// | 1234.00    | 1.234      |
/// | -1500      | -1.500     |
///
/// للعرض فقط: حقول الإدخال والنسخ تبقى بالأرقام الخام حتى تُقرأ صحيحًا.
class AmountFormat {
  AmountFormat._();

  /// [maxDecimals]: أقصى عدد خانات بعد الفاصلة (تُحذف الأصفار في آخرها).
  static String display(num value, {int maxDecimals = 2}) {
    final v = value.toDouble();
    if (v.isNaN || v.isInfinite) return '0';
    final abs = v.abs();
    // toStringAsFixed تعطي صيغة أسية للأعداد الضخمة جدًا
    if (abs >= 1e21) return v.toString();

    final fixed = abs.toStringAsFixed(maxDecimals < 0 ? 0 : maxDecimals);
    final dot = fixed.indexOf('.');
    final intPart = dot < 0 ? fixed : fixed.substring(0, dot);
    final decimals = dot < 0
        ? ''
        : fixed.substring(dot + 1).replaceFirst(RegExp(r'0+$'), '');

    final grouped = groupDigits(intPart);
    final isZero = decimals.isEmpty && RegExp(r'^0+$').hasMatch(intPart);
    final sign = v < 0 && !isZero ? '-' : '';
    return decimals.isEmpty ? '$sign$grouped' : '$sign$grouped,$decimals';
  }

  /// يحوّل "1250000" إلى "1.250.000" (أرقام فقط بدون إشارة).
  static String groupDigits(String digits, {String separator = '.'}) {
    final n = digits.length;
    if (n <= 3) return digits;
    final b = StringBuffer();
    for (var i = 0; i < n; i++) {
      if (i > 0 && (n - i) % 3 == 0) b.write(separator);
      b.write(digits[i]);
    }
    return b.toString();
  }
}
