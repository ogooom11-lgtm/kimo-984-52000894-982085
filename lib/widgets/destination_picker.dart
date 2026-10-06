// lib/widgets/destination_picker.dart
// -------------------------------------------------------------
// اختيار وجهة حركة الشركة (قائمة من الأسفل): «بدون وجهة» + كل الوجهات من
// الإعدادات، والمذكورة بالرسالة أولًا. نفس القائمة بشاشة الفقاعات وصفحة
// التفاصيل والإضافة اليدوية.
//
// showDestinationWordSheet: تحديد كلمة من الرسالة (ضغط مطوّل/سحب) كاسم وجهة
// جديدة أو كاختصار لوجهة موجودة — بتنحفظ فورًا بالإعدادات ← الوجهات.
// -------------------------------------------------------------

import 'package:flutter/material.dart';

import '../services/destinations.dart';
import '../services/detection/text_tokens.dart'
    show stripEdgePunct, tokenHasDigit, tokensFromLine;
import '../services/settings_words.dart';

const Color kDestOfficeColor = Color(0xFF0E7490);
const Color kDestExternalColor = Color(0xFF9333EA);

Color destinationColor(Destination? d) => d == null
    ? const Color(0xFF64748B)
    : (d.toOffice ? kDestOfficeColor : kDestExternalColor);

IconData destinationIcon(Destination? d) => d == null
    ? Icons.not_listed_location_rounded
    : (d.toOffice ? Icons.storefront_rounded : Icons.place_rounded);

/// يعيد اسم الوجهة المختارة، أو '' لـ«بدون وجهة»، أو null إذا انسكرت القائمة.
Future<String?> showDestinationPicker(
  BuildContext context, {
  required DestinationBook book,
  String? current,
  List<String> detected = const [],
  String title = 'وجهة الحركة',
}) {
  final items = [...book.items]
    ..sort((a, b) {
      final ma = detected.contains(a.name) ? 0 : 1;
      final mb = detected.contains(b.name) ? 0 : 1;
      if (ma != mb) return ma.compareTo(mb);
      return a.name.compareTo(b.name);
    });
  final currentKey = destinationKey(current);
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      final muted = cs.onSurfaceVariant;
      Widget check(bool on) => on
          ? Icon(Icons.check_circle_rounded, color: cs.primary)
          : const SizedBox(width: 24);
      return Directionality(
        textDirection: TextDirection.rtl,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * .75,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detected.isEmpty
                    ? 'الوجهات من الإعدادات. التابعة لمكتب لازم توصل لمكتب.'
                    : 'مذكورة بالرسالة: ${detected.join('، ')}',
                style: TextStyle(color: muted, fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                leading: Icon(Icons.not_listed_location_rounded, color: muted),
                title: const Text(
                  'بدون وجهة',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                trailing: check(currentKey.isEmpty),
                onTap: () => Navigator.pop(ctx, ''),
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'ما في وجهات بعد — أضفها من الإعدادات ← الوجهات، أو اضغط '
                    'مطوّلًا على كلمة بالرسالة واختار «تحديد كاسم وجهة».',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final d in items)
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  selected: d.key == currentKey,
                  leading: Icon(destinationIcon(d), color: destinationColor(d)),
                  title: Text(
                    d.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    [
                      d.toOffice ? 'تابعة لمكتب' : 'مو تابعة لمكتب',
                      if (detected.contains(d.name)) 'مذكورة بالرسالة',
                      if (d.aliases.isNotEmpty) d.aliases.take(3).join('، '),
                    ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: check(d.key == currentKey),
                  onTap: () => Navigator.pop(ctx, d.name),
                ),
            ],
          ),
        ),
      );
    },
  );
}

// =============================================================
// تحديد كلمة كوجهة (اسم جديد أو اختصار)
// =============================================================

/// نتيجة «تحديد كلمة كوجهة»
class DestinationWordResult {
  /// الوجهة يلي صارت الكلمة تدل عليها
  final String destination;

  /// الكلمة/العبارة يلي انحفظت
  final String phrase;

  /// وجهة جديدة (وإلا اختصار لوجهة موجودة)
  final bool created;

  const DestinationWordResult({
    required this.destination,
    required this.phrase,
    required this.created,
  });
}

const String _kAttachedLetters = 'ولبفك';

