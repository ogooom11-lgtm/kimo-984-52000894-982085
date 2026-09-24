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

  const CurrencyDetectResult({
    required this.pos,
    required this.detectedKey,
    required this.detectedDisplayName,
    required this.suggestSymbols,
    required this.suggestNames,
    required this.confidence,
    required this.remainingTokensByLine,
  });

  bool get hasCurrency => detectedDisplayName != null && detectedDisplayName!.trim().isNotEmpty;

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

String _normExact(String s) =>
    _normalizeArabic(s).replaceAll(RegExp(r'\s+'), ' ').trim();

String _normNoSpace(String s) =>
    _normExact(s).replaceAll(RegExp(r'\s+'), '');

bool _sameNorm(String a, String b) => _normExact(a) == _normExact(b);

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

String? _familyOf(String token) {
  final noSpace = _normNoSpace(token);
  final upperNoSpace = noSpace.toUpperCase();

  for (final e in _currencyFamilies.entries) {
    for (final raw in e.value) {
      final familyTok = _normNoSpace(raw);
      if (familyTok == noSpace || familyTok.toUpperCase() == upperNoSpace) {
        return e.key;
      }
    }
  }
  return null;
}

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

_ResolvedCurrency? _resolveCurrencyToken(
    String token,
    Map<String, String> currencyMap,
    ) {
  final cleaned = _cleanToken(token);
  if (cleaned.isEmpty) return null;

  // 1) تطابق exact مع aliases
  for (final e in currencyMap.entries) {
    if (_sameNorm(cleaned, e.key)) {
      return _ResolvedCurrency(
        key: e.key,
        displayName: e.value,
        family: _familyOf(e.key) ?? _familyOf(e.value),
        score: 1.0,
      );
    }
  }

  // 2) تطابق exact مع display names
  for (final e in currencyMap.entries) {
    if (_sameNorm(cleaned, e.value)) {
      return _ResolvedCurrency(
        key: e.key,
        displayName: e.value,
        family: _familyOf(e.key) ?? _familyOf(e.value),
        score: 0.99,
      );
    }
  }

  // 3) تطابق عبر family
  final fam = _familyOf(cleaned);
  if (fam != null) {
    for (final e in currencyMap.entries) {
      final entryFam = _familyOf(e.key) ?? _familyOf(e.value);
      if (entryFam == fam) {
        return _ResolvedCurrency(
          key: e.key,
          displayName: e.value,
          family: fam,
          score: 0.95,
        );
      }
    }

    // لو لم نجد ضمن الإعدادات، نعيد اسمًا افتراضيًا للاقتراح
    return _ResolvedCurrency(
      key: fam,
      displayName: _defaultFamilyDisplay[fam] ?? cleaned,
      family: fam,
      score: 0.75,
    );
  }

  return null;
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

  const _StickyMatch({
    required this.resolved,
    required this.numericPart,
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
    Map<String, String> currencyMap,
    ) {
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
    final resolved = _resolveCurrencyToken(cur, currencyMap);
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
    final resolved = _resolveCurrencyToken(cur, currencyMap);
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

    _CurrencyCandidate? best;

    void registerCandidate(_CurrencyCandidate c) {
      if (best == null || c.score > best!.score) {
        best = c;
      }
    }

    for (int li = 0; li < preparedTokensByLine.length; li++) {
      final row = preparedTokensByLine[li];
      if (row.isEmpty) continue;

      for (int ti = 0; ti < row.length; ti++) {
        final tok = row[ti].token.trim();
        if (tok.isEmpty) continue;

        final cleanedTok = _cleanToken(tok);
        if (cleanedTok.isEmpty) continue;
        if (ignoredSet.contains(cleanedTok)) continue;

        // 1) exact token
        final exact = _resolveCurrencyToken(cleanedTok, currencyMap);
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

        // 2) sticky token مثل 2000$ أو 190000سوري أو $2000
        final sticky = _splitStickyCurrencyToken(cleanedTok, currencyMap);
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
              endTokenIndex: ti,
              replacementForStart: sticky.numericPart,
              resolved: sticky.resolved,
              score: sticky.resolved.score + 0.01,
            ),
          );
          continue;
        }

        // 3) عملة من كلمتين: "ليرة سورية" / "ريال قطري" / "ل س"
        if (ti + 1 < row.length) {
          final t1 = row[ti].token.trim();
          final t2 = row[ti + 1].token.trim();
          if (t1.isNotEmpty && t2.isNotEmpty) {
            final fusedSpace = '$t1 $t2';
            final resolved2 = _resolveCurrencyToken(fusedSpace, currencyMap);

            if (resolved2 != null) {
              names.add(fusedSpace);

              registerCandidate(
                _CurrencyCandidate(
                  originalPos: row[ti].originalPos,
                  lineIndex: li,
                  startTokenIndex: ti,
                  endTokenIndex: ti + 1,
                  replacementForStart: null,
                  resolved: resolved2,
                  score: resolved2.score - 0.01,
                ),
              );
              continue;
            }
          }
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

    final remaining = _applyCandidateRemoval(preparedTokensByLine, best);
    final conf = best?.score ?? ((sym.isNotEmpty || names.isNotEmpty) ? 0.6 : 0.0);

    return CurrencyDetectResult(
      pos: best?.originalPos,
      detectedKey: best?.resolved.key,
      detectedDisplayName: best?.resolved.displayName,
      suggestSymbols: sym,
      suggestNames: names,
      confidence: conf,
      remainingTokensByLine: remaining,
    );
  }
}