// lib/services/detection/message_noise.dart
// -------------------------------------------------------------
// كشف «الضجيج» داخل رسائل التسليم: أرقام الهواتف (مع أو بدون مفتاح دولي،
// ملزوقة أو مفصولة بمسافات/شرطات)، التواريخ، الأوقات، الأكواد وأرقام المرجع،
// النسب، الروابط والأرقام الطويلة — حتى لا تُعتبر مبلغًا ولا جزءًا من الاسم.
//
// الفهارس مطابقة تمامًا لـ tokensFromLine في text_tokens.dart.
// (ملف Dart نقي بدون Flutter)
// -------------------------------------------------------------

import 'text_tokens.dart' as tt;

enum NoiseKind { phone, date, time, code, percent, link, longNumber, context }

extension NoiseKindInfo on NoiseKind {
  String get label {
    switch (this) {
      case NoiseKind.phone:
        return 'رقم هاتف';
      case NoiseKind.date:
        return 'تاريخ';
      case NoiseKind.time:
        return 'وقت';
      case NoiseKind.code:
        return 'رمز/رقم مرجع';
      case NoiseKind.percent:
        return 'نسبة';
      case NoiseKind.link:
        return 'رابط';
      case NoiseKind.longNumber:
        return 'رقم طويل';
      case NoiseKind.context:
        return 'كلمة دالة';
    }
  }
}

class NoiseMark {
  final NoiseKind kind;

  /// رقم مشكوك به (مثل 8–9 أرقام متتالية غير مدوّرة): يُستبعد في المحاولة
  /// الأولى لكشف المبلغ، ويُسمح به فقط إن لم يوجد أي مبلغ آخر.
  final bool suspect;

  const NoiseMark(this.kind, {this.suspect = false});

  @override
  String toString() => 'NoiseMark(${kind.name}${suspect ? ', suspect' : ''})';
}

/// مبلغ مكتوب بمجموعات آلاف مفصولة بمسافات: «1 500 000» أو «500 000»
class MergedNumber {
  final int start;
  final int end; // شامل
  final String digits;

  const MergedNumber(this.start, this.end, this.digits);

  bool contains(int i) => i >= start && i <= end;
}

class LineNoise {
  /// التوكنات (مطابقة لـ tokensFromLine)
  final List<String> tokens;

  /// القطعة الخام المقابلة لكل توكن (قبل التنظيف)
  final List<String> raw;

  final Map<int, NoiseMark> marks;
  final List<MergedNumber> merged;

  LineNoise({
    required this.tokens,
    required this.raw,
    required this.marks,
    required this.merged,
  });

  NoiseMark? markAt(int i) => marks[i];

  bool isNoise(int i, {bool includeSuspect = true}) {
    final m = marks[i];
    if (m == null) return false;
    return includeSuspect || !m.suspect;
  }

  MergedNumber? mergedStartingAt(int i) {
    for (final m in merged) {
      if (m.start == i) return m;
    }
    return null;
  }

  /// توكن داخل مبلغ مدموج لكنه ليس أوله (يُحذف من مراحل الكشف)
  bool isAbsorbed(int i) {
    for (final m in merged) {
      if (i > m.start && i <= m.end) return true;
    }
    return false;
  }

  MergedNumber? mergedContaining(int i) {
    for (final m in merged) {
      if (m.contains(i)) return m;
    }
    return null;
  }
}

class MessageNoiseScanner {
  final Set<String> _currencyKeys;
  final Set<String> _amountKeywordKeys;

  MessageNoiseScanner({
    Iterable<String> currencyWords = const [],
    Iterable<String> amountKeywords = const [],
  }) : _currencyKeys = {
         for (final w in currencyWords)
           for (final k in tt.tokensFromLine(w).map(tt.matchKey))
             if (k.isNotEmpty && !tt.tokenHasDigit(k)) k,
       },
       _amountKeywordKeys = {
         for (final w in amountKeywords)
           for (final k in tt.tokensFromLine(w).map(tt.matchKey))
             if (k.isNotEmpty) k,
       };

  List<LineNoise> scan(List<String> lines) => [
    for (final l in lines) scanLine(l),
  ];

  // ============ القواعد الثابتة ============

