// lib/services/detection/text_tokens.dart
// -------------------------------------------------------------
// أدوات تقسيم وتطبيع موحّدة تستخدمها شاشة الفقاعات وكاشف الاسم،
// حتى تكون فهارس التوكنات متطابقة تمامًا بين الواجهة والكاشف.
// (ملف Dart نقي بدون Flutter)
// -------------------------------------------------------------

final RegExp _diacriticsRe = RegExp(r'[\u064B-\u065F\u0670]');
final RegExp _disallowedCharsRe = RegExp(
  r'[^\u0600-\u06FFa-zA-Z0-9\$€£﷼₺٫\.,\-_\/\+]',
);
final RegExp _digitSepRe = RegExp(r'[.,،\-\_\u0640\u066B\u066C]');
final RegExp _spacesRe = RegExp(r'\s+');
final RegExp _edgePunctRe = RegExp(
  r'^[\s\.,،؛؟:;\-_/+!\u0640]+|[\s\.,،؛؟:;\-_/+!\u0640]+$',
);
final RegExp _hasDigitRe = RegExp(r'[0-9\u0660-\u0669]');
final RegExp _allDigitsRe = RegExp(r'^[0-9\u0660-\u0669]+$');

String stripDiacritics(String s) => s.replaceAll(_diacriticsRe, '');

/// تطبيع الحروف العربية المتشابهة (أ/إ/آ → ا ، ى/ئ → ي ، ؤ → و ، ة → ه)
String normalizeArabic(String s) {
  s = stripDiacritics(s);
  s = s.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
  s = s.replaceAll('ى', 'ي').replaceAll('ئ', 'ي').replaceAll('ؤ', 'و');
  s = s.replaceAll('ة', 'ه');
  return s.trim();
}

bool _isAsciiDigit(int code) => code >= 0x30 && code <= 0x39;
bool _isArabicDigit(int code) => code >= 0x0660 && code <= 0x0669;
bool _isDigitCode(int code) => _isAsciiDigit(code) || _isArabicDigit(code);

/// هل الفاصل الواقع عند [i] (بين رقمين) فاصل تجميع يجب حذفه؟
/// - الشرطة/الشرطة السفلية/التطويل وفاصل الآلاف العربي: تُحذف دائمًا.
/// - الفاصلة العشرية العربية (٫): تبقى دائمًا.
/// - النقطة والفاصلة: تُحذف فقط إذا تبعتها 3 أرقام بالضبط (1,500 أو 1.500.000)،
///   وإلا فهي فاصلة عشرية (1.5 أو 12,50) وتبقى.
bool _isGroupingSeparatorAt(String w, int i) {
  final ch = w[i];
  if (ch == '\u066B') return false;
  if (ch == '.' || ch == ',' || ch == '،') {
    var n = 0;
    var j = i + 1;
    while (j < w.length && _isDigitCode(w.codeUnitAt(j))) {
      n++;
      j++;
    }
    return n == 3;
  }
  return true;
}

/// يحذف فواصل الآلاف الواقعة بين رقمين (1,500 → 1500) مع إبقاء الفاصلة
/// العشرية (1.5 تبقى 1.5).
String squashDigitSeparators(String w) {
  if (w.isEmpty) return w;
  final out = StringBuffer();
  for (int i = 0; i < w.length; i++) {
    final ch = w[i];
    if (_digitSepRe.hasMatch(ch)) {
      final prev = (i > 0) ? w.codeUnitAt(i - 1) : null;
      final next = (i + 1 < w.length) ? w.codeUnitAt(i + 1) : null;
      if (prev != null &&
          next != null &&
          _isDigitCode(prev) &&
          _isDigitCode(next) &&
          _isGroupingSeparatorAt(w, i)) {
        continue;
      }
    }
    out.write(ch);
  }
  return out.toString();
}

/// تنظيف توكن واحد كما يظهر في الفقاعات
String cleanToken(String w) {
  final trimmed = w.replaceAll(_disallowedCharsRe, '').trim();
  return squashDigitSeparators(trimmed);
}

/// تقسيم سطر إلى توكنات (هذه الفهارس هي المرجع في كل الشاشة)
List<String> tokensFromLine(String line) =>
    line.split(_spacesRe).map(cleanToken).where((w) => w.isNotEmpty).toList();

/// مفتاح مقارنة موحّد لتوكن: تطبيع عربي + أحرف صغيرة + حذف علامات الترقيم
/// من الأطراف (الرموز مثل $ و € تبقى كما هي).
String matchKey(String token) {
  var s = normalizeArabic(token).toLowerCase();
  if (s.isEmpty) return s;
  s = s.replaceAll(_edgePunctRe, '');
  return s;
}

/// مفتاح مقارنة لنص كامل (اسم/جملة)
String normalizeText(String s) =>
    tokensFromLine(s).map(matchKey).where((e) => e.isNotEmpty).join(' ');

/// نص التوكن للعرض بدون علامات الترقيم في الأطراف (بدون تطبيع الحروف)
String stripEdgePunct(String token) {
  final s = token.replaceAll(_edgePunctRe, '');
  return s.isEmpty ? token.trim() : s;
}

bool tokenHasDigit(String token) => _hasDigitRe.hasMatch(token);

bool isAllDigits(String token) => _allDigitsRe.hasMatch(token);

