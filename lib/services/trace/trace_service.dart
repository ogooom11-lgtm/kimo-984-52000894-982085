// lib/services/trace/trace_service.dart
// -------------------------------------------------------------
// خدمة تتبّع مصدر الحركة:
//  • تحسب «مين مصدر كل حركة مكتب» (وكل حركة إرسال بشركة: من أي استقبال
//    بشركة تانية) بالخلفية (Isolate) وتعيد الحساب تلقائيًا
//    مع أي تغيير بالحركات أو الحسابات أو سجل التعديلات أو الإعدادات.
//  • تحفظ قرارات المستخدم (تأكيد/تغيير/مجهول/«مو هي»/تجاهل تحذير) بصندوق
//    مستقل (tx_links) مع إعدادات التتبّع. الصندوق كله داخل النسخة
//    الاحتياطية. (ما منحتفظ بنص الرسائل: الوجهة بتنسجل مع الحركة نفسها.)
//  • كل قرار يدوي بينسجل بسجل الحركة («مسار الحركة»).
// -------------------------------------------------------------

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../database_service.dart';
import '../../models.dart';
import '../detection/receive_matching.dart' show CurrencyMatcher;
import '../operation_log_service.dart';
import '../tx_history_service.dart';
import 'trace_engine.dart';
import 'trace_timeline.dart'
    show kTraceAlignAmountSource, kTraceAlignNameSource;

export 'trace_engine.dart';

/// الحساب بخيط منفصل حتى ما يعلّق الواجهة (المدخلات نسخ عادية بدون Hive)
Future<TraceResult> _runInIsolate(
  TraceEngine engine,
  List<TransactionModel> txs,
  Map<int, Account> accounts,
  Map<int, List<TxHistoryEntry>> keyEdits,
  Map<String, Destination> destinations,
) => Isolate.run(
  () => engine.run(
    transactions: txs,
    accounts: accounts,
    keyEdits: keyEdits,
    destinations: destinations,
  ),
);

class TraceService {
  TraceService._();

  static const String _prefsKey = '__prefs__';
  static const String _rejectedKey = '__rejected__';
  static const String _dismissedKey = '__dismissed__';
  static const String _decisionPrefix = 'd:';

  /// نص رسائل حركات الشركات (نسخة قديمة) — ما عاد ينحفظ، ومنمسحه.
  static const String _messagePrefix = 'm:';
  static const int _maxDismissed = 4000;

  /// آخر نتيجة (null = لسا عم يحسب أول مرة)
  static final ValueNotifier<TraceResult?> result = ValueNotifier<TraceResult?>(
    null,
  );

  static final ValueNotifier<TracePrefs> prefs = ValueNotifier<TracePrefs>(
    const TracePrefs(),
  );

  /// عدد التحذيرات الفعّالة (شارة الصفحة الرئيسية)
  static final ValueNotifier<int> activeCount = ValueNotifier<int>(0);

  /// true أثناء إعادة الحساب
  static final ValueNotifier<bool> computing = ValueNotifier<bool>(false);

  static bool _started = false;
  static bool _ready = false;
  static bool _busy = false;
  static bool _again = false;
  static bool _isolateFailed = false;
  static Timer? _debounce;
  static Timer? _ticker;
  static int _ticks = 0;
  static Listenable? _sources;

  static TraceDecisions _decisions = const TraceDecisions();
  static Map<int, TransactionModel>? _txIndex;
  static DestinationBook? _destinations;

  static Box<dynamic>? get _box =>
      Hive.isBoxOpen(DatabaseService.txLinksBoxName)
      ? Hive.box<dynamic>(DatabaseService.txLinksBoxName)
      : null;

  static TraceDecisions get decisions => _decisions;

  // ===========================
  // التشغيل
  // ===========================

