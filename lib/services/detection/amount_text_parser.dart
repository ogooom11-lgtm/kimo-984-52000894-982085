// lib/services/detection/amount_text_parser.dart
// -------------------------------------------------------------
// خدمة مستقلة لتحويل المبالغ المكتوبة كتابةً أو بصيغ مختلطة إلى أرقام.
// أمثلة مدعومة:
// - ٣مليون و١١٥ الف
// - مليون و 225 الف
// - 5 مليون و نص
// - فقط خمسة ملايين ليرة سورية
// - مليونين وستمائة ألف
// - 150طن / 22 طون   => طن/طون = مليون
// -------------------------------------------------------------

class AmountTextParseResult {
  final double? value;
  final bool matched;
  final double confidence;
  final String normalizedText;

  const AmountTextParseResult({
    required this.value,
    required this.matched,
    required this.confidence,
    required this.normalizedText,
  });

  static const empty = AmountTextParseResult(
    value: null,
    matched: false,
    confidence: 0.0,
    normalizedText: '',
  );
}

class _SegmentParseResult {
  final double value;
  final bool matched;
  final bool hadMagnitude;
  final double? lastMagnitudeUnit;
  final bool halfOnly;

  const _SegmentParseResult({
    required this.value,
    required this.matched,
    required this.hadMagnitude,
    required this.lastMagnitudeUnit,
    required this.halfOnly,
  });
}