String digitsOnly(String s) {
  final b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (_isAsciiDigit(c)) {
      b.writeCharCode(c);
    } else if (_isArabicDigit(c)) {
      b.writeCharCode(0x30 + (c - 0x0660));
    }
  }
  return b.toString();
}

/// رقم يبدو هاتفًا: 9 إلى 14 رقمًا ويبدأ بـ + أو 0
bool isPhoneLike(String token) {
  final raw = token.trim();
  final d = digitsOnly(raw);
  if (d.length < 9 || d.length > 14) return false;
  if (raw.startsWith('+')) return true;
  return d.startsWith('0');
}

const Set<String> phoneWordKeys = {
  'هاتف',
  'الهاتف',
  'هاتفه',
  'هاتفها',
  'جوال',
  'الجوال',
  'جواله',
  'جوالها',
  'واتس',
  'الواتس',
  'واتساب',
  'الواتساب',
  'whatsapp',
  'whats',
  'موبايل',
  'الموبايل',
  'موبايله',
  'موبايلها',
  'تلفون',
  'التلفون',
  'تلفونه',
  'تليفون',
  'التليفون',
  'رقم',
  'الرقم',
  'رقمه',
  'رقمها',
  'نمره',
  'النمره',
  'نمرته',
  'للتواصل',
  'phone',
  'mobile',
  'tel',
};

const Set<String> amountUnitKeys = {
  'الف',
  'الاف',
  'مليون',
  'ملايين',
  'مليار',
  'مليارات',
};

bool containsCurrencySymbol(String token) =>
    token.contains('\$') ||
    token.contains('€') ||
    token.contains('£') ||
    token.contains('﷼') ||
    token.contains('₺');

/// مجموعة عبارات (كلمة واحدة أو عدة كلمات) مع مطابقة على مستوى التوكنات.
class PhraseSet {
  final Set<String> _singles = <String>{};
  final Map<String, List<List<String>>> _multiByFirst = {};
  final Map<String, List<List<String>>> _multiByLast = {};
  final List<String> _originals = [];
  final Map<String, String> _originalByKey = {};

  PhraseSet(Iterable<String> entries) {
    for (final raw in entries) {
      final keys = tokensFromLine(
        raw,
      ).map(matchKey).where((e) => e.isNotEmpty).toList();
      if (keys.isEmpty) continue;
      _originals.add(raw.trim());
      _originalByKey[keys.join(' ')] = raw.trim();
      if (keys.length == 1) {
        _singles.add(keys.first);
      } else {
        (_multiByFirst[keys.first] ??= []).add(keys);
        (_multiByLast[keys.last] ??= []).add(keys);
      }
    }
    for (final list in _multiByFirst.values) {
      list.sort((a, b) => b.length.compareTo(a.length));
    }
    for (final list in _multiByLast.values) {
      list.sort((a, b) => b.length.compareTo(a.length));
    }
  }

  bool get isEmpty => _singles.isEmpty && _multiByFirst.isEmpty;
  bool get isNotEmpty => !isEmpty;
  List<String> get originals => List.unmodifiable(_originals);

  bool containsKey(String key) => _singles.contains(key);

  /// طول أطول عبارة تبدأ عند [i] (0 إن لم توجد)
  int matchAt(List<String> keys, int i) {
    if (i < 0 || i >= keys.length) return 0;
    final multis = _multiByFirst[keys[i]];
    if (multis != null) {
      for (final seq in multis) {
        if (i + seq.length > keys.length) continue;
        var ok = true;
        for (int j = 1; j < seq.length; j++) {
          if (keys[i + j] != seq[j]) {
            ok = false;
            break;
          }
        }
        if (ok) return seq.length;
      }
    }
    return _singles.contains(keys[i]) ? 1 : 0;
  }

  /// طول أطول عبارة تنتهي عند [end] (0 إن لم توجد)
  int matchEndingAt(List<String> keys, int end) {
    if (end < 0 || end >= keys.length) return 0;
    final multis = _multiByLast[keys[end]];
    if (multis != null) {
      for (final seq in multis) {
        final start = end - seq.length + 1;
        if (start < 0) continue;
        var ok = true;
        for (int j = 0; j < seq.length - 1; j++) {
          if (keys[start + j] != seq[j]) {
            ok = false;
            break;
          }
        }
        if (ok) return seq.length;
      }
    }
    return _singles.contains(keys[end]) ? 1 : 0;
  }

  /// كل المطابقات داخل سطر: قائمة (بداية، طول، النص الأصلي)
  List<PhraseHit> findAll(List<String> keys, {int lineIndex = 0}) {
    final hits = <PhraseHit>[];
    int i = 0;
    while (i < keys.length) {
      final len = matchAt(keys, i);
      if (len > 0) {
        final k = keys.sublist(i, i + len).join(' ');
        hits.add(
          PhraseHit(
            lineIndex: lineIndex,
            start: i,
            length: len,
            phrase: _originalByKey[k] ?? k,
          ),
        );
        i += len;
      } else {
        i++;
      }
    }
    return hits;
  }
}

class PhraseHit {
  final int lineIndex;
  final int start;
  final int length;
  final String phrase;

  const PhraseHit({
    required this.lineIndex,
    required this.start,
    required this.length,
    required this.phrase,
  });

  int get end => start + length; // exclusive
}
