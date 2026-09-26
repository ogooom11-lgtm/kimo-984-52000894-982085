// lib/services/detection/amount_detector.dart
// -------------------------------------------------------------
// المرحلة 3 من خط المعالجة:
// 1) استقبال النص المتبقي بعد الاسم/العملة
// 2) استخدام amountKeywords + ignoredWords من الإعدادات
// 3) تجاهل الهواتف والأكواد والأرقام غير المالية
// 4) عدم اعتبار طن/طون مبالغ
// 5) إعادة أفضل مبلغ + المرشحات + تنبيه تعدد المبالغ الحقيقي
//
// ملاحظة:
// - أبقينا detect(lines: ...) للتوافق المؤقت.
// - أضفنا detectPrepared(...) للمسار الجديد القادم من currency_detector.
// -------------------------------------------------------------

import 'dart:core';
import 'amount_text_parser.dart';
import 'text_tokens.dart' as tt;

/// موضع (سطر، توكن)
class Position {
  final int x; // line index
  final int y; // token index
  const Position(this.x, this.y);

  @override
  String toString() => 'Position(x=$x, y=$y)';
}

/// توكن جاهز للتمرير إلى كاشف المبلغ مع حفظ مكانه الأصلي
class AmountPreparedToken {
  final String token;
  final Position originalPos;

  const AmountPreparedToken({required this.token, required this.originalPos});

  AmountPreparedToken copyWith({String? token, Position? originalPos}) {
    return AmountPreparedToken(
      token: token ?? this.token,
      originalPos: originalPos ?? this.originalPos,
    );
  }
}

/// نتيجة كشف المبلغ
class AmountDetectResult {
  /// موضع أفضل مبلغ رقمي تم اختياره
  final Position? numericPos;

  /// القيمة الرقمية النهائية المختارة
  final double? numericValue;

  /// القيمة المحسوبة من النصوص اللفظية مثل "ثلاثة مليون ومئة ألف"
  final double? textValue;

  /// هل يوجد تعارض كبير بين النصي والرقمي؟
  final bool hasConflict;

  /// هل يوجد أكثر من مبلغ حقيقي مختلف بعد التصفية؟
  final bool hasMultipleCandidates;

  /// جميع القيم المرشحة المميزة بعد التصفية
  final List<double> candidateValues;

  /// هل المبلغ المختار جاء من تعبير لفظي/مركّب (numericPos = أول توكن فيه)؟
  final bool fromText;

  /// موقع أقوى مرشح لكل قيمة في [candidateValues] (بنفس الترتيب)
  final List<Position> candidatePositions;

  const AmountDetectResult({
    required this.numericPos,
    required this.numericValue,
    required this.textValue,
    required this.hasConflict,
    required this.hasMultipleCandidates,
    required this.candidateValues,
    this.fromText = false,
    this.candidatePositions = const <Position>[],
  });

  @override
  String toString() {
    return 'AmountDetectResult('
        'numericPos=$numericPos, '
        'numericValue=$numericValue, '
        'textValue=$textValue, '
        'hasConflict=$hasConflict, '
        'hasMultipleCandidates=$hasMultipleCandidates, '
        'candidateValues=$candidateValues'
        ')';
  }
}

class _AmountCandidate {
  final Position pos;
  final double value;
  final int score;
  final bool fromText;

  const _AmountCandidate({
    required this.pos,
    required this.value,
    required this.score,
    required this.fromText,
  });

  /// أفضلية: النقاط أولًا، ثم الرقمي على النصي، ثم القيمة الأكبر
  bool beats(_AmountCandidate other) {
    if (score != other.score) return score > other.score;
    if (fromText != other.fromText) return !fromText;
    return value.abs() > other.value.abs();
  }
}

class AmountDetector {
  // ========= تطبيع عام =========

  static String _stripDiacritics(String s) =>
      s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');

  static String _normalizeArabic(String s) {
    s = _stripDiacritics(s);
    s = s.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
    s = s.replaceAll('ى', 'ي').replaceAll('ئ', 'ي').replaceAll('ؤ', 'و');
    s = s.replaceAll('ة', 'ه');
    return s.trim();
  }

