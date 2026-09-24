// lib/services/detection/name_detector.dart
// -------------------------------------------------------------
// كاشف الاسم (نسخة مطوّرة):
// 1) يفحص كل الأسطر ويستخرج المرشحين من كل سطر مع درجة ونوع دليل:
//    - كلمة اسم داخل السطر (المستفيد: ...)
//    - السطر السابق ينتهي بكلمة اسم
//    - مطابقة اسم المرسل
//    - اسم معروف (مستخدم في حركات سابقة)
//    - شكل سطر يشبه الاسم (بدون دليل)
// 2) يقارن الأسطر ويعتمد الأفضل.
// 3) عند عدم وجود مرشح مناسب أو وجود أكثر من سطر فيه اسم معروف:
//    تُفحص آخر كلمة في السطر السابق لكل مرشح:
//      - كلمة اسم  → يُختار ذلك السطر
//      - كلمة ممنوعة → يُستبعد ذلك السطر ويُختار الآخر
//      - غير محسوم → يُترك الاسم فارغًا ليحدده المستخدم (مع اقتراحات)
// 4) الكلمات والجمل الممنوعة لا تدخل أبدًا في الاسم ويتوقف عندها الامتداد.
// (ملف Dart نقي بدون Flutter)
// -------------------------------------------------------------

import 'text_tokens.dart';

class TokenRef {
  final int lineIndex;
  final int tokenIndex;
  const TokenRef(this.lineIndex, this.tokenIndex);
}

class ForwardToken {
  final String token;
  final TokenRef original;
  const ForwardToken({required this.token, required this.original});
}

/// نوع الدليل الذي بُني عليه ترشيح سطر كاسم
enum NameEvidence {
  keyword,
  previousLineKeyword,
  sender,
  knownFull,
  known,
  senderPartial,
  weakKnown,
  lineShape,
}

extension NameEvidenceInfo on NameEvidence {
  bool get isStrong =>
      this == NameEvidence.keyword || this == NameEvidence.previousLineKeyword;

  bool get isKnownLevel =>
      this == NameEvidence.sender ||
      this == NameEvidence.knownFull ||
      this == NameEvidence.known;

  bool get isMedium =>
      this == NameEvidence.senderPartial || this == NameEvidence.weakKnown;

  String get label {
    switch (this) {
      case NameEvidence.keyword:
        return 'بعد كلمة اسم';
      case NameEvidence.previousLineKeyword:
        return 'السطر السابق ينتهي بكلمة اسم';
      case NameEvidence.sender:
        return 'مطابق لاسم المرسل';
      case NameEvidence.knownFull:
        return 'اسم معروف من حركات سابقة';
      case NameEvidence.known:
        return 'يشبه اسمًا معروفًا';
      case NameEvidence.senderPartial:
        return 'يحتوي جزءًا من اسم المرسل';
      case NameEvidence.weakKnown:
        return 'فيه كلمة من اسم معروف';
      case NameEvidence.lineShape:
        return 'سطر يشبه الاسم';
    }
  }
}

class NameLineCandidate {
  final int lineIndex;
  final List<int> tokenIndexes;
  final double score;
  final NameEvidence evidence;
  final String text;

  /// true إذا سبقته كلمة ممنوعة (في نفس السطر أو في آخر السطر السابق)
  final bool blockedByForbidden;

  const NameLineCandidate({
    required this.lineIndex,
    required this.tokenIndexes,
    required this.score,
    required this.evidence,
    required this.text,
    this.blockedByForbidden = false,
  });
}

class NameDetectResult {
  /// التوكنات التي اعتُبرت اسمًا (سطر → فهارس)
  final Map<int, List<int>> tokensByLine;
  final double confidence;

  /// النص المتبقي (للتوافق مع المراحل القديمة)
  final List<List<ForwardToken>> remainingTokensByLine;

  /// كل الأسطر المرشحة (الأفضل أولًا) — تُستخدم كاقتراحات للمستخدم
  final List<NameLineCandidate> candidates;

  /// true إذا تُرك الاسم فارغًا بسبب تعارض لم يُحسم
  final bool ambiguous;

  /// شرح مختصر لسبب الاختيار أو سبب ترك الاسم فارغًا
  final String? reason;

  const NameDetectResult({
    required this.tokensByLine,
    required this.confidence,
    required this.remainingTokensByLine,
    this.candidates = const [],
    this.ambiguous = false,
    this.reason,
  });

