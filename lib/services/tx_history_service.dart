// lib/services/tx_history_service.dart
// -------------------------------------------------------------
// سجل تعديلات الحركات: يراقب صندوق الحركات ويسجّل تلقائيًا كل تغيير على
// معلومات أي حركة (من أي شاشة: التعديل، التسليم، الإلغاء، النقل، التراجع...)
// مع التاريخ والوقت.
//
// - يحتفظ بلقطة لكل حركة في الذاكرة؛ عند حفظ الحركة يقارن اللقطة السابقة
//   بالحالة الجديدة ويسجّل الفروقات فقط (حدث Hive يحمل نفس الكائن بعد
//   تعديله، لذلك لا بد من اللقطة لمعرفة القيم القديمة).
// - السجل في صندوق كسول مستقل (tx_edit_history) مفتاحه معرّف الحركة كنص:
//   لا يُحمَّل كله في الذاكرة مهما كبر، ومنفصل عن «سجل العمليات» المحدود
//   بعدد والقابل للمسح، ويبقى ما بقيت الحركة.
// - الكتابة مجمّعة على دفعات حتى لا تثقل العمليات الجماعية.
// -------------------------------------------------------------

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';

import '../database_service.dart';
import '../models.dart';
import 'tx_history.dart';

export 'tx_history.dart';

class _TxState {
  final int id;
  final List<Object?> values;
  const _TxState(this.id, this.values);
}

class _Annotation {
  final String source;
  final DateTime until;

  /// وقت التعديل المسجّل بدل وقت الحفظ (مثل وقت الرسالة)
  final DateTime? at;
  const _Annotation(this.source, this.until, [this.at]);
}

typedef _RawEntries = Map<String, List<Map<String, dynamic>>>;

class TxHistoryService {
  TxHistoryService._();

  /// أقصى عدد إدخالات محفوظة لكل حركة (الأقدم يُحذف أولًا)
  static const int maxEntriesPerTx = 300;

  static const Duration _annotationTtl = Duration(seconds: 15);
  static const Duration _flushDelay = Duration(milliseconds: 150);
  static const int _flushThreshold = 200;
  static const Duration _orphanRetention = Duration(days: 60);

  /// تاريخ بدء تسجيل التعديلات (مفاتيح تبدأ بـ __ ليست حركات)
  static const String _sinceKey = '__since__';

  /// لقطة كل حركة حسب مفتاح Hive
  static final Map<dynamic, _TxState> _states = {};

  /// إدخالات لم تُكتب بعد، وإدخالات قيد الكتابة (مفتاح = معرّف الحركة كنص)
  static final _RawEntries _pending = {};
  static _RawEntries _inFlight = {};
  static final Map<int, _Annotation> _annotations = {};

  static StreamSubscription<BoxEvent>? _sub;
  static AppLifecycleListener? _lifecycle;
  static Timer? _flushTimer;
  static Future<void> _flushChain = Future<void>.value();
  static int _pendingCount = 0;
  static int _suspended = 0;
  static bool _started = false;
  static DateTime? _since;

  /// يزداد مع كل تغيير في السجل (لتحديث صفحة السجل مباشرة)
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// تعديلات الاسم/المبلغ/العملة لكل حركة (الأحدث أولًا)، تُحمَّل مرة وحدة
  /// ثم تتحدث مع كل تسجيل. null = لم تُحمَّل بعد.
  static Map<int, List<TxHistoryEntry>>? _keyEdits;

  /// ما يُسجَّل أثناء التحميل (حتى لا يضيع)
  static Map<int, List<TxHistoryEntry>>? _keyEditsLive;
  static Future<void>? _keyEditsLoad;

  /// يزداد عند تحميل تعديلات الاسم/المبلغ/العملة أو تغيّرها
  static final ValueNotifier<int> keyEditsRevision = ValueNotifier<int>(0);

  static bool get _historyOpen =>
      Hive.isBoxOpen(DatabaseService.txHistoryBoxName);