  static String _normalizeAmountText(String input) {
    if (input.isEmpty) return input;

    final buf = StringBuffer();
    for (int i = 0; i < input.length; i++) {
      final c = input.codeUnitAt(i);
      if (c >= 0x0660 && c <= 0x0669) {
        buf.write(String.fromCharCode(0x30 + (c - 0x0660)));
      } else {
        buf.writeCharCode(c);
      }
    }

    String t = buf.toString();
    t = _normalizeArabic(t);
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  static bool _looselyEq(String a, String b) =>
      _normalizeArabic(a).toUpperCase() == _normalizeArabic(b).toUpperCase();

  static bool _sameAmount(double a, double b) => (a - b).abs() < 0.0001;

  static void _addUniqueAmount(List<double> list, double? value) {
    if (value == null) return;
    if (value <= 0) return;
    if (list.any((e) => _sameAmount(e, value))) return;
    list.add(value);
  }

  // ========= تقسيم وتنظيف =========

  /// نفس منطق شاشة الفقاعات: حذف فواصل الآلاف مع إبقاء الفاصلة العشرية
  static String _squashDigitSeparators(String w) => tt.squashDigitSeparators(w);

  static String _cleanToken(String w) {
    final trimmed = w
        .replaceAll(
          RegExp(r'[^\u0600-\u06FFa-zA-Z0-9\$€£﷼₺٫\.\,\-_\/\+\:]'),
          '',
        )
        .trim();
    return _squashDigitSeparators(trimmed);
  }

  static List<String> tokensFromLine(String line) {
    return line
        .split(RegExp(r'\s+'))
        .map(_cleanToken)
        .where((w) => w.isNotEmpty)
        .toList();
  }

  static bool _isPureDigitsToken(String token) =>
      RegExp(r'^[0-9\u0660-\u0669]+$').hasMatch(token);

  static bool _hasDigits(String s) => RegExp(r'[0-9\u0660-\u0669]').hasMatch(s);

  // ========= كلمات/وحدات =========

  static const Set<String> _phoneWords = {
    'الرقم',
    'رقم',
    'هاتف',
    'الهاتف',
    'جوال',
    'الجوال',
    'موبايل',
    'واتس',
    'واتساب',
    'تلفون',
    'تليفون',
    'phone',
    'mobile',
  };

  static const Set<String> _rangeWords = {
    'فوق',
    'تحت',
    'اكبر',
    'اصغر',
    'أكبر',
    'أصغر',
  };

  /// وحدات غير مالية يجب ألا تجعل الرقم مبلغًا
  static const Set<String> _nonMoneyUnits = {
    'كغ',
    'كيلو',
    'كيلوغرام',
    'كرتون',
    'حبه',
    'حبة',
    'قطعة',
    'قطعه',
  };

  static const Set<String> _moneyMagnitudeWords = {
    'الف',
    'الاف',
    'ألف',
    'آلاف',
    'مليون',
    'ملايين',
    'مليار',
    'مليارات',
    'طن',
    'طون',
  };

  static bool _isMoneyMagnitudeToken(String token) {
    final t = _normalizeArabic(_cleanToken(token));
    return _moneyMagnitudeWords.contains(t);
  }

  static double _magnitudeUnitValue(String token) {
    final t = _normalizeArabic(_cleanToken(token));

    if (t == 'الف' || t == 'ألف' || t == 'الاف' || t == 'آلاف') {
      return 1e3;
    }

    if (t == 'مليون' || t == 'ملايين' || t == 'طن' || t == 'طون') {
      return 1e6;
    }

    if (t == 'مليار' || t == 'مليارات') {
      return 1e9;
    }

    return 1.0;
  }

  /// يضرب بالمقدار فقط إذا كان الرقم نفسه ليس كبيرًا أصلًا.
  /// مثال:
  /// 4 مليون => 4,000,000
  /// 2000000 مليون => 2,000,000 فقط
  static double _applyMagnitudeSmart(double baseValue, String magnitudeToken) {
    final unit = _magnitudeUnitValue(magnitudeToken);
    if (unit <= 1.0) return baseValue;

    // إذا الرقم نفسه وصل أصلًا لحجم هذه الوحدة أو تجاوزها، لا نضربه مرة ثانية
    if (baseValue >= unit) return baseValue;

    return baseValue * unit;
  }

  static String? _extractEmbeddedMoneyMagnitude(String token) {
    if (token.isEmpty) return null;

    final t = _normalizeInlineAmountToken(token);
    if (t.isEmpty) return null;

    final rest = t
        .replaceFirst(
          RegExp(
            r'^[+\-]?[0-9\u0660-\u0669][0-9\u0660-\u0669,.\u066B\u066C]*\s*',
          ),
          '',
        )
        .trim();

    if (rest.isEmpty) return null;

    final m = RegExp(
      r'^(الف|الاف|ألف|آلاف|مليون|ملايين|مليار|مليارات|طن|طون)',
      unicode: true,
    ).firstMatch(rest);

    return m?.group(1);
  }

  static String _normalizeInlineAmountToken(String token) {
    if (token.isEmpty) return token;

    String t = _normalizeArabic(_cleanToken(token));

    // 3طون => 3 طون
    // 250الف => 250 الف
    // 7مليون => 7 مليون
    t = t.replaceAllMapped(
      RegExp(
        r'([0-9\u0660-\u0669])(?=(الف|الاف|ألف|آلاف|مليون|ملايين|مليار|مليارات|طن|طون)\b)',
        unicode: true,
      ),
      (m) => '${m.group(1)} ',
    );

    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  static bool _isIgnoredExact(String token, Set<String> ignoredWords) {
    if (token.isEmpty) return false;
    final t = _cleanToken(token);
    return ignoredWords.contains(t);
  }

  static bool _isAmountKeywordExact(String token, Set<String> amountKeywords) {
    if (token.isEmpty) return false;
    final t = _cleanToken(token);
    return amountKeywords.contains(t);
  }

  static bool _isNonMoneyUnitToken(String token) {
    final t = _normalizeArabic(_cleanToken(token));
    return _nonMoneyUnits.contains(t);
  }

  /// العملة المكتوبة بأكثر من كلمة («ليرة سورية») تُضاف كلماتها أيضًا: الرسالة
  /// تُقرأ كلمة كلمة، فالعبارة كاملة لا تطابق أي كلمة وحدها.
  static Set<String> _expandHints(Set<String> hints) {
    if (!hints.any((h) => h.trim().contains(RegExp(r'\s')))) return hints;
    return {
      ...hints,
      for (final h in hints)
        for (final w in h.trim().split(RegExp(r'\s+')))
          if (_cleanToken(w).length >= 2) _cleanToken(w),
    };
  }

  static bool _containsCurrencyHint(String token, Set<String> currencyHints) {
    if (token.isEmpty) return false;

    if (token.contains('\$') ||
        token.contains('€') ||
        token.contains('£') ||
        token.contains('﷼') ||
        token.contains('₺')) {
      return true;
    }

    final norm = _normalizeArabic(_cleanToken(token));

    for (final h in currencyHints) {
      if (_looselyEq(norm, h)) return true;
    }

    return false;
  }

  static String _digitsOnly(String s) {
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) {
        b.writeCharCode(c);
      } else if (c >= 0x0660 && c <= 0x0669) {
        b.writeCharCode(0x30 + (c - 0x0660));
      }
    }
    return b.toString();
  }

