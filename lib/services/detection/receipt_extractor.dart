// lib/services/detection/receipt_extractor.dart
// -------------------------------------------------------------
// استخراج (الاسم + المبلغ + العملة) من رسالة تسليم واحدة:
// 1) كشف الضجيج (هواتف، تواريخ، أوقات، أكواد...) عبر MessageNoiseScanner.
// 2) كشف الاسم بعد استبدال الضجيج بفاصل رقمي (يحافظ على الفهارس ويوقف الاسم)،
//    وأخذ التوكنات بفهارسها الدقيقة فقط (بدون بقية السطر).
// 3) كشف العملة ثم المبلغ على باقي النص بعد حذف الاسم والضجيج.
//    المحاولة الأولى تستبعد الأرقام المشكوك بها (8–9 أرقام متتالية)،
//    والثانية تسمح بها فقط إن لم يوجد أي مبلغ.
// (ملف Dart نقي بدون Flutter)
// -------------------------------------------------------------

import 'dart:math' show Point;

import 'amount_detector.dart' as ad;
import 'currency_detector.dart' as cd;
import 'message_noise.dart';
import 'name_detector.dart' as nd;
import 'text_tokens.dart' as tt;

/// اقتراح اسم (سطر + فهارس دقيقة)
class ReceiptNameOption {
  final int lineIndex;
  final List<int> tokenIndexes;
  final String text;
  final String reason;

  const ReceiptNameOption({
    required this.lineIndex,
    required this.tokenIndexes,
    required this.text,
    required this.reason,
  });
}

class ReceiptExtraction {
  /// توكنات كل سطر مع علامات الضجيج
  final List<LineNoise> lines;

  /// توكنات الاسم (سطر → فهارس مرتبة)
  final Map<int, List<int>> nameTokensByLine;
  final String name;
  final bool nameAmbiguous;
  final String? nameReason;
  final List<ReceiptNameOption> nameOptions;

  final double? amount;

  /// توكنات المبلغ المختار (أكثر من توكن للمبالغ المفصولة بمسافات)
  final List<Point<int>> amountTokens;
  final bool amountFromText;
  final bool amountHasConflict;
  final bool amountHasMultipleCandidates;
  final List<double> amountCandidates;

  /// تم اعتماد رقم مشكوك به (قد يكون هاتفًا) لعدم وجود مبلغ غيره
  final bool amountFromSuspect;

  final Point<int>? currencyPos;
  final String? currencyKey;

  /// مواقع كل كلمات العملة المختارة («ليرة سورية» = موقعان)
  final List<Point<int>> currencyPositions;

  /// كل العملات المختلفة في الرسالة (بالاسم المعروض)
  final List<String> currencyNames;

  /// في الرسالة أكثر من مبلغ وأكثر من عملة: لا نعرف أي مبلغ لأي عملة، فلا
  /// يُعتمد المبلغ تلقائيًا ويختاره المستخدم (مع تحذير)
  final bool moneyAmbiguous;

  const ReceiptExtraction({
    required this.lines,
    required this.nameTokensByLine,
    required this.name,
    required this.nameAmbiguous,
    required this.nameReason,
    required this.nameOptions,
    required this.amount,
    required this.amountTokens,
    required this.amountFromText,
    required this.amountHasConflict,
    required this.amountHasMultipleCandidates,
    required this.amountCandidates,
    required this.amountFromSuspect,
    required this.currencyPos,
    required this.currencyKey,
    this.currencyPositions = const [],
    this.currencyNames = const [],
    this.moneyAmbiguous = false,
  });

  NoiseMark? noiseAt(int li, int ti) =>
      (li >= 0 && li < lines.length) ? lines[li].markAt(ti) : null;
}

class ReceiptExtractor {
  final nd.NameDetectorConfig nameConfig;
  final Map<String, String> currencyMap;
  final List<String> amountKeywords;
  final List<String> ignoredWords;
  final Map<String, double> customWordValues;
  final MessageNoiseScanner scanner;
  final Set<String> _currencyHints;

  ReceiptExtractor({
    required this.nameConfig,
    required this.currencyMap,
    this.amountKeywords = const [],
    this.ignoredWords = const [],
    this.customWordValues = const {},
  }) : scanner = MessageNoiseScanner(
         currencyWords: [...currencyMap.keys, ...currencyMap.values],
         amountKeywords: amountKeywords,
       ),
       _currencyHints = {
         ...currencyMap.keys,
         ...currencyMap.values,
       }.where((e) => e.trim().isNotEmpty).toSet();

