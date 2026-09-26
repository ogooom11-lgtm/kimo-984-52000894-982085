// lib/services/detection/currency_detector.dart
// -------------------------------------------------------------
// المرحلة 2 من خط المعالجة:
// 1) استقبال النص المنظّف بعد مرحلة الاسم
// 2) كشف العملة اعتمادًا على currencyMap من الإعدادات
// 3) حذف العملة من النص الممرَّر للمرحلة التالية
// 4) الإبقاء على موضع العملة الأصلي لعرض التحديد في bubble_screen
//
// ملاحظة:
// - أبقينا detect(lines: ...) القديمة للتوافق المؤقت مع bubble_screen الحالي.
// - أضفنا detectPrepared(...) للمسار الجديد.
// -------------------------------------------------------------

import 'dart:math' show Point;

/// توكن جاهز للتمرير بين المراحل مع حفظ الموضع الأصلي
class PreparedToken {
  final String token;
  final Point<int> originalPos;

  const PreparedToken({
    required this.token,
    required this.originalPos,
  });

  PreparedToken copyWith({
    String? token,
    Point<int>? originalPos,
  }) {
    return PreparedToken(
      token: token ?? this.token,
      originalPos: originalPos ?? this.originalPos,
    );
  }
}

/// نتيجة كشف العملة
class CurrencyDetectResult {
  /// موضع العملة في النص الأصلي
  final Point<int>? pos;

  /// alias أو المفتاح المرجّح إن أمكن
  final String? detectedKey;

  /// الاسم النهائي للعرض/التخزين
  final String? detectedDisplayName;

  /// اقتراحات تعلّم (رموز)
  final Set<String> suggestSymbols;

  /// اقتراحات تعلّم (أسماء)
  final Set<String> suggestNames;

  /// الثقة
  final double confidence;

  /// النص المتبقي بعد حذف العملة أو نزعها من التوكن الملزوق
  final List<List<PreparedToken>> remainingTokensByLine;

  /// مواقع كل كلمات العملة المختارة: «ليرة سورية» = موقعان يبدآن بـ [pos]
  final List<Point<int>> positions;

  /// كل العملات المختلفة الموجودة في النص بالترتيب، باسمها المعروض ومن دون
  /// تكرار ($ و دولار عملة واحدة إن كان اسمهما في الإعدادات واحدًا)
  final List<String> currencyNames;

  const CurrencyDetectResult({
    required this.pos,
    required this.detectedKey,
    required this.detectedDisplayName,
    required this.suggestSymbols,
    required this.suggestNames,
    required this.confidence,
    required this.remainingTokensByLine,
    this.positions = const [],
    this.currencyNames = const [],
  });

  bool get hasCurrency => detectedDisplayName != null && detectedDisplayName!.trim().isNotEmpty;

  /// في النص أكثر من عملة مختلفة
  bool get hasMultipleCurrencies => currencyNames.length >= 2;

  List<String> get remainingLines =>
      remainingTokensByLine.map((row) => row.map((e) => e.token).join(' ')).toList();
}

// ===== أدوات مساعدة عامة =====

String _stripDiacritics(String s) =>
    s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');

String _normalizeArabic(String s) {
  s = _stripDiacritics(s);
  s = s.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
  s = s.replaceAll('ى', 'ي').replaceAll('ئ', 'ي').replaceAll('ؤ', 'و');
  s = s.replaceAll('ة', 'ه');
  return s.trim();
}

String _cleanToken(String w) =>
    _normalizeArabic(
      w.replaceAll(RegExp(r'[^\u0600-\u06FFA-Za-z0-9\$€£﷼₺._\-]'), ''),
    ).trim();

List<String> _tokensFromLine(String line) => line
    .split(RegExp(r'\s+'))
    .map(_cleanToken)
    .where((w) => w.isNotEmpty)
    .toList();

/// مفتاح مقارنة موحّد للعملات: بدون مسافات ولا رموز زائدة، حروف عربية موحّدة
/// وحروف لاتينية كبيرة. «ليرة سورية» = «ليره سوريه» = «ليرةسورية».
String _currencyKey(String s) => _cleanToken(s).toUpperCase();

/// أطول عملة نبحث عنها بعدد الكلمات («دولار امريكي صافي»)
const int _maxPhraseWords = 3;

bool _hasDigits(String s) => RegExp(r'[0-9\u0660-\u0669]').hasMatch(s);