  static bool _startsLikePhone(String raw, String digits) {
    final t = raw.trim();
    if (digits.isEmpty) return false;

    if (t.startsWith('+')) return true;
    if (digits.startsWith('0')) return true;

    return false;
  }

  static bool _isPhoneLikeToken(String token) {
    final raw = token.trim();
    final d = _digitsOnly(raw);

    if (d.length < 9 || d.length > 14) return false;

    return _startsLikePhone(raw, d);
  }

  static bool _lineLooksLikeSplitPhone(List<String> tokens) {
    if (tokens.isEmpty) return false;

    final joined = tokens.map((e) => e.trim()).join(' ');
    final allDigits = _digitsOnly(joined);

    if (allDigits.length < 9 || allDigits.length > 14) return false;

    // رقم دولي مفصول بمسافات: +964 000 000 000
    if (joined.trim().startsWith('+')) return true;

    // رقم محلي مفصول بمسافات: 099 123 4567
    final digitGroups = tokens
        .where((t) => RegExp(r'^[0-9\u0660-\u0669]+$').hasMatch(t))
        .toList();
    if (digitGroups.length >= 2 && allDigits.startsWith('0')) {
      return true;
    }

    return false;
  }

  // ========= أنماط أرقام غير مالية =========

  static final RegExp _timeRe = RegExp(
    r'^[0-9\u0660-\u0669]{1,2}:[0-9\u0660-\u0669]{2}(:[0-9\u0660-\u0669]{2})?$',
  );
  static final RegExp _slashBetweenDigitsRe = RegExp(
    r'[0-9\u0660-\u0669]/[0-9\u0660-\u0669]',
  );

  /// وقت (10:30) أو تاريخ (12/5 ، 12/5/2025) — ليس مبلغًا
  static bool _isTimeOrDateToken(String token) {
    final t = token.trim();
    if (t.isEmpty) return false;
    return _timeRe.hasMatch(t) || _slashBetweenDigitsRe.hasMatch(t);
  }

  static int _trailingZeros(String digits) {
    var n = 0;
    for (int i = digits.length - 1; i >= 0 && digits[i] == '0'; i--) {
      n++;
    }
    return n;
  }

  /// رقم طويل بدون فواصل (هاتف بدون مفتاح دولي/حساب/بطاقة) — ليس مبلغًا.
  /// الأرقام الكبيرة «المدوّرة» مثل 1000000000 تبقى مبالغ.
  static bool _isLongIdToken(String token) {
    final t = token.trim();
    if (!_isPureDigitsToken(t)) return false;
    final d = _digitsOnly(t);
    if (d.length >= 13) return true;
    return d.length >= 10 && _trailingZeros(d) < 5;
  }

  /// رقم مشكوك به (8–9 أرقام غير مدوّرة بدون فواصل) قد يكون هاتفًا محليًا:
  /// يبقى مرشحًا لكن بنقاط أقل.
  static bool _isSuspectPhoneDigits(String token) {
    final t = token.trim();
    if (!_isPureDigitsToken(t)) return false;
    final d = _digitsOnly(t);
    return d.length >= 8 && d.length <= 9 && _trailingZeros(d) <= 1;
  }

  // ========= تعابير لفظية/مركّبة =========

  static const Set<String> _magnitudeWordKeys = {
    'الف',
    'الاف',
    'مليون',
    'ملايين',
    'مليار',
    'مليارات',
    'طن',
    'طون',
  };

  static bool _isMagnitudeWord(String norm) {
    var k = norm;
    if (k.startsWith('و') && k.length > 2) {
      final rest = k.substring(1);
      if (_magnitudeWordKeys.contains(rest)) k = rest;
    }
    return _magnitudeWordKeys.contains(k);
  }