  // ---------------------------------------------------------------------------

  ReceiptExtraction extract(List<String> lines, {String senderName = ''}) {
    final noise = scanner.scan(lines);

    // 1) الاسم: الضجيج يُستبدل بفاصل رقمي حتى لا يدخل في الاسم ولا يغيّر الفهارس
    final nameLines = [
      for (final ln in noise)
        [
          for (int i = 0; i < ln.tokens.length; i++)
            (ln.isNoise(i) || ln.mergedContaining(i) != null)
                ? '0'
                : ln.tokens[i],
        ],
    ];

    final nameRes = nd.NameDetector.detectTokens(
      tokenLines: nameLines,
      senderName: senderName,
      config: nameConfig,
    );

    final nameTokens = <int, List<int>>{
      for (final e in nameRes.tokensByLine.entries)
        e.key: (List<int>.from(e.value)..sort()),
    };
    final name = textOf(noise, nameTokens);

    final options = <ReceiptNameOption>[];
    final seen = <String>{};
    for (final c in nameRes.candidates) {
      final text = textOf(noise, {c.lineIndex: c.tokenIndexes});
      final key = tt.normalizeText(text);
      if (key.isEmpty || !seen.add(key)) continue;
      options.add(
        ReceiptNameOption(
          lineIndex: c.lineIndex,
          tokenIndexes: List<int>.from(c.tokenIndexes)..sort(),
          text: text,
          reason: c.evidence.label,
        ),
      );
      if (options.length >= 6) break;
    }

    // 2) العملة + المبلغ (محاولة صارمة ثم مرنة)
    var pass = _detectMoney(noise, nameTokens, includeSuspect: false);
    var fromSuspect = false;
    if (pass.amount.numericValue == null) {
      final relaxed = _detectMoney(noise, nameTokens, includeSuspect: true);
      if (relaxed.amount.numericValue != null) {
        pass = relaxed;
        fromSuspect = true;
      }
    }

    final amountTokens = <Point<int>>[];
    final pos = pass.amount.numericPos;
    if (pos != null && pos.x >= 0 && pos.x < noise.length) {
      final merged = noise[pos.x].mergedStartingAt(pos.y);
      if (merged != null) {
        for (int i = merged.start; i <= merged.end; i++) {
          amountTokens.add(Point(pos.x, i));
        }
      } else {
        amountTokens.add(Point(pos.x, pos.y));
      }
    }

    String? currencyKey = pass.currency.detectedKey;
    final cpos = pass.currency.pos;
    if (currencyKey == null && cpos != null && cpos.x < noise.length) {
      final toks = noise[cpos.x].tokens;
      if (cpos.y >= 0 && cpos.y < toks.length) {
        currencyKey = currencyKeyOf(toks[cpos.y]);
      }
    }

    return ReceiptExtraction(
      lines: noise,
      nameTokensByLine: nameTokens,
      name: name,
      nameAmbiguous: nameRes.ambiguous,
      nameReason: nameRes.reason,
      nameOptions: options,
      amount: pass.amount.numericValue,
      amountTokens: amountTokens,
      amountFromText: pass.amount.fromText,
      amountHasConflict: pass.amount.hasConflict,
      amountHasMultipleCandidates: pass.amount.hasMultipleCandidates,
      amountCandidates: List<double>.from(pass.amount.candidateValues),
      amountFromSuspect: fromSuspect,
      currencyPos: cpos,
      currencyKey: currencyKey,
      currencyPositions: List<Point<int>>.from(pass.currency.positions),
      currencyNames: List<String>.from(pass.currency.currencyNames),
      moneyAmbiguous:
          pass.amount.candidateValues.length >= 2 &&
          pass.currency.hasMultipleCurrencies,
    );
  }

  /// مفتاح العملة في الإعدادات لنص عملة (رمز أو اسم)
  String? currencyKeyOf(String token) {
    final t = tt.matchKey(token);
    if (t.isEmpty) return null;
    for (final k in currencyMap.keys) {
      if (tt.matchKey(k) == t) return k;
    }
    for (final e in currencyMap.entries) {
      if (tt.matchKey(e.value) == t) return e.key;
    }
    return null;
  }