/// اقتراحات الكلمة/العبارة من الكلمة رقم [index] بالسطر: الكلمة نفسها،
/// وبدون حرف الجر الملزق («بالشام» ← «الشام»، «للشام» ← «الشام»، «لحلب» ←
/// «حلب»)، والعبارة مع كلمة أو كلمتين بعدها («دير الزور»).
/// الأول هو الأرجح.
List<String> destinationPhraseOptions(List<String> tokens, int index) {
  final out = <String>[];
  void add(String s, {bool first = false}) {
    final v = s.trim();
    final k = destinationKey(v);
    if (k.isEmpty || out.any((e) => destinationKey(e) == k)) return;
    first ? out.insert(0, v) : out.add(v);
  }

  if (index < 0 || index >= tokens.length) return out;
  String clean(String t) => stripEdgePunct(t).trim();
  final w = clean(tokens[index]);
  if (w.isEmpty || tokenHasDigit(w)) return out;
  add(w);
  if (w.length > 3 && w.startsWith('لل')) {
    // «للشام» = ل + الشام
    add('ال${w.substring(2)}', first: true);
  } else if (w.length > 2 && _kAttachedLetters.contains(w[0])) {
    final rest = w.substring(1);
    // «بالشام»/«والشام»: الحرف أكيد ملزق؛ غير هيك اقتراح بس («لحلب»)
    add(rest, first: rest.startsWith('ال') && rest.length > 3);
  }
  final words = <String>[w];
  for (var j = index + 1; j < tokens.length && words.length < 3; j++) {
    final n = clean(tokens[j]);
    if (n.isEmpty || tokenHasDigit(n)) break;
    words.add(n);
    add(words.join(' '));
  }
  return out;
}

/// قائمة من الأسفل: تحديد كلمة كاسم وجهة جديدة أو كاختصار لوجهة موجودة.
/// [options] اقتراحات الكلمة (الأول = الافتراضي). [aliasFirst] يفتح على
/// «اختصار لوجهة». [suggestedDestination] الوجهة المقترحة للاختصار.
Future<DestinationWordResult?> showDestinationWordSheet(
  BuildContext context, {
  required List<String> options,
  required DestinationBook book,
  bool aliasFirst = false,
  String? suggestedDestination,
}) {
  return showModalBottomSheet<DestinationWordResult>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _DestinationWordSheet(
      options: options,
      book: book,
      aliasFirst: aliasFirst,
      suggested: suggestedDestination,
    ),
  );
}

class _DestinationWordSheet extends StatefulWidget {
  final List<String> options;
  final DestinationBook book;
  final bool aliasFirst;
  final String? suggested;

  const _DestinationWordSheet({
    required this.options,
    required this.book,
    required this.aliasFirst,
    required this.suggested,
  });

  @override
  State<_DestinationWordSheet> createState() => _DestinationWordSheetState();
}