  static final Expando<Map<String, bool>> _numberWordCaches =
      Expando<Map<String, bool>>('numberWords');

  /// كلمة عددية بدون أرقام يفهمها محلل المبالغ النصية (خمس، مية، الف، ونص...)
  static bool _isNumberWord(
    String token,
    Map<String, double> customWordValues,
    Map<String, bool> cache,
  ) {
    if (token.isEmpty || _hasDigits(token)) return false;
    return cache.putIfAbsent(token, () {
      final r = AmountTextParser.parse(
        token,
        customWordValues: customWordValues,
      );
      return r.matched && r.value != null;
    });
  }

  // ========= تحليل رقم مفرد =========

  static double? parseAmountToken(String token) {
    if (token.isEmpty) return null;

    String t = _normalizeAmountText(token);

    // أبقِ فقط الجزء الذي يهم الرقم إذا كان ملزوقًا برموز
    final m = RegExp(r'([+\-]?[0-9][0-9,.\u066B\u066C]*)').firstMatch(t);
    if (m == null) return null;
    t = m.group(1) ?? '';
    if (t.isEmpty) return null;

    t = t.replaceAll('٫', '.').replaceAll('٬', ',').replaceAll('،', ',');

    // لو كان الشكل مجموعات آلاف مفصولة فقط: 5.500.000 أو 1,600,000
    bool looksGroupedByThousands(String s, String sep) {
      final signless = s.replaceFirst(RegExp(r'^[+\-]'), '');
      final parts = signless.split(sep);
      if (parts.length < 2) return false;
      if (parts.first.isEmpty || parts.first.length > 3) return false;
      for (int i = 1; i < parts.length; i++) {
        if (parts[i].length != 3) return false;
      }
      return true;
    }

    final hasComma = t.contains(',');
    final hasDot = t.contains('.');

    if (hasComma && hasDot) {
      final lastComma = t.lastIndexOf(',');
      final lastDot = t.lastIndexOf('.');
      final lastSepIndex = lastComma > lastDot ? lastComma : lastDot;
      final lastSepChar = lastComma > lastDot ? ',' : '.';
      final digitsAfter = t
          .substring(lastSepIndex + 1)
          .replaceAll(RegExp(r'[^0-9]'), '');

      // إذا آخر فاصل يبدو عشريًا (1 أو 2 رقم) نعتبره عشريًا ونحذف الباقي
      if (digitsAfter.length == 1 || digitsAfter.length == 2) {
        if (lastSepChar == '.') {
          t = t.replaceAll(',', '');
        } else {
          t = t.replaceAll('.', '');
          final idx = t.lastIndexOf(',');
          t = t.replaceRange(idx, idx + 1, '.');
          t = t.replaceAll(',', '');
        }
      } else {
        // في سياق المبالغ نحذف كل الفواصل ونعتبرها آلاف
        t = t.replaceAll(',', '').replaceAll('.', '');
      }
    } else if (hasComma) {
      if (looksGroupedByThousands(t, ',')) {
        t = t.replaceAll(',', '');
      } else {
        final idx = t.lastIndexOf(',');
        final digitsAfter = t
            .substring(idx + 1)
            .replaceAll(RegExp(r'[^0-9]'), '');
        if (digitsAfter.length == 1 || digitsAfter.length == 2) {
          t = t.replaceRange(idx, idx + 1, '.');
          t = t.replaceAll(',', '');
        } else {
          t = t.replaceAll(',', '');
        }
      }
    } else if (hasDot) {
      if (looksGroupedByThousands(t, '.')) {
        t = t.replaceAll('.', '');
      } else {
        final idx = t.lastIndexOf('.');
        final digitsAfter = t
            .substring(idx + 1)
            .replaceAll(RegExp(r'[^0-9]'), '');
        if (!(digitsAfter.length == 1 || digitsAfter.length == 2)) {
          t = t.replaceAll('.', '');
        }
      }
    }

    t = t.replaceAll(RegExp(r'[^0-9.\-+]'), '');
    if (t.isEmpty) return null;

    return double.tryParse(t);
  }

  // ========= كلمة المقدار في سطر مستقل =========

  /// توكن رقمي صالح ليكون جزءًا من مبلغ (ليس هاتفًا ولا كودًا ولا وقتًا).
  static bool _isMoneyDigitToken(String t) {
    if (!_hasDigits(t)) return false;
    if (t.contains('+') || t.contains('#')) return false;
    if (_isPhoneLikeToken(t) || _isLongIdToken(t)) return false;
    if (_isTimeOrDateToken(t)) return false;
    return parseAmountToken(_normalizeInlineAmountToken(t)) != null;
  }