  /// نص الاسم من فهارس دقيقة (مع حذف علامات الترقيم من الأطراف)
  static String textOf(List<LineNoise> noise, Map<int, List<int>> byLine) {
    final parts = <String>[];
    final lineIdx = byLine.keys.toList()..sort();
    for (final li in lineIdx) {
      if (li < 0 || li >= noise.length) continue;
      final idxs = List<int>.from(byLine[li]!)..sort();
      for (final ti in idxs) {
        if (ti < 0 || ti >= noise[li].tokens.length) continue;
        final s = tt.stripEdgePunct(noise[li].tokens[ti]);
        if (s.isNotEmpty) parts.add(s);
      }
    }
    return parts.join(' ');
  }

  /// امتداد الاسم عند الضغط على كلمة: من الكلمة حتى أول فاصل (رقم، عملة،
  /// كلمة ممنوعة، كلمة مبلغ، هاتف...).
  List<int> spanFrom(LineNoise line, int start) {
    if (start < 0 || start >= line.tokens.length) return const [];
    final keys = nameConfig.keysOf(line.tokens);
    final span = nameConfig.collectSpan(
      keys,
      start,
      forbiddenIdx: nameConfig.forbiddenMask(keys),
      extraStop: (i) => line.isNoise(i) || line.mergedContaining(i) != null,
    );
    if (span.isNotEmpty) return span;
    if (!tt.tokenHasDigit(line.tokens[start]) && !line.isNoise(start)) {
      return [start];
    }
    return const [];
  }

  /// قيمة رقمية لتوكن (أو للمبلغ المدموج الذي يحتويه) عند الضغط عليه
  static double? numberAt(LineNoise line, int i) {
    if (i < 0 || i >= line.tokens.length) return null;
    final merged = line.mergedContaining(i);
    if (merged != null) return double.tryParse(merged.digits);
    final raw = line.tokens[i];
    if (!tt.tokenHasDigit(raw)) return null;
    return ad.AmountDetector.parseAmountToken(raw);
  }

  // ---------------------------------------------------------------------------

  ({ad.AmountDetectResult amount, cd.CurrencyDetectResult currency})
  _detectMoney(
    List<LineNoise> noise,
    Map<int, List<int>> nameTokens, {
    required bool includeSuspect,
  }) {
    final prepared = <List<cd.PreparedToken>>[];
    for (int li = 0; li < noise.length; li++) {
      final ln = noise[li];
      final row = <cd.PreparedToken>[];
      final keys = ln.tokens.map(tt.matchKey).toList();
      // سطر فيه كلمة «تجاهل السطر» لا يدخل في كشف المبلغ
      if (keys.any(nameConfig.lineIgnored.containsKey)) {
        prepared.add(row);
        continue;
      }
      final removed = (nameTokens[li] ?? const <int>[]).toSet();
      for (int ti = 0; ti < ln.tokens.length; ti++) {
        if (removed.contains(ti)) continue;
        if (ln.isAbsorbed(ti)) continue;
        final mark = ln.markAt(ti);
        if (mark != null && !(includeSuspect && mark.suspect)) continue;
        if (nameConfig.isIgnoredKey(keys[ti])) continue;
        final merged = ln.mergedStartingAt(ti);
        final tok = merged?.digits ?? ln.tokens[ti];
        final norm = tt.normalizeArabic(tok);
        if (norm.isEmpty) continue;
        row.add(cd.PreparedToken(token: norm, originalPos: Point(li, ti)));
      }
      prepared.add(row);
    }

    final cur = cd.CurrencyDetector.detectPrepared(
      preparedTokensByLine: prepared,
      currencyMap: currencyMap,
      ignoredWords: ignoredWords,
    );

    final amountRows = [
      for (final row in cur.remainingTokensByLine)
        [
          for (final t in row)
            ad.AmountPreparedToken(
              token: t.token,
              originalPos: ad.Position(t.originalPos.x, t.originalPos.y),
            ),
        ],
    ];

    final amount = ad.AmountDetector.detectPrepared(
      preparedTokensByLine: amountRows,
      currencyHints: _currencyHints,
      amountKeywords: amountKeywords,
      ignoredWords: ignoredWords,
      customWordValues: customWordValues,
      currencyAnchor: cur.pos == null
          ? null
          : ad.Position(cur.pos!.x, cur.pos!.y),
      keywordLookAhead: 3,
    );

    return (amount: amount, currency: cur);
  }
}
