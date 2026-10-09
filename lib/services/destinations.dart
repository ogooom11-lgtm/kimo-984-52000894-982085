// lib/services/destinations.dart
// -------------------------------------------------------------
// الوجهات (لحركات الشركات): قائمة أسماء محفوظة بالإعدادات، وبتنختار وحدة
// منها لكل حركة.
// -------------------------------------------------------------

import '../models.dart';

/// وجهة وحدة
class Destination {
  final String name;

  const Destination(this.name);

  /// مفتاح المقارنة (بعد توحيد الهمزات والتاء المربوطة...)
  String get key => destinationKey(name);
}

/// مفتاح مقارنة اسم الوجهة
String destinationKey(String? name) {
  var t = (name ?? '').trim().toLowerCase();
  if (t.isEmpty) return '';
  t = t
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll(RegExp('[\u064B-\u0652\u0640]'), '')
      .replaceAll(RegExp(r'\s+'), ' ');
  return t;
}

/// أسماء الوجهات المحفوظة بالإعدادات
List<String> destinationNamesOf(Settings s) => [
  ...s.destinationInfo.keys,
  ...s.destinationMap.values,
];

/// كل الوجهات (من الإعدادات)
class DestinationBook {
  final List<Destination> items;
  final Map<String, Destination> _byKey;

  DestinationBook._(this.items, this._byKey);

  static final DestinationBook empty = DestinationBook._(const [], const {});

  factory DestinationBook.fromSettings(Settings? s) {
    if (s == null) return empty;
    return DestinationBook.fromNames(destinationNamesOf(s));
  }

  factory DestinationBook.fromNames(Iterable<String> names) {
    final byKey = <String, Destination>{};
    final items = <Destination>[];
    for (final raw in names) {
      final n = raw.trim();
      final k = destinationKey(n);
      if (k.isEmpty || byKey.containsKey(k)) continue;
      final d = Destination(n);
      byKey[k] = d;
      items.add(d);
    }
    items.sort((a, b) => a.name.compareTo(b.name));
    return DestinationBook._(List.unmodifiable(items), byKey);
  }

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  List<String> get names => [for (final d in items) d.name];

  Destination? byName(String? name) {
    final k = destinationKey(name);
    if (k.isEmpty) return null;
    return _byKey[k];
  }
}
