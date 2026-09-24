// lib/screens/verify_receive_screen.dart
// صفحة التسليم (مطابقة واستلام): تستخرج الاسم والمبلغ والعملة من كل رسالة
// (مع تجاهل أرقام الهواتف والتواريخ والأوقات والأكواد)، ثم تطابقها مع الحركات
// المضافة وتنفّذ التسليم مع تسجيل العملية في سجل العمليات.

import 'dart:math' show Point;
import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database_service.dart';
import '../models.dart';

// كواشف (كما عندك)
import '../services/detection/name_detector.dart' as nd;
import '../services/detection/amount_detector.dart' as ad;
import '../services/detection/text_tokens.dart' as tt;
import '../services/detection/message_noise.dart';
import '../services/detection/receipt_extractor.dart';
import '../services/operation_log_service.dart';
import '../utils/chunked_task.dart';
import '../widgets/operation_progress_bar.dart';

class VerifyReceiveScreen extends StatefulWidget {
  final Account account;
  final String rawText;

  const VerifyReceiveScreen({
    super.key,
    required this.account,
    required this.rawText,
  });

  @override
  State<VerifyReceiveScreen> createState() => _VerifyReceiveScreenState();
}

class _VerifyReceiveScreenState extends State<VerifyReceiveScreen> {
  // الإعدادات
  late Settings _settings;
  late List<String> _nameKeywords;
  late List<String> _amountKeywords;
  late Map<String, String> _currencyMap;

  late final List<_ParsedSegment> _segments;
  final List<_BubbleState> _bubbles = [];
  // فقاعات مستبعدة: تُحفظ فقط للتخلص من متحكماتها عند إغلاق الصفحة
  final List<_BubbleState> _removedBubbles = [];

  // الحركات (المضافة فقط كبداية للترشيح)
  late List<TransactionModel> _addedOnly;
  late _PendingIndex _pending;
  late final ReceiptExtractor _extractor;

  // تحليل الرسائل يتم على دفعات مع شريط تقدم حتى لا تتجمد الواجهة
  bool _building = true;
  final ValueNotifier<OperationProgress?> _progress =
      ValueNotifier<OperationProgress?>(null);

  // أخطاء التنفيذ
  final List<_ExecError> _lastErrors = [];
  final Map<int, String> _lastErrorByTxId = {};

  // حالة واجهة فقط — لا تغيّر منطق المطابقة أو التنفيذ
  _BubbleFilter _bubbleFilter = _BubbleFilter.all;
  _BubbleSort _bubbleSort = _BubbleSort.original;
  bool _compactMode = false;
  bool _showMessagePanel = true;
  bool _showSimilarCandidates = true;
  bool _showCompactTopDock = false;

  @override
  void initState() {
    super.initState();

    _settings =
        DatabaseService.getSettings() ??
        Settings(
          nameKeywords: ['المستفيد', 'إلى', 'ل', 'لـ'],
          amountKeywords: ['المبلغ', 'قيمة', 'amount', r'$'],
          currencyMap: {r'$': 'دولار'},
          ignoredWords: [],
        );
    _nameKeywords = List.of(_settings.nameKeywords);
    _amountKeywords = List.of(_settings.amountKeywords);
    _currencyMap = Map.of(_settings.currencyMap);

    _segments = _splitByHeader(widget.rawText);

    final all = DatabaseService.getTransactionsForAccount(widget.account.id);
    _addedOnly = all.where((t) => t.status == TransactionStatus.added).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    _pending = _PendingIndex(_addedOnly);

    _extractor = ReceiptExtractor(
      nameConfig: _nameConfig,
      currencyMap: _currencyMap,
      amountKeywords: _amountKeywords,
      ignoredWords: _settings.ignoredWords,
      customWordValues: _settings.amountWordValues,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _buildBubbles());
  }

  Future<void> _buildBubbles() async {
    const label = 'جارٍ تحليل الرسائل';
    try {
      await runTimeSliced(
        total: _segments.length,
        work: (i) {
          _BubbleState st;
          try {
            st = _buildInitialState(_segments[i], i);
          } catch (e) {
            // رسالة غير متوقعة: نعرضها بدون استخراج بدل تعطيل الصفحة كلها
            debugPrint('VerifyReceiveScreen extract error: $e');
            st = _BubbleState(segment: _segments[i], index: i);
          }
          // تُضاف كل فقاعة فور بنائها حتى يعمل منع تكرار نفس الحركة بين الفقاعات
          _bubbles.add(st);
        },
        onProgress: (done, total) {
          _progress.value = OperationProgress(
            label: label,
            done: done,
            total: total,
          );
        },
        isCancelled: () => !mounted,
      );
    } finally {
      if (mounted) {
        _progress.value = null;
        setState(() => _building = false);
      }
    }
  }

  @override
  void dispose() {
    for (final b in [..._bubbles, ..._removedBubbles]) {
      b.dispose();
    }
    _progress.dispose();
    super.dispose();
  }

  // ====== تقسيم الهيدر ======
  final _headerRe = RegExp(
    r'\[\s*([0-9\u0660-\u0669]{1,2})\/[\u200F\u200E]?\s*([0-9\u0660-\u0669]{1,2})\s*[,،]\s*([0-9\u0660-\u0669]{1,2})\s*:\s*([0-9\u0660-\u0669]{2})\s*\]\s*([^:\n]+?)\s*:',
    multiLine: true,
  );