  /// سطر يبدأ بكلمة مقدار (ألف، مليون...) وليس بعدها إلا عملة أو كلمة مبلغ
  /// أو كلمة متجاهلة: «الف» ، «ألف دولار» ، «مليون $».
  static bool isMagnitudeOnlyLine(
    List<String> tokens, {
    Set<String> currencyHints = const <String>{},
    List<String> amountKeywords = const <String>[],
    List<String> ignoredWords = const <String>[],
  }) => _isMagnitudeOnlyTokens(
    tokens,
    _expandHints(currencyHints),
    amountKeywords.map(_cleanToken).where((e) => e.isNotEmpty).toSet(),
    ignoredWords.map(_cleanToken).where((e) => e.isNotEmpty).toSet(),
  );

  /// هل يُربط سطر كلمة مقدار («الف») بهذا السطر؟ نعم إذا انتهى برقم أقل من
  /// 1000 أو بعدد لفظي: «250» ثم «الف» = 250 ألف، أما «10.000» ثم «مليون»
  /// فليست «عشرة آلاف مليون».
  static bool canTakeMagnitudeLine(
    List<String> tokens, {
    List<String> ignoredWords = const <String>[],
    Map<String, double> customWordValues = const <String, double>{},
  }) => _endsWithAmount(
    tokens,
    ignoredWords.map(_cleanToken).where((e) => e.isNotEmpty).toSet(),
    customWordValues,
    _numberWordCaches[customWordValues] ??= <String, bool>{},
  );

  static bool _isMagnitudeOnlyTokens(
    List<String> tokens,
    Set<String> currencyHints,
    Set<String> amountKeywordSet,
    Set<String> ignoredSet,
  ) {
    var seenMagnitude = false;
    for (final t in tokens) {
      if (_cleanToken(t).isEmpty || _isIgnoredExact(t, ignoredSet)) continue;
      if (!seenMagnitude) {
        if (!_isMoneyMagnitudeToken(t)) return false;
        seenMagnitude = true;
        continue;
      }
      if (_containsCurrencyHint(t, currencyHints)) continue;
      if (_isAmountKeywordExact(t, amountKeywordSet)) continue;
      return false;
    }
    return seenMagnitude;
  }

  /// آخر كلمة فعلية في السطر (بدون الفارغة والمتجاهلة)، أو -1
  static int _lastEffectiveIndex(List<String> tokens, Set<String> ignoredSet) {
    for (int i = tokens.length - 1; i >= 0; i--) {
      final t = tokens[i];
      if (_cleanToken(t).isEmpty || _isIgnoredExact(t, ignoredSet)) continue;
      return i;
    }
    return -1;
  }

  /// آخر كلمة في السطر رقم مبلغ صغير (أقل من 1000، بدون مقدار ملزوق به) أو
  /// عدد لفظي ليس مقدارًا.
  static bool _endsWithAmount(
    List<String> tokens,
    Set<String> ignoredSet,
    Map<String, double> customWordValues,
    Map<String, bool> numberWordCache,
  ) {
    if (tokens.join(' ').contains('#')) return false;
    if (_lineLooksLikeSplitPhone(tokens)) return false;
    final i = _lastEffectiveIndex(tokens, ignoredSet);
    if (i < 0) return false;
    final t = tokens[i];
    if (_hasDigits(t)) {
      if (!_isMoneyDigitToken(t)) return false;
      final norm = _normalizeInlineAmountToken(t);
      if (_extractEmbeddedMoneyMagnitude(norm) != null) return false;
      // «10.000» ثم «مليون» ليست «عشرة آلاف مليون»: الربط للأرقام الصغيرة فقط
      final v = parseAmountToken(norm);
      return v != null && v.abs() < 1000;
    }
    if (_isMagnitudeWord(_normalizeArabic(_cleanToken(t)))) return false;
    return _isNumberWord(t, customWordValues, numberWordCache);
  }

  /// «250» ثم «الف» في سطر بعده (ولو بينهما أسطر فارغة) = «250 الف»: سطر كلمة
  /// المقدار يُلحق بآخر سطر غير فارغ قبله إذا كان ينتهي برقم صغير أو عدد لفظي.
  /// التوكنات تحتفظ بمواقعها الأصلية، فتعليم المبلغ في النص لا يتأثر.
  ///
  /// [currencyAnchor] موقع العملة التي حُذفت قبل كشف المبلغ: إن كان السطر
  /// السابق ينتهي بها («10.000 سوري») فمبلغه اكتمل، وسطر «مليون قديم» بعده
  /// مبلغ آخر وليس مقدارًا له.
  static List<List<AmountPreparedToken>> _joinMagnitudeLines(
    List<List<AmountPreparedToken>> rows, {
    required Set<String> currencyHints,
    required Set<String> amountKeywordSet,
    required Set<String> ignoredSet,
    required Map<String, double> customWordValues,
    required Map<String, bool> numberWordCache,
    Position? currencyAnchor,
  }) {
    List<List<AmountPreparedToken>>? out;
    int? lastIdx;
    for (int li = 0; li < rows.length; li++) {
      final row = out?[li] ?? rows[li];
      if (row.isEmpty) continue;
      final prevIdx = lastIdx;
      lastIdx = li;
      if (prevIdx == null) continue;
      final tokens = [for (final p in row) p.token];
      if (!_isMagnitudeOnlyTokens(
        tokens,
        currencyHints,
        amountKeywordSet,
        ignoredSet,
      )) {
        continue;
      }
      final prevRow = out?[prevIdx] ?? rows[prevIdx];
      final prevTokens = [for (final p in prevRow) p.token];
      if (currencyAnchor != null) {
        final lastEff = _lastEffectiveIndex(prevTokens, ignoredSet);
        if (lastEff >= 0) {
          final last = prevRow[lastEff].originalPos;
          if (currencyAnchor.x == last.x && currencyAnchor.y >= last.y) {
            continue;
          }
        }
      }
      if (!_endsWithAmount(
        prevTokens,
        ignoredSet,
        customWordValues,
        numberWordCache,
      )) {
        continue;
      }
      out ??= List<List<AmountPreparedToken>>.of(rows);
      out[prevIdx] = [...prevRow, ...row];
      out[li] = const <AmountPreparedToken>[];
      lastIdx = prevIdx;
    }
    return out ?? rows;
  }