  bool get isEmpty => tokensByLine.isEmpty;

  List<String> get remainingLines => remainingTokensByLine
      .map((row) => row.map((e) => e.token).join(' '))
      .toList();
}

/// إعدادات الكاشف بعد تجهيزها مرة واحدة (مجموعات مطبّعة + فهرس الأسماء المعروفة)
class NameDetectorConfig {
  final PhraseSet nameKeywords;
  final PhraseSet ignored;
  final PhraseSet lineIgnored;
  final PhraseSet currency;
  final PhraseSet forbidden;
  final PhraseSet amountKeywords;
  final PhraseSet cancelKeywords;

  final List<List<String>> _knownNames = [];
  final Map<String, List<int>> _knownIndex = {};

  NameDetectorConfig({
    required List<String> nameKeywords,
    List<String> knownNames = const [],
    List<String> ignoredWords = const [],
    List<String> lineIgnoredWords = const [],
    List<String> currencyWords = const [],
    List<String> forbiddenWords = const [],
    List<String> forbiddenPhrases = const [],
    List<String> amountKeywords = const [],
    List<String> cancelKeywords = const [],
  }) : nameKeywords = PhraseSet(nameKeywords),
       ignored = PhraseSet(ignoredWords),
       lineIgnored = PhraseSet(lineIgnoredWords),
       currency = PhraseSet(currencyWords),
       forbidden = PhraseSet([...forbiddenWords, ...forbiddenPhrases]),
       amountKeywords = PhraseSet(amountKeywords),
       cancelKeywords = PhraseSet(cancelKeywords) {
    final seen = <String>{};
    for (final name in knownNames) {
      final keys = tokensFromLine(
        name,
      ).map(matchKey).where((k) => k.isNotEmpty && !tokenHasDigit(k)).toList();
      if (keys.isEmpty) continue;
      final joined = keys.join(' ');
      if (!seen.add(joined)) continue;
      final id = _knownNames.length;
      _knownNames.add(keys);
      for (final k in keys.toSet()) {
        (_knownIndex[k] ??= []).add(id);
      }
    }
  }

  void addKnownName(String name) {
    final keys = tokensFromLine(
      name,
    ).map(matchKey).where((k) => k.isNotEmpty && !tokenHasDigit(k)).toList();
    if (keys.isEmpty) return;
    final id = _knownNames.length;
    _knownNames.add(keys);
    for (final k in keys.toSet()) {
      (_knownIndex[k] ??= []).add(id);
    }
  }

  List<String> keysOf(List<String> tokens) => tokens.map(matchKey).toList();

  bool isIgnoredKey(String key) => ignored.containsKey(key);

  /// فهارس التوكنات المغطاة بكلمة/جملة ممنوعة داخل سطر
  Set<int> forbiddenMask(List<String> keys) {
    final out = <int>{};
    if (forbidden.isEmpty) return out;
    for (final hit in forbidden.findAll(keys)) {
      for (int i = hit.start; i < hit.end; i++) {
        out.add(i);
      }
    }
    return out;
  }

  /// هل يبدأ عند [i] شيء يوقف امتداد الاسم؟ (يعيد السبب أو null)
  String? stopReasonAt(List<String> keys, int i, {Set<int>? forbiddenIdx}) {
    if (i < 0 || i >= keys.length) return 'نهاية السطر';
    final k = keys[i];
    if (k.isEmpty) return 'فراغ';
    if ((forbiddenIdx?.contains(i) ?? false) ||
        forbidden.matchAt(keys, i) > 0) {
      return 'كلمة ممنوعة';
    }
    if (tokenHasDigit(k)) return 'رقم';
    if (containsCurrencySymbol(k) || currency.matchAt(keys, i) > 0) {
      return 'عملة';
    }
    if (amountKeywords.matchAt(keys, i) > 0) return 'كلمة مبلغ';
    if (nameKeywords.matchAt(keys, i) > 0) return 'كلمة اسم';
    if (cancelKeywords.matchAt(keys, i) > 0) return 'كلمة إلغاء';
    if (lineIgnored.containsKey(k)) return 'كلمة تجاهل سطر';
    if (phoneWordKeys.contains(k)) return 'كلمة هاتف';
    if (amountUnitKeys.contains(k)) return 'وحدة مبلغ';
    return null;
  }

