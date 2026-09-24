// lib/services/detection/receive_matching.dart
// -------------------------------------------------------------
// مطابقة رسائل التسليم مع الحركات المضافة + الاختيار التلقائي.
// (ملف Dart نقي بدون Flutter حتى يمكن اختباره مباشرة)
//
// 1) مفاتيح الاسم: تطبيع عربي موحّد مع دمج الأسماء المركبة
//    (عبد الله = عبدالله ، أبو بكر = أبوبكر ، نور الدين = نورالدين)،
//    وتجاهل «بن/ابن/بنت» بين اسمين، والتطويل، والحروف الفارسية.
// 2) فهرس الحركات المعلّقة: يعطي لكل حركة درجة تطابق الاسم
//    (3 = مطابق تمامًا ، 2 = جزء متصل من الاسم أو ظاهر حرفيًا في الرسالة ،
//    1 = كلمتان مشتركتان) مع قوة التطابق والكلمات الزائدة.
// 3) هوية العملة: الرموز المترادفة ($ / USD / دولار) عملة واحدة.
// 4) الاختيار التلقائي لكل الفقاعات دفعة واحدة:
//    - المطابقة المؤكدة الأقوى تُختار دائمًا.
//    - الحركات «التوائم» (نفس الاسم والمبلغ والعملة) تُوزّع على الرسائل
//      بالترتيب، الأقدم أولًا.
//    - لا تُعطى حركة لفقاعتين، والأقوى مطابقة يسبق على نفس الحركة.
//    - لا تنزل فقاعة إلى مرشح أضعف إذا أُخذ أفضل مرشحيها (رسالة مكررة).
// -------------------------------------------------------------

import 'currency_detector.dart' as cd;
import 'text_tokens.dart' as tt;

// =============================================================
// 1) مفاتيح الاسم
// =============================================================

/// كلمات تُلصق بالكلمة التي بعدها: «عبد الله» = «عبدالله»، «أبو بكر» = «أبوبكر».
const Set<String> _joinWithNext = {'عبد', 'ابو'};

/// كلمات تُلصق بالكلمة التي قبلها: «نور الدين» = «نورالدين»، «فتح الله».
const Set<String> _joinWithPrevious = {'الله', 'الدين'};

/// كلمات النسب بين اسمين: «محمد بن علي» = «محمد علي».
const Set<String> _lineageWords = {'بن', 'ابن', 'بنت'};

/// مفتاح مقارنة لكلمة واحدة من اسم.
String nameKeyOf(String token) {
  var k = tt.matchKey(token);
  if (k.isEmpty) return k;
  k = k
      .replaceAll('\u0640', '') // تطويل
      .replaceAll('\u06CC', 'ي') // ی فارسية
      .replaceAll('\u06A9', 'ك') // ک فارسية
      .replaceAll('\u06D5', 'ه'); // ە
  return k;
}

/// دمج الأسماء المركبة وحذف كلمات النسب الواقعة بين اسمين.
List<String> compactNameKeys(List<String> keys) {
  final out = <String>[];
  for (int i = 0; i < keys.length; i++) {
    var k = keys[i];
    if (_lineageWords.contains(k) && out.isNotEmpty && i + 1 < keys.length) {
      continue;
    }
    if (_joinWithNext.contains(k) && i + 1 < keys.length) {
      i++;
      k = '$k${keys[i]}';
    }
    if (_joinWithPrevious.contains(k) && out.isNotEmpty) {
      out[out.length - 1] = '${out.last}$k';
      continue;
    }
    out.add(k);
  }
  return out;
}

/// مفاتيح الاسم من توكنات جاهزة (مثل توكنات سطر من الرسالة).
List<String> nameKeysOfTokens(Iterable<String> tokens) {
  final keys = <String>[];
  for (final t in tokens) {
    final k = nameKeyOf(t);
    if (k.isNotEmpty) keys.add(k);
  }
  return compactNameKeys(keys);
}

/// مفاتيح الاسم من نص.
List<String> nameKeysOf(String text) =>
    nameKeysOfTokens(tt.tokensFromLine(text));