  // ========= التحضير من lines إلى prepared =========

  static List<List<AmountPreparedToken>> _toPrepared(List<String> lines) {
    final rows = <List<AmountPreparedToken>>[];

    for (int li = 0; li < lines.length; li++) {
      final toks = tokensFromLine(lines[li]);
      rows.add([
        for (int ti = 0; ti < toks.length; ti++)
          AmountPreparedToken(token: toks[ti], originalPos: Position(li, ti)),
      ]);
    }

    return rows;
  }

  // ========= الواجهة القديمة =========

  static AmountDetectResult detect(
    List<String> lines, {
    Set<String> currencyHints = const <String>{},
    List<String> amountKeywords = const <String>[],
    List<String> ignoredWords = const <String>[],
    Map<String, double> customWordValues = const <String, double>{},
    double conflictThreshold = 0.35,
    Position? currencyAnchor,
    int keywordLookAhead = 3,
  }) {
    return detectPrepared(
      preparedTokensByLine: _toPrepared(lines),
      currencyHints: currencyHints,
      amountKeywords: amountKeywords,
      ignoredWords: ignoredWords,
      customWordValues: customWordValues,
      conflictThreshold: conflictThreshold,
      currencyAnchor: currencyAnchor,
      keywordLookAhead: keywordLookAhead,
    );
  }

  // ========= الواجهة الجديدة =========

