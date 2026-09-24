// lib/services/detection/name_detector.dart
// -------------------------------------------------------------
// المرحلة 1 من خط المعالجة:
// 1) كشف الاسم
// 2) إزالة الاسم + الهواتف + الأكواد + الكلمات المتجاهلة
// 3) تجهيز النص المتبقي للمرحلة التالية (currency_detector)
// مع الحفاظ على ربط كل توكن بمكانه الأصلي داخل الرسالة.
// -------------------------------------------------------------

class TokenRef {
  final int lineIndex;
  final int tokenIndex;
  const TokenRef(this.lineIndex, this.tokenIndex);
}

class ForwardToken {
  final String token;
  final TokenRef original;
  const ForwardToken({
    required this.token,
    required this.original,
  });
}

class NameDetectResult {
  final Map<int, List<int>> tokensByLine; // التوكنات التي تم اعتبارها اسمًا
  final double confidence;

  // النص الذي سيُرسل للمرحلة التالية
  final List<List<ForwardToken>> remainingTokensByLine;

  const NameDetectResult({
    required this.tokensByLine,
    required this.confidence,
    required this.remainingTokensByLine,
  });

  bool get isEmpty => tokensByLine.isEmpty;

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

String _cleanToken(String w) => _normalizeArabic(
  w.replaceAll(
    RegExp(r'[^\u0600-\u06FFa-zA-Z0-9\$€£﷼٫.,_/\-]'),
    '',
  ),
).trim();

List<String> _tokensFromLine(String line) => line
    .split(RegExp(r'\s+'))
    .map(_cleanToken)
    .where((w) => w.isNotEmpty)
    .toList();

bool _tokenHasDigit(String token) =>
    RegExp(r'[0-9\u0660-\u0669]').hasMatch(token);

bool _hasCurrencySymbol(String token) {
  return token.contains('\$') ||
      token.contains('€') ||
      token.contains('£') ||
      token.contains('﷼') ||
      token.contains('₺');
}



bool _isPhoneWord(String token) {
  const phoneTokens = <String>{
    'هاتف',
    'الهاتف',
    'جوال',
    'الجوال',
    'واتس',
    'واتساب',
    'whatsapp',
    'whats',
    'موبايل',
    'تلفون',
    'تليفون',
    'رقم',
    'الرقم',
  };
  return phoneTokens.contains(token);
}

/// كلمات تدل على وحدات مبالغ
bool _isAmountUnitToken(String token) {
  const amountWords = <String>{
    'الف',
    'الاف',
    'مليون',
    'مليار',
  };
  return amountWords.contains(token);
}

bool _isIgnoredExact(String token, Set<String> ignoredTokens) {
  return ignoredTokens.contains(token);
}

bool _containsLineIgnoredWord(List<String> tokens, Set<String> lineIgnoredSet) {
  if (tokens.isEmpty || lineIgnoredSet.isEmpty) return false;
  for (final t in tokens) {
    if (lineIgnoredSet.contains(t)) return true;
  }
  return false;
}

bool _shouldIgnoreWholeLine(
    String rawLine,
    List<String> tokens,
    Set<String> lineIgnoredSet,
    ) {
  if (_containsLineIgnoredWord(tokens, lineIgnoredSet)) return true;
  if (_looksLikeSplitPhoneLine(rawLine, tokens)) return true;
  if (tokens.any(_isPhoneWord)) return true;
  if (tokens.length == 1 && _isPhoneLikeToken(tokens.first)) return true;
  return false;
}

/// هل هذا السطر يبدو سطر هاتف/كود؟
String _digitsOnly(String s) {
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

bool _startsLikePhone(String raw, String digits) {
  final t = raw.trim();
  if (digits.isEmpty) return false;

  // +964xxxxxxxxx
  if (t.startsWith('+')) return true;

  // 09xxxxxxxx أو 07xxxxxxxx أو أي رقم محلي يبدأ بصفر
  if (digits.startsWith('0')) return true;

  return false;
}

bool _isPhoneLikeToken(String token) {
  final raw = token.trim();
  final d = _digitsOnly(raw);

  // لا نعتمد على الطول وحده
  if (d.length < 9 || d.length > 14) return false;

  // يجب أن يبدأ فعليًا كرقم هاتف
  return _startsLikePhone(raw, d);
}

bool _looksLikeSplitPhoneLine(String rawLine, List<String> tokens) {
  final trimmed = rawLine.trim();

  // +964 000 000 000
  if (trimmed.startsWith('+')) {
    final joined = _digitsOnly(rawLine);
    return joined.length >= 9 && joined.length <= 14;
  }

  // 0xx xxx xxx xxx
  final digitGroups = tokens.where((t) => RegExp(r'^[0-9\u0660-\u0669]+$').hasMatch(t)).toList();
  if (digitGroups.length >= 2) {
    final joined = digitGroups.map(_digitsOnly).join();
    if (joined.length >= 9 && joined.length <= 14 && joined.startsWith('0')) {
      return true;
    }
  }

  return false;
}

bool _shouldDropLineFromForwarding(String rawLine, List<String> tokens) {
  if (tokens.any(_isPhoneWord)) return true;

  if (_looksLikeSplitPhoneLine(rawLine, tokens)) return true;

  if (tokens.length == 1 && _isPhoneLikeToken(tokens.first)) {
    return true;
  }

  return false;
}

bool _shouldSkipLineForNameDetection(
    String rawLine,
    Set<String> lineIgnoredSet,
    ) {
  final tokens = _tokensFromLine(rawLine);
  if (tokens.isEmpty) return true;

  if (_shouldIgnoreWholeLine(rawLine, tokens, lineIgnoredSet)) return true;

  return false;
}

/// هل هذا التوكن يمكن أن يكون جزءًا من الاسم؟
bool _isNameToken(
    String token,
    Set<String> ignoredTokens,
    Set<String> currencyTokens,
    ) {
  if (token.isEmpty) return false;
  if (_tokenHasDigit(token)) return false;
  if (_isIgnoredExact(token, ignoredTokens)) return false;
  if (currencyTokens.contains(token)) return false;
  if (_isAmountUnitToken(token)) return false;
  if (_hasCurrencySymbol(token)) return false;
  if (_isPhoneWord(token)) return false;
  return true;
}
bool _isBadTokenBeforeNameStart(
    String token,
    Set<String> ignoredTokens,
    Set<String> lineIgnoredTokens,
    Set<String> currencyTokens,
    Set<String> nameKeywordTokens,
    ) {
  if (token.isEmpty) return true;
  if (_tokenHasDigit(token)) return true;
  if (_isPhoneLikeToken(token)) return true;
  if (_isPhoneWord(token)) return true;
  if (_hasCurrencySymbol(token)) return true;
  if (currencyTokens.contains(token)) return true;
  if (ignoredTokens.contains(token)) return true;
  if (lineIgnoredTokens.contains(token)) return true;
  if (nameKeywordTokens.contains(token)) return true;
  return false;
}


bool _hasBlockedWordBeforeSpan(
    List<int> span,
    List<String> tokens,
    Set<String> ignoredTokens,
    Set<String> lineIgnoredTokens,
    Set<String> currencyTokens,
    Set<String> nameKeywordTokens,
    ) {
  if (span.isEmpty) return true;

  final first = span.first;
  final prev = first - 1;
  if (prev < 0) return false;

  final prevToken = tokens[prev];

  return _isBadTokenBeforeNameStart(
    prevToken,
    ignoredTokens,
    lineIgnoredTokens,
    currencyTokens,
    nameKeywordTokens,
  );
}
bool _isForbiddenNameEdgeToken(
    String token,
    Set<String> ignoredTokens,
    Set<String> lineIgnoredTokens,
    Set<String> currencyTokens,
    Set<String> nameKeywordTokens,
    ) {
  if (token.isEmpty) return true;
  if (_tokenHasDigit(token)) return true;
  if (_isPhoneLikeToken(token)) return true;
  if (_isPhoneWord(token)) return true;
  if (_hasCurrencySymbol(token)) return true;
  if (currencyTokens.contains(token)) return true;
  if (ignoredTokens.contains(token)) return true;
  if (lineIgnoredTokens.contains(token)) return true;
  if (nameKeywordTokens.contains(token)) return true;
  return false;
}

List<int> _trimForbiddenEdgesFromSpan(
    List<int> span,
    List<String> tokens,
    Set<String> ignoredTokens,
    Set<String> lineIgnoredTokens,
    Set<String> currencyTokens,
    Set<String> nameKeywordTokens,
    ) {
  if (span.isEmpty) return const [];

  int left = 0;
  int right = span.length - 1;

  while (left <= right) {
    final tok = tokens[span[left]];
    if (_isForbiddenNameEdgeToken(
      tok,
      ignoredTokens,
      lineIgnoredTokens,
      currencyTokens,
      nameKeywordTokens,
    )) {
      left++;
    } else {
      break;
    }
  }

  while (right >= left) {
    final tok = tokens[span[right]];
    if (_isForbiddenNameEdgeToken(
      tok,
      ignoredTokens,
      lineIgnoredTokens,
      currencyTokens,
      nameKeywordTokens,
    )) {
      right--;
    } else {
      break;
    }
  }

  if (left > right) return const [];
  return span.sublist(left, right + 1);
}


/// اجمع امتداد الاسم بدءًا من startIndex
List<int> _collectNameSpan(
    List<String> tokens,
    int startIndex,
    Set<String> ignoredTokens,
    Set<String> currencyTokens,
    ) {
  final indices = <int>[];
  for (int i = startIndex; i < tokens.length; i++) {
    final t = tokens[i];
    if (!_isNameToken(t, ignoredTokens, currencyTokens)) break;
    indices.add(i);
  }
  return indices;
}


List<int> _collectBidirectionalNameSpan(
    List<String> tokens,
    int centerIndex,
    Set<String> ignoredTokens,
    Set<String> currencyTokens,
    ) {
  if (centerIndex < 0 || centerIndex >= tokens.length) return const [];

  if (!_isNameToken(tokens[centerIndex], ignoredTokens, currencyTokens)) {
    return const [];
  }

  int start = centerIndex;
  int end = centerIndex;

  // تمدد إلى اليسار
  for (int i = centerIndex - 1; i >= 0; i--) {
    if (!_isNameToken(tokens[i], ignoredTokens, currencyTokens)) break;
    start = i;
  }

  // تمدد إلى اليمين
  for (int i = centerIndex + 1; i < tokens.length; i++) {
    if (!_isNameToken(tokens[i], ignoredTokens, currencyTokens)) break;
    end = i;
  }

  return [for (int i = start; i <= end; i++) i];
}

int _countOverlap(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final sb = b.toSet();
  int c = 0;
  for (final x in a) {
    if (sb.contains(x)) c++;
  }
  return c;
}

List<int> _bestKnownNameSpanInLine(
    List<String> tokens,
    List<List<String>> knownNameTokenLists,
    Set<String> ignoredTokens,
    Set<String> currencyTokens,
    ) {
  List<int> best = const [];
  int bestScore = 0;

  for (int i = 0; i < tokens.length; i++) {
    final span = _collectBidirectionalNameSpan(
      tokens,
      i,
      ignoredTokens,
      currencyTokens,
    );

    if (span.isEmpty) continue;

    final spanTokens = span.map((idx) => tokens[idx]).toList();

    for (final known in knownNameTokenLists) {
      final overlap = _countOverlap(spanTokens, known);

      // نريد على الأقل كلمة مشتركة قوية
      if (overlap <= 0) continue;

      // شجّع التطابق الأقوى
      int score = overlap * 10;

      // شجّع إذا كان الاسم الناتج ليس طويلًا جدًا
      final extra = spanTokens.length - overlap;
      score -= extra;

      if (score > bestScore) {
        bestScore = score;
        best = span;
      }
    }
  }

  return best;
}


/// ابحث عن sequence متطابق exact داخل التوكنات
int _findExactSequenceStart(List<String> tokens, List<String> pattern) {
  if (tokens.isEmpty || pattern.isEmpty) return -1;
  if (pattern.length > tokens.length) return -1;

  for (int i = 0; i <= tokens.length - pattern.length; i++) {
    bool ok = true;
    for (int j = 0; j < pattern.length; j++) {
      if (tokens[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

List<List<ForwardToken>> _buildRemainingTokens({
  required List<String> lines,
  required Map<int, List<int>> nameTokensByLine,
  required Set<String> ignoredSet,
  required Set<String> lineIgnoredSet,
}) {
  final result = <List<ForwardToken>>[];

  for (int li = 0; li < lines.length; li++) {
    final rawLine = lines[li];
    final tokens = _tokensFromLine(rawLine);

    if (tokens.isEmpty) {
      result.add(const []);
      continue;
    }

    if (_shouldIgnoreWholeLine(rawLine, tokens, lineIgnoredSet)) {
      result.add(const []);
      continue;
    }

    final removedNameIdx = (nameTokensByLine[li] ?? const <int>[]).toSet();
    final row = <ForwardToken>[];

    for (int ti = 0; ti < tokens.length; ti++) {
      final token = tokens[ti];

      // احذف الاسم
      if (removedNameIdx.contains(ti)) continue;

      // احذف الكلمات المتجاهلة exact
      if (_isIgnoredExact(token, ignoredSet)) continue;

      // احذف أي توكن هاتف واضح
      if (_isPhoneWord(token)) continue;
      if (_isPhoneLikeToken(token)) continue;

      row.add(
        ForwardToken(
          token: token,
          original: TokenRef(li, ti),
        ),
      );
    }

    result.add(row);
  }

  return result;
}

class NameDetector {
  static NameDetectResult detect({
    required List<String> lines,
    required String senderName,
    required List<String> nameKeywords,
    List<String> knownNames = const [],
    List<String> ignoredWords = const [],
    List<String> lineIgnoredWords = const [],
    List<String> currencyWords = const [],
  }) {
    final map = <int, List<int>>{};

    final ignoredSet = ignoredWords
        .map(_cleanToken)
        .where((w) => w.isNotEmpty)
        .toSet();

    final currencySet = currencyWords
        .map(_cleanToken)
        .where((w) => w.isNotEmpty)
        .toSet();

    final lineIgnoredSet = lineIgnoredWords
        .map(_cleanToken)
        .where((w) => w.isNotEmpty)
        .toSet();


    final nameKeywordSet = nameKeywords
        .map(_cleanToken)
        .where((w) => w.isNotEmpty)
        .toSet();

    final senderTokens = _tokensFromLine(senderName);
    double confidence = 0.0;

    NameDetectResult done(double conf) {
      return NameDetectResult(
        tokensByLine: Map<int, List<int>>.from(map),
        confidence: conf,
        remainingTokensByLine: _buildRemainingTokens(
          lines: lines,
          nameTokensByLine: map,
          ignoredSet: ignoredSet,
          lineIgnoredSet: lineIgnoredSet,
        ),
      );
    }
    // ===== 1) مطابقة exact للاسم القادم من الهيدر كـ sequence =====
    if (senderTokens.isNotEmpty) {
      for (int li = 0; li < lines.length; li++) {
        final rawLine = lines[li];
        if (_shouldSkipLineForNameDetection(rawLine, lineIgnoredSet)) continue;

        final tokens = _tokensFromLine(rawLine);
        if (tokens.isEmpty) continue;

        final start = _findExactSequenceStart(tokens, senderTokens);
        if (start >= 0) {
          final span = <int>[];
          for (int i = 0; i < senderTokens.length; i++) {
            final idx = start + i;
            if (idx < tokens.length &&
                _isNameToken(tokens[idx], ignoredSet, currencySet)) {
              span.add(idx);
            }
          }
          if (span.isNotEmpty) {
            map[li] = span;
            confidence = 1.0;
            return done(confidence);
          }
        }
      }
    }

    // ===== 2) كلمات مفتاحية exact token فقط =====
    final keywordTokens = nameKeywords
        .map(_cleanToken)
        .where((w) => w.isNotEmpty)
        .toList();

    for (int li = 0; li < lines.length; li++) {
      final rawLine = lines[li];
      if (_shouldSkipLineForNameDetection(rawLine, lineIgnoredSet)) continue;

      final tokens = _tokensFromLine(rawLine);
      if (tokens.isEmpty) continue;

      for (final k in keywordTokens) {
        final keywordIndex = tokens.indexOf(k);
        if (keywordIndex < 0) continue;

        final startIndex = keywordIndex + 1;
        if (startIndex >= tokens.length) continue;

        final span = _collectNameSpan(
          tokens,
          startIndex,
          ignoredSet,
          currencySet,
        );

        if (span.isNotEmpty) {
          map[li] = span;
          confidence = 0.92;
          return done(confidence);
        }
      }
    }

    // ===== 3) مطابقة جزئية محسوبة على أجزاء senderName ولكن exact token =====
    if (senderTokens.isNotEmpty) {
      final senderParts = senderTokens.where((e) => e.length >= 2).toSet();

      for (int li = 0; li < lines.length; li++) {
        final rawLine = lines[li];
        if (_shouldSkipLineForNameDetection(rawLine, lineIgnoredSet)) continue;

        final tokens = _tokensFromLine(rawLine);
        if (tokens.isEmpty) continue;

        final hitIndex = tokens.indexWhere(
              (t) => senderParts.contains(t) && _isNameToken(t, ignoredSet, currencySet),
        );

        if (hitIndex >= 0) {
          var span = _collectBidirectionalNameSpan(
            tokens,
            hitIndex,
            ignoredSet,
            currencySet,
          );

          span = _trimForbiddenEdgesFromSpan(
            span,
            tokens,
            ignoredSet,
            lineIgnoredSet,
            currencySet,
            nameKeywordSet,
          );

          if (span.isNotEmpty &&
              !_hasBlockedWordBeforeSpan(
                span,
                tokens,
                ignoredSet,
                lineIgnoredSet,
                currencySet,
                nameKeywordSet,
              )) {
            map[li] = span;
            confidence = 0.72;
            return done(confidence);
          }
        }
      }
    }

    // ===== 4) الاستفادة من knownNames بشكل أذكى =====
    final knownNameTokenLists = knownNames
        .map(_tokensFromLine)
        .where((lst) => lst.isNotEmpty)
        .toList();

    if (knownNameTokenLists.isNotEmpty) {
      for (int li = 0; li < lines.length; li++) {
        final rawLine = lines[li];
        if (_shouldSkipLineForNameDetection(rawLine, lineIgnoredSet)) continue;

        final tokens = _tokensFromLine(rawLine);
        if (tokens.isEmpty) continue;

        var span = _bestKnownNameSpanInLine(
          tokens,
          knownNameTokenLists,
          ignoredSet,
          currencySet,
        );

        span = _trimForbiddenEdgesFromSpan(
          span,
          tokens,
          ignoredSet,
          lineIgnoredSet,
          currencySet,
          nameKeywordSet,
        );

        if (span.isNotEmpty &&
            !_hasBlockedWordBeforeSpan(
              span,
              tokens,
              ignoredSet,
              lineIgnoredSet,
              currencySet,
              nameKeywordSet,
            )) {
          map[li] = span;
          confidence = 0.86;
          return done(confidence);
        }
      }
    }

    // ===== 5) fallback =====


    return done(confidence == 0.0 ? 0.0 : confidence);
  }
}