  static void start() {
    if (_started) return;
    if (!Hive.isBoxOpen(DatabaseService.transactionsBoxName)) return;
    _started = true;
    _loadStore();
    final sources = Listenable.merge([
      DatabaseService.transactionsBox.listenable(),
      DatabaseService.accountsBox.listenable(),
      DatabaseService.settingsBox.listenable(),
      TxHistoryService.keyEditsRevision,
    ]);
    sources.addListener(schedule);
    _sources = sources;
    // «ما راحت لمكتب» بتعتمد على الوقت: منعيد الحساب كل 5 دقائق إذا في
    // وجهات تابعة لمكتب، وإلا كل ساعة (لمدة التحذيرات بس)
    _ticker = Timer.periodic(const Duration(minutes: 5), (_) {
      _ticks++;
      if (destinations.items.any((d) => d.toOffice) || _ticks % 12 == 0) {
        schedule();
      }
    });
    // ننتظر الأسماء القديمة من سجل التعديلات قبل أول حساب (بحد أقصى 8 ثواني)
    unawaited(
      Future.any<void>([
        TxHistoryService.ensureKeyEdits(),
        Future<void>.delayed(const Duration(seconds: 8)),
      ]).whenComplete(() {
        _ready = true;
        schedule(immediate: true);
      }),
    );
  }

  static void stop() {
    _sources?.removeListener(schedule);
    _sources = null;
    _ticker?.cancel();
    _ticker = null;
    _debounce?.cancel();
    _started = false;
  }