bool _isAsciiCurrencySymbol(String tok) =>
    RegExp(r'^[A-Z]{2,4}$').hasMatch(tok) ||
        RegExp(r'^[\$\€\£\﷼\₺]+$').hasMatch(tok);

List<List<PreparedToken>> _clonePrepared(List<List<PreparedToken>> rows) =>
    rows.map((r) => r.map((e) => e.copyWith()).toList()).toList();

// ===== عائلات العملات =====
// نستخدمها فقط للمطابقة الذكية حين تختلف الـ aliases بين الإعدادات والرسالة.

const Map<String, Set<String>> _currencyFamilies = {
  'USD': {
    'USD', r'$', 'دولار', 'دولارات', 'دولارصافي', 'دولارامريكي', 'دولارأمريكي'
  },
  'EUR': {
    'EUR', '€', 'يورو'
  },
  'SYP': {
    'SYP', 'سوري', 'سورية', 'سوريه', 'ل.س', 'لس', 'ل س', 'ليرةسورية', 'ليرهسوريه', 'ليرة سورية'
  },
};

const Map<String, String> _defaultFamilyDisplay = {
  'USD': 'دولار',
  'EUR': 'يورو',
  'SYP': 'ليرة سورية',
};

final Map<String, String> _familyByKey = {
  for (final e in _currencyFamilies.entries)
    for (final raw in e.value) _currencyKey(raw): e.key,
};

String? _familyOf(String token) => _familyByKey[_currencyKey(token)];

class _ResolvedCurrency {
  final String? key;
  final String displayName;
  final String? family;
  final double score;

  const _ResolvedCurrency({
    required this.key,
    required this.displayName,
    required this.family,
    required this.score,
  });
}

/// فهرس عملات الإعدادات: يُبنى مرة لكل عملية كشف، والمقارنة بمفتاح بدون
/// مسافات، فالعملة المكتوبة بكلمتين («ليرة سورية») تطابق كلمتيها في الرسالة.
class _CurrencyIndex {
  final Map<String, MapEntry<String, String>> _byAlias = {};
  final Map<String, MapEntry<String, String>> _byName = {};
  final Map<String, MapEntry<String, String>> _byFamily = {};

  _CurrencyIndex(Map<String, String> currencyMap) {
    for (final e in currencyMap.entries) {
      final aliasKey = _currencyKey(e.key);
      if (aliasKey.isNotEmpty) _byAlias.putIfAbsent(aliasKey, () => e);
      final nameKey = _currencyKey(e.value);
      if (nameKey.isNotEmpty) _byName.putIfAbsent(nameKey, () => e);
      final fam = _familyOf(e.key) ?? _familyOf(e.value);
      if (fam != null) _byFamily.putIfAbsent(fam, () => e);
    }
  }

  _ResolvedCurrency? resolve(String token) => resolveKey(_currencyKey(token));

  /// [key] من [_currencyKey] (أو مفاتيح عدة كلمات ملصوقة ببعضها)
  _ResolvedCurrency? resolveKey(String key) {
    if (key.isEmpty) return null;

    // 1) تطابق exact مع aliases
    final alias = _byAlias[key];
    if (alias != null) return _fromEntry(alias, 1.0);

    // 2) تطابق exact مع display names
    final name = _byName[key];
    if (name != null) return _fromEntry(name, 0.99);

    // 3) تطابق عبر family
    final fam = _familyByKey[key];
    if (fam == null) return null;
    final entry = _byFamily[fam];
    if (entry != null) return _fromEntry(entry, 0.95, family: fam);

    // لو لم نجد ضمن الإعدادات، نعيد اسمًا افتراضيًا للاقتراح
    return _ResolvedCurrency(
      key: fam,
      displayName: _defaultFamilyDisplay[fam] ?? key,
      family: fam,
      score: 0.75,
    );
  }

  static _ResolvedCurrency _fromEntry(
      MapEntry<String, String> e,
      double score, {
        String? family,
      }) {
    return _ResolvedCurrency(
      key: e.key,
      displayName: e.value,
      family: family ?? _familyOf(e.key) ?? _familyOf(e.value),
      score: score,
    );
  }
}

bool _looksLikeCurrencyToken(String token) {
  if (token.isEmpty) return false;
  if (_familyOf(token) != null) return true;

  final t = _cleanToken(token);
  if (t.isEmpty) return false;

  return RegExp(
    r'^(USD|EUR|SYP|'
    r'₺|﷼|\$|€|£|'
    r'دولار|دولارات|'
    r'يورو|'
    r'سوري|سورية|سوريه|ل\.س|لس)$',
    caseSensitive: false,
  ).hasMatch(t);
}

