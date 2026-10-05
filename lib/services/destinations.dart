// lib/services/destinations.dart
// -------------------------------------------------------------
// الوجهات (لحركات الشركات بس):
//  • كل وجهة إلها اسم واختصارات تابعة إلها (متل العملات بالضبط)، والبرنامج
//    بيتعرف عليها من نص الرسالة وقت الإضافة — حتى لو كانت ملزقة بحرف جر
//    («لحلب»، «بتركيا»، «والشام»، «للشام»).
//  • المستخدم بيحدد إذا الوجهة تابعة لمكتب من المكاتب أو لا (ويمكن يحدد
//    أي مكاتب بالضبط).
//  • التتبّع: وجهة تابعة لمكتب = لازم توصل لمكتب (وإلا تنبيه «ما راحت
//    لمكتب»). وجهة مو تابعة لمكتب = ما منستناها، وإذا لقينا إلها حركة مكتب
//    مطابقة = تحذير «يمكن تغيّر المسار».
//
// ملف Dart نقي (بدون Flutter) حتى يمكن استعماله بخيط الحساب واختباره.
// -------------------------------------------------------------

import '../models.dart';
import 'detection/text_tokens.dart'
    show matchKey, normalizeText, tokensFromLine;

/// وجهة وحدة مع اختصاراتها
class Destination {
  final String name;
  final List<String> aliases;

  /// تابعة لمكتب من المكاتب؟
  final bool toOffice;

  /// المكاتب المحددة للوجهة (فاضية = أي مكتب)
  final List<int> officeIds;

  const Destination({
    required this.name,
    this.aliases = const [],
    this.toOffice = false,
    this.officeIds = const [],
  });

  /// مفتاح المقارنة (بعد توحيد الهمزات والتاء المربوطة...)
  String get key => destinationKey(name);

  bool allowsOffice(int accountId) =>
      toOffice && (officeIds.isEmpty || officeIds.contains(accountId));

  Map<String, dynamic> infoMap() => {
    'office': toOffice,
    if (officeIds.isNotEmpty) 'accounts': List<int>.of(officeIds),
  };
}

/// مفتاح مقارنة اسم الوجهة
String destinationKey(String? name) => normalizeText(name ?? '');

/// مكان ذكر وجهة بالرسالة
class DestinationHit {
  final String name;

  /// الكلمة/العبارة كما انكتبت بالإعدادات (الاسم أو الاختصار)
  final String phrase;
  final int line;
  final int start;
  final int length;

  const DestinationHit({
    required this.name,
    required this.phrase,
    required this.line,
    required this.start,
    required this.length,
  });
}

/// نتيجة كشف الوجهة برسالة
class DestinationDetection {
  /// الوجهات المذكورة بترتيب ظهورها (بدون تكرار)
  final List<String> names;
  final List<DestinationHit> hits;

  const DestinationDetection(this.names, this.hits);

  static const DestinationDetection none = DestinationDetection([], []);

  bool get isEmpty => names.isEmpty;

  /// وجهة وحدة واضحة (null إذا ما في، أو في أكتر من وحدة)
  String? get single => names.length == 1 ? names.first : null;

  bool get ambiguous => names.length > 1;

  /// الكلمة يلي انكشفت فيها الوجهة [name] (للشرح)
  String? phraseOf(String name) {
    for (final h in hits) {
      if (h.name == name) return h.phrase;
    }
    return null;
  }
}

class _Phrase {
  final List<String> keys;
  final Destination dest;
  final String original;
  const _Phrase(this.keys, this.dest, this.original);
}

/// كل الوجهات (من الإعدادات) مع أدوات البحث والكشف
class DestinationBook {
  final List<Destination> items;
  final Map<String, Destination> _byKey;
  final Map<String, List<_Phrase>> _byFirst;

  DestinationBook._(this.items, this._byKey, this._byFirst);

  static final DestinationBook empty = DestinationBook._(const [], {}, {});

  factory DestinationBook.fromSettings(Settings? s) {
    if (s == null) return empty;
    return DestinationBook.fromMaps(s.destinationMap, s.destinationInfo);
  }