  static final RegExp _spacesRe = RegExp(r'\s+');
  static final RegExp _phoneEmojiRe = RegExp(
    '[\u{1F4DE}\u{260E}\u{1F4F1}\u{1F4F2}\u{2706}]',
    unicode: true,
  );
  static final RegExp _edgeJunkRe = RegExp(
    r'^[^0-9a-zA-Z\u0621-\u064A\u0660-\u0669+#%٪]+|[^0-9a-zA-Z\u0621-\u064A\u0660-\u0669%٪]+$',
  );
  static final RegExp _digitsAndSepsRe = RegExp(
    r'^[0-9][0-9\-./,()]*[0-9]$|^[0-9]$',
  );
  static final RegExp _allDigitsRe = RegExp(r'^[0-9]+$');
  static final RegExp _timeRe = RegExp(
    r'^([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?(am|pm|ص|م)?$',
    caseSensitive: false,
  );
  static final RegExp _date3Re = RegExp(
    r'^([0-9]{1,4})([/\-.])([0-9]{1,2})\2([0-9]{1,4})$',
  );
  static final RegExp _date2Re = RegExp(r'^([0-9]{1,2})/([0-9]{1,2})$');
  static final RegExp _latinRe = RegExp(r'[a-zA-Z]');
  static final RegExp _latinOnlyRe = RegExp(r'[^a-zA-Z]');
  static final RegExp _hyphenBetweenDigitsRe = RegExp(r'[0-9]-[0-9]');
  static final RegExp _emailRe = RegExp(r'\S+@\S+\.\S+');
  static final RegExp _domainRe = RegExp(
    r'\.(com|net|org|me|io|ly|info|app)(/|$)',
    caseSensitive: false,
  );

  /// رموز عملات لاتينية قد تلتصق بالمبلغ (100USD) — ليست أكوادًا
  static const Set<String> _currencyLatin = {
    'usd',
    'us',
    'eur',
    'euro',
    'try',
    'tl',
    'syp',
    'sp',
    'lbp',
    'sar',
    'aed',
    'iqd',
    'jod',
    'kwd',
    'qar',
    'egp',
    'gbp',
    'k',
    'm',
  };

  /// كلمات تسبق رقم مرجع/كود
  static const Set<String> _refWords = {
    'كود',
    'الكود',
    'رمز',
    'الرمز',
    'مرجع',
    'المرجع',
    'ref',
    'id',
    'code',
    'pin',
    'otp',
  };

  /// أسماء تأتي بعد «رقم» وتعني رقم مرجع لا هاتف
  static const Set<String> _refNounsAfterNumber = {
    'الحواله',
    'حواله',
    'الحوالات',
    'العمليه',
    'عمليه',
    'الاشعار',
    'اشعار',
    'الطلب',
    'طلب',
    'الوصل',
    'وصل',
    'الايصال',
    'ايصال',
    'الفاتوره',
    'فاتوره',
    'الحساب',
    'حساب',
    'البطاقه',
    'بطاقه',
    'الهويه',
    'هويه',
    'المرجع',
    'مرجع',
    'التحويل',
    'تحويل',
    'السند',
    'سند',
    'الكود',
    'كود',
  };

  static const Set<String> _dateWords = {'تاريخ', 'التاريخ', 'بتاريخ'};
  static const Set<String> _timeWords = {
    'الساعه',
    'ساعه',
    'بالساعه',
    'الوقت',
    'وقت',
  };

  /// أطوال أرقام الهواتف الدولية (مع مفتاح الدولة، بدون + أو 00)
  static const Map<String, int> _intlMaxLen = {
    '963': 12,
    '964': 13,
    '90': 12,
    '974': 11,
    '971': 12,
    '966': 12,
    '962': 12,
    '961': 11,
    '965': 11,
    '968': 11,
    '973': 11,
    '970': 12,
    '972': 12,
    '20': 12,
    '218': 12,
    '212': 12,
    '213': 12,
    '216': 11,
    '49': 14,
    '44': 12,
    '31': 11,
    '46': 12,
    '45': 10,
    '47': 10,
    '43': 13,
    '33': 11,
    '39': 13,
    '34': 11,
    '32': 11,
    '41': 11,
    '1': 11,
    '7': 11,
  };

  static int _maxIntlLen(String digitsNoPrefix) {
    for (final len in const [3, 2, 1]) {
      if (digitsNoPrefix.length < len) continue;
      final cc = digitsNoPrefix.substring(0, len);
      final max = _intlMaxLen[cc];
      if (max != null) return max;
    }
    return 15;
  }