class _StickyMatch {
  final _ResolvedCurrency resolved;
  final String numericPart;

  /// عدد الكلمات بعد التوكن الملزوق التي تكمل اسم العملة («10000ليرة سورية»)
  final int extraTokens;

  const _StickyMatch({
    required this.resolved,
    required this.numericPart,
    this.extraTokens = 0,
  });
}
String _amountCorePattern() {
  return
    r'[0-9\u0660-\u0669][0-9\u0660-\u0669,.\u066B\u066C]*'
    r'(?:'
    r'(?:الف|الاف|ألف|آلاف|مليون|ملايين|مليار|مليارات|طن|طون)'
    r')?';
}
_StickyMatch? _splitStickyCurrencyToken(
    String token,
    _CurrencyIndex index, {
      String? nextKey,
    }) {
  final t = _cleanToken(token);
  if (t.isEmpty) return null;

  final amountCore = _amountCorePattern();

  // prefix currency + number(+magnitude)
  // أمثلة:
  // $2000
  // $250الف
  // دولار1000
  // USD3مليون
  final prefix = RegExp(
    '^([\\u0600-\\u06FFA-Za-z\\\$€£﷼₺\\.]+)($amountCore)\$',
    unicode: true,
  ).firstMatch(t);

  if (prefix != null) {
    final cur = prefix.group(1)!;
    final num = prefix.group(2)!;
    final resolved = index.resolve(cur);
    if (resolved != null) {
      return _StickyMatch(
        resolved: resolved,
        numericPart: num,
      );
    }
  }

  // number(+magnitude) + suffix currency
  // أمثلة:
  // 2000$
  // 190000سوري
  // 250الف$
  // 3مليون$
  // 150طن$
  final suffix = RegExp(
    '^($amountCore)([\\u0600-\\u06FFA-Za-z\\\$€£﷼₺\\.]+)\$',
    unicode: true,
  ).firstMatch(t);

  if (suffix != null) {
    final num = suffix.group(1)!;
    final cur = suffix.group(2)!;

    // «10000ليرة» ثم «سورية»: العملة من كلمتين والرقم ملزوق بأولاهما
    if (nextKey != null && nextKey.isNotEmpty) {
      final joined = index.resolveKey(_currencyKey(cur) + nextKey);
      if (joined != null) {
        return _StickyMatch(
          resolved: joined,
          numericPart: num,
          extraTokens: 1,
        );
      }
    }

    final resolved = index.resolve(cur);
    if (resolved != null) {
      return _StickyMatch(
        resolved: resolved,
        numericPart: num,
      );
    }
  }

  return null;
}

class _CurrencyCandidate {
  final Point<int> originalPos;
  final int lineIndex;
  final int startTokenIndex;
  final int endTokenIndex;
  final String? replacementForStart;
  final _ResolvedCurrency resolved;
  final double score;

  const _CurrencyCandidate({
    required this.originalPos,
    required this.lineIndex,
    required this.startTokenIndex,
    required this.endTokenIndex,
    required this.replacementForStart,
    required this.resolved,
    required this.score,
  });
}

List<List<PreparedToken>> _applyCandidateRemoval(
    List<List<PreparedToken>> source,
    _CurrencyCandidate? candidate,
    ) {
  final cloned = _clonePrepared(source);
  if (candidate == null) return cloned;

  final li = candidate.lineIndex;
  if (li < 0 || li >= cloned.length) return cloned;

  final row = cloned[li];
  final out = <PreparedToken>[];

  for (int i = 0; i < row.length; i++) {
    final item = row[i];

    if (i < candidate.startTokenIndex || i > candidate.endTokenIndex) {
      out.add(item);
      continue;
    }

    if (i == candidate.startTokenIndex &&
        candidate.replacementForStart != null &&
        candidate.replacementForStart!.trim().isNotEmpty) {
      out.add(
        item.copyWith(token: candidate.replacementForStart!.trim()),
      );
    }
  }

  cloned[li] = out;
  return cloned;
}

class CurrencyDetector {
  /// الواجهة القديمة للتوافق المؤقت مع bubble_screen الحالي
  static CurrencyDetectResult detect({
    required List<String> lines,
    required Map<String, String> currencyMap,
    List<String> ignoredWords = const [],
  }) {
    final prepared = <List<PreparedToken>>[];

    for (int li = 0; li < lines.length; li++) {
      final toks = _tokensFromLine(lines[li]);
      prepared.add([
        for (int ti = 0; ti < toks.length; ti++)
          PreparedToken(
            token: toks[ti],
            originalPos: Point(li, ti),
          ),
      ]);
    }

    return detectPrepared(
      preparedTokensByLine: prepared,
      currencyMap: currencyMap,
      ignoredWords: ignoredWords,
    );
  }