  /// يجمع الاسم بدءًا من [start] حتى نهاية السطر أو أول كلمة إيقاف.
  /// الكلمات المهملة تُتخطى ولا تُضاف.
  List<int> collectSpan(
    List<String> keys,
    int start, {
    Set<int>? forbiddenIdx,
    bool Function(int index)? extraStop,
    int maxTokens = 8,
  }) {
    final span = <int>[];
    for (int i = start; i < keys.length; i++) {
      if (extraStop != null && extraStop(i)) break;
      if (stopReasonAt(keys, i, forbiddenIdx: forbiddenIdx) != null) break;
      if (isIgnoredKey(keys[i])) continue;
      span.add(i);
      if (span.length >= maxTokens) break;
    }
    return span;
  }

  bool _canBeNameKey(List<String> keys, int i, Set<int> forbiddenIdx) =>
      stopReasonAt(keys, i, forbiddenIdx: forbiddenIdx) == null &&
      !isIgnoredKey(keys[i]);
}

class _LineInfo {
  final List<String> tokens;
  final List<String> keys;
  final Set<int> forbiddenIdx;
  final bool skipped;

  _LineInfo(this.tokens, this.keys, this.forbiddenIdx, this.skipped);

  bool get isEmpty => keys.isEmpty;
}

final RegExp _legacyDisallowedRe = RegExp(
  r'[^\u0600-\u06FFa-zA-Z0-9\$€£﷼٫.,_/\-]',
);

String _legacyClean(String w) =>
    normalizeArabic(w.replaceAll(_legacyDisallowedRe, '')).trim();

class NameDetector {
  // ===================== واجهة التوافق القديمة =====================
  static NameDetectResult detect({
    required List<String> lines,
    required String senderName,
    required List<String> nameKeywords,
    List<String> knownNames = const [],
    List<String> ignoredWords = const [],
    List<String> lineIgnoredWords = const [],
    List<String> currencyWords = const [],
    List<String> forbiddenWords = const [],
    List<String> forbiddenPhrases = const [],
    List<String> amountKeywords = const [],
    List<String> cancelKeywords = const [],
  }) {
    final config = NameDetectorConfig(
      nameKeywords: nameKeywords,
      knownNames: knownNames,
      ignoredWords: ignoredWords,
      lineIgnoredWords: lineIgnoredWords,
      currencyWords: currencyWords,
      forbiddenWords: forbiddenWords,
      forbiddenPhrases: forbiddenPhrases,
      amountKeywords: amountKeywords,
      cancelKeywords: cancelKeywords,
    );
    return detectTokens(
      tokenLines: lines.map(tokensFromLine).toList(),
      senderName: senderName,
      config: config,
    );
  }

