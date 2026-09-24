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

  const AmountDetectResult({
    required this.numericPos,
    required this.numericValue,
    required this.textValue,
    required this.hasConflict,
    required this.hasMultipleCandidates,
    required this.candidateValues,
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

  static bool _isAsciiDigitCode(int code) => code >= 0x30 && code <= 0x39;
  static bool _isArabicDigitCode(int code) => code >= 0x0660 && code <= 0x0669;
  static bool _isDigitCode(int code) =>
      _isAsciiDigitCode(code) || _isArabicDigitCode(code);

  static String _squashDigitSeparators(String w) {
    if (w.isEmpty) return w;
    final sep = RegExp(r'[.,،\-\_\u0640\u066B\u066C]');
    final out = StringBuffer();

    for (int i = 0; i < w.length; i++) {
      final ch = w[i];
      final prev = (i > 0) ? w.codeUnitAt(i - 1) : null;
      final next = (i + 1 < w.length) ? w.codeUnitAt(i + 1) : null;

      if (sep.hasMatch(ch)) {
        if (prev != null &&
            next != null &&
            _isDigitCode(prev) &&
            _isDigitCode(next)) {
          continue;
        }
      }

      out.write(ch);
    }

    return out.toString();
  }

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
    final amountKeywordSet = amountKeywords
        .map(_cleanToken)
        .where((e) => e.isNotEmpty)
        .toSet();

    final ignoredSet = ignoredWords
        .map(_cleanToken)
        .where((e) => e.isNotEmpty)
        .toSet();

    final candidates = <_AmountCandidate>[];
    double? textValue;
    Position? textPos;

    // 1) كشف التركيبات النصية على مستوى السطر
    for (int li = 0; li < preparedTokensByLine.length; li++) {
      final row = preparedTokensByLine[li];
      if (row.isEmpty) continue;

      final tokens = row.map((e) => e.token).toList();
      final line = tokens.join(' ');

      if (line.contains('#')) continue;
      if (tokens.any((t) => _isIgnoredExact(t, ignoredSet))) {
        // لا نسقط السطر كله، فقط لا نرفع ثقته
      }

      final parsedText = AmountTextParser.parse(
        line,
        customWordValues: customWordValues,
      );
      final txt = parsedText.matched ? parsedText.value : null;
      if (txt != null && txt > 0) {
        int score = 5;
        if (tokens.any((t) => _containsCurrencyHint(t, currencyHints)))
          score += 3;
        if (tokens.any((t) => _isAmountKeywordExact(t, amountKeywordSet)))
          score += 4;
        if (currencyAnchor != null && currencyAnchor.x == li) score += 2;

        textValue = txt;
        textPos = row.first.originalPos;

        candidates.add(
          _AmountCandidate(
            pos: textPos,
            value: txt,
            score: score,
            fromText: true,
          ),
        );
      }
    }

    // 2) كشف المرشحات الرقمية
    for (int li = 0; li < preparedTokensByLine.length; li++) {
      final row = preparedTokensByLine[li];
      if (row.isEmpty) continue;

      final tokens = row.map((e) => e.token).toList();

      if (tokens.isEmpty) continue;
      if (tokens.join(' ').contains('#')) continue;

      final lineHasKeyword = tokens.any(
        (t) => _isAmountKeywordExact(t, amountKeywordSet),
      );
      final lineHasCurrency = tokens.any(
        (t) => _containsCurrencyHint(t, currencyHints),
      );

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
        if (_isPhoneLikeToken(t)) continue;

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
        if (prev != null && _containsCurrencyHint(prev, currencyHints))
          score += 4;
        if (next != null && _containsCurrencyHint(next, currencyHints))
          score += 4;

        if (lineHasCurrency) score += 1;

        if (embeddedMagnitude != null)
          score += 4;
        else if (next != null && _isMoneyMagnitudeToken(next))
          score += 4;
        if (prev != null && _isMoneyMagnitudeToken(prev)) score += 2;

        // دعم كلمات المبلغ exact فقط
        for (int back = 1; back <= keywordLookAhead; back++) {
          final idx = ti - back;
          if (idx >= 0 &&
              _isAmountKeywordExact(tokens[idx], amountKeywordSet)) {
            score += 6;
            break;
          }
        }

        for (int fwd = 1; fwd <= keywordLookAhead; fwd++) {
          final idx = ti + fwd;
          if (idx < tokens.length &&
              _isAmountKeywordExact(tokens[idx], amountKeywordSet)) {
            score += 3;
            break;
          }
        }

        if (lineHasKeyword) score += 1;

        if (currencyAnchor != null) {
          if (currencyAnchor.x == row[ti].originalPos.x) {
            score += 2;
            final dist = (currencyAnchor.y - row[ti].originalPos.y).abs();
            if (dist <= 1) {
              score += 3;
            } else if (dist <= 3) {
              score += 2;
            } else if (dist <= 5) {
              score += 1;
            }
          }
        }

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

    // 3) المرشحات المميزة
    final candidateValues = <double>[];
    for (final c in candidates) {
      _addUniqueAmount(candidateValues, c.value);
    }
    candidateValues.sort();

    // 4) اختيار أفضل مرشح رقمي
    _AmountCandidate? bestNumeric;
    for (final c in candidates.where((e) => !e.fromText)) {
      if (bestNumeric == null) {
        bestNumeric = c;
        continue;
      }

      if (c.score > bestNumeric.score ||
          (c.score == bestNumeric.score &&
              c.value.abs() > bestNumeric.value.abs())) {
        bestNumeric = c;
      }
    }

    // 5) حسم النصي مع الرقمي
    double? finalNumeric = bestNumeric?.value;
    Position? finalPos = bestNumeric?.pos;
    bool conflict = false;

    if (finalNumeric != null && textValue != null) {
      final big = finalNumeric.abs() > textValue.abs()
          ? finalNumeric
          : textValue;
      final small = finalNumeric.abs() > textValue.abs()
          ? textValue
          : finalNumeric;
      final rel = (big - small).abs() / (big == 0 ? 1 : big.abs());
      conflict = rel >= conflictThreshold;

      if (conflict) {
        finalNumeric = textValue;
        finalPos = textPos;
      }
    } else if (finalNumeric == null && textValue != null) {
      finalNumeric = textValue;
      finalPos = textPos;
    }

    final hasMultipleCandidates = candidateValues.length >= 2;

    return AmountDetectResult(
      numericPos: finalPos,
      numericValue: finalNumeric,
      textValue: textValue,
      hasConflict: conflict,
      hasMultipleCandidates: hasMultipleCandidates,
      candidateValues: candidateValues,
    );
  }
}