class _DestinationWordSheetState extends State<_DestinationWordSheet> {
  late final TextEditingController _phrase = TextEditingController(
    text: widget.options.isEmpty ? '' : widget.options.first,
  );
  final TextEditingController _search = TextEditingController();
  late bool _alias = widget.aliasFirst && widget.book.isNotEmpty;
  bool _toOffice = false;
  String? _target;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _target = widget.book.byName(widget.suggested)?.name;
  }

  @override
  void dispose() {
    _phrase.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final phrase = _phrase.text.trim();
    if (destinationKey(phrase).isEmpty) {
      setState(() => _error = 'اكتب الكلمة أو العبارة');
      return;
    }
    final target = _target;
    if (_alias && target == null) {
      setState(() => _error = 'اختار الوجهة يلي بتدل عليها هالكلمة');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    String? err;
    try {
      err = _alias
          ? await SettingsWords.addDestinationAlias(target!, phrase)
          : await SettingsWords.addDestination(phrase, toOffice: _toOffice);
    } catch (e) {
      err = 'تعذّر الحفظ: $e';
    }
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _saving = false;
        _error = err;
      });
      return;
    }
    Navigator.pop(
      context,
      DestinationWordResult(
        destination: _alias ? target! : phrase,
        phrase: phrase,
        created: !_alias,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurfaceVariant;
    final q = destinationKey(_search.text);
    final items = [
      for (final d in widget.book.items)
        if (q.isEmpty ||
            d.key.contains(q) ||
            d.aliases.any((a) => destinationKey(a).contains(q)))
          d,
    ]..sort((a, b) => a.name.compareTo(b.name));
    final phrase = _phrase.text.trim();
    // الكلمة كلها معروفة مسبقًا كوجهة (أو اختصار، أو بحرف ملزق)
    final existing = widget.book.detect([phrase]);
    final firstHit = existing.hits.isEmpty ? null : existing.hits.first;
    final owner =
        firstHit != null &&
            firstHit.start == 0 &&
            firstHit.length == tokensFromLine(phrase).length
        ? firstHit.name
        : null;
    final hasAttached =
        widget.options.isNotEmpty &&
        widget.options.any(
          (o) => o.length > 2 && _kAttachedLetters.contains(o[0]),
        );
    final accent = _alias ? kDestExternalColor : kDestOfficeColor;

    Widget sectionTitle(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w900)),
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .88,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      _alias
                          ? Icons.alt_route_rounded
                          : Icons.add_location_alt_rounded,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'تحديد كلمة كوجهة',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          'بتنحفظ بالإعدادات ← الوجهات، والبرنامج بيتعرف '
                          'عليها لحالو بالرسائل الجاية.',
                          style: TextStyle(color: muted, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(
                    value: false,
                    icon: Icon(Icons.add_location_alt_rounded),
                    label: Text('وجهة جديدة'),
                  ),
                  ButtonSegment(
                    value: true,
                    enabled: widget.book.isNotEmpty,
                    icon: const Icon(Icons.alt_route_rounded),
                    label: const Text('اختصار لوجهة'),
                  ),
                ],
                selected: {_alias},
                onSelectionChanged: (s) => setState(() {
                  _alias = s.first;
                  _error = null;
                }),
              ),
              const SizedBox(height: 16),
              sectionTitle(
                _alias ? 'الاختصار (متل ما بينكتب بالرسائل)' : 'اسم الوجهة',
              ),
              TextField(
                controller: _phrase,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.short_text_rounded, color: accent),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              if (widget.options.length > 1) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final o in widget.options)
                      ChoiceChip(
                        label: Text(o),
                        selected: phrase == o,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() {
                          _phrase.text = o;
                          _error = null;
                        }),
                      ),
                  ],
                ),
              ],
              if (hasAttached) ...[
                const SizedBox(height: 6),
                Text(
                  'الحرف الملزق متل «ل» و«ب» و«و» ما بيلزم: «حلب» بتنعرف '
                  'كمان بـ«لحلب» و«بحلب».',
                  style: TextStyle(color: muted, fontSize: 11.5),
                ),
              ],
              if (owner != null) ...[
                const SizedBox(height: 8),
                Text(
                  'ملاحظة: «$phrase» معروفة مسبقًا كوجهة «$owner».',
                  style: TextStyle(
                    color: Colors.orange.shade800,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (!_alias)
                Material(
                  color: cs.surfaceContainerHighest.withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(16),
                  child: SwitchListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    secondary: Icon(
                      _toOffice
                          ? Icons.storefront_rounded
                          : Icons.place_rounded,
                      color: _toOffice ? kDestOfficeColor : kDestExternalColor,
                    ),
                    title: const Text(
                      'تابعة لمكتب',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      _toOffice
                          ? 'لازم توصل لمكتب: إذا ما وصلت بينبهك البرنامج.'
                          : 'ما منستناها توصل لمكتب. إذا وصلت لمكتب = تحذير '
                                '«يمكن تغيّر المسار».',
                      style: const TextStyle(fontSize: 12),
                    ),
                    value: _toOffice,
                    onChanged: (v) => setState(() => _toOffice = v),
                  ),
                )
              else ...[
                sectionTitle('الوجهة يلي بتدل عليها'),
                if (widget.book.items.length > 6) ...[
                  TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'بحث بالوجهات',
                      prefixIcon: const Icon(Icons.search_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text('ما في نتائج', style: TextStyle(color: muted)),
                  ),
                for (final d in items) _destTile(context, d),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.withValues(alpha: .3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: Colors.red,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Colors.red.shade800,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('إلغاء'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: accent),
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_rounded),
                      label: Text(_alias ? 'حفظ كاختصار' : 'حفظ الوجهة'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _destTile(BuildContext context, Destination d) {
    final cs = Theme.of(context).colorScheme;
    final selected = _target == d.name;
    final color = destinationColor(d);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? color.withValues(alpha: .12)
            : cs.surfaceContainerHighest.withValues(alpha: .4),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() {
            _target = d.name;
            _error = null;
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? color.withValues(alpha: .55)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(destinationIcon(d), color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: selected ? color : null,
                        ),
                      ),
                      Text(
                        [
                          d.toOffice ? 'تابعة لمكتب' : 'مو تابعة لمكتب',
                          if (d.aliases.isNotEmpty)
                            d.aliases.take(4).join('، '),
                        ].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? color : cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
