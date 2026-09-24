// lib/screens/bubble_screen.dart — نسخة مُحسّنة تدعم عدّة ملفات وتراعي الإعدادات بالكامل
import 'package:flutter/material.dart';
import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import '../database_service.dart';
import '../models.dart';
import 'add_edit_transaction_screen.dart';

// خدمات الكشف
import '../services/detection/name_detector.dart' as nd;
import '../services/detection/amount_detector.dart' as ad;
import '../services/detection/currency_detector.dart' as cd;

/// مراحل التحديد
enum SelectionStage { name, amount, currency, done }

enum BubbleActionMode { add, cancel }

/// مقطع واحد بين هيدر واتساب والهيدر التالي
class ParsedSegment {
  final String header; // مثال: [27/10, 13:46] a:
  final String senderName; // الاسم بعد الهيدر
  final DateTime? timestamp;
  final List<String> lines; // نص متعدد الأسطر كما هو

  ParsedSegment({
    required this.header,
    required this.senderName,
    required this.timestamp,
    required this.lines,
  });
}

class _ForwardLine {
  final List<String> tokens;
  final List<_TokPos> originals;

  const _ForwardLine({required this.tokens, required this.originals});

  String get text => tokens.join(' ');
}

class BubbleScreen extends StatefulWidget {
  final Account account;

  /// نص واحد كما في السلوك القديم (اختياري الآن)
  final String? rawText;

  /// محتويات عدّة ملفات (كل عنصر = محتوى ملف كامل)
  final List<String>? fileTexts;

  const BubbleScreen({
    super.key,
    required this.account,
    this.rawText,
    this.fileTexts,
  });

  @override
  State<BubbleScreen> createState() => _BubbleScreenState();
}

class _BubbleScreenState extends State<BubbleScreen> {
  // ====== لوحة ألوان عصرية ======
  static const _gradStart = Color(0xFF3F51B5); // indigo 500
  static const _gradEnd = Color(0xFF26A69A); // teal 400
  static const _chipIndigo = Color(0xFF5C6BC0); // indigo 400
  static const _chipTeal = Color(0xFFF08006); // teal 400
  static const _chipBlue = Color(0xFF42A5F5); // blue 400
  static const _chipYellow = Color(0xFFF0C100); // amber 700
  static const _chipRed = Color(0xFFE53935); // red 600
  static const _chipGreen = Color(0xFF43A047); // green 600

  // المقاطع
  late List<ParsedSegment> _segments;

  // الإعدادات
  late Settings _settings;
  late List<String> _nameKeywords;
  late List<String> _amountKeywords;
  late Map<String, String> _currencyMap; // مفتاح=اختصار/رمز، قيمة=اسم
  late List<String> _ignored;
  late List<String> _lineIgnored;
  late List<String> _cancelKeywords;
  late Map<String, double> _amountWordValues;
  late List<String> _bubbleReadyNames;
  late List<String> _companyUserNames;
  late List<BubbleQuickActionConfig> _bubbleQuickActions;
  late List<TransactionModel> _allTransactions;
  late Map<int, String> _accountNamesById;
  late List<String> _knownBeneficiaryNames;

  // اقتراحات تعلّم (من كاشف العملة)
  final Set<String> _suggestCurrencySymbols = {};
  final Set<String> _suggestCurrencyNames = {};

  // تحديدات
  final List<_SegmentSelection> _selections = [];
  final Map<int, BubbleActionMode> _segmentModes = {};
  final Map<int, int> _cancelSelectedTxIds = {};
  final Map<int, List<TransactionModel>> _cancelCandidatesCache = {};
  final Map<int, String> _cancelCandidateQueries = {};
  final Set<int> _cancelCandidatesLoading = {};
  final Map<int, bool> _cancelShowMore = {};
  final Map<int, CompanyMovementType> _companyMovementOverrides = {};

  // تعارض/اختيارات المبلغ
  final Map<int, double> _amountOverride = {};
  final Set<int> _amountConflict = {};
  final Map<int, double> _amountTextCandidate = {};
  final Map<int, List<double>> _amountCandidatesCache = {};

  // إدخال يدوي للاسم
  final Map<int, String> _nameOverride = {};
  BubbleActionMode _viewMode = BubbleActionMode.add;
  bool _isSending = false;
  final Set<int> _savedSegments = {};
  final Map<int, _SavedAddSummary> _savedAddSummaries = {};
  final Map<int, _CancelledSummary> _cancelledSummaries = {};