  static AmountDetectResult detectPrepared({
    required List<List<AmountPreparedToken>> preparedTokensByLine,
    Set<String> currencyHints = const <String>{},
    List<String> amountKeywords = const <String>[],
    List<String> ignoredWords = const <String>[],
    Map<String, double> customWordValues = const <String, double>{},
    double conflictThreshold = 0.35,
    Position? currencyAnchor,
    int keywordLookAhead = 3,
  }) {
    currencyHints = _expandHints(currencyHints);
    final amountKeywordSet = amountKeywords
        .map(_cleanToken)
        .where((e) => e.isNotEmpty)
        .toSet();

    final ignoredSet = ignoredWords
        .map(_cleanToken)
        .where((e) => e.isNotEmpty)
        .toSet();

    final candidates = <_AmountCandidate>[];
    // ذاكرة «هل هذه كلمة عددية؟» تُشارك بين الرسائل ما دامت قيم الكلمات نفسها
    final numberWordCache = _numberWordCaches[customWordValues] ??=
        <String, bool>{};

    int keywordBonus(List<String> tokens, int start, int end) {
      var bonus = 0;
      for (int back = 1; back <= keywordLookAhead; back++) {
        final idx = start - back;
        if (idx >= 0 && _isAmountKeywordExact(tokens[idx], amountKeywordSet)) {
          bonus += 6;
          break;
        }
      }
      for (int fwd = 1; fwd <= keywordLookAhead; fwd++) {
        final idx = end + fwd;
        if (idx < tokens.length &&
            _isAmountKeywordExact(tokens[idx], amountKeywordSet)) {
          bonus += 3;
          break;
        }
      }
      return bonus;
    }

    // كلمة المقدار في سطر مستقل بعد الرقم: «250» ثم «الف» = 250 ألف
    final rows = _joinMagnitudeLines(
      preparedTokensByLine,
      currencyHints: currencyHints,
      amountKeywordSet: amountKeywordSet,
      ignoredSet: ignoredSet,
      customWordValues: customWordValues,
      numberWordCache: numberWordCache,
      currencyAnchor: currencyAnchor,
    );

    int anchorBonus(Position pos) {
      if (currencyAnchor == null || currencyAnchor.x != pos.x) return 0;
      var bonus = 2;
      final dist = (currencyAnchor.y - pos.y).abs();
      if (dist <= 1) {
        bonus += 3;
      } else if (dist <= 3) {
        bonus += 2;
      } else if (dist <= 5) {
        bonus += 1;
      }
      return bonus;
    }

    for (int li = 0; li < rows.length; li++) {
      final row = rows[li];
      if (row.isEmpty) continue;

      final tokens = row.map((e) => e.token).toList();
      if (tokens.join(' ').contains('#')) continue;

      final lineHasKeyword = tokens.any(
        (t) => _isAmountKeywordExact(t, amountKeywordSet),
      );
      final lineHasCurrency = tokens.any(
        (t) => _containsCurrencyHint(t, currencyHints),
      );

      // توكن رقمي صالح ليكون جزءًا من مبلغ؟
      bool isMoneyDigitToken(String t) {
        if (!_hasDigits(t)) return false;
        if (t.contains('+') || t.contains('#')) return false;
        if (_isPhoneLikeToken(t) || _isLongIdToken(t)) return false;
        if (_isTimeOrDateToken(t)) return false;
        return parseAmountToken(_normalizeInlineAmountToken(t)) != null;
      }

      // ---------- 1) التعابير اللفظية/المركّبة (خمسمية، 2 مليون و500 الف) ----------
      final coveredByText = <int>{};
      var i = 0;
      while (i < tokens.length) {
        bool spanable(int k) {
          final t = tokens[k];
          if (t.isEmpty || _isIgnoredExact(t, ignoredSet)) return false;
          if (_phoneWords.contains(_normalizeArabic(t))) return false;
          if (isMoneyDigitToken(t)) return true;
          return _isNumberWord(t, customWordValues, numberWordCache);
        }

        if (!spanable(i)) {
          i++;
          continue;
        }
        final start = i;
        while (i < tokens.length) {
          if (spanable(i)) {
            i++;
            continue;
          }
          // «و» وحدها تربط جزأين من نفس المبلغ
          if (_normalizeArabic(tokens[i]) == 'و' &&
              i + 1 < tokens.length &&
              spanable(i + 1)) {
            i++;
            continue;
          }
          break;
        }
        final end = i - 1;

        final digitIdx = <int>[];
        final magnitudeIdx = <int>[];
        final quantityIdx = <int>[];
        for (int k = start; k <= end; k++) {
          final t = tokens[k];
          if (_hasDigits(t)) {
            digitIdx.add(k);
          } else if (_isMagnitudeWord(_normalizeArabic(_cleanToken(t)))) {
            magnitudeIdx.add(k);
          } else if (_isNumberWord(t, customWordValues, numberWordCache)) {
            quantityIdx.add(k);
          }
        }

        // أرقام فقط، أو رقم واحد يتبعه مقدار واحد (500 الف): المرحلة الرقمية تكفي
        if (quantityIdx.isEmpty &&
            (magnitudeIdx.isEmpty ||
                (magnitudeIdx.length == 1 &&
                    digitIdx.length == 1 &&
                    magnitudeIdx.first == digitIdx.first + 1))) {
          continue;
        }

        final spanText = tokens.sublist(start, end + 1).join(' ');
        final parsed = AmountTextParser.parse(
          spanText,
          customWordValues: customWordValues,
        );
        final value = parsed.matched ? parsed.value : null;
        if (value == null || value <= 0 || value.abs() < 10) continue;

        // كلمة مقدار وحدها (مثل «ألف شكر») تعبير ضعيف
        final weak = quantityIdx.isEmpty && digitIdx.isEmpty;

        var score = weak ? 1 : 5;
        final prev = start > 0 ? tokens[start - 1] : null;
        final next = end + 1 < tokens.length ? tokens[end + 1] : null;
        var hasContext = false;
        // للتعبير الضعيف (كلمة مقدار وحدها) لا نعتبر العملة التي تسبقه دليلًا:
        // «500 دولار ألف شكر».
        if ((!weak &&
                prev != null &&
                _containsCurrencyHint(prev, currencyHints)) ||
            (next != null && _containsCurrencyHint(next, currencyHints)) ||
            tokens
                .sublist(start, end + 1)
                .any((t) => _containsCurrencyHint(t, currencyHints))) {
          score += 4;
          hasContext = true;
        }
        final kb = keywordBonus(tokens, start, end);
        if (kb > 0) hasContext = true;
        score += kb;
        if (lineHasCurrency) score += 1;
        if (lineHasKeyword) score += 1;
        score += anchorBonus(row[start].originalPos);

        if (weak && !hasContext) continue;

        // أجزاء التعبير المركّب لا تُعرض كمبالغ مستقلة
        if (!weak && digitIdx.isNotEmpty) {
          var maxPart = 0.0;
          for (final k in digitIdx) {
            final v = parseAmountToken(_normalizeInlineAmountToken(tokens[k]));
            if (v != null && v.abs() > maxPart) maxPart = v.abs();
          }
          if (value.abs() + 1e-9 >= maxPart) {
            for (int k = start; k <= end; k++) {
              coveredByText.add(k);
            }
          }
        }

        candidates.add(
          _AmountCandidate(
            pos: row[start].originalPos,
            value: value,
            score: score,
            fromText: true,
          ),
        );
      }

      // ---------- 2) المرشحات الرقمية ----------
      if (_lineLooksLikeSplitPhone(tokens) &&
          !lineHasCurrency &&
          !lineHasKeyword) {
        continue;
      }

      bool seenPhoneWord = false;
      bool stopAfterRangeWord = false;

      for (int ti = 0; ti < tokens.length; ti++) {
        final t = tokens[ti];
        if (t.isEmpty) continue;

        if (_isIgnoredExact(t, ignoredSet)) continue;
        if (t.contains('+') || t.contains('#')) continue;

        final norm = _normalizeArabic(t);

        if (_phoneWords.contains(norm)) {
          seenPhoneWord = true;
          continue;
        }

        if (_rangeWords.contains(norm)) {
          stopAfterRangeWord = true;
          continue;
        }

        if (stopAfterRangeWord) continue;
        if (seenPhoneWord) continue;
        if (coveredByText.contains(ti)) continue;
        if (_isPhoneLikeToken(t)) continue;
        if (_isLongIdToken(t)) continue;
        if (_isTimeOrDateToken(t)) continue;

        final prev = ti > 0 ? tokens[ti - 1] : null;
        final next = ti + 1 < tokens.length ? tokens[ti + 1] : null;

        if (prev != null && _isNonMoneyUnitToken(prev)) continue;
        if (_isNonMoneyUnitToken(t)) continue;

        final tokenForParsing = _normalizeInlineAmountToken(t);

        double? v = parseAmountToken(tokenForParsing);
        if (v == null) continue;

        // أولًا: مقدار ملزوق داخل نفس التوكن مثل 250الف$ أو 3طون
        final embeddedMagnitude = _extractEmbeddedMoneyMagnitude(
          tokenForParsing,
        );
        if (embeddedMagnitude != null) {
          v = _applyMagnitudeSmart(v, embeddedMagnitude);
        }
        // ثانيًا: مقدار منفصل في التوكن التالي مثل 3 طن أو 250 الف
        else if (next != null && _isMoneyMagnitudeToken(next)) {
          v = _applyMagnitudeSmart(v, next);
        }

        // فلترة الأرقام الصغيرة تكون بعد تطبيق المقدار وليس قبله
        if (v.abs() < 10) continue;

        int score = 1;

        if (_containsCurrencyHint(tokenForParsing, currencyHints)) score += 4;
        if (prev != null && _containsCurrencyHint(prev, currencyHints)) {
          score += 4;
        }
        if (next != null && _containsCurrencyHint(next, currencyHints)) {
          score += 4;
        }

        if (lineHasCurrency) score += 1;

        if (embeddedMagnitude != null) {
          score += 4;
        } else if (next != null && _isMoneyMagnitudeToken(next)) {
          score += 4;
        }
        if (prev != null && _isMoneyMagnitudeToken(prev)) score += 2;

        // دعم كلمات المبلغ exact فقط
        score += keywordBonus(tokens, ti, ti);

        if (lineHasKeyword) score += 1;

        score += anchorBonus(row[ti].originalPos);

        // رقم يشبه هاتفًا محليًا بدون مفتاح: يبقى مرشحًا بنقاط أقل
        if (_isSuspectPhoneDigits(t)) score -= 2;

        candidates.add(
          _AmountCandidate(
            pos: row[ti].originalPos,
            value: v,
            score: score,
            fromText: false,
          ),
        );
      }
    }

    // 3) المرشحات المميزة (مع موقع أقوى مرشح لكل قيمة)
    final candidateValues = <double>[];
    for (final c in candidates) {
      _addUniqueAmount(candidateValues, c.value);
    }
    candidateValues.sort();
    final candidatePositions = <Position>[
      for (final v in candidateValues)
        candidates
            .where((c) => _sameAmount(c.value, v))
            .reduce((a, b) => b.beats(a) ? b : a)
            .pos,
    ];

    // 4) أفضل مرشح إجمالًا (بدل «آخر سطر نصي يفوز»)
    _AmountCandidate? best;
    _AmountCandidate? bestNumeric;
    _AmountCandidate? bestText;
    for (final c in candidates) {
      if (best == null || c.beats(best)) best = c;
      if (c.fromText) {
        if (bestText == null || c.beats(bestText)) bestText = c;
      } else {
        if (bestNumeric == null || c.beats(bestNumeric)) bestNumeric = c;
      }
    }

    // 5) تعارض حقيقي: نصي ورقمي مختلفان بدون أفضلية واضحة لأحدهما
    bool conflict = false;
    if (bestText != null && bestNumeric != null) {
      final a = bestText.value.abs();
      final b = bestNumeric.value.abs();
      final big = a > b ? a : b;
      final rel = (a - b).abs() / (big == 0 ? 1 : big);
      conflict =
          rel >= conflictThreshold &&
          (bestText.score - bestNumeric.score).abs() <= 2;
    }

    final hasMultipleCandidates = candidateValues.length >= 2;

    return AmountDetectResult(
      numericPos: best?.pos,
      numericValue: best?.value,
      textValue: bestText?.value,
      hasConflict: conflict,
      hasMultipleCandidates: hasMultipleCandidates,
      candidateValues: candidateValues,
      fromText: best?.fromText ?? false,
      candidatePositions: candidatePositions,
    );
  }
}