  /// الواجهة الجديدة للمسار الصحيح:
  /// تستقبل النص الناتج من name_detector / أو أي مرحلة سابقة
  static CurrencyDetectResult detectPrepared({
    required List<List<PreparedToken>> preparedTokensByLine,
    required Map<String, String> currencyMap,
    List<String> ignoredWords = const [],
  }) {
    final sym = <String>{};
    final names = <String>{};
    final ignoredSet = ignoredWords
        .map(_cleanToken)
        .where((e) => e.isNotEmpty)
        .toSet();
    final index = _CurrencyIndex(currencyMap);

    _CurrencyCandidate? best;
    // كل العملات المختلفة بالترتيب: مفتاح الاسم المعروض ← الاسم المعروض
    final found = <String, String>{};

    void registerCandidate(_CurrencyCandidate c) {
      final display = c.resolved.displayName.trim();
      found.putIfAbsent(_currencyKey(display), () => display);
      if (best == null || c.score > best!.score) {
        best = c;
      }
    }

    for (int li = 0; li < preparedTokensByLine.length; li++) {
      final row = preparedTokensByLine[li];
      if (row.isEmpty) continue;

      // مفتاح كل كلمة مرة واحدة (فارغ = كلمة لا تدخل في العملة)
      final keys = <String>[
        for (final p in row) _scanKey(p.token, ignoredSet),
      ];

      for (int ti = 0; ti < row.length; ti++) {
        if (keys[ti].isEmpty) continue;
        final cleanedTok = _cleanToken(row[ti].token.trim());

        // 1) أطول عبارة أولًا: «ليرة سورية» عملة واحدة، ولا تُقرأ «ليرة» وحدها
        //    (قد تكون «ليرة» وحدها معرّفة لعملة أخرى مثل الليرة التركية)
        final phrase = _phraseAt(keys, ti, index);
        if (phrase != null) {
          final text = [
            for (int k = ti; k < ti + phrase.words; k++) row[k].token.trim(),
          ].join(' ');
          final fam = phrase.resolved.family;
          if (fam != null) sym.add(fam);
          names.add(text);

          registerCandidate(
            _CurrencyCandidate(
              originalPos: row[ti].originalPos,
              lineIndex: li,
              startTokenIndex: ti,
              endTokenIndex: ti + phrase.words - 1,
              replacementForStart: null,
              resolved: phrase.resolved,
              score: phrase.resolved.score,
            ),
          );
          ti += phrase.words - 1;
          continue;
        }

        // 2) exact token
        final exact = index.resolveKey(keys[ti]);
        if (exact != null) {
          if (_isAsciiCurrencySymbol(cleanedTok)) {
            sym.add(cleanedTok.toUpperCase());
          } else {
            names.add(cleanedTok);
          }

          registerCandidate(
            _CurrencyCandidate(
              originalPos: row[ti].originalPos,
              lineIndex: li,
              startTokenIndex: ti,
              endTokenIndex: ti,
              replacementForStart: null,
              resolved: exact,
              score: exact.score,
            ),
          );
          continue;
        }

        // 3) sticky token مثل 2000$ أو 190000سوري أو $2000 أو 10000ليرة سورية
        final sticky = _splitStickyCurrencyToken(
          cleanedTok,
          index,
          nextKey: ti + 1 < row.length ? keys[ti + 1] : null,
        );
        if (sticky != null) {
          final fam = sticky.resolved.family;
          if (fam != null) {
            sym.add(fam);
          } else if (_isAsciiCurrencySymbol(cleanedTok)) {
            sym.add(cleanedTok.toUpperCase());
          } else {
            names.add(cleanedTok);
          }

          registerCandidate(
            _CurrencyCandidate(
              originalPos: row[ti].originalPos,
              lineIndex: li,
              startTokenIndex: ti,
              endTokenIndex: ti + sticky.extraTokens,
              replacementForStart: sticky.numericPart,
              resolved: sticky.resolved,
              score: sticky.resolved.score + 0.01,
            ),
          );
          ti += sticky.extraTokens;
          continue;
        }

        // 4) اقتراحات لو بدا التوكن كعملة لكنه غير مضاف بشكل واضح في الإعدادات
        if (_looksLikeCurrencyToken(cleanedTok)) {
          final fam = _familyOf(cleanedTok);
          if (fam != null) {
            sym.add(fam);
            names.add(_defaultFamilyDisplay[fam] ?? cleanedTok);
          } else {
            if (_isAsciiCurrencySymbol(cleanedTok)) {
              sym.add(cleanedTok.toUpperCase());
            } else {
              names.add(cleanedTok);
            }
          }
        }
      }
    }

    final chosen = best;
    final remaining = _applyCandidateRemoval(preparedTokensByLine, chosen);
    final conf = chosen?.score ?? ((sym.isNotEmpty || names.isNotEmpty) ? 0.6 : 0.0);

    final positions = <Point<int>>[];
    if (chosen != null) {
      final row = preparedTokensByLine[chosen.lineIndex];
      for (int k = chosen.startTokenIndex;
          k <= chosen.endTokenIndex && k < row.length;
          k++) {
        positions.add(row[k].originalPos);
      }
    }

    return CurrencyDetectResult(
      pos: chosen?.originalPos,
      detectedKey: chosen?.resolved.key,
      detectedDisplayName: chosen?.resolved.displayName,
      suggestSymbols: sym,
      suggestNames: names,
      confidence: conf,
      remainingTokensByLine: remaining,
      positions: positions,
      currencyNames: found.values.toList(),
    );
  }