  @override
  void initState() {
    super.initState();

    _settings =
        DatabaseService.getSettings() ??
        Settings(
          nameKeywords: const ['المستفيد', 'إلى', 'ل', 'لـ'],
          amountKeywords: const ['المبلغ', 'قيمة', 'amount', '\$'],
          currencyMap: const {'\$': 'دولار'},
          ignoredWords: const [],
          lineIgnoredWords: const [],
          cancelKeywords: const ['الغاء'],
          amountWordValues: const {},
          bubbleReadyNames: const [],
          bubbleQuickActions: const [],
          companyUserNames: const [],
        );

    _nameKeywords = List.of(_settings.nameKeywords);
    _amountKeywords = List.of(_settings.amountKeywords);
    _currencyMap = Map.of(_settings.currencyMap);
    _ignored = List.of(_settings.ignoredWords);
    _lineIgnored = List.of(_settings.lineIgnoredWords);
    _cancelKeywords = List.of(_settings.cancelKeywords);
    _amountWordValues = Map.of(_settings.amountWordValues);
    _bubbleReadyNames = List.of(_settings.bubbleReadyNames);
    _companyUserNames = List.of(_settings.companyUserNames);
    _bubbleQuickActions = List.of(_settings.bubbleQuickActions);
    _allTransactions = DatabaseService.transactionsBox.values.toList();
    _accountNamesById = {
      for (final account in DatabaseService.accountsBox.values)
        account.id: account.name,
    };
    _knownBeneficiaryNames = _allTransactions
        .map((t) => t.beneficiary)
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList();

    // === دعم عدّة ملفات ===
    final texts = <String>[];
    if (widget.fileTexts != null && widget.fileTexts!.isNotEmpty) {
      texts.addAll(
        widget.fileTexts!
            .where((t) => t.trim().isNotEmpty)
            .map((t) => t.trim()),
      );
    }
    if ((widget.rawText ?? '').trim().isNotEmpty) {
      texts.add(widget.rawText!.trim());
    }

    if (texts.isEmpty) {
      _segments = [
        ParsedSegment(
          header: '',
          senderName: '',
          timestamp: null,
          lines: const [],
        ),
      ];
    } else {
      _segments = texts.expand(_splitByHeader).toList();
      // رتب المقاطع زمنيًا إن أمكن
      _segments.sort((a, b) {
        final ta = a.timestamp, tb = b.timestamp;
        if (ta == null && tb == null) return 0;
        if (ta == null) return 1;
        if (tb == null) return -1;
        return ta.compareTo(tb);
      });
    }

    // ابنِ التحديدات + فضّل نص المبلغ عند وجوده
    for (var i = 0; i < _segments.length; i++) {
      final sel = _autoDetect(_segments[i], i);
      _selections.add(sel);
      final mode = _segmentLooksLikeCancel(_segments[i])
          ? BubbleActionMode.cancel
          : BubbleActionMode.add;
      _segmentModes[i] = mode;
      if (mode == BubbleActionMode.cancel) {
        sel.stage = SelectionStage.name;
      }
    }

    final hasAdd = _segmentModes.values.any((m) => m == BubbleActionMode.add);
    _viewMode = hasAdd ? BubbleActionMode.add : BubbleActionMode.cancel;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (var i = 0; i < _segments.length; i++) {
        if (_modeOf(i) == BubbleActionMode.cancel) {
          _requestCancelCandidates(i);
        }
      }
    });
  }

  // ====== أدوات تصميم ======
  Color _onSurface(BuildContext ctx) =>
      Theme.of(ctx).colorScheme.onSurface.withOpacity(0.9);
  Color _muted(BuildContext ctx) =>
      Theme.of(ctx).colorScheme.onSurface.withOpacity(0.6);

  // ====== تطبيع عربي/مقارنات ======
  String _stripDiacritics(String s) =>
      s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');
  String _normalizeArabic(String s) {
    s = _stripDiacritics(s);
    s = s.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
    s = s.replaceAll('ى', 'ي').replaceAll('ئ', 'ي').replaceAll('ؤ', 'و');
    s = s.replaceAll('ة', 'ه');
    return s.trim();
  }

  String _normalizeForSearch(String s) =>
      _normalizeArabic(s).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  bool _segmentLooksLikeCancel(ParsedSegment seg) {
    final text = _normalizeForSearch('${seg.header}\n${seg.lines.join('\n')}');
    if (text.isEmpty) return false;

    for (final word in _cancelKeywords) {
      final normalized = _normalizeForSearch(word);
      if (normalized.isNotEmpty && text.contains(normalized)) return true;
    }
    return false;
  }

  BubbleActionMode _modeOf(int segIndex) =>
      _segmentModes[segIndex] ?? BubbleActionMode.add;

  bool get _isCompanyAccount => widget.account.type.isCompany;

  bool _isCompanyUser(String name) {
    final wanted = _normalizeForSearch(name);
    return wanted.isNotEmpty &&
        _companyUserNames.any((item) => _normalizeForSearch(item) == wanted);
  }

  CompanyMovementType _companyMovementForSegment(int segIndex) {
    return _companyMovementOverrides[segIndex] ??
        (_isCompanyUser(_segments[segIndex].senderName)
            ? CompanyMovementType.sent
            : CompanyMovementType.received);
  }

  bool _canCancel(TransactionModel tx) => _isCompanyAccount
      ? tx.companyMovementType != null && !tx.companyMovementType!.isCancelled
      : tx.status == TransactionStatus.added;

  String _movementLabel(TransactionModel tx) =>
      _isCompanyAccount && tx.companyMovementType != null
      ? tx.companyMovementType!.label
      : _txStatusLabel(tx.status);

  void _setSegmentMode(int segIndex, BubbleActionMode mode) {
    setState(() {
      _segmentModes[segIndex] = mode;
      _invalidateCancelCandidates(segIndex);
      if (mode == BubbleActionMode.cancel) {
        _selections[segIndex].stage = SelectionStage.name;
      } else {
        _refreshStageForSegment(segIndex);
      }
    });
    if (mode == BubbleActionMode.cancel) {
      _requestCancelCandidates(segIndex);
    }
  }

  List<String> _nameWords(String value) => _normalizeForSearch(
    value,
  ).split(' ').where((word) => word.trim().isNotEmpty).toList();

  int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final curr = List<int>.filled(b.length + 1, 0);
      curr[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        curr[j + 1] = [
          curr[j] + 1,
          prev[j + 1] + 1,
          prev[j] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      prev = curr;
    }
    return prev.last;
  }

  bool _similarNameWord(String a, String b) {
    if (a == b) return true;
    final minLen = a.length < b.length ? a.length : b.length;
    if (minLen < 3) return false;
    final maxDistance = minLen >= 7 ? 2 : 1;
    return _levenshtein(a, b) <= maxDistance;
  }

  double _cancelNameScore(TransactionModel tx, String name) {
    final wanted = _normalizeForSearch(name);
    final candidate = _normalizeForSearch(tx.beneficiary);
    if (wanted.isEmpty || candidate.isEmpty) return -1;
    if (wanted == candidate) return 1;

    final wantedWords = _nameWords(wanted);
    final candidateWords = _nameWords(candidate);
    if (wantedWords.isEmpty || candidateWords.isEmpty) return -1;
    if (candidateWords.length < (wantedWords.length >= 3 ? 2 : 1)) return -1;
    if ((candidateWords.length - wantedWords.length).abs() > 1) return -1;

    final used = <int>{};
    var matches = 0;
    for (final wantedWord in wantedWords) {
      for (var i = 0; i < candidateWords.length; i++) {
        if (used.contains(i)) continue;
        if (_similarNameWord(wantedWord, candidateWords[i])) {
          used.add(i);
          matches++;
          break;
        }
      }
    }

    final requiredMatches = wantedWords.length <= 2
        ? wantedWords.length
        : wantedWords.length - 1;
    if (matches < requiredMatches) return -1;
    return matches / wantedWords.length;
  }

  bool _isExactCancelMatch(TransactionModel tx, String name) =>
      _normalizeForSearch(tx.beneficiary) == _normalizeForSearch(name);

  List<TransactionModel> _computeCancelCandidates(String name) {
    final scored = <({TransactionModel tx, double score})>[];
    for (final tx in _allTransactions) {
      if (tx.accountId != widget.account.id) continue;
      if (_isCompanyAccount &&
          (tx.companyMovementType == null ||
              tx.companyMovementType!.isCancelled)) {
        continue;
      }
      final score = _cancelNameScore(tx, name);
      if (score >= 0) scored.add((tx: tx, score: score));
    }

    scored.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) return scoreCompare;

      int statusRank(TransactionStatus status) {
        switch (status) {
          case TransactionStatus.added:
            return 0;
          case TransactionStatus.received:
            return 1;
          case TransactionStatus.cancelled:
            return 2;
        }
      }

      final statusCompare = statusRank(
        a.tx.status,
      ).compareTo(statusRank(b.tx.status));
      if (statusCompare != 0) return statusCompare;
      return b.tx.date.compareTo(a.tx.date);
    });

    return scored.map((e) => e.tx).toList();
  }

  String _cancelQueryForSegment(int segIndex) => _normalizeForSearch(
    _buildSelectedName(_segments[segIndex], _selections[segIndex], segIndex),
  );

  void _invalidateCancelCandidates(int segIndex) {
    _cancelCandidatesCache.remove(segIndex);
    _cancelCandidateQueries.remove(segIndex);
    _cancelCandidatesLoading.remove(segIndex);
    _cancelSelectedTxIds.remove(segIndex);
    _cancelShowMore.remove(segIndex);
  }

  List<TransactionModel> _cancelCandidatesForSegment(int segIndex) {
    final query = _cancelQueryForSegment(segIndex);
    if (query.isEmpty) return const [];
    if (_cancelCandidateQueries[segIndex] != query) return const [];
    return _cancelCandidatesCache[segIndex] ?? const [];
  }

  void _requestCancelCandidates(int segIndex) {
    if (!mounted || _modeOf(segIndex) != BubbleActionMode.cancel) return;
    final name = _buildSelectedName(
      _segments[segIndex],
      _selections[segIndex],
      segIndex,
    ).trim();
    final query = _normalizeForSearch(name);
    if (query.isEmpty) return;
    if (_cancelCandidatesLoading.contains(segIndex) &&
        _cancelCandidateQueries[segIndex] == query) {
      return;
    }
    if (_cancelCandidatesCache.containsKey(segIndex) &&
        _cancelCandidateQueries[segIndex] == query) {
      return;
    }

    setState(() {
      _cancelCandidatesLoading.add(segIndex);
      _cancelCandidateQueries[segIndex] = query;
    });

    Future<List<TransactionModel>>.delayed(
      Duration.zero,
      () => _computeCancelCandidates(name),
    ).then((candidates) {
      if (!mounted) return;
      final currentQuery = _cancelQueryForSegment(segIndex);
      if (currentQuery != query) return;
      setState(() {
        _cancelCandidatesLoading.remove(segIndex);
        _cancelCandidateQueries[segIndex] = query;
        _cancelCandidatesCache[segIndex] = candidates;
      });
    });
  }

  bool _eqCur(String a, String b) {
    final aa = _normalizeArabic(a).toUpperCase();
    final bb = _normalizeArabic(b).toUpperCase();
    return aa == bb;
  }

  Settings _getSettingsOrDefault() {
    return DatabaseService.getSettings() ??
        Settings(
          nameKeywords: const ["المستفيد"],
          amountKeywords: const ["المبلغ", "\$"],
          currencyMap: const {"\$": "دولار"},
          ignoredWords: const [],
        );
  }

  bool _isKnownCurrencyToken(Settings s, String token) {
    if (token.isEmpty) return false;
    for (final k in s.currencyMap.keys) {
      if (_eqCur(k, token)) return true;
    }
    for (final v in s.currencyMap.values) {
      if (_eqCur(v, token)) return true;
    }
    return false;
  }

  /// إن كان token اسمًا يعيد رمزه، وإن كان رمزًا يعيده كما هو، وإلا null
  String? _mapTokenToCurrencyKey(Settings s, String token) {
    for (final k in s.currencyMap.keys) {
      if (_eqCur(k, token)) return k;
    }
    for (final e in s.currencyMap.entries) {
      if (_eqCur(e.value, token)) return e.key;
    }
    return null;
  }

  // يحوّل أي توكن (رمز/اختصار/اسم) إلى "اسم العملة" النهائي للتخزين/العرض
  String? _currencyNameForToken(String token) {
    final s = _getSettingsOrDefault();

    // 1) لو التوكن يطابق مفتاح/اختصار معروف → رجّع الاسم المقابل من الخريطة
    final key = _mapTokenToCurrencyKey(s, token);
    if (key != null) return s.currencyMap[key];

    // 2) لو التوكن أصلاً اسم معروف (قيمة ضمن الخريطة) → رجّعه كما هو
    for (final name in s.currencyMap.values) {
      if (_eqCur(name, token)) return name;
    }

    // 3) غير معروف
    return null;
  }

  // ====== تقسيم النص حسب هيدر واتساب ======
  final _headerRe = RegExp(
    r'\[\s*([0-9\u0660-\u0669]{1,2})\/[\u200F\u200E]?\s*([0-9\u0660-\u0669]{1,2})\s*[,،]\s*([0-9\u0660-\u0669]{1,2})\s*:\s*([0-9\u0660-\u0669]{2})\s*\]\s*([^:\n]+?)\s*:',
    multiLine: true,
  );

  List<ParsedSegment> _splitByHeader(String input) {
    final text = input.replaceAll('\r', '');
    final matches = _headerRe.allMatches(text).toList();
    final segments = <ParsedSegment>[];

    if (matches.isEmpty) {
      final lines = text.split('\n').map((e) => e.trimRight()).toList();
      segments.add(
        ParsedSegment(
          header: '',
          senderName: '',
          timestamp: null,
          lines: lines,
        ),
      );
      return segments;
    }

    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final start = m.end;
      final end = (i + 1 < matches.length) ? matches[i + 1].start : text.length;
      final body = text.substring(start, end);

      final dd = _toIntDigits(m.group(1)!);
      final MM = _toIntDigits(m.group(2)!);
      final hh = _toIntDigits(m.group(3)!);
      final mm = _toIntDigits(m.group(4)!);
      final name = m.group(5)!.trim();

      DateTime? ts;
      try {
        final now = DateTime.now();
        ts = DateTime(now.year, MM, dd, hh, mm);
      } catch (_) {}

      final lines = body.split('\n').map((e) => e.trimRight()).toList();

      segments.add(
        ParsedSegment(
          header: m.group(0)!.trim(),
          senderName: name,
          timestamp: ts,
          lines: lines,
        ),
      );
    }

    return segments;
  }

  int _toIntDigits(String s) {
    final buf = StringBuffer();
    for (final ch in s.characters) {
      final code = ch.codeUnitAt(0);
      if (code >= 0x0660 && code <= 0x0669) {
        buf.write(String.fromCharCode('0'.codeUnitAt(0) + (code - 0x0660)));
      } else {
        buf.write(ch);
      }
    }
    return int.tryParse(buf.toString()) ?? 0;
  }

  // ====== تنظيف التوكنات (مع حذف الرموز بين الأرقام المتتالية) ======
  bool _isAsciiDigit(int code) => code >= 0x30 && code <= 0x39;
  bool _isArabicDigit(int code) => code >= 0x0660 && code <= 0x0669;
  bool _isDigitCode(int code) => _isAsciiDigit(code) || _isArabicDigit(code);

  String _squashDigitSeparators(String w) {
    if (w.isEmpty) return w;
    final sep = RegExp(r'[.,،\-\_\u0640\u066B\u066C]'); // . , ، - _ ـ ٫ ٬
    final out = StringBuffer();
    for (int i = 0; i < w.length; i++) {
      final ch = w[i];
      if (sep.hasMatch(ch)) {
        final prev = (i > 0) ? w.codeUnitAt(i - 1) : null;
        final next = (i + 1 < w.length) ? w.codeUnitAt(i + 1) : null;
        if (prev != null &&
            next != null &&
            _isDigitCode(prev) &&
            _isDigitCode(next)) {
          // احذف الفاصل بين الأرقام
          continue;
        }
      }
      out.write(ch);
    }
    return out.toString();
  }

  String _cleanToken(String w) {
    final trimmed = w
        .replaceAll(RegExp(r'[^\u0600-\u06FFa-zA-Z0-9\$€£﷼٫\.,\-_\/\+]'), '')
        .trim();
    return _squashDigitSeparators(trimmed);
  }

  List<String> _tokensFromLine(String line) => line
      .split(RegExp(r'\s+'))
      .map(_cleanToken)
      .where((w) => w.isNotEmpty)
      .toList();

  // ====== Helpers خاصة بكلمات "المبلغ" ======
  bool _isAmountKeywordToken(String token) {
    final t = _normalizeArabic(token);
    for (final k in _amountKeywords) {
      if (_normalizeArabic(k) == t) return true;
    }
    return false;
  }

  /// يحاول التقاط المبلغ مباشرة بعد كلمة من كلمات المبلغ (المبلغ: 123 ...)
  double? _findAmountRightAfterKeyword(
    List<String> lines, {
    int lookahead = 3,
  }) {
    for (int li = 0; li < lines.length; li++) {
      final toks = _tokensFromLine(lines[li]);
      for (int ti = 0; ti < toks.length; ti++) {
        if (_isAmountKeywordToken(toks[ti])) {
          for (int k = 1; k <= lookahead && (ti + k) < toks.length; k++) {
            final v = ad.AmountDetector.parseAmountToken(toks[ti + k]);
            if (v != null && v > 0) return v;
          }
        }
      }
    }
    return null;
  }

  // ====== اكتشاف "شبه هاتف" ======
  String _digitsOnly(String s) {
    final b = StringBuffer();
    for (final ch in s.characters) {
      final code = ch.codeUnitAt(0);
      if (_isAsciiDigit(code)) {
        b.write(ch);
      } else if (_isArabicDigit(code)) {
        b.write(String.fromCharCode('0'.codeUnitAt(0) + (code - 0x0660)));
      }
    }
    return b.toString();
  }

  bool _startsLikePhone(String raw, String digits) {
    final t = raw.trim();
    if (digits.isEmpty) return false;

    if (t.startsWith('+')) return true;
    if (digits.startsWith('0')) return true;

    return false;
  }

  bool _isPhoneLike(String token) {
    final raw = token.trim();
    final d = _digitsOnly(raw);

    if (d.length < 9 || d.length > 14) return false;

    return _startsLikePhone(raw, d);
  }

  // ====== كلمات تُعدّ مصدرًا لنص مبلغ لفظي (نقفلها) ======
  static const Set<String> _textNumberWords = {
    // أعداد أساسية
    'صفر',
    'واحد',
    'واحده',
    'واحدة',
    'اثنين',
    'اثنان',
    'اثنتان',
    'ثلاث',
    'ثلاثه',
    'ثلاثة',
    'اربع',
    'اربعه',
    'أربع',
    'أربعة',
    'خمس',
    'خمسه',
    'خمسة',
    'ست',
    'سته',
    'ستة',
    'سبع',
    'سبعه',
    'سبعة',
    'ثمان',
    'ثماني',
    'ثمانيه',
    'ثمانية',
    'تسع',
    'تسعه',
    'تسعة',
    'عشر',
    'عشره',
    'عشرة',
    'أحد',
    'إحدى',
    'احدى',
    // عشرات/مئات/آلاف/ملايين/مليارات
    'عشرين',
    'ثلاثين',
    'اربعين',
    'أربعين',
    'خمسين',
    'ستين',
    'سبعين',
    'ثمانين',
    'تسعين',
    'مائه', 'مئة', 'مائتين', 'مئتان', 'مئه', 'مئتين',
    'الف', 'ألف', 'آلاف', 'الفين', 'ألفين',
    'مليون', 'ملايين', 'مليونين',
    'مليار', 'مليارات', 'مليارين',
    // صيغ شائعة
    'و', 'نصف', 'ثلث', 'ربع',
  };

  Set<_TokPos> _lockTextualAmountTokens(List<String> lines) {
    final locked = <_TokPos>{};
    for (int li = 0; li < lines.length; li++) {
      final toks = _tokensFromLine(lines[li]);
      for (int ti = 0; ti < toks.length; ti++) {
        final tok = toks[ti];
        final norm = _normalizeArabic(tok);
        final isLettersOnly = RegExp(r'^[\u0600-\u06FF]+$').hasMatch(norm);
        final isDigitsOnly = RegExp(r'^[0-9\u0660-\u0669]+$').hasMatch(tok);
        if (isLettersOnly && _textNumberWords.contains(norm)) {
          locked.add(_TokPos(li, ti));
          if (ti - 1 >= 0) {
            final prev = toks[ti - 1];
            if (RegExp(r'^[0-9\u0660-\u0669]+$').hasMatch(prev))
              locked.add(_TokPos(li, ti - 1));
          }
          if (ti + 1 < toks.length) {
            final next = toks[ti + 1];
            if (RegExp(r'^[0-9\u0660-\u0669]+$').hasMatch(next))
              locked.add(_TokPos(li, ti + 1));
          }
        } else if (!isLettersOnly && !isDigitsOnly) {
          if (RegExp(r'[0-9\u0660-\u0669]').hasMatch(tok) &&
              RegExp(r'[\u0600-\u06FF]').hasMatch(tok)) {
            locked.add(_TokPos(li, ti));
          }
        }
      }
    }
    return locked;
  }

  bool _isIgnoredWord(String token) {
    final t = _normalizeArabic(_cleanToken(token));
    if (t.isEmpty) return false;

    for (final w in _ignored) {
      final iw = _normalizeArabic(_cleanToken(w));
      if (iw == t) return true;
    }
    return false;
  }

  // ====== تجاهُل كلمات بالإعدادات ======
  Set<String> _currencyHintsFromSettings() {
    final out = <String>{};

    for (final k in _currencyMap.keys) {
      final v = _cleanToken(k);
      if (v.isNotEmpty) out.add(v);
    }

    for (final v0 in _currencyMap.values) {
      final v = _cleanToken(v0);
      if (v.isNotEmpty) out.add(v);
    }

    return out;
  }

  String _stripDetectedCurrency(String token) {
    String t = _cleanToken(token);
    if (t.isEmpty) return '';

    final patterns =
        <String>{
            ..._currencyMap.keys.map(_cleanToken),
            ..._currencyMap.values.map(_cleanToken),
          }.where((e) => e.isNotEmpty).toList()
          ..sort((a, b) => b.length.compareTo(a.length));

    for (final p in patterns) {
      if (t == p) return '';

      if (_digitsOnly(t).isNotEmpty) {
        if (t.startsWith(p)) {
          final rest = t.substring(p.length);
          if (_digitsOnly(rest).isNotEmpty) return rest;
        }
        if (t.endsWith(p)) {
          final rest = t.substring(0, t.length - p.length);
          if (_digitsOnly(rest).isNotEmpty) return rest;
        }
      }
    }

    t = t.replaceAll(RegExp(r'^[\$€£﷼₺]+'), '');
    t = t.replaceAll(RegExp(r'[\$€£﷼₺]+$'), '');
    return t.trim();
  }

  String _stripDetectedAmount(String token) {
    String t = _cleanToken(token);
    if (t.isEmpty) return '';

    final s = _getSettingsOrDefault();

    // إذا التوكن نفسه عملة معروفة من الإعدادات، لا تلمسه
    if (_isKnownCurrencyToken(s, t)) return t;

    // احذف الجزء الرقمي من البداية
    t = t
        .replaceFirst(
          RegExp(r'^[+\-]?[0-9\u0660-\u0669][0-9\u0660-\u0669,.\u066B\u066C]*'),
          '',
        )
        .trim();

    // إذا صار الباقي يطابق عملة معروفة، أبقه كما هو
    if (t.isNotEmpty && _isKnownCurrencyToken(s, t)) return t;

    // احذف وحدات المبلغ فقط إذا لم تكن عملة معروفة في الإعدادات
    t = t
        .replaceFirst(
          RegExp(r'^(الف|الاف|ألف|آلاف|مليون|ملايين|مليار|مليارات|طن|طون)'),
          '',
        )
        .trim();

    // تحقق مرة أخيرة
    if (t.isNotEmpty && _isKnownCurrencyToken(s, t)) return t;

    return _cleanToken(t).trim();
  }

  List<_ForwardLine> _buildForwardLinesForCurrency(
    ParsedSegment seg,
    _SegmentSelection sel,
  ) {
    final rows = <_ForwardLine>[];

    for (int li = 0; li < seg.lines.length; li++) {
      final rawLine = seg.lines[li];
      final toks = _tokensFromLine(rawLine);

      if (rawLine.contains('+') || rawLine.contains('#')) {
        rows.add(const _ForwardLine(tokens: [], originals: []));
        continue;
      }

      final keptTokens = <String>[];
      final keptOriginals = <_TokPos>[];

      for (int ti = 0; ti < toks.length; ti++) {
        String tok = toks[ti];
        final pos = _TokPos(li, ti);

        if (sel.nameTokens.contains(pos)) continue;
        if (sel.phoneLikeTokens.contains(pos)) continue;
        if (_isPhoneLike(tok)) continue;
        if (_isIgnoredWord(tok)) continue;

        // إذا هذا هو التوكن الذي اعتبرناه مبلغًا، انزع منه المبلغ
        // لكن اترك أي alias للعملة إذا كان معروفًا في الإعدادات
        if (sel.amount == pos) {
          tok = _stripDetectedAmount(tok);
          tok = _cleanToken(tok);
          if (tok.isEmpty) continue;
        }

        keptTokens.add(tok);
        keptOriginals.add(pos);
      }

      rows.add(_ForwardLine(tokens: keptTokens, originals: keptOriginals));
    }

    return rows;
  }

  List<_ForwardLine> _buildForwardLinesForAmount(
    ParsedSegment seg,
    _SegmentSelection sel,
  ) {
    final rows = <_ForwardLine>[];

    for (int li = 0; li < seg.lines.length; li++) {
      final rawLine = seg.lines[li];
      final toks = _tokensFromLine(rawLine);

      if (rawLine.contains('+') || rawLine.contains('#')) {
        rows.add(const _ForwardLine(tokens: [], originals: []));
        continue;
      }

      final keptTokens = <String>[];
      final keptOriginals = <_TokPos>[];

      for (int ti = 0; ti < toks.length; ti++) {
        final pos = _TokPos(li, ti);
        String tok = toks[ti];

        if (sel.nameTokens.contains(pos)) continue;
        if (sel.phoneLikeTokens.contains(pos)) continue;
        if (_isPhoneLike(tok)) continue;
        if (_isIgnoredWord(tok)) continue;

        if (sel.currencyToken == pos) {
          tok = _stripDetectedCurrency(tok);
          tok = _cleanToken(tok);
          if (tok.isEmpty) continue;
        }

        keptTokens.add(tok);
        keptOriginals.add(pos);
      }

      rows.add(_ForwardLine(tokens: keptTokens, originals: keptOriginals));
    }

    return rows;
  }

  void _refreshStageForSegment(int segIndex) {
    final sel = _selections[segIndex];

    if (_modeOf(segIndex) == BubbleActionMode.cancel) {
      sel.stage = SelectionStage.name;
      return;
    }

    if (!_hasNameFor(segIndex, sel)) {
      sel.stage = SelectionStage.name;
    } else if (!_hasAmountFor(segIndex, sel)) {
      sel.stage = SelectionStage.amount;
    } else if (sel.currencyToken == null && sel.currencyFromMenu == null) {
      sel.stage = SelectionStage.currency;
    } else {
      sel.stage = SelectionStage.done;
    }
  }

  Future<void> _detectAmountFromTappedLine(
    int segIndex,
    int lineIndex,
    List<String> tokensThisLine,
  ) async {
    final seg = _segments[segIndex];
    final sel = _selections[segIndex];

    final originalLine = seg.lines[lineIndex];

    final keptTokens = <String>[];
    final keptOriginals = <_TokPos>[];

    if (!originalLine.contains('+') && !originalLine.contains('#')) {
      for (int ti = 0; ti < tokensThisLine.length; ti++) {
        final pos = _TokPos(lineIndex, ti);
        String tok = tokensThisLine[ti];

        if (sel.nameTokens.contains(pos)) continue;
        if (sel.phoneLikeTokens.contains(pos)) continue;
        if (_isPhoneLike(tok)) continue;
        if (_isIgnoredWord(tok)) continue;

        if (sel.currencyToken == pos) {
          tok = _stripDetectedCurrency(tok);
          tok = _cleanToken(tok);
          if (tok.isEmpty) continue;
        }

        keptTokens.add(tok);
        keptOriginals.add(pos);
      }
    }

    final amtRes = ad.AmountDetector.detect(
      [keptTokens.join(' ')],
      currencyHints: _currencyHintsFromSettings(),
      conflictThreshold: 0.35,
      customWordValues: _amountWordValues,
    );

    if (!mounted) return;

    setState(() {
      sel.amount = null;
      _amountOverride.remove(segIndex);
      _amountConflict.remove(segIndex);
      _amountTextCandidate.remove(segIndex);
      _amountCandidatesCache.remove(segIndex);

      if (amtRes.textValue != null) {
        _amountTextCandidate[segIndex] = amtRes.textValue!;
      }

      if (amtRes.numericValue != null && amtRes.numericValue! > 0) {
        _amountOverride[segIndex] = amtRes.numericValue!;
      }

      if (amtRes.numericPos != null &&
          amtRes.numericPos!.x == 0 &&
          amtRes.numericPos!.y >= 0 &&
          amtRes.numericPos!.y < keptOriginals.length) {
        sel.amount = keptOriginals[amtRes.numericPos!.y];
      }

      if (amtRes.hasConflict) {
        _amountConflict.add(segIndex);
      }

      _refreshStageForSegment(segIndex);
    });

    if (amtRes.numericValue == null && amtRes.textValue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لم يتم العثور على مبلغ واضح في هذا السطر'),
        ),
      );
    }
  }

  // ====== التعرّف الآلي ======
  _SegmentSelection _autoDetect(ParsedSegment seg, int segIndex) {
    final sel = _SegmentSelection(stage: SelectionStage.name);

    // 1) تعليم أرقام الهاتف
    for (int li = 0; li < seg.lines.length; li++) {
      final toks = _tokensFromLine(seg.lines[li]);
      for (int ti = 0; ti < toks.length; ti++) {
        if (_isPhoneLike(toks[ti])) {
          sel.phoneLikeTokens.add(_TokPos(li, ti));
        }
      }
    }

    // 2) قفل كلمات المبلغ النصّي
    sel.amountTextLockedTokens.addAll(_lockTextualAmountTokens(seg.lines));

    // 3) الاسم
    final nameRes = nd.NameDetector.detect(
      lines: seg.lines,
      senderName: seg.senderName,
      nameKeywords: _nameKeywords,
      knownNames: _knownBeneficiaryNames,
      ignoredWords: _ignored,
      lineIgnoredWords: _lineIgnored,
      currencyWords: [..._currencyMap.keys, ..._currencyMap.values],
    );

    nameRes.tokensByLine.forEach((li, idxs) {
      final toks = _tokensFromLine(seg.lines[li]);
      for (final ti in idxs) {
        if (ti >= 0 && ti < toks.length && !_isIgnoredWord(toks[ti])) {
          sel.nameTokens.add(_TokPos(li, ti));
        }
      }
    });

    // 5) المبلغ على النص المنظف
    final amountForward = _buildForwardLinesForAmount(seg, sel);

    final amtRes = ad.AmountDetector.detect(
      amountForward.map((e) => e.text).toList(),
      currencyHints: _currencyHintsFromSettings(),
      conflictThreshold: 0.35,
      customWordValues: _amountWordValues,
    );

    if (amtRes.textValue != null) {
      _amountTextCandidate[segIndex] = amtRes.textValue!;
    }

    if (amtRes.numericValue != null && amtRes.numericValue! > 0) {
      _amountOverride[segIndex] = amtRes.numericValue!;
    }

    if (amtRes.numericPos != null &&
        amtRes.numericPos!.x >= 0 &&
        amtRes.numericPos!.x < amountForward.length) {
      final row = amountForward[amtRes.numericPos!.x];
      if (amtRes.numericPos!.y >= 0 &&
          amtRes.numericPos!.y < row.originals.length) {
        final p = row.originals[amtRes.numericPos!.y];
        if (!sel.phoneLikeTokens.contains(p)) {
          sel.amount = p;
        }
      }
    }

    if (amtRes.hasConflict) {
      _amountConflict.add(segIndex);
    }

    // المرحلة الحالية
    if (!_hasNameFor(segIndex, sel)) {
      sel.stage = SelectionStage.name;
    } else if (!_hasAmountFor(segIndex, sel)) {
      sel.stage = SelectionStage.amount;
    } else if (sel.currencyToken == null && sel.currencyFromMenu == null) {
      sel.stage = SelectionStage.currency;
    } else {
      sel.stage = SelectionStage.done;
    }

    // 4) العملة على النص المنظف
    final currencyForward = _buildForwardLinesForCurrency(seg, sel);

    final curRes = cd.CurrencyDetector.detect(
      lines: currencyForward.map((e) => e.text).toList(),
      currencyMap: _currencyMap,
    );

    if (curRes.pos != null &&
        curRes.pos!.x >= 0 &&
        curRes.pos!.x < currencyForward.length) {
      final row = currencyForward[curRes.pos!.x];
      if (curRes.pos!.y >= 0 && curRes.pos!.y < row.originals.length) {
        sel.currencyToken = row.originals[curRes.pos!.y];
      }
    }

    sel.currencyDetectedName = curRes.detectedDisplayName;

    if (sel.currencyDetectedName != null &&
        sel.currencyDetectedName!.trim().isNotEmpty) {
      sel.currencyFromMenu = null;
    }

    _suggestCurrencySymbols.addAll(curRes.suggestSymbols);
    _suggestCurrencyNames.addAll(curRes.suggestNames);

    _suggestCurrencySymbols.addAll(curRes.suggestSymbols);
    _suggestCurrencyNames.addAll(curRes.suggestNames);

    return sel;
  }

  bool _hasNameFor(int segIndex, _SegmentSelection sel) =>
      (_nameOverride[segIndex]?.trim().isNotEmpty ?? false) ||
      sel.nameTokens.isNotEmpty;

  bool _hasAmountFor(int segIndex, _SegmentSelection sel) {
    if (_amountOverride.containsKey(segIndex)) return true;
    if (sel.amount == null) return false;
    final seg = _segments[segIndex];
    final toks = _tokensFromLine(seg.lines[sel.amount!.line]);
    if (sel.amount!.index < 0 || sel.amount!.index >= toks.length) return false;
    final v = ad.AmountDetector.parseAmountToken(toks[sel.amount!.index]);
    return v != null && v > 0;
  }

  // ====== مرحلة/إرشاد ======
  String _stageHint(SelectionStage s) {
    switch (s) {
      case SelectionStage.name:
        return "حدد الاسم";
      case SelectionStage.amount:
        return "حدد المبلغ";
      case SelectionStage.currency:
        return "حدد العملة أو اخترها";
      case SelectionStage.done:
        return "تم التحديد";
    }
  }

  // ====== مسح ======
  void _clearSelection(int segIndex) {
    setState(() {
      final sel = _selections[segIndex];
      sel.nameTokens.clear();
      sel.amount = null;
      sel.currencyToken = null;
      sel.currencyFromMenu = null;
      sel.currencyDetectedName = null;
      _amountOverride.remove(segIndex);
      _amountConflict.remove(segIndex);
      _amountTextCandidate.remove(segIndex);
      _amountCandidatesCache.remove(segIndex);
      _nameOverride.remove(segIndex);
      _invalidateCancelCandidates(segIndex);
      sel.stage = SelectionStage.name;
    });
  }

  void _clearCategory(int segIndex, String category) {
    setState(() {
      final sel = _selections[segIndex];
      switch (category) {
        case 'name':
          sel.nameTokens.clear();
          _nameOverride.remove(segIndex);
          _invalidateCancelCandidates(segIndex);
          break;
        case 'currency':
          sel.currencyToken = null;
          sel.currencyFromMenu = null;
          sel.currencyDetectedName = null;
          break;
        case 'amount':
          sel.amount = null;
          _amountOverride.remove(segIndex);
          _amountConflict.remove(segIndex);
          _amountTextCandidate.remove(segIndex);
          _amountCandidatesCache.remove(segIndex);
          break;
      }
      if (!_hasNameFor(segIndex, sel)) {
        sel.stage = SelectionStage.name;
      } else if (!_hasAmountFor(segIndex, sel)) {
        sel.stage = SelectionStage.amount;
      } else if (sel.currencyToken == null && sel.currencyFromMenu == null) {
        sel.stage = SelectionStage.currency;
      } else {
        sel.stage = SelectionStage.done;
      }
    });
  }

  void _goStage(int segIndex, SelectionStage stage) {
    setState(() => _selections[segIndex].stage = stage);
  }

  // ====== منع تعدد الأدوار للفقاعة الواحدة ======
  String? _occupiedRoleName(
    _SegmentSelection sel,
    _TokPos pos,
    SelectionStage current,
  ) {
    final isName = sel.nameTokens.contains(pos);
    final isAmt = (sel.amount == pos);
    final isCur = (sel.currencyToken == pos);

    if (current == SelectionStage.name && (isAmt || isCur))
      return isAmt ? 'مبلغ' : 'عملة';
    if (current == SelectionStage.amount && (isName || isCur))
      return isName ? 'اسم' : 'عملة';
    if (current == SelectionStage.currency && (isName || isAmt))
      return isName ? 'اسم' : 'مبلغ';
    return null;
  }

  // ====== إزالة تحديد فقاعة معيّنة ======
  void _unselectToken(int segIndex, _TokPos pos) {
    final sel = _selections[segIndex];
    final isAmt = sel.amount == pos;
    final isCur = sel.currencyToken == pos;
    final isName = sel.nameTokens.contains(pos);

    if (isAmt && isCur) {
      _showClearAmountOrCurrencyDialog(segIndex);
      return;
    }

    setState(() {
      if (isName) {
        sel.nameTokens.remove(pos);
        _nameOverride.remove(segIndex);
        _invalidateCancelCandidates(segIndex);
      }

      if (isAmt) {
        sel.amount = null;
        _amountOverride.remove(segIndex);
        _amountConflict.remove(segIndex);
        _amountTextCandidate.remove(segIndex);
        _amountCandidatesCache.remove(segIndex);
      }

      if (isCur) {
        sel.currencyToken = null;
        sel.currencyFromMenu = null;
        sel.currencyDetectedName = null;
      }

      _refreshStageForSegment(segIndex);
    });
  }

  bool _isLockedToken(int segIndex, int li, int ti) =>
      _selections[segIndex].amountTextLockedTokens.contains(_TokPos(li, ti));
  bool _isPhoneToken(int segIndex, int li, int ti) =>
      _selections[segIndex].phoneLikeTokens.contains(_TokPos(li, ti));

  // ====== اختيار/تبديل بحسب المرحلة مع القفل وفلترة ignoredWords ======
  void _toggleForStage(
    int segIndex,
    int lineIndex,
    int tokenIndex,
    List<String> tokensThisLine,
  ) async {
    final sel = _selections[segIndex];
    final pos = _TokPos(lineIndex, tokenIndex);
    final tok = (tokenIndex >= 0 && tokenIndex < tokensThisLine.length)
        ? tokensThisLine[tokenIndex]
        : '';

    // التوكن الأحمر: مسموح فقط في مرحلة المبلغ
    if (_isLockedToken(segIndex, lineIndex, tokenIndex)) {
      if (sel.stage != SelectionStage.amount) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('هذه الفقاعة الحمراء تُستخدم فقط عند اختيار المبلغ'),
          ),
        );
        return;
      }

      await _detectAmountFromTappedLine(segIndex, lineIndex, tokensThisLine);

      if (_hasMultipleAmountCandidates(segIndex)) {
        await _openMultiAmountPickerDialog(segIndex);
      }
      return;
    }

    // كلمات ignored لا تُستخدم كاسم
    if (sel.stage == SelectionStage.name && _isIgnoredWord(tok)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'هذه الكلمة مُتجاهلة من الإعدادات ولا يمكن اختيارها كاسم',
          ),
        ),
      );
      return;
    }

    // منع تعدد الأدوار للتوكن نفسه
    final occ = _occupiedRoleName(sel, pos, sel.stage);
    if (occ != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هذه الفقاعة محددة مسبقًا كـ $occ')),
      );
      return;
    }

    setState(() {}); // فقط لتأثير الضغط

    switch (sel.stage) {
      case SelectionStage.name:
        setState(() {
          if (sel.nameTokens.isEmpty) {
            for (int t2 = tokenIndex; t2 < tokensThisLine.length; t2++) {
              final p = _TokPos(lineIndex, t2);
              final tk = tokensThisLine[t2];
              if (_occupiedRoleName(sel, p, SelectionStage.name) == null &&
                  !_isLockedToken(segIndex, p.line, p.index) &&
                  !_isIgnoredWord(tk)) {
                sel.nameTokens.add(p);
              }
            }
          } else {
            if (sel.nameTokens.contains(pos)) {
              sel.nameTokens.remove(pos);
            } else if (!_isIgnoredWord(tok)) {
              sel.nameTokens.add(pos);
            }
          }
          _nameOverride.remove(segIndex);
          _invalidateCancelCandidates(segIndex);
          _refreshStageForSegment(segIndex);
        });
        if (_modeOf(segIndex) == BubbleActionMode.cancel) {
          _requestCancelCandidates(segIndex);
        }
        return;

      case SelectionStage.amount:
        await _detectAmountFromTappedLine(segIndex, lineIndex, tokensThisLine);

        if (_hasMultipleAmountCandidates(segIndex)) {
          await _openMultiAmountPickerDialog(segIndex);
        }
        return;

      case SelectionStage.currency:
        if (!_isKnownCurrencyToken(_getSettingsOrDefault(), tok)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('العملة غير مُعرّفة في الإعدادات')),
          );
          return;
        }

        setState(() {
          sel.currencyToken = pos;
          sel.currencyFromMenu = null;
          _refreshStageForSegment(segIndex);
        });
        return;

      case SelectionStage.done:
        return;
    }
  }

  // ====== إدخال يدوي: الاسم ======
  Future<void> _openNameManualDialog(int segIndex, String currentName) async {
    final ctrl = TextEditingController(text: currentName);
    String? result;

    await showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تحرير الاسم يدويًا'),
          content: TextField(
            controller: ctrl,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'اكتب الاسم هنا...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () {
                final v = ctrl.text.trim();
                result = v.isEmpty ? null : v;
                Navigator.pop(ctx);
              },
              child: const Text('اعتماد'),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    setState(() {
      if (result != null && result!.isNotEmpty) {
        _nameOverride[segIndex] = result!;
        _selections[segIndex].nameTokens.clear();
        _invalidateCancelCandidates(segIndex);
      }
      _refreshStageForSegment(segIndex);
    });
    if (_modeOf(segIndex) == BubbleActionMode.cancel) {
      _requestCancelCandidates(segIndex);
    }
  }

  // ====== إدخال يدوي: المبلغ ======
  Future<void> _openAmountManualDialog(
    int segIndex,
    double? currentAmount,
  ) async {
    final ctrl = TextEditingController(
      text: currentAmount != null ? currentAmount.toStringAsFixed(2) : '',
    );
    double? result;

    await showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تحرير المبلغ يدويًا'),
          content: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              hintText: 'أدخل المبلغ (مثال: 150.00)',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () {
                final v = double.tryParse(ctrl.text.replaceAll(',', '.'));
                result = v;
                Navigator.pop(ctx);
              },
              child: const Text('اعتماد'),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    setState(() {
      if (result != null && result! > 0) {
        _amountOverride[segIndex] = result!;
        _amountConflict.remove(segIndex);
        _amountCandidatesCache.remove(segIndex);
        _selections[segIndex].amount = null;
      }
      _refreshStageForSegment(segIndex);
    });
  }

  Future<void> _showClearAmountOrCurrencyDialog(int segIndex) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('إلغاء التحديد'),
          content: const Text(
            'هذا التحديد يحتوي على مبلغ وعملة. ماذا تريد أن تلغي؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'amount'),
              child: const Text('إلغاء المبلغ'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'currency'),
              child: const Text('إلغاء العملة'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'both'),
              child: const Text('إلغاء الاثنين'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('إلغاء'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || choice == null) return;

    switch (choice) {
      case 'amount':
        _clearCategory(segIndex, 'amount');
        break;
      case 'currency':
        _clearCategory(segIndex, 'currency');
        break;
      case 'both':
        setState(() {
          final sel = _selections[segIndex];
          sel.amount = null;
          sel.currencyToken = null;
          sel.currencyFromMenu = null;
          _amountOverride.remove(segIndex);
          _amountConflict.remove(segIndex);
          _amountTextCandidate.remove(segIndex);
          _refreshStageForSegment(segIndex);
        });
        break;
    }
  }

  // ====== لون/خلفية التوكن ======
  Color _tokenColor(BuildContext ctx, int segIndex, int li, int ti) {
    final sel = _selections[segIndex];
    final cs = Theme.of(ctx).colorScheme;

    if (_isLockedToken(segIndex, li, ti)) return _chipRed;
    if (sel.nameTokens.contains(_TokPos(li, ti))) return _chipIndigo;
    if (_isDualAmountCurrencyPos(segIndex, li, ti)) return Colors.white;
    if (_isAmountPos(segIndex, li, ti)) return _chipTeal;
    if (_isCurrencyPos(segIndex, li, ti)) return _chipBlue;
    if (_isPhoneToken(segIndex, li, ti)) return _chipYellow;

    return cs.onSurface.withOpacity(0.6);
  }

  Decoration _tokenDecoration(BuildContext ctx, int segIndex, int li, int ti) {
    final pos = _TokPos(li, ti);

    if (_isLockedToken(segIndex, li, ti)) {
      return BoxDecoration(
        color: _chipRed.withOpacity(0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _chipRed.withOpacity(.75), width: 1.2),
      );
    }

    if (_selections[segIndex].nameTokens.contains(pos)) {
      return BoxDecoration(
        color: _chipIndigo.withOpacity(0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _chipIndigo.withOpacity(.75), width: 1.2),
      );
    }

    if (_isDualAmountCurrencyPos(segIndex, li, ti)) {
      return BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _chipTeal.withOpacity(.22),
            _chipTeal.withOpacity(.22),
            _chipBlue.withOpacity(.22),
            _chipBlue.withOpacity(.22),
          ],
          stops: const [0.0, 0.5, 0.5, 1.0],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _mixedAmountCurrencyBorder(), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: _mixedAmountCurrencyBorder().withOpacity(.18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      );
    }

    if (_isAmountPos(segIndex, li, ti)) {
      return BoxDecoration(
        color: _chipTeal.withOpacity(0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _chipTeal.withOpacity(.75), width: 1.2),
      );
    }

    if (_isCurrencyPos(segIndex, li, ti)) {
      return BoxDecoration(
        color: _chipBlue.withOpacity(0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _chipBlue.withOpacity(.75), width: 1.2),
      );
    }

    if (_isPhoneToken(segIndex, li, ti)) {
      return BoxDecoration(
        color: _chipYellow.withOpacity(0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _chipYellow.withOpacity(.75), width: 1.2),
      );
    }

    return BoxDecoration(
      color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.08),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.14),
        width: 1,
      ),
    );
  }

  // ====== بناء القيم ======
  String _buildSelectedName(
    ParsedSegment seg,
    _SegmentSelection sel,
    int segIndex,
  ) {
    final manual = _nameOverride[segIndex];
    if (manual != null && manual.trim().isNotEmpty) return manual.trim();

    if (sel.nameTokens.isEmpty) return '';
    final byLine = <int, List<int>>{};
    for (final p in sel.nameTokens) {
      (byLine[p.line] ??= []).add(p.index);
    }
    final parts = <String>[];
    for (final entry
        in byLine.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      final li = entry.key;
      final idxs = entry.value..sort();
      final toks = _tokensFromLine(seg.lines[li]);
      for (final ti in idxs) {
        if (ti >= 0 && ti < toks.length) {
          final tok = toks[ti];
          if (!_isIgnoredWord(tok)) parts.add(tok);
        }
      }
    }
    return parts.join(' ');
  }

  double? _buildSelectedAmount(
    ParsedSegment seg,
    _SegmentSelection sel,
    int segIndex,
  ) {
    if (_amountOverride.containsKey(segIndex)) return _amountOverride[segIndex];
    if (sel.amount != null) {
      final toks = _tokensFromLine(seg.lines[sel.amount!.line]);
      if (sel.amount!.index >= 0 && sel.amount!.index < toks.length) {
        final v = ad.AmountDetector.parseAmountToken(toks[sel.amount!.index]);
        if (v != null) return v;
      }
    }
    return null;
  }

  // نُرجِع دومًا "اسم العملة" (وليس الرمز)
  String? _buildSelectedCurrency(ParsedSegment seg, _SegmentSelection sel) {
    if (sel.currencyFromMenu != null &&
        sel.currencyFromMenu!.trim().isNotEmpty) {
      return sel.currencyFromMenu;
    }

    if (sel.currencyDetectedName != null &&
        sel.currencyDetectedName!.trim().isNotEmpty) {
      return sel.currencyDetectedName;
    }

    final p = sel.currencyToken;
    if (p == null) return null;

    final toks = _tokensFromLine(seg.lines[p.line]);
    if (p.index < 0 || p.index >= toks.length) return null;

    final tok = toks[p.index];
    return _currencyNameForToken(tok);
  }

  bool _segmentReady(_SegmentSelection sel, int segIndex) {
    final hasName = _buildSelectedName(
      _segments[segIndex],
      sel,
      segIndex,
    ).trim().isNotEmpty;
    final hasAmount =
        _buildSelectedAmount(_segments[segIndex], sel, segIndex) != null;
    final hasCurr = (_buildSelectedCurrency(_segments[segIndex], sel) != null);
    return hasName && hasAmount && hasCurr;
  }

  bool _cancelReady(int segIndex) {
    if (_cancelledSummaries.containsKey(segIndex)) return false;
    if (_modeOf(segIndex) != BubbleActionMode.cancel) return false;
    final selectedId = _cancelSelectedTxIds[segIndex];
    if (selectedId == null) return false;

    for (final tx in _cancelCandidatesForSegment(segIndex)) {
      if (tx.id == selectedId && _canCancel(tx)) {
        return true;
      }
    }
    return false;
  }

  bool _cancelAlreadyResolved(int segIndex) {
    if (_cancelledSummaries.containsKey(segIndex)) return true;
    if (_modeOf(segIndex) != BubbleActionMode.cancel) return false;
    final candidates = _cancelCandidatesForSegment(segIndex);
    return candidates.isNotEmpty &&
        candidates.every((tx) => tx.status == TransactionStatus.cancelled);
  }

  bool _segmentReadyForMode(int segIndex) {
    if (_modeOf(segIndex) == BubbleActionMode.cancel) {
      return _cancelReady(segIndex) || _cancelAlreadyResolved(segIndex);
    }
    return _segmentReady(_selections[segIndex], segIndex);
  }

  bool _hasCancelSegments() {
    for (int i = 0; i < _segments.length; i++) {
      if (_modeOf(i) == BubbleActionMode.cancel &&
          !_cancelledSummaries.containsKey(i)) {
        return true;
      }
    }
    return false;
  }

  bool _hasPendingAddSegments() {
    for (int i = 0; i < _segments.length; i++) {
      if (_modeOf(i) == BubbleActionMode.add &&
          !_savedSegments.contains(i) &&
          _segmentReady(_selections[i], i)) {
        return true;
      }
    }
    return false;
  }

  bool _hasUnresolvedConflicts() => _amountConflict.any(
    (segIndex) =>
        _modeOf(segIndex) == BubbleActionMode.add &&
        !_savedSegments.contains(segIndex),
  );

  // ====== سطر اختيار العملة (Dropdown) — أسماء فقط ======
  Widget _buildCurrencyPickerRow(BuildContext context, int si) {
    final namesOnly = _currencyMap.values.toSet().toList();
    namesOnly.sort();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _selections[si].currencyFromMenu,
              items: namesOnly
                  .map(
                    (name) => DropdownMenuItem<String>(
                      value: name,
                      child: Text(name),
                    ),
                  )
                  .toList(),
              onChanged: (pickedName) =>
                  _onCurrencyPickedFromMenu(si, pickedName),
              decoration: const InputDecoration(
                labelText: "اختر العملة (اختياري إذا التقطت من النص)",
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_selections[si].currencyToken != null) ...[
            const SizedBox(width: 10),
            Chip(
              label: const Text("عملة من النص"),
              avatar: const Icon(Icons.check, size: 18),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withOpacity(.12),
            ),
          ],
        ],
      ),
    );
  }

  // اختيار عملة من القائمة (أسماء فقط) — يمنع غير المُعرفة
  void _onCurrencyPickedFromMenu(int segIndex, String? pickedName) {
    final s = _getSettingsOrDefault();
    if (pickedName == null) {
      setState(() {
        _selections[segIndex].currencyFromMenu = null;
        _selections[segIndex].currencyToken = null;
      });
      return;
    }

    final entry = s.currencyMap.entries.firstWhere(
      (e) => _eqCur(e.value, pickedName),
      orElse: () => const MapEntry('', ''),
    );
    final finalKey = entry.key.isEmpty ? null : entry.key;

    if (finalKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذه العملة غير مُدرجة في الإعدادات')),
      );
      return;
    }

    setState(() {
      _settings = s;
      _currencyMap = Map.of(s.currencyMap);
      final sel = _selections[segIndex];
      sel.currencyFromMenu = pickedName; // نخزّن الاسم مباشرة
      sel.currencyToken = null;

      if (!_hasNameFor(segIndex, sel)) {
        sel.stage = SelectionStage.name;
      } else if (!_hasAmountFor(segIndex, sel)) {
        sel.stage = SelectionStage.amount;
      } else if (sel.currencyFromMenu == null) {
        sel.stage = SelectionStage.currency;
      } else {
        sel.stage = SelectionStage.done;
      }
    });
  }

  // ====== Dialog مراجعة تعارض رقم/نص ======
  Future<void> _openAmountConflictDialog(int segIndex) async {
    final seg = _segments[segIndex];
    final sel = _selections[segIndex];

    double? numericVal;
    if (sel.amount != null) {
      final toks = _tokensFromLine(seg.lines[sel.amount!.line]);
      if (sel.amount!.index >= 0 && sel.amount!.index < toks.length) {
        numericVal = ad.AmountDetector.parseAmountToken(
          toks[sel.amount!.index],
        );
      }
    }
    final textVal = _amountTextCandidate[segIndex];

    double? result = textVal ?? numericVal;
    String mode = (textVal != null) ? 'text' : 'num';
    final customCtrl = TextEditingController(
      text: result?.toStringAsFixed(2) ?? '',
    );

    await showDialog(
      context: context,
      builder: (ctx) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (c, setS) {
              return AlertDialog(
                title: const Text("مراجعة المبلغ"),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (textVal != null)
                        RadioListTile<String>(
                          value: 'text',
                          groupValue: mode,
                          onChanged: (v) => setS(() => mode = v!),
                          title: Text(
                            "استخدام النص المحسوب: ${textVal!.toStringAsFixed(2)}",
                          ),
                        ),
                      if (numericVal != null)
                        RadioListTile<String>(
                          value: 'num',
                          groupValue: mode,
                          onChanged: (v) => setS(() => mode = v!),
                          title: Text(
                            "استخدام الرقم: ${numericVal!.toStringAsFixed(2)}",
                          ),
                        ),
                      RadioListTile<String>(
                        value: 'custom',
                        groupValue: mode,
                        onChanged: (v) => setS(() => mode = v!),
                        title: const Text("إدخال يدوي"),
                      ),
                      if (mode == 'custom')
                        TextField(
                          controller: customCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: "أدخل المبلغ",
                            border: OutlineInputBorder(),
                          ),
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("إلغاء"),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      switch (mode) {
                        case 'num':
                          result = numericVal;
                          break;
                        case 'text':
                          result = textVal;
                          break;
                        case 'custom':
                          result = double.tryParse(
                            customCtrl.text.replaceAll(',', '.'),
                          );
                          break;
                      }
                      Navigator.pop(ctx);
                    },
                    child: const Text("اعتماد"),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (result != null && mounted) {
      setState(() {
        _amountOverride[segIndex] = result!;
        _amountConflict.remove(segIndex);
        _amountCandidatesCache.remove(segIndex);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("تم اعتماد المبلغ لهذا المقطع")),
      );
    }
  }

  bool _isAmountPos(int segIndex, int li, int ti) {
    return _selections[segIndex].amount == _TokPos(li, ti);
  }

  bool _isCurrencyPos(int segIndex, int li, int ti) {
    return _selections[segIndex].currencyToken == _TokPos(li, ti);
  }

  bool _isDualAmountCurrencyPos(int segIndex, int li, int ti) {
    return _isAmountPos(segIndex, li, ti) && _isCurrencyPos(segIndex, li, ti);
  }

  Color _mixedAmountCurrencyBorder() {
    return Color.lerp(_chipTeal, _chipBlue, 0.5) ?? _chipBlue;
  }

  Widget _buildTokenChip({
    required BuildContext context,
    required int segIndex,
    required int lineIndex,
    required int tokenIndex,
    required String token,
    required List<String> tokensThisLine,
  }) {
    final sel = _selections[segIndex];
    final pos = _TokPos(lineIndex, tokenIndex);
    final selected =
        sel.nameTokens.contains(pos) ||
        sel.amount == pos ||
        sel.currencyToken == pos;
    final isLocked = _isLockedToken(segIndex, lineIndex, tokenIndex);

    final color = _tokenColor(context, segIndex, lineIndex, tokenIndex);
    final decoration = _tokenDecoration(
      context,
      segIndex,
      lineIndex,
      tokenIndex,
    );

    final canTap = !isLocked || sel.stage == SelectionStage.amount;

    return AnimatedScale(
      scale: selected ? 1.03 : 1.0,
      duration: const Duration(milliseconds: 120),
      child: InkWell(
        onTap: canTap
            ? () => _toggleForStage(
                segIndex,
                lineIndex,
                tokenIndex,
                tokensThisLine,
              )
            : null,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: decoration,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                token,
                style: TextStyle(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  decoration: isLocked
                      ? TextDecoration.underline
                      : TextDecoration.none,
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _unselectToken(segIndex, pos),
                  child: Icon(Icons.close, size: 16, color: color),
                ),
              ],
              if (!selected &&
                  _isPhoneToken(segIndex, lineIndex, tokenIndex)) ...[
                const SizedBox(width: 6),
                const Icon(Icons.phone_android, size: 14, color: Colors.amber),
              ],
              if (!selected && isLocked) ...[
                const SizedBox(width: 6),
                Icon(Icons.touch_app, size: 14, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _normalizeNameForCompare(String s) =>
      _normalizeArabic(s).replaceAll(RegExp(r'\s+'), ' ').trim();

  bool _eqName(String a, String b) =>
      _normalizeNameForCompare(a) == _normalizeNameForCompare(b);

  bool _sameAmount(double a, double b) => (a - b).abs() < 0.0001;

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _sameExactMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  String _fmtDateTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  void _addUniqueAmount(List<double> list, double? value) {
    if (value == null || value <= 0) return;
    final exists = list.any((e) => (e - value).abs() < 0.0001);
    if (!exists) list.add(value);
  }

  List<double> _amountCandidatesForSegment(int segIndex) {
    final cached = _amountCandidatesCache[segIndex];
    if (cached != null) return cached;

    final seg = _segments[segIndex];
    final sel = _selections[segIndex];

    final forward = _buildForwardLinesForAmount(seg, sel);

    final res = ad.AmountDetector.detect(
      forward.map((e) => e.text).toList(),
      currencyHints: _currencyHintsFromSettings(),
      conflictThreshold: 0.35,
      customWordValues: _amountWordValues,
    );

    final values = <double>[];

    _addUniqueAmount(values, res.numericValue);
    _addUniqueAmount(values, res.textValue);
    _addUniqueAmount(values, _amountOverride[segIndex]);
    _addUniqueAmount(values, _amountTextCandidate[segIndex]);

    values.sort();
    _amountCandidatesCache[segIndex] = values;
    return values;
  }

  bool _hasMultipleAmountCandidates(int segIndex) =>
      _amountCandidatesForSegment(segIndex).length >= 2;

  Future<void> _copyNameToClipboard(int segIndex) async {
    final seg = _segments[segIndex];
    final sel = _selections[segIndex];
    final name = _buildSelectedName(seg, sel, segIndex).trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لا يوجد اسم لنسخه')));
      return;
    }

    await Clipboard.setData(ClipboardData(text: name));
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('تم نسخ الاسم: $name')));
  }

  String _fmtAmount(double value) {
    final isInt = value == value.roundToDouble();
    return isInt ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
  }

  Future<void> _copyAmountToClipboard(double amount) async {
    final text = _fmtAmount(amount);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('تم نسخ المبلغ: $text')));
  }

  void _applyChosenAmount(int segIndex, double amount) {
    setState(() {
      _amountOverride[segIndex] = amount;
      _amountConflict.remove(segIndex);
      _amountCandidatesCache.remove(segIndex);
      _selections[segIndex].amount = null;
      _refreshStageForSegment(segIndex);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم اعتماد المبلغ: ${_fmtAmount(amount)}')),
    );
  }

  Future<void> _openMultiAmountPickerDialog(
    int segIndex, {
    bool afterSave = false,
  }) async {
    final seg = _segments[segIndex];
    final sel = _selections[segIndex];
    final name = _buildSelectedName(seg, sel, segIndex).trim();
    final currency = _buildSelectedCurrency(seg, sel);
    final amounts = _amountCandidatesForSegment(segIndex);

    if (amounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد مبالغ مرشحة في هذه الرسالة')),
      );
      return;
    }

    await showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(
            afterSave
                ? 'يوجد أكثر من مبلغ في هذه الرسالة'
                : 'اختر المبلغ الذي سيتم حفظه',
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (name.isNotEmpty) ...[
                    Text(
                      'الاسم: $name',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (currency != null) ...[
                    Text('العملة: $currency'),
                    const SizedBox(height: 12),
                  ],
                  ...amounts.map(
                    (amount) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _fmtAmount(amount),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'نسخ المبلغ',
                              onPressed: () => _copyAmountToClipboard(amount),
                              icon: const Icon(Icons.copy),
                            ),
                            const SizedBox(width: 6),
                            FilledButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                _applyChosenAmount(segIndex, amount);
                              },
                              child: const Text('اعتماد'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            OutlinedButton.icon(
              onPressed: name.isEmpty
                  ? null
                  : () => _copyNameToClipboard(segIndex),
              icon: const Icon(Icons.copy_all),
              label: const Text('نسخ الاسم'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );
  }

  void _reindexAfterDelete(int deletedIndex) {
    final newAmountOverride = <int, double>{};
    for (final e in _amountOverride.entries) {
      if (e.key == deletedIndex) continue;
      newAmountOverride[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _amountOverride
      ..clear()
      ..addAll(newAmountOverride);

    final newAmountConflict = <int>{};
    for (final v in _amountConflict) {
      if (v == deletedIndex) continue;
      newAmountConflict.add(v > deletedIndex ? v - 1 : v);
    }
    _amountConflict
      ..clear()
      ..addAll(newAmountConflict);

    final newAmountTextCandidate = <int, double>{};
    for (final e in _amountTextCandidate.entries) {
      if (e.key == deletedIndex) continue;
      newAmountTextCandidate[e.key > deletedIndex ? e.key - 1 : e.key] =
          e.value;
    }
    _amountTextCandidate
      ..clear()
      ..addAll(newAmountTextCandidate);

    final newAmountCandidatesCache = <int, List<double>>{};
    for (final e in _amountCandidatesCache.entries) {
      if (e.key == deletedIndex) continue;
      newAmountCandidatesCache[e.key > deletedIndex ? e.key - 1 : e.key] =
          e.value;
    }
    _amountCandidatesCache
      ..clear()
      ..addAll(newAmountCandidatesCache);

    final newNameOverride = <int, String>{};
    for (final e in _nameOverride.entries) {
      if (e.key == deletedIndex) continue;
      newNameOverride[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _nameOverride
      ..clear()
      ..addAll(newNameOverride);

    final newSaved = <int>{};
    for (final v in _savedSegments) {
      if (v == deletedIndex) continue;
      newSaved.add(v > deletedIndex ? v - 1 : v);
    }
    _savedSegments
      ..clear()
      ..addAll(newSaved);

    final newSavedSummaries = <int, _SavedAddSummary>{};
    for (final e in _savedAddSummaries.entries) {
      if (e.key == deletedIndex) continue;
      newSavedSummaries[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _savedAddSummaries
      ..clear()
      ..addAll(newSavedSummaries);

    final newCancelledSummaries = <int, _CancelledSummary>{};
    for (final e in _cancelledSummaries.entries) {
      if (e.key == deletedIndex) continue;
      newCancelledSummaries[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _cancelledSummaries
      ..clear()
      ..addAll(newCancelledSummaries);

    final newModes = <int, BubbleActionMode>{};
    for (final e in _segmentModes.entries) {
      if (e.key == deletedIndex) continue;
      newModes[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _segmentModes
      ..clear()
      ..addAll(newModes);

    final newCancelSelected = <int, int>{};
    for (final e in _cancelSelectedTxIds.entries) {
      if (e.key == deletedIndex) continue;
      newCancelSelected[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _cancelSelectedTxIds
      ..clear()
      ..addAll(newCancelSelected);

    final newCancelCandidates = <int, List<TransactionModel>>{};
    for (final e in _cancelCandidatesCache.entries) {
      if (e.key == deletedIndex) continue;
      newCancelCandidates[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _cancelCandidatesCache
      ..clear()
      ..addAll(newCancelCandidates);

    final newCancelQueries = <int, String>{};
    for (final e in _cancelCandidateQueries.entries) {
      if (e.key == deletedIndex) continue;
      newCancelQueries[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _cancelCandidateQueries
      ..clear()
      ..addAll(newCancelQueries);

    final newCancelLoading = <int>{};
    for (final v in _cancelCandidatesLoading) {
      if (v == deletedIndex) continue;
      newCancelLoading.add(v > deletedIndex ? v - 1 : v);
    }
    _cancelCandidatesLoading
      ..clear()
      ..addAll(newCancelLoading);

    final newCancelShowMore = <int, bool>{};
    for (final e in _cancelShowMore.entries) {
      if (e.key == deletedIndex) continue;
      newCancelShowMore[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _cancelShowMore
      ..clear()
      ..addAll(newCancelShowMore);
  }

  Future<void> _confirmDeleteSegment(int segIndex) async {
    final seg = _segments[segIndex];
    final preview = seg.lines
        .where((e) => e.trim().isNotEmpty)
        .take(2)
        .join(' | ');

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('حذف الفقاعة'),
              content: Text(
                preview.isEmpty
                    ? 'هل تريد حذف هذه الفقاعة؟'
                    : 'هل تريد حذف هذه الفقاعة؟\n\n$preview',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('تأكيد الحذف'),
                ),
              ],
            ),
          ),
        ) ??
        false;

    if (!ok || !mounted) return;

    setState(() {
      _segments.removeAt(segIndex);
      _selections.removeAt(segIndex);
      _reindexAfterDelete(segIndex);
    });

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم حذف الفقاعة')));
  }

  List<_PendingTxDraft> _collectReadyDrafts() {
    final drafts = <_PendingTxDraft>[];

    for (int i = 0; i < _segments.length; i++) {
      if (_modeOf(i) != BubbleActionMode.add) continue;
      if (_savedSegments.contains(i)) continue;
      final seg = _segments[i];
      final sel = _selections[i];
      if (!_segmentReady(sel, i)) continue;

      final beneficiary = _buildSelectedName(seg, sel, i).trim();
      final amount = _buildSelectedAmount(seg, sel, i) ?? 0.0;
      final currency = _buildSelectedCurrency(seg, sel);
      final date = seg.timestamp ?? DateTime.now();

      if (beneficiary.isEmpty || amount <= 0 || currency == null) continue;

      drafts.add(
        _PendingTxDraft(
          segIndex: i,
          beneficiary: beneficiary,
          amount: amount,
          currency: currency,
          companyMovementType: _isCompanyAccount
              ? _companyMovementForSegment(i)
              : null,
          date: date,
        ),
      );
    }

    return drafts;
  }

  List<_PendingCancelDraft> _collectReadyCancelDrafts() {
    final drafts = <_PendingCancelDraft>[];

    for (int i = 0; i < _segments.length; i++) {
      if (_modeOf(i) != BubbleActionMode.cancel) continue;
      if (_cancelledSummaries.containsKey(i)) continue;
      final selectedId = _cancelSelectedTxIds[i];
      if (selectedId == null) continue;

      final candidates = _cancelCandidatesForSegment(i);
      for (final tx in candidates) {
        if (tx.id == selectedId && _canCancel(tx)) {
          drafts.add(
            _PendingCancelDraft(
              segIndex: i,
              transaction: tx,
              date: _segments[i].timestamp ?? DateTime.now(),
            ),
          );
          break;
        }
      }
    }

    return drafts;
  }

  Future<bool> _confirmDuplicateWarnings(List<_PendingTxDraft> drafts) async {
    final all = await DatabaseService.getAllTransactions();
    final accountsById = <int, Account>{
      for (final account in DatabaseService.accountsBox.values)
        account.id: account,
    };
    final warnings = <_DuplicateWarningItem>[];
    final now = DateTime.now();
    final since = now.subtract(const Duration(days: 2));

    for (final d in drafts) {
      final exactCritical = <TransactionModel>[];
      final sameNameAmountCurrency = <TransactionModel>[];
      final sameNameOnly = <TransactionModel>[];

      for (final t in all) {
        final candidateAccount = accountsById[t.accountId];
        if (candidateAccount == null ||
            candidateAccount.type != widget.account.type ||
            t.date.isBefore(since)) {
          continue;
        }

        if (_isCompanyAccount &&
            t.companyMovementType != d.companyMovementType) {
          continue;
        }

        final sameName = _eqName(t.beneficiary, d.beneficiary);
        if (!sameName) continue;

        final sameAmount = _sameAmount(t.amount, d.amount);
        final sameCurrency = _eqCur(t.currency, d.currency);
        final sameMoment = _sameExactMinute(t.date, d.date);

        if (sameAmount && sameCurrency && sameMoment) {
          exactCritical.add(t);
          continue;
        }

        if (sameAmount && sameCurrency) {
          sameNameAmountCurrency.add(t);
          continue;
        }

        sameNameOnly.add(t);
      }

      if (exactCritical.isNotEmpty ||
          sameNameAmountCurrency.isNotEmpty ||
          sameNameOnly.isNotEmpty) {
        warnings.add(
          _DuplicateWarningItem(
            draft: d,
            exactCritical: exactCritical,
            sameNameAmountCurrency: sameNameAmountCurrency,
            sameNameOnly: sameNameOnly,
          ),
        );
      }
    }

    if (warnings.isEmpty) return true;

    final hasCritical = warnings.any((w) => w.exactCritical.isNotEmpty);
    final scopeLabel = _isCompanyAccount
        ? 'حسابات الشركة وبنفس نوع الحركة'
        : 'حسابات المكتب';

    return await showDialog<bool>(
          context: context,
          barrierDismissible: !hasCritical,
          builder: (ctx) {
            Color movementColor(TransactionModel tx) {
              if (_isCompanyAccount) {
                switch (tx.companyMovementType) {
                  case CompanyMovementType.sent:
                    return _chipIndigo;
                  case CompanyMovementType.received:
                    return _chipGreen;
                  case CompanyMovementType.sentCancelled:
                    return _chipRed;
                  case CompanyMovementType.receivedCancelled:
                    return _chipYellow;
                  case null:
                    return Colors.grey;
                }
              }
              return _txStatusColor(tx.status);
            }

            IconData movementIcon(TransactionModel tx) {
              if (_isCompanyAccount) {
                switch (tx.companyMovementType) {
                  case CompanyMovementType.sent:
                    return Icons.outbox_rounded;
                  case CompanyMovementType.received:
                    return Icons.move_to_inbox_rounded;
                  case CompanyMovementType.sentCancelled:
                    return Icons.undo_rounded;
                  case CompanyMovementType.receivedCancelled:
                    return Icons.assignment_return_rounded;
                  case null:
                    return Icons.help_outline_rounded;
                }
              }
              switch (tx.status) {
                case TransactionStatus.added:
                  return Icons.add_circle_outline_rounded;
                case TransactionStatus.received:
                  return Icons.check_circle_outline_rounded;
                case TransactionStatus.cancelled:
                  return Icons.cancel_outlined;
              }
            }

            Widget buildResultCard(TransactionModel tx) {
              final color = movementColor(tx);
              final accountName =
                  accountsById[tx.accountId]?.name ?? 'حساب غير معروف';

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(.07),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withOpacity(.24)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: color.withOpacity(.14),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(movementIcon(tx), color: color, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tx.beneficiary,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            tx.amount.toStringAsFixed(2) + ' ' + tx.currency,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _duplicateInfoChip(
                                icon: Icons.account_balance_wallet_rounded,
                                label: accountName,
                                color: color,
                              ),
                              _duplicateInfoChip(
                                icon: movementIcon(tx),
                                label: _movementLabel(tx),
                                color: color,
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'تاريخ الحركة: ' + _fmtDateTime(tx.date),
                            style: TextStyle(
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            Widget buildSection(
              String title,
              Color color,
              List<TransactionModel> items,
            ) {
              if (items.isEmpty) return const SizedBox.shrink();

              return Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: color.withOpacity(.28)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.manage_search_rounded, color: color),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Text(
                          items.length.toString(),
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    ...items.take(4).map(buildResultCard),
                    if (items.length > 4)
                      Text(
                        'و ' + (items.length - 4).toString() + ' نتائج أخرى',
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              );
            }

            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                title: Text(
                  hasCritical
                      ? 'تحذير مهم جدًا قبل الحفظ'
                      : 'يوجد تشابه قبل الحفظ',
                ),
                content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasCritical
                              ? 'وجدت حركات قد تكون مكررة بشكل خطير. راجعها جيدًا قبل المتابعة.'
                              : 'وجدت تشابهات محتملة. راجعها قبل المتابعة.',
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Theme.of(ctx).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.history_toggle_off_rounded,
                                color: Theme.of(ctx).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'نطاق البحث: آخر يومين ضمن ' + scopeLabel,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        ...warnings.map((w) {
                          final movementText = _isCompanyAccount
                              ? ' — ' +
                                    (w.draft.companyMovementType?.label ??
                                        'حركة شركة')
                              : '';
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                ctx,
                              ).colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Theme.of(
                                  ctx,
                                ).colorScheme.outlineVariant.withOpacity(.38),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  w.draft.beneficiary +
                                      ' | ' +
                                      w.draft.amount.toStringAsFixed(2) +
                                      ' ' +
                                      w.draft.currency +
                                      movementText,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'التاريخ/الوقت: ' +
                                      _fmtDateTime(w.draft.date),
                                ),
                                buildSection(
                                  'مطابقة تامة',
                                  Colors.red,
                                  w.exactCritical,
                                ),
                                buildSection(
                                  'الاسم + المبلغ + العملة',
                                  Colors.orange,
                                  w.sameNameAmountCurrency,
                                ),
                                buildSection(
                                  'الاسم متشابه',
                                  Colors.blue,
                                  w.sameNameOnly,
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('إلغاء'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(hasCritical ? 'متابعة رغم التحذير' : 'متابعة'),
                  ),
                ],
              ),
            );
          },
        ) ??
        false;
  }

  Widget _duplicateInfoChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSavedTransactionEditor(int segIndex) async {
    final summary = _savedAddSummaries[segIndex];
    if (summary == null) return;

    TransactionModel? transaction;
    for (final item in _allTransactions) {
      if (item.id == summary.transactionId &&
          item.accountId == widget.account.id) {
        transaction = item;
        break;
      }
    }

    if (transaction == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر العثور على الحركة المحفوظة')),
        );
      }
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddEditTransactionScreen(
          account: widget.account,
          existing: transaction,
        ),
      ),
    );

    if (mounted) setState(() {});
  }

  Future<void> _showPostSaveMultiAmountDialog(List<int> indices) async {
    final unique = indices.toSet().toList()..sort();

    await showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تم الحفظ ويوجد أكثر من مبلغ'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                children: unique.map((i) {
                  final seg = _segments[i];
                  final sel = _selections[i];
                  final summary = _savedAddSummaries[i];
                  final name = _buildSelectedName(seg, sel, i);
                  final amounts = _amountCandidatesForSegment(i);

                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isEmpty ? 'بدون اسم' : name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'المبالغ المحتملة: ${amounts.map(_fmtAmount).join(' / ')}',
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _copyNameToClipboard(i),
                                icon: const Icon(Icons.copy_all),
                                label: const Text('نسخ الاسم'),
                              ),
                              FilledButton.icon(
                                onPressed: () => _openMultiAmountPickerDialog(
                                  i,
                                  afterSave: true,
                                ),
                                icon: const Icon(Icons.payments_outlined),
                                label: const Text('اختيار / نسخ المبالغ'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: summary == null
                                    ? null
                                    : () => _openSavedTransactionEditor(i),
                                icon: const Icon(Icons.edit_note_rounded),
                                label: const Text('فتح تعديل الحركة'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('حسنًا'),
            ),
          ],
        ),
      ),
    );
  }

  // ====== حفظ وإنشاء الحركات ======
  Future<void> _sendForMode(BubbleActionMode mode) async {
    if (_isSending) return;

    final drafts = mode == BubbleActionMode.add
        ? _collectReadyDrafts()
        : const <_PendingTxDraft>[];
    final cancelDrafts = mode == BubbleActionMode.cancel
        ? _collectReadyCancelDrafts()
        : const <_PendingCancelDraft>[];

    if (drafts.isEmpty && cancelDrafts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mode == BubbleActionMode.add
                ? 'لا توجد إضافات مكتملة للتنفيذ'
                : 'لا توجد إلغاءات مختارة للتنفيذ',
          ),
        ),
      );
      return;
    }

    if (mode == BubbleActionMode.add && _hasUnresolvedConflicts()) {
      final first = _amountConflict.firstWhere(
        (segIndex) => _modeOf(segIndex) == BubbleActionMode.add,
      );
      await _openAmountConflictDialog(first);
      if (_hasUnresolvedConflicts()) return;
    }

    if (drafts.isNotEmpty) {
      final proceed = await _confirmDuplicateWarnings(drafts);
      if (!proceed) return;
    }

    setState(() => _isSending = true);

    int saved = 0;
    int cancelled = 0;
    final multiAmountSaved = <int>[];

    try {
      for (final d in drafts) {
        final tx = TransactionModel(
          id: DateTime.now().millisecondsSinceEpoch + d.segIndex,
          accountId: widget.account.id,
          beneficiary: d.beneficiary,
          amount: d.amount,
          currency: d.currency,
          notes: "",
          status: TransactionStatus.added,
          date: d.date,
          companyMovementType: _isCompanyAccount ? d.companyMovementType : null,
        );

        await DatabaseService.addTransaction(tx);
        _allTransactions.add(tx);
        if (!_knownBeneficiaryNames.contains(tx.beneficiary)) {
          _knownBeneficiaryNames.add(tx.beneficiary);
        }
        saved++;

        _savedSegments.add(d.segIndex);
        _savedAddSummaries[d.segIndex] = _SavedAddSummary(
          transactionId: tx.id,
          name: d.beneficiary,
          amount: d.amount,
          currency: d.currency,
          companyMovementType: d.companyMovementType,
          date: d.date,
        );
        if (_hasMultipleAmountCandidates(d.segIndex)) {
          multiAmountSaved.add(d.segIndex);
        }
      }

      if (saved > 0) {
        for (var i = 0; i < _segments.length; i++) {
          if (_modeOf(i) == BubbleActionMode.cancel) {
            _invalidateCancelCandidates(i);
          }
        }
      }

      for (final d in cancelDrafts) {
        if (_isCompanyAccount) {
          d.transaction.companyMovementType =
              d.transaction.companyMovementType!.cancelled;
          d.transaction.cancelledAt = d.date;
        } else {
          d.transaction.applyStatus(TransactionStatus.cancelled, at: d.date);
        }
        await d.transaction.save();
        _cancelSelectedTxIds.remove(d.segIndex);
        _cancelledSummaries[d.segIndex] = _CancelledSummary(
          name: d.transaction.beneficiary,
          amount: d.transaction.amount,
          currency: d.transaction.currency,
          date: d.date,
        );
        cancelled++;
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }

    if (!mounted) return;

    if (saved > 0) {
      for (var i = 0; i < _segments.length; i++) {
        if (_modeOf(i) == BubbleActionMode.cancel) {
          _requestCancelCandidates(i);
        }
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            if (saved > 0) "تمت إضافة $saved حركة",
            if (cancelled > 0) "تم إلغاء $cancelled حركة",
          ].join('، '),
        ),
      ),
    );

    if (multiAmountSaved.isNotEmpty) {
      await _showPostSaveMultiAmountDialog(multiAmountSaved);
    }

    if (!mounted) return;

    if (mode == BubbleActionMode.add) {
      if (_hasCancelSegments()) {
        setState(() => _viewMode = BubbleActionMode.cancel);
        return;
      }
      Navigator.pop(context, true);
      return;
    }

    if (!_hasCancelSegments() && !_hasPendingAddSegments()) {
      Navigator.pop(context, true);
    }
  }

  Color _stageBorderColor(SelectionStage s, bool ready) {
    if (ready) return _chipGreen;
    switch (s) {
      case SelectionStage.name:
        return _chipIndigo;
      case SelectionStage.amount:
        return _chipTeal;
      case SelectionStage.currency:
        return _chipBlue;
      case SelectionStage.done:
        return _chipGreen;
    }
  }

  Color _borderColorForSegment(int segIndex, _SegmentSelection sel) {
    if (_modeOf(segIndex) == BubbleActionMode.cancel) {
      if (_cancelReady(segIndex) || _cancelAlreadyResolved(segIndex)) {
        return _chipGreen;
      }
      return _chipRed;
    }

    return _stageBorderColor(sel.stage, _segmentReady(sel, segIndex));
  }

  String _hintForSegment(int segIndex, _SegmentSelection sel) {
    if (_modeOf(segIndex) == BubbleActionMode.cancel) {
      final name = _buildSelectedName(
        _segments[segIndex],
        sel,
        segIndex,
      ).trim();
      if (name.isEmpty) return 'حدد الاسم حتى أبحث عن الحركات المطلوب إلغاؤها';
      if (_cancelAlreadyResolved(segIndex)) {
        return 'كل النتائج لهذا الاسم ملغية مسبقًا';
      }
      if (_cancelReady(segIndex)) return 'تم اختيار الحركة المطلوب إلغاؤها';
      return 'اختر الحركة التي تريد تحويلها إلى ملغية';
    }

    return _stageHint(sel.stage);
  }

  String _txStatusLabel(TransactionStatus status) {
    switch (status) {
      case TransactionStatus.added:
        return 'مضافة';
      case TransactionStatus.received:
        return 'مستلمة';
      case TransactionStatus.cancelled:
        return 'ملغية';
    }
  }

  Color _txStatusColor(TransactionStatus status) {
    switch (status) {
      case TransactionStatus.added:
        return _chipBlue;
      case TransactionStatus.received:
        return _chipGreen;
      case TransactionStatus.cancelled:
        return _chipRed;
    }
  }

  DateTime? _txStatusDate(TransactionModel tx) {
    if (_isCompanyAccount && tx.companyMovementType != null) {
      return tx.companyMovementType!.isCancelled ? tx.cancelledAt : tx.date;
    }
    switch (tx.status) {
      case TransactionStatus.added:
        return tx.date;
      case TransactionStatus.received:
        return tx.receivedAt;
      case TransactionStatus.cancelled:
        return tx.cancelledAt;
    }
  }

  String _accountNameForTx(TransactionModel tx) =>
      _accountNamesById[tx.accountId] ?? 'حساب #${tx.accountId}';

  List<TransactionModel> _visibleCancelCandidates(int segIndex) {
    final candidates = _cancelCandidatesForSegment(segIndex);
    final added = candidates.where(_canCancel).toList();

    if (_cancelShowMore[segIndex] == true) return candidates;
    if (added.isNotEmpty) return added.take(5).toList();
    return candidates.take(5).toList();
  }

  bool _hasMoreCancelCandidates(int segIndex) {
    final candidates = _cancelCandidatesForSegment(segIndex);
    final visible = _visibleCancelCandidates(segIndex);
    return candidates.length > visible.length ||
        (candidates.any((tx) => !_canCancel(tx)) &&
            (_cancelShowMore[segIndex] != true));
  }

  Widget _buildModeSwitch(int segIndex) {
    final mode = _modeOf(segIndex);

    Widget chip(
      BubbleActionMode value,
      String label,
      IconData icon,
      Color color,
    ) {
      final selected = mode == value;
      return ChoiceChip(
        selected: selected,
        label: Text(label),
        avatar: Icon(icon, size: 18, color: selected ? Colors.white : color),
        selectedColor: color,
        labelStyle: TextStyle(
          color: selected ? Colors.white : color,
          fontWeight: FontWeight.w800,
        ),
        onSelected: (_) => _setSegmentMode(segIndex, value),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(
          BubbleActionMode.add,
          'إضافة',
          Icons.add_circle_rounded,
          _chipGreen,
        ),
        chip(BubbleActionMode.cancel, 'إلغاء', Icons.cancel_rounded, _chipRed),
      ],
    );
  }

  Widget _buildCompanyMovementSwitch(int segIndex) {
    if (!_isCompanyAccount || _modeOf(segIndex) != BubbleActionMode.add) {
      return const SizedBox.shrink();
    }
    final selected = _companyMovementForSegment(segIndex);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        children: [CompanyMovementType.sent, CompanyMovementType.received].map((
          type,
        ) {
          final active = selected.isSent == type.isSent;
          return ChoiceChip(
            selected: active,
            label: Text(type.label),
            avatar: Icon(
              type.isSent
                  ? Icons.call_made_rounded
                  : Icons.call_received_rounded,
              size: 18,
              color: active
                  ? Colors.white
                  : (type.isSent ? _chipIndigo : _chipGreen),
            ),
            selectedColor: type.isSent ? _chipIndigo : _chipGreen,
            labelStyle: TextStyle(
              color: active ? Colors.white : null,
              fontWeight: FontWeight.w800,
            ),
            onSelected: (_) =>
                setState(() => _companyMovementOverrides[segIndex] = type),
          );
        }).toList(),
      ),
    );
  }

  IconData _bubbleActionIconData(String key) {
    switch (key) {
      case 'zeros':
        return Icons.exposure_zero_rounded;
      case 'person':
        return Icons.person_add_alt_1_rounded;
      case 'clear':
        return Icons.backspace_rounded;
      case 'currency':
        return Icons.currency_exchange_rounded;
      case 'flash':
        return Icons.bolt_rounded;
      case 'check':
        return Icons.task_alt_rounded;
      default:
        return Icons.tune_rounded;
    }
  }

  Future<String?> _pickReadyName() async {
    if (_bubbleReadyNames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد أسماء جاهزة في الإعدادات')),
      );
      return null;
    }

    return showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SimpleDialog(
          title: const Text('اختر اسمًا جاهزًا'),
          children: _bubbleReadyNames
              .map(
                (name) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, name),
                  child: Text(name),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Future<void> _applyBubbleQuickAction(
    int segIndex,
    BubbleQuickActionConfig action,
  ) async {
    switch (action.actionType) {
      case 'appendZeros':
        final amount = _buildSelectedAmount(
          _segments[segIndex],
          _selections[segIndex],
          segIndex,
        );
        if (amount == null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('حدد المبلغ أولًا')));
          return;
        }
        final zeros = int.tryParse(action.value.trim()) ?? 2;
        var multiplier = 1.0;
        for (var i = 0; i < zeros.clamp(1, 6); i++) {
          multiplier *= 10;
        }
        setState(() {
          _amountOverride[segIndex] = amount * multiplier;
          _amountConflict.remove(segIndex);
          _amountCandidatesCache.remove(segIndex);
          _selections[segIndex].amount = null;
          _refreshStageForSegment(segIndex);
        });
        return;

      case 'setName':
        final picked =
            action.value.trim().isEmpty ||
                action.value.trim() == '@pick' ||
                action.value.trim() == 'قائمة'
            ? await _pickReadyName()
            : action.value.trim();
        if (picked == null || picked.isEmpty) return;
        setState(() {
          _nameOverride[segIndex] = picked;
          _selections[segIndex].nameTokens.clear();
          _invalidateCancelCandidates(segIndex);
          _refreshStageForSegment(segIndex);
        });
        if (_modeOf(segIndex) == BubbleActionMode.cancel) {
          _requestCancelCandidates(segIndex);
        }
        return;

      case 'clearStage':
        final stage = _selections[segIndex].stage;
        switch (stage) {
          case SelectionStage.name:
            _clearCategory(segIndex, 'name');
            break;
          case SelectionStage.amount:
            _clearCategory(segIndex, 'amount');
            break;
          case SelectionStage.currency:
          case SelectionStage.done:
            _clearCategory(segIndex, 'currency');
            break;
        }
        return;

      case 'setCurrency':
        final value = action.value.trim();
        final currencyName =
            _currencyNameForToken(value) ??
            _currencyMap.values.firstWhere(
              (name) => _eqCur(name, value),
              orElse: () => '',
            );
        if (currencyName.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('العملة "$value" غير موجودة في الإعدادات')),
          );
          return;
        }
        setState(() {
          final sel = _selections[segIndex];
          sel.currencyFromMenu = currencyName;
          sel.currencyToken = null;
          sel.currencyDetectedName = currencyName;
          _refreshStageForSegment(segIndex);
        });
        return;
    }
  }

  Widget _buildBubbleQuickActions(BuildContext context, int segIndex) {
    if (_bubbleQuickActions.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _bubbleQuickActions.map((action) {
          final icon = Icon(_bubbleActionIconData(action.iconKey), size: 18);
          final label = Text(
            action.label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800),
          );
          final child = action.iconAbove
              ? Column(mainAxisSize: MainAxisSize.min, children: [icon, label])
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [icon, const SizedBox(width: 6), label],
                );

          return Tooltip(
            message: action.label,
            child: OutlinedButton(
              onPressed: () => _applyBubbleQuickAction(segIndex, action),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.primary,
                side: BorderSide(color: cs.primary.withOpacity(.28)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: child,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCancelCandidatesPanel(BuildContext context, int segIndex) {
    final cs = Theme.of(context).colorScheme;
    final seg = _segments[segIndex];
    final sel = _selections[segIndex];
    final name = _buildSelectedName(seg, sel, segIndex).trim();

    if (name.isEmpty) {
      return _inlineInfoBox(
        context,
        icon: Icons.person_search_rounded,
        color: _chipRed,
        text: 'اختر الاسم من الفقاعات أو اكتبه يدويًا لعرض الحركات المطابقة.',
      );
    }

    final loading = _cancelCandidatesLoading.contains(segIndex);
    final query = _cancelQueryForSegment(segIndex);
    if (!loading &&
        (_cancelCandidateQueries[segIndex] != query ||
            !_cancelCandidatesCache.containsKey(segIndex))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _requestCancelCandidates(segIndex);
      });
    }
    final candidates = _cancelCandidatesForSegment(segIndex);
    if (loading && candidates.isEmpty) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _chipRed.withOpacity(.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _chipRed.withOpacity(.30)),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'جارٍ البحث داخل هذا الحساب عن نتائج مطابقة للاسم "$name"...',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      );
    }

    if (candidates.isEmpty) {
      return _inlineInfoBox(
        context,
        icon: Icons.search_off_rounded,
        color: _chipRed,
        text: 'لا توجد حركات مطابقة للاسم "$name" داخل هذا الحساب.',
      );
    }

    final allCancelled = candidates.every(
      (tx) => _isCompanyAccount
          ? tx.companyMovementType?.isCancelled == true
          : tx.status == TransactionStatus.cancelled,
    );
    final visibleCandidates = _visibleCancelCandidates(segIndex);
    final hasAdded = candidates.any(_canCancel);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _chipRed.withOpacity(.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _chipRed.withOpacity(.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.manage_search_rounded, color: _chipRed),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  allCancelled
                      ? 'النتائج الموجودة ملغية مسبقًا'
                      : hasAdded
                      ? (_isCompanyAccount
                            ? 'حركات الشركة المطابقة'
                            : 'الحركات المضافة المطابقة')
                      : (_isCompanyAccount
                            ? 'لا توجد حركات شركة قابلة للإلغاء'
                            : 'لا توجد حركات مضافة مطابقة'),
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              if (loading) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ...visibleCandidates.map((tx) {
            final canCancel = _canCancel(tx);
            final statusColor =
                _isCompanyAccount && tx.companyMovementType != null
                ? (tx.companyMovementType!.isCancelled
                      ? _chipRed
                      : (tx.companyMovementType!.isSent
                            ? _chipIndigo
                            : _chipGreen))
                : _txStatusColor(tx.status);
            final statusDate = _txStatusDate(tx);
            final selected = _cancelSelectedTxIds[segIndex] == tx.id;
            final exactMatch = _isExactCancelMatch(tx, name);

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: selected
                    ? cs.primary.withOpacity(.10)
                    : cs.surface.withOpacity(.75),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? cs.primary.withOpacity(.45)
                      : cs.outlineVariant.withOpacity(.30),
                ),
              ),
              child: RadioListTile<int>(
                value: tx.id,
                groupValue: _cancelSelectedTxIds[segIndex],
                onChanged: !canCancel
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _cancelSelectedTxIds[segIndex] = value);
                      },
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${tx.beneficiary} — ${tx.amount.toStringAsFixed(2)} ${tx.currency}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Chip(
                        label: Text(exactMatch ? 'مطابقة تمامًا' : 'متشابهة'),
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          exactMatch
                              ? Icons.verified_rounded
                              : Icons.compare_arrows_rounded,
                          size: 16,
                        ),
                        backgroundColor: (exactMatch ? _chipGreen : _chipYellow)
                            .withOpacity(.12),
                      ),
                    ),
                  ],
                ),
                subtitle: Text(
                  [
                    'الحساب: ${_accountNameForTx(tx)}',
                    'تاريخ الحركة: ${_fmtDateTime(tx.date)}',
                    '${_movementLabel(tx)}${statusDate == null ? '' : ': ${_fmtDateTime(statusDate)}'}',
                  ].join(' • '),
                ),
                secondary: Icon(
                  !canCancel
                      ? Icons.cancel_rounded
                      : Icons.radio_button_checked,
                  color: statusColor,
                ),
              ),
            );
          }),
          if (_hasMoreCancelCandidates(segIndex)) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => setState(
                  () => _cancelShowMore[segIndex] =
                      !(_cancelShowMore[segIndex] ?? false),
                ),
                icon: Icon(
                  _cancelShowMore[segIndex] == true
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: Text(
                  _cancelShowMore[segIndex] == true ? 'عرض أقل' : 'عرض المزيد',
                ),
              ),
            ),
          ],
          if (allCancelled)
            Text(
              'لا يوجد شيء لتنفيذه هنا، لأن كل الحركات المطابقة ملغية أصلًا.',
              style: TextStyle(color: cs.error, fontWeight: FontWeight.w700),
            ),
        ],
      ),
    );
  }

  Widget _inlineInfoBox(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String text,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(.28)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  int _segmentCountForMode(BubbleActionMode mode) =>
      _segmentModes.values.where((m) => m == mode).length;

  int _readyAddCount() => _collectReadyDrafts().length;

  int _readyCancelCount() => _collectReadyCancelDrafts().length;

  Widget _buildBubbleScreenHeader(
    BuildContext context, {
    required int addReadyCount,
    required int cancelReadyCount,
  }) {
    final cs = Theme.of(context).colorScheme;

    Widget stat({
      required IconData icon,
      required String label,
      required String value,
      required Color color,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: color.withOpacity(.10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(.20)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 6),
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withOpacity(.68),
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget modeChip(BubbleActionMode mode, String label, IconData icon) {
      final selected = _viewMode == mode;
      final color = mode == BubbleActionMode.add ? _chipGreen : _chipRed;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _viewMode = mode),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? color : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? color : cs.outlineVariant.withOpacity(.35),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: selected ? Colors.white : color, size: 19),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : color,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withOpacity(.22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.06),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              stat(
                icon: Icons.forum_rounded,
                label: 'كل الفقاعات',
                value: '${_segments.length}',
                color: cs.primary,
              ),
              const SizedBox(width: 8),
              stat(
                icon: Icons.add_circle_rounded,
                label: 'إضافة جاهزة',
                value: '$addReadyCount',
                color: _chipGreen,
              ),
              const SizedBox(width: 8),
              stat(
                icon: Icons.cancel_rounded,
                label: 'إلغاء جاهز',
                value: '$cancelReadyCount',
                color: _chipRed,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              modeChip(
                BubbleActionMode.add,
                'الإضافات (${_segmentCountForMode(BubbleActionMode.add)})',
                Icons.add_task_rounded,
              ),
              const SizedBox(width: 10),
              modeChip(
                BubbleActionMode.cancel,
                'الإلغاء (${_segmentCountForMode(BubbleActionMode.cancel)})',
                Icons.cancel_schedule_send_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _lockedSummaryCard({
    required BuildContext context,
    required Color color,
    required IconData icon,
    required String title,
    required List<String> lines,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(.34), width: 1.6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Icon(Icons.lock_rounded, color: color, size: 18),
                  ],
                ),
                const SizedBox(height: 8),
                ...lines.map(
                  (line) => Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      line,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLockedAddBubble(BuildContext context, _SavedAddSummary summary) {
    return _lockedSummaryCard(
      context: context,
      color: _chipGreen,
      icon: Icons.add_task_rounded,
      title: 'تمت إضافة الحركة',
      lines: [
        'الاسم: ${summary.name}',
        'المبلغ: ${_fmtAmount(summary.amount)} ${summary.currency}',
        'التاريخ: ${_fmtDateTime(summary.date)}',
      ],
    );
  }

  Widget _buildLockedCancelBubble(
    BuildContext context,
    _CancelledSummary summary,
  ) {
    return _lockedSummaryCard(
      context: context,
      color: _chipRed,
      icon: Icons.cancel_rounded,
      title: 'تم إلغاء ${summary.name}',
      lines: [
        'الحركة: ${summary.name}',
        'المبلغ: ${_fmtAmount(summary.amount)} ${summary.currency}',
        'تاريخ الإلغاء: ${_fmtDateTime(summary.date)}',
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final addReadyCount = _readyAddCount();
    final cancelReadyCount = _readyCancelCount();

    // فرز: اعرض نمطًا واحدًا في كل مرة، وغير المكتمل أولًا.
    final order = List.generate(
      _segments.length,
      (i) => i,
    ).where((i) => _modeOf(i) == _viewMode).toList();
    order.sort((a, b) {
      final ra = _segmentReadyForMode(a);
      final rb = _segmentReadyForMode(b);
      if (ra == rb) return a.compareTo(b);
      return ra ? 1 : -1;
    });

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accountStart = _isCompanyAccount
        ? const Color(0xFF5E35B1)
        : _gradStart;
    final accountEnd = _isCompanyAccount ? const Color(0xFF00897B) : _gradEnd;

    final cardBg = isDark
        ? cs.surface.withOpacity(0.6)
        : cs.surface.withOpacity(0.95);
    final canSendAdd =
        !_isSending && addReadyCount > 0 && !_hasUnresolvedConflicts();
    final canSendCancel = !_isSending && cancelReadyCount > 0;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _isCompanyAccount
            ? (isDark ? const Color(0xFF181522) : const Color(0xFFF8F5FF))
            : null,
        appBar: AppBar(
          title: Text(
            _isCompanyAccount ? 'تحليل حركات الشركة' : 'تحليل حركات المكتب',
          ),
          centerTitle: true,
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [accountStart, accountEnd],
              ),
            ),
          ),
        ),

        bottomNavigationBar: SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canSendAdd
                        ? () => _sendForMode(BubbleActionMode.add)
                        : null,
                    icon: _isSending && _viewMode == BubbleActionMode.add
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_task_rounded),
                    label: Text('تنفيذ الإضافات ($addReadyCount)'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: _chipGreen,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canSendCancel
                        ? () => _sendForMode(BubbleActionMode.cancel)
                        : null,
                    icon: _isSending && _viewMode == BubbleActionMode.cancel
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cancel_schedule_send_rounded),
                    label: Text('تنفيذ الإلغاء ($cancelReadyCount)'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: _chipRed,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        body: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 105),
          itemCount: order.length + (order.isEmpty ? 2 : 1),
          itemBuilder: (context, orderIdx) {
            if (orderIdx == 0) {
              return _buildBubbleScreenHeader(
                context,
                addReadyCount: addReadyCount,
                cancelReadyCount: cancelReadyCount,
              );
            }
            if (order.isEmpty) {
              return _inlineInfoBox(
                context,
                icon: _viewMode == BubbleActionMode.add
                    ? Icons.add_circle_outline_rounded
                    : Icons.cancel_outlined,
                color: _viewMode == BubbleActionMode.add
                    ? _chipGreen
                    : _chipRed,
                text: _viewMode == BubbleActionMode.add
                    ? 'لا توجد فقاعات إضافة في هذا النص.'
                    : 'لا توجد فقاعات إلغاء في هذا النص.',
              );
            }

            final si = order[orderIdx - 1];
            final seg = _segments[si];
            final sel = _selections[si];

            final nameText = _buildSelectedName(seg, sel, si);
            final amountVal = _buildSelectedAmount(seg, sel, si);
            final currencyText = _buildSelectedCurrency(seg, sel);
            final wasSaved = _savedSegments.contains(si);
            final mode = _modeOf(si);
            final amountCandidates = mode == BubbleActionMode.add
                ? _amountCandidatesForSegment(si)
                : const <double>[];
            final hasMultiAmount = amountCandidates.length >= 2;

            final borderColor = _borderColorForSegment(si, sel);
            final savedSummary = _savedAddSummaries[si];
            if (mode == BubbleActionMode.add && savedSummary != null) {
              return _buildLockedAddBubble(context, savedSummary);
            }
            final cancelledSummary = _cancelledSummaries[si];
            if (mode == BubbleActionMode.cancel && cancelledSummary != null) {
              return _buildLockedCancelBubble(context, cancelledSummary);
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderColor, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.25 : 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (seg.header.isNotEmpty)
                      Text(
                        seg.header,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _muted(context),
                        ),
                      ),
                    if (seg.timestamp != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          "التاريخ: ${seg.timestamp} • المرسل: ${seg.senderName}",
                          style: TextStyle(
                            fontSize: 12,
                            color: _muted(context),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    _buildModeSwitch(si),
                    _buildCompanyMovementSwitch(si),
                    _buildBubbleQuickActions(context, si),
                    const SizedBox(height: 10),

                    // شريط مرحلة الإرشاد + إعادة الضبط
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  _gradStart.withOpacity(.10),
                                  _gradEnd.withOpacity(.10),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _hintForSegment(si, sel),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: borderColor,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (mode == BubbleActionMode.cancel &&
                            _cancelCandidatesLoading.contains(si)) ...[
                          const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ),
                          const SizedBox(width: 8),
                        ],
                        IconButton.filledTonal(
                          onPressed: () => _confirmDeleteSegment(si),
                          tooltip: "حذف الفقاعة",
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filledTonal(
                          onPressed: () => _clearSelection(si),
                          icon: const Icon(Icons.restart_alt),
                          tooltip: "إلغاء التحديد الكلّي",
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // شارات سريعة (اسم/مبلغ/عملة)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _pill(
                          context,
                          icon: Icons.person,
                          label: mode == BubbleActionMode.cancel
                              ? (nameText.isEmpty
                                    ? "اسم الإلغاء: غير محدد"
                                    : "اسم الإلغاء: $nameText")
                              : (nameText.isEmpty
                                    ? "الاسم: غير محدد"
                                    : "الاسم: $nameText"),
                          color: mode == BubbleActionMode.cancel
                              ? _chipRed
                              : _chipIndigo,
                          onTap: () => _goStage(si, SelectionStage.name),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.edit, size: 16),
                                tooltip: "تحرير الاسم يدويًا",
                                onPressed: () =>
                                    _openNameManualDialog(si, nameText),
                                color: Colors.white,
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.backspace, size: 16),
                                tooltip: "مسح تحديد الاسم",
                                onPressed: () => _clearCategory(si, 'name'),
                                color: Colors.white,
                              ),
                            ],
                          ),
                        ),
                        if (mode == BubbleActionMode.add)
                          _pill(
                            context,
                            icon: Icons.numbers,
                            label: amountVal == null
                                ? "المبلغ: غير محدد"
                                : "المبلغ: ${amountVal.toStringAsFixed(2)}",
                            color: _chipTeal,
                            onTap: () => _goStage(si, SelectionStage.amount),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(Icons.edit, size: 16),
                                  tooltip: "تحرير المبلغ يدويًا",
                                  onPressed: () =>
                                      _openAmountManualDialog(si, amountVal),
                                  color: Colors.black,
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(Icons.backspace, size: 16),
                                  tooltip: "مسح تحديد المبلغ",
                                  onPressed: () {
                                    final sel = _selections[si];
                                    if (sel.amount != null &&
                                        sel.currencyToken != null &&
                                        sel.amount == sel.currencyToken) {
                                      _showClearAmountOrCurrencyDialog(si);
                                    } else {
                                      _clearCategory(si, 'amount');
                                    }
                                  },
                                  color: Colors.black,
                                ),
                              ],
                            ),
                          ),
                        if (mode == BubbleActionMode.add)
                          _pill(
                            context,
                            icon: Icons.currency_exchange,
                            label: currencyText == null
                                ? "العملة: غير محددة"
                                : "العملة: $currencyText",
                            color: _chipBlue,
                            onTap: () => _goStage(si, SelectionStage.currency),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(Icons.backspace, size: 16),
                                  tooltip: "مسح تحديد العملة",
                                  onPressed: () {
                                    final sel = _selections[si];
                                    if (sel.amount != null &&
                                        sel.currencyToken != null &&
                                        sel.amount == sel.currencyToken) {
                                      _showClearAmountOrCurrencyDialog(si);
                                    } else {
                                      _clearCategory(si, 'currency');
                                    }
                                  },
                                  color: Colors.black,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    if (mode == BubbleActionMode.add && hasMultiAmount) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: (wasSaved ? Colors.orange : Colors.amber)
                              .withOpacity(.10),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: (wasSaved ? Colors.orange : Colors.amber)
                                .withOpacity(.45),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              wasSaved
                                  ? 'تم حفظ الرسالة، لكن يوجد أكثر من مبلغ محتمل. يمكنك اختيار المبلغ الصحيح ونسخ الاسم أو أي مبلغ بشكل منفصل.'
                                  : 'تم العثور على أكثر من مبلغ داخل الرسالة. اختر الآن أي مبلغ تريد حفظه.',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: wasSaved
                                    ? Colors.orange[900]
                                    : Colors.amber[900],
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (amountVal != null)
                              Text(
                                'المبلغ المعتمد حاليًا: ${_fmtAmount(amountVal)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: () => _openMultiAmountPickerDialog(
                                    si,
                                    afterSave: wasSaved,
                                  ),
                                  icon: const Icon(Icons.rule),
                                  label: const Text('اختيار المبلغ'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: nameText.trim().isEmpty
                                      ? null
                                      : () => _copyNameToClipboard(si),
                                  icon: const Icon(Icons.copy_all),
                                  label: const Text('نسخ الاسم'),
                                ),
                                ...amountCandidates.map(
                                  (v) => OutlinedButton.icon(
                                    onPressed: () => _copyAmountToClipboard(v),
                                    icon: const Icon(Icons.copy),
                                    label: Text('نسخ ${_fmtAmount(v)}'),
                                  ),
                                ),
                                if (wasSaved)
                                  const Chip(
                                    label: Text('تم حفظها'),
                                    avatar: Icon(Icons.check_circle, size: 18),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],

                    // تعارض رقم/نص
                    if (mode == BubbleActionMode.add &&
                        _amountConflict.contains(si)) ...[
                      Row(
                        children: [
                          Chip(
                            label: const Text("تعارض في المبلغ (رقم/نص)"),
                            avatar: const Icon(
                              Icons.warning_amber,
                              color: Colors.red,
                            ),
                            backgroundColor: Colors.red.withOpacity(.1),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _openAmountConflictDialog(si),
                            icon: const Icon(Icons.rule),
                            label: const Text("مراجعة"),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],

                    // النص — فقاعات كلمات
                    ...List.generate(seg.lines.length, (li) {
                      final line = seg.lines[li];
                      final tokens = _tokensFromLine(line);
                      if (tokens.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: List.generate(tokens.length, (ti) {
                            final tok = tokens[ti];
                            return _buildTokenChip(
                              context: context,
                              segIndex: si,
                              lineIndex: li,
                              tokenIndex: ti,
                              token: tok,
                              tokensThisLine: tokens,
                            );
                          }),
                        ),
                      );
                    }),

                    // اختيار العملة من القائمة
                    if (mode == BubbleActionMode.cancel)
                      _buildCancelCandidatesPanel(context, si),

                    if (mode == BubbleActionMode.add &&
                        (_selections[si].stage == SelectionStage.currency ||
                            _selections[si].stage == SelectionStage.done))
                      _buildCurrencyPickerRow(context, si),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ====== عنصر شارة ======
  Widget _pill(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.white;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.25),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: textColor),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w700),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              DefaultTextStyle(
                style: TextStyle(color: textColor),
                child: trailing,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ====== موضع توكن ======
class _TokPos {
  final int line;
  final int index;
  const _TokPos(this.line, this.index);

  @override
  bool operator ==(Object other) =>
      other is _TokPos && other.line == line && other.index == index;

  @override
  int get hashCode => Object.hash(line, index);
}

// ====== حالة المقطع ======
class _SegmentSelection {
  SelectionStage stage;

  final Set<_TokPos> nameTokens = {};
  _TokPos? amount; // رقم
  _TokPos? currencyToken; // عملة من النص
  String? currencyFromMenu; // اسم عملة من القائمة
  String? currencyDetectedName; // اسم العملة المكتشفة من النص

  final Set<_TokPos> phoneLikeTokens = {};
  final Set<_TokPos> amountTextLockedTokens = {};

  _SegmentSelection({required this.stage});
}

class _SavedAddSummary {
  final int transactionId;
  final String name;
  final double amount;
  final String currency;
  final CompanyMovementType? companyMovementType;
  final DateTime date;

  const _SavedAddSummary({
    required this.transactionId,
    required this.name,
    required this.amount,
    required this.currency,
    this.companyMovementType,
    required this.date,
  });
}

class _CancelledSummary {
  final String name;
  final double amount;
  final String currency;
  final CompanyMovementType? companyMovementType;
  final DateTime date;

  const _CancelledSummary({
    required this.name,
    required this.amount,
    required this.currency,
    this.companyMovementType,
    required this.date,
  });
}

// ====== صف اقتراحات (احتياطي مستقبلي) ======
class _SuggestRow extends StatefulWidget {
  final String title;
  final List<String> items;
  final void Function(List<String> selected) onAdd;

  const _SuggestRow({
    required this.title,
    required this.items,
    required this.onAdd,
  });

  @override
  State<_SuggestRow> createState() => _SuggestRowState();
}

class _SuggestRowState extends State<_SuggestRow> {
  late final Map<String, bool> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {for (final i in widget.items) i: true};
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: widget.items.map((e) {
            final on = _selected[e] ?? false;
            return FilterChip(
              label: Text(e),
              selected: on,
              onSelected: (v) => setState(() => _selected[e] = v),
            );
          }).toList(),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              final chosen = _selected.entries
                  .where((kv) => kv.value)
                  .map((kv) => kv.key)
                  .toList();
              if (chosen.isNotEmpty) widget.onAdd(chosen);
            },
            icon: const Icon(Icons.playlist_add),
            label: const Text("إضافة المحدد"),
          ),
        ),
      ],
    );
  }
}

class _PendingTxDraft {
  final int segIndex;
  final String beneficiary;
  final double amount;
  final String currency;
  final CompanyMovementType? companyMovementType;
  final DateTime date;

  const _PendingTxDraft({
    required this.segIndex,
    required this.beneficiary,
    required this.amount,
    required this.currency,
    this.companyMovementType,
    required this.date,
  });
}

class _PendingCancelDraft {
  final int segIndex;
  final TransactionModel transaction;
  final DateTime date;

  const _PendingCancelDraft({
    required this.segIndex,
    required this.transaction,
    required this.date,
  });
}

class _DuplicateWarningItem {
  final _PendingTxDraft draft;
  final List<TransactionModel> exactCritical;
  final List<TransactionModel> sameNameAmountCurrency;
  final List<TransactionModel> sameNameOnly;

  const _DuplicateWarningItem({
    required this.draft,
    required this.exactCritical,
    required this.sameNameAmountCurrency,
    required this.sameNameOnly,
  });
}
