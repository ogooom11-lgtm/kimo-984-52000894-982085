// lib/screens/bubble_screen.dart — نسخة مُحسّنة تدعم عدّة ملفات وتراعي الإعدادات بالكامل
import 'dart:async';
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import '../bubble_prefs.dart';
import '../database_service.dart';
import '../models.dart';
import '../services/operation_log_service.dart';
import '../services/tx_history_service.dart';
import '../services/settings_words.dart';
import '../utils/amount_format.dart';
import '../utils/chunked_task.dart';
import '../widgets/operation_progress_bar.dart';
import '../widgets/scroll_edge_buttons.dart';
import 'add_edit_transaction_screen.dart';
import 'operations_log_screen.dart';
import 'settings_screen.dart';

// خدمات الكشف
import '../services/detection/name_detector.dart' as nd;
import '../services/detection/amount_detector.dart' as ad;
import '../services/detection/currency_detector.dart' as cd;
import '../services/detection/segment_splitter.dart';
import '../services/detection/text_tokens.dart' as tt;
import '../services/detection/edit_message.dart' as em;

/// مراحل التحديد
enum SelectionStage { name, amount, currency, done, newName }

enum BubbleActionMode { add, edit, cancel }

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

  /// توكنات كل سطر (تُحسب مرة واحدة)
  late final List<List<String>> tokenLines = [
    for (final line in lines)
      List<String>.unmodifiable(tt.tokensFromLine(line)),
  ];
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
  static const _chipEdit = Color(0xFFE08600); // amber — رسائل التعديل
  static const _forbiddenColor = Color(0xFFD84315); // deep orange 800
  static const _newNameColor = Color(0xFF00897B); // teal — الاسم الجديد

  // ألوان الأدوار (قابلة للتخصيص من الإعدادات)
  Color get _nameColor => _prefs.nameColorValue;
  Color get _amountColor => _prefs.amountColorValue;
  Color get _currencyColor => _prefs.currencyColorValue;

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
  late List<String> _editKeywords;
  late Map<String, double> _amountWordValues;
  late List<String> _bubbleReadyNames;
  late List<String> _companyUserNames;
  late List<BubbleQuickActionConfig> _bubbleQuickActions;
  late List<String> _forbiddenWords;
  late List<String> _forbiddenPhrases;
  late BubbleUiPrefs _prefs;
  late nd.NameDetectorConfig _nameConfig;
  late tt.PhraseSet _forbiddenPhraseSet;
  late tt.PhraseSet _forbiddenWordSet;
  late List<TransactionModel> _allTransactions;
  late Map<int, String> _accountNamesById;
  late List<String> _knownBeneficiaryNames;

  // كاش للتوكنات والأسماء المطبّعة
  final Map<String, List<String>> _tokenCache = {};
  Expando<String> _txNormNames = Expando<String>('txNormName');

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

  // رسائل التعديل: الحركة المختارة، الحقول المختارة للتعديل، اسم بحث يدوي،
  // فتح قائمة النتائج بعد اختيار الحركة، وملخص ما تم تعديله
  final Map<int, int> _editSelectedTxIds = {};
  final Map<int, Set<em.EditField>> _editFields = {};
  final Map<int, String> _editSearchQueries = {};
  final Set<int> _editPickerOpen = {};
  final Map<int, _EditedSummary> _editedSummaries = {};

  /// التعديل: الاسم الجديد المكتوب/الملصوق يدويًا (وإلا الكلمات المحددة له)
  final Map<int, String> _editNewNameOverride = {};

  /// نتائج البحث عن الحركة (إلغاء/تعديل) مع طريقة المطابقة لكل حركة
  final Map<int, List<_TargetHit>> _targetHits = {};

  /// فهرس أسماء حركات الحساب (الحالية + السابقة من سجل التعديل) للبحث السريع
  _TargetSearchIndex? _searchIndex;
  Future<_TargetSearchIndex>? _searchIndexBuilding;
  int _searchIndexGeneration = 0;

  /// الأسماء السابقة لحركات الحساب من سجل التعديل (تُقرأ مرة واحدة)
  Map<int, List<String>>? _pastNamesByTx;
  bool _pastNamesLoading = false;

  // تعارض/اختيارات المبلغ
  final Map<int, double> _amountOverride = {};
  final Set<int> _amountConflict = {};
  final Map<int, double> _amountTextCandidate = {};
  final Map<int, List<double>> _amountCandidatesCache = {};

  /// رسائل فيها أكثر من مبلغ وأكثر من عملة: لا يُعتمد المبلغ تلقائيًا
  final Map<int, _MoneyAmbiguity> _moneyAmbiguity = {};

  /// المبلغ الثاني للحركة (اختياري) وعملته — رسالة فيها مبلغان بعملتين
  final Map<int, double> _secondAmount = {};
  final Map<int, String> _secondCurrency = {};

  // إدخال يدوي للاسم
  final Map<int, String> _nameOverride = {};
  BubbleActionMode _viewMode = BubbleActionMode.add;

  /// قائمة الفقاعات (لزرّي الصعود إلى الأعلى والنزول إلى الأسفل)
  final ScrollController _listScroll = ScrollController();
  bool _isSending = false;
  final Set<int> _savedSegments = {};
  final Map<int, _SavedAddSummary> _savedAddSummaries = {};
  final Map<int, _CancelledSummary> _cancelledSummaries = {};

  // تقدم العمليات (شريط سفلي بالنسبة المئوية)
  final ValueNotifier<OperationProgress?> _progress =
      ValueNotifier<OperationProgress?>(null);
  bool _analyzing = false;
  int _analysisGeneration = 0;
  bool _legendExpanded = false;

  bool get _busy => _isSending || _analyzing;

  void _setProgress(OperationProgress? p) {
    if (mounted) _progress.value = p;
  }

  @override
  void initState() {
    super.initState();

    _loadSettingsAndPrefs();
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
    _rebuildNameConfig();

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
      final parsed = texts.expand(_splitByHeader).toList();
      // رتب المقاطع زمنيًا إن أمكن — ترتيب ثابت: الرسائل بنفس الوقت (أو بدون
      // وقت مثل صفوف ملف Excel) تبقى بترتيبها الأصلي
      final order = List<int>.generate(parsed.length, (i) => i)
        ..sort((x, y) {
          final ta = parsed[x].timestamp, tb = parsed[y].timestamp;
          var c = 0;
          if (ta == null && tb != null) {
            c = 1;
          } else if (ta != null && tb == null) {
            c = -1;
          } else if (ta != null && tb != null) {
            c = ta.compareTo(tb);
          }
          return c != 0 ? c : x.compareTo(y);
        });
      _segments = [for (final i in order) parsed[i]];
    }

    // التحليل يتم على دفعات بعد ظهور الشاشة حتى لا يتجمد التطبيق
    _analyzing = true;
    _setProgress(
      OperationProgress(
        label: 'جارٍ تحليل الرسائل...',
        done: 0,
        total: _segments.length,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _runInitialAnalysis();
    });
  }

  @override
  void dispose() {
    _analysisGeneration++;
    _progress.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  Settings _defaultSettings() => Settings(
    nameKeywords: const ['المستفيد', 'إلى', 'ل', 'لـ'],
    amountKeywords: const ['المبلغ', 'قيمة', 'amount', '\$'],
    currencyMap: const {'\$': 'دولار'},
    ignoredWords: const [],
    lineIgnoredWords: const [],
    cancelKeywords: const ['الغاء'],
    editKeywords: const ['تعديل'],
    amountWordValues: const {},
    bubbleReadyNames: const [],
    bubbleQuickActions: const [],
    companyUserNames: const [],
  );

  void _loadSettingsAndPrefs() {
    _settings = DatabaseService.getSettings() ?? _defaultSettings();
    _nameKeywords = List.of(_settings.nameKeywords);
    _amountKeywords = List.of(_settings.amountKeywords);
    _currencyMap = Map.of(_settings.currencyMap);
    _ignored = List.of(_settings.ignoredWords);
    _lineIgnored = List.of(_settings.lineIgnoredWords);
    _cancelKeywords = List.of(_settings.cancelKeywords);
    _editKeywords = List.of(_settings.editKeywords);
    _amountWordValues = Map.of(_settings.amountWordValues);
    _bubbleReadyNames = List.of(_settings.bubbleReadyNames);
    _companyUserNames = List.of(_settings.companyUserNames);
    _bubbleQuickActions = List.of(_settings.bubbleQuickActions);
    _forbiddenWords = List.of(_settings.forbiddenWords);
    _forbiddenPhrases = List.of(_settings.forbiddenPhrases);
    _prefs = BubbleUiPrefs.fromSettings(_settings);
  }

  void _rebuildNameConfig() {
    _nameConfig = nd.NameDetectorConfig(
      nameKeywords: _nameKeywords,
      knownNames: _knownBeneficiaryNames,
      ignoredWords: _ignored,
      lineIgnoredWords: _lineIgnored,
      currencyWords: [..._currencyMap.keys, ..._currencyMap.values],
      forbiddenWords: _forbiddenWords,
      forbiddenPhrases: _forbiddenPhrases,
      amountKeywords: _amountKeywords,
      cancelKeywords: _cancelKeywords,
      editKeywords: _editKeywords,
    );
    _forbiddenPhraseSet = tt.PhraseSet(_forbiddenPhrases);
    _forbiddenWordSet = tt.PhraseSet(_forbiddenWords);
  }

  /// يعيد تحميل الإعدادات بعد تعديلها (من قائمة الكلمة أو من صفحة الإعدادات)
  void _reloadSettings() {
    _loadSettingsAndPrefs();
    _rebuildNameConfig();
    _tokenCache.clear();
    for (var i = 0; i < _selections.length; i++) {
      _computeForbiddenFor(_segments[i], _selections[i]);
    }
    _amountCandidatesCache.clear();
  }

  // ====== التحليل التدريجي ======
  void _analyzeNext() {
    final i = _selections.length;
    final seg = _segments[i];
    final sel = _autoDetect(seg, i);
    _selections.add(sel);
    final mode = _modeForSegment(seg);
    _segmentModes[i] = mode;
    if (mode == BubbleActionMode.cancel) {
      sel.stage = SelectionStage.name;
    }
  }

  Future<void> _runInitialAnalysis() async {
    final gen = ++_analysisGeneration;
    final slice = Stopwatch()..start();
    final uiTick = Stopwatch()..start();

    while (mounted &&
        gen == _analysisGeneration &&
        _selections.length < _segments.length) {
      _analyzeNext();
      if (slice.elapsedMilliseconds >= 12) {
        _setProgress(
          OperationProgress(
            label: 'جارٍ تحليل الرسائل...',
            done: _selections.length,
            total: _segments.length,
          ),
        );
        if (uiTick.elapsedMilliseconds >= 250) {
          setState(() {});
          uiTick
            ..reset()
            ..start();
        }
        await yieldToUi();
        slice
          ..reset()
          ..start();
      }
    }
    if (!mounted || gen != _analysisGeneration) return;

    // الترتيب: الإضافات أولًا، ثم التعديلات، ثم الإلغاء
    final hasAdd = _segmentModes.values.any((m) => m == BubbleActionMode.add);
    final hasEdit = _segmentModes.values.any((m) => m == BubbleActionMode.edit);
    setState(() {
      _analyzing = false;
      _viewMode = hasAdd
          ? BubbleActionMode.add
          : (hasEdit ? BubbleActionMode.edit : BubbleActionMode.cancel);
    });
    _setProgress(null);

    for (var i = 0; i < _selections.length; i++) {
      if (_needsTarget(i)) {
        _requestCancelCandidates(i);
      }
    }
  }

  /// إعادة تحليل الفقاعات غير المحفوظة بعد تغيير الإعدادات
  Future<void> _reanalyzeUnsaved() async {
    if (_busy) return;
    final targets = <int>[
      for (var i = 0; i < _selections.length; i++)
        if (!_savedSegments.contains(i) &&
            !_cancelledSummaries.containsKey(i) &&
            !_editedSummaries.containsKey(i))
          i,
    ];
    if (targets.isEmpty) return;

    final gen = ++_analysisGeneration;
    setState(() => _analyzing = true);
    try {
      await runTimeSliced(
        total: targets.length,
        isCancelled: () => !mounted || gen != _analysisGeneration,
        onProgress: (done, total) => _setProgress(
          OperationProgress(
            label: 'جارٍ إعادة تحليل الفقاعات...',
            done: done,
            total: total,
          ),
        ),
        work: (k) {
          final i = targets[k];
          if (i >= _selections.length) return;
          _amountOverride.remove(i);
          _amountConflict.remove(i);
          _amountTextCandidate.remove(i);
          _amountCandidatesCache.remove(i);
          _secondAmount.remove(i);
          _secondCurrency.remove(i);
          // الاسم اليدوي (_nameOverride) يبقى كما هو
          _selections[i] = _autoDetect(_segments[i], i);
          _refreshStageForSegment(i);
          _invalidateCancelCandidates(i);
        },
      );
    } finally {
      if (mounted) {
        setState(() => _analyzing = false);
      }
      _setProgress(null);
    }
    if (!mounted) return;
    for (final i in targets) {
      if (i < _selections.length && _needsTarget(i)) {
        _requestCancelCandidates(i);
      }
    }
  }

  // ====== أدوات تصميم ======
  Color _muted(BuildContext ctx) =>
      Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.6);

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

  /// نوع الفقاعة حسب كلمات الإلغاء والتعديل في الإعدادات
  BubbleActionMode _modeForSegment(ParsedSegment seg) {
    // عنوان صف الملف المستورد («صف 5 • اسم الملف») وصفي فقط ولا يُفحص
    final header = seg.senderName.isEmpty ? '' : seg.header;
    final kind = em.classifyMessage(
      '$header\n${seg.lines.join('\n')}',
      cancelKeywords: _cancelKeywords,
      editKeywords: _editKeywords,
      normalize: _normalizeForSearch,
    );
    switch (kind) {
      case em.MessageKind.cancel:
        return BubbleActionMode.cancel;
      case em.MessageKind.edit:
        return BubbleActionMode.edit;
      case em.MessageKind.add:
        return BubbleActionMode.add;
    }
  }

  /// فقاعات تحتاج اختيار حركة موجودة (إلغاء أو تعديل)
  bool _needsTarget(int segIndex) {
    final m = _modeOf(segIndex);
    return m == BubbleActionMode.cancel || m == BubbleActionMode.edit;
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
      _clearEditState(segIndex);
      if (mode == BubbleActionMode.cancel) {
        _selections[segIndex].stage = SelectionStage.name;
      } else {
        _refreshStageForSegment(segIndex);
      }
    });
    if (_needsTarget(segIndex)) {
      _requestCancelCandidates(segIndex);
    }
  }

  void _clearEditState(int segIndex) {
    _editSelectedTxIds.remove(segIndex);
    _editFields.remove(segIndex);
    _editSearchQueries.remove(segIndex);
    _editPickerOpen.remove(segIndex);
    _editNewNameOverride.remove(segIndex);
    if (segIndex < _selections.length) {
      _selections[segIndex].newNameTokens.clear();
    }
  }

  // ====== التعديل: اسم البحث + الاسم الجديد ======

  /// نص كلمات محددة من الرسالة (بترتيبها)
  String _textOfTokens(ParsedSegment seg, Set<_TokPos> tokens) {
    final sorted = tokens.toList()
      ..sort(
        (a, b) =>
            a.line != b.line ? a.line.compareTo(b.line) : a.index - b.index,
      );
    final parts = <String>[];
    for (final p in sorted) {
      if (p.line < 0 || p.line >= seg.lines.length) continue;
      final toks = _tokensFromLine(seg.lines[p.line]);
      if (p.index < 0 || p.index >= toks.length) continue;
      if (!_isIgnoredWord(toks[p.index])) parts.add(toks[p.index]);
    }
    return parts.join(' ');
  }

  /// الاسم الجديد في رسالة التعديل (المكتوب يدويًا أولًا ثم الكلمات المحددة)
  String _editNewName(int segIndex) {
    final manual = (_editNewNameOverride[segIndex] ?? '').trim();
    if (manual.isNotEmpty) return manual;
    if (segIndex >= _selections.length) return '';
    final sel = _selections[segIndex];
    if (sel.newNameTokens.isEmpty) return '';
    return _textOfTokens(_segments[segIndex], sel.newNameTokens).trim();
  }

  /// الاسم الجديد مختلف عن اسم الحركة المختارة: يُختار «تعديل الاسم» تلقائيًا
  void _syncEditNameField(int segIndex) {
    final tx = _selectedEditTx(segIndex);
    if (tx == null) return;
    final chosen = _editFields.putIfAbsent(segIndex, () => <em.EditField>{});
    final p = _editProposalsFor(
      segIndex,
      tx,
    ).firstWhere((p) => p.field == em.EditField.name);
    if (p.available) {
      chosen.add(em.EditField.name);
    } else {
      chosen.remove(em.EditField.name);
    }
  }

  void _setEditNewName(int segIndex, String? value) {
    final v = value?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    setState(() {
      _selections[segIndex].newNameTokens.clear();
      if (v.isEmpty) {
        _editNewNameOverride.remove(segIndex);
      } else {
        _editNewNameOverride[segIndex] = v;
      }
      _syncEditNameField(segIndex);
    });
  }

  Future<void> _openEditNewNameDialog(int segIndex) async {
    final result = await _editTextDialog(
      title: 'الاسم الجديد',
      initial: _editNewName(segIndex),
      hint: 'الاسم الذي سيصبح اسم الحركة بعد التعديل',
    );
    if (!mounted || result == null || segIndex >= _selections.length) return;
    _setEditNewName(segIndex, result);
  }

  /// نص الحافظة كسطر واحد (للصق الاسم مكان الاسم الحالي)
  Future<String?> _clipboardName() async {
    var text = '';
    try {
      final data = await Clipboard.getData('text/plain');
      text = data?.text ?? '';
    } catch (_) {
      text = '';
    }
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) {
      _snack('📋 الحافظة فارغة');
      return null;
    }
    if (text.length > 120) text = text.substring(0, 120).trim();
    return text;
  }

  /// زر اللصق بجانب فقاعة الاسم: نص الحافظة يصبح الاسم (في التعديل: اسم البحث)
  Future<void> _pasteName(int segIndex) async {
    final text = await _clipboardName();
    if (text == null || !mounted || segIndex >= _selections.length) return;
    if (_modeOf(segIndex) == BubbleActionMode.edit) {
      _setEditSearch(segIndex, text);
      _snack('تم لصق اسم البحث: $text');
      return;
    }
    setState(() {
      _nameOverride[segIndex] = text;
      _selections[segIndex].nameTokens.clear();
      _invalidateCancelCandidates(segIndex);
      _refreshStageForSegment(segIndex);
    });
    if (_needsTarget(segIndex)) _requestCancelCandidates(segIndex);
    _snack('تم لصق الاسم: $text');
  }

  Future<void> _pasteEditNewName(int segIndex) async {
    final text = await _clipboardName();
    if (text == null || !mounted || segIndex >= _selections.length) return;
    _setEditNewName(segIndex, text);
    _snack('تم لصق الاسم الجديد: $text');
  }

  List<String> _nameWords(String value) => _normalizeForSearch(
    value,
  ).split(' ').where((word) => word.trim().isNotEmpty).toList();

  /// اسم الحركة المطبّع (مع كاش لكل كائن حتى لا يُعاد التطبيع في كل مقارنة)
  String _txNormName(TransactionModel tx) =>
      _txNormNames[tx] ??= _normalizeForSearch(tx.beneficiary);

  // ====== البحث عن الحركة لرسائل الإلغاء والتعديل ======

  /// نتيجة البحث لهذه الحركة في هذه الفقاعة (مطابقة تامة؟ باسم سابق؟)
  _TargetHit? _hitFor(int segIndex, TransactionModel tx) {
    for (final h in _targetHits[segIndex] ?? const <_TargetHit>[]) {
      if (identical(h.tx, tx) || h.tx.id == tx.id) return h;
    }
    return null;
  }

  bool _isExactHit(int segIndex, TransactionModel tx) =>
      _hitFor(segIndex, tx)?.exact ?? false;

  /// الحركة «مضافة» (قابلة للإلغاء/التعديل كحركة جارية)
  bool _isActiveTx(TransactionModel tx) => _isCompanyAccount
      ? tx.companyMovementType != null && !tx.companyMovementType!.isCancelled
      : tx.status == TransactionStatus.added;

  /// إبطال فهرس الأسماء (بعد إضافة/تعديل/تراجع)
  void _invalidateSearchIndex() {
    _searchIndex = null;
    _searchIndexBuilding = null;
    _searchIndexGeneration++;
  }

  /// فهرس أسماء حركات هذا الحساب (يُبنى مرة واحدة على دفعات)
  Future<_TargetSearchIndex> _ensureSearchIndex() {
    final ready = _searchIndex;
    if (ready != null) return Future<_TargetSearchIndex>.value(ready);
    return _searchIndexBuilding ??= _buildSearchIndex();
  }

  Future<_TargetSearchIndex> _buildSearchIndex() async {
    final gen = _searchIndexGeneration;
    final accountTxs = [
      for (final tx in _allTransactions)
        if (tx.accountId == widget.account.id) tx,
    ];
    final past = _pastNamesByTx ?? const <int, List<String>>{};
    final entries = <_NameEntry>[];
    await runTimeSliced(
      total: accountTxs.length,
      isCancelled: () => !mounted,
      budget: const Duration(milliseconds: 16),
      work: (i) {
        final tx = accountTxs[i];
        final norm = _txNormName(tx);
        if (norm.isNotEmpty) {
          entries.add(_NameEntry(tx, norm, _nameWords(norm), null));
        }
        for (final old in past[tx.id] ?? const <String>[]) {
          final n = _normalizeForSearch(old);
          if (n.isEmpty || n == norm) continue;
          entries.add(_NameEntry(tx, n, _nameWords(n), old));
        }
      },
    );
    final index = _TargetSearchIndex(entries);
    if (gen == _searchIndexGeneration) {
      _searchIndex = index;
      _searchIndexBuilding = null;
    }
    return index;
  }

  /// الأسماء السابقة لحركات الحساب من سجل التعديل: رسالة الإلغاء/التعديل قد
  /// تكون بالاسم القديم. تُقرأ مرة واحدة ثم يُعاد البحث في الفقاعات.
  Future<void> _ensurePastNames() async {
    if (_pastNamesByTx != null || _pastNamesLoading) return;
    _pastNamesLoading = true;
    final out = <int, List<String>>{};
    try {
      final edited = [
        for (final tx in _allTransactions)
          if (tx.accountId == widget.account.id &&
              TxHistoryService.hasHistory(tx.id))
            tx,
      ];
      for (final tx in edited) {
        try {
          final states = txPastStates(
            await TxHistoryService.entriesFor(tx.id),
            name: tx.beneficiary,
            amount: tx.amount,
            currency: tx.currency,
          );
          final names = <String>{
            for (final s in states)
              if (s.name.trim().isNotEmpty) s.name.trim(),
          };
          if (names.isNotEmpty) out[tx.id] = names.toList();
        } catch (e) {
          debugPrint('BubbleScreen history error: $e');
        }
        if (!mounted) return;
      }
    } finally {
      _pastNamesLoading = false;
    }
    if (!mounted) return;
    _pastNamesByTx = out;
    if (out.isEmpty) return;
    setState(() {
      _invalidateSearchIndex();
      for (var i = 0; i < _selections.length; i++) {
        if (_needsTarget(i)) {
          _cancelCandidateQueries.remove(i);
          _cancelCandidatesCache.remove(i);
          _cancelCandidatesLoading.remove(i);
        }
      }
    });
    for (var i = 0; i < _selections.length; i++) {
      if (_needsTarget(i)) _requestCancelCandidates(i);
    }
  }

  /// نتائج البحث بالاسم داخل هذا الحساب (بالاسم الحالي أو السابق للحركة).
  /// للإلغاء: الحركات القابلة للإلغاء في حسابات الشركات؛ للتعديل: كل حركات
  /// الحساب. الحركات المضافة بعد وقت الرسالة تُتجاهل (لا يمكن أن تكون المقصودة).
  Future<List<_TargetHit>> _computeCancelCandidates(
    String name, {
    bool forEdit = false,
    DateTime? before,
  }) async {
    final index = await _ensureSearchIndex();
    if (!mounted) return const [];
    final wanted = _normalizeForSearch(name);
    final words = _nameWords(wanted);
    // أوقات الرسائل بالدقيقة: كل ما أضيف خلال دقيقة الرسالة يبقى
    final limit = before == null
        ? null
        : DateTime(
            before.year,
            before.month,
            before.day,
            before.hour,
            before.minute,
          ).add(const Duration(minutes: 1));
    final hits = <_TargetHit>[
      for (final h in index.search(wanted, words))
        if ((forEdit ||
                !_isCompanyAccount ||
                (h.tx.companyMovementType != null &&
                    !h.tx.companyMovementType!.isCancelled)) &&
            (limit == null || h.tx.date.isBefore(limit)))
          h,
    ];

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

    hits.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) return scoreCompare;
      // الاسم الحالي قبل الاسم السابق
      final pastCompare = (a.pastName == null ? 0 : 1).compareTo(
        b.pastName == null ? 0 : 1,
      );
      if (pastCompare != 0) return pastCompare;
      final statusCompare = statusRank(
        a.tx.status,
      ).compareTo(statusRank(b.tx.status));
      if (statusCompare != 0) return statusCompare;
      final dateCompare = b.tx.date.compareTo(a.tx.date);
      if (dateCompare != 0) return dateCompare;
      return b.tx.id.compareTo(a.tx.id);
    });

    return hits;
  }

  String _cancelQueryForSegment(int segIndex) =>
      _normalizeForSearch(_targetSearchName(segIndex));

  /// الاسم الذي نبحث به عن الحركة. في التعديل يمكن كتابة اسم بحث يدويًا، وإلا
  /// فهو الاسم المحدد في الرسالة.
  String _targetSearchName(int segIndex) {
    if (_modeOf(segIndex) == BubbleActionMode.edit) {
      final manual = (_editSearchQueries[segIndex] ?? '').trim();
      if (manual.isNotEmpty) return manual;
    }
    return _buildSelectedName(
      _segments[segIndex],
      _selections[segIndex],
      segIndex,
    ).trim();
  }

  void _invalidateCancelCandidates(int segIndex) {
    _targetHits.remove(segIndex);
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
    if (!mounted || segIndex >= _selections.length) return;
    if (!_needsTarget(segIndex)) return;
    final name = _targetSearchName(segIndex);
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

    // رسالة الإلغاء/التعديل قد تكون بالاسم القديم للحركة
    unawaited(_ensurePastNames());

    final gen = _searchIndexGeneration;
    _computeCancelCandidates(
      name,
      forEdit: _modeOf(segIndex) == BubbleActionMode.edit,
      before: _segments[segIndex].timestamp,
    ).then((hits) {
      if (!mounted || segIndex >= _selections.length) return;
      final currentQuery = _cancelQueryForSegment(segIndex);
      if (currentQuery != query) return;
      if (gen != _searchIndexGeneration) {
        // تغيّر الفهرس أثناء البحث (أسماء سابقة/حركات جديدة): نعيد البحث
        _cancelCandidatesLoading.remove(segIndex);
        _cancelCandidateQueries.remove(segIndex);
        _requestCancelCandidates(segIndex);
        return;
      }
      setState(() {
        _cancelCandidatesLoading.remove(segIndex);
        _cancelCandidateQueries[segIndex] = query;
        _targetHits[segIndex] = hits;
        _cancelCandidatesCache[segIndex] = [for (final h in hits) h.tx];
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

  // ====== تقسيم النص حسب هيدر واتساب أو فواصل صفوف الملفات ======
  List<ParsedSegment> _splitByHeader(String input) => [
    for (final raw in SegmentSplitter.split(input))
      ParsedSegment(
        header: raw.header,
        senderName: raw.senderName,
        timestamp: raw.timestamp,
        lines: raw.lines,
      ),
  ];

  // ====== تنظيف التوكنات (مع حذف الرموز بين الأرقام المتتالية) ======
  bool _isAsciiDigit(int code) => code >= 0x30 && code <= 0x39;
  bool _isArabicDigit(int code) => code >= 0x0660 && code <= 0x0669;

  String _cleanToken(String w) => tt.cleanToken(w);

  /// توكنات سطر (نفس المقسّم المستخدم في كاشف الاسم، مع كاش)
  List<String> _tokensFromLine(String line) => _tokenCache.putIfAbsent(
    line,
    () => List<String>.unmodifiable(tt.tokensFromLine(line)),
  );

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

    for (final raw in [..._currencyMap.keys, ..._currencyMap.values]) {
      final v = _cleanToken(raw);
      if (v.isNotEmpty) out.add(v);

      // العملة من أكثر من كلمة («ليرة سورية»): كل كلمة منها تلميح عملة أيضًا
      final words = raw.trim().split(RegExp(r'\s+'));
      if (words.length < 2) continue;
      for (final w in words) {
        final c = _cleanToken(w);
        if (c.length >= 2) out.add(c);
      }
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
        // باقي كلمات عملة من أكثر من كلمة («سورية» في «ليرة سورية»)
        if (sel.currencyToken != pos && sel.isCurrencyAt(pos)) continue;

        if (sel.currencyToken == pos) {
          // كلمة عملة بلا أرقام تُحذف كلها (ولو كانت أول كلمة من «ليرة سورية»)
          if (!tt.tokenHasDigit(tok)) continue;
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

  /// موقع العملة المختارة داخل أسطر المبلغ بعد حذفها منها (رقمها = عدد الكلمات
  /// المحفوظة قبلها): يمنع ضم «مليون» في السطر التالي لسطر انتهى بعملة.
  ad.Position? _currencyAnchorIn(
    List<_ForwardLine> rows,
    _SegmentSelection sel,
  ) {
    final c = sel.currencyToken;
    if (c == null || c.line < 0 || c.line >= rows.length) return null;
    final before = rows[c.line].originals.where((o) => o.index < c.index);
    return ad.Position(c.line, before.length);
  }

  /// أسطر الكشف بمواقع الكلمات الأصلية (لكاشف العملة)
  List<List<cd.PreparedToken>> _preparedFromForward(
    List<_ForwardLine> rows,
  ) => [
    for (final row in rows)
      [
        for (int k = 0; k < row.tokens.length; k++)
          cd.PreparedToken(
            token: row.tokens[k],
            originalPos: Point(row.originals[k].line, row.originals[k].index),
          ),
      ],
  ];

  /// يعتمد العملة المكتشفة، مع باقي كلماتها إن كانت من أكثر من كلمة
  void _setCurrencyFromDetect(
    _SegmentSelection sel,
    cd.CurrencyDetectResult res,
  ) {
    final p = res.pos;
    if (p == null) return;
    final start = _TokPos(p.x, p.y);
    sel.currencyToken = start;
    sel.currencyPhraseStart = start;
    sel.currencyPhraseTokens
      ..clear()
      ..addAll([
        for (final q in res.positions)
          if (q != p) _TokPos(q.x, q.y),
      ]);
  }

  /// العملة المكتوبة في سطر معيّن (بدون كلمات الاسم)، أو null
  _LineCurrency? _currencyOnLine(
    ParsedSegment seg,
    _SegmentSelection sel,
    int lineIndex,
  ) {
    if (lineIndex < 0 || lineIndex >= seg.lines.length) return null;
    final toks = _tokensFromLine(seg.lines[lineIndex]);
    final row = <cd.PreparedToken>[
      for (int ti = 0; ti < toks.length; ti++)
        if (!sel.nameTokens.contains(_TokPos(lineIndex, ti)) &&
            !_isIgnoredWord(toks[ti]))
          cd.PreparedToken(token: toks[ti], originalPos: Point(lineIndex, ti)),
    ];
    if (row.isEmpty) return null;
    final res = cd.CurrencyDetector.detectPrepared(
      preparedTokensByLine: [row],
      currencyMap: _currencyMap,
    );
    final p = res.pos;
    final name = res.detectedDisplayName?.trim() ?? '';
    if (p == null || name.isEmpty) return null;
    return _LineCurrency(
      start: _TokPos(p.x, p.y),
      extra: {
        for (final q in res.positions)
          if (q != p) _TokPos(q.x, q.y),
      },
      name: name,
    );
  }

  void _applyLineCurrency(_SegmentSelection sel, _LineCurrency c) {
    sel.currencyToken = c.start;
    sel.currencyPhraseStart = c.start;
    sel.currencyPhraseTokens
      ..clear()
      ..addAll(c.extra);
    sel.currencyDetectedName = c.name;
    sel.currencyFromMenu = null;
  }

  /// آخر كلمة فعلية في السطر عملة («10.000 سوري» أو «250$» أو «ليرة سورية»)
  bool _lineEndsWithCurrency(
    _SegmentSelection sel,
    int lineIndex,
    List<String> tokens,
  ) {
    for (int ti = tokens.length - 1; ti >= 0; ti--) {
      final pos = _TokPos(lineIndex, ti);
      final tok = tokens[ti];
      if (sel.nameTokens.contains(pos) ||
          sel.phoneLikeTokens.contains(pos) ||
          _isPhoneLike(tok) ||
          _isIgnoredWord(tok)) {
        continue;
      }
      return sel.isCurrencyAt(pos) ||
          tt.containsCurrencySymbol(tok) ||
          cd.CurrencyDetector.phraseAt(
                tokens: tokens,
                index: ti,
                currencyMap: _currencyMap,
              ) !=
              null;
    }
    return false;
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
        if (sel.currencyToken != pos && sel.isCurrencyAt(pos)) continue;

        if (sel.currencyToken == pos) {
          // كلمة عملة بلا أرقام تُحذف كلها (ولو كانت أول كلمة من «ليرة سورية»)
          if (!tt.tokenHasDigit(tok)) continue;
          tok = _stripDetectedCurrency(tok);
          tok = _cleanToken(tok);
          if (tok.isEmpty) continue;
        }

        keptTokens.add(tok);
        keptOriginals.add(pos);
      }
    }

    // كلمة مقدار في سطر بعده («250» ثم «الف»): تُحسب مع السطر المضغوط، إلا إذا
    // انتهى السطر بعملة («10.000 سوري») أو برقم كبير: «مليون» بعده مبلغ آخر
    final extraLines = <String>[];
    if (keptTokens.isNotEmpty &&
        !_lineEndsWithCurrency(sel, lineIndex, tokensThisLine) &&
        ad.AmountDetector.canTakeMagnitudeLine(
          keptTokens,
          customWordValues: _amountWordValues,
        )) {
      for (int li = lineIndex + 1; li < seg.lines.length; li++) {
        final toks = _tokensFromLine(seg.lines[li]);
        final next = <String>[];
        for (int ti = 0; ti < toks.length; ti++) {
          final pos = _TokPos(li, ti);
          if (sel.nameTokens.contains(pos)) continue;
          if (sel.phoneLikeTokens.contains(pos)) continue;
          if (_isIgnoredWord(toks[ti])) continue;
          next.add(toks[ti]);
        }
        if (next.isEmpty) continue;
        if (ad.AmountDetector.isMagnitudeOnlyLine(
          next,
          currencyHints: _currencyHintsFromSettings(),
        )) {
          extraLines.add(next.join(' '));
        }
        break;
      }
    }

    final amtRes = ad.AmountDetector.detect(
      [keptTokens.join(' '), ...extraLines],
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

      // رسالة بأكثر من عملة: عملة المبلغ المختار هي المكتوبة في سطره
      _moneyAmbiguity[segIndex]?.autoPicked = false;
      if (_moneyAmbiguity.containsKey(segIndex) &&
          sel.currencyFromMenu == null &&
          _hasAmountFor(segIndex, sel)) {
        final c = _currencyOnLine(seg, sel, lineIndex);
        if (c != null) _applyLineCurrency(sel, c);
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

    // 2.5) الكلمات/الجمل الممنوعة
    _computeForbiddenFor(seg, sel);

    // 3) الاسم: فحص كل الأسطر ومقارنتها واعتماد الأفضل
    final nameRes = nd.NameDetector.detectTokens(
      tokenLines: seg.tokenLines,
      senderName: seg.senderName,
      config: _nameConfig,
    );

    nameRes.tokensByLine.forEach((li, idxs) {
      final toks = _tokensFromLine(seg.lines[li]);
      for (final ti in idxs) {
        if (ti >= 0 && ti < toks.length && !_isIgnoredWord(toks[ti])) {
          sel.nameTokens.add(_TokPos(li, ti));
        }
      }
    });
    sel.nameCandidates = nameRes.candidates;
    sel.nameAmbiguous = nameRes.ambiguous;
    sel.nameReason = nameRes.reason;

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

    // 4) العملة على النص المنظف (بمواقع الكلمات الأصلية؛ والعملة قد تكون من
    //    أكثر من كلمة مثل «ليرة سورية»)
    final currencyForward = _buildForwardLinesForCurrency(seg, sel);

    final curRes = cd.CurrencyDetector.detectPrepared(
      preparedTokensByLine: _preparedFromForward(currencyForward),
      currencyMap: _currencyMap,
    );

    _setCurrencyFromDetect(sel, curRes);

    sel.currencyDetectedName = curRes.detectedDisplayName;

    if (sel.currencyDetectedName != null &&
        sel.currencyDetectedName!.trim().isNotEmpty) {
      sel.currencyFromMenu = null;
    }

    _suggestCurrencySymbols.addAll(curRes.suggestSymbols);
    _suggestCurrencyNames.addAll(curRes.suggestNames);

    // 6) تعارض في المبلغ: أكثر من مبلغ وأكثر من عملة (لا نعرف أي مبلغ لأي
    //    عملة)، أو مبلغان مختلفان أكيدان («50,000 ل.س.ج» و«50,مليون»)، أو المبلغ
    //    بالحروف غير المبلغ بالأرقام. حسب الإعدادات: يختار المستخدم المبلغ
    //    بنفسه (مع تحذير)، أو يُعتمد الأرجح تلقائيًا مع تنبيه. العملة تبقى
    //    المكتشفة.
    _moneyAmbiguity.remove(segIndex);
    final multiCurrency =
        amtRes.candidateValues.length >= 2 && curRes.hasMultipleCurrencies;
    if (multiCurrency || amtRes.hasConflictingAmounts) {
      final confirm = _prefs.confirmMultiAmount;
      _TokPos? originalOf(ad.Position p) {
        if (p.x < 0 || p.x >= amountForward.length) return null;
        final row = amountForward[p.x];
        if (p.y < 0 || p.y >= row.originals.length) return null;
        return row.originals[p.y];
      }

      final amb = _MoneyAmbiguity(
        currencies: List<String>.from(curRes.currencyNames),
        options: [
          for (int k = 0; k < amtRes.candidateValues.length; k++)
            _AmountOption(
              value: amtRes.candidateValues[k],
              currency: k < amtRes.candidatePositions.length
                  ? _currencyOnLine(seg, sel, amtRes.candidatePositions[k].x)
                  : null,
              pos: k < amtRes.candidatePositions.length
                  ? originalOf(amtRes.candidatePositions[k])
                  : null,
            ),
        ],
        multiCurrency: multiCurrency,
        mismatch: amtRes.wordsDigitsMismatch,
        strongValues: List<double>.from(amtRes.strongValues),
        autoPicked: !confirm,
      );
      _moneyAmbiguity[segIndex] = amb;
      _amountConflict.remove(segIndex);
      if (confirm) {
        sel.amount = null;
        _amountOverride.remove(segIndex);
        _amountTextCandidate.remove(segIndex);
        _amountCandidatesCache.remove(segIndex);
        if (_hasNameFor(segIndex, sel)) sel.stage = SelectionStage.amount;
      } else if (multiCurrency && amb.pairHasTwoCurrencies) {
        // بدون تأكيد + مبلغان بعملتين: يُعتمدان معًا (المبلغ والمبلغ الثاني)
        final pair = amb.firstPair!;
        _amountOverride[segIndex] = pair.$1.value;
        sel.amount = pair.$1.pos;
        _applyLineCurrency(sel, pair.$1.currency!);
        _secondAmount[segIndex] = pair.$2.value;
        _secondCurrency[segIndex] = pair.$2.currency!.name;
        amb.autoPicked = false;
        amb.autoBoth = true;
      } else {
        // بدون تأكيد: المبلغ الأرجح يبقى، وعملته هي المكتوبة في سطره
        final picked = _buildSelectedAmount(seg, sel, segIndex);
        final c = picked == null ? null : amb.optionFor(picked)?.currency;
        if (c != null && sel.currencyFromMenu == null) {
          _applyLineCurrency(sel, c);
        }
        if (picked == null) amb.autoPicked = false;
      }
    }

    return sel;
  }

  /// يحدد الكلمات والجمل الممنوعة داخل المقطع (للتمييز والتنبيه)
  void _computeForbiddenFor(ParsedSegment seg, _SegmentSelection sel) {
    sel.forbiddenTokens.clear();
    sel.forbiddenPhraseTokens.clear();
    sel.forbiddenPhrases.clear();
    if (_forbiddenPhraseSet.isEmpty && _forbiddenWordSet.isEmpty) return;

    final allKeys = <String>[];
    for (int li = 0; li < seg.lines.length; li++) {
      final keys = _nameConfig.keysOf(_tokensFromLine(seg.lines[li]));
      allKeys.addAll(keys);
      for (final hit in _forbiddenWordSet.findAll(keys, lineIndex: li)) {
        for (int ti = hit.start; ti < hit.end; ti++) {
          sel.forbiddenTokens.add(_TokPos(li, ti));
        }
      }
      for (final hit in _forbiddenPhraseSet.findAll(keys, lineIndex: li)) {
        for (int ti = hit.start; ti < hit.end; ti++) {
          sel.forbiddenTokens.add(_TokPos(li, ti));
          sel.forbiddenPhraseTokens.add(_TokPos(li, ti));
        }
        if (!sel.forbiddenPhrases.contains(hit.phrase)) {
          sel.forbiddenPhrases.add(hit.phrase);
        }
      }
    }

    // جمل ممتدة على أكثر من سطر
    if (_forbiddenPhrases.isNotEmpty) {
      final joined = ' ${allKeys.join(' ')} ';
      for (final phrase in _forbiddenPhrases) {
        if (sel.forbiddenPhrases.contains(phrase.trim())) continue;
        final key = tt.normalizeText(phrase);
        if (key.isNotEmpty && joined.contains(' $key ')) {
          sel.forbiddenPhrases.add(phrase.trim());
        }
      }
    }
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
      case SelectionStage.newName:
        return "حدد الاسم الجديد";
    }
  }

  // ====== مسح ======
  void _clearSelection(int segIndex) {
    setState(() {
      final sel = _selections[segIndex];
      sel.nameTokens.clear();
      sel.newNameTokens.clear();
      _editNewNameOverride.remove(segIndex);
      _secondAmount.remove(segIndex);
      _secondCurrency.remove(segIndex);
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
          _editSearchQueries.remove(segIndex);
          _invalidateCancelCandidates(segIndex);
          break;
        case 'newName':
          sel.newNameTokens.clear();
          _editNewNameOverride.remove(segIndex);
          _syncEditNameField(segIndex);
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
    final isCur = sel.isCurrencyAt(pos);
    final isNew = sel.newNameTokens.contains(pos);

    if (current == SelectionStage.name && (isAmt || isCur || isNew)) {
      return isAmt ? 'مبلغ' : (isCur ? 'عملة' : 'اسم جديد');
    }
    if (current == SelectionStage.amount && (isName || isCur || isNew)) {
      return isName ? 'اسم' : (isCur ? 'عملة' : 'اسم جديد');
    }
    if (current == SelectionStage.currency && (isName || isAmt || isNew)) {
      return isName ? 'اسم' : (isAmt ? 'مبلغ' : 'اسم جديد');
    }
    if (current == SelectionStage.newName && (isName || isAmt || isCur)) {
      return isName ? 'اسم البحث' : (isAmt ? 'مبلغ' : 'عملة');
    }
    return null;
  }

  // ====== إزالة تحديد فقاعة معيّنة ======
  void _unselectToken(int segIndex, _TokPos pos) {
    final sel = _selections[segIndex];
    final isAmt = sel.amount == pos;
    final isCur = sel.isCurrencyAt(pos);
    final isName = sel.nameTokens.contains(pos);

    if (isAmt && isCur) {
      _showClearAmountOrCurrencyDialog(segIndex);
      return;
    }

    if (sel.newNameTokens.contains(pos)) {
      setState(() {
        sel.newNameTokens.remove(pos);
        _editNewNameOverride.remove(segIndex);
        _syncEditNameField(segIndex);
      });
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

      // في الرسالة متعددة العملات الضغط نفسه هو الاختيار (بدون نافذة ثانية)
      if (!_moneyAmbiguity.containsKey(segIndex) &&
          _hasMultipleAmountCandidates(segIndex)) {
        await _openMultiAmountPickerDialog(segIndex);
      }
      return;
    }

    // كلمات ignored لا تُستخدم كاسم
    if ((sel.stage == SelectionStage.name ||
            sel.stage == SelectionStage.newName) &&
        _isIgnoredWord(tok)) {
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
        final keys = _nameConfig.keysOf(tokensThisLine);
        final forbiddenIdx = _nameConfig.forbiddenMask(keys);

        // الكلمة/الجملة الممنوعة لا تدخل في الاسم أبدًا
        if (forbiddenIdx.contains(tokenIndex) &&
            !sel.nameTokens.contains(pos)) {
          _snack(
            sel.forbiddenPhraseTokens.contains(pos)
                ? '«$tok» جزء من جملة ممنوعة ولا يمكن أن يكون ضمن الاسم'
                : '«$tok» كلمة ممنوعة ولا يمكن أن تكون جزءًا من الاسم',
          );
          return;
        }

        // الضغط على كلمة في سطر آخر = تحديد اسم جديد (يمتد تلقائيًا)،
        // أما الضغط داخل نفس سطر الاسم فيضيف/يزيل الكلمة فقط.
        final sameLine = sel.nameTokens.any((p) => p.line == lineIndex);
        if (sel.nameTokens.isEmpty || !sameLine) {
          final res = _nameSpanFromTap(
            segIndex,
            lineIndex,
            tokenIndex,
            tokensThisLine,
            keys,
            forbiddenIdx,
          );
          if (res.span.isEmpty) {
            _snack(res.reason ?? 'تعذر تحديد الاسم من هذه الكلمة');
            return;
          }
          setState(() {
            sel.nameTokens
              ..clear()
              ..addAll(res.span.map((ti) => _TokPos(lineIndex, ti)));
            _nameOverride.remove(segIndex);
            // التعديل: الاسم المضغوط هو اسم البحث (بدل البحث اليدوي)
            _editSearchQueries.remove(segIndex);
            _invalidateCancelCandidates(segIndex);
            _refreshStageForSegment(segIndex);
          });
        } else {
          setState(() {
            if (sel.nameTokens.contains(pos)) {
              sel.nameTokens.remove(pos);
            } else if (!_isIgnoredWord(tok)) {
              sel.nameTokens.add(pos);
            }
            _nameOverride.remove(segIndex);
            _editSearchQueries.remove(segIndex);
            _invalidateCancelCandidates(segIndex);
            _refreshStageForSegment(segIndex);
          });
        }
        if (_needsTarget(segIndex)) {
          _requestCancelCandidates(segIndex);
        }
        return;

      case SelectionStage.newName:
        // التعديل: كلمات الاسم الجديد (مثل الاسم: يمتد تلقائيًا)
        final keys = _nameConfig.keysOf(tokensThisLine);
        final forbiddenIdx = _nameConfig.forbiddenMask(keys);
        if (forbiddenIdx.contains(tokenIndex) &&
            !sel.newNameTokens.contains(pos)) {
          _snack('«$tok» كلمة ممنوعة ولا يمكن أن تكون جزءًا من الاسم');
          return;
        }
        final sameLine = sel.newNameTokens.any((p) => p.line == lineIndex);
        if (sel.newNameTokens.isEmpty || !sameLine) {
          final res = _nameSpanFromTap(
            segIndex,
            lineIndex,
            tokenIndex,
            tokensThisLine,
            keys,
            forbiddenIdx,
            stage: SelectionStage.newName,
          );
          if (res.span.isEmpty) {
            _snack(res.reason ?? 'تعذر تحديد الاسم من هذه الكلمة');
            return;
          }
          setState(() {
            sel.newNameTokens
              ..clear()
              ..addAll(res.span.map((ti) => _TokPos(lineIndex, ti)));
            _editNewNameOverride.remove(segIndex);
            _syncEditNameField(segIndex);
          });
        } else {
          setState(() {
            if (!sel.newNameTokens.remove(pos) && !_isIgnoredWord(tok)) {
              sel.newNameTokens.add(pos);
            }
            _editNewNameOverride.remove(segIndex);
            _syncEditNameField(segIndex);
          });
        }
        return;

      case SelectionStage.amount:
        await _detectAmountFromTappedLine(segIndex, lineIndex, tokensThisLine);

        if (!_moneyAmbiguity.containsKey(segIndex) &&
            _hasMultipleAmountCandidates(segIndex)) {
          await _openMultiAmountPickerDialog(segIndex);
        }
        return;

      case SelectionStage.currency:
        // العملة قد تكون من أكثر من كلمة («ليرة سورية»): تؤخذ العبارة كاملة
        final phrase = cd.CurrencyDetector.phraseAt(
          tokens: tokensThisLine,
          index: tokenIndex,
          currencyMap: _currencyMap,
        );
        final match = (phrase != null && phrase.inSettings) ? phrase : null;
        if (match == null &&
            !_isKnownCurrencyToken(_getSettingsOrDefault(), tok)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('العملة غير مُعرّفة في الإعدادات')),
          );
          return;
        }

        setState(() {
          if (match != null) {
            _applyLineCurrency(
              sel,
              _LineCurrency(
                start: _TokPos(lineIndex, match.start),
                extra: {
                  for (int k = match.start + 1; k <= match.end; k++)
                    _TokPos(lineIndex, k),
                },
                name: match.displayName,
              ),
            );
          } else {
            sel.currencyToken = pos;
            sel.currencyDetectedName = null;
            sel.currencyFromMenu = null;
          }
          _refreshStageForSegment(segIndex);
        });
        return;

      case SelectionStage.done:
        return;
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// عند الضغط على كلمة لتحديد الاسم: يمتد الاسم حتى نهاية السطر أو حتى أول
  /// كلمة ممنوعة / رقم / عملة / كلمة مبلغ / كلمة اسم / ... (كلمات الإيقاف).
  /// الضغط على كلمة اسم (مثل: المستفيد) يبدأ الاسم من الكلمة التي بعدها.
  ({List<int> span, String? reason}) _nameSpanFromTap(
    int segIndex,
    int lineIndex,
    int tokenIndex,
    List<String> tokens,
    List<String> keys,
    Set<int> forbiddenIdx, {
    SelectionStage stage = SelectionStage.name,
  }) {
    final sel = _selections[segIndex];
    bool extraStop(int i) {
      final p = _TokPos(lineIndex, i);
      return _occupiedRoleName(sel, p, stage) != null ||
          _isLockedToken(segIndex, lineIndex, i) ||
          sel.phoneLikeTokens.contains(p) ||
          tt.isPhoneLike(tokens[i]);
    }

    var start = tokenIndex;
    final kwLen = _nameConfig.nameKeywords.matchAt(keys, start);
    if (kwLen > 0) start += kwLen;
    while (start < keys.length && _nameConfig.isIgnoredKey(keys[start])) {
      start++;
    }
    if (start >= keys.length) {
      return (
        span: const <int>[],
        reason: 'لا توجد كلمات صالحة للاسم بعد هذه الكلمة في السطر',
      );
    }
    if (extraStop(start)) {
      return (
        span: const <int>[],
        reason: 'هذه الكلمة محددة لدور آخر (مبلغ/عملة/هاتف)',
      );
    }
    final startReason = _nameConfig.stopReasonAt(
      keys,
      start,
      forbiddenIdx: forbiddenIdx,
    );
    if (startReason != null) {
      return (span: const <int>[], reason: 'لا يمكن بدء الاسم من $startReason');
    }
    if (!_prefs.autoExtendName) return (span: <int>[start], reason: null);

    final span = _nameConfig.collectSpan(
      keys,
      start,
      forbiddenIdx: forbiddenIdx,
      extraStop: extraStop,
      maxTokens: 100,
    );
    return (span: span, reason: null);
  }

  /// اعتماد سطر مقترح كاسم
  void _applyNameCandidate(int segIndex, nd.NameLineCandidate c) {
    final sel = _selections[segIndex];
    setState(() {
      sel.nameTokens
        ..clear()
        ..addAll(
          c.tokenIndexes
              .map((ti) => _TokPos(c.lineIndex, ti))
              .where(
                (p) =>
                    _occupiedRoleName(sel, p, SelectionStage.name) == null &&
                    !sel.forbiddenTokens.contains(p),
              ),
        );
      _nameOverride.remove(segIndex);
      _invalidateCancelCandidates(segIndex);
      _refreshStageForSegment(segIndex);
    });
    if (_needsTarget(segIndex)) {
      _requestCancelCandidates(segIndex);
    }
  }

  /// الكلمات/الجمل الممنوعة الموجودة داخل نص يكتبه المستخدم
  List<String> _forbiddenInText(String text) {
    final keys = _nameConfig.keysOf(tt.tokensFromLine(text));
    if (keys.isEmpty) return const [];
    final out = <String>[];
    for (final hit in _forbiddenPhraseSet.findAll(keys)) {
      if (!out.contains(hit.phrase)) out.add(hit.phrase);
    }
    for (final hit in _forbiddenWordSet.findAll(keys)) {
      if (!out.contains(hit.phrase)) out.add(hit.phrase);
    }
    return out;
  }

  // ====== قائمة الضغط المطوّل على الكلمة ======
  Future<void> _showWordActions(
    int segIndex,
    int lineIndex,
    int tokenIndex,
    String token,
    List<String> tokensThisLine,
  ) async {
    if (_busy) {
      _snack('انتظر حتى تنتهي العملية الجارية');
      return;
    }
    final settings = SettingsWords.load();
    final word = token.trim();
    if (word.isEmpty) return;
    final phraseSuggestion = tokensThisLine.skip(tokenIndex).take(6).join(' ');
    final currencyOf = SettingsWords.currencyOfAlias(settings, word);
    final sel = _selections[segIndex];
    final selectedName = _buildSelectedName(
      _segments[segIndex],
      sel,
      segIndex,
    ).trim();
    double? wordValue;
    for (final e in settings.amountWordValues.entries) {
      if (tt.normalizeText(e.key) == tt.normalizeText(word)) {
        wordValue = e.value;
        break;
      }
    }

    bool inList(WordListKind k) => SettingsWords.contains(settings, k, word);

    final roles = <String>[
      if (inList(WordListKind.forbidden)) 'ممنوعة',
      if (sel.forbiddenPhraseTokens.contains(_TokPos(lineIndex, tokenIndex)))
        'ضمن جملة ممنوعة',
      if (currencyOf != null) 'عملة: $currencyOf',
      if (inList(WordListKind.nameKeyword)) 'كلمة اسم',
      if (inList(WordListKind.amountKeyword)) 'كلمة مبلغ',
      if (inList(WordListKind.ignored)) 'مهملة',
      if (inList(WordListKind.lineIgnored)) 'تجاهل سطر',
      if (inList(WordListKind.cancelKeyword)) 'كلمة إلغاء',
      if (inList(WordListKind.editKeyword)) 'كلمة تعديل',
      if (wordValue != null) 'قيمة: ${_fmtAmount(wordValue)}',
    ];

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;

        Widget tile(
          String key,
          IconData icon,
          String title,
          Color color, {
          String? subtitle,
          bool remove = false,
        }) {
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            leading: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .13),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                remove ? Icons.remove_circle_outline_rounded : icon,
                color: color,
                size: 20,
              ),
            ),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: subtitle == null
                ? null
                : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(ctx, key),
          );
        }

        String addOrRemove(WordListKind k) =>
            inList(k) ? 'إزالة من ${k.label}' : 'إضافة إلى ${k.label}';

        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * .85,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            word,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: roles.isEmpty
                              ? Text(
                                  'كلمة عادية — اختر ما تريد فعله بها',
                                  style: TextStyle(
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w700,
                                  ),
                                )
                              : Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: roles
                                      .map(
                                        (r) => Chip(
                                          label: Text(r),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    tile(
                      'forbidden',
                      Icons.block_rounded,
                      addOrRemove(WordListKind.forbidden),
                      _forbiddenColor,
                      subtitle: 'لا تدخل في الاسم ويتوقف عندها تحديد الاسم',
                      remove: inList(WordListKind.forbidden),
                    ),
                    tile(
                      'currency',
                      Icons.currency_exchange_rounded,
                      currencyOf != null
                          ? 'إزالة من اختصارات العملة ($currencyOf)'
                          : 'إضافة كاختصار عملة',
                      _currencyColor,
                      subtitle: currencyOf != null
                          ? null
                          : 'اختر العملة التي تدل عليها هذه الكلمة',
                      remove: currencyOf != null,
                    ),
                    tile(
                      'nameKeyword',
                      Icons.person_search_rounded,
                      addOrRemove(WordListKind.nameKeyword),
                      _nameColor,
                      subtitle: 'الكلمة التي يأتي بعدها اسم المستفيد',
                      remove: inList(WordListKind.nameKeyword),
                    ),
                    tile(
                      'phrase',
                      Icons.gpp_bad_rounded,
                      'إضافة جملة ممنوعة تبدأ من هذه الكلمة',
                      _forbiddenColor,
                      subtitle: '«$phraseSuggestion»',
                    ),
                    tile(
                      'amountKeyword',
                      Icons.payments_rounded,
                      addOrRemove(WordListKind.amountKeyword),
                      _amountColor,
                      remove: inList(WordListKind.amountKeyword),
                    ),
                    tile(
                      'ignored',
                      Icons.visibility_off_rounded,
                      addOrRemove(WordListKind.ignored),
                      Colors.orange,
                      subtitle: 'تُتجاهل أثناء التحليل ولا تُختار كاسم',
                      remove: inList(WordListKind.ignored),
                    ),
                    tile(
                      'lineIgnored',
                      Icons.playlist_remove_rounded,
                      addOrRemove(WordListKind.lineIgnored),
                      Colors.red,
                      subtitle: 'أي سطر يحتوي هذه الكلمة يُتجاهل بالكامل',
                      remove: inList(WordListKind.lineIgnored),
                    ),
                    tile(
                      'cancelKeyword',
                      Icons.cancel_schedule_send_rounded,
                      addOrRemove(WordListKind.cancelKeyword),
                      Colors.pink,
                      subtitle: 'الرسالة التي تحتويها تُعامل كعملية إلغاء',
                      remove: inList(WordListKind.cancelKeyword),
                    ),
                    tile(
                      'editKeyword',
                      Icons.edit_note_rounded,
                      addOrRemove(WordListKind.editKeyword),
                      Colors.orange,
                      subtitle:
                          'الرسالة التي تحتويها تُعامل كتعديل لحركة موجودة',
                      remove: inList(WordListKind.editKeyword),
                    ),
                    tile(
                      'wordValue',
                      Icons.calculate_rounded,
                      'تعيين قيمة رقمية لهذه الكلمة',
                      Colors.indigo,
                      subtitle: wordValue == null
                          ? 'مثال: ستمئة = 600'
                          : 'القيمة الحالية: ${_fmtAmount(wordValue)}',
                    ),
                    if (selectedName.isNotEmpty)
                      tile(
                        'readyName',
                        Icons.person_pin_circle_rounded,
                        'حفظ الاسم المحدد كاسم جاهز',
                        Colors.blueGrey,
                        subtitle: selectedName,
                      ),
                    tile('copy', Icons.copy_rounded, 'نسخ الكلمة', cs.primary),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (action == null || !mounted) return;

    bool changed = false;
    String message = '';

    Future<void> toggle(WordListKind kind) async {
      if (inList(kind)) {
        changed = await SettingsWords.remove(kind, word);
        message = 'تمت إزالة «$word» من ${kind.label}';
      } else {
        changed = await SettingsWords.add(kind, word);
        message = changed
            ? 'تمت إضافة «$word» إلى ${kind.label}'
            : '«$word» موجودة مسبقًا في ${kind.label}';
      }
    }

    switch (action) {
      case 'forbidden':
        await toggle(WordListKind.forbidden);
        break;
      case 'nameKeyword':
        await toggle(WordListKind.nameKeyword);
        break;
      case 'amountKeyword':
        await toggle(WordListKind.amountKeyword);
        break;
      case 'ignored':
        await toggle(WordListKind.ignored);
        break;
      case 'lineIgnored':
        await toggle(WordListKind.lineIgnored);
        break;
      case 'cancelKeyword':
        await toggle(WordListKind.cancelKeyword);
        break;
      case 'editKeyword':
        await toggle(WordListKind.editKeyword);
        break;
      case 'currency':
        if (currencyOf != null) {
          changed = await SettingsWords.removeCurrencyAlias(word);
          message = 'تمت إزالة «$word» من اختصارات $currencyOf';
        } else {
          final target = await _pickCurrencyForAlias(word);
          if (target == null) return;
          changed = await SettingsWords.addCurrencyAlias(word, target);
          message = changed
              ? 'تمت إضافة «$word» كاختصار لعملة $target'
              : '«$word» معرّفة مسبقًا كعملة';
        }
        break;
      case 'phrase':
        final phrase = await _editTextDialog(
          title: 'إضافة جملة ممنوعة',
          initial: phraseSuggestion,
          hint: 'اكتب الجملة الممنوعة كما تظهر في الرسائل',
        );
        if (phrase == null) return;
        changed = await SettingsWords.add(WordListKind.forbiddenPhrase, phrase);
        message = changed
            ? 'تمت إضافة الجملة الممنوعة «$phrase»'
            : 'الجملة موجودة مسبقًا';
        break;
      case 'wordValue':
        final value = await _numberDialog(
          title: 'قيمة الكلمة «$word»',
          initial: wordValue,
        );
        if (value == null) return;
        changed = await SettingsWords.setAmountWordValue(word, value);
        message = 'تم تعيين «$word» = ${_fmtAmount(value)}';
        break;
      case 'readyName':
        changed = await SettingsWords.add(WordListKind.readyName, selectedName);
        message = changed
            ? 'تم حفظ «$selectedName» في الأسماء الجاهزة'
            : 'الاسم موجود مسبقًا في الأسماء الجاهزة';
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: word));
        _snack('تم نسخ «$word»');
        return;
    }

    if (!mounted) return;
    if (!changed) {
      _snack(message.isEmpty ? 'لم يتغير شيء' : message);
      return;
    }

    setState(_reloadSettings);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(message),
          action: SnackBarAction(
            label: 'إعادة التحليل',
            onPressed: () {
              if (mounted) _reanalyzeUnsaved();
            },
          ),
        ),
      );
  }

  Future<String?> _pickCurrencyForAlias(String alias) async {
    final names = SettingsWords.currencyNames(SettingsWords.load());
    final newCtrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('«$alias» اختصار لأي عملة؟'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (names.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: names
                          .map(
                            (n) => ActionChip(
                              avatar: const Icon(
                                Icons.currency_exchange_rounded,
                                size: 16,
                              ),
                              label: Text(n),
                              onPressed: () => Navigator.pop(ctx, n),
                            ),
                          )
                          .toList(),
                    ),
                  const SizedBox(height: 14),
                  const Text(
                    'أو أنشئ عملة جديدة:',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: newCtrl,
                    decoration: const InputDecoration(
                      hintText: 'اسم العملة المعروض مثل: دينار',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final v = newCtrl.text.trim();
                if (v.isNotEmpty) Navigator.pop(ctx, v);
              },
              child: const Text('إنشاء واعتماد'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _editTextDialog({
    required String title,
    required String initial,
    String? hint,
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final v = ctrl.text.trim();
                Navigator.pop(ctx, v.isEmpty ? null : v);
              },
              child: const Text('اعتماد'),
            ),
          ],
        ),
      ),
    );
  }

  /// تحويل رقم مكتوب بالأرقام العربية/الفواصل إلى صيغة قابلة للتحليل
  String _asciiNumber(String input) {
    final b = StringBuffer();
    for (final ch in input.trim().characters) {
      final code = ch.codeUnitAt(0);
      if (code >= 0x0660 && code <= 0x0669) {
        b.writeCharCode(0x30 + code - 0x0660);
      } else if (code >= 0x06F0 && code <= 0x06F9) {
        b.writeCharCode(0x30 + code - 0x06F0);
      } else if (ch == '٫' || ch == ',') {
        b.write('.');
      } else if (ch != '٬' && ch != ' ') {
        b.write(ch);
      }
    }
    return b.toString();
  }

  Future<double?> _numberDialog({required String title, double? initial}) {
    final ctrl = TextEditingController(
      text: initial == null ? '' : _rawAmount(initial),
    );
    return showDialog<double>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              hintText: 'مثال: 600',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(_asciiNumber(ctrl.text));
                Navigator.pop(ctx, v != null && v > 0 ? v : null);
              },
              child: const Text('اعتماد'),
            ),
          ],
        ),
      ),
    );
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
          content: StatefulBuilder(
            builder: (ctx, setD) {
              final found = _forbiddenInText(ctrl.text);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: ctrl,
                    maxLines: 3,
                    onChanged: (_) => setD(() {}),
                    decoration: const InputDecoration(
                      hintText: 'اكتب الاسم هنا...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (found.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _forbiddenColor.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _forbiddenColor.withValues(alpha: .35),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.block_rounded,
                            color: _forbiddenColor,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'الاسم يحتوي على ممنوع: ${found.map((e) => '«$e»').join('، ')}',
                              style: const TextStyle(
                                color: _forbiddenColor,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
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
    if (_needsTarget(segIndex)) {
      _requestCancelCandidates(segIndex);
    }
  }

  // ====== إدخال يدوي: المبلغ ======
  Future<void> _openAmountManualDialog(
    int segIndex,
    double? currentAmount,
  ) async {
    final ctrl = TextEditingController(
      text: currentAmount != null ? _rawAmount(currentAmount) : '',
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
  /// لون نص مقروء فوق خلفية فاتحة/داكنة
  Color _readable(BuildContext ctx, Color c) {
    final dark = Theme.of(ctx).brightness == Brightness.dark;
    return Color.lerp(c, dark ? Colors.white : Colors.black, dark ? .28 : .22)!;
  }

  bool _isForbiddenToken(int segIndex, int li, int ti) =>
      _selections[segIndex].forbiddenTokens.contains(_TokPos(li, ti));

  Color _tokenColor(BuildContext ctx, int segIndex, int li, int ti) {
    final sel = _selections[segIndex];
    final cs = Theme.of(ctx).colorScheme;

    if (_isLockedToken(segIndex, li, ti)) return _readable(ctx, _chipRed);
    if (sel.nameTokens.contains(_TokPos(li, ti))) {
      return _readable(ctx, _nameColor);
    }
    if (sel.newNameTokens.contains(_TokPos(li, ti))) {
      return _readable(ctx, _newNameColor);
    }
    if (_isDualAmountCurrencyPos(segIndex, li, ti)) return cs.onSurface;
    if (_isAmountPos(segIndex, li, ti)) return _readable(ctx, _amountColor);
    if (_isCurrencyPos(segIndex, li, ti)) {
      return _readable(ctx, _currencyColor);
    }
    if (_isForbiddenToken(segIndex, li, ti)) {
      return _readable(ctx, _forbiddenColor);
    }
    if (_isPhoneToken(segIndex, li, ti)) return _readable(ctx, _chipYellow);

    return cs.onSurface.withValues(alpha: 0.78);
  }

  BoxDecoration _roleDecoration(Color color, double radius) => BoxDecoration(
    color: color.withValues(alpha: 0.14),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: color.withValues(alpha: .75), width: 1.2),
  );

  Decoration _tokenDecoration(BuildContext ctx, int segIndex, int li, int ti) {
    final pos = _TokPos(li, ti);
    final radius = _prefs.compact ? 10.0 : 14.0;

    if (_isLockedToken(segIndex, li, ti)) {
      return _roleDecoration(_chipRed, radius);
    }

    if (_selections[segIndex].nameTokens.contains(pos)) {
      return _roleDecoration(_nameColor, radius);
    }

    if (_selections[segIndex].newNameTokens.contains(pos)) {
      return _roleDecoration(_newNameColor, radius);
    }

    if (_isDualAmountCurrencyPos(segIndex, li, ti)) {
      final mixed = _mixedAmountCurrencyBorder();
      return BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _amountColor.withValues(alpha: .22),
            _amountColor.withValues(alpha: .22),
            _currencyColor.withValues(alpha: .22),
            _currencyColor.withValues(alpha: .22),
          ],
          stops: const [0.0, 0.5, 0.5, 1.0],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: mixed, width: 1.4),
        boxShadow: [
          BoxShadow(
            color: mixed.withValues(alpha: .18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      );
    }

    if (_isAmountPos(segIndex, li, ti)) {
      return _roleDecoration(_amountColor, radius);
    }

    if (_isCurrencyPos(segIndex, li, ti)) {
      return _roleDecoration(_currencyColor, radius);
    }

    if (_isForbiddenToken(segIndex, li, ti)) {
      return BoxDecoration(
        color: _forbiddenColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: _forbiddenColor.withValues(alpha: .55),
          width: 1.2,
        ),
      );
    }

    if (_isPhoneToken(segIndex, li, ti)) {
      return _roleDecoration(_chipYellow, radius);
    }

    final cs = Theme.of(ctx).colorScheme;
    return BoxDecoration(
      color: cs.onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: cs.onSurface.withValues(alpha: 0.14), width: 1),
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
    if (_modeOf(segIndex) == BubbleActionMode.edit) {
      return _editReady(segIndex);
    }
    return _segmentReady(_selections[segIndex], segIndex);
  }

  bool _hasCancelSegments() {
    for (int i = 0; i < _selections.length; i++) {
      if (_modeOf(i) == BubbleActionMode.cancel &&
          !_cancelledSummaries.containsKey(i)) {
        return true;
      }
    }
    return false;
  }

  bool _hasPendingAddSegments() {
    for (int i = 0; i < _selections.length; i++) {
      if (_modeOf(i) == BubbleActionMode.add &&
          !_savedSegments.contains(i) &&
          _segmentReady(_selections[i], i)) {
        return true;
      }
    }
    return false;
  }

  /// فقاعات تعديل لم تُنفّذ بعد
  bool _hasEditSegments() {
    for (int i = 0; i < _selections.length; i++) {
      if (_modeOf(i) == BubbleActionMode.edit &&
          !_editedSummaries.containsKey(i)) {
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
      text: result == null ? '' : _rawAmount(result),
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
                            "استخدام النص المحسوب: ${_fmtAmount(textVal!)}",
                          ),
                        ),
                      if (numericVal != null)
                        RadioListTile<String>(
                          value: 'num',
                          groupValue: mode,
                          onChanged: (v) => setS(() => mode = v!),
                          title: Text(
                            "استخدام الرقم: ${_fmtAmount(numericVal!)}",
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
    return _selections[segIndex].isCurrencyAt(_TokPos(li, ti));
  }

  bool _isDualAmountCurrencyPos(int segIndex, int li, int ti) {
    return _isAmountPos(segIndex, li, ti) && _isCurrencyPos(segIndex, li, ti);
  }

  Color _mixedAmountCurrencyBorder() {
    return Color.lerp(_amountColor, _currencyColor, 0.5) ?? _currencyColor;
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
        sel.newNameTokens.contains(pos) ||
        sel.amount == pos ||
        sel.isCurrencyAt(pos);
    final isLocked = _isLockedToken(segIndex, lineIndex, tokenIndex);
    final isForbidden = sel.forbiddenTokens.contains(pos);

    final color = _tokenColor(context, segIndex, lineIndex, tokenIndex);
    final decoration = _tokenDecoration(
      context,
      segIndex,
      lineIndex,
      tokenIndex,
    );

    final canTap = !isLocked || sel.stage == SelectionStage.amount;
    final compact = _prefs.compact;
    final fontSize = _prefs.tokenFontSize;
    final iconSize = (fontSize + 1).clamp(12.0, 20.0);

    void openActions() => _showWordActions(
      segIndex,
      lineIndex,
      tokenIndex,
      token,
      tokensThisLine,
    );

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
        onLongPress: openActions,
        onSecondaryTap: openActions,
        borderRadius: BorderRadius.circular(compact ? 10 : 16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 7, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: decoration,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isForbidden && !selected) ...[
                Icon(Icons.block_rounded, size: iconSize - 2, color: color),
                const SizedBox(width: 4),
              ],
              Text(
                token,
                style: TextStyle(
                  color: color,
                  fontSize: fontSize,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  decoration: isLocked
                      ? TextDecoration.underline
                      : (isForbidden && !selected
                            ? TextDecoration.lineThrough
                            : TextDecoration.none),
                  decorationColor: color,
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _unselectToken(segIndex, pos),
                  child: Icon(Icons.close, size: iconSize, color: color),
                ),
              ],
              if (!selected &&
                  _isPhoneToken(segIndex, lineIndex, tokenIndex)) ...[
                const SizedBox(width: 6),
                Icon(Icons.phone_android, size: iconSize - 2, color: color),
              ],
              if (!selected && isLocked) ...[
                const SizedBox(width: 6),
                Icon(Icons.touch_app, size: iconSize - 2, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }

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
      currencyAnchor: _currencyAnchorIn(forward, sel),
    );

    final values = <double>[];

    _addUniqueAmount(values, res.numericValue);
    _addUniqueAmount(values, res.textValue);
    _addUniqueAmount(values, _amountOverride[segIndex]);
    _addUniqueAmount(values, _amountTextCandidate[segIndex]);
    for (final o in _moneyAmbiguity[segIndex]?.options ?? const []) {
      _addUniqueAmount(values, o.value);
    }

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

  /// المبلغ للعرض: نقطة بين كل 3 خانات والكسور بفاصلة إن وُجدت (250.000)
  String _fmtAmount(double value) => AmountFormat.display(value);

  /// المبلغ بالأرقام الخام لحقول الإدخال والنسخ (250000 أو 1234.50)
  String _rawAmount(double value) {
    final isInt = value == value.roundToDouble();
    return isInt ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
  }

  Future<void> _copyAmountToClipboard(double amount) async {
    final text = _rawAmount(amount);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('تم نسخ المبلغ: $text')));
  }

  void _applyChosenAmount(int segIndex, double amount) {
    String? pairedCurrency;
    setState(() {
      final sel = _selections[segIndex];
      _amountOverride[segIndex] = amount;
      _amountConflict.remove(segIndex);
      _amountCandidatesCache.remove(segIndex);
      sel.amount = null;
      _moneyAmbiguity[segIndex]?.autoPicked = false;
      _moneyAmbiguity[segIndex]?.autoBoth = false;
      // اختيار مبلغ واحد: لا مبلغ ثاني
      _secondAmount.remove(segIndex);
      _secondCurrency.remove(segIndex);
      // رسالة بأكثر من عملة: المبلغ يأخذ العملة المكتوبة في سطره
      final c = _moneyAmbiguity[segIndex]?.optionFor(amount)?.currency;
      if (c != null && sel.currencyFromMenu == null) {
        _applyLineCurrency(sel, c);
        pairedCurrency = c.name;
      }
      _refreshStageForSegment(segIndex);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          pairedCurrency == null
              ? 'تم اعتماد المبلغ: ${_fmtAmount(amount)}'
              : 'تم اعتماد المبلغ: ${_fmtAmount(amount)} $pairedCurrency',
        ),
      ),
    );
  }

  /// «اعتماد المبلغين معًا»: الأول مبلغ الحركة والثاني «المبلغ الثاني»
  void _applyBothAmounts(int segIndex) {
    final amb = _moneyAmbiguity[segIndex];
    final pair = amb?.firstPair;
    if (amb == null || pair == null) return;
    final seg = _segments[segIndex];
    String? second;
    setState(() {
      final sel = _selections[segIndex];
      amb.autoPicked = false;
      amb.autoBoth = false;
      _amountOverride[segIndex] = pair.$1.value;
      sel.amount = pair.$1.pos;
      _amountConflict.remove(segIndex);
      _amountCandidatesCache.remove(segIndex);
      final c1 = pair.$1.currency;
      if (c1 != null && sel.currencyFromMenu == null) {
        _applyLineCurrency(sel, c1);
      }
      _secondAmount[segIndex] = pair.$2.value;
      final c2 = pair.$2.currency?.name ?? _buildSelectedCurrency(seg, sel);
      if (c2 != null && c2.trim().isNotEmpty) {
        _secondCurrency[segIndex] = c2;
      } else {
        _secondCurrency.remove(segIndex);
      }
      second = c2;
      _refreshStageForSegment(segIndex);
    });
    _snack(
      'تم اعتماد المبلغين: ${_fmtAmount(pair.$1.value)} '
      '${pair.$1.currency?.name ?? ''} + ${_fmtAmount(pair.$2.value)} ${second ?? ''}',
    );
  }

  /// كتابة/تعديل المبلغ الثاني
  Future<void> _openSecondAmountDialog(int segIndex) async {
    final v = await _numberDialog(
      title: 'المبلغ الثاني',
      initial: _secondAmount[segIndex],
    );
    if (!mounted || v == null || segIndex >= _selections.length) return;
    if (v <= 0) {
      setState(() {
        _secondAmount.remove(segIndex);
        _secondCurrency.remove(segIndex);
      });
      return;
    }
    setState(() => _secondAmount[segIndex] = v);
    if (_secondCurrency[segIndex] == null) await _pickSecondCurrency(segIndex);
  }

  /// عملة المبلغ الثاني (من عملات الإعدادات)
  Future<void> _pickSecondCurrency(int segIndex) async {
    final names = _currencyMap.values.toSet().toList()..sort();
    if (names.isEmpty) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SimpleDialog(
          title: const Text('عملة المبلغ الثاني'),
          children: [
            for (final n in names)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, n),
                child: Row(
                  children: [
                    Icon(
                      _secondCurrency[segIndex] == n
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(n)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null || segIndex >= _selections.length) return;
    setState(() => _secondCurrency[segIndex] = picked);
  }

  void _clearSecondAmount(int segIndex) {
    setState(() {
      _secondAmount.remove(segIndex);
      _secondCurrency.remove(segIndex);
      _moneyAmbiguity[segIndex]?.autoBoth = false;
    });
  }

  /// نص زر المبلغ في رسالة بأكثر من عملة: المبلغ مع عملة سطره إن عُرفت
  String _amountOptionLabel(_MoneyAmbiguity amb, double value) {
    final c = amb.optionFor(value)?.currency;
    return c == null ? _fmtAmount(value) : '${_fmtAmount(value)} ${c.name}';
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

    final newMoneyAmbiguity = <int, _MoneyAmbiguity>{};
    for (final e in _moneyAmbiguity.entries) {
      if (e.key == deletedIndex) continue;
      newMoneyAmbiguity[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _moneyAmbiguity
      ..clear()
      ..addAll(newMoneyAmbiguity);

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

    final newMovementOverrides = <int, CompanyMovementType>{};
    for (final e in _companyMovementOverrides.entries) {
      if (e.key == deletedIndex) continue;
      newMovementOverrides[e.key > deletedIndex ? e.key - 1 : e.key] = e.value;
    }
    _companyMovementOverrides
      ..clear()
      ..addAll(newMovementOverrides);

    _shiftKeys(_editSelectedTxIds, deletedIndex);
    _shiftKeys(_editFields, deletedIndex);
    _shiftKeys(_editSearchQueries, deletedIndex);
    _shiftKeys(_editedSummaries, deletedIndex);
    _shiftKeys(_editNewNameOverride, deletedIndex);
    _shiftKeys(_targetHits, deletedIndex);
    _shiftKeys(_secondAmount, deletedIndex);
    _shiftKeys(_secondCurrency, deletedIndex);
    final newPickerOpen = <int>{
      for (final v in _editPickerOpen)
        if (v != deletedIndex) v > deletedIndex ? v - 1 : v,
    };
    _editPickerOpen
      ..clear()
      ..addAll(newPickerOpen);
  }

  /// إزاحة مفاتيح خريطة بعد حذف فقاعة
  static void _shiftKeys<V>(Map<int, V> map, int deletedIndex) {
    final next = <int, V>{};
    map.forEach((k, v) {
      if (k != deletedIndex) next[k > deletedIndex ? k - 1 : k] = v;
    });
    map
      ..clear()
      ..addAll(next);
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

    for (int i = 0; i < _selections.length; i++) {
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

      final second = _secondAmount[i];
      final hasSecond = second != null && second > 0;

      drafts.add(
        _PendingTxDraft(
          segIndex: i,
          beneficiary: beneficiary,
          amount: amount,
          currency: currency,
          secondAmount: hasSecond ? second : null,
          secondCurrency: hasSecond ? (_secondCurrency[i] ?? currency) : null,
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

    for (int i = 0; i < _selections.length; i++) {
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

  /// تسمية حالة أي حركة (مكتب أو شركة) بغض النظر عن نوع الحساب الحالي
  String _anyTxLabel(TransactionModel tx) =>
      tx.companyMovementType?.label ?? _txStatusLabel(tx.status);

  /// فحص التكرار على دفعات مع شريط تقدم — داخل الحساب الحالي فقط:
  /// - مطابقة تامة (الاسم + المبلغ + العملة + نفس الدقيقة): كل الأوقات وكل
  ///   الحالات (حتى الملغية والمستلمة).
  /// - الاسم + المبلغ + العملة: خلال المدة المحددة في الإعدادات، بكل الحالات.
  /// - الاسم فقط: آخر يومين.
  /// - التكرار داخل النص نفسه.
  Future<List<_DuplicateWarningItem>> _scanDuplicates(
    List<_PendingTxDraft> drafts,
  ) async {
    final accountId = widget.account.id;
    final all = DatabaseService.transactionsBox.values
        .where((t) => t.accountId == accountId)
        .toList();
    final now = DateTime.now();
    final strongDays = _prefs.duplicateDays;
    const weakDays = 2;

    final items = [
      for (final d in drafts)
        _DuplicateWarningItem(
          draft: d,
          exactCritical: [],
          sameNameAmountCurrency: [],
          sameNameOnly: [],
          batchDuplicates: [],
        ),
    ];

    final byName = <String, List<int>>{};
    for (int i = 0; i < drafts.length; i++) {
      final key = _normalizeForSearch(drafts[i].beneficiary);
      if (key.isEmpty) continue;
      (byName[key] ??= []).add(i);
    }

    bool withinDays(DateTime a, DateTime b, int days) =>
        a.difference(b).inMinutes.abs() <= days * 24 * 60;

    await runTimeSliced(
      total: all.length,
      isCancelled: () => !mounted,
      onProgress: (done, total) => _setProgress(
        OperationProgress(
          label: 'جارٍ فحص التكرار...',
          done: done,
          total: total,
        ),
      ),
      work: (ti) {
        final t = all[ti];
        final idxs = byName[_txNormName(t)];
        if (idxs == null) return;

        for (final di in idxs) {
          final d = drafts[di];
          final sameAmount = _sameAmount(t.amount, d.amount);
          final sameCurrency = _eqCur(t.currency, d.currency);

          // مطابقة تامة: أي وقت، أي حالة
          if (sameAmount && sameCurrency && _sameExactMinute(t.date, d.date)) {
            items[di].exactCritical.add(t);
            continue;
          }

          // في حسابات الشركة نقارن نفس الاتجاه (مرسلة/مستقبلة) حتى لو كانت ملغية
          if (_isCompanyAccount &&
              (t.companyMovementType?.isSent ?? false) !=
                  (d.companyMovementType?.isSent ?? false)) {
            continue;
          }

          if (sameAmount && sameCurrency) {
            if (withinDays(t.date, d.date, strongDays) ||
                withinDays(t.date, now, strongDays)) {
              items[di].sameNameAmountCurrency.add(t);
            }
            continue;
          }

          if (withinDays(t.date, d.date, weakDays) ||
              withinDays(t.date, now, weakDays)) {
            items[di].sameNameOnly.add(t);
          }
        }
      },
    );

    // التكرار داخل النص نفسه
    for (final group in byName.values) {
      if (group.length < 2) continue;
      for (final a in group) {
        for (final b in group) {
          if (a == b) continue;
          final da = drafts[a];
          final db = drafts[b];
          if (_sameAmount(da.amount, db.amount) &&
              _eqCur(da.currency, db.currency) &&
              (da.companyMovementType?.isSent ?? false) ==
                  (db.companyMovementType?.isSent ?? false)) {
            items[a].batchDuplicates.add(db);
          }
        }
      }
    }

    return items.where((w) => w.hasAny).toList();
  }

  /// نافذة تأكيد إضافية عند الضغط على «متابعة رغم التحذير»
  Future<bool> _confirmContinueDespiteWarning(
    BuildContext ctx,
    List<_DuplicateWarningItem> warnings,
  ) async {
    final exact = warnings.fold<int>(
      0,
      (sum, w) =>
          sum +
          w.exactCritical.length +
          w.batchDuplicates
              .where((d) => _sameExactMinute(d.date, w.draft.date))
              .length,
    );
    final strong = warnings.fold<int>(
      0,
      (sum, w) => sum + w.sameNameAmountCurrency.length,
    );
    return await showDialog<bool>(
          context: ctx,
          builder: (c) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              icon: const Icon(
                Icons.warning_amber_rounded,
                color: Colors.red,
                size: 36,
              ),
              title: const Text('تأكيد الحفظ رغم التحذير'),
              content: Text(
                [
                  'أنت على وشك حفظ ${warnings.length} حركة عليها تحذير تكرار.',
                  if (exact > 0) '• مطابقات تامة: $exact',
                  if (strong > 0) '• نفس الاسم والمبلغ والعملة: $strong',
                  '',
                  'هل أنت متأكد أنك تريد المتابعة؟',
                ].join('\n'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('رجوع للمراجعة'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Navigator.pop(c, true),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('نعم، احفظ'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<bool> _confirmDuplicateWarnings(List<_PendingTxDraft> drafts) async {
    final warnings = await _scanDuplicates(drafts);
    _setProgress(null);
    if (!mounted) return false;
    if (warnings.isEmpty) return true;

    final accountsById = <int, Account>{
      for (final account in DatabaseService.accountsBox.values)
        account.id: account,
    };

    final hasCritical = warnings.any(
      (w) =>
          w.exactCritical.isNotEmpty ||
          w.batchDuplicates.any((d) => _sameExactMinute(d.date, w.draft.date)),
    );
    final hasStrong = warnings.any(
      (w) =>
          w.sameNameAmountCurrency.isNotEmpty || w.batchDuplicates.isNotEmpty,
    );
    final needsConfirm = hasCritical || hasStrong;
    final scopeLabel = _isCompanyAccount
        ? 'هذا الحساب فقط وبنفس اتجاه الحركة (يشمل الملغية)'
        : 'هذا الحساب فقط (يشمل المستلمة والملغية)';

    return await showDialog<bool>(
          context: context,
          barrierDismissible: !hasCritical,
          builder: (ctx) {
            Color movementColor(TransactionModel tx) {
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
                  return _txStatusColor(tx.status);
              }
            }

            IconData movementIcon(TransactionModel tx) {
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
                  switch (tx.status) {
                    case TransactionStatus.added:
                      return Icons.add_circle_outline_rounded;
                    case TransactionStatus.received:
                      return Icons.check_circle_outline_rounded;
                    case TransactionStatus.cancelled:
                      return Icons.cancel_outlined;
                  }
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
                  color: color.withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withValues(alpha: .24)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .14),
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
                            '${_fmtAmount(tx.amount)} ${tx.currency}',
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
                                label: _anyTxLabel(tx),
                                color: color,
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'تاريخ الحركة: ${_fmtDateTime(tx.date)}',
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

            Widget sectionShell({
              required String title,
              required Color color,
              required int count,
              String? note,
              required List<Widget> children,
            }) {
              return Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: color.withValues(alpha: .28)),
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
                          '$count',
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        note,
                        style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 9),
                    ...children,
                  ],
                ),
              );
            }

            String? statusNote(List<TransactionModel> items) {
              final cancelled = items
                  .where(
                    (t) =>
                        t.status == TransactionStatus.cancelled ||
                        (t.companyMovementType?.isCancelled ?? false),
                  )
                  .length;
              final received = items
                  .where((t) => t.status == TransactionStatus.received)
                  .length;
              if (cancelled == 0 && received == 0) return null;
              return [
                if (received > 0) 'منها $received مستلمة',
                if (cancelled > 0) '$cancelled ملغية',
              ].join(' و ');
            }

            Widget buildSection(
              String title,
              Color color,
              List<TransactionModel> items,
            ) {
              if (items.isEmpty) return const SizedBox.shrink();
              return sectionShell(
                title: title,
                color: color,
                count: items.length,
                note: statusNote(items),
                children: [
                  ...items.take(4).map(buildResultCard),
                  if (items.length > 4)
                    Text(
                      'و ${items.length - 4} نتائج أخرى',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              );
            }

            Widget buildBatchSection(_DuplicateWarningItem w) {
              if (w.batchDuplicates.isEmpty) return const SizedBox.shrink();
              const color = Colors.deepPurple;
              return sectionShell(
                title: 'مكرر داخل النص نفسه',
                color: color,
                count: w.batchDuplicates.length,
                children: w.batchDuplicates.take(4).map((d) {
                  final exact = _sameExactMinute(d.date, w.draft.date);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Icon(
                          exact
                              ? Icons.content_copy_rounded
                              : Icons.compare_arrows_rounded,
                          size: 18,
                          color: color,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${d.beneficiary} | ${_fmtAmount(d.amount)} ${d.currency} — ${_fmtDateTime(d.date)}${exact ? ' (نفس الدقيقة)' : ''}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
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
                              ? 'وجدت حركات مكررة بشكل مطابق تمامًا (حتى لو كانت ملغية أو مستلمة). راجعها جيدًا قبل المتابعة.'
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
                                  'المطابقة التامة: كل الأوقات • '
                                  'الاسم+المبلغ+العملة: آخر ${_prefs.duplicateDays} يومًا • '
                                  'الاسم فقط: آخر يومين — ضمن $scopeLabel',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Theme.of(
                                      ctx,
                                    ).colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        ...warnings.map((w) {
                          final movementText = _isCompanyAccount
                              ? ' — ${w.draft.companyMovementType?.label ?? 'حركة شركة'}'
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
                                color: Theme.of(ctx).colorScheme.outlineVariant
                                    .withValues(alpha: .38),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${w.draft.beneficiary} | ${_fmtAmount(w.draft.amount)} ${w.draft.currency}$movementText',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'التاريخ/الوقت: ${_fmtDateTime(w.draft.date)}',
                                ),
                                buildSection(
                                  'مطابقة تامة',
                                  Colors.red,
                                  w.exactCritical,
                                ),
                                buildBatchSection(w),
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
                    style: needsConfirm
                        ? ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          )
                        : null,
                    onPressed: () async {
                      if (!needsConfirm) {
                        Navigator.pop(ctx, true);
                        return;
                      }
                      final ok = await _confirmContinueDespiteWarning(
                        ctx,
                        warnings,
                      );
                      if (ok && ctx.mounted) Navigator.pop(ctx, true);
                    },
                    child: Text(needsConfirm ? 'متابعة رغم التحذير' : 'متابعة'),
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
  /// تأكيد قبل حفظ رسائل تحتوي على جمل ممنوعة
  Future<bool> _confirmForbiddenPhrases(List<_PendingTxDraft> drafts) async {
    if (!_prefs.confirmForbiddenPhrase) return true;
    final flagged = <({_PendingTxDraft draft, List<String> phrases})>[];
    for (final d in drafts) {
      final phrases = _selections[d.segIndex].forbiddenPhrases;
      if (phrases.isNotEmpty) flagged.add((draft: d, phrases: phrases));
    }
    if (flagged.isEmpty) return true;

    return await showDialog<bool>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              icon: const Icon(
                Icons.gpp_maybe_rounded,
                color: _forbiddenColor,
                size: 36,
              ),
              title: const Text('رسائل تحتوي على جمل ممنوعة'),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${flagged.length} رسالة من الرسائل الجاهزة للحفظ تحتوي على جملة ممنوعة:',
                      ),
                      const SizedBox(height: 10),
                      ...flagged.map(
                        (f) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _forbiddenColor.withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _forbiddenColor.withValues(alpha: .30),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${f.draft.beneficiary} — ${_fmtAmount(f.draft.amount)} ${f.draft.currency}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                f.phrases.map((e) => '«$e»').join('، '),
                                style: const TextStyle(
                                  color: _forbiddenColor,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('رجوع'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _forbiddenColor,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('حفظ رغم ذلك'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<void> _sendForMode(BubbleActionMode mode) async {
    if (_busy) return;
    if (mode == BubbleActionMode.edit) {
      await _sendEdits();
      return;
    }

    final drafts = mode == BubbleActionMode.add
        ? _collectReadyDrafts()
        : const <_PendingTxDraft>[];
    final cancelDrafts = mode == BubbleActionMode.cancel
        ? _collectReadyCancelDrafts()
        : const <_PendingCancelDraft>[];

    if (drafts.isEmpty && cancelDrafts.isEmpty) {
      _snack(
        mode == BubbleActionMode.add
            ? 'لا توجد إضافات مكتملة للتنفيذ'
            : 'لا توجد إلغاءات مختارة للتنفيذ',
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
      if (!await _confirmForbiddenPhrases(drafts)) return;
      if (!mounted) return;
      setState(() => _isSending = true);
      bool proceed = false;
      try {
        proceed = await _confirmDuplicateWarnings(drafts);
      } finally {
        _setProgress(null);
        if (mounted) setState(() => _isSending = false);
      }
      if (!proceed || !mounted) return;
    }

    setState(() => _isSending = true);

    int saved = 0;
    int cancelled = 0;
    final multiAmountSaved = <int>[];
    final addRecords = <OperationTxRecord>[];
    final cancelRecords = <OperationTxRecord>[];
    final addedSegments = <int>[];
    final cancelledSegments = <int>[];
    final total = drafts.length + cancelDrafts.length;
    var done = 0;

    void tick(String label) {
      done++;
      _setProgress(OperationProgress(label: label, done: done, total: total));
    }

    _setProgress(
      OperationProgress(
        label: mode == BubbleActionMode.add
            ? 'جارٍ حفظ الحركات...'
            : 'جارٍ تنفيذ الإلغاء...',
        done: 0,
        total: total,
      ),
    );

    try {
      final existingIds = DatabaseService.transactionsBox.values
          .map((t) => t.id)
          .toSet();
      for (final d in drafts) {
        final tx = TransactionModel(
          id: DatabaseService.newTransactionId(existingIds: existingIds),
          accountId: widget.account.id,
          beneficiary: d.beneficiary,
          amount: d.amount,
          currency: d.currency,
          secondAmount: d.secondAmount,
          secondCurrency: d.secondCurrency,
          notes: "",
          status: TransactionStatus.added,
          date: d.date,
          companyMovementType: _isCompanyAccount ? d.companyMovementType : null,
        );

        await DatabaseService.addTransaction(tx);
        _allTransactions.add(tx);
        _invalidateSearchIndex();
        if (!_knownBeneficiaryNames.contains(tx.beneficiary)) {
          _knownBeneficiaryNames.add(tx.beneficiary);
          _nameConfig.addKnownName(tx.beneficiary);
        }
        saved++;
        addedSegments.add(d.segIndex);
        addRecords.add(
          OperationTxRecord(
            txId: tx.id,
            after: OperationLogService.snapshot(tx),
          ),
        );

        _savedSegments.add(d.segIndex);
        _savedAddSummaries[d.segIndex] = _SavedAddSummary(
          transactionId: tx.id,
          name: d.beneficiary,
          amount: d.amount,
          currency: d.currency,
          secondAmount: d.secondAmount,
          secondCurrency: d.secondCurrency,
          companyMovementType: d.companyMovementType,
          date: d.date,
        );
        if (d.secondAmount == null &&
            _hasMultipleAmountCandidates(d.segIndex)) {
          multiAmountSaved.add(d.segIndex);
        }
        tick('جارٍ حفظ الحركات...');
        if (done % 20 == 0) await yieldToUi();
      }

      if (saved > 0) {
        for (var i = 0; i < _selections.length; i++) {
          if (_needsTarget(i)) {
            _invalidateCancelCandidates(i);
          }
        }
      }

      for (final d in cancelDrafts) {
        final before = OperationLogService.snapshot(d.transaction);
        if (_isCompanyAccount) {
          d.transaction.companyMovementType =
              d.transaction.companyMovementType!.cancelled;
          d.transaction.cancelledAt = d.date;
        } else {
          d.transaction.applyStatus(TransactionStatus.cancelled, at: d.date);
        }
        TxHistoryService.annotate(
          [d.transaction.id],
          'تحليل الرسائل',
          at: d.date,
        );
        await d.transaction.save();
        cancelRecords.add(
          OperationTxRecord(
            txId: d.transaction.id,
            before: before,
            after: OperationLogService.snapshot(d.transaction),
          ),
        );
        cancelledSegments.add(d.segIndex);
        _cancelSelectedTxIds.remove(d.segIndex);
        _cancelledSummaries[d.segIndex] = _CancelledSummary(
          name: d.transaction.beneficiary,
          amount: d.transaction.amount,
          currency: d.transaction.currency,
          date: d.date,
        );
        cancelled++;
        tick('جارٍ تنفيذ الإلغاء...');
        if (done % 20 == 0) await yieldToUi();
      }
    } finally {
      _setProgress(null);
      if (mounted) {
        setState(() => _isSending = false);
      }
    }

    // تسجيل العمليات في السجل (للتراجع لاحقًا)
    OperationLogEntry? entry;
    if (addRecords.isNotEmpty) {
      entry = await OperationLogService.log(
        kind: OperationKind.bubbleAdd,
        title: 'إضافة ${addRecords.length} حركة إلى «${widget.account.name}»',
        subtitle: widget.account.type.label,
        records: addRecords,
      );
    }
    if (cancelRecords.isNotEmpty) {
      entry = await OperationLogService.log(
        kind: OperationKind.bubbleCancel,
        title: 'إلغاء ${cancelRecords.length} حركة من «${widget.account.name}»',
        subtitle: widget.account.type.label,
        records: cancelRecords,
      );
    }

    if (!mounted) return;

    if (saved > 0) {
      for (var i = 0; i < _selections.length; i++) {
        if (_needsTarget(i)) {
          _requestCancelCandidates(i);
        }
      }
    }

    final messenger = ScaffoldMessenger.of(context);
    final loggedEntry = entry;
    final segmentsForUndo = mode == BubbleActionMode.add
        ? addedSegments
        : cancelledSegments;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            [
              if (saved > 0) "تمت إضافة $saved حركة",
              if (cancelled > 0) "تم إلغاء $cancelled حركة",
            ].join('، '),
          ),
          action: loggedEntry == null
              ? null
              : SnackBarAction(
                  label: 'تراجع',
                  onPressed: () => _undoFromSnackBar(
                    loggedEntry,
                    segmentsForUndo,
                    messenger,
                  ),
                ),
        ),
      );

    if (multiAmountSaved.isNotEmpty) {
      await _showPostSaveMultiAmountDialog(multiAmountSaved);
    }

    if (!mounted) return;

    // الترتيب: بعد الإضافات ننتقل إلى التعديلات ثم الإلغاء
    if (mode == BubbleActionMode.add) {
      if (_hasEditSegments()) {
        setState(() => _viewMode = BubbleActionMode.edit);
        return;
      }
      if (_hasCancelSegments()) {
        setState(() => _viewMode = BubbleActionMode.cancel);
        return;
      }
      Navigator.pop(context, true);
      return;
    }

    if (!_hasCancelSegments() &&
        !_hasPendingAddSegments() &&
        !_hasEditSegments()) {
      Navigator.pop(context, true);
    }
  }

  /// تراجع سريع من رسالة النجاح (يعمل حتى لو أُغلقت الشاشة)
  Future<void> _undoFromSnackBar(
    OperationLogEntry entry,
    List<int> segIndexes,
    ScaffoldMessengerState messenger,
  ) async {
    final affected = await OperationLogService.undo(entry);
    if (mounted) {
      final deletedIds = entry.kind.createsTransactions ? entry.txIds : <int>{};
      setState(() {
        for (final i in segIndexes) {
          _savedSegments.remove(i);
          _savedAddSummaries.remove(i);
          _cancelledSummaries.remove(i);
          _editedSummaries.remove(i);
          if (i < _selections.length) _refreshStageForSegment(i);
        }
        _allTransactions.removeWhere((t) => deletedIds.contains(t.id));
        // التراجع عن تعديل يعيد الأسماء القديمة: نعيد تطبيع الأسماء
        _txNormNames = Expando<String>('txNormName');
        _invalidateSearchIndex();
        _pastNamesByTx = null;
        for (var i = 0; i < _selections.length; i++) {
          if (_needsTarget(i)) {
            _invalidateCancelCandidates(i);
          }
        }
      });
      for (var i = 0; i < _selections.length; i++) {
        if (_needsTarget(i)) _requestCancelCandidates(i);
      }
    }
    messenger.showSnackBar(
      SnackBar(content: Text('تم التراجع عن العملية ($affected حركة)')),
    );
  }

  Future<void> _openOperationsLog() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const OperationsLogScreen()));
    if (!mounted) return;
    // قد يكون المستخدم تراجع عن عمليات: نحدّث نسخة الحركات
    setState(() {
      _allTransactions = DatabaseService.transactionsBox.values.toList();
      _txNormNames = Expando<String>('txNormName');
      _invalidateSearchIndex();
      _pastNamesByTx = null;
      for (var i = 0; i < _selections.length; i++) {
        if (_needsTarget(i)) {
          _invalidateCancelCandidates(i);
        }
      }
    });
    for (var i = 0; i < _selections.length; i++) {
      if (_needsTarget(i)) _requestCancelCandidates(i);
    }
  }

  Future<void> _openBubbleSettings() async {
    final confirmBefore = _prefs.confirmMultiAmount;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
    if (!mounted) return;
    setState(_reloadSettings);
    // تغيّر خيار «تأكيد عند وجود أكثر من مبلغ»: نعيد تحليل الفقاعات غير المحفوظة
    if (confirmBefore != _prefs.confirmMultiAmount) {
      await _reanalyzeUnsaved();
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
      case SelectionStage.newName:
        return _newNameColor;
    }
  }

  Color _borderColorForSegment(int segIndex, _SegmentSelection sel) {
    if (_modeOf(segIndex) == BubbleActionMode.cancel) {
      if (_cancelReady(segIndex) || _cancelAlreadyResolved(segIndex)) {
        return _chipGreen;
      }
      return _chipRed;
    }
    if (_modeOf(segIndex) == BubbleActionMode.edit) {
      return _editReady(segIndex) ? _chipGreen : _chipEdit;
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

    if (_modeOf(segIndex) == BubbleActionMode.edit) {
      if (sel.stage == SelectionStage.newName) {
        return 'حدد الاسم الجديد الذي ستصبح عليه الحركة';
      }
      if (_targetSearchName(segIndex).isEmpty) {
        return 'حدد اسم البحث (أو الصقه/اكتبه) لعرض الحركات المراد تعديلها';
      }
      if (_selectedEditTx(segIndex) == null) {
        return 'اختر الحركة التي تريد تعديلها من النتائج';
      }
      if (_editReady(segIndex)) return 'جاهزة: راجع التعديلات ثم نفّذها';
      return 'اختر ما تريد تعديله: الاسم أو المبلغ أو العملة';
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

  /// النتائج المعروضة قبل «عرض المزيد»: إذا وُجدت حركات مضافة بالاسم نفسه
  /// تمامًا تُعرض وحدها (بدون المستلمة والملغية والمتشابهة)
  List<TransactionModel> _collapsedTargetCandidates(
    int segIndex,
    bool Function(TransactionModel) active,
  ) {
    final candidates = _cancelCandidatesForSegment(segIndex);
    final exactActive = [
      for (final tx in candidates)
        if (active(tx) && _isExactHit(segIndex, tx)) tx,
    ];
    if (exactActive.isNotEmpty) return exactActive.take(5).toList();
    final activeOnes = candidates.where(active).toList();
    if (activeOnes.isNotEmpty) return activeOnes.take(5).toList();
    return candidates.take(5).toList();
  }

  List<TransactionModel> _visibleCancelCandidates(int segIndex) {
    if (_cancelShowMore[segIndex] == true) {
      return _cancelCandidatesForSegment(segIndex);
    }
    return _collapsedTargetCandidates(segIndex, _canCancel);
  }

  bool _hasMoreCancelCandidates(int segIndex) =>
      _cancelCandidatesForSegment(segIndex).length >
      _collapsedTargetCandidates(segIndex, _canCancel).length;

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
        chip(BubbleActionMode.edit, 'تعديل', Icons.edit_rounded, _chipEdit),
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
        if (_needsTarget(segIndex)) {
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
          case SelectionStage.newName:
            _clearCategory(segIndex, 'newName');
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
            final hit = _hitFor(segIndex, tx);
            final exactMatch = hit?.exact ?? false;
            final pastName = hit?.pastName;

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
                      '${tx.beneficiary} — ${_fmtAmount(tx.amount)} ${tx.currency}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Chip(
                            label: Text(
                              exactMatch ? 'مطابقة تمامًا' : 'متشابهة',
                            ),
                            visualDensity: VisualDensity.compact,
                            avatar: Icon(
                              exactMatch
                                  ? Icons.verified_rounded
                                  : Icons.compare_arrows_rounded,
                              size: 16,
                            ),
                            backgroundColor:
                                (exactMatch ? _chipGreen : _chipYellow)
                                    .withValues(alpha: .12),
                          ),
                          if (pastName != null)
                            Chip(
                              label: Text('بالاسم السابق: $pastName'),
                              visualDensity: VisualDensity.compact,
                              avatar: const Icon(
                                Icons.history_rounded,
                                size: 16,
                              ),
                              backgroundColor: _chipIndigo.withValues(
                                alpha: .12,
                              ),
                            ),
                        ],
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

  // ====== رسائل التعديل: تعديل حركة موجودة ======

  /// الحركة المختارة للتعديل (من كل حركات الحساب، حتى لو تغيّرت نتائج البحث)
  TransactionModel? _selectedEditTx(int segIndex) {
    final id = _editSelectedTxIds[segIndex];
    if (id == null) return null;
    for (final tx in _allTransactions) {
      if (tx.id == id && tx.accountId == widget.account.id) return tx;
    }
    return null;
  }

  /// نفس العملة؟ (الاختصار أو الرمز يُحوّل إلى اسم العملة من الإعدادات)
  bool _sameCurrencyName(String a, String b) =>
      _eqCur(_currencyNameForToken(a) ?? a, _currencyNameForToken(b) ?? b);

  /// مقارنة ما اكتُشف في الرسالة مع قيم الحركة المختارة
  List<em.EditProposal> _editProposalsFor(int segIndex, TransactionModel tx) {
    final seg = _segments[segIndex];
    final sel = _selections[segIndex];
    return em.buildEditProposals(
      oldName: tx.beneficiary,
      oldAmount: tx.amount,
      oldCurrency: tx.currency,
      newName: _editNewName(segIndex),
      newAmount: _buildSelectedAmount(seg, sel, segIndex),
      newCurrency: _buildSelectedCurrency(seg, sel),
      normalizeName: _normalizeForSearch,
      sameCurrency: _sameCurrencyName,
      formatAmount: _fmtAmount,
    );
  }

  bool _editReady(int segIndex) {
    if (_modeOf(segIndex) != BubbleActionMode.edit ||
        _editedSummaries.containsKey(segIndex)) {
      return false;
    }
    final tx = _selectedEditTx(segIndex);
    if (tx == null) return false;
    return em
        .effectiveEditFields(
          _editProposalsFor(segIndex, tx),
          _editFields[segIndex] ?? const <em.EditField>{},
        )
        .isNotEmpty;
  }

  List<_PendingEditDraft> _collectReadyEditDrafts() {
    final drafts = <_PendingEditDraft>[];
    for (var i = 0; i < _selections.length; i++) {
      if (_modeOf(i) != BubbleActionMode.edit) continue;
      if (_editedSummaries.containsKey(i)) continue;
      final tx = _selectedEditTx(i);
      if (tx == null) continue;
      final proposals = _editProposalsFor(i, tx);
      final fields = em.effectiveEditFields(
        proposals,
        _editFields[i] ?? const <em.EditField>{},
      );
      if (fields.isEmpty) continue;
      final seg = _segments[i];
      final sel = _selections[i];
      drafts.add(
        _PendingEditDraft(
          segIndex: i,
          transaction: tx,
          proposals: proposals,
          fields: fields,
          name: fields.contains(em.EditField.name) ? _editNewName(i) : null,
          amount: fields.contains(em.EditField.amount)
              ? _buildSelectedAmount(seg, sel, i)
              : null,
          currency: fields.contains(em.EditField.currency)
              ? _buildSelectedCurrency(seg, sel)
              : null,
        ),
      );
    }
    return drafts;
  }

  void _selectEditTx(int segIndex, TransactionModel tx) {
    setState(() {
      _editSelectedTxIds[segIndex] = tx.id;
      _editPickerOpen.remove(segIndex);
      _editFields[segIndex] = em.defaultEditSelection(
        _editProposalsFor(segIndex, tx),
      );
      _syncEditNameField(segIndex);
    });
  }

  void _toggleEditField(int segIndex, em.EditField field) {
    setState(() {
      final chosen = _editFields.putIfAbsent(segIndex, () => <em.EditField>{});
      if (!chosen.remove(field)) chosen.add(field);
    });
  }

  /// اسم بحث يدوي (null أو فارغ = الرجوع إلى الاسم المحدد في الرسالة)
  void _setEditSearch(int segIndex, String? query) {
    final q = query?.trim() ?? '';
    setState(() {
      if (q.isEmpty) {
        _editSearchQueries.remove(segIndex);
      } else {
        _editSearchQueries[segIndex] = q;
        // البحث باسم آخر: الاسم المحدد في الرسالة يصبح «الاسم الجديد» (كما
        // كان سابقًا) ما لم يُحدَّد اسم جديد
        final sel = _selections[segIndex];
        final messageName = _buildSelectedName(
          _segments[segIndex],
          sel,
          segIndex,
        ).trim();
        if (_editNewName(segIndex).isEmpty &&
            messageName.isNotEmpty &&
            _normalizeForSearch(messageName) != _normalizeForSearch(q)) {
          if (sel.nameTokens.isNotEmpty && _nameOverride[segIndex] == null) {
            sel.newNameTokens.addAll(sel.nameTokens);
            sel.nameTokens.clear();
          } else {
            _editNewNameOverride[segIndex] = messageName;
            _nameOverride.remove(segIndex);
            sel.nameTokens.clear();
          }
        }
      }
      _invalidateCancelCandidates(segIndex);
      _editPickerOpen.add(segIndex);
    });
    _requestCancelCandidates(segIndex);
  }

  Future<void> _openEditSearchDialog(int segIndex) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _EditSearchDialog(initial: _targetSearchName(segIndex)),
    );
    if (!mounted || result == null) return;
    _setEditSearch(segIndex, result);
  }

  Widget _buildEditPanel(BuildContext context, int segIndex) {
    const color = _chipEdit;
    final searchName = _targetSearchName(segIndex);
    final manual = (_editSearchQueries[segIndex] ?? '').trim();
    final selectedTx = _selectedEditTx(segIndex);
    final pickerOpen = selectedTx == null || _editPickerOpen.contains(segIndex);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.manage_search_rounded, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  searchName.isEmpty
                      ? 'البحث عن الحركة'
                      : 'البحث عن: «$searchName»',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              if (manual.isNotEmpty)
                IconButton(
                  tooltip: 'البحث بالاسم الموجود في الرسالة',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => _setEditSearch(segIndex, null),
                ),
              TextButton.icon(
                onPressed: () => _openEditSearchDialog(segIndex),
                icon: const Icon(Icons.search_rounded, size: 18),
                label: Text(manual.isEmpty ? 'بحث باسم آخر' : 'تغيير البحث'),
                style: TextButton.styleFrom(
                  foregroundColor: _readable(context, color),
                ),
              ),
            ],
          ),
          if (pickerOpen) _buildEditCandidates(context, segIndex, searchName),
          if (selectedTx != null)
            _buildEditChoices(
              context,
              segIndex,
              selectedTx,
              pickerOpen: pickerOpen,
            ),
        ],
      ),
    );
  }

  Widget _buildEditCandidates(
    BuildContext context,
    int segIndex,
    String searchName,
  ) {
    final cs = Theme.of(context).colorScheme;
    const color = _chipEdit;
    if (searchName.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _inlineInfoBox(
          context,
          icon: Icons.person_search_rounded,
          color: color,
          text:
              'حدد الاسم من الفقاعات، أو اضغط «بحث باسم آخر» واكتب اسم صاحب الحركة.',
        ),
      );
    }

    final loading = _cancelCandidatesLoading.contains(segIndex);
    final query = _cancelQueryForSegment(segIndex);
    final stale =
        _cancelCandidateQueries[segIndex] != query ||
        !_cancelCandidatesCache.containsKey(segIndex);
    if (!loading && stale) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _requestCancelCandidates(segIndex);
      });
    }
    final candidates = _cancelCandidatesForSegment(segIndex);
    if (candidates.isEmpty) {
      if (loading || stale) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
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
                  'جارٍ البحث في هذا الحساب عن «$searchName»...',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _inlineInfoBox(
          context,
          icon: Icons.search_off_rounded,
          color: color,
          text:
              'لا توجد حركات مطابقة للاسم «$searchName» في هذا الحساب. جرّب «بحث باسم آخر».',
        ),
      );
    }

    final showAll = _cancelShowMore[segIndex] == true;
    final collapsed = _collapsedTargetCandidates(segIndex, _isActiveTx);
    final visible = showAll ? candidates : collapsed;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'اختر الحركة التي تريد تعديلها (${candidates.length})',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (final tx in visible)
            _buildEditCandidateRow(context, segIndex, tx, searchName),
          if (candidates.length > collapsed.length)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _cancelShowMore[segIndex] = !showAll),
                icon: Icon(
                  showAll
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: Text(
                  showAll ? 'عرض أقل' : 'عرض المزيد (${candidates.length})',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditCandidateRow(
    BuildContext context,
    int segIndex,
    TransactionModel tx,
    String searchName,
  ) {
    final cs = Theme.of(context).colorScheme;
    const color = _chipEdit;
    final selected = _editSelectedTxIds[segIndex] == tx.id;
    final hit = _hitFor(segIndex, tx);
    final exact = hit?.exact ?? false;
    final pastName = hit?.pastName;
    final movement = tx.companyMovementType;
    final statusColor = movement != null
        ? (movement.isCancelled
              ? _chipRed
              : (movement.isSent ? _chipIndigo : _chipGreen))
        : _txStatusColor(tx.status);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? color.withValues(alpha: .14)
            : cs.surface.withValues(alpha: .85),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _selectEditTx(segIndex, tx),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? color
                    : cs.outlineVariant.withValues(alpha: .35),
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? color : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${tx.beneficiary} — ${_fmtAmount(tx.amount)} ${tx.currency}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _statusChip(context, _anyTxLabel(tx), statusColor),
                          if (exact)
                            _statusChip(context, 'مطابقة تمامًا', _chipGreen),
                          if (pastName != null)
                            _statusChip(
                              context,
                              'بالاسم السابق: $pastName',
                              _chipIndigo,
                            ),
                          Text(
                            _fmtDateTime(tx.date),
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEditChoices(
    BuildContext context,
    int segIndex,
    TransactionModel tx, {
    required bool pickerOpen,
  }) {
    final cs = Theme.of(context).colorScheme;
    const color = _chipEdit;
    final proposals = _editProposalsFor(segIndex, tx);
    final chosen = _editFields[segIndex] ?? const <em.EditField>{};

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: .9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.edit_note_rounded, color: color, size: 20),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'الحركة المختارة',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              if (!pickerOpen)
                TextButton(
                  onPressed: () =>
                      setState(() => _editPickerOpen.add(segIndex)),
                  child: const Text('تغيير الحركة'),
                ),
            ],
          ),
          Text(
            '${tx.beneficiary} — ${_fmtAmount(tx.amount)} ${tx.currency}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            '${_anyTxLabel(tx)} • ${_fmtDateTime(tx.date)}',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const Divider(height: 18),
          const Text(
            'ما الذي تريد تعديله؟',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
          ),
          const SizedBox(height: 2),
          for (final p in proposals)
            _buildEditFieldRow(context, segIndex, p, chosen),
        ],
      ),
    );
  }

  Widget _buildEditFieldRow(
    BuildContext context,
    int segIndex,
    em.EditProposal p,
    Set<em.EditField> chosen,
  ) {
    final cs = Theme.of(context).colorScheme;
    const color = _chipEdit;
    final enabled = p.available;
    final checked = enabled && chosen.contains(p.field);
    final muted = cs.onSurfaceVariant;
    final icon = switch (p.field) {
      em.EditField.name => Icons.person_rounded,
      em.EditField.amount => Icons.payments_rounded,
      em.EditField.currency => Icons.currency_exchange_rounded,
    };

    final Widget detail;
    if (p.newText == null) {
      detail = Text(
        p.field == em.EditField.name
            ? 'بدون تغيير — حدد «الاسم الجديد» إن أردت تعديله'
            : 'لم يُحدَّد في الرسالة',
        style: TextStyle(color: muted, fontSize: 12.5),
      );
    } else if (!p.changes) {
      detail = Text(
        'بدون تغيير (${p.oldText})',
        style: TextStyle(color: muted, fontSize: 12.5),
      );
    } else {
      detail = Text.rich(
        TextSpan(
          style: TextStyle(color: cs.onSurface, fontSize: 13),
          children: [
            const TextSpan(text: 'من '),
            TextSpan(
              text: p.oldText,
              style: TextStyle(
                color: muted,
                decoration: TextDecoration.lineThrough,
                decorationColor: muted,
              ),
            ),
            const TextSpan(text: ' إلى '),
            TextSpan(
              text: p.newText,
              style: TextStyle(
                color: _readable(context, color),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      );
    }

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled ? () => _toggleEditField(segIndex, p.field) : null,
      child: Row(
        children: [
          Checkbox(
            value: checked,
            onChanged: enabled
                ? (_) => _toggleEditField(segIndex, p.field)
                : null,
            activeColor: color,
            visualDensity: VisualDensity.compact,
          ),
          Icon(icon, size: 18, color: enabled ? color : muted),
          const SizedBox(width: 6),
          Text(
            '${em.EditFieldInfo(p.field).label}:',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: enabled ? cs.onSurface : muted,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(child: detail),
        ],
      ),
    );
  }

  Widget _buildLockedEditBubble(BuildContext context, _EditedSummary summary) {
    return _lockedSummaryCard(
      context: context,
      color: _chipEdit,
      icon: Icons.edit_note_rounded,
      title: 'تم تعديل ${summary.name}',
      lines: [...summary.lines, 'وقت التعديل: ${_fmtDateTime(summary.date)}'],
    );
  }

  /// تنفيذ رسائل التعديل الجاهزة (بعد الإضافات وقبل الإلغاء)
  Future<void> _sendEdits() async {
    if (_busy) return;
    final drafts = _collectReadyEditDrafts();
    if (drafts.isEmpty) {
      _snack('لا توجد تعديلات جاهزة للتنفيذ');
      return;
    }

    setState(() => _isSending = true);
    final records = <OperationTxRecord>[];
    final editedSegments = <int>[];
    var done = 0;
    _setProgress(
      OperationProgress(
        label: 'جارٍ تنفيذ التعديلات...',
        done: 0,
        total: drafts.length,
      ),
    );

    try {
      for (final d in drafts) {
        final tx = d.transaction;
        final before = OperationLogService.snapshot(tx);
        final lines = <String>[
          for (final p in d.proposals)
            if (d.fields.contains(p.field)) p.sentence,
        ];
        final name = d.name;
        if (name != null && name.isNotEmpty) tx.beneficiary = name;
        final amount = d.amount;
        if (amount != null && amount > 0) tx.amount = amount;
        final currency = d.currency;
        if (currency != null && currency.isNotEmpty) tx.currency = currency;
        // وقت التعديل = وقت الرسالة (مثل الإضافة والإلغاء)
        final at = _segments[d.segIndex].timestamp ?? DateTime.now();
        TxHistoryService.annotate(
          [tx.id],
          'تحليل الرسائل (رسالة تعديل)',
          at: at,
        );
        await tx.save();
        _txNormNames[tx] = null;
        _invalidateSearchIndex();
        if (name != null) _pastNamesByTx = null;
        if (name != null && !_knownBeneficiaryNames.contains(tx.beneficiary)) {
          _knownBeneficiaryNames.add(tx.beneficiary);
          _nameConfig.addKnownName(tx.beneficiary);
        }
        records.add(
          OperationTxRecord(
            txId: tx.id,
            before: before,
            after: OperationLogService.snapshot(tx),
          ),
        );
        editedSegments.add(d.segIndex);
        _editedSummaries[d.segIndex] = _EditedSummary(
          name: tx.beneficiary,
          lines: lines,
          date: at,
        );
        done++;
        _setProgress(
          OperationProgress(
            label: 'جارٍ تنفيذ التعديلات...',
            done: done,
            total: drafts.length,
          ),
        );
        if (done % 20 == 0) await yieldToUi();
      }
    } finally {
      _setProgress(null);
      if (mounted) {
        setState(() => _isSending = false);
      }
    }

    OperationLogEntry? entry;
    if (records.isNotEmpty) {
      entry = await OperationLogService.log(
        kind: OperationKind.bubbleEdit,
        title: 'تعديل ${records.length} حركة في «${widget.account.name}»',
        subtitle: widget.account.type.label,
        records: records,
      );
    }
    if (!mounted) return;

    // الأسماء أو المبالغ تغيّرت: نحدّث نتائج البحث في فقاعات الإلغاء والتعديل
    setState(() {
      for (var i = 0; i < _selections.length; i++) {
        if (_needsTarget(i)) _invalidateCancelCandidates(i);
      }
    });
    for (var i = 0; i < _selections.length; i++) {
      if (_needsTarget(i)) _requestCancelCandidates(i);
    }

    final messenger = ScaffoldMessenger.of(context);
    final loggedEntry = entry;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text('تم تعديل ${records.length} حركة'),
          action: loggedEntry == null
              ? null
              : SnackBarAction(
                  label: 'تراجع',
                  onPressed: () =>
                      _undoFromSnackBar(loggedEntry, editedSegments, messenger),
                ),
        ),
      );

    // بعد التعديلات يأتي الإلغاء
    if (_hasCancelSegments()) {
      setState(() => _viewMode = BubbleActionMode.cancel);
      return;
    }
    if (!_hasPendingAddSegments() && !_hasEditSegments()) {
      Navigator.pop(context, true);
    }
  }

  /// زر التنفيذ في الشريط السفلي (مضغوط عند وجود ثلاثة أزرار)
  Widget _sendButton({
    required BubbleActionMode mode,
    required bool enabled,
    required IconData icon,
    required String label,
    required Color color,
    required bool compact,
  }) {
    final busy = _isSending && _viewMode == mode;
    final Widget iconWidget = busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon);
    final style = FilledButton.styleFrom(
      padding: compact
          ? const EdgeInsets.symmetric(vertical: 10, horizontal: 6)
          : const EdgeInsets.symmetric(vertical: 14),
      backgroundColor: color,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
    final onPressed = enabled ? () => _sendForMode(mode) : null;
    if (!compact) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: iconWidget,
        label: Text(label),
        style: style,
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: style,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget,
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
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

  int _readyEditCount() => _collectReadyEditDrafts().length;

  int _forbiddenSegmentsCount() =>
      _selections.where((s) => s.forbiddenPhrases.isNotEmpty).length;

  Widget _buildBubbleScreenHeader(
    BuildContext context, {
    required int addReadyCount,
    required int editReadyCount,
    required int cancelReadyCount,
  }) {
    final cs = Theme.of(context).colorScheme;
    final forbiddenCount = _forbiddenSegmentsCount();
    final showEditChip =
        _segmentCountForMode(BubbleActionMode.edit) > 0 ||
        _viewMode == BubbleActionMode.edit;

    Widget stat({
      required IconData icon,
      required String label,
      required String value,
      required Color color,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: .20)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 5),
              Text(
                value,
                style: TextStyle(
                  color: _readable(context, color),
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: .68),
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
      final color = mode == BubbleActionMode.add
          ? _chipGreen
          : (mode == BubbleActionMode.edit ? _chipEdit : _chipRed);
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
                color: selected
                    ? color
                    : cs.outlineVariant.withValues(alpha: .35),
              ),
            ),
            child: showEditChip
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        color: selected ? Colors.white : color,
                        size: 19,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? Colors.white
                              : _readable(context, color),
                          fontWeight: FontWeight.w900,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        color: selected ? Colors.white : color,
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? Colors.white
                                : _readable(context, color),
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
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .06),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
              if (showEditChip) ...[
                const SizedBox(width: 8),
                stat(
                  icon: Icons.edit_note_rounded,
                  label: 'تعديل جاهز',
                  value: '$editReadyCount',
                  color: _chipEdit,
                ),
              ],
              const SizedBox(width: 8),
              stat(
                icon: Icons.cancel_rounded,
                label: 'إلغاء جاهز',
                value: '$cancelReadyCount',
                color: _chipRed,
              ),
              if (forbiddenCount > 0) ...[
                const SizedBox(width: 8),
                stat(
                  icon: Icons.gpp_bad_rounded,
                  label: 'جمل ممنوعة',
                  value: '$forbiddenCount',
                  color: _forbiddenColor,
                ),
              ],
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
              if (showEditChip) ...[
                const SizedBox(width: 10),
                modeChip(
                  BubbleActionMode.edit,
                  'التعديلات (${_segmentCountForMode(BubbleActionMode.edit)})',
                  Icons.edit_note_rounded,
                ),
              ],
              const SizedBox(width: 10),
              modeChip(
                BubbleActionMode.cancel,
                'الإلغاء (${_segmentCountForMode(BubbleActionMode.cancel)})',
                Icons.cancel_schedule_send_rounded,
              ),
            ],
          ),
          if (_prefs.showLegend) ...[
            const SizedBox(height: 10),
            _buildLegend(context),
          ],
        ],
      ),
    );
  }

  Widget _buildLegend(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget item(Color c, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.withValues(alpha: .25),
            border: Border.all(color: c, width: 1.4),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );

    return InkWell(
      onTap: () => setState(() => _legendExpanded = !_legendExpanded),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'دليل الألوان وطريقة الاستخدام',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                Icon(
                  _legendExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                item(_nameColor, 'الاسم'),
                item(_amountColor, 'المبلغ'),
                item(_currencyColor, 'العملة'),
                item(_chipYellow, 'هاتف'),
                item(_chipRed, 'مبلغ بالحروف'),
                item(_forbiddenColor, 'ممنوع'),
              ],
            ),
            if (_legendExpanded) ...[
              const SizedBox(height: 8),
              Text(
                '• اضغط على الكلمة لتحديدها حسب المرحلة الحالية (الاسم ← المبلغ ← العملة).\n'
                '• عند تحديد الاسم يمتد تلقائيًا حتى نهاية السطر أو حتى أول كلمة ممنوعة أو رقم أو عملة أو كلمة إيقاف.\n'
                '• اضغط مطولًا على أي كلمة (أو بزر الفأرة الأيمن) لإضافتها ككلمة ممنوعة أو اختصار عملة أو كلمة اسم وغيرها.\n'
                '• يمكنك تغيير الألوان وحجم الخط وطريقة العرض من الإعدادات ← تخصيص شاشة الفقاعات.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.55,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
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
      margin: EdgeInsets.only(bottom: _prefs.compact ? 8 : 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: .34), width: 1.6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .14),
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
                          color: _readable(context, color),
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
        if (summary.secondAmount != null)
          'المبلغ الثاني: ${_fmtAmount(summary.secondAmount!)} ${summary.secondCurrency ?? ''}',
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

  // ====== بطاقة الفقاعة (التصميم الجديد) ======
  Color _avatarColor(String name) {
    if (name.trim().isEmpty) return _gradStart;
    final hue = (name.trim().hashCode.abs() % 360).toDouble();
    return HSVColor.fromAHSV(1, hue, .55, .75).toColor();
  }

  String _fmtShortStamp(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} • ${two(dt.hour)}:${two(dt.minute)}';
  }

  Widget _statusChip(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: _readable(context, color),
          fontWeight: FontWeight.w900,
          fontSize: 11.5,
        ),
      ),
    );
  }

  Widget _buildCardHeader(
    BuildContext context,
    int si, {
    required String statusText,
    required Color statusColor,
  }) {
    final seg = _segments[si];
    final sender = seg.senderName.trim();
    final avatar = _avatarColor(sender);
    final initial = sender.isEmpty ? '${si + 1}' : sender.characters.first;
    // صفوف الملفات المستوردة: العنوان «صف N» بدل «رسالة N»
    final untitled = seg.header.trim().isNotEmpty
        ? seg.header.trim()
        : 'رسالة ${si + 1}';

    return Row(
      children: [
        if (_prefs.showSenderHeader) ...[
          CircleAvatar(
            radius: _prefs.compact ? 14 : 17,
            backgroundColor: avatar.withValues(alpha: .18),
            child: Text(
              initial,
              style: TextStyle(
                color: _readable(context, avatar),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sender.isEmpty ? untitled : sender,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14.5,
                  ),
                ),
                if (seg.timestamp != null)
                  Text(
                    _fmtShortStamp(seg.timestamp!),
                    style: TextStyle(fontSize: 11.5, color: _muted(context)),
                  ),
              ],
            ),
          ),
        ] else
          Expanded(
            child: Text(
              sender.isEmpty ? untitled : 'رسالة ${si + 1}',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        const SizedBox(width: 6),
        _statusChip(context, statusText, statusColor),
        PopupMenuButton<String>(
          tooltip: 'خيارات الفقاعة',
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (value) async {
            switch (value) {
              case 'copy':
                final text = seg.lines.join('\n').trim();
                await Clipboard.setData(ClipboardData(text: text));
                _snack('تم نسخ نص الرسالة');
                break;
              case 'copyName':
                await _copyNameToClipboard(si);
                break;
              case 'reset':
                _clearSelection(si);
                break;
              case 'delete':
                await _confirmDeleteSegment(si);
                break;
            }
          },
          itemBuilder: (_) {
            PopupMenuItem<String> item(
              String value,
              IconData icon,
              String label, {
              Color? color,
            }) {
              return PopupMenuItem<String>(
                value: value,
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: color),
                    const SizedBox(width: 10),
                    Text(label, style: TextStyle(color: color)),
                  ],
                ),
              );
            }

            return [
              item('copy', Icons.copy_all_rounded, 'نسخ نص الرسالة'),
              item('copyName', Icons.badge_outlined, 'نسخ الاسم'),
              item('reset', Icons.restart_alt_rounded, 'إلغاء التحديد الكلّي'),
              item(
                'delete',
                Icons.delete_outline_rounded,
                'حذف الفقاعة',
                color: Colors.red,
              ),
            ];
          },
        ),
      ],
    );
  }

  Widget _pillAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    required Color color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }

  Widget _rolePill(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String? value,
    required Color color,
    required bool active,
    VoidCallback? onTap,
    List<({IconData icon, String tooltip, VoidCallback onTap})> actions =
        const [],
    String emptyText = 'غير محدد',
  }) {
    final done = value != null && value.trim().isNotEmpty;
    final fg = active ? Colors.white : _readable(context, color);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: 10,
          vertical: _prefs.compact ? 5 : 8,
        ),
        decoration: BoxDecoration(
          color: active ? color : color.withValues(alpha: done ? .15 : .07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: color.withValues(alpha: active ? 1 : (done ? .6 : .35)),
            width: active ? 1.6 : 1.1,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: .30),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(done ? Icons.check_circle_rounded : icon, size: 17, color: fg),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                done ? '$title: $value' : '$title: $emptyText',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontWeight: FontWeight.w800),
              ),
            ),
            for (final a in actions) ...[
              const SizedBox(width: 4),
              _pillAction(
                icon: a.icon,
                tooltip: a.tooltip,
                onTap: a.onTap,
                color: fg,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRolePills(
    BuildContext context,
    int si, {
    required BubbleActionMode mode,
    required String nameText,
    required double? amountVal,
    required String? currencyText,
  }) {
    final sel = _selections[si];
    final stage = sel.stage;
    final nameColor = mode == BubbleActionMode.cancel ? _chipRed : _nameColor;

    void clearAmountOrCurrency(String category) {
      final s = _selections[si];
      if (s.amount != null &&
          s.currencyToken != null &&
          s.amount == s.currencyToken) {
        _showClearAmountOrCurrencyDialog(si);
      } else {
        _clearCategory(si, category);
      }
    }

    final isEdit = mode == BubbleActionMode.edit;
    final searchName = isEdit ? _targetSearchName(si) : '';
    final newName = isEdit ? _editNewName(si) : '';

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (isEdit) ...[
          // التعديل: اسم للبحث عن الحركة، واسم جديد تصبح عليه
          _rolePill(
            context,
            icon: Icons.person_search_rounded,
            title: 'اسم البحث',
            value: searchName.isEmpty ? null : searchName,
            color: nameColor,
            active: stage == SelectionStage.name,
            onTap: () => _goStage(si, SelectionStage.name),
            actions: [
              (
                icon: Icons.content_paste_rounded,
                tooltip: 'لصق اسم البحث من الحافظة',
                onTap: () => _pasteName(si),
              ),
              (
                icon: Icons.edit_rounded,
                tooltip: 'كتابة اسم البحث',
                onTap: () => _openEditSearchDialog(si),
              ),
              if (searchName.isNotEmpty)
                (
                  icon: Icons.backspace_rounded,
                  tooltip: 'مسح اسم البحث',
                  onTap: () => _clearCategory(si, 'name'),
                ),
            ],
          ),
          _rolePill(
            context,
            icon: Icons.drive_file_rename_outline_rounded,
            title: 'الاسم الجديد',
            value: newName.isEmpty ? null : newName,
            color: _newNameColor,
            active: stage == SelectionStage.newName,
            emptyText: 'بدون تغيير',
            onTap: () => _goStage(si, SelectionStage.newName),
            actions: [
              (
                icon: Icons.content_paste_rounded,
                tooltip: 'لصق الاسم الجديد من الحافظة',
                onTap: () => _pasteEditNewName(si),
              ),
              (
                icon: Icons.edit_rounded,
                tooltip: 'كتابة الاسم الجديد',
                onTap: () => _openEditNewNameDialog(si),
              ),
              if (newName.isNotEmpty)
                (
                  icon: Icons.backspace_rounded,
                  tooltip: 'مسح الاسم الجديد',
                  onTap: () => _clearCategory(si, 'newName'),
                ),
            ],
          ),
        ] else
          _rolePill(
            context,
            icon: Icons.person_rounded,
            title: mode == BubbleActionMode.cancel ? 'اسم الإلغاء' : 'الاسم',
            value: nameText.trim().isEmpty ? null : nameText,
            color: nameColor,
            active: stage == SelectionStage.name,
            onTap: () => _goStage(si, SelectionStage.name),
            actions: [
              (
                icon: Icons.content_paste_rounded,
                tooltip: 'لصق الاسم من الحافظة',
                onTap: () => _pasteName(si),
              ),
              (
                icon: Icons.edit_rounded,
                tooltip: 'تحرير الاسم يدويًا',
                onTap: () => _openNameManualDialog(si, nameText),
              ),
              if (nameText.trim().isNotEmpty)
                (
                  icon: Icons.backspace_rounded,
                  tooltip: 'مسح تحديد الاسم',
                  onTap: () => _clearCategory(si, 'name'),
                ),
            ],
          ),
        if (mode != BubbleActionMode.cancel)
          _rolePill(
            context,
            icon: Icons.numbers_rounded,
            title: 'المبلغ',
            value: amountVal == null ? null : _fmtAmount(amountVal),
            color: _amountColor,
            active: stage == SelectionStage.amount,
            onTap: () => _goStage(si, SelectionStage.amount),
            actions: [
              (
                icon: Icons.edit_rounded,
                tooltip: 'تحرير المبلغ يدويًا',
                onTap: () => _openAmountManualDialog(si, amountVal),
              ),
              if (mode == BubbleActionMode.add &&
                  amountVal != null &&
                  _secondAmount[si] == null)
                (
                  icon: Icons.add_card_rounded,
                  tooltip: 'إضافة مبلغ ثاني',
                  onTap: () => _openSecondAmountDialog(si),
                ),
              if (amountVal != null)
                (
                  icon: Icons.backspace_rounded,
                  tooltip: 'مسح تحديد المبلغ',
                  onTap: () => clearAmountOrCurrency('amount'),
                ),
            ],
          ),
        if (mode == BubbleActionMode.add && _secondAmount[si] != null)
          _rolePill(
            context,
            icon: Icons.add_card_rounded,
            title: 'المبلغ الثاني',
            value:
                '${_fmtAmount(_secondAmount[si]!)} ${_secondCurrency[si] ?? '(بدون عملة)'}',
            color: _amountColor,
            active: false,
            onTap: () => _openSecondAmountDialog(si),
            actions: [
              (
                icon: Icons.currency_exchange_rounded,
                tooltip: 'عملة المبلغ الثاني',
                onTap: () => _pickSecondCurrency(si),
              ),
              (
                icon: Icons.backspace_rounded,
                tooltip: 'حذف المبلغ الثاني',
                onTap: () => _clearSecondAmount(si),
              ),
            ],
          ),
        if (mode != BubbleActionMode.cancel)
          _rolePill(
            context,
            icon: Icons.currency_exchange_rounded,
            title: 'العملة',
            value: currencyText,
            color: _currencyColor,
            active: stage == SelectionStage.currency,
            onTap: () => _goStage(si, SelectionStage.currency),
            actions: [
              if (currencyText != null)
                (
                  icon: Icons.backspace_rounded,
                  tooltip: 'مسح تحديد العملة',
                  onTap: () => clearAmountOrCurrency('currency'),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildStageHint(
    BuildContext context,
    int si,
    _SegmentSelection sel,
    Color color,
  ) {
    final mode = _modeOf(si);
    String extra = '';
    if (mode == BubbleActionMode.add) {
      switch (sel.stage) {
        case SelectionStage.name:
          extra = ' — اضغط على أول كلمة من الاسم';
          break;
        case SelectionStage.amount:
          extra = ' — اضغط على سطر المبلغ';
          break;
        case SelectionStage.currency:
          extra = ' — اضغط على العملة أو اخترها من القائمة';
          break;
        case SelectionStage.done:
        case SelectionStage.newName:
          break;
      }
    } else if (mode == BubbleActionMode.edit &&
        sel.stage == SelectionStage.newName) {
      extra = ' — اضغط على أول كلمة من الاسم الجديد، أو الصقه أو اكتبه';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: .10), color.withValues(alpha: .03)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline_rounded, size: 17, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${_hintForSegment(si, sel)}$extra',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: _readable(context, color),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNameSuggestions(
    BuildContext context,
    int si,
    _SegmentSelection sel,
  ) {
    final cands = sel.nameCandidates.take(4).toList();
    final color = _nameColor;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_search_rounded, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  sel.nameAmbiguous
                      ? 'لم يُحسم الاسم تلقائيًا — اختر السطر الصحيح'
                      : 'اقتراحات للاسم',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: _readable(context, color),
                  ),
                ),
              ),
            ],
          ),
          if ((sel.nameReason ?? '').isNotEmpty && sel.nameAmbiguous) ...[
            const SizedBox(height: 3),
            Text(
              sel.nameReason!,
              style: TextStyle(fontSize: 11.5, color: _muted(context)),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: cands
                .map(
                  (c) => ActionChip(
                    avatar: CircleAvatar(
                      radius: 10,
                      backgroundColor: color.withValues(alpha: .2),
                      child: Text(
                        '${c.lineIndex + 1}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: _readable(context, color),
                        ),
                      ),
                    ),
                    label: Text(c.text),
                    tooltip: 'السطر ${c.lineIndex + 1} • ${c.evidence.label}',
                    onPressed: () => _applyNameCandidate(si, c),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildForbiddenBanner(BuildContext context, _SegmentSelection sel) {
    final fg = _readable(context, _forbiddenColor);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _forbiddenColor.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _forbiddenColor.withValues(alpha: .45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.gpp_bad_rounded, color: _forbiddenColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'تحتوي الرسالة على جملة ممنوعة',
                  style: TextStyle(fontWeight: FontWeight.w900, color: fg),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: sel.forbiddenPhrases
                      .map(
                        (p) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _forbiddenColor.withValues(alpha: .15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '«$p»',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              color: fg,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMultiAmountBox(
    BuildContext context,
    int si, {
    required bool wasSaved,
    required double? amountVal,
    required String nameText,
    required List<double> amountCandidates,
  }) {
    // تعارض في المبلغ: تحذير أوضح وأزرار اعتماد مباشرة
    final amb = wasSaved ? null : _moneyAmbiguity[si];
    final base = amb != null
        ? Colors.deepOrange
        : (wasSaved ? Colors.orange : Colors.amber);
    final String message;
    if (amb != null) {
      final mm = amb.mismatch;
      final values = amb.strongValues.length >= 2
          ? amb.strongValues
          : [for (final o in amb.options) o.value];
      final String head;
      if (mm != null) {
        head =
            'تنبيه: المبلغ بالأرقام (${_fmtAmount(mm.digits)}) لا يطابق المبلغ المكتوب بالحروف (${_fmtAmount(mm.words)}).';
      } else if (amb.multiCurrency) {
        head =
            'تنبيه: عثرت على مبلغين وعملتين في الرسالة (${amb.currencies.join(' ، ')}).';
      } else {
        head =
            'تنبيه: الرسالة فيها مبلغين مختلفين (${values.map(_fmtAmount).join(' و ')}).';
      }
      final String tail;
      if (amountVal == null) {
        tail =
            amb.options.length >= 2 &&
                mm == null &&
                _modeOf(si) == BubbleActionMode.add
            ? ' اعتمد المبلغين معًا (المبلغ والمبلغ الثاني) أو اختر مبلغًا واحدًا:'
            : ' لذلك ما تم تحديد المبلغ تلقائيًا. اختر المبلغ الصحيح:';
      } else if (amb.autoBoth) {
        tail =
            ' تم اعتماد المبلغين تلقائيًا (حسب الإعدادات): المبلغ والمبلغ الثاني — يمكنك اختيار مبلغ واحد بدلًا من ذلك:';
      } else if (amb.autoPicked) {
        tail =
            ' تم اختيار ${_fmtAmount(amountVal)} تلقائيًا (حسب الإعدادات) — اضغط على مبلغ آخر لتغييره:';
      } else {
        tail = ' تأكد أن المبلغ والعملة صحيحين.';
      }
      message = '$head$tail';
    } else {
      message = wasSaved
          ? 'تم حفظ الرسالة، لكن يوجد أكثر من مبلغ محتمل. يمكنك اختيار المبلغ الصحيح ونسخ الاسم أو أي مبلغ بشكل منفصل.'
          : 'تم العثور على أكثر من مبلغ داخل الرسالة. اختر الآن أي مبلغ تريد حفظه.';
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: base.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: base.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (amb != null) ...[
                Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: _readable(context, base),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _readable(context, base),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (amb != null) ...[
            if (_modeOf(si) == BubbleActionMode.add &&
                amb.mismatch == null &&
                amb.firstPair != null &&
                _secondAmount[si] == null) ...[
              FilledButton.icon(
                onPressed: () => _applyBothAmounts(si),
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: Text(
                  'اعتماد المبلغين: ${_amountOptionLabel(amb, amb.firstPair!.$1.value)} + ${_amountOptionLabel(amb, amb.firstPair!.$2.value)}',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.deepOrange,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in amountCandidates)
                  FilledButton.tonalIcon(
                    onPressed: () => _applyChosenAmount(si, v),
                    icon: Icon(
                      amountVal != null && (amountVal - v).abs() < 0.0001
                          ? Icons.check_circle
                          : Icons.touch_app_outlined,
                      size: 18,
                    ),
                    label: Text(_amountOptionLabel(amb, v)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (amountVal != null)
            Text(
              'المبلغ المعتمد حاليًا: ${_fmtAmount(amountVal)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          if (_secondAmount[si] != null)
            Text(
              'المبلغ الثاني: ${_fmtAmount(_secondAmount[si]!)} ${_secondCurrency[si] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () =>
                    _openMultiAmountPickerDialog(si, afterSave: wasSaved),
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
    );
  }

  Widget _buildSegmentCard(BuildContext context, int si) {
    final seg = _segments[si];
    final sel = _selections[si];
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final mode = _modeOf(si);
    final savedSummary = _savedAddSummaries[si];
    if (mode == BubbleActionMode.add && savedSummary != null) {
      return _buildLockedAddBubble(context, savedSummary);
    }
    final cancelledSummary = _cancelledSummaries[si];
    if (mode == BubbleActionMode.cancel && cancelledSummary != null) {
      return _buildLockedCancelBubble(context, cancelledSummary);
    }
    final editedSummary = _editedSummaries[si];
    if (mode == BubbleActionMode.edit && editedSummary != null) {
      return _buildLockedEditBubble(context, editedSummary);
    }

    final nameText = _buildSelectedName(seg, sel, si);
    final amountVal = _buildSelectedAmount(seg, sel, si);
    final currencyText = _buildSelectedCurrency(seg, sel);
    final wasSaved = _savedSegments.contains(si);
    final amountCandidates =
        (mode == BubbleActionMode.add ||
            (mode == BubbleActionMode.edit && _moneyAmbiguity.containsKey(si)))
        ? _amountCandidatesForSegment(si)
        : const <double>[];
    final hasMultiAmount = amountCandidates.length >= 2;
    final borderColor = _borderColorForSegment(si, sel);
    final ready = _segmentReadyForMode(si);

    String statusText;
    if (mode == BubbleActionMode.cancel) {
      statusText = ready ? 'جاهزة للإلغاء' : 'إلغاء';
    } else if (mode == BubbleActionMode.edit) {
      statusText = ready ? 'جاهزة للتعديل' : 'تعديل';
    } else if (ready) {
      statusText = 'جاهزة';
    } else {
      final missing = <String>[
        if (nameText.trim().isEmpty) 'الاسم',
        if (amountVal == null) 'المبلغ',
        if (currencyText == null) 'العملة',
      ];
      statusText = missing.isEmpty
          ? 'غير مكتملة'
          : 'ينقص: ${missing.join('، ')}';
    }

    final pad = _prefs.compact ? 10.0 : 14.0;
    final gap = _prefs.compact ? 6.0 : 8.0;

    return Container(
      margin: EdgeInsets.only(bottom: _prefs.compact ? 8 : 12),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceContainer : cs.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: borderColor.withValues(alpha: ready ? .9 : .5),
          width: ready ? 2 : 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .25 : .06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(height: 4, color: borderColor),
            Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCardHeader(
                    context,
                    si,
                    statusText: statusText,
                    statusColor: ready ? _chipGreen : borderColor,
                  ),
                  SizedBox(height: gap),
                  Row(
                    children: [
                      Expanded(child: _buildModeSwitch(si)),
                      if (_needsTarget(si) &&
                          _cancelCandidatesLoading.contains(si))
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        ),
                    ],
                  ),
                  _buildCompanyMovementSwitch(si),
                  if (_prefs.showQuickActions)
                    _buildBubbleQuickActions(context, si),
                  if (sel.forbiddenPhrases.isNotEmpty)
                    _buildForbiddenBanner(context, sel),
                  SizedBox(height: gap + 2),
                  _buildRolePills(
                    context,
                    si,
                    mode: mode,
                    nameText: nameText,
                    amountVal: amountVal,
                    currencyText: currencyText,
                  ),
                  SizedBox(height: gap),
                  _buildStageHint(context, si, sel, borderColor),
                  if (nameText.trim().isEmpty && sel.nameCandidates.isNotEmpty)
                    _buildNameSuggestions(context, si, sel),
                  if (mode != BubbleActionMode.cancel && hasMultiAmount)
                    _buildMultiAmountBox(
                      context,
                      si,
                      wasSaved: wasSaved,
                      amountVal: amountVal,
                      nameText: nameText,
                      amountCandidates: amountCandidates,
                    ),
                  if (mode == BubbleActionMode.add &&
                      _amountConflict.contains(si)) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Chip(
                          label: const Text("تعارض في المبلغ (رقم/نص)"),
                          avatar: const Icon(
                            Icons.warning_amber,
                            color: Colors.red,
                          ),
                          backgroundColor: Colors.red.withValues(alpha: .1),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _openAmountConflictDialog(si),
                          icon: const Icon(Icons.rule),
                          label: const Text("مراجعة"),
                        ),
                      ],
                    ),
                  ],
                  SizedBox(height: gap + 2),

                  // النص — فقاعات كلمات
                  ...List.generate(seg.lines.length, (li) {
                    final tokens = _tokensFromLine(seg.lines[li]);
                    if (tokens.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: EdgeInsets.only(bottom: gap),
                      child: Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: List.generate(tokens.length, (ti) {
                          return _buildTokenChip(
                            context: context,
                            segIndex: si,
                            lineIndex: li,
                            tokenIndex: ti,
                            token: tokens[ti],
                            tokensThisLine: tokens,
                          );
                        }),
                      ),
                    );
                  }),

                  if (mode == BubbleActionMode.cancel)
                    _buildCancelCandidatesPanel(context, si),

                  // اختيار العملة من القائمة
                  if (mode != BubbleActionMode.cancel &&
                      (sel.stage == SelectionStage.currency ||
                          sel.stage == SelectionStage.done))
                    _buildCurrencyPickerRow(context, si),

                  // التعديل: البحث عن الحركة واختيار ما يُعدَّل
                  if (mode == BubbleActionMode.edit)
                    _buildEditPanel(context, si),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final addReadyCount = _readyAddCount();
    final cancelReadyCount = _readyCancelCount();
    final editReadyCount = _readyEditCount();

    // اعرض نمطًا واحدًا في كل مرة (وغير المكتمل أولًا إن كان مفعّلًا)
    final analyzed = _selections.length;
    final order = <int>[
      for (var i = 0; i < analyzed; i++)
        if (_modeOf(i) == _viewMode) i,
    ];
    if (_prefs.incompleteFirst) {
      final readyCache = <int, bool>{
        for (final i in order) i: _segmentReadyForMode(i),
      };
      order.sort((a, b) {
        final ra = readyCache[a]!;
        final rb = readyCache[b]!;
        if (ra == rb) return a.compareTo(b);
        return ra ? 1 : -1;
      });
    }

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accountStart = _isCompanyAccount
        ? const Color(0xFF5E35B1)
        : _gradStart;
    final accountEnd = _isCompanyAccount ? const Color(0xFF00897B) : _gradEnd;

    final canSendAdd =
        !_busy && addReadyCount > 0 && !_hasUnresolvedConflicts();
    final canSendCancel = !_busy && cancelReadyCount > 0;
    final canSendEdit = !_busy && editReadyCount > 0;
    final showEdit = _segmentCountForMode(BubbleActionMode.edit) > 0;
    final showTrailing = order.isEmpty || _analyzing;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        // لا نسمح بالخروج أثناء الحفظ حتى لا تنقطع العملية في منتصفها
        canPop: !_isSending,
        child: Scaffold(
          backgroundColor: _isCompanyAccount
              ? (isDark ? const Color(0xFF181522) : const Color(0xFFF8F5FF))
              : null,
          appBar: AppBar(
            title: Text(
              _isCompanyAccount ? 'تحليل حركات الشركة' : 'تحليل حركات المكتب',
            ),
            centerTitle: true,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                tooltip: 'سجل العمليات',
                icon: const Icon(Icons.history_rounded),
                onPressed: _busy ? null : _openOperationsLog,
              ),
              IconButton(
                tooltip: 'تخصيص الفقاعات والإعدادات',
                icon: const Icon(Icons.tune_rounded),
                onPressed: _busy ? null : _openBubbleSettings,
              ),
            ],
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
                color: cs.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OperationProgressBar(
                    progress: _progress,
                    padding: const EdgeInsets.only(bottom: 8),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _sendButton(
                          mode: BubbleActionMode.add,
                          enabled: canSendAdd,
                          icon: Icons.add_task_rounded,
                          label: showEdit
                              ? 'الإضافات ($addReadyCount)'
                              : 'تنفيذ الإضافات ($addReadyCount)',
                          color: _chipGreen,
                          compact: showEdit,
                        ),
                      ),
                      if (showEdit) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: _sendButton(
                            mode: BubbleActionMode.edit,
                            enabled: canSendEdit,
                            icon: Icons.edit_note_rounded,
                            label: 'التعديلات ($editReadyCount)',
                            color: _chipEdit,
                            compact: true,
                          ),
                        ),
                      ],
                      SizedBox(width: showEdit ? 8 : 10),
                      Expanded(
                        child: _sendButton(
                          mode: BubbleActionMode.cancel,
                          enabled: canSendCancel,
                          icon: Icons.cancel_schedule_send_rounded,
                          label: showEdit
                              ? 'الإلغاء ($cancelReadyCount)'
                              : 'تنفيذ الإلغاء ($cancelReadyCount)',
                          color: _chipRed,
                          compact: showEdit,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          body: ScrollEdgeButtons(
            controller: _listScroll,
            child: ListView.builder(
              controller: _listScroll,
              // مساحة في الأسفل حتى لا يغطي زرّا الصعود/النزول آخر فقاعة
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 112),
              itemCount: order.length + 1 + (showTrailing ? 1 : 0),
              itemBuilder: (context, idx) {
                if (idx == 0) {
                  return _buildBubbleScreenHeader(
                    context,
                    addReadyCount: addReadyCount,
                    editReadyCount: editReadyCount,
                    cancelReadyCount: cancelReadyCount,
                  );
                }
                final k = idx - 1;
                if (k < order.length) {
                  return _buildSegmentCard(context, order[k]);
                }

                if (_analyzing) {
                  return _inlineInfoBox(
                    context,
                    icon: Icons.hourglass_top_rounded,
                    color: cs.primary,
                    text:
                        'جارٍ تحليل ${_segments.length - _selections.length} رسالة متبقية... يمكنك البدء بالفقاعات الظاهرة.',
                  );
                }
                return _inlineInfoBox(
                  context,
                  icon: _viewMode == BubbleActionMode.add
                      ? Icons.add_circle_outline_rounded
                      : (_viewMode == BubbleActionMode.edit
                            ? Icons.edit_note_rounded
                            : Icons.cancel_outlined),
                  color: _viewMode == BubbleActionMode.add
                      ? _chipGreen
                      : (_viewMode == BubbleActionMode.edit
                            ? _chipEdit
                            : _chipRed),
                  text: _viewMode == BubbleActionMode.add
                      ? 'لا توجد فقاعات إضافة في هذا النص.'
                      : (_viewMode == BubbleActionMode.edit
                            ? 'لا توجد فقاعات تعديل في هذا النص.'
                            : 'لا توجد فقاعات إلغاء في هذا النص.'),
                );
              },
            ),
          ),
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

  /// رسائل التعديل: كلمات الاسم الجديد (الاسم الحالي [nameTokens] للبحث)
  final Set<_TokPos> newNameTokens = {};
  _TokPos? amount; // رقم
  _TokPos? currencyToken; // عملة من النص
  String? currencyFromMenu; // اسم عملة من القائمة
  String? currencyDetectedName; // اسم العملة المكتشفة من النص

  // عملة من أكثر من كلمة («ليرة سورية»): باقي كلماتها بعد [currencyToken].
  // تُحسب فقط ما دام [currencyToken] هو نفس بداية العبارة
  _TokPos? currencyPhraseStart;
  final Set<_TokPos> currencyPhraseTokens = {};

  final Set<_TokPos> phoneLikeTokens = {};
  final Set<_TokPos> amountTextLockedTokens = {};

  // اقتراحات الاسم من الكاشف (تظهر عندما لا يُحسم الاسم)
  List<nd.NameLineCandidate> nameCandidates = const [];
  bool nameAmbiguous = false;
  String? nameReason;

  // الكلمات/الجمل الممنوعة داخل الرسالة
  final Set<_TokPos> forbiddenTokens = {};
  final Set<_TokPos> forbiddenPhraseTokens = {};
  final List<String> forbiddenPhrases = [];

  _SegmentSelection({required this.stage});

  /// هل الكلمة جزء من العملة المختارة (أول كلمة أو باقي كلمات العبارة)؟
  bool isCurrencyAt(_TokPos pos) {
    final c = currencyToken;
    if (c == null) return false;
    if (c == pos) return true;
    return currencyPhraseStart == c && currencyPhraseTokens.contains(pos);
  }
}

/// عملة مكتوبة في سطر معيّن (قد تكون من أكثر من كلمة)
class _LineCurrency {
  final _TokPos start;
  final Set<_TokPos> extra;
  final String name;

  const _LineCurrency({
    required this.start,
    required this.extra,
    required this.name,
  });
}

/// مبلغ مرشح في رسالة بأكثر من عملة، مع العملة المكتوبة في سطره (إن وُجدت)
class _AmountOption {
  final double value;
  final _LineCurrency? currency;

  /// مكان المبلغ في الرسالة (لترتيب المبلغ الأول ثم الثاني)
  final _TokPos? pos;

  const _AmountOption({required this.value, this.currency, this.pos});
}

/// تعارض في مبلغ الرسالة: أكثر من مبلغ وأكثر من عملة، أو مبلغان مختلفان،
/// أو المبلغ بالحروف غير المبلغ بالأرقام
class _MoneyAmbiguity {
  final List<_AmountOption> options;
  final List<String> currencies;

  /// أكثر من مبلغ وأكثر من عملة
  final bool multiCurrency;

  /// المبلغ بالأرقام والمبلغ المكتوب بالحروف (عند اختلافهما)
  final ({double digits, double words})? mismatch;

  /// المبالغ المختلفة الأكيدة في الرسالة (للتحذير)
  final List<double> strongValues;

  /// اعتُمد المبلغ الأرجح تلقائيًا (الإعدادات: بدون تأكيد) ولم يغيّره المستخدم
  bool autoPicked;

  /// اعتُمد المبلغان معًا تلقائيًا (المبلغ + المبلغ الثاني بعملتيهما)
  bool autoBoth = false;

  _MoneyAmbiguity({
    required this.options,
    required this.currencies,
    this.multiCurrency = false,
    this.mismatch,
    this.strongValues = const [],
    this.autoPicked = false,
  });

  _AmountOption? optionFor(double value) {
    for (final o in options) {
      if ((o.value - value).abs() < 0.0001) return o;
    }
    return null;
  }

  /// أول مبلغين مختلفين حسب مكانهما في الرسالة (المبلغ ثم المبلغ الثاني)
  (_AmountOption, _AmountOption)? get firstPair {
    if (options.length < 2) return null;
    final sorted = List<_AmountOption>.of(options)
      ..sort((a, b) {
        final pa = a.pos, pb = b.pos;
        if (pa == null || pb == null) return 0;
        if (pa.line != pb.line) return pa.line.compareTo(pb.line);
        return pa.index.compareTo(pb.index);
      });
    return (sorted[0], sorted[1]);
  }

  /// المبلغان بعملتين مختلفتين معروفتين (يصلحان كمبلغ + مبلغ ثاني)
  bool get pairHasTwoCurrencies {
    final p = firstPair;
    if (p == null) return false;
    final a = p.$1.currency?.name, b = p.$2.currency?.name;
    return a != null && b != null && a != b;
  }
}

class _SavedAddSummary {
  final int transactionId;
  final String name;
  final double amount;
  final String currency;
  final double? secondAmount;
  final String? secondCurrency;
  final CompanyMovementType? companyMovementType;
  final DateTime date;

  const _SavedAddSummary({
    required this.transactionId,
    required this.name,
    required this.amount,
    required this.currency,
    this.secondAmount,
    this.secondCurrency,
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
  final double? secondAmount;
  final String? secondCurrency;
  final CompanyMovementType? companyMovementType;
  final DateTime date;

  const _PendingTxDraft({
    required this.segIndex,
    required this.beneficiary,
    required this.amount,
    required this.currency,
    this.secondAmount,
    this.secondCurrency,
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

class _PendingEditDraft {
  final int segIndex;
  final TransactionModel transaction;
  final List<em.EditProposal> proposals;
  final Set<em.EditField> fields;
  final String? name;
  final double? amount;
  final String? currency;

  const _PendingEditDraft({
    required this.segIndex,
    required this.transaction,
    required this.proposals,
    required this.fields,
    this.name,
    this.amount,
    this.currency,
  });
}

/// نتيجة بحث عن حركة لرسالة إلغاء/تعديل
class _TargetHit {
  final TransactionModel tx;
  final double score;

  /// الاسم يطابق اسم الحركة (الحالي أو السابق) تمامًا
  final bool exact;

  /// تطابقت مع اسم سابق للحركة من سجل التعديل (وليس اسمها الحالي)
  final String? pastName;

  const _TargetHit({
    required this.tx,
    required this.score,
    required this.exact,
    this.pastName,
  });
}

/// اسم حركة (حالي أو سابق) مطبّع ومقسّم إلى كلمات
class _NameEntry {
  final TransactionModel tx;
  final String norm;
  final List<String> words;
  final String? pastName;

  const _NameEntry(this.tx, this.norm, this.words, this.pastName);
}

/// فهرس أسماء الحركات: مطابقة تامة فورية، والمتشابهة تُفحص فقط للحركات التي
/// تشترك بكلمة قريبة من كلمات الاسم (بدل مقارنة كل الحركات)
class _TargetSearchIndex {
  final List<_NameEntry> entries;
  final Map<String, List<int>> _exact = {};
  final Map<String, List<int>> _byWord = {};
  final Map<String, List<String>> _similarCache = {};

  _TargetSearchIndex(this.entries) {
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      (_exact[e.norm] ??= <int>[]).add(i);
      for (final w in e.words.toSet()) {
        (_byWord[w] ??= <int>[]).add(i);
      }
    }
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);
    for (var i = 0; i < a.length; i++) {
      curr[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        var v = curr[j] + 1;
        if (prev[j + 1] + 1 < v) v = prev[j + 1] + 1;
        if (prev[j] + cost < v) v = prev[j] + cost;
        curr[j + 1] = v;
      }
      final t = prev;
      prev = curr;
      curr = t;
    }
    return prev[b.length];
  }

  /// نفس قواعد التشابه السابقة: كلمة قصيرة (أقل من 3 أحرف) تطابق تمامًا فقط
  static bool similarWord(String a, String b) {
    if (a == b) return true;
    final minLen = a.length < b.length ? a.length : b.length;
    if (minLen < 3) return false;
    final maxDistance = minLen >= 7 ? 2 : 1;
    if ((a.length - b.length).abs() > maxDistance) return false;
    return _levenshtein(a, b) <= maxDistance;
  }

  List<String> _similarWords(String w) => _similarCache[w] ??= [
    for (final v in _byWord.keys)
      if (similarWord(w, v)) v,
  ];

  static double _score(String wanted, List<String> wantedWords, _NameEntry e) {
    if (e.norm == wanted) return 1;
    final candidateWords = e.words;
    if (wantedWords.isEmpty || candidateWords.isEmpty) return -1;
    if (candidateWords.length < (wantedWords.length >= 3 ? 2 : 1)) return -1;
    if ((candidateWords.length - wantedWords.length).abs() > 1) return -1;
    final used = <int>{};
    var matches = 0;
    for (final w in wantedWords) {
      for (var i = 0; i < candidateWords.length; i++) {
        if (used.contains(i)) continue;
        if (similarWord(w, candidateWords[i])) {
          used.add(i);
          matches++;
          break;
        }
      }
    }
    final required = wantedWords.length <= 2
        ? wantedWords.length
        : wantedWords.length - 1;
    if (matches < required) return -1;
    return matches / wantedWords.length;
  }

  /// كل الحركات المطابقة للاسم (أفضل نتيجة لكل حركة)
  List<_TargetHit> search(String wanted, List<String> wantedWords) {
    final best = <int, _TargetHit>{};
    void consider(int i, double score) {
      final e = entries[i];
      final hit = _TargetHit(
        tx: e.tx,
        score: score,
        exact: e.norm == wanted,
        pastName: e.pastName,
      );
      final prev = best[e.tx.id];
      if (prev == null ||
          hit.score > prev.score ||
          (hit.score == prev.score &&
              prev.pastName != null &&
              hit.pastName == null)) {
        best[e.tx.id] = hit;
      }
    }

    if (wanted.isEmpty) return const [];
    for (final i in _exact[wanted] ?? const <int>[]) {
      consider(i, 1);
    }
    // كم كلمة من كلمات الاسم تشبه كلمة في كل حركة: تُفحص بالتفصيل فقط
    // الحركات التي فيها العدد المطلوب من الكلمات المتشابهة
    final unique = wantedWords.toSet().toList();
    final counts = <int, int>{};
    for (final w in unique) {
      final seen = <int>{};
      for (final v in _similarWords(w)) {
        for (final i in _byWord[v]!) {
          if (seen.add(i)) counts[i] = (counts[i] ?? 0) + 1;
        }
      }
    }
    final required = unique.length <= 2 ? unique.length : unique.length - 1;
    counts.forEach((i, n) {
      if (n < required || entries[i].norm == wanted) return;
      final s = _score(wanted, wantedWords, entries[i]);
      if (s >= 0) consider(i, s);
    });
    return best.values.toList();
  }
}

/// ملخص فقاعة تعديل بعد تنفيذها
class _EditedSummary {
  final String name;
  final List<String> lines;
  final DateTime date;

  const _EditedSummary({
    required this.name,
    required this.lines,
    required this.date,
  });
}

/// نافذة كتابة اسم البحث عن الحركة المراد تعديلها (تملك المتحكم وتتخلص منه
/// بعد إغلاق النافذة بالكامل)
class _EditSearchDialog extends StatefulWidget {
  final String initial;

  const _EditSearchDialog({required this.initial});

  @override
  State<_EditSearchDialog> createState() => _EditSearchDialogState();
}

class _EditSearchDialogState extends State<_EditSearchDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('البحث عن الحركة المراد تعديلها'),
        content: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            hintText: 'اكتب اسم صاحب الحركة...',
            prefixIcon: Icon(Icons.search_rounded),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(onPressed: _submit, child: const Text('بحث')),
        ],
      ),
    );
  }
}

class _DuplicateWarningItem {
  final _PendingTxDraft draft;
  final List<TransactionModel> exactCritical;
  final List<TransactionModel> sameNameAmountCurrency;
  final List<TransactionModel> sameNameOnly;

  /// حركات أخرى داخل نفس النص بنفس الاسم والمبلغ والعملة
  final List<_PendingTxDraft> batchDuplicates;

  const _DuplicateWarningItem({
    required this.draft,
    required this.exactCritical,
    required this.sameNameAmountCurrency,
    required this.sameNameOnly,
    required this.batchDuplicates,
  });

  bool get hasAny =>
      exactCritical.isNotEmpty ||
      sameNameAmountCurrency.isNotEmpty ||
      sameNameOnly.isNotEmpty ||
      batchDuplicates.isNotEmpty;
}