class AmountTextParser {
  // ====== واجهة الاستخدام ======
  static AmountTextParseResult parse(
    String text, {
    Map<String, double> customWordValues = const {},
  }) {
    if (text.trim().isEmpty) return AmountTextParseResult.empty;

    final normalized = _normalizeInput(text);
    final customValues = _normalizeCustomWordValues(customWordValues);
    final directCombo = RegExp(
      r'^'
      r'([0-9\u0660-\u0669]+)\s*'
      r'(مليون|ملايين|طن|طون|مليار|مليارات)\s*'
      r'و\s*'
      r'([0-9\u0660-\u0669]+)\s*'
      r'(الف|الاف|ألف|آلاف)'
      r'$',
      unicode: true,
    ).firstMatch(normalized);

    if (directCombo != null) {
      final first = _parseNumericToken(directCombo.group(1) ?? '') ?? 0;
      final bigMag = _magnitudeUnitValue(directCombo.group(2) ?? '') ?? 0;
      final second = _parseNumericToken(directCombo.group(3) ?? '') ?? 0;
      final smallMag = _magnitudeUnitValue(directCombo.group(4) ?? '') ?? 0;

      final total = (first * bigMag) + (second * smallMag);

      if (total > 0) {
        return AmountTextParseResult(
          value: total,
          matched: true,
          confidence: 0.98,
          normalizedText: normalized,
        );
      }
    }
    if (normalized.isEmpty) return AmountTextParseResult.empty;

    final segments = normalized
        .split(RegExp(r'\s+و\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (segments.isEmpty) return AmountTextParseResult.empty;

    double total = 0.0;
    bool matchedAny = false;
    double? lastLargeMagnitude; // مليون/مليار

    for (final seg in segments) {
      final parsed = _parseSegment(seg, customValues);
      if (!parsed.matched || parsed.value <= 0) continue;

      matchedAny = true;

      // مثال: "5 مليون و نص" => segment("نصف") بعد مليون
      if (parsed.halfOnly && lastLargeMagnitude != null) {
        total += parsed.value * lastLargeMagnitude; // 0.5 * 1e6
        continue;
      }

      // مثال شائع مختصر: "3 مليون و 220" => 3,220,000
      // نعامله كآلاف فقط إذا كان قبلها مليون/مليار ولا يوجد مقدار صريح في هذا الجزء.
      if (!parsed.hadMagnitude &&
          lastLargeMagnitude != null &&
          lastLargeMagnitude >= 1e6 &&
          parsed.value > 0 &&
          parsed.value < 1000000) {
        total += parsed.value * 1e3;
        continue;
      }

      total += parsed.value;

      if (parsed.lastMagnitudeUnit != null &&
          parsed.lastMagnitudeUnit! >= 1e6) {
        lastLargeMagnitude = parsed.lastMagnitudeUnit;
      }
    }

    if (!matchedAny || total <= 0) {
      return AmountTextParseResult(
        value: null,
        matched: false,
        confidence: 0.0,
        normalizedText: normalized,
      );
    }

    final hasMagnitude = RegExp(
      r'(?<![\u0600-\u06FF])(الف|مليون|مليار|طن|طون)(?![\u0600-\u06FF])',
    ).hasMatch(normalized);
    final confidence = hasMagnitude ? 0.96 : 0.82;

    return AmountTextParseResult(
      value: total,
      matched: true,
      confidence: confidence,
      normalizedText: normalized,
    );
  }

  // ====== التحليل الداخلي ======
  static _SegmentParseResult _parseSegment(
    String seg,
    Map<String, double> customWordValues,
  ) {
    final tokens = seg
        .split(RegExp(r'\s+'))
        .map(_normalizeToken)
        .where((e) => e.isNotEmpty && e != 'و')
        .toList();

    if (tokens.isEmpty) {
      return const _SegmentParseResult(
        value: 0,
        matched: false,
        hadMagnitude: false,
        lastMagnitudeUnit: null,
        halfOnly: false,
      );
    }

    final halfOnly = tokens.length == 1 && _isHalfToken(tokens.first);

    double total = 0.0;
    double current = 0.0;
    bool matched = false;
    bool hadMagnitude = false;
    double? lastMagnitudeUnit;

    for (final token in tokens) {
      final mag = _magnitudeUnitValue(token);
      if (mag != null) {
        final base = current > 0 ? current : (_isHalfToken(token) ? 0.5 : 1.0);
        total += _applyMagnitudeSmart(base, mag);
        current = 0.0;
        matched = true;
        hadMagnitude = true;
        lastMagnitudeUnit = mag;
        continue;
      }

      if (_isHalfToken(token)) {
        current += 0.5;
        matched = true;
        continue;
      }

      final numeric = _parseNumericToken(token);
      if (numeric != null) {
        current += numeric;
        matched = true;
        continue;
      }

      final custom = customWordValues[token];
      if (custom != null) {
        if (custom >= 100 && current > 0) {
          current = _applyMagnitudeSmart(current, custom);
          hadMagnitude = true;
          lastMagnitudeUnit = custom;
        } else {
          current += custom;
        }
        matched = true;
        continue;
      }

      final direct = _directNumberWords[token];
      if (direct != null) {
        current += direct.toDouble();
        matched = true;
        continue;
      }

      final hundredDirect = _directHundreds[token];
      if (hundredDirect != null) {
        if (current > 0) {
          current = _applyMagnitudeSmart(current, hundredDirect.toDouble());
        } else {
          current += hundredDirect.toDouble();
        }
        matched = true;
        hadMagnitude = true;
        lastMagnitudeUnit = hundredDirect.toDouble();
        continue;
      }

      if (_isHundredWord(token)) {
        if (current == 0) current = 1;
        current *= 100;
        matched = true;
        continue;
      }

      // كلمات غير مهمة مثل:
      // فقط، صافي، ليرة، دولار، سوري، جديد...
      // نتجاهلها بدون إفساد التحليل.
    }

    if (current > 0) {
      // مثال: "3 مليون 220" داخل نفس الجزء
      if (hadMagnitude &&
          lastMagnitudeUnit != null &&
          lastMagnitudeUnit >= 1e6 &&
          current < 1000000) {
        total += current * 1e3;
      } else {
        total += current;
      }
    }

    return _SegmentParseResult(
      value: total,
      matched: matched || total > 0,
      hadMagnitude: hadMagnitude,
      lastMagnitudeUnit: lastMagnitudeUnit,
      halfOnly: halfOnly,
    );
  }

  // ====== التطبيع ======
  static String _stripDiacritics(String s) =>
      s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');

  static String _normalizeArabic(String s) {
    s = _stripDiacritics(s);
    s = s.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
    s = s.replaceAll('ى', 'ي').replaceAll('ئ', 'ي').replaceAll('ؤ', 'و');
    s = s.replaceAll('ة', 'ه');
    return s.trim();
  }

  static String _toAsciiDigits(String s) {
    final out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x0660 && c <= 0x0669) {
        out.writeCharCode(0x30 + (c - 0x0660));
      } else {
        out.writeCharCode(c);
      }
    }
    return out.toString();
  }