  List<_ParsedSegment> _splitByHeader(String input) {
    final text = input.replaceAll('\r', '');
    final matches = _headerRe.allMatches(text).toList();
    final segments = <_ParsedSegment>[];

    if (matches.isEmpty) {
      final lines = text.split('\n').map((e) => e.trimRight()).toList();
      segments.add(
        _ParsedSegment(
          header: 'بدون هيدر',
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
        _ParsedSegment(
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

  String _formatSegmentTime(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d/$m • $h:$mm';
  }

  List<String> _currencyWordsFromSettings() {
    return {
      ..._settings.currencyMap.keys,
      ..._settings.currencyMap.values,
    }.where((e) => e.trim().isNotEmpty).toList();
  }

  String _formatAmount(double v) {
    final isInt = v == v.roundToDouble();
    return isInt ? v.toInt().toString() : v.toStringAsFixed(2);
  }

  String _formatAmountList(List<double> values) {
    if (values.isEmpty) return '';
    return values
        .map((e) {
          final isInt = e == e.roundToDouble();
          return isInt ? e.toInt().toString() : e.toStringAsFixed(2);
        })
        .join(' ، ');
  }

  String _formatTxDateTime(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year.toString();
    final h = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d/$m/$y • $h:$mm';
  }

  int? _selectedIdOf(_BubbleState st) {
    if (st.selectedTxIds.isEmpty) return null;
    return st.selectedTxIds.first;
  }

  bool _isTxSelectedInAnotherBubble(_BubbleState current, int txId) {
    for (final b in _bubbles) {
      if (identical(b, current)) continue;
      if (b.selectedTxIds.contains(txId)) return true;
    }
    return false;
  }

  void _selectSingleCandidate(_BubbleState st, int txId) {
    if (st.isReadOnly) {
      _showSnack(
        icon: Icons.lock_outline,
        text:
            'هذه الفقاعة أصبحت للقراءة فقط بعد التنفيذ، لا يمكن اختيار نتائج منها.',
        color: Theme.of(context).colorScheme.error,
      );
      return;
    }

    if (_isTxSelectedInAnotherBubble(st, txId)) {
      _showSnack(
        icon: Icons.lock_outline,
        text: 'هذه الحركة محددة بالفعل في فقاعة أخرى، لا يمكن تحديدها هنا.',
        color: Theme.of(context).colorScheme.error,
      );
      return;
    }

    st.selectedTxIds
      ..clear()
      ..add(txId);

    _recomputeWarningsAndReady(st);
    setState(() {});
  }

  void _clearSelectedCandidate(_BubbleState st, int txId) {
    if (st.isReadOnly) return;

    st.selectedTxIds.remove(txId);
    _recomputeWarningsAndReady(st);
    setState(() {});
  }

  // ====== الحالة الأولى لكل فقاعة ======
  // إعدادات كاشف الاسم تُجهّز مرة واحدة لكل الرسائل (بدل إعادة فرز كل
  // الحركات وبناء فهرس الأسماء لكل رسالة، وهو ما كان يسبب التجمّد)
  nd.NameDetectorConfig? _nameConfigCache;
  nd.NameDetectorConfig get _nameConfig =>
      _nameConfigCache ??= nd.NameDetectorConfig(
        nameKeywords: _nameKeywords,
        knownNames: DatabaseService.transactionsBox.values
            .where((t) => t.accountId == widget.account.id)
            .map((t) => t.beneficiary)
            .where((s) => s.trim().isNotEmpty)
            .toSet()
            .toList(),
        ignoredWords: _settings.ignoredWords,
        lineIgnoredWords: _settings.lineIgnoredWords,
        currencyWords: _currencyWordsFromSettings(),
        forbiddenWords: _settings.forbiddenWords,
        forbiddenPhrases: _settings.forbiddenPhrases,
        amountKeywords: _amountKeywords,
        cancelKeywords: _settings.cancelKeywords,
      );

  _BubbleState _buildInitialState(_ParsedSegment seg, int segIndex) {
    final st = _BubbleState(segment: seg, index: segIndex);
    final ex = _extractor.extract(seg.lines, senderName: seg.senderName);
    st.extraction = ex;

    for (int li = 0; li < ex.lines.length; li++) {
      ex.lines[li].marks.forEach((ti, m) {
        st.noiseTokens[_TokPos(li, ti)] = m;
      });
    }

    st.nameTokens.addAll(_tokMapToSet(ex.nameTokensByLine));
    st.detectedName = ex.name;

    st.currencyPos = ex.currencyPos;
    st.currencyKey = ex.currencyKey;

    st.detectedAmount = ex.amount;
    st.amount = ex.amount;
    st.detectedAmountTokens = {
      for (final p in ex.amountTokens) _TokPos(p.x, p.y),
    };
    st.amountHasConflict = ex.amountHasConflict;
    st.amountHasMultipleCandidates = ex.amountHasMultipleCandidates;
    st.amountCandidateValues = List<double>.from(ex.amountCandidates);
    st.amountFromSuspect = ex.amountFromSuspect;

    _refreshCandidates(st);
    return st;
  }

  Set<_TokPos> _tokMapToSet(Map<int, List<int>> map) {
    final s = <_TokPos>{};
    map.forEach((li, idxs) {
      for (final ti in idxs) {
        s.add(_TokPos(li, ti));
      }
    });
    return s;
  }

  /// الاسم الفعلي للفقاعة (اليدوي أولًا ثم المكتشف)
  String _effectiveName(_BubbleState st) {
    final manual = st.manualName?.trim() ?? '';
    if (manual.isNotEmpty) return manual;
    return st.detectedName?.trim() ?? '';
  }

  /// هل [needle] يظهر كتسلسل متصل داخل [hay]؟
  static bool _containsSeq(List<String> hay, List<String> needle) {
    if (needle.isEmpty || needle.length > hay.length) return false;
    for (int i = 0; i + needle.length <= hay.length; i++) {
      var ok = true;
      for (int j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }

  /// العملة متوافقة إلا إذا عُرفت العملتان وكانتا مختلفتين
  bool _currencyCompatible(TransactionModel tx, String? messageKey) {
    if (messageKey == null) return true;
    final txKey = _extractor.currencyKeyOf(tx.currency);
    if (txKey == null) return true;
    return txKey == messageKey;
  }

  String _currencyLabel(String? key) {
    if (key == null) return 'غير محددة';
    return _currencyMap[key] ?? key;
  }

  /// درجات المطابقة: 3 = الاسم مطابق تمامًا ، 2 = اسم الحركة ظاهر في الرسالة أو
  /// الاسم جزء متصل من اسم الحركة (أو العكس) ، 1 = كلمتان مشتركتان على الأقل.
  void _refreshCandidates(_BubbleState st) {
    if (st.isReadOnly) return;

    st.warningTexts.clear();
    st.ready = false;
    st.selectedTxIds.clear();
    st.candidates.clear();
    st.hasAmbiguousExactMatches = false;
    st.amountChosenByMatch = false;
    st.amount = st.manualAmount ?? st.detectedAmount;

    final name = _effectiveName(st);
    final nameKeys = tt
        .tokensFromLine(name)
        .map(tt.matchKey)
        .where((k) => k.isNotEmpty)
        .toList();

    final rankById = <int, int>{};
    final txById = <int, TransactionModel>{};
    void bump(TransactionModel tx, int rank) {
      txById[tx.id] = tx;
      if ((rankById[tx.id] ?? 0) < rank) rankById[tx.id] = rank;
    }

    if (nameKeys.isNotEmpty) {
      for (final tx in _pending.byFull[nameKeys.join(' ')] ?? const []) {
        bump(tx, 3);
      }
      final overlap = <int, int>{};
      for (final k in nameKeys.toSet()) {
        for (final tx in _pending.byToken[k] ?? const <TransactionModel>[]) {
          final keys = _pending.keysById[tx.id]!;
          if (_containsSeq(keys, nameKeys) || _containsSeq(nameKeys, keys)) {
            bump(tx, 2);
          } else {
            overlap[tx.id] = (overlap[tx.id] ?? 0) + 1;
            if (overlap[tx.id]! >= 2) bump(tx, 1);
          }
        }
      }
    }

    // اسم الحركة ظاهر حرفيًا في نص الرسالة (حتى لو لم يُكتشف الاسم)
    final ex = st.extraction;
    if (ex != null) {
      for (final line in ex.lines) {
        final keys = line.tokens.map(tt.matchKey).toList();
        for (int p = 0; p < keys.length; p++) {
          final list = _pending.byFirst[keys[p]];
          if (list == null) continue;
          for (final tx in list) {
            final txKeys = _pending.keysById[tx.id]!;
            if (p + txKeys.length > keys.length) continue;
            var ok = true;
            for (int j = 1; j < txKeys.length; j++) {
              if (keys[p + j] != txKeys[j]) {
                ok = false;
                break;
              }
            }
            if (ok) bump(tx, 2);
          }
        }
      }
    }

    const double tol = 0.0001;

    void buildCandidates() {
      st.candidates.clear();
      final hasAmount = st.amount != null;
      final amount = st.amount ?? 0.0;
      rankById.forEach((id, rank) {
        final tx = txById[id]!;
        final delta = hasAmount ? (tx.amount - amount).abs() : 0.0;
        final currencyOk = _currencyCompatible(tx, st.currencyKey);
        final exact = hasAmount && delta <= tol && rank >= 2 && currencyOk;
        st.candidates.add(
          _Candidate(
            tx: tx,
            delta: delta,
            exact: exact,
            rank: rank,
            currencyOk: currencyOk,
          ),
        );
      });
    }

    buildCandidates();

    // الرسالة فيها أكثر من رقم: نعتمد الرقم الذي يطابق حركة معلقة
    if (st.manualAmount == null &&
        !st.candidates.any((c) => c.exact) &&
        st.amountCandidateValues.length > 1) {
      for (final v in st.amountCandidateValues) {
        if (st.amount != null && (v - st.amount!).abs() <= tol) continue;
        final hit = st.candidates.any(
          (c) => c.rank >= 2 && c.currencyOk && (c.tx.amount - v).abs() <= tol,
        );
        if (hit) {
          st.amount = v;
          st.amountChosenByMatch = true;
          buildCandidates();
          break;
        }
      }
    }

    st.candidates.sort((a, b) {
      if (a.exact != b.exact) return a.exact ? -1 : 1;
      final r = b.rank.compareTo(a.rank);
      if (r != 0) return r;
      final d = a.delta.compareTo(b.delta);
      if (d != 0) return d;
      return b.tx.date.compareTo(a.tx.date);
    });

    // اختيار تلقائي فقط إذا كانت هناك مطابقة مؤكدة واحدة أفضل من غيرها
    final autoExact = st.candidates.where((c) {
      if (!c.exact) return false;
      if (c.tx.status == TransactionStatus.received) return false;
      if (_isTxSelectedInAnotherBubble(st, c.tx.id)) return false;
      return true;
    }).toList();

    if (autoExact.length == 1) {
      st.selectedTxIds.add(autoExact.first.tx.id);
    } else if (autoExact.length > 1) {
      final topRank = autoExact.first.rank;
      final top = autoExact.where((c) => c.rank == topRank).toList();
      if (top.length == 1) {
        st.selectedTxIds.add(top.first.tx.id);
      } else {
        st.hasAmbiguousExactMatches = true;
      }
    }

    _recomputeWarningsAndReady(st);
  }

  /// اعتماد اسم من الرسالة (فهارس دقيقة) — من الضغط على كلمة أو من الاقتراحات
  void _applyNameTokens(_BubbleState st, int li, List<int> idxs) {
    final ex = st.extraction;
    if (ex == null || idxs.isEmpty) return;
    final text = ReceiptExtractor.textOf(ex.lines, {li: idxs});
    if (text.isEmpty) return;
    st.manualName = text;
    st.manualNameTokens
      ..clear()
      ..addAll(idxs.map((ti) => _TokPos(li, ti)));
    st.nameController.text = text;
    _refreshCandidates(st);
    setState(() {});
  }

  void _applyManualAmount(
    _BubbleState st,
    double? value, {
    Set<_TokPos> tokens = const {},
  }) {
    st.manualAmount = (value != null && value > 0) ? value : null;
    st.manualAmountTokens
      ..clear()
      ..addAll(st.manualAmount == null ? const <_TokPos>{} : tokens);
    st.amountController.text = st.manualAmount == null
        ? ''
        : _formatAmount(st.manualAmount!);
    _refreshCandidates(st);
    setState(() {});
  }

  void _onMessageTokenTap(_BubbleState st, int li, int ti) {
    final ex = st.extraction;
    if (st.isReadOnly || ex == null || li >= ex.lines.length) return;
    final line = ex.lines[li];
    if (ti >= line.tokens.length) return;

    if (tt.tokenHasDigit(line.tokens[ti])) {
      final v = ReceiptExtractor.numberAt(line, ti);
      if (v == null || v <= 0) {
        _showSnack(
          icon: Icons.info_outline,
          text: 'هذا الرقم ليس مبلغًا صالحًا.',
        );
        return;
      }
      final mark = line.markAt(ti);
      final merged = line.mergedContaining(ti);
      _applyManualAmount(
        st,
        v,
        tokens: merged == null
            ? {_TokPos(li, ti)}
            : {for (int x = merged.start; x <= merged.end; x++) _TokPos(li, x)},
      );
      _showSnack(
        icon: Icons.payments_outlined,
        text: mark == null
            ? 'تم اعتماد المبلغ ${_formatAmount(v)} يدويًا.'
            : 'تم اعتماد ${_formatAmount(v)} كمبلغ رغم أنه يبدو ${mark.kind.label}.',
      );
      return;
    }

    final span = _extractor.spanFrom(line, ti);
    if (span.isEmpty) {
      final mark = line.markAt(ti);
      _showSnack(
        icon: Icons.info_outline,
        text: mark == null
            ? 'لا يمكن اعتماد «${line.tokens[ti]}» كاسم.'
            : 'لا يمكن اعتماد «${line.tokens[ti]}» كاسم (${mark.kind.label}).',
      );
      return;
    }
    _applyNameTokens(st, li, span);
  }

  void _recomputeWarningsAndReady(_BubbleState st) {
    st.warningTexts.clear();
    if (st.isReadOnly) {
      st.ready = false;
      st.selectedTxIds.clear();
      return;
    }
    if (st.selectedTxIds.isEmpty) st.ready = false;

    final manualAmount = st.manualAmount != null;

    if (st.amountChosenByMatch && st.amount != null) {
      st.warningTexts.add(
        'الرسالة فيها أكثر من رقم، وتم اعتماد المبلغ ${_formatAmount(st.amount!)} لأنه يطابق حركة مضافة.',
      );
    } else if (st.amountHasMultipleCandidates && !manualAmount) {
      final vals = _formatAmountList(st.amountCandidateValues);
      st.warningTexts.add(
        vals.isEmpty
            ? 'يوجد أكثر من مبلغ حقيقي داخل الرسالة، لذلك تم اختيار أفضل مرشح فقط.'
            : 'يوجد أكثر من مبلغ حقيقي داخل الرسالة: $vals',
      );
    }

    if (st.amountHasConflict && !manualAmount && !st.amountChosenByMatch) {
      st.warningTexts.add(
        'يوجد تعارض واضح بين المبلغ الرقمي والمبلغ النصي، وتم اعتماد النتيجة الأقوى من كاشف المبلغ.',
      );
    }

    if (st.amountFromSuspect && !manualAmount && !st.amountChosenByMatch) {
      st.warningTexts.add(
        'المبلغ المعتمد رقم طويل قد يكون رقم هاتف — تأكد منه أو اضغط على المبلغ الصحيح في الرسالة.',
      );
    }

    if (st.hasAmbiguousExactMatches) {
      st.warningTexts.add(
        'يوجد أكثر من تطابق مؤكد لهذه الفقاعة، لذلك لم يتم تحديد أي نتيجة تلقائيًا. اختر واحدة يدويًا.',
      );
    }

    const double tol = 0.0001;
    final toRemove = <int>[];

    for (final id in st.selectedTxIds) {
      final match = st.candidates.where((c) => c.tx.id == id);
      if (match.isEmpty) {
        toRemove.add(id);
        continue;
      }
      final tx = match.first.tx;

      if (_isTxSelectedInAnotherBubble(st, id)) {
        st.warningTexts.add(
          'هذه الحركة محددة في فقاعة أخرى، لذلك تم منع استخدامها هنا.',
        );
        toRemove.add(id);
        continue;
      }

      if (tx.status == TransactionStatus.received) {
        st.warningTexts.add(
          'الحركة "${tx.beneficiary}" مستلمة مسبقًا — لا يمكن تحديدها.',
        );
        toRemove.add(id);
      } else if (tx.status == TransactionStatus.cancelled) {
        st.warningTexts.add(
          'تنبيه: الحركة "${tx.beneficiary}" حالتها "ملغية".',
        );
      }

      if (st.amount != null && (tx.amount - st.amount!).abs() > tol) {
        st.warningTexts.add(
          'تحذير: اختلاف مبلغ مع "${tx.beneficiary}" (${_formatAmount(tx.amount)} ≠ ${_formatAmount(st.amount!)}).',
        );
      }

      if (!_currencyCompatible(tx, st.currencyKey)) {
        st.warningTexts.add(
          'تحذير: عملة الحركة "${tx.beneficiary}" (${tx.currency}) تختلف عن عملة الرسالة (${_currencyLabel(st.currencyKey)}).',
        );
      }
    }

    for (final id in toRemove) {
      st.selectedTxIds.remove(id);
    }

    st.ready = st.selectedTxIds.isNotEmpty;
  }

  // ====== عرض الفقاعات حسب الفلترة والفرز ======
  List<_BubbleState> get _visibleBubbles {
    final list = _bubbles.where(_matchesBubbleFilter).toList();

    int nullSafeDateCompare(DateTime? a, DateTime? b) {
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      return b.compareTo(a);
    }

    switch (_bubbleSort) {
      case _BubbleSort.original:
        list.sort((a, b) => a.index.compareTo(b.index));
        break;
      case _BubbleSort.latestMessage:
        list.sort(
          (a, b) =>
              nullSafeDateCompare(a.segment.timestamp, b.segment.timestamp),
        );
        break;
      case _BubbleSort.readyFirst:
        list.sort((a, b) {
          final r = (b.ready ? 1 : 0).compareTo(a.ready ? 1 : 0);
          if (r != 0) return r;
          return a.index.compareTo(b.index);
        });
        break;
      case _BubbleSort.warningFirst:
        list.sort((a, b) {
          final r = b.warningTexts.length.compareTo(a.warningTexts.length);
          if (r != 0) return r;
          return a.index.compareTo(b.index);
        });
        break;
      case _BubbleSort.mostCandidates:
        list.sort((a, b) {
          final r = b.candidates.length.compareTo(a.candidates.length);
          if (r != 0) return r;
          return a.index.compareTo(b.index);
        });
        break;
      case _BubbleSort.readOnlyLast:
        list.sort((a, b) {
          final r = (a.isReadOnly ? 1 : 0).compareTo(b.isReadOnly ? 1 : 0);
          if (r != 0) return r;
          return a.index.compareTo(b.index);
        });
        break;
    }
    return list;
  }

  bool _matchesBubbleFilter(_BubbleState b) {
    switch (_bubbleFilter) {
      case _BubbleFilter.all:
        return true;
      case _BubbleFilter.ready:
        return !b.isReadOnly && b.ready;
      case _BubbleFilter.needsReview:
        return !b.isReadOnly && !b.ready;
      case _BubbleFilter.selected:
        return !b.isReadOnly && b.selectedTxIds.isNotEmpty;
      case _BubbleFilter.hasCandidates:
        return !b.isReadOnly && b.candidates.isNotEmpty;
      case _BubbleFilter.warnings:
        return b.warningTexts.isNotEmpty;
      case _BubbleFilter.readOnly:
        return b.isReadOnly;
    }
  }

  int get _selectedCount =>
      _bubbles.fold<int>(0, (p, b) => p + b.selectedTxIds.length);
  int get _readyCount => _bubbles.where((b) => !b.isReadOnly && b.ready).length;
  int get _warningCount =>
      _bubbles.where((b) => b.warningTexts.isNotEmpty).length;
  int get _readOnlyCount => _bubbles.where((b) => b.isReadOnly).length;

  String _filterLabel(_BubbleFilter f) {
    switch (f) {
      case _BubbleFilter.all:
        return 'الكل';
      case _BubbleFilter.ready:
        return 'جاهزة';
      case _BubbleFilter.needsReview:
        return 'تحتاج مراجعة';
      case _BubbleFilter.selected:
        return 'مختارة';
      case _BubbleFilter.hasCandidates:
        return 'لها نتائج';
      case _BubbleFilter.warnings:
        return 'تحذيرات';
      case _BubbleFilter.readOnly:
        return 'قراءة فقط';
    }
  }

  IconData _filterIcon(_BubbleFilter f) {
    switch (f) {
      case _BubbleFilter.all:
        return Icons.all_inbox_outlined;
      case _BubbleFilter.ready:
        return Icons.check_circle_outline;
      case _BubbleFilter.needsReview:
        return Icons.manage_search_outlined;
      case _BubbleFilter.selected:
        return Icons.radio_button_checked;
      case _BubbleFilter.hasCandidates:
        return Icons.fact_check_outlined;
      case _BubbleFilter.warnings:
        return Icons.warning_amber_rounded;
      case _BubbleFilter.readOnly:
        return Icons.lock_outline;
    }
  }

  String _sortLabel(_BubbleSort s) {
    switch (s) {
      case _BubbleSort.original:
        return 'الترتيب الأصلي';
      case _BubbleSort.latestMessage:
        return 'الأحدث أولاً';
      case _BubbleSort.readyFirst:
        return 'الجاهزة أولاً';
      case _BubbleSort.warningFirst:
        return 'التحذيرات أولاً';
      case _BubbleSort.mostCandidates:
        return 'الأكثر نتائج';
      case _BubbleSort.readOnlyLast:
        return 'المنفذة أخيراً';
    }
  }

  Color _bubbleAccent(_BubbleState st, ColorScheme cs) {
    if (st.isReadOnly) return cs.primary;
    if (st.warningTexts.isNotEmpty) return cs.error;
    if (st.ready) return Colors.green.shade600;
    if (st.candidates.isNotEmpty) return Colors.orange.shade700;
    return cs.outline;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visible = _visibleBubbles;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          elevation: 0,
          titleSpacing: 16,
          title: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withOpacity(.7),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.verified_user_outlined,
                  color: cs.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'مطابقة واستلام',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      widget.account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            Tooltip(
              message: _compactMode
                  ? 'إظهار العرض المريح'
                  : 'تفعيل العرض المختصر',
              child: IconButton(
                onPressed: () => setState(() => _compactMode = !_compactMode),
                icon: Icon(
                  _compactMode
                      ? Icons.view_agenda_outlined
                      : Icons.view_compact_alt_outlined,
                ),
              ),
            ),
            Tooltip(
              message: _showMessagePanel
                  ? 'إخفاء نص الرسائل'
                  : 'إظهار نص الرسائل',
              child: IconButton(
                onPressed: () =>
                    setState(() => _showMessagePanel = !_showMessagePanel),
                icon: Icon(
                  _showMessagePanel
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            _adaptiveTopChrome(visible.length),
            OperationProgressBar(
              progress: _progress,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            ),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _handleListScroll,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _building
                      ? _buildingState()
                      : visible.isEmpty
                      ? _emptyState()
                      : ListView.builder(
                          key: ValueKey(
                            '${_bubbleFilter.name}-${_bubbleSort.name}-${visible.length}-$_compactMode-$_showMessagePanel',
                          ),
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                          itemCount: visible.length,
                          itemBuilder: (context, i) =>
                              TweenAnimationBuilder<double>(
                                tween: Tween(begin: 0, end: 1),
                                duration: Duration(
                                  milliseconds: 220 + ((i < 8 ? i : 8) * 35),
                                ),
                                curve: Curves.easeOutCubic,
                                builder: (context, v, child) => Opacity(
                                  opacity: v,
                                  child: Transform.translate(
                                    offset: Offset(0, 14 * (1 - v)),
                                    child: child,
                                  ),
                                ),
                                child: _bubbleCard(visible[i]),
                              ),
                        ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: _bottomActionBar(),
      ),
    );
  }

  Widget _buildingState() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('building'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              'جارٍ تحليل ${_segments.length} رسالة واستخراج الأسماء والمبالغ...',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ====== رأس ملخّص أنيق ======

  bool _handleListScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final shouldCompact = notification.metrics.pixels > 24;
    if (shouldCompact != _showCompactTopDock && mounted) {
      setState(() => _showCompactTopDock = shouldCompact);
    }
    return false;
  }

  Widget _adaptiveTopChrome(int visibleCount) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      child: _showCompactTopDock
          ? _compactTopDock(visibleCount)
          : Column(
              key: const ValueKey('full-top-chrome'),
              children: [_topHeaderCard(), _filterSortBar(visibleCount)],
            ),
    );
  }

  Widget _compactTopDock(int visibleCount) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      key: const ValueKey('compact-top-dock'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surface.withOpacity(.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.outlineVariant.withOpacity(.55)),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withOpacity(.06),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            _compactDockButton(
              icon: Icons.dashboard_outlined,
              tooltip: 'الملخص',
              badgeText: '${_bubbles.length}',
              color: cs.primary,
              onTap: _showSummarySheet,
            ),
            const SizedBox(width: 8),
            _compactDockButton(
              icon: _filterIcon(_bubbleFilter),
              tooltip: 'الفلترة والفرز',
              badgeText: '$visibleCount',
              color: Colors.blue.shade700,
              onTap: _showFilterSortSheet,
            ),
            const SizedBox(width: 8),
            _compactDockButton(
              icon: Icons.tune_rounded,
              tooltip: 'خيارات العرض',
              badgeText: [
                if (_compactMode) 'م',
                if (_showMessagePanel) 'ر',
                if (_showSimilarCandidates) 'ش',
              ].join(' '),
              color: Colors.teal.shade700,
              onTap: _showDisplayOptionsSheet,
            ),
            const Spacer(),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: cs.primary.withOpacity(.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.keyboard_double_arrow_up_rounded,
                    size: 16,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'شريط مختصر',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactDockButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    required Color color,
    String? badgeText,
  }) {
    final cs = Theme.of(context).colorScheme;
    final hasBadge = badgeText != null && badgeText.trim().isNotEmpty;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(.18)),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 20, color: color),
                if (hasBadge)
                  PositionedDirectional(
                    top: -9,
                    end: -11,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: color.withOpacity(.35)),
                      ),
                      child: Center(
                        child: Text(
                          badgeText!,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: badgeText.length > 2 ? 9 : 10,
                            fontWeight: FontWeight.w800,
                            color: color,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSummarySheet() async {
    final cs = Theme.of(context).colorScheme;
    await _showTopDetailSheet(
      title: 'ملخص الشاشة',
      subtitle: 'إحصاءات سريعة عن كل الفقاعات والحالة الحالية.',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _metricCard(
            Icons.forum_outlined,
            'الرسائل',
            '${_bubbles.length}',
            cs.primary,
          ),
          _metricCard(
            Icons.filter_alt_outlined,
            'المعروضة',
            '${_visibleBubbles.length}',
            Colors.blue.shade700,
          ),
          _metricCard(
            Icons.radio_button_checked,
            'المختارة',
            '$_selectedCount',
            Colors.green.shade700,
          ),
          _metricCard(
            Icons.check_circle_outline,
            'الجاهزة',
            '$_readyCount',
            Colors.teal.shade700,
          ),
          _metricCard(
            Icons.lock_outline,
            'قراءة فقط',
            '$_readOnlyCount',
            cs.primary,
          ),
          _metricCard(
            Icons.warning_amber_rounded,
            'تحذيرات',
            '$_warningCount',
            cs.error,
          ),
        ],
      ),
    );
  }

  Future<void> _showFilterSortSheet() async {
    final cs = Theme.of(context).colorScheme;
    await _showTopDetailSheet(
      title: 'الفلترة والفرز',
      subtitle: 'اختر ما تريد إظهاره ورتّب الفقاعات بالطريقة الأنسب.',
      child: StatefulBuilder(
        builder: (context, setModalState) {
          void update(void Function() fn) {
            setState(fn);
            setModalState(() {});
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'الفلاتر',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _BubbleFilter.values.map((f) {
                  final selected = _bubbleFilter == f;
                  return ChoiceChip(
                    selected: selected,
                    avatar: Icon(_filterIcon(f), size: 16),
                    label: Text(_filterLabel(f)),
                    showCheckmark: false,
                    onSelected: (_) => update(() => _bubbleFilter = f),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withOpacity(.32),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.outlineVariant.withOpacity(.5)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<_BubbleSort>(
                    isExpanded: true,
                    value: _bubbleSort,
                    borderRadius: BorderRadius.circular(16),
                    onChanged: (v) {
                      if (v == null) return;
                      update(() => _bubbleSort = v);
                    },
                    items: _BubbleSort.values
                        .map(
                          (s) => DropdownMenuItem<_BubbleSort>(
                            value: s,
                            child: Text(_sortLabel(s)),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'معروض الآن: ${_visibleBubbles.length} فقاعة',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showDisplayOptionsSheet() async {
    final cs = Theme.of(context).colorScheme;
    await _showTopDetailSheet(
      title: 'خيارات العرض',
      subtitle: 'تحكم بشكل الشاشة فقط بدون المساس بأي منطق أو بيانات.',
      child: StatefulBuilder(
        builder: (context, setModalState) {
          void update(void Function() fn) {
            setState(fn);
            setModalState(() {});
          }

          return Column(
            children: [
              SwitchListTile.adaptive(
                value: _compactMode,
                onChanged: (v) => update(() => _compactMode = v),
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.view_compact_alt_outlined),
                title: const Text('الوضع المختصر'),
                subtitle: const Text(
                  'تقليل المسافات وحجم العناصر داخل الفقاعات.',
                ),
              ),
              SwitchListTile.adaptive(
                value: _showMessagePanel,
                onChanged: (v) => update(() => _showMessagePanel = v),
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.message_outlined),
                title: const Text('إظهار نص الرسائل'),
                subtitle: const Text(
                  'إظهار أو إخفاء نص الرسالة داخل كل فقاعة.',
                ),
              ),
              SwitchListTile.adaptive(
                value: _showSimilarCandidates,
                onChanged: (v) => update(() => _showSimilarCandidates = v),
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.compare_arrows_rounded),
                title: const Text('إظهار النتائج المشابهة'),
                subtitle: const Text(
                  'عرض النتائج غير المؤكدة أسفل قسم المطابقات المؤكدة.',
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.primary.withOpacity(.18)),
                ),
                child: Text(
                  'عند التمرير للأعلى يتحول الشريط العلوي تلقائياً إلى شريط مختصر من الأيقونات.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.primary),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showTopDetailSheet({
    required String title,
    required String subtitle,
    required Widget child,
  }) async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(color: cs.outlineVariant.withOpacity(.45)),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  12,
                  18,
                  18 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 5,
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: cs.outlineVariant.withOpacity(.65),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 18),
                      child,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topHeaderCard() {
    final cs = Theme.of(context).colorScheme;
    final visible = _visibleBubbles.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: cs.outlineVariant.withOpacity(.55)),
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              cs.primaryContainer.withOpacity(.55),
              cs.surfaceContainerHighest.withOpacity(.34),
              cs.surface.withOpacity(.96),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withOpacity(.06),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(.12),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: cs.primary.withOpacity(.20)),
                  ),
                  child: Icon(
                    Icons.account_balance_wallet_outlined,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'لوحة مراجعة الرسائل',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'اختر، راجع، نفّذ — وبعد التنفيذ تصبح الفقاعة للقراءة فقط.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _metricCard(
                  Icons.forum_outlined,
                  'الرسائل',
                  '${_bubbles.length}',
                  cs.primary,
                ),
                _metricCard(
                  Icons.filter_alt_outlined,
                  'المعروضة',
                  '$visible',
                  Colors.blue.shade700,
                ),
                _metricCard(
                  Icons.radio_button_checked,
                  'المختارة',
                  '$_selectedCount',
                  Colors.green.shade700,
                ),
                _metricCard(
                  Icons.check_circle_outline,
                  'الجاهزة',
                  '$_readyCount',
                  Colors.teal.shade700,
                ),
                _metricCard(
                  Icons.lock_outline,
                  'قراءة فقط',
                  '$_readOnlyCount',
                  cs.primary,
                ),
                _metricCard(
                  Icons.warning_amber_rounded,
                  'تحذيرات',
                  '$_warningCount',
                  cs.error,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricCard(IconData icon, String label, String value, Color color) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(.78),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withOpacity(.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: const TextStyle(fontWeight: FontWeight.w900, height: 1),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  height: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterSortBar(int visibleCount) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withOpacity(.30),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: cs.outlineVariant.withOpacity(.50)),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _BubbleFilter.values.map((f) {
                        final selected = _bubbleFilter == f;
                        return Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: ChoiceChip(
                            selected: selected,
                            avatar: Icon(_filterIcon(f), size: 16),
                            label: Text(_filterLabel(f)),
                            onSelected: (_) =>
                                setState(() => _bubbleFilter = f),
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: cs.outlineVariant.withOpacity(.6),
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<_BubbleSort>(
                      value: _bubbleSort,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      borderRadius: BorderRadius.circular(16),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _bubbleSort = v);
                      },
                      items: _BubbleSort.values
                          .map(
                            (s) => DropdownMenuItem<_BubbleSort>(
                              value: s,
                              child: Text(_sortLabel(s)),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.tune_rounded, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'معروض: $visibleCount • الفرز: ${_sortLabel(_bubbleSort)}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  selected: _showSimilarCandidates,
                  label: const Text('المشابهة'),
                  avatar: const Icon(Icons.compare_arrows_rounded, size: 16),
                  onSelected: (v) => setState(() => _showSimilarCandidates = v),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 6),
                FilterChip(
                  selected: _compactMode,
                  label: const Text('مختصر'),
                  avatar: const Icon(Icons.compress_rounded, size: 16),
                  onSelected: (v) => setState(() => _compactMode = v),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('empty-bubbles'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: cs.primary.withOpacity(.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.manage_search_outlined,
                size: 40,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'لا توجد فقاعات ضمن هذا الفلتر',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'جرّب تغيير الفلتر أو الفرز من الشريط العلوي.',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomActionBar() {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Container(
          decoration: BoxDecoration(
            color: cs.surface.withOpacity(.92),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: cs.outlineVariant.withOpacity(.55)),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withOpacity(.08),
                blurRadius: 26,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _onExecute,
                  icon: const Icon(Icons.done_all),
                  label: Text('تنفيذ المختارة ($_selectedCount)'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _showErrorsDialog,
                icon: const Icon(Icons.bug_report_outlined),
                label: const Text('الأخطاء'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ====== بطاقة فقاعة برسائلها وتفاصيلها ======
  Widget _bubbleCard(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;
    final accent = _bubbleAccent(st, cs);
    final selectedCount = st.selectedTxIds.length;
    final isCollapsed = _compactMode || !st.expanded;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      margin: EdgeInsets.only(bottom: _compactMode ? 8 : 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: accent.withOpacity(st.ready || st.isReadOnly ? .36 : .18),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(st.ready ? .10 : .045),
            blurRadius: st.ready ? 24 : 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            PositionedDirectional(
              top: 0,
              bottom: 0,
              start: 0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                width: 5,
                color: accent,
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                14,
                _compactMode ? 10 : 14,
                18,
                _compactMode ? 10 : 14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => setState(() => st.expanded = !st.expanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Hero(
                            tag: 'bubble-${st.index}',
                            child: Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: accent.withOpacity(.10),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: accent.withOpacity(.25),
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  '${st.index + 1}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: accent,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        st.segment.senderName.isEmpty
                                            ? 'مرسل غير معروف'
                                            : st.segment.senderName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w900,
                                            ),
                                      ),
                                    ),
                                    if (st.segment.timestamp != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: cs.surfaceContainerHighest
                                              .withOpacity(.45),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Text(
                                          _formatSegmentTime(
                                            st.segment.timestamp!,
                                          ),
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    if (selectedCount > 0)
                                      _StatePill(
                                        text: 'مختارة: $selectedCount',
                                        icon: Icons.checklist,
                                        color: Colors.green.shade700,
                                      ),
                                    if (st.isReadOnly)
                                      _StatePill(
                                        text: 'قراءة فقط',
                                        icon: Icons.lock_outline,
                                        color: cs.primary,
                                      ),
                                    if (!st.isReadOnly && st.ready)
                                      _StatePill(
                                        text: 'جاهزة',
                                        icon: Icons.check_circle,
                                        color: Colors.green.shade700,
                                      ),
                                    if (!st.isReadOnly && !st.ready)
                                      _StatePill(
                                        text: 'تحتاج مراجعة',
                                        icon: Icons.info_outline,
                                        color: Colors.orange.shade700,
                                      ),
                                    if (st.warningTexts.isNotEmpty)
                                      _StatePill(
                                        text:
                                            'تحذيرات ${st.warningTexts.length}',
                                        icon: Icons.warning_amber_rounded,
                                        color: cs.error,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          AnimatedRotation(
                            turns: isCollapsed ? 0 : .5,
                            duration: const Duration(milliseconds: 220),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (!_compactMode) ...[
                    const SizedBox(height: 10),
                    _bubbleQuickInfo(st),
                  ],

                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 240),
                    reverseDuration: const Duration(milliseconds: 180),
                    sizeCurve: Curves.easeOutCubic,
                    firstCurve: Curves.easeOutCubic,
                    secondCurve: Curves.easeInCubic,
                    crossFadeState: isCollapsed
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    firstChild: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_showMessagePanel) ...[
                          const SizedBox(height: 12),
                          _messagePane(st),
                        ],
                        const SizedBox(height: 10),
                        _bubbleActionRow(st),
                        const SizedBox(height: 12),
                        _detailPane(st),
                      ],
                    ),
                    secondChild: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _compactBubbleLine(st),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubbleQuickInfo(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _miniInfo(
          Icons.numbers_rounded,
          'المبلغ',
          st.amount == null
              ? 'غير محدد'
              : '${_formatAmount(st.amount!)}${_amountSourceSuffix(st)}',
        ),
        _miniInfo(
          Icons.payments_outlined,
          'العملة',
          _currencyLabel(st.currencyKey),
        ),
        _miniInfo(
          Icons.fact_check_outlined,
          'النتائج',
          '${st.candidates.length}',
        ),
        if (st.segment.header.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withOpacity(.25),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.outlineVariant.withOpacity(.45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.short_text_rounded,
                  size: 17,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    st.segment.header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _miniInfo(IconData icon, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(.24),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withOpacity(.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
          Text(
            value,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _bubbleActionRow(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await _confirm(
              'استبعاد الفقاعة',
              'سيتم استبعاد هذه الفقاعة من العملية (لن تُحذف أي حركة). المتابعة؟',
            );
            if (!ok) return;
            setState(() {
              _bubbles.remove(st);
              _removedBubbles.add(st);
            });
            _showSnack(
              icon: Icons.remove_circle_outline,
              text: 'تم استبعاد الفقاعة.',
            );
          },
          icon: const Icon(Icons.hide_source_outlined),
          label: const Text('استبعاد'),
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: st.isReadOnly ? 'الفقاعة للقراءة فقط' : 'تحديث الترشيحات',
          child: IconButton.filledTonal(
            onPressed: st.isReadOnly
                ? null
                : () {
                    _refreshCandidates(st);
                    setState(() {});
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        const Spacer(),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: st.isReadOnly
              ? _StatePill(
                  key: const ValueKey('readonly'),
                  text: 'منفذة / قراءة فقط',
                  icon: Icons.lock_outline,
                  color: cs.primary,
                )
              : (st.ready
                    ? _StatePill(
                        key: const ValueKey('ready'),
                        text: 'جاهزة للتنفيذ',
                        icon: Icons.check_circle,
                        color: Colors.green.shade700,
                      )
                    : _StatePill(
                        key: const ValueKey('review'),
                        text: 'غير مكتملة',
                        icon: Icons.info_outline,
                        color: Colors.orange.shade700,
                      )),
        ),
      ],
    );
  }

  Widget _compactBubbleLine(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;
    final name = (st.manualName?.trim().isNotEmpty == true)
        ? st.manualName!.trim()
        : (st.detectedName?.trim().isNotEmpty == true
              ? st.detectedName!.trim()
              : 'اسم غير محدد');

    return Row(
      children: [
        Expanded(
          child: Text(
            '$name • ${st.amount == null ? 'مبلغ غير محدد' : _formatAmount(st.amount!)} • نتائج: ${st.candidates.length}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: () => setState(() => st.expanded = true),
          icon: const Icon(Icons.open_in_full_rounded, size: 16),
          label: const Text('فتح'),
        ),
      ],
    );
  }

  // ====== لوحة النص ======
  Widget _messagePane(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(
          st.isReadOnly ? .16 : .22,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withOpacity(.50)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 18,
                color: cs.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'نص الرسالة',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: cs.primary,
                ),
              ),
              const Spacer(),
              if (st.isReadOnly)
                _StatePill(
                  text: 'قراءة فقط',
                  icon: Icons.lock_outline,
                  color: cs.primary,
                ),
            ],
          ),
          const SizedBox(height: 10),
          ..._messageLines(st),
          const SizedBox(height: 2),
          _tokenLegend(st),
          const Divider(height: 22),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _infoInline(
                icon: Icons.numbers,
                label: 'المبلغ',
                value: st.amount == null
                    ? 'غير محدد'
                    : '${_formatAmount(st.amount!)}${_amountSourceSuffix(st)}',
              ),
              _infoInline(
                icon: Icons.attach_money,
                label: 'العملة',
                value: _currencyLabel(st.currencyKey),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _amountSourceSuffix(_BubbleState st) {
    if (st.manualAmount != null) return ' (يدوي)';
    if (st.amountChosenByMatch) return ' (مطابق لحركة)';
    return '';
  }

  _TokRole _roleOf(_BubbleState st, int li, int ti) {
    final pos = _TokPos(li, ti);
    final nameSet = st.manualName != null ? st.manualNameTokens : st.nameTokens;
    if (nameSet.contains(pos)) return _TokRole.name;
    final amountSet = st.manualAmount != null
        ? st.manualAmountTokens
        : (st.amountChosenByMatch
              ? const <_TokPos>{}
              : st.detectedAmountTokens);
    if (amountSet.contains(pos)) return _TokRole.amount;
    final cp = st.currencyPos;
    if (cp != null && cp.x == li && cp.y == ti) return _TokRole.currency;
    final m = st.noiseTokens[pos];
    if (m != null) {
      return m.kind == NoiseKind.context ? _TokRole.context : _TokRole.noise;
    }
    return _TokRole.plain;
  }

  Color _roleColor(_TokRole role, ColorScheme cs) {
    switch (role) {
      case _TokRole.name:
        return Colors.indigo.shade600;
      case _TokRole.amount:
        return Colors.green.shade700;
      case _TokRole.currency:
        return Colors.teal.shade600;
      case _TokRole.noise:
        return Colors.amber.shade800;
      case _TokRole.context:
        return Colors.blueGrey;
      case _TokRole.plain:
        return cs.outline;
    }
  }

  List<Widget> _messageLines(_BubbleState st) {
    final ex = st.extraction;
    if (ex == null) {
      return [
        for (final l in st.segment.lines)
          if (l.trim().isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l)),
      ];
    }
    final cs = Theme.of(context).colorScheme;
    final out = <Widget>[];
    for (int li = 0; li < ex.lines.length; li++) {
      final line = ex.lines[li];
      if (line.tokens.isEmpty) continue;
      out.add(
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (int ti = 0; ti < line.tokens.length; ti++)
              _messageToken(st, li, ti, cs),
          ],
        ),
      );
      out.add(const SizedBox(height: 7));
    }
    return out;
  }

  Widget _messageToken(_BubbleState st, int li, int ti, ColorScheme cs) {
    final line = st.extraction!.lines[li];
    final tok = line.tokens[ti];
    final role = _roleOf(st, li, ti);
    final mark = st.noiseTokens[_TokPos(li, ti)];
    final accent = _roleColor(role, cs);
    final highlighted = role != _TokRole.plain;
    final hasDigit = tt.tokenHasDigit(tok);

    final String tip;
    if (st.isReadOnly) {
      tip = 'قراءة فقط';
    } else if (role == _TokRole.noise && mark != null) {
      tip =
          '${mark.kind.label}${mark.suspect ? ' (مشكوك به)' : ''} — تم تجاهله. اضغط لاعتماده كمبلغ';
    } else if (hasDigit) {
      tip = 'اضغط لاعتماد هذا الرقم كمبلغ';
    } else {
      tip = 'اضغط لاعتماد الاسم من هنا';
    }

    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: st.isReadOnly ? null : () => _onMessageTokenTap(st, li, ti),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 170),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: accent.withValues(alpha: highlighted ? .55 : .25),
            ),
            color: highlighted
                ? accent.withValues(alpha: role == _TokRole.context ? .06 : .13)
                : cs.surface.withValues(alpha: .72),
          ),
          child: Text(
            tok,
            style: TextStyle(
              color: role == _TokRole.noise ? accent : null,
              decoration: role == _TokRole.noise
                  ? TextDecoration.lineThrough
                  : null,
              decorationColor: accent.withValues(alpha: .7),
              fontWeight: role == _TokRole.name || role == _TokRole.amount
                  ? FontWeight.w800
                  : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _tokenLegend(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;
    final kinds = <NoiseKind>{
      for (final m in st.noiseTokens.values)
        if (m.kind != NoiseKind.context) m.kind,
    };

    Widget dot(Color c, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: c.withValues(alpha: .75),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            dot(_roleColor(_TokRole.name, cs), 'الاسم'),
            dot(_roleColor(_TokRole.amount, cs), 'المبلغ'),
            dot(_roleColor(_TokRole.currency, cs), 'العملة'),
            if (kinds.isNotEmpty)
              dot(
                _roleColor(_TokRole.noise, cs),
                'متجاهَل: ${kinds.map((k) => k.label).join('، ')}',
              ),
          ],
        ),
        if (!st.isReadOnly) ...[
          const SizedBox(height: 6),
          Text(
            'اضغط على كلمة لاعتماد الاسم منها، أو على رقم لاعتماده كمبلغ.',
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  // ====== لوحة التفاصيل ======
  Widget _detailPane(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (st.isReadOnly) ...[
          _infoTile(
            icon: Icons.lock_outline,
            text:
                'تم تنفيذ اختيار من هذه الفقاعة، لذلك أصبحت للقراءة فقط ولا يمكن تحديد أي نتيجة أخرى منها.',
          ),
          const SizedBox(height: 12),
        ],
        _sectionTitle(Icons.person_outline, 'الاسم'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            InputChip(
              label: Text(
                (st.manualName?.trim().isNotEmpty == true)
                    ? st.manualName!
                    : (st.detectedName?.isNotEmpty == true
                          ? st.detectedName!
                          : 'غير محدد'),
              ),
              avatar: const Icon(Icons.badge_outlined),
            ),
            SizedBox(
              width: 320,
              child: TextField(
                controller: st.nameController,
                enabled: !st.isReadOnly,
                decoration: InputDecoration(
                  labelText: 'الاسم اليدوي',
                  hintText: 'مثال: محمد أحمد',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.edit_outlined),
                  suffixIcon: st.isReadOnly
                      ? null
                      : IconButton(
                          tooltip: 'اعتماد',
                          icon: const Icon(Icons.check),
                          onPressed: () {
                            final typed = st.nameController.text.trim();
                            st.manualName = typed.isEmpty ? null : typed;
                            st.manualNameTokens.clear();
                            _refreshCandidates(st);
                            setState(() {});
                          },
                        ),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: st.isReadOnly
                  ? null
                  : () {
                      st.manualName = null;
                      st.manualNameTokens.clear();
                      st.nameController.clear();
                      _refreshCandidates(st);
                      setState(() {});
                    },
              icon: const Icon(Icons.undo),
              label: const Text('إلغاء اليدوي'),
            ),
          ],
        ),
        ..._nameHints(st),

        const SizedBox(height: 14),
        _sectionTitle(Icons.payments_outlined, 'المبلغ'),
        const SizedBox(height: 6),
        _amountEditor(st),

        const SizedBox(height: 14),

        if (st.warningTexts.isNotEmpty) ...[
          _warningBox(st.warningTexts),
          const SizedBox(height: 12),
        ],

        _sectionTitle(Icons.checklist_outlined, 'المختارة'),
        const SizedBox(height: 6),
        st.selectedTxIds.isEmpty
            ? _infoTile(
                icon: Icons.info_outline,
                text: 'لم يتم اختيار أي حركة.',
              )
            : _selectedSummary(st),

        const SizedBox(height: 14),

        _sectionTitle(Icons.search_outlined, 'كل النتائج'),
        const SizedBox(height: 6),
        st.candidates.isEmpty
            ? _infoTile(
                icon: Icons.search_off,
                text: 'لا يوجد مرشّحون لهذا النص.',
              )
            : _candidatesList(st),
      ],
    );
  }

  List<Widget> _nameHints(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;
    final ex = st.extraction;
    if (ex == null) return const [];
    final current = tt.normalizeText(_effectiveName(st));
    final options = ex.nameOptions
        .where((o) => tt.normalizeText(o.text) != current)
        .toList();
    final noName = _effectiveName(st).isEmpty;

    return [
      if (noName) ...[
        const SizedBox(height: 8),
        _infoTile(
          icon: Icons.info_outline,
          text:
              '${ex.nameReason ?? 'لم يتم العثور على الاسم'} — اضغط على الاسم داخل نص الرسالة أو اختر من الاقتراحات.',
        ),
      ],
      if (options.isNotEmpty && !st.isReadOnly) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'اقتراحات:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: cs.onSurfaceVariant,
              ),
            ),
            for (final o in options)
              Tooltip(
                message: o.reason,
                child: ActionChip(
                  avatar: const Icon(Icons.person_search_outlined, size: 18),
                  label: Text(o.text),
                  onPressed: () =>
                      _applyNameTokens(st, o.lineIndex, o.tokenIndexes),
                ),
              ),
          ],
        ),
      ],
    ];
  }

  Widget _amountEditor(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;
    final others = st.amountCandidateValues
        .where((v) => st.amount == null || (v - st.amount!).abs() > 0.0001)
        .toList();

    void applyTyped() {
      final raw = st.amountController.text.trim();
      if (raw.isEmpty) {
        _applyManualAmount(st, null);
        return;
      }
      final v = ad.AmountDetector.parseAmountToken(tt.cleanToken(raw));
      if (v == null || v <= 0) {
        _showSnack(
          icon: Icons.error_outline,
          text: 'اكتب مبلغًا صحيحًا.',
          color: cs.error,
        );
        return;
      }
      _applyManualAmount(st, v);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            InputChip(
              avatar: const Icon(Icons.payments_outlined),
              label: Text(
                st.amount == null
                    ? 'غير محدد'
                    : '${_formatAmount(st.amount!)} ${st.currencyKey == null ? '' : _currencyLabel(st.currencyKey)}${_amountSourceSuffix(st)}',
              ),
            ),
            SizedBox(
              width: 220,
              child: TextField(
                controller: st.amountController,
                enabled: !st.isReadOnly,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onSubmitted: (_) => applyTyped(),
                decoration: InputDecoration(
                  labelText: 'المبلغ اليدوي',
                  hintText: 'مثال: 1500',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.edit_outlined),
                  suffixIcon: st.isReadOnly
                      ? null
                      : IconButton(
                          tooltip: 'اعتماد',
                          icon: const Icon(Icons.check),
                          onPressed: applyTyped,
                        ),
                ),
              ),
            ),
            if (st.manualAmount != null)
              TextButton.icon(
                onPressed: st.isReadOnly
                    ? null
                    : () => _applyManualAmount(st, null),
                icon: const Icon(Icons.undo),
                label: const Text('إلغاء اليدوي'),
              ),
          ],
        ),
        if (others.isNotEmpty && !st.isReadOnly) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'أرقام أخرى في الرسالة:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurfaceVariant,
                ),
              ),
              for (final v in others)
                ActionChip(
                  label: Text(_formatAmount(v)),
                  onPressed: () => _applyManualAmount(st, v),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _selectedSummary(_BubbleState st) {
    final cs = Theme.of(context).colorScheme;
    final items = st.candidates
        .where((c) => st.selectedTxIds.contains(c.tx.id))
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withOpacity(.6)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        children: items.map((c) {
          final delta = (st.amount != null)
              ? (c.tx.amount - st.amount!).abs()
              : null;
          final err = _lastErrorByTxId[c.tx.id];
          final isCancelled = c.tx.status == TransactionStatus.cancelled;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _rowTx(
                checkbox: Radio<int>(
                  value: c.tx.id,
                  groupValue: _selectedIdOf(st),
                  onChanged: st.isReadOnly
                      ? null
                      : (_) => _selectSingleCandidate(st, c.tx.id),
                ),
                title: '${c.tx.beneficiary} • ${c.tx.amount} ${c.tx.currency}',
                subtitle:
                    'الحالة: ${_statusLabel(c.tx.status)}'
                    '${delta != null && delta > 0 ? ' • Δ ${delta.toStringAsFixed(2)}' : ''}'
                    ' • ${_formatTxDateTime(c.tx.date)}',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCancelled)
                      const Padding(
                        padding: EdgeInsetsDirectional.only(end: 8),
                        child: _WarnPill(text: 'ملغية'),
                      ),
                    IconButton(
                      tooltip: st.isReadOnly
                          ? 'الفقاعة للقراءة فقط'
                          : 'إزالة من المختارة',
                      onPressed: st.isReadOnly
                          ? null
                          : () => _clearSelectedCandidate(st, c.tx.id),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (err != null && err.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0, right: 40),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'خطأ: $err',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: 'نسخ الخطأ',
                        icon: const Icon(Icons.copy),
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: err)),
                      ),
                    ],
                  ),
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _candidatesList(_BubbleState st) {
    final exact = st.candidates.where((c) => c.exact).toList();
    final similar = st.candidates.where((c) => !c.exact).toList();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Column(
        key: ValueKey(
          'candidates-${st.index}-$_showSimilarCandidates-${st.candidates.length}',
        ),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (exact.isNotEmpty) ...[
            _subHeader(
              'مطابقة مؤكدة',
              icon: Icons.verified_outlined,
              count: exact.length,
            ),
            ...exact.map((c) => _candidateRow(st, c)),
            const SizedBox(height: 8),
          ],
          if (similar.isNotEmpty && _showSimilarCandidates) ...[
            _subHeader(
              'مشابهة',
              icon: Icons.compare_arrows_rounded,
              count: similar.length,
            ),
            ...similar.map((c) => _candidateRow(st, c)),
          ],
          if (similar.isNotEmpty && !_showSimilarCandidates)
            _infoTile(
              icon: Icons.visibility_off_outlined,
              text:
                  'تم إخفاء ${similar.length} نتيجة مشابهة من شريط الخيارات العلوي.',
            ),
        ],
      ),
    );
  }

  Widget _candidateRow(_BubbleState st, _Candidate c) {
    final cs = Theme.of(context).colorScheme;
    final selected = st.selectedTxIds.contains(c.tx.id);
    final delta = (st.amount != null) ? (c.tx.amount - st.amount!).abs() : 0.0;
    final err = _lastErrorByTxId[c.tx.id];

    final isReceived = c.tx.status == TransactionStatus.received;
    final isCancelled = c.tx.status == TransactionStatus.cancelled;
    final lockedByAnother = _isTxSelectedInAnotherBubble(st, c.tx.id);
    final disabled = st.isReadOnly || isReceived || lockedByAnother;
    final accent = selected
        ? cs.primary
        : (c.exact ? Colors.green.shade700 : cs.outline);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: selected
            ? cs.primary.withOpacity(.075)
            : cs.surfaceContainerLowest.withOpacity(.65),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withOpacity(selected ? .70 : .32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Radio<int>(
                  value: c.tx.id,
                  groupValue: _selectedIdOf(st),
                  onChanged: disabled
                      ? null
                      : (_) => _selectSingleCandidate(st, c.tx.id),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.tx.beneficiary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withOpacity(.10),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${c.tx.amount} ${c.tx.currency}',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: selected ? cs.primary : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _TinyPill(
                          icon: Icons.flag_outlined,
                          text: _statusLabel(c.tx.status),
                        ),
                        if (st.amount != null)
                          _TinyPill(
                            icon: Icons.call_split_rounded,
                            text: 'Δ ${delta.toStringAsFixed(2)}',
                          ),
                        _TinyPill(
                          icon: Icons.schedule_outlined,
                          text: _formatTxDateTime(c.tx.date),
                        ),
                        if (c.exact)
                          _TinyPill(
                            icon: Icons.verified_outlined,
                            text: 'مؤكدة',
                            color: Colors.green.shade700,
                          ),
                        if (st.isReadOnly)
                          _TinyPill(
                            icon: Icons.lock_outline,
                            text: 'قراءة فقط',
                            color: cs.primary,
                          ),
                        if (isReceived)
                          _TinyPill(
                            icon: Icons.done_all,
                            text: 'مستلمة مسبقًا',
                            color: cs.error,
                          ),
                        if (isCancelled)
                          _TinyPill(
                            icon: Icons.cancel_outlined,
                            text: 'ملغية',
                            color: cs.error,
                          ),
                        if (lockedByAnother)
                          _TinyPill(
                            icon: Icons.lock_clock_outlined,
                            text: 'محجوزة بفقاعة أخرى',
                            color: cs.primary,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: st.isReadOnly
                    ? 'الفقاعة للقراءة فقط'
                    : 'إزالة هذه النتيجة من الفقاعة',
                onPressed: st.isReadOnly
                    ? null
                    : () {
                        final wasSelected = st.selectedTxIds.contains(c.tx.id);
                        if (wasSelected) {
                          st.selectedTxIds.remove(c.tx.id);
                        }
                        st.candidates.removeWhere((x) => x.tx.id == c.tx.id);
                        _recomputeWarningsAndReady(st);
                        setState(() {});
                      },
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          if (st.isReadOnly)
            _inlineHint(
              'هذه الفقاعة نُفذت سابقًا وأصبحت للقراءة فقط، لذلك لا يمكن اختيار هذه النتيجة.',
              cs.primary,
            ),
          if (isReceived)
            _inlineHint(
              'هذه الحركة مُسجّلة مسبقًا كمستلمة — لا يمكن تحديدها.',
              cs.error,
            ),
          if (lockedByAnother)
            _inlineHint(
              'هذه الحركة محددة الآن داخل فقاعة أخرى، لذلك هي مقفلة هنا.',
              cs.primary,
            ),
          if (err != null && err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8.0, right: 44),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'خطأ: $err',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'نسخ الخطأ',
                    icon: const Icon(Icons.copy),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: err)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _inlineHint(String text, Color color) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 44, top: 7),
      child: Text(text, style: TextStyle(color: color, fontSize: 12)),
    );
  }

  // ====== عناصر UI مساعدة ======
  Widget _rowTx({
    required Widget checkbox,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        checkbox,
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        trailing,
      ],
    );
  }

  Widget _infoInline({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withOpacity(.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w800)),
          Flexible(child: Text(value, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _warningBox(List<String> warns) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.error.withOpacity(.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withOpacity(.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18),
              SizedBox(width: 6),
              Text('تحذيرات', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          ...warns.map(
            (w) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $w'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoTile({
    required IconData icon,
    required String text,
    Color? color,
  }) {
    final cs = Theme.of(context).colorScheme;
    final base = color ?? cs.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: base.withOpacity(.25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: (color ?? cs.outlineVariant).withOpacity(.6)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color ?? cs.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  Widget _sectionTitle(IconData icon, String t) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            t,
            style: TextStyle(fontWeight: FontWeight.bold, color: cs.primary),
          ),
        ],
      ),
    );
  }

  Widget _subHeader(String t, {IconData? icon, int? count}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 17, color: cs.primary),
            const SizedBox(width: 6),
          ],
          Text(t, style: const TextStyle(fontWeight: FontWeight.w900)),
          if (count != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primary.withOpacity(.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return 'مضافة';
      case TransactionStatus.received:
        return 'مستلمة';
      case TransactionStatus.cancelled:
        return 'ملغية';
    }
  }

  // ====== تنفيذ ======
  Future<void> _onExecute() async {
    if (_building) return;
    final totalBubblesBefore = _bubbles.length;
    _lastErrors.clear();
    _lastErrorByTxId.clear();

    final readyBubbles = _bubbles
        .where((b) => !b.isReadOnly && b.ready && b.selectedTxIds.isNotEmpty)
        .toList();
    if (readyBubbles.isEmpty) {
      _showSnack(
        icon: Icons.info_outline,
        text: 'لا توجد فقاعات مكتملة للتنفيذ حالياً.',
      );
      return;
    }

    final withWarnings = readyBubbles
        .where((b) => b.warningTexts.isNotEmpty)
        .toList();
    if (withWarnings.isNotEmpty) {
      final ok = await _confirm(
        'تأكيد التنفيذ',
        'هناك ${withWarnings.length} فقاعة تحتوي تحذيرات. هل تريد المتابعة؟',
      );
      if (!ok) return;
    }

    int changed = 0;
    int failed = 0;
    final records = <OperationTxRecord>[];

    for (final st in readyBubbles.toList()) {
      var bubbleChanged = false;

      for (final id in st.selectedTxIds.toList()) {
        try {
          final tx = st.candidates.firstWhere((c) => c.tx.id == id).tx;

          final DateTime ts =
              st.segment.timestamp ??
              DateTime.now(); // timestamp متاح من الهيدر
          final before = OperationLogService.snapshot(tx);
          tx.applyStatus(TransactionStatus.received, at: ts);
          await tx.save();
          records.add(
            OperationTxRecord(
              txId: tx.id,
              before: before,
              after: OperationLogService.snapshot(tx),
            ),
          );

          // لا نحذف المرشحات المتبقية من الفقاعة.
          // بعد نجاح التنفيذ نقفل الفقاعة كاملة للقراءة فقط.
          st.selectedTxIds.remove(id);
          bubbleChanged = true;
          changed++;
        } catch (e) {
          failed++;
          final reason = e.toString();
          _lastErrors.add(
            _ExecError(
              bubbleHeader: st.segment.header,
              txId: id,
              reason: reason,
            ),
          );
          _lastErrorByTxId[id] = reason;
        }
      }

      if (bubbleChanged) {
        st.isReadOnly = true;
        st.readOnlyAt = DateTime.now();
        st.ready = false;
        st.selectedTxIds.clear();
        st.warningTexts.clear();
      } else if (st.selectedTxIds.isEmpty && st.candidates.isEmpty) {
        _bubbles.remove(st);
        _removedBubbles.add(st);
      } else {
        _recomputeWarningsAndReady(st);
      }
    }

    // تسجيل التسليم في سجل العمليات (قابل للتراجع من شاشة السجل)
    await OperationLogService.log(
      kind: OperationKind.statusChange,
      title:
          'تسليم ${records.length} حركة من صفحة التسليم في «${widget.account.name}»',
      subtitle: records.length == 1 ? null : 'مطابقة واستلام',
      records: records,
    );

    if (!mounted) return;

    if (changed > 0 && _bubbles.isEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _SuccessConfirmPage(count: changed),
        ),
      );
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return;
    }

    if (changed > 0) {
      final remainingBubbles = _bubbles.length;
      _showSnack(
        icon: Icons.check_circle,
        text:
            'تم تنفيذ $changed من أصل $totalBubblesBefore — تبقّى $remainingBubbles${failed > 0 ? ' • تعذّر تنفيذ $failed' : ''}',
      );
    } else if (failed > 0) {
      _showSnack(
        icon: Icons.error_outline,
        text: 'تعذّر تنفيذ $failed عملية. افتح "الأخطاء" للاطلاع.',
        color: Theme.of(context).colorScheme.error,
      );
    }

    setState(() {});
  }

  // ======Dialogs & Snackbars=====
  void _showErrorsDialog() {
    showDialog(
      context: context,
      builder: (_) {
        final all = _lastErrors
            .map(
              (e) =>
                  'الفقاعة: ${e.bubbleHeader}\nTxId: ${e.txId}\nالسبب: ${e.reason}',
            )
            .join('\n— — —\n');
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('أخطاء التنفيذ'),
            content: SizedBox(
              width: 600,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(all.isEmpty ? 'لا يوجد أخطاء' : all),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (all.isNotEmpty)
                          FilledButton.tonal(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: all));
                              Navigator.pop(context);
                              _showSnack(
                                icon: Icons.copy,
                                text: 'تم نسخ جميع الأخطاء.',
                              );
                            },
                            child: const Text('نسخ الكل'),
                          ),
                        ..._lastErrors.asMap().entries.map(
                          (e) => OutlinedButton(
                            onPressed: () {
                              final t =
                                  'الفقاعة: ${e.value.bubbleHeader}\nTxId: ${e.value.txId}\nالسبب: ${e.value.reason}';
                              Clipboard.setData(ClipboardData(text: t));
                              _showSnack(
                                icon: Icons.copy,
                                text: 'تم نسخ الخطأ #${e.key + 1}.',
                              );
                            },
                            child: Text('نسخ الخطأ #${e.key + 1}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إغلاق'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<bool> _confirm(String title, String msg) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: Text(title),
              content: Text(msg),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('تأكيد'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  void _showSnack({
    required IconData icon,
    required String text,
    Color? color,
  }) {
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: (color ?? cs.inverseSurface),
        content: Row(
          children: [
            Icon(icon, color: cs.onInverseSurface),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: TextStyle(color: cs.onInverseSurface)),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'حسنًا',
          textColor: cs.primary,
          onPressed: () {},
        ),
      ),
    );
  }
}

// ====== شاشة تأكيد ملء الشاشة ======
class _SuccessConfirmPage extends StatelessWidget {
  final int count;
  const _SuccessConfirmPage({required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: cs.surface,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.verified, size: 96, color: Colors.green.shade600),
                  const SizedBox(height: 16),
                  Text(
                    'تم التنفيذ بنجاح',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'عدد الحركات المنفذة: $count',
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.home),
                    label: const Text('العودة للرئيسية'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ====== تراكيب داخليّة ======
class _ParsedSegment {
  final String header;
  final String senderName;
  final DateTime? timestamp;
  final List<String> lines;
  _ParsedSegment({
    required this.header,
    required this.senderName,
    required this.timestamp,
    required this.lines,
  });
}

class _TokPos {
  final int li;
  final int ti;
  const _TokPos(this.li, this.ti);
  @override
  bool operator ==(Object other) =>
      other is _TokPos && other.li == li && other.ti == ti;
  @override
  int get hashCode => Object.hash(li, ti);
}

class _Candidate {
  final TransactionModel tx;
  final double delta;
  final bool exact;

  /// 3 = اسم مطابق تمامًا ، 2 = اسم الحركة ظاهر في الرسالة/جزء متصل ، 1 = تشابه
  final int rank;
  final bool currencyOk;

  _Candidate({
    required this.tx,
    required this.delta,
    required this.exact,
    this.rank = 0,
    this.currencyOk = true,
  });
}

/// فهرس الحركات المضافة للمطابقة السريعة بالاسم
class _PendingIndex {
  final Map<int, List<String>> keysById = {};
  final Map<String, List<TransactionModel>> byFull = {};
  final Map<String, List<TransactionModel>> byFirst = {};
  final Map<String, List<TransactionModel>> byToken = {};

  _PendingIndex(List<TransactionModel> txs) {
    for (final tx in txs) {
      final keys = tt
          .tokensFromLine(tx.beneficiary)
          .map(tt.matchKey)
          .where((k) => k.isNotEmpty)
          .toList();
      if (keys.isEmpty) continue;
      keysById[tx.id] = keys;
      (byFull[keys.join(' ')] ??= []).add(tx);
      (byFirst[keys.first] ??= []).add(tx);
      for (final k in keys.toSet()) {
        if (k.length >= 2) (byToken[k] ??= []).add(tx);
      }
    }
  }
}

class _ExecError {
  final String bubbleHeader;
  final int txId;
  final String reason;
  _ExecError({
    required this.bubbleHeader,
    required this.txId,
    required this.reason,
  });
}

class _BubbleState {
  final _ParsedSegment segment;
  final int index;

  ReceiptExtraction? extraction;
  final Map<_TokPos, NoiseMark> noiseTokens = {};
  final Set<_TokPos> nameTokens = {};
  final Set<_TokPos> manualNameTokens = {};

  String? detectedName;
  String? manualName;
  final TextEditingController nameController = TextEditingController();

  /// المبلغ الفعلي (يدوي، أو مختار بالمطابقة، أو المكتشف)
  double? amount;
  double? detectedAmount;
  double? manualAmount;
  Set<_TokPos> detectedAmountTokens = {};
  final Set<_TokPos> manualAmountTokens = {};
  final TextEditingController amountController = TextEditingController();
  bool amountChosenByMatch = false;
  bool amountFromSuspect = false;

  Point<int>? currencyPos;
  String? currencyKey;

  final List<_Candidate> candidates = [];
  final Set<int> selectedTxIds = {};

  bool ready = false;
  bool hasAmbiguousExactMatches = false;

  bool amountHasConflict = false;
  bool amountHasMultipleCandidates = false;
  List<double> amountCandidateValues = [];

  final List<String> warningTexts = [];

  bool isReadOnly = false;
  DateTime? readOnlyAt;

  // حالة عرض فقط
  bool expanded = true;

  _BubbleState({required this.segment, required this.index});

  void dispose() {
    nameController.dispose();
    amountController.dispose();
  }
}

/// دور التوكن في نص الرسالة (للتلوين)
enum _TokRole { plain, name, amount, currency, noise, context }

enum _BubbleFilter {
  all,
  ready,
  needsReview,
  selected,
  hasCandidates,
  warnings,
  readOnly,
}

enum _BubbleSort {
  original,
  latestMessage,
  readyFirst,
  warningFirst,
  mostCandidates,
  readOnlyLast,
}

// ====== عناصر عرض صغيرة ======
class _TinyPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const _TinyPill({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final clr = color ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: clr.withOpacity(.07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: clr.withOpacity(.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: clr),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              color: clr,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ====== شارات ======
class _WarnPill extends StatelessWidget {
  final String text;
  const _WarnPill({required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.error.withOpacity(.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.error.withOpacity(.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: cs.error),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 11, color: cs.error)),
        ],
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? color;
  const _StatePill({
    Key? key,
    required this.text,
    required this.icon,
    this.color,
  }) : super(key: key);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final clr = color ?? cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: clr.withOpacity(.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: clr.withOpacity(.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: clr),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, color: clr)),
        ],
      ),
    );
  }
}