  static bool get _ready =>
      _historyOpen && Hive.isBoxOpen(DatabaseService.transactionsBoxName);

  static LazyBox<dynamic> get _box =>
      Hive.lazyBox<dynamic>(DatabaseService.txHistoryBoxName);

  static String _keyOf(int txId) => '$txId';

  static bool _isMetaKey(Object? key) => '$key'.startsWith('__');

  /// منذ متى يُسجَّل سجل التعديلات (التعديلات الأقدم غير مسجلة)
  static DateTime? get trackingSince => _since;

  // ===========================
  // التشغيل
  // ===========================

  /// يبدأ المراقبة (مرة واحدة بعد فتح الصناديق)
  static void start() {
    if (_started || !_ready) return;
    _started = true;
    unawaited(_loadSince());
    _rebuildStates();
    _sub = DatabaseService.transactionsBox.watch().listen(
      _onEvent,
      onError: (Object e) => debugPrint('TxHistory watch error: $e'),
    );
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) unawaited(flush());
      },
    );
    unawaited(
      Future<void>.delayed(const Duration(seconds: 8), _cleanupOrphans),
    );
  }

  static Future<void> stop() async {
    await flush();
    await _sub?.cancel();
    _sub = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _states.clear();
    _started = false;
  }

  static Future<void> _loadSince() async {
    try {
      if (_box.containsKey(_sinceKey)) {
        _since = TxHistoryFormatter.parseDate(await _box.get(_sinceKey));
      }
      if (_since == null) {
        _since = DateTime.now();
        await _box.put(_sinceKey, _since!.toIso8601String());
      }
      revision.value++;
    } catch (e) {
      debugPrint('TxHistory since error: $e');
    }
  }

  static void _rebuildStates() {
    _states.clear();
    final box = DatabaseService.transactionsBox;
    for (final key in box.keys) {
      final t = box.get(key);
      if (t != null) _states[key] = _TxState(t.id, txSnapshot(t));
    }
  }

  /// أوقف التسجيل مؤقتًا (مثل استعادة نسخة احتياطية تستبدل كل الحركات)
  static Future<void> suspend() async {
    _suspended++;
    await flush();
  }

  static Future<void> resume() async {
    // نترك أحداث العملية الموقوفة (تصل لاحقًا بشكل غير متزامن) تمر أولًا
    await Future<void>.delayed(Duration.zero);
    if (_suspended > 0) _suspended--;
    if (_suspended == 0 && _started) _rebuildStates();
    revision.value++;
  }

  /// اذكر مصدر التعديل القادم لهذه الحركات (يظهر في السجل)، مثل «تعديل يدوي».
  /// يُستدعى قبل الحفظ مباشرة، ويسري على أول حفظ لكل حركة خلال ثوانٍ.
  /// [at]: وقت التعديل الذي يظهر في السجل بدل وقت الحفظ، مثل وقت الرسالة عند
  /// التعديل أو الإلغاء من تحليل الرسائل.
  static void annotate(Iterable<int> txIds, String source, {DateTime? at}) {
    final now = DateTime.now();
    final until = now.add(_annotationTtl);
    for (final id in txIds) {
      _annotations[id] = _Annotation(source, until, at);
    }
    if (_annotations.length > 5000) {
      _annotations.removeWhere((_, a) => now.isAfter(a.until));
    }
  }

  static _Annotation? _takeAnnotation(int txId) {
    final a = _annotations.remove(txId);
    if (a == null || DateTime.now().isAfter(a.until)) return null;
    return a;
  }

  /// هل للحركة سجل تعديلات؟ (فحص سريع بدون قراءة من القرص)
  static bool hasHistory(int txId) => _historyOpen && _hasHistory(txId);

  // ===========================
  // التسجيل
  // ===========================

  static void _onEvent(BoxEvent ev) {
    if (_suspended > 0) return;
    try {
      final now = DateTime.now();
      if (ev.deleted) {
        final prev = _states.remove(ev.key);
        if (prev == null) return;
        final v = prev.values;
        final ann = _takeAnnotation(prev.id);
        _record(
          prev.id,
          TxHistoryEntry(
            at: ann?.at ?? now,
            kind: TxHistoryKind.deleted,
            source: ann?.source,
            ctx: {
              'name': v[TxField.beneficiary.index],
              'amount': v[TxField.amount.index],
              'c': v[TxField.currency.index],
            },
          ),
        );
        return;
      }

      final t = ev.value;
      if (t is! TransactionModel) return;
      final after = txSnapshot(t);
      final prev = _states[ev.key];
      _states[ev.key] = _TxState(t.id, after);
      final ann = _takeAnnotation(t.id);
      final source = ann?.source;
      final at = ann?.at ?? now;

      if (prev == null || prev.id != t.id) {
        // حركة جديدة: لا شيء للتسجيل، إلا إذا كان لها سجل سابق، أي أنها
        // حركة محذوفة تمت استعادتها (التراجع يعيدها بنفس المعرّف)
        if (_hasHistory(t.id)) {
          _record(
            t.id,
            TxHistoryEntry(
              at: at,
              kind: TxHistoryKind.restored,
              source: source,
            ),
          );
        }
        return;
      }

      final changes = diffTxSnapshots(
        prev.values,
        after,
        accountLabel: _accountName,
      );
      if (changes.isEmpty) return;
      final c2 = t.secondCurrency?.trim() ?? '';
      _record(
        t.id,
        TxHistoryEntry(
          at: at,
          kind: TxHistoryKind.edit,
          source: source,
          changes: changes,
          ctx: {
            'c': t.currency,
            if (t.hasSecondAmount && c2.isNotEmpty) 'c2': c2,
          },
        ),
      );
    } catch (e) {
      debugPrint('TxHistory record error: $e');
    }
  }

  static bool _hasHistory(int txId) {
    final key = _keyOf(txId);
    return _pending.containsKey(key) ||
        _inFlight.containsKey(key) ||
        _box.containsKey(key);
  }

  static String? _accountName(int accountId) {
    try {
      for (final a in DatabaseService.accountsBox.values) {
        if (a.id == accountId) return a.name;
      }
    } catch (_) {}
    return null;
  }

  static void _record(int txId, TxHistoryEntry e) {
    (_pending[_keyOf(txId)] ??= <Map<String, dynamic>>[]).add(e.toMap());
    _pendingCount++;
    revision.value++;
    if (e.isKeyEdit) {
      final loaded = _keyEdits;
      final target = loaded ?? _keyEditsLive;
      if (target != null) {
        (target[txId] ??= <TxHistoryEntry>[]).insert(0, e);
        if (loaded != null) keyEditsRevision.value++;
      }
    }
    if (_pendingCount >= _flushThreshold) {
      unawaited(flush());
    } else {
      _flushTimer?.cancel();
      _flushTimer = Timer(_flushDelay, () => unawaited(flush()));
    }
  }

  // ===========================
  // تعديلات الاسم/المبلغ/العملة (لتتبّع مصدر الحركة)
  // ===========================

  /// هل حُمّلت تعديلات كل الحركات؟
  static bool get keyEditsLoaded => _keyEdits != null;

  /// تعديلات الاسم/المبلغ/العملة لكل حركة (الأحدث أولًا). فارغة قبل التحميل.
  static Map<int, List<TxHistoryEntry>> get keyEdits => _keyEdits ?? const {};

  /// يحمّل تعديلات كل الحركات مرة وحدة (قراءة من القرص بالخلفية)
  static Future<void> ensureKeyEdits() => _keyEditsLoad ??= _loadKeyEdits();

  static String _entrySig(TxHistoryEntry e) =>
      '${e.at.millisecondsSinceEpoch}|${e.kind.name}|${e.changes.join(',')}';

  static Future<void> _loadKeyEdits() async {
    final live = <int, List<TxHistoryEntry>>{};
    _keyEditsLive = live;
    final out = <int, List<TxHistoryEntry>>{};
    try {
      if (_historyOpen) {
        for (final key in _box.keys.toList()) {
          if (_isMetaKey(key)) continue;
          final id = int.tryParse('$key');
          if (id == null) continue;
          Object? raw;
          try {
            raw = await _box.get(key);
          } catch (_) {
            continue;
          }
          if (raw is! List) continue;
          final list = <TxHistoryEntry>[];
          for (final m in raw.reversed) {
            if (m is! Map) continue;
            try {
              final e = TxHistoryEntry.fromMap(m);
              if (e.isKeyEdit) list.add(e);
            } catch (_) {}
          }
          if (list.isNotEmpty) out[id] = list;
        }
        // غير المحفوظ بعد (الأحدث)
        for (final src in [_inFlight, _pending]) {
          src.forEach((k, v) {
            final id = int.tryParse(k);
            if (id == null) return;
            for (final m in v) {
              try {
                final e = TxHistoryEntry.fromMap(m);
                if (!e.isKeyEdit) continue;
                final list = out[id] ??= <TxHistoryEntry>[];
                final sig = _entrySig(e);
                if (list.any((x) => _entrySig(x) == sig)) continue;
                list.insert(0, e);
              } catch (_) {}
            }
          });
        }
      }
    } catch (e) {
      debugPrint('TxHistory key edits error: $e');
    }
    // ما سُجّل أثناء التحميل
    live.forEach((id, entries) {
      final list = out[id] ??= <TxHistoryEntry>[];
      for (final e in entries.reversed) {
        final sig = _entrySig(e);
        if (list.any((x) => _entrySig(x) == sig)) continue;
        list.insert(0, e);
      }
    });
    _keyEdits = out;
    _keyEditsLive = null;
    keyEditsRevision.value++;
  }

  static void _resetKeyEdits() {
    _keyEdits = null;
    _keyEditsLive = null;
    _keyEditsLoad = null;
  }

  /// اكتب الإدخالات المعلّقة الآن
  static Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushChain = _flushChain.then((_) => _writePending());
    return _flushChain;
  }

  static Future<void> _writePending() async {
    if (_pending.isEmpty || !_historyOpen) return;
    final batch = Map<String, List<Map<String, dynamic>>>.of(_pending);
    _pending.clear();
    _pendingCount = 0;
    _inFlight = batch;
    try {
      final updates = <String, dynamic>{};
      for (final e in batch.entries) {
        final stored = _box.containsKey(e.key) ? await _box.get(e.key) : null;
        final list = <dynamic>[if (stored is List) ...stored, ...e.value];
        if (list.length > maxEntriesPerTx) {
          list.removeRange(0, list.length - maxEntriesPerTx);
        }
        updates[e.key] = list;
      }
      await _box.putAll(updates);
    } catch (e) {
      debugPrint('TxHistory flush error: $e');
    } finally {
      _inFlight = {};
    }
  }

  // ===========================
  // القراءة
  // ===========================

  /// سجل الحركة (الأحدث تسجيلًا أولًا؛ للعرض حسب الوقت: [sortEntriesByTime])
  static Future<List<TxHistoryEntry>> entriesFor(int txId) async {
    if (!_historyOpen) return const [];
    final key = _keyOf(txId);
    // نأخذ ما في الذاكرة ونبدأ القراءة من القرص في نفس اللحظة (get يثبّت
    // موضع القيمة فورًا)؛ لو انتهت كتابة دفعة أثناء القراءة لا نفقدها
    final unsaved = <dynamic>[...?_inFlight[key], ...?_pending[key]];
    Object? stored;
    try {
      if (_box.containsKey(key)) stored = await _box.get(key);
    } catch (e) {
      debugPrint('TxHistory read error: $e');
    }
    final raw = <dynamic>[if (stored is List) ...stored, ...unsaved];
    // دفعة قيد الكتابة قد تظهر في المحفوظ أيضًا: نمنع التكرار
    final seen = <String>{};
    final out = <TxHistoryEntry>[];
    for (final m in raw.reversed) {
      if (m is! Map) continue;
      if (!seen.add('${m['at']}|${m['k']}|${m['ch']}|${m['ctx']}')) continue;
      try {
        out.add(TxHistoryEntry.fromMap(m));
      } catch (_) {}
    }
    return out;
  }

  // ===========================
  // النسخ الاحتياطي
  // ===========================

  static Future<Map<String, dynamic>> exportAll() async {
    await flush();
    final out = <String, dynamic>{};
    if (!_historyOpen) return out;
    for (final key in _box.keys.toList()) {
      try {
        final v = await _box.get(key);
        if (_isMetaKey(key)) {
          if (v != null) out['$key'] = v;
        } else if (v is List && v.isNotEmpty) {
          out['$key'] = v;
        }
      } catch (e) {
        debugPrint('TxHistory export error: $e');
      }
    }
    return out;
  }

  /// يستبدل السجل كاملًا بما في النسخة (نسخة قديمة بدون سجل = سجل فارغ،
  /// حتى لا تبقى تعديلات لاحقة لا تطابق الحركات المستعادة).
  static Future<void> importAll(Object? raw) async {
    if (!_historyOpen) return;
    await flush();
    _resetKeyEdits();
    await _box.clear();
    // بداية التسجيل = بداية سجل النسخة، أو الآن إن لم يكن فيها سجل
    final since = raw is Map
        ? TxHistoryFormatter.parseDate(raw[_sinceKey])
        : null;
    _since = since ?? DateTime.now();
    await _box.put(_sinceKey, _since!.toIso8601String());
    if (raw is! Map) {
      unawaited(ensureKeyEdits());
      return;
    }
    final updates = <String, dynamic>{};
    raw.forEach((k, v) {
      if (_isMetaKey(k) || v is! List) return;
      final list = [
        for (final m in v)
          if (m is Map) m,
      ];
      if (list.isEmpty) return;
      updates['$k'] = list.length > maxEntriesPerTx
          ? list.sublist(list.length - maxEntriesPerTx)
          : list;
    });
    if (updates.isNotEmpty) await _box.putAll(updates);
    unawaited(ensureKeyEdits());
  }

  // ===========================
  // التنظيف
  // ===========================

  /// حذف سجلات حركات محذوفة منذ مدة طويلة
  static Future<void> _cleanupOrphans() async {
    if (!_ready || _suspended > 0 || !_started) return;
    try {
      final alive = <String>{for (final s in _states.values) _keyOf(s.id)};
      final cutoff = DateTime.now().subtract(_orphanRetention);
      final stale = <dynamic>[];
      for (final key in _box.keys.toList()) {
        if (_isMetaKey(key)) continue;
        final k = '$key';
        if (alive.contains(k) || _pending.containsKey(k)) continue;
        final list = await _box.get(key);
        DateTime? last;
        if (list is List && list.isNotEmpty && list.last is Map) {
          last = TxHistoryFormatter.parseDate((list.last as Map)['at']);
        }
        if (last == null || last.isBefore(cutoff)) stale.add(key);
      }
      if (stale.isEmpty || _suspended > 0) return;
      // قد تُستعاد حركة أثناء الفحص: نعيد التحقق قبل الحذف
      final aliveNow = <String>{for (final s in _states.values) _keyOf(s.id)};
      stale.removeWhere(
        (k) => aliveNow.contains('$k') || _pending.containsKey('$k'),
      );
      if (stale.isNotEmpty) await _box.deleteAll(stale);
    } catch (e) {
      debugPrint('TxHistory cleanup error: $e');
    }
  }
}