  static String _normalizeInput(String text) {
    String t = _toAsciiDigits(text);
    t = _normalizeArabic(t);

    // توحيد الفواصل
    t = t
        .replaceAll('٫', '.')
        .replaceAll('٬', ',')
        .replaceAll('،', ',')
        .replaceAll('\n', ' ');

    // فصل رموز العملة عن الرقم أو الكلمة
    t = t.replaceAllMapped(
      RegExp(r'([0-9])([\$€£﷼₺])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    t = t.replaceAllMapped(
      RegExp(r'([\$€£﷼₺])([0-9])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    // فصل رمز العملة عن الكلمة العربية أيضًا
    t = t.replaceAllMapped(
      RegExp(r'([\u0600-\u06FF])([\$€£﷼₺])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    t = t.replaceAllMapped(
      RegExp(r'([\$€£﷼₺])([\u0600-\u06FF])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // إضافة مسافة بين الرقم والحروف العربية
    t = t.replaceAllMapped(
      RegExp(r'([0-9])([\u0600-\u06FF])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    t = t.replaceAllMapped(
      RegExp(r'([\u0600-\u06FF])([0-9])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // مثال: 3مليونو350الف => 3 مليون و 350 الف
    t = t.replaceAllMapped(
      RegExp(
        r'(الف|الاف|لف|مليون|ملايين|مليار|مليارات|طن|طون)\s*و\s*(?=[0-9\u0660-\u0669])',
        unicode: true,
      ),
      (m) => '${m.group(1)} و ',
    );

    t = t.replaceAllMapped(
      RegExp(
        r'(الف|الاف|لف|مليون|ملايين|مليار|مليارات|طن|طون)\s*و\s*(?=[\u0600-\u06FF])',
        unicode: true,
      ),
      (m) => '${m.group(1)} و ',
    );

    // و350 => و 350
    t = t.replaceAllMapped(RegExp(r'\bو(?=[0-9])'), (_) => 'و ');

    // وشيء => و شيء
    t = t.replaceAllMapped(RegExp(r'\bو(?=[\u0600-\u06FF])'), (_) => 'و ');
    t = t.replaceAllMapped(
      RegExp(
        r'([0-9\u0660-\u0669]+)\s*(مليون|ملايين|طن|طون|مليار|مليارات)\s*و\s*([0-9\u0660-\u0669]+)\s*(الف|الاف|ألف|آلاف)',
        unicode: true,
      ),
      (m) => '${m.group(1)} ${m.group(2)} و ${m.group(3)} ${m.group(4)}',
    );

    // تنظيف ضجيج شائع
    t = t.replaceAll(RegExp(r'[/\\|=*#:_~]+'), ' ');
    t = t.replaceAll(RegExp(r'[()\[\]{}]+'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

    // توحيد صيغ المقادير
    // ملاحظة: \b في Dart لا يعتبر الحروف العربية جزءًا من الكلمة، لذلك نستخدم
    // حدودًا عربية صريحة (_word).
    t = t.replaceAll(_word('الالف|الف|الاف|لف'), 'الف');
    t = t.replaceAll(_word('ملايين'), 'مليون');
    t = t.replaceAll(_word('مليارات'), 'مليار');

    // طن/طون = مليون
    t = t.replaceAll(_word('طن'), 'مليون');
    t = t.replaceAll(_word('طون'), 'مليون');

    // المثنى
    t = t.replaceAll(_word('مليونين|مليونان'), '2 مليون');
    t = t.replaceAll(_word('مليارين|ملياران'), '2 مليار');
    t = t.replaceAll(_word('الفين|الفان'), '2 الف');

    // شيوع كتابات مختلفة
    t = t.replaceAll(_word('نص'), 'نصف');
    t = t.replaceAll(_word('للف'), 'الف');

    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// كلمة/كلمات عربية كاملة (بدون أن تكون جزءًا من كلمة أطول)
  static RegExp _word(String alternatives) => RegExp(
    '(?<![\u0600-\u06FF])(?:$alternatives)(?![\u0600-\u06FF])',
    unicode: true,
  );

  static String _normalizeToken(String token) {
    String t = token.trim();

    // نزيل نقاط/فواصل زائدة من الأطراف فقط
    t = t.replaceAll(RegExp(r'^[^\u0600-\u06FF0-9\$€£﷼₺]+'), '');
    t = t.replaceAll(RegExp(r'[^\u0600-\u06FF0-9\$€£﷼₺]+$'), '');
    t = t.trim();

    if (t.isEmpty) return '';

    // لو بدأت بـ "و" وكانت بعدها كلمة/رقم مفهوم
    if (t.startsWith('و') && t.length > 1) {
      final rest = t.substring(1).trim();
      if (_isRecognizedToken(rest)) return rest;
    }

    return t;
  }

  static bool _isRecognizedToken(String token) {
    if (token.isEmpty) return false;
    if (_isHalfToken(token)) return true;
    if (_magnitudeUnitValue(token) != null) return true;
    if (_parseNumericToken(token) != null) return true;
    if (_directNumberWords.containsKey(token)) return true;
    if (_directHundreds.containsKey(token)) return true;
    if (_isHundredWord(token)) return true;
    return false;
  }

  static Map<String, double> _normalizeCustomWordValues(
    Map<String, double> values,
  ) {
    if (values.isEmpty) return const {};
    final out = <String, double>{};
    for (final entry in values.entries) {
      final key = _normalizeToken(_normalizeInput(entry.key));
      final value = entry.value;
      if (key.isNotEmpty && value > 0) out[key] = value;
    }
    return out;
  }

  // ====== القيم النصية ======
  static const Map<String, int> _directNumberWords = {
    'صفر': 0,
    'واحد': 1,
    'واحده': 1,
    'واحده.': 1,
    'واحده،': 1,
    'واحده\$': 1,
    'واحده\$\$': 1,
    'واحده\$\$\$': 1,
    'واحده\$\$\$\$': 1,
    'واحده\$\$\$\$\$': 1,
    'واحده\$ \$': 1,
    'واحده\$ \$\$': 1,
    'واحده\$ \$\$\$': 1,
    'واحده\$ \$\$\$\$': 1,
    'واحده\$ \$\$\$\$\$': 1,
    'واحده\$ \$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$': 1,
    'واحده\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$': 1,

    'واحده؟': 1,
    'واحده!': 1,
    'واحده،.': 1,
    'واحده..': 1,
    'واحده...': 1,

    'اثنان': 2,
    'اثنين': 2,
    'اتنين': 2,
    'اثنتان': 2,
    'اثنتين': 2,
    'ثلاث': 3,
    'ثلاثه': 3,
    'ثلاثة': 3,
    'اربع': 4,
    'اربعه': 4,
    'اربعة': 4,
    'خمس': 5,
    'خمسه': 5,
    'خمسة': 5,
    'ست': 6,
    'سته': 6,
    'ستة': 6,
    'سبع': 7,
    'سبعه': 7,
    'سبعة': 7,
    'ثمان': 8,
    'ثماني': 8,
    'ثمانيه': 8,
    'ثمانية': 8,
    'تسع': 9,
    'تسعه': 9,
    'تسعة': 9,
    'عشر': 10,
    'عشرة': 10,
    'عشره': 10,
    'احدعشر': 11,
    'احد عشر': 11,
    'اثناعشر': 12,
    'اثني عشر': 12,
    'اثنا عشر': 12,
    'ثلاثةعشر': 13,
    'ثلاثهعشر': 13,
    'اربعةعشر': 14,
    'اربعهعشر': 14,
    'خمسةعشر': 15,
    'خمسهعشر': 15,
    'ستةعشر': 16,
    'ستهعشر': 16,
    'سبعةعشر': 17,
    'سبعهعشر': 17,
    'ثمانيةعشر': 18,
    'ثمانيهعشر': 18,
    'تسعةعشر': 19,
    'تسعهعشر': 19,
    'عشرين': 20,
    'ثلاثين': 30,
    'تلاتين': 30,
    'تلاثين': 30,
    'تلات': 3,
    'تلاته': 3,
    'تمن': 8,
    'تمانيه': 8,
    'تماني': 8,
    'تمانين': 80,
    'تمنين': 80,
    'اربعين': 40,
    'خمسين': 50,
    'ستين': 60,
    'سبعين': 70,
    'ثمانين': 80,
    'تسعين': 90,
  };

  static const Map<String, int> _directHundreds = {
    'مئتين': 200,
    'مئتان': 200,
    'ميتين': 200,
    'ثلاثمئه': 300,
    'ثلاثمئة': 300,
    'اربعمئه': 400,
    'اربعمئة': 400,
    'خمسمئه': 500,
    'خمسمئة': 500,
    'ستمئه': 600,
    'ستمئة': 600,
    'سبعمئه': 700,
    'سبعمئة': 700,
    'ثمانمئه': 800,
    'ثمانمئة': 800,
    'تسعمئه': 900,
    'تسعمئة': 900,
    // الصيغ بعد التطبيع (مئة/مية/مائة → ميه/مايه) والعامية
    'مايتين': 200,
    'ميتان': 200,
    'ثلاثميه': 300,
    'تلاتميه': 300,
    'تلتميه': 300,
    'ثلاثمايه': 300,
    'اربعميه': 400,
    'ربعميه': 400,
    'اربعمايه': 400,
    'خمسميه': 500,
    'خمسمايه': 500,
    'ستميه': 600,
    'ستمايه': 600,
    'سبعميه': 700,
    'سبعمايه': 700,
    'ثمانميه': 800,
    'تمانميه': 800,
    'تمنميه': 800,
    'ثمانمايه': 800,
    'تسعميه': 900,
    'تسعمايه': 900,
  };

  static bool _isHundredWord(String token) {
    return token == 'مئه' ||
        token == 'مئة' ||
        token == 'ميه' ||
        token == 'مايه';
  }

  static bool _isHalfToken(String token) {
    return token == 'نصف' || token == 'نص';
  }

  static double? _magnitudeUnitValue(String token) {
    final t = _normalizeArabic(token);

    if (t == 'الف' || t == 'الاف' || t == 'ألف' || t == 'آلاف') return 1e3;
    if (t == 'مليون' || t == 'ملايين' || t == 'طن' || t == 'طون') return 1e6;
    if (t == 'مليار' || t == 'مليارات') return 1e9;

    return null;
  }

  static double _applyMagnitudeSmart(double baseValue, double unit) {
    if (unit <= 1.0) return baseValue;

    // 2000000 مليون => لا تضربه مرة ثانية
    if (baseValue >= unit) return baseValue;

    return baseValue * unit;
  }

  // ====== تحليل رقم مباشر ======
  static double? _parseNumericToken(String token) {
    if (token.isEmpty) return null;

    String t = token.trim();

    final m = RegExp(r'([+\-]?[0-9][0-9,.\u066B\u066C]*)').firstMatch(t);
    if (m == null) return null;

    t = m.group(1) ?? '';
    if (t.isEmpty) return null;

    t = t.replaceAll('٫', '.').replaceAll('٬', ',').replaceAll('،', ',');

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
}