  /// عملة (من كلمة أو أكثر) تشمل الكلمة [index] في [tokens]، أو null.
  /// تُستخدم عند الضغط على كلمة لاختيار العملة يدويًا، ولمعرفة إن كان السطر
  /// ينتهي بعملة. الأطول أولًا: «ليرة سورية» قبل «ليرة».
  static CurrencyPhraseMatch? phraseAt({
    required List<String> tokens,
    required int index,
    required Map<String, String> currencyMap,
    List<String> ignoredWords = const [],
  }) {
    if (index < 0 || index >= tokens.length) return null;
    final ignoredSet = ignoredWords
        .map(_cleanToken)
        .where((e) => e.isNotEmpty)
        .toSet();
    final keys = [for (final t in tokens) _scanKey(t, ignoredSet)];
    if (keys[index].isEmpty) return null;
    final idx = _CurrencyIndex(currencyMap);

    for (int len = _maxPhraseWords; len >= 1; len--) {
      for (int start = index - len + 1; start <= index; start++) {
        if (start < 0 || start + len > keys.length) continue;
        final parts = keys.sublist(start, start + len);
        if (parts.any((k) => k.isEmpty)) continue;
        final r = idx.resolveKey(parts.join());
        if (r == null) continue;
        return CurrencyPhraseMatch(
          start: start,
          end: start + len - 1,
          key: r.key,
          displayName: r.displayName,
          inSettings: r.score > 0.9,
        );
      }
    }
    return null;
  }
}

/// نتيجة [CurrencyDetector.phraseAt]: كلمات العملة من [start] إلى [end]
class CurrencyPhraseMatch {
  final int start;
  final int end;
  final String? key;
  final String displayName;

  /// العملة معرّفة في الإعدادات (وليست من العائلات الافتراضية فقط)
  final bool inSettings;

  const CurrencyPhraseMatch({
    required this.start,
    required this.end,
    required this.key,
    required this.displayName,
    required this.inSettings,
  });
}

/// مفتاح كلمة لفحص العملات، أو '' إن كانت فارغة أو متجاهلة
String _scanKey(String token, Set<String> ignoredSet) {
  final c = _cleanToken(token.trim());
  if (c.isEmpty || ignoredSet.contains(c)) return '';
  return c.toUpperCase();
}

/// عملة من كلمتين أو أكثر تبدأ عند [start] (الأطول أولًا)، أو null
({_ResolvedCurrency resolved, int words})? _phraseAt(
    List<String> keys,
    int start,
    _CurrencyIndex index,
    ) {
  for (int len = _maxPhraseWords; len >= 2; len--) {
    if (start + len > keys.length) continue;
    final parts = keys.sublist(start, start + len);
    if (parts.any((k) => k.isEmpty)) continue;
    final r = index.resolveKey(parts.join());
    if (r != null) return (resolved: r, words: len);
  }
  return null;
}

/// عائلة العملة (USD / EUR / SYP) لرمز أو اسم عملة، أو null إن لم تُعرف.
/// تُستخدم لاعتبار الرموز المترادفة ($ / USD / دولار) عملة واحدة.
String? currencyFamilyOf(String token) => _familyOf(token);