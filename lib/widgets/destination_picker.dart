// lib/widgets/destination_picker.dart
// -------------------------------------------------------------
// اختيار وجهة حركة الشركة (قائمة من الأسفل): «بدون وجهة» + كل الوجهات من
// الإعدادات، والمذكورة بالرسالة أولًا. نفس القائمة بشاشة الفقاعات وصفحة
// التفاصيل والإضافة اليدوية.
// -------------------------------------------------------------

import 'package:flutter/material.dart';

import '../services/destinations.dart';

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
                    'ما في وجهات بعد — أضفها من الإعدادات ← الوجهات.',
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