  static String _ascii(String s) {
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x0660 && c <= 0x0669) {
        b.writeCharCode(0x30 + (c - 0x0660));
      } else if (c >= 0x06F0 && c <= 0x06F9) {
        b.writeCharCode(0x30 + (c - 0x06F0));
      } else {
        b.writeCharCode(c);
      }
    }
    return b.toString();
  }

  static String _core(String raw) {
    final s = _ascii(
      raw.trim(),
    ).replaceAll('\u066B', '.').replaceAll('\u066C', ',');
    return s.replaceAll(_edgeJunkRe, '');
  }

  static int _trailingZeros(String d) {
    var n = 0;
    for (int i = d.length - 1; i >= 0 && d[i] == '0'; i--) {
      n++;
    }
    return n;
  }

  static bool _isDate(String core) {
    final m3 = _date3Re.firstMatch(core);
    if (m3 != null) {
      final a = m3.group(1)!;
      final b = int.parse(m3.group(3)!);
      final c = m3.group(4)!;
      final sep = m3.group(2)!;
      if (a.length == 4) {
        // سنة/شهر/يوم
        final d = int.parse(c);
        return c.length <= 2 && b >= 1 && b <= 12 && d >= 1 && d <= 31;
      }
      if (a.length > 2) return false;
      if (c.length != 2 && c.length != 4) return false;
      final x = int.parse(a);
      if (x < 1 || b < 1) return false;
      // يوم/شهر/سنة أو شهر/يوم/سنة
      final ok = (x <= 31 && b <= 12) || (x <= 12 && b <= 31);
      if (!ok) return false;
      // مع النقطة نطلب سنة واضحة حتى لا نخلط مع الأرقام العشرية
      if (sep == '.' && c.length == 2 && x > 12 && b > 12) return false;
      return true;
    }
    final m2 = _date2Re.firstMatch(core);
    if (m2 != null) {
      final x = int.parse(m2.group(1)!);
      final y = int.parse(m2.group(2)!);
      if (x < 1 || y < 1) return false;
      return (x <= 31 && y <= 12) || (x <= 12 && y <= 31);
    }
    return false;
  }

  bool _isMoneyWordAt(List<String> tokens, int i) {
    if (i < 0 || i >= tokens.length) return false;
    final t = tokens[i];
    if (tt.containsCurrencySymbol(t)) return true;
    final k = tt.matchKey(t);
    if (k.isEmpty) return false;
    return _currencyKeys.contains(k) ||
        tt.amountUnitKeys.contains(k) ||
        _amountKeywordKeys.contains(k);
  }

  /// تصنيف توكن واحد بمعزل عن جيرانه
  NoiseMark? _classifySingle(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('http') ||
        lower.contains('www.') ||
        lower.contains('://') ||
        _emailRe.hasMatch(raw) ||
        _domainRe.hasMatch(lower)) {
      return const NoiseMark(NoiseKind.link);
    }

    final core = _core(raw);
    final d = tt.digitsOnly(raw);
    if (d.isEmpty) return null;

    if (raw.contains('%') || raw.contains('٪')) {
      return const NoiseMark(NoiseKind.percent);
    }
    if (raw.contains('#') || raw.contains('*')) {
      return const NoiseMark(NoiseKind.code);
    }

    final tm = _timeRe.firstMatch(core);
    if (tm != null) {
      final h = int.parse(tm.group(1)!);
      final m = int.parse(tm.group(2)!);
      if (h <= 24 && m <= 59) return const NoiseMark(NoiseKind.time);
    }

    if (_isDate(core)) return const NoiseMark(NoiseKind.date);

    // + مع 7–15 رقمًا
    if (core.startsWith('+')) {
      final rest = core.substring(1);
      if (d.length >= 7 && d.length <= 15 && _digitsAndSepsRe.hasMatch(rest)) {
        return const NoiseMark(NoiseKind.phone);
      }
      if (d.length > 15) return const NoiseMark(NoiseKind.longNumber);
    }

    final digitsWithSeps = _digitsAndSepsRe.hasMatch(core);

    if (digitsWithSeps && d.length >= 16) {
      return const NoiseMark(NoiseKind.longNumber);
    }

    // 00 + مفتاح دولي
    if (digitsWithSeps && d.startsWith('00') && d.length >= 10) {
      return d.length <= 15
          ? const NoiseMark(NoiseKind.phone)
          : const NoiseMark(NoiseKind.longNumber);
    }

    // يبدأ بصفر (وليس كسرًا عشريًا مثل 0.5): المبالغ لا تبدأ بصفر
    final isZeroDecimal = RegExp(r'^0[.,][0-9]+$').hasMatch(core);
    if (digitsWithSeps && d.startsWith('0') && !isZeroDecimal) {
      if (d.length >= 8) return const NoiseMark(NoiseKind.phone);
      if (d.length >= 4) return const NoiseMark(NoiseKind.code);
    }

    // أرقام بينها شرطات: 933-123-456
    if (digitsWithSeps && _hyphenBetweenDigitsRe.hasMatch(core)) {
      return d.length >= 7
          ? const NoiseMark(NoiseKind.phone)
          : const NoiseMark(NoiseKind.code);
    }

    // حروف لاتينية مع أرقام (TRX5521 ، A12B) — ما لم تكن رمز عملة ملزوقًا
    if (_latinRe.hasMatch(core)) {
      final letters = core.replaceAll(_latinOnlyRe, '').toLowerCase();
      if (!_currencyLatin.contains(letters)) {
        return const NoiseMark(NoiseKind.code);
      }
    }

    // أرقام متتالية بدون فواصل
    if (_allDigitsRe.hasMatch(core)) {
      if (d.length >= 13) return const NoiseMark(NoiseKind.longNumber);
      if (d.length >= 10 && _trailingZeros(d) < 5) {
        return const NoiseMark(NoiseKind.phone);
      }
      if (d.length >= 8 && _trailingZeros(d) <= 1) {
        return const NoiseMark(NoiseKind.phone, suspect: true);
      }
    }

    return null;
  }

  bool _isDigitGroup(String raw) {
    final c = _core(raw);
    return RegExp(r'^\+?[0-9]+$').hasMatch(c);
  }

  // ============ المسح ============

  LineNoise scanLine(String line) {
    final tokens = <String>[];
    final raw = <String>[];
    final phoneEmojiAt = <int>{};
    var pendingEmoji = false;

    for (final piece in line.split(_spacesRe)) {
      if (piece.isEmpty) continue;
      final cleaned = tt.cleanToken(piece);
      final hasEmoji = _phoneEmojiRe.hasMatch(piece);
      if (cleaned.isEmpty) {
        if (hasEmoji) pendingEmoji = true;
        continue;
      }
      if (pendingEmoji || hasEmoji) phoneEmojiAt.add(tokens.length);
      pendingEmoji = false;
      tokens.add(cleaned);
      raw.add(piece);
    }

    final marks = <int, NoiseMark>{};
    final merged = <MergedNumber>[];

    // 1) قواعد التوكن المفرد
    for (int i = 0; i < tokens.length; i++) {
      final m = _classifySingle(raw[i]);
      if (m != null) marks[i] = m;
    }

    // 2) سلاسل أرقام مفصولة بمسافات (تتقدّم على قواعد التوكن المفرد)
    int i = 0;
    while (i < tokens.length) {
      if (!_isDigitGroup(raw[i])) {
        i++;
        continue;
      }

      final first = _core(raw[i]);
      final d0 = tt.digitsOnly(first);
      final hasPlus = first.startsWith('+');
      final intl = hasPlus || d0.startsWith('00');
      final local = !intl && d0.startsWith('0');

      var j = i;
      while (j + 1 < tokens.length && _isDigitGroup(raw[j + 1])) {
        final nextCore = _core(raw[j + 1]);
        if (nextCore.startsWith('+')) break;
        // في سلسلة بلا مفتاح، الرقم الذي يبدأ بصفر (وليس مجموعة آلاف من 3
        // أرقام مثل 000 أو 050) هو بداية هاتف جديد
        if (!intl &&
            !local &&
            nextCore.startsWith('0') &&
            tt.digitsOnly(nextCore).length != 3) {
          break;
        }
        j++;
      }

      if (intl || local) {
        final noPrefix = hasPlus ? d0 : (intl ? d0.substring(2) : d0);
        final max = intl ? _maxIntlLen(noPrefix) : 11;
        var total = noPrefix.length;
        var k = i;
        while (k + 1 <= j) {
          final next = tt.digitsOnly(raw[k + 1]);
          if (total + next.length > max) break;
          // المجموعة المتبوعة بعملة/مقدار هي المبلغ وليست جزءًا من الهاتف
          if (_isMoneyWordAt(tokens, k + 2)) break;
          total += next.length;
          k++;
        }
        final minLen = intl ? 7 : 8;
        if (total >= minLen && k > i) {
          for (int x = i; x <= k; x++) {
            marks[x] = const NoiseMark(NoiseKind.phone);
          }
        }
        i = k + 1;
        continue;
      }

      if (j > i) {
        final groups = [for (int x = i; x <= j; x++) tt.digitsOnly(raw[x])];
        final total = groups.fold<int>(0, (a, g) => a + g.length);
        final thousands =
            groups.first.length <= 3 &&
            groups.skip(1).every((g) => g.length == 3);
        final followedByMoney = _isMoneyWordAt(tokens, j + 1);
        if (thousands &&
            (groups.last == '000' || (groups.length == 2 && followedByMoney))) {
          merged.add(MergedNumber(i, j, groups.join()));
          for (int x = i; x <= j; x++) {
            marks.remove(x);
          }
        } else if (total >= 8 &&
            groups.every((g) => g.length >= 2 && g.length <= 4)) {
          for (int x = i; x <= j; x++) {
            marks[x] = const NoiseMark(NoiseKind.phone);
          }
        }
      }
      i = j + 1;
    }

    // 3) إيموجي الهاتف قبل الرقم
    for (final idx in phoneEmojiAt) {
      if (idx < tokens.length && tt.tokenHasDigit(tokens[idx])) {
        marks[idx] = const NoiseMark(NoiseKind.phone);
        for (int x = idx + 1; x < tokens.length; x++) {
          if (!_isDigitGroup(raw[x]) || _isMoneyWordAt(tokens, x + 1)) break;
          marks[x] = const NoiseMark(NoiseKind.phone);
        }
      }
    }

    // 4) كلمات السياق: رقم/هاتف/جوال... ، كود/مرجع ، تاريخ ، الساعة
    final keys = tokens.map(tt.matchKey).toList();
    for (int w = 0; w < tokens.length; w++) {
      final k = keys[w];
      if (k.isEmpty || tt.tokenHasDigit(k)) continue;

      NoiseKind? kind;
      var reach = 4;
      var maxFillers = 2;
      if (tt.phoneWordKeys.contains(k)) {
        kind = NoiseKind.phone;
        // «رقم الحوالة/العملية/الطلب...» = رقم مرجع
        if ((k == 'رقم' || k == 'الرقم') &&
            w + 1 < tokens.length &&
            _refNounsAfterNumber.contains(keys[w + 1])) {
          kind = NoiseKind.code;
        }
      } else if (_refWords.contains(k)) {
        kind = NoiseKind.code;
        reach = 3;
        maxFillers = 1;
      } else if (_dateWords.contains(k)) {
        kind = NoiseKind.date;
        reach = 3;
        maxFillers = 0;
      } else if (_timeWords.contains(k)) {
        kind = NoiseKind.time;
        reach = 2;
        maxFillers = 0;
      }
      if (kind == null) continue;

      var fillers = 0;
      var foundDigits = false;
      var markedAny = false;
      for (int x = w + 1; x < tokens.length && x <= w + reach; x++) {
        if (_isMoneyWordAt(tokens, x)) break;
        final hasDigit = tt.tokenHasDigit(tokens[x]);
        if (!hasDigit) {
          if (foundDigits) break;
          if (tt.phoneWordKeys.contains(keys[x]) ||
              _refNounsAfterNumber.contains(keys[x])) {
            continue; // «رقم الهاتف» ، «رقم الحوالة»
          }
          fillers++;
          if (fillers > maxFillers) break;
          continue;
        }
        // مبلغ مدموج أو رقم متبوع بعملة: ليس هاتفًا
        if (merged.any((m) => m.contains(x))) break;
        if (_isMoneyWordAt(tokens, x + 1)) break;
        if (kind == NoiseKind.time) {
          final v = int.tryParse(tt.digitsOnly(tokens[x])) ?? 99;
          final existing = marks[x];
          if (v > 24 && existing?.kind != NoiseKind.time) break;
        }
        final existing = marks[x];
        if (existing == null || existing.suspect) {
          marks[x] = NoiseMark(kind);
        }
        foundDigits = true;
        markedAny = true;
      }
      if (markedAny || kind == NoiseKind.phone || kind == NoiseKind.code) {
        marks[w] = const NoiseMark(NoiseKind.context);
      }
    }

    return LineNoise(tokens: tokens, raw: raw, marks: marks, merged: merged);
  }
}