/// هل [needle] يظهر كتسلسل متصل داخل [hay]؟
bool containsKeySeq(List<String> hay, List<String> needle) {
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

// =============================================================
// 2) تطابق الاسم مع الحركات المعلّقة
// =============================================================

/// نتيجة تطابق اسم الرسالة مع اسم حركة.
class NameMatch {
  /// 3 = الاسم مطابق تمامًا ، 2 = جزء متصل (أو ظاهر حرفيًا في الرسالة) ،
  /// 1 = كلمتان مشتركتان على الأقل.
  final int tier;

  /// عدد الكلمات المتطابقة.
  final int strength;

  /// عدد الكلمات الزائدة في أحد الاسمين (الأقل أفضل).
  final int extra;

  const NameMatch(this.tier, this.strength, this.extra);

  /// موجب إذا كانت هذه النتيجة أقوى من [other].
  int compareTo(NameMatch other) {
    if (tier != other.tier) return tier.compareTo(other.tier);
    if (strength != other.strength) return strength.compareTo(other.strength);
    return other.extra.compareTo(extra);
  }

  @override
  String toString() => 'NameMatch($tier, $strength, $extra)';
}

/// فهرس أسماء الحركات المعلّقة للمطابقة السريعة.
class PendingNameIndex {
  final Map<int, List<String>> keysById = {};
  final Map<String, List<int>> _byFull = {};
  final Map<String, List<int>> _byFirst = {};
  final Map<String, List<int>> _byToken = {};

  PendingNameIndex(Map<int, String> namesById) {
    namesById.forEach((id, name) {
      final keys = nameKeysOf(name);
      if (keys.isEmpty) return;
      keysById[id] = keys;
      (_byFull[keys.join(' ')] ??= []).add(id);
      (_byFirst[keys.first] ??= []).add(id);
      for (final k in keys.toSet()) {
        if (k.length >= 2) (_byToken[k] ??= []).add(id);
      }
    });
  }

  /// مفتاح الاسم الكامل لحركة (بعد التطبيع والدمج).
  String fullKeyOf(int id) => keysById[id]?.join(' ') ?? '';

  /// درجة تطابق كل حركة مرشحة مع الرسالة.
  /// [nameKeys]: مفاتيح الاسم المعتمد للرسالة (المكتشف أو اليدوي).
  /// [lineKeys]: مفاتيح كل سطر من الرسالة (لاكتشاف اسم الحركة الظاهر حرفيًا).
  Map<int, NameMatch> match({
    required List<String> nameKeys,
    List<List<String>> lineKeys = const [],
  }) {
    final out = <int, NameMatch>{};
    void bump(int id, NameMatch m) {
      final cur = out[id];
      if (cur == null || m.compareTo(cur) > 0) out[id] = m;
    }

    if (nameKeys.isNotEmpty) {
      for (final id in _byFull[nameKeys.join(' ')] ?? const <int>[]) {
        bump(id, NameMatch(3, nameKeys.length, 0));
      }
      final overlap = <int, int>{};
      final contained = <int>{};
      final notContained = <int>{};
      for (final k in nameKeys.toSet()) {
        for (final id in _byToken[k] ?? const <int>[]) {
          // التحقق من الاحتواء مرة واحدة لكل حركة (لا لكل كلمة مشتركة)
          if (contained.contains(id)) continue;
          if (notContained.contains(id)) {
            final n = (overlap[id] ?? 0) + 1;
            overlap[id] = n;
            if (n >= 2) bump(id, NameMatch(1, n, 0));
            continue;
          }
          final keys = keysById[id]!;
          if (containsKeySeq(nameKeys, keys)) {
            contained.add(id);
            // اسم الحركة جزء متصل من اسم الرسالة
            bump(id, NameMatch(2, keys.length, nameKeys.length - keys.length));
          } else if (containsKeySeq(keys, nameKeys)) {
            contained.add(id);
            // اسم الرسالة جزء متصل من اسم الحركة
            bump(
              id,
              NameMatch(2, nameKeys.length, keys.length - nameKeys.length),
            );
          } else {
            notContained.add(id);
            overlap[id] = (overlap[id] ?? 0) + 1;
          }
        }
      }
    }

    // اسم الحركة ظاهر حرفيًا (كاملًا) في نص الرسالة، حتى لو لم يُكتشف الاسم
    for (final keys in lineKeys) {
      for (int p = 0; p < keys.length; p++) {
        final list = _byFirst[keys[p]];
        if (list == null) continue;
        for (final id in list) {
          final txKeys = keysById[id]!;
          if (p + txKeys.length > keys.length) continue;
          var ok = true;
          for (int j = 1; j < txKeys.length; j++) {
            if (keys[p + j] != txKeys[j]) {
              ok = false;
              break;
            }
          }
          if (ok) bump(id, NameMatch(2, txKeys.length, 0));
        }
      }
    }
    return out;
  }
}

// =============================================================
// 3) هوية العملة
// =============================================================

/// مقارنة العملات مع اعتبار الرموز المترادفة في الإعدادات عملة واحدة:
/// كل المفاتيح التي تشير إلى نفس الاسم ($ و USD ← دولار) متطابقة، وكذلك
/// عائلات العملات المعروفة (USD / EUR / SYP).
class CurrencyMatcher {
  final Map<String, String> currencyMap;
  final Map<String, Set<String>> _cache = {};

  CurrencyMatcher(this.currencyMap);

  static final RegExp _spaces = RegExp(r'\s+');

  static String _norm(String s) =>
      tt.normalizeArabic(s).toLowerCase().replaceAll(_spaces, '');

  /// معرّفات العملة: اسمها في الإعدادات وعائلتها. فارغة = عملة غير معروفة.
  Set<String> idsOf(String? raw) {
    if (raw == null) return const {};
    final t = _norm(raw);
    if (t.isEmpty) return const {};
    return _cache.putIfAbsent(t, () {
      final ids = <String>{};
      for (final e in currencyMap.entries) {
        if (_norm(e.key) == t || _norm(e.value) == t) {
          final v = _norm(e.value);
          if (v.isNotEmpty) ids.add('n:$v');
          final f = cd.currencyFamilyOf(e.key) ?? cd.currencyFamilyOf(e.value);
          if (f != null) ids.add('f:$f');
        }
      }
      final f = cd.currencyFamilyOf(raw);
      if (f != null) ids.add('f:$f');
      return ids;
    });
  }

  /// true = نفس العملة ، false = عملتان معروفتان مختلفتان ،
  /// null = إحداهما غير معروفة (لا نمنع المطابقة بسببها).
  bool? compare(String? a, String? b) {
    final ia = idsOf(a);
    final ib = idsOf(b);
    if (ia.isEmpty || ib.isEmpty) return null;
    return ia.any(ib.contains);
  }

  /// مفتاح ثابت للعملة (لتجميع الحركات المتطابقة).
  String canonicalOf(String? raw) {
    final ids = idsOf(raw);
    for (final id in ids) {
      if (id.startsWith('f:')) return id;
    }
    if (ids.isNotEmpty) return ids.first;
    return raw == null ? '' : _norm(raw);
  }
}

// =============================================================
// 4) الاختيار التلقائي
// =============================================================

/// مرشح مؤكد (الاسم + المبلغ + العملة) قابل للاختيار التلقائي.
class AutoPick {
  final int txId;
  final NameMatch name;

  /// العملة معروفة ومطابقة (أفضل من عملة غير معروفة).
  final bool currencyExact;

  /// حركات بنفس المفتاح متطابقة تمامًا (نفس الاسم والمبلغ والعملة)،
  /// واختيار أي واحدة منها صحيح.
  final String twinKey;

  /// أُضيفت الحركة قبل وقت الرسالة (أو لا يوجد وقت للرسالة).
  final bool beforeMessage;

  /// تاريخ الحركة (الأقدم يُختار أولًا بين التوائم).
  final int dateMillis;

  const AutoPick({
    required this.txId,
    required this.name,
    this.currencyExact = false,
    this.twinKey = '',
    this.beforeMessage = true,
    this.dateMillis = 0,
  });

  /// موجب إذا كان [a] أقوى من [b].
  static int compareQuality(AutoPick a, AutoPick b) {
    final n = a.name.compareTo(b.name);
    if (n != 0) return n;
    if (a.currencyExact != b.currencyExact) return a.currencyExact ? 1 : -1;
    return 0;
  }

  /// ترتيب التفضيل بين مرشحين بنفس القوة (سالب = [a] أولًا):
  /// ما أُضيف قبل وقت الرسالة، ثم الأقدم.
  static int compareOrder(AutoPick a, AutoPick b) {
    if (a.beforeMessage != b.beforeMessage) return a.beforeMessage ? -1 : 1;
    final d = a.dateMillis.compareTo(b.dateMillis);
    if (d != 0) return d;
    return a.txId.compareTo(b.txId);
  }

  static bool areTwins(AutoPick a, AutoPick b) =>
      a.txId == b.txId || (a.twinKey.isNotEmpty && a.twinKey == b.twinKey);
}

/// طلب اختيار لفقاعة واحدة.
class AutoSelectRequest {
  /// المرشحات المؤكدة فقط.
  final List<AutoPick> picks;

  /// الاختيار التلقائي السابق لهذه الفقاعة (يبقى إن بقي صالحًا).
  final int? previous;

  const AutoSelectRequest({required this.picks, this.previous});
}

enum AutoSelectOutcome {
  /// لا توجد مطابقة مؤكدة.
  none,

  /// تم الاختيار.
  selected,

  /// أكثر من مطابقة مؤكدة بنفس القوة لحركات مختلفة — تحتاج اختيارًا يدويًا.
  ambiguous,

  /// أفضل مطابقة لهذه الفقاعة محجوزة (بفقاعة أخرى أو مستلمة).
  bestTaken,
}

class AutoSelectDecision {
  final AutoSelectOutcome outcome;
  final int? txId;

  /// عدد الحركات المتطابقة تمامًا المتاحة لهذه الفقاعة (1 = بلا تكرار).
  final int twins;

  const AutoSelectDecision(this.outcome, {this.txId, this.twins = 0});

  @override
  String toString() => 'AutoSelectDecision($outcome, $txId, twins: $twins)';
}

class _Claim {
  final int req;
  final AutoPick pick;
  final bool isPrevious;
  const _Claim(this.req, this.pick, this.isPrevious);
}

/// يوزّع الحركات على الفقاعات دفعة واحدة. [reserved]: حركات لا يجوز
/// اختيارها تلقائيًا (مختارة يدويًا في فقاعة أخرى، أو مستلمة).
List<AutoSelectDecision> autoSelect(
  List<AutoSelectRequest> requests, {
  Set<int> reserved = const {},
}) {
  final n = requests.length;
  final decisions = List<AutoSelectDecision?>.filled(n, null);
  final taken = <int>{...reserved};

  // أفضل قوة لكل فقاعة (بغض النظر عن الحجز)
  final best = <AutoPick?>[
    for (final r in requests)
      r.picks.isEmpty
          ? null
          : r.picks.reduce((a, b) => AutoPick.compareQuality(b, a) > 0 ? b : a),
  ];

  int twinCount(int i, AutoPick p) {
    var c = 0;
    for (final q in requests[i].picks) {
      if (q.txId == p.txId ||
          (AutoPick.compareQuality(q, p) == 0 && AutoPick.areTwins(q, p))) {
        c++;
      }
    }
    return c;
  }

  final claims = <_Claim>[
    for (int i = 0; i < n; i++)
      for (final p in requests[i].picks)
        _Claim(i, p, requests[i].previous == p.txId),
  ];
  claims.sort((a, b) {
    // الأقوى أولًا، ثم الاختيار السابق (ثبات)، ثم ترتيب الرسائل، ثم الأقدم
    final q = AutoPick.compareQuality(b.pick, a.pick);
    if (q != 0) return q;
    if (a.isPrevious != b.isPrevious) return a.isPrevious ? -1 : 1;
    if (a.req != b.req) return a.req.compareTo(b.req);
    return AutoPick.compareOrder(a.pick, b.pick);
  });

  for (final c in claims) {
    final i = c.req;
    if (decisions[i] != null) continue;
    if (taken.contains(c.pick.txId)) continue;
    if (AutoPick.compareQuality(c.pick, best[i]!) < 0) {
      // كل أفضل مرشحي هذه الفقاعة محجوزة: لا ننزل إلى مرشح أضعف
      decisions[i] = const AutoSelectDecision(AutoSelectOutcome.bestTaken);
      continue;
    }
    if (!c.isPrevious) {
      final rivals = requests[i].picks.where(
        (p) =>
            p.txId != c.pick.txId &&
            !taken.contains(p.txId) &&
            AutoPick.compareQuality(p, c.pick) == 0 &&
            !AutoPick.areTwins(p, c.pick),
      );
      if (rivals.isNotEmpty) {
        decisions[i] = const AutoSelectDecision(AutoSelectOutcome.ambiguous);
        continue;
      }
    }
    taken.add(c.pick.txId);
    decisions[i] = AutoSelectDecision(
      AutoSelectOutcome.selected,
      txId: c.pick.txId,
      twins: twinCount(i, c.pick),
    );
  }

  // فرصة ثانية للفقاعات الملتبسة: ربما أخذت فقاعات أخرى المرشحات المنافسة
  for (int i = 0; i < n; i++) {
    if (decisions[i]?.outcome != AutoSelectOutcome.ambiguous) continue;
    final free =
        requests[i].picks
            .where(
              (p) =>
                  !taken.contains(p.txId) &&
                  AutoPick.compareQuality(p, best[i]!) == 0,
            )
            .toList()
          ..sort(AutoPick.compareOrder);
    if (free.isEmpty) {
      decisions[i] = const AutoSelectDecision(AutoSelectOutcome.bestTaken);
      continue;
    }
    if (free.every((p) => AutoPick.areTwins(p, free.first))) {
      taken.add(free.first.txId);
      decisions[i] = AutoSelectDecision(
        AutoSelectOutcome.selected,
        txId: free.first.txId,
        twins: twinCount(i, free.first),
      );
    }
  }

  return [
    for (int i = 0; i < n; i++)
      decisions[i] ??
          // لم يُحسم: إما بلا مرشحات، أو كل مرشحاتها محجوزة
          (requests[i].picks.isEmpty
              ? const AutoSelectDecision(AutoSelectOutcome.none)
              : const AutoSelectDecision(AutoSelectOutcome.bestTaken)),
  ];
}