  // ===================== الواجهة الجديدة =====================
  static NameDetectResult detectTokens({
    required List<List<String>> tokenLines,
    required String senderName,
    required NameDetectorConfig config,
  }) {
    // 1) تجهيز الأسطر
    final lines = <_LineInfo>[];
    for (final toks in tokenLines) {
      final keys = config.keysOf(toks);
      final forbiddenIdx = config.forbiddenMask(keys);
      lines.add(
        _LineInfo(
          toks,
          keys,
          forbiddenIdx,
          _shouldSkipLine(toks, keys, config),
        ),
      );
    }

    int prevNonEmpty(int li) {
      for (int i = li - 1; i >= 0; i--) {
        if (!lines[i].isEmpty) return i;
      }
      return -1;
    }

    // آخر كلمة مفيدة في السطر (تتخطى الكلمات المهملة)
    int lastMeaningful(_LineInfo line) {
      for (int i = line.keys.length - 1; i >= 0; i--) {
        if (!config.isIgnoredKey(line.keys[i])) return i;
      }
      return -1;
    }

    bool prevEndsWithKeyword(int li) {
      final p = prevNonEmpty(li);
      if (p < 0) return false;
      final last = lastMeaningful(lines[p]);
      if (last < 0) return false;
      return config.nameKeywords.matchEndingAt(lines[p].keys, last) > 0;
    }

    bool prevEndsWithForbidden(int li) {
      final p = prevNonEmpty(li);
      if (p < 0) return false;
      final last = lastMeaningful(lines[p]);
      if (last < 0) return false;
      return lines[p].forbiddenIdx.contains(last) ||
          config.forbidden.matchEndingAt(lines[p].keys, last) > 0;
    }

    // هل الاسم يبدأ فعليًا من بداية السطر (قبله كلمات مهملة فقط)؟
    bool startsAtLineStart(_LineInfo line, List<int> span) {
      if (span.isEmpty) return false;
      for (int i = 0; i < span.first; i++) {
        if (!config.isIgnoredKey(line.keys[i])) return false;
      }
      return true;
    }

    // هل الكلمة التي تسبق الاسم مباشرة ممنوعة؟
    bool forbiddenBefore(_LineInfo line, List<int> span) {
      if (span.isEmpty) return false;
      for (int i = span.first - 1; i >= 0; i--) {
        if (config.isIgnoredKey(line.keys[i])) continue;
        return line.forbiddenIdx.contains(i);
      }
      return false;
    }

    final candidates = <NameLineCandidate>[];

    void addCandidate(
      int li,
      List<int> span,
      double score,
      NameEvidence evidence,
    ) {
      if (span.isEmpty) return;
      final line = lines[li];
      // اسم مسبوق بكلمة ممنوعة في نفس السطر، أو يبدأ السطر بينما السطر
      // السابق ينتهي بكلمة ممنوعة → يُعلَّم كمستبعد (ويُحسب في قاعدة الحسم)
      final blocked =
          !evidence.isStrong &&
          (forbiddenBefore(line, span) ||
              (startsAtLineStart(line, span) && prevEndsWithForbidden(li)));
      candidates.add(
        NameLineCandidate(
          lineIndex: li,
          tokenIndexes: List<int>.unmodifiable(span),
          score: score,
          evidence: evidence,
          text: span.map((i) => line.tokens[i]).join(' '),
          blockedByForbidden: blocked,
        ),
      );
    }

    // تقييم التطابق مع الأسماء المعروفة لامتداد معيّن
    ({int overlap, bool full})? bestKnownMatch(List<String> spanKeys) {
      if (config._knownNames.isEmpty || spanKeys.isEmpty) return null;
      final counts = <int, int>{};
      for (final k in spanKeys.toSet()) {
        final ids = config._knownIndex[k];
        if (ids == null) continue;
        for (final id in ids) {
          counts[id] = (counts[id] ?? 0) + 1;
        }
      }
      if (counts.isEmpty) return null;
      int bestOverlap = 0;
      bool bestFull = false;
      int bestExtra = 1 << 30;
      counts.forEach((id, overlap) {
        final known = config._knownNames[id];
        final full = overlap >= known.toSet().length;
        final extra = spanKeys.length - overlap;
        final better =
            (full && !bestFull) ||
            (full == bestFull &&
                (overlap > bestOverlap ||
                    (overlap == bestOverlap && extra < bestExtra)));
        if (better) {
          bestOverlap = overlap;
          bestFull = full;
          bestExtra = extra;
        }
      });
      return (overlap: bestOverlap, full: bestFull);
    }

    final senderKeys = tokensFromLine(
      senderName,
    ).map(matchKey).where((k) => k.isNotEmpty).toList();
    final senderParts = senderKeys
        .where((k) => k.length >= 2 && !tokenHasDigit(k))
        .toSet();

    // 2) استخراج المرشحين من كل الأسطر
    for (int li = 0; li < lines.length; li++) {
      final line = lines[li];
      if (line.isEmpty || line.skipped) continue;
      final keys = line.keys;

      // أ) كلمة اسم داخل السطر
      int i = 0;
      while (i < keys.length) {
        final len = config.nameKeywords.matchAt(keys, i);
        if (len == 0) {
          i++;
          continue;
        }
        final kwText = keys.sublist(i, i + len).join(' ');
        final span = config.collectSpan(
          keys,
          i + len,
          forbiddenIdx: line.forbiddenIdx,
        );
        if (span.isNotEmpty) {
          // الكلمات القصيرة مثل «ل» و«الى» أضعف من «المستفيد»
          final specific = kwText.replaceAll(' ', '').length > 3;
          var score = specific ? 100.0 : 86.0;
          final km = bestKnownMatch(span.map((x) => keys[x]).toList());
          if (km != null && (km.full || km.overlap >= 2)) score += 8;
          addCandidate(li, span, score, NameEvidence.keyword);
        }
        i += len;
      }

      // ب) السطر السابق ينتهي بكلمة اسم → هذا السطر هو الاسم
      if (prevEndsWithKeyword(li)) {
        int start = 0;
        while (start < keys.length && config.isIgnoredKey(keys[start])) {
          start++;
        }
        final span = config.collectSpan(
          keys,
          start,
          forbiddenIdx: line.forbiddenIdx,
        );
        addCandidate(li, span, 95, NameEvidence.previousLineKeyword);
      }

      // ج) اسم المرسل كسلسلة كاملة
      if (senderKeys.isNotEmpty && senderKeys.length <= keys.length) {
        for (int s = 0; s <= keys.length - senderKeys.length; s++) {
          var ok = true;
          for (int j = 0; j < senderKeys.length; j++) {
            if (keys[s + j] != senderKeys[j]) {
              ok = false;
              break;
            }
          }
          if (!ok) continue;
          final core = <int>[
            for (int j = 0; j < senderKeys.length; j++)
              if (config._canBeNameKey(keys, s + j, line.forbiddenIdx)) s + j,
          ];
          if (core.isEmpty) break;
          // نمدّ المطابقة لتشمل كامل المقطع المتصل (مثل: أحمد → أحمد محمد العلي)
          final runs = _nameRuns(keys, line.forbiddenIdx, config);
          final run = runs.firstWhere(
            (r) => r.contains(core.first),
            orElse: () => core,
          );
          addCandidate(li, run, 80, NameEvidence.sender);
          break;
        }
      }

      // د) الأسماء المعروفة + جزء من اسم المرسل (على مستوى المقاطع المتصلة)
      final runs = _nameRuns(keys, line.forbiddenIdx, config);
      double bestRunScore = -1;
      NameEvidence? bestRunEvidence;
      List<int>? bestRunSpan;
      for (final run in runs) {
        final runKeys = run.map((x) => keys[x]).toList();
        final km = bestKnownMatch(runKeys);
        NameEvidence? ev;
        double score = 0;
        final span = run;
        if (km != null) {
          if (km.full) {
            ev = NameEvidence.knownFull;
            score = 90 - (runKeys.length - km.overlap) * 2.0;
          } else if (km.overlap >= 2) {
            ev = NameEvidence.known;
            score = 70.0 + km.overlap * 2 - (runKeys.length - km.overlap);
          } else {
            ev = NameEvidence.weakKnown;
            score = 40;
          }
        }
        if (senderParts.isNotEmpty && runKeys.any(senderParts.contains)) {
          if (ev == null || score < 50) {
            ev = NameEvidence.senderPartial;
            score = 50;
          }
        }
        if (ev != null && score > bestRunScore) {
          bestRunScore = score;
          bestRunEvidence = ev;
          bestRunSpan = span;
        }
      }
      if (bestRunEvidence != null && bestRunSpan != null) {
        addCandidate(li, bestRunSpan, bestRunScore, bestRunEvidence);
      }

      // هـ) شكل سطر يشبه الاسم: 2-5 كلمات كلها صالحة للاسم.
      // إذا سبقت المقطعَ كلمةٌ/جملةٌ ممنوعة نضيفه أيضًا (سيُعلَّم كمستبعد)
      // حتى تعمل قاعدة «كلمة ممنوعة → اختر السطر الآخر».
      if (runs.length == 1) {
        final run = runs.first;
        final meaningful = <int>[
          for (int x = 0; x < keys.length; x++)
            if (!config.isIgnoredKey(keys[x])) x,
        ];
        final others = meaningful.where((x) => !run.contains(x)).toList();
        final onlyForbiddenBefore =
            others.isNotEmpty &&
            others.every((x) => line.forbiddenIdx.contains(x) && x < run.first);
        if (others.isEmpty &&
            run.length >= 2 &&
            run.length <= 5 &&
            run.every((x) => keys[x].length >= 2)) {
          addCandidate(li, run, 30, NameEvidence.lineShape);
        } else if (onlyForbiddenBefore && run.length <= 5) {
          addCandidate(li, run, 30, NameEvidence.lineShape);
        }
      }
    }

    // 3) أفضل مرشح لكل سطر (غير المستبعد أولًا ثم الأعلى درجة)
    final bestByLine = <int, NameLineCandidate>{};
    for (final c in candidates) {
      final cur = bestByLine[c.lineIndex];
      if (cur == null) {
        bestByLine[c.lineIndex] = c;
        continue;
      }
      if (cur.blockedByForbidden != c.blockedByForbidden) {
        if (!c.blockedByForbidden) bestByLine[c.lineIndex] = c;
        continue;
      }
      if (c.score > cur.score ||
          (c.score == cur.score &&
              c.tokenIndexes.length > cur.tokenIndexes.length)) {
        bestByLine[c.lineIndex] = c;
      }
    }
    final perLine = bestByLine.values.toList()
      ..sort((a, b) {
        if (a.blockedByForbidden != b.blockedByForbidden) {
          return a.blockedByForbidden ? 1 : -1;
        }
        final s = b.score.compareTo(a.score);
        if (s != 0) return s;
        return a.lineIndex.compareTo(b.lineIndex);
      });

    // الاقتراحات للمستخدم: المرشحون غير المستبعدين فقط
    final suggestions = perLine.where((c) => !c.blockedByForbidden).toList();
    final blockedCount = perLine.where((c) => c.blockedByForbidden).length;

    NameDetectResult done(
      NameLineCandidate? chosen, {
      required double confidence,
      bool ambiguous = false,
      String? reason,
    }) {
      final map = <int, List<int>>{};
      if (chosen != null) {
        map[chosen.lineIndex] = List<int>.from(chosen.tokenIndexes);
      }
      return NameDetectResult(
        tokensByLine: map,
        confidence: chosen == null ? 0.0 : confidence,
        remainingTokensByLine: _buildRemaining(lines, map, config),
        candidates: suggestions,
        ambiguous: ambiguous,
        reason: reason,
      );
    }

    if (perLine.isEmpty) {
      return done(null, confidence: 0, reason: 'لم يتم العثور على سطر اسم');
    }

    // قاعدة الحسم بآخر كلمة في السطر السابق:
    // كلمة اسم → نختار ذلك السطر، كلمة ممنوعة → نستبعده ونختار الآخر
    NameLineCandidate? tieBreak(List<NameLineCandidate> list) {
      final kw = list.where((c) => prevEndsWithKeyword(c.lineIndex)).toList();
      if (kw.length == 1) return kw.first;
      final rest = list
          .where((c) => !prevEndsWithForbidden(c.lineIndex))
          .toList();
      if (rest.length == 1 && rest.length < list.length) return rest.first;
      return null;
    }

    // أ) أدلة قوية (كلمة اسم في نفس السطر أو في آخر السطر السابق)
    final strong = perLine
        .where((c) => c.evidence.isStrong && !c.blockedByForbidden)
        .toList();
    if (strong.isNotEmpty) {
      if (strong.length == 1) {
        final c = strong.first;
        return done(c, confidence: 0.92, reason: c.evidence.label);
      }
      if (strong[0].score > strong[1].score) {
        final c = strong.first;
        return done(c, confidence: 0.9, reason: c.evidence.label);
      }
      final top = strong.where((c) => c.score == strong.first.score).toList();
      final tb = tieBreak(top);
      if (tb != null) {
        return done(tb, confidence: 0.85, reason: 'حُسم بالسطر السابق');
      }
      return done(
        null,
        confidence: 0,
        ambiguous: true,
        reason: 'يوجد أكثر من سطر بعد كلمة اسم — اختر السطر الصحيح',
      );
    }

    // ب) أسطر فيها اسم معروف / اسم المرسل
    final known = perLine.where((c) => c.evidence.isKnownLevel).toList();
    final knownOk = known.where((c) => !c.blockedByForbidden).toList();
    if (knownOk.length == 1) {
      final c = knownOk.first;
      final resolvedByForbidden = known.length > 1;
      return done(
        c,
        confidence: resolvedByForbidden ? 0.8 : 0.86,
        reason: resolvedByForbidden ? 'حُسم بالسطر السابق' : c.evidence.label,
      );
    }
    if (knownOk.length >= 2) {
      final tb = tieBreak(knownOk);
      if (tb != null) {
        return done(tb, confidence: 0.8, reason: 'حُسم بالسطر السابق');
      }
      return done(
        null,
        confidence: 0,
        ambiguous: true,
        reason: 'يوجد أكثر من سطر فيه اسم معروف — اختر السطر الصحيح',
      );
    }

    // ج) أدلة متوسطة (جزء من اسم المرسل / كلمة من اسم معروف)
    final medium = perLine
        .where((c) => c.evidence.isMedium && !c.blockedByForbidden)
        .toList();
    if (medium.length == 1) {
      final c = medium.first;
      return done(c, confidence: 0.7, reason: c.evidence.label);
    }
    if (medium.length >= 2) {
      final tb = tieBreak(medium);
      if (tb != null) {
        return done(tb, confidence: 0.66, reason: 'حُسم بالسطر السابق');
      }
      return done(
        null,
        confidence: 0,
        ambiguous: true,
        reason: 'يوجد أكثر من سطر مرشح للاسم — اختر السطر الصحيح',
      );
    }

    // د) لا يوجد مرشح مناسب → نعتمد فقط على الحسم بالسطر السابق:
    // إذا استُبعد سطر بسبب كلمة ممنوعة وبقي سطر واحد يشبه الاسم نختاره.
    final shapedOk = perLine
        .where(
          (c) => c.evidence == NameEvidence.lineShape && !c.blockedByForbidden,
        )
        .toList();
    if (shapedOk.length == 1 && blockedCount > 0) {
      return done(
        shapedOk.first,
        confidence: 0.55,
        reason: 'حُسم بالسطر السابق (استُبعد سطر بعد كلمة ممنوعة)',
      );
    }
    return done(
      null,
      confidence: 0,
      ambiguous: shapedOk.length > 1,
      reason: shapedOk.isEmpty
          ? 'لم يتم العثور على سطر اسم مناسب'
          : 'لم يُحسم الاسم تلقائيًا — اختر السطر الصحيح',
    );
  }