  /// [aliasMap]: اختصار ← اسم الوجهة. [info]: اسم الوجهة ← معلوماتها.
  factory DestinationBook.fromMaps(
    Map<String, String> aliasMap,
    Map<String, dynamic> info,
  ) {
    final names = <String>[];
    final seen = <String>{};
    void addName(String raw) {
      final n = raw.trim();
      if (n.isEmpty) return;
      final k = destinationKey(n);
      if (k.isEmpty || !seen.add(k)) return;
      names.add(n);
    }

    for (final n in info.keys) {
      addName(n);
    }
    for (final n in aliasMap.values) {
      addName(n);
    }
    final aliasesByKey = <String, List<String>>{};
    aliasMap.forEach((alias, name) {
      final a = alias.trim();
      if (a.isEmpty) return;
      (aliasesByKey[destinationKey(name)] ??= []).add(a);
    });
    Map<dynamic, dynamic>? infoOf(String name) {
      final direct = info[name];
      if (direct is Map) return direct;
      final k = destinationKey(name);
      for (final e in info.entries) {
        if (destinationKey(e.key) == k && e.value is Map) {
          return e.value as Map;
        }
      }
      return null;
    }

    final items = <Destination>[];
    for (final n in names) {
      final i = infoOf(n);
      final rawIds = i?['accounts'];
      final ids = <int>[];
      if (rawIds is List) {
        for (final x in rawIds) {
          final id = x is num ? x.toInt() : int.tryParse('$x');
          if (id != null && !ids.contains(id)) ids.add(id);
        }
      }
      final aliases = [...?aliasesByKey[destinationKey(n)]]
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      items.add(
        Destination(
          name: n,
          aliases: aliases,
          toOffice: i?['office'] == true,
          officeIds: ids,
        ),
      );
    }
    items.sort((a, b) => a.name.compareTo(b.name));
    return DestinationBook.build(items);
  }

  factory DestinationBook.build(List<Destination> items) {
    final byKey = <String, Destination>{};
    final byFirst = <String, List<_Phrase>>{};
    for (final d in items) {
      byKey[d.key] = d;
      for (final raw in <String>[d.name, ...d.aliases]) {
        final keys = [
          for (final t in tokensFromLine(raw))
            if (matchKey(t).isNotEmpty) matchKey(t),
        ];
        if (keys.isEmpty) continue;
        final p = _Phrase(keys, d, raw.trim());
        for (final first in _phraseHeads(keys.first)) {
          (byFirst[first] ??= []).add(p);
        }
      }
    }
    for (final list in byFirst.values) {
      list.sort((a, b) => b.keys.length.compareTo(a.keys.length));
    }
    return DestinationBook._(List.unmodifiable(items), byKey, byFirst);
  }

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  List<String> get names => [for (final d in items) d.name];

  /// الوجهات حسب مفتاحها (للحساب بالخلفية)
  Map<String, Destination> get byKey => Map.unmodifiable(_byKey);

  Destination? byName(String? name) {
    final k = destinationKey(name);
    if (k.isEmpty) return null;
    return _byKey[k];
  }

  /// أول كلمة بعبارة الوجهة: نسجلها كمان بدون «ال» حتى «الشام» = «شام».
  static Iterable<String> _phraseHeads(String k) sync* {
    yield k;
    if (k.length > 3 && k.startsWith('ال')) yield k.substring(2);
  }

  /// أشكال الكلمة بالرسالة: كما هي، وبدون حرف جر ملزق (و/ل/ب/ف/ك)، وبدون
  /// «ال» («لحلب» ← «حلب»، «والشام» ← «شام»، «للشام» ← «شام»).
  static Iterable<String> _tokenForms(String k) sync* {
    yield k;
    String? noPrefix;
    if (k.length > 2 && 'ولبفك'.contains(k[0])) {
      noPrefix = k.substring(1);
      yield noPrefix;
    }
    if (k.length > 3 && k.startsWith('لل')) {
      yield k.substring(2);
    }
    if (k.length > 3 && k.startsWith('ال')) yield k.substring(2);
    if (noPrefix != null && noPrefix.length > 3 && noPrefix.startsWith('ال')) {
      yield noPrefix.substring(2);
    }
  }

  /// الوجهات المذكورة بالأسطر
  DestinationDetection detect(Iterable<String> lines) {
    if (_byFirst.isEmpty) return DestinationDetection.none;
    final hits = <DestinationHit>[];
    final names = <String>[];
    var li = -1;
    for (final line in lines) {
      li++;
      final keys = [for (final t in tokensFromLine(line)) matchKey(t)];
      var i = 0;
      while (i < keys.length) {
        _Phrase? best;
        if (keys[i].isNotEmpty) {
          for (final form in _tokenForms(keys[i])) {
            final list = _byFirst[form];
            if (list == null) continue;
            for (final p in list) {
              if (i + p.keys.length > keys.length) continue;
              var ok = true;
              for (var j = 1; j < p.keys.length; j++) {
                if (keys[i + j] != p.keys[j]) {
                  ok = false;
                  break;
                }
              }
              if (ok && (best == null || p.keys.length > best.keys.length)) {
                best = p;
              }
              if (ok) break;
            }
          }
        }
        if (best == null) {
          i++;
          continue;
        }
        hits.add(
          DestinationHit(
            name: best.dest.name,
            phrase: best.original,
            line: li,
            start: i,
            length: best.keys.length,
          ),
        );
        if (!names.contains(best.dest.name)) names.add(best.dest.name);
        i += best.keys.length;
      }
    }
    return DestinationDetection(names, hits);
  }
}