  /// أعد الحساب بعد لحظة (التغييرات المتلاحقة بتندمج)
  static void schedule({bool immediate = false}) {
    _txIndex = null;
    _destinations = null;
    if (!_started) return;
    _debounce?.cancel();
    _debounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 450),
      () => unawaited(_compute()),
    );
  }

  static Future<void> _compute() async {
    if (!_ready) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    computing.value = true;
    try {
      do {
        _again = false;
        final r = await _run();
        if (r != null) {
          final fixed = identical(r.dismissed, _decisions.dismissed)
              ? r
              : r.withDismissed(_decisions.dismissed);
          result.value = fixed;
          activeCount.value = fixed.activeWarnings.length;
        }
      } while (_again);
    } finally {
      _busy = false;
      computing.value = false;
    }
  }

  static TransactionModel _copyTx(TransactionModel t) => TransactionModel(
    id: t.id,
    accountId: t.accountId,
    beneficiary: t.beneficiary,
    amount: t.amount,
    currency: t.currency,
    notes: t.notes,
    status: t.status,
    date: t.date,
    receivedAt: t.receivedAt,
    cancelledAt: t.cancelledAt,
    secondAmount: t.secondAmount,
    secondCurrency: t.secondCurrency,
    companyMovementType: t.companyMovementType,
    destination: t.destination,
  );

  static Future<TraceResult?> _run() async {
    try {
      if (!TxHistoryService.keyEditsLoaded) {
        unawaited(TxHistoryService.ensureKeyEdits());
      }
      final accounts = <int, Account>{
        for (final a in DatabaseService.accountsBox.values)
          a.id: Account(id: a.id, name: a.name, type: a.type),
      };
      final txs = <TransactionModel>[
        for (final t in DatabaseService.transactionsBox.values)
          if (accounts.containsKey(t.accountId)) _copyTx(t),
      ];
      final settings = DatabaseService.getSettings();
      final engine = TraceEngine(
        prefs: prefs.value,
        currency: CurrencyMatcher(
          Map<String, String>.of(settings?.currencyMap ?? const {}),
        ),
        decisions: _decisions,
      );
      final edits = <int, List<TxHistoryEntry>>{
        for (final e in TxHistoryService.keyEdits.entries)
          e.key: List<TxHistoryEntry>.of(e.value),
      };
      final destinations = Map<String, Destination>.of(
        DestinationBook.fromSettings(settings).byKey,
      );
      if (!kIsWeb && !_isolateFailed) {
        try {
          return await _runInIsolate(
            engine,
            txs,
            accounts,
            edits,
            destinations,
          );
        } catch (e) {
          debugPrint('Trace isolate failed, running inline: $e');
          _isolateFailed = true;
        }
      }
      return engine.run(
        transactions: txs,
        accounts: accounts,
        keyEdits: edits,
        destinations: destinations,
      );
    } catch (e, s) {
      debugPrint('Trace compute error: $e\n$s');
      return null;
    }
  }

  // ===========================
  // التخزين
  // ===========================

  static void _loadStore() {
    final box = _box;
    if (box == null) return;
    prefs.value = TracePrefs.fromMap(box.get(_prefsKey));
    final byOffice = <int, TraceDecision>{};
    final oldMessages = <dynamic>[];
    for (final key in box.keys) {
      final k = '$key';
      if (k.startsWith(_decisionPrefix)) {
        final d = TraceDecision.fromMap(box.get(key));
        if (d != null) byOffice[d.officeId] = d;
      } else if (k.startsWith(_messagePrefix)) {
        oldMessages.add(key);
      }
    }
    // نص الرسائل المحفوظ من نسخة سابقة: ما عاد إله لزوم
    if (oldMessages.isNotEmpty) unawaited(box.deleteAll(oldMessages));
    final rejected = <int, Set<int>>{};
    final rawRejected = box.get(_rejectedKey);
    if (rawRejected is Map) {
      rawRejected.forEach((k, v) {
        final id = int.tryParse('$k');
        if (id == null || v is! List) return;
        final set = <int>{};
        for (final x in v) {
          final n = int.tryParse('$x');
          if (n != null) set.add(n);
        }
        if (set.isNotEmpty) rejected[id] = set;
      });
    }
    final rawDismissed = box.get(_dismissedKey);
    final dismissed = <String>{
      if (rawDismissed is List)
        for (final x in rawDismissed) '$x',
    };
    _decisions = TraceDecisions(
      byOffice: byOffice,
      rejected: rejected,
      dismissed: dismissed,
    );
  }

  static void _setDecisions({
    Map<int, TraceDecision>? byOffice,
    Map<int, Set<int>>? rejected,
    Set<String>? dismissed,
  }) {
    _decisions = TraceDecisions(
      byOffice: byOffice ?? _decisions.byOffice,
      rejected: rejected ?? _decisions.rejected,
      dismissed: dismissed ?? _decisions.dismissed,
    );
  }

  // ===========================
  // أدوات للواجهة
  // ===========================

  /// الحركة من معرّفها (فهرس يتحدث مع أي تغيير بالصندوق)
  static TransactionModel? txById(int id) {
    var index = _txIndex;
    if (index == null) {
      index = <int, TransactionModel>{
        for (final t in DatabaseService.transactionsBox.values) t.id: t,
      };
      _txIndex = index;
    }
    final t = index[id];
    if (t != null && t.isInBox) return t;
    if (t != null) _txIndex = null;
    return null;
  }

  /// الوجهات من الإعدادات (بتتحدث مع أي تغيير بالإعدادات)
  static DestinationBook get destinations =>
      _destinations ??= DestinationBook.fromSettings(
        Hive.isBoxOpen(DatabaseService.settingsBoxName)
            ? DatabaseService.getSettings()
            : null,
      );

  static Account? accountById(int id) {
    for (final a in DatabaseService.accountsBox.values) {
      if (a.id == id) return a;
    }
    return null;
  }

  static String accountName(int accountId) =>
      accountById(accountId)?.name ?? 'حساب #$accountId';

  /// وصف مختصر لحركة: «ABC • محمد أحمد • 500 دولار»
  static String describeTx(int id) {
    final t = txById(id);
    if (t == null) return 'حركة محذوفة';
    return '${accountName(t.accountId)} • ${t.beneficiary} • '
            '${traceAmount(t.amount)} ${t.currency}'
        .trim();
  }

  /// حركة «الوجهة» [destId] حركة إرسال بحساب شركة (مو حركة مكتب)؟
  static bool isSentDest(int destId) {
    final t = txById(destId);
    if (t == null) return false;
    return accountById(t.accountId)?.type.isCompany ?? false;
  }

  /// «حركة مكتب» / «حركة إرسال» حسب حركة الوجهة [destId]
  static String destNoun(int destId) =>
      isSentDest(destId) ? 'حركة إرسال' : 'حركة مكتب';

  static String _currentSourceLabel(int officeId) {
    final t = result.value?.office[officeId];
    if (t == null) return prefs.value.unknown;
    final link = t.link;
    if (t.status.linked && link != null) return describeTx(link.companyId);
    if (t.status == TraceStatus.possible) return 'محتمل (بدو اختيار)';
    return prefs.value.unknown;
  }

  // ===========================
  // قرارات المستخدم
  // ===========================

  /// ربط يدوي: مصدر حركة المكتب (أو الإرسال) [officeId] هو حركة الشركة
  /// [companyId]
  static Future<void> linkManually(int officeId, int companyId) async {
    final o = txById(officeId);
    final c = txById(companyId);
    if (o == null || c == null) return;
    final before = _currentSourceLabel(officeId);
    final prevCompany = result.value?.companyOf(officeId);
    final rej = _decisions.rejected[officeId];
    if (rej != null && rej.contains(companyId)) {
      await _saveRejected(officeId, rej.difference({companyId}));
    }
    final d = TraceDecision(
      officeId: officeId,
      kind: TraceDecisionKind.link,
      companyId: companyId,
      at: DateTime.now(),
      officeSnap: traceSnapOf(o),
      companySnap: traceSnapOf(c),
    );
    _setDecisions(
      byOffice: Map<int, TraceDecision>.of(_decisions.byOffice)..[officeId] = d,
    );
    await _box?.put('$_decisionPrefix$officeId', d.toMap());
    final same = prevCompany == companyId;
    TxHistoryService.recordLink(
      officeId,
      title: same ? 'تأكيد مصدر الحركة' : 'تحديد مصدر الحركة يدويًا',
      from: same ? null : before,
      to: describeTx(companyId),
    );
    final noun = destNoun(officeId);
    TxHistoryService.recordLink(
      companyId,
      title: same ? 'تأكيد الربط مع $noun' : 'ربط ب$noun يدويًا',
      label: 'الوجهة',
      to: describeTx(officeId),
    );
    if (prevCompany != null && !same) {
      TxHistoryService.recordLink(
        prevCompany,
        title: 'فك الربط مع $noun',
        label: 'الوجهة',
        from: describeTx(officeId),
      );
    }
    schedule(immediate: true);
  }

  /// توحيد المبلغ بين حركة مكتب وحركة شركة (من «مسار الحركة»):
  /// [officeTakesCompany] = true يعني حركة المكتب بتاخد مبلغ حركة الشركة، وإلا
  /// العكس. [link] = كمان تأكيد الربط بين الحركتين. بيرجع المبلغ الجديد، أو
  /// null إذا وحدة من الحركتين ما عادت موجودة.
  static Future<double?> alignAmount(
    int officeId,
    int companyId, {
    required bool officeTakesCompany,
    bool link = true,
  }) async {
    final o = txById(officeId);
    final c = txById(companyId);
    if (o == null || c == null) return null;
    final target = officeTakesCompany ? o : c;
    final source = officeTakesCompany ? c : o;
    final value = source.amount;
    if ((target.amount - value).abs() >= 0.005) {
      final before = OperationLogService.snapshot(target);
      TxHistoryService.annotate([target.id], kTraceAlignAmountSource);
      target.amount = value;
      await target.save();
      await OperationLogService.log(
        kind: OperationKind.manualEdit,
        title:
            'تعديل مبلغ «${target.beneficiary}» ليصير متل '
            '${officeTakesCompany ? 'حركة الشركة' : (isSentDest(officeId) ? 'حركة الإرسال' : 'حركة المكتب')}',
        subtitle: 'من مسار الحركة',
        records: [
          OperationTxRecord(
            txId: target.id,
            before: before,
            after: OperationLogService.snapshot(target),
          ),
        ],
      );
    }
    await _afterAlign(officeId, companyId, link: link, amount: true);
    return value;
  }

  /// توحيد الاسم بين حركة مكتب وحركة شركة (من «مسار الحركة»):
  /// [officeTakesCompany] = true يعني حركة المكتب بتاخد اسم حركة الشركة، وإلا
  /// العكس. [link] = كمان تأكيد الربط بين الحركتين. بيرجع الاسم الجديد، أو
  /// null إذا وحدة من الحركتين ما عادت موجودة أو الاسم يلي رح ناخده فاضي.
  static Future<String?> alignName(
    int officeId,
    int companyId, {
    required bool officeTakesCompany,
    bool link = true,
  }) async {
    final o = txById(officeId);
    final c = txById(companyId);
    if (o == null || c == null) return null;
    final target = officeTakesCompany ? o : c;
    final source = officeTakesCompany ? c : o;
    final value = source.beneficiary.trim();
    if (value.isEmpty) return null;
    final old = target.beneficiary.trim();
    if (old != value) {
      final before = OperationLogService.snapshot(target);
      TxHistoryService.annotate([target.id], kTraceAlignNameSource);
      target.beneficiary = value;
      await target.save();
      await OperationLogService.log(
        kind: OperationKind.manualEdit,
        title:
            'تعديل اسم «$old» لـ «$value» متل '
            '${officeTakesCompany ? 'حركة الشركة' : (isSentDest(officeId) ? 'حركة الإرسال' : 'حركة المكتب')}',
        subtitle: 'من مسار الحركة',
        records: [
          OperationTxRecord(
            txId: target.id,
            before: before,
            after: OperationLogService.snapshot(target),
          ),
        ],
      );
    }
    await _afterAlign(officeId, companyId, link: link, name: true);
    return value;
  }

  /// الربط بين حركة المكتب وحركة الشركة مؤكد يدويًا؟
  static bool isConfirmedPair(int officeId, int companyId) {
    final d = _decisions.byOffice[officeId];
    return d != null &&
        d.kind == TraceDecisionKind.link &&
        d.companyId == companyId;
  }

  /// بعد توحيد الاسم/المبلغ: إذا الربط مؤكد من قبل منقبل القيمة الجديدة بقيم
  /// التأكيد بس (بلا تحذير «انعدلت بعد ما أكدت الربط» بسببها، وبلا تأكيد
  /// جديد بالسجل)، وإلا منأكد الربط إذا المستخدم طلب.
  static Future<void> _afterAlign(
    int officeId,
    int companyId, {
    required bool link,
    bool name = false,
    bool amount = false,
  }) async {
    final d = _decisions.byOffice[officeId];
    final o = txById(officeId);
    final c = txById(companyId);
    if (d != null &&
        o != null &&
        c != null &&
        isConfirmedPair(officeId, companyId)) {
      String? patch(String? snap, TransactionModel t) => snap == null
          ? null
          : (traceSnapPatch(snap, t, name: name, amount: amount) ??
                traceSnapOf(t));
      final nd = TraceDecision(
        officeId: officeId,
        kind: d.kind,
        companyId: companyId,
        at: d.at,
        officeSnap: patch(d.officeSnap, o),
        companySnap: patch(d.companySnap, c),
      );
      _setDecisions(
        byOffice: Map<int, TraceDecision>.of(_decisions.byOffice)
          ..[officeId] = nd,
      );
      await _box?.put('$_decisionPrefix$officeId', nd.toMap());
      schedule(immediate: true);
    } else if (link) {
      await linkManually(officeId, companyId);
    } else {
      schedule(immediate: true);
    }
  }

  /// المصدر «مجهول» (قرار يدوي)
  static Future<void> markUnknown(int officeId) async {
    if (txById(officeId) == null) return;
    final before = _currentSourceLabel(officeId);
    final prevCompany = result.value?.companyOf(officeId);
    final d = TraceDecision(
      officeId: officeId,
      kind: TraceDecisionKind.unknown,
      at: DateTime.now(),
    );
    _setDecisions(
      byOffice: Map<int, TraceDecision>.of(_decisions.byOffice)..[officeId] = d,
    );
    await _box?.put('$_decisionPrefix$officeId', d.toMap());
    TxHistoryService.recordLink(
      officeId,
      title: 'تحديد المصدر «${prefs.value.unknown}»',
      from: before,
      to: prefs.value.unknown,
    );
    if (prevCompany != null) {
      TxHistoryService.recordLink(
        prevCompany,
        title: 'فك الربط مع ${destNoun(officeId)}',
        label: 'الوجهة',
        from: describeTx(officeId),
      );
    }
    schedule(immediate: true);
  }

  /// إلغاء القرار اليدوي والرجوع للربط التلقائي
  static Future<void> resetToAuto(int officeId, {bool log = true}) async {
    final had = _decisions.byOffice[officeId];
    if (had == null) return;
    _setDecisions(
      byOffice: Map<int, TraceDecision>.of(_decisions.byOffice)
        ..remove(officeId),
    );
    await _box?.delete('$_decisionPrefix$officeId');
    if (log) {
      final companyId = had.companyId;
      TxHistoryService.recordLink(
        officeId,
        title: 'رجوع للربط التلقائي',
        from: had.kind == TraceDecisionKind.link && companyId != null
            ? describeTx(companyId)
            : prefs.value.unknown,
      );
    }
    schedule(immediate: true);
  }

  /// «مو هي»: استبعاد حركة شركة كمصدر لحركة مكتب
  static Future<void> reject(int officeId, int companyId) async {
    final set = <int>{...?_decisions.rejected[officeId], companyId};
    await _saveRejected(officeId, set);
    final d = _decisions.byOffice[officeId];
    if (d != null &&
        d.kind == TraceDecisionKind.link &&
        d.companyId == companyId) {
      _setDecisions(
        byOffice: Map<int, TraceDecision>.of(_decisions.byOffice)
          ..remove(officeId),
      );
      await _box?.delete('$_decisionPrefix$officeId');
    }
    TxHistoryService.recordLink(
      officeId,
      title: 'استبعاد مصدر محتمل («مو هي»)',
      from: describeTx(companyId),
    );
    schedule(immediate: true);
  }

  static Future<void> _saveRejected(int officeId, Set<int> set) async {
    final map = Map<int, Set<int>>.of(_decisions.rejected);
    if (set.isEmpty) {
      map.remove(officeId);
    } else {
      map[officeId] = set;
    }
    _setDecisions(rejected: map);
    await _box?.put(_rejectedKey, <String, dynamic>{
      for (final e in map.entries) '${e.key}': e.value.toList(),
    });
  }

  /// تجاهل تحذير (بيرجع إذا تغيّر سببه، مثل تعديل جديد)
  static Future<void> dismiss(TraceWarning w) async {
    if (!w.dismissable) return;
    final set = <String>{..._decisions.dismissed, w.sig};
    await _saveDismissed(set);
    for (final id in <int?>[w.officeId, w.companyId]) {
      if (id == null) continue;
      TxHistoryService.recordLink(
        id,
        title: 'تجاهل تحذير',
        label: 'التحذير',
        to: w.title,
      );
    }
  }

  /// إرجاع تحذير متجاهَل
  static Future<void> undismiss(String sig) async {
    if (!_decisions.dismissed.contains(sig)) return;
    await _saveDismissed(<String>{..._decisions.dismissed}..remove(sig));
  }

  static Future<void> _saveDismissed(Set<String> set) async {
    var list = set.toList();
    if (list.length > _maxDismissed) {
      list = list.sublist(list.length - _maxDismissed);
    }
    final kept = list.toSet();
    _setDecisions(dismissed: kept);
    await _box?.put(_dismissedKey, list);
    final r = result.value;
    if (r != null) {
      final next = r.withDismissed(kept);
      result.value = next;
      activeCount.value = next.activeWarnings.length;
    }
  }

  static Future<void> setPrefs(TracePrefs p) async {
    prefs.value = p;
    await _box?.put(_prefsKey, p.toMap());
    // مؤجل شوي: تحريك المؤشر بيبعت تغييرات كتير ورا بعض
    schedule();
  }

  // ===========================
  // النسخ الاحتياطي
  // ===========================

  static Map<String, dynamic> exportAll() {
    final box = _box;
    if (box == null) return const {};
    return <String, dynamic>{
      for (final k in box.keys)
        if (!'$k'.startsWith(_messagePrefix)) '$k': box.get(k),
    };
  }

  /// يستبدل بيانات التتبّع بما في النسخة. نسخة قديمة بدونها: منمسح القرارات
  /// (معرّفات الحركات تغيّرت) ومنخلّي الإعدادات.
  static Future<void> importAll(Object? raw) async {
    final box = _box;
    if (box == null) return;
    final keepPrefs = box.get(_prefsKey);
    await box.clear();
    if (raw is Map && raw.isNotEmpty) {
      final m = <String, dynamic>{};
      raw.forEach((k, v) {
        if (v != null && !'$k'.startsWith(_messagePrefix)) m['$k'] = v;
      });
      await box.putAll(m);
    } else if (keepPrefs != null) {
      await box.put(_prefsKey, keepPrefs);
    }
    _loadStore();
    schedule();
  }
}