  /// المقاطع المتصلة من الكلمات الصالحة للاسم داخل سطر
  static List<List<int>> _nameRuns(
    List<String> keys,
    Set<int> forbiddenIdx,
    NameDetectorConfig config,
  ) {
    final runs = <List<int>>[];
    var current = <int>[];
    for (int i = 0; i < keys.length; i++) {
      if (config.isIgnoredKey(keys[i])) continue; // المهملة لا تقطع المقطع
      if (config.stopReasonAt(keys, i, forbiddenIdx: forbiddenIdx) != null) {
        if (current.isNotEmpty) runs.add(current);
        current = <int>[];
        continue;
      }
      current.add(i);
    }
    if (current.isNotEmpty) runs.add(current);
    return runs.where((r) => r.length <= 8).toList();
  }

  static final RegExp _letterRe = RegExp(r'[a-zA-Z\u0621-\u064A]');

  /// أسطر لا يمكن أن تحتوي اسمًا: سطر فارغ، أو فيه كلمة «تجاهل السطر»، أو
  /// لا يحتوي إلا أرقامًا ورموزًا (رقم هاتف/كود مفصول أو غير مفصول).
  /// ملاحظة: كلمات الهاتف (رقم/هاتف/جوال...) لم تعد تُسقط السطر كاملًا؛ هي
  /// فواصل توقف الاسم فقط، حتى يُكشف الاسم المكتوب قبلها في نفس السطر.
  static bool _shouldSkipLine(
    List<String> tokens,
    List<String> keys,
    NameDetectorConfig config,
  ) {
    if (keys.isEmpty) return true;
    if (keys.any(config.lineIgnored.containsKey)) return true;
    if (!tokens.any(_letterRe.hasMatch)) return true;
    return false;
  }

  static List<List<ForwardToken>> _buildRemaining(
    List<_LineInfo> lines,
    Map<int, List<int>> nameTokensByLine,
    NameDetectorConfig config,
  ) {
    final result = <List<ForwardToken>>[];
    for (int li = 0; li < lines.length; li++) {
      final line = lines[li];
      if (line.isEmpty || line.skipped) {
        result.add(const []);
        continue;
      }
      final removed = (nameTokensByLine[li] ?? const <int>[]).toSet();
      final row = <ForwardToken>[];
      for (int ti = 0; ti < line.tokens.length; ti++) {
        if (removed.contains(ti)) continue;
        final key = line.keys[ti];
        if (config.isIgnoredKey(key)) continue;
        if (phoneWordKeys.contains(key)) continue;
        if (isPhoneLike(line.tokens[ti])) continue;
        // نفس شكل التوكن الذي كانت تمرره النسخة القديمة (مطبّع عربيًا)
        final legacy = _legacyClean(line.tokens[ti]);
        if (legacy.isEmpty) continue;
        row.add(ForwardToken(token: legacy, original: TokenRef(li, ti)));
      }
      result.add(row);
    }
    return result;
  }
}
