// lib/widgets/destination_picker.dart
// -------------------------------------------------------------
// اختيار وجهة حركة الشركة (قائمة من الأسفل): «بدون وجهة» + كل الوجهات من
// الإعدادات، مع زر لإضافة وجهة جديدة.
// -------------------------------------------------------------

import 'package:flutter/material.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/destinations.dart';

const Color kDestColor = Color(0xFF0E7490);

/// يعيد اسم الوجهة المختارة، أو '' لـ«بدون وجهة»، أو null إذا انسكرت القائمة.
Future<String?> showDestinationPicker(
  BuildContext context, {
  required DestinationBook book,
  String? current,
  String title = 'وجهة الحركة',
}) {
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
              for (final d in book.items)
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  selected: d.key == currentKey,
                  leading: const Icon(Icons.place_rounded, color: kDestColor),
                  title: Text(
                    d.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  trailing: check(d.key == currentKey),
                  onTap: () => Navigator.pop(ctx, d.name),
                ),
              const SizedBox(height: 6),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                leading: Icon(
                  Icons.add_location_alt_rounded,
                  color: cs.primary,
                ),
                title: Text(
                  'وجهة جديدة',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: cs.primary,
                  ),
                ),
                onTap: () async {
                  final name = await _askNewDestination(ctx);
                  if (name == null || !ctx.mounted) return;
                  Navigator.pop(ctx, name);
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// يطلب اسم وجهة جديدة ويحفظها بالإعدادات. يعيد اسمها (أو اسم الموجودة).
Future<String?> _askNewDestination(BuildContext context) async {
  final ctrl = TextEditingController();
  final raw = await showDialog<String>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('وجهة جديدة'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: const InputDecoration(labelText: 'اسم الوجهة'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('إضافة'),
          ),
        ],
      ),
    ),
  );
  final name = raw?.trim() ?? '';
  if (name.isEmpty) return null;
  final s =
      DatabaseService.getSettings() ??
      Settings(
        nameKeywords: [],
        amountKeywords: [],
        currencyMap: {},
        ignoredWords: [],
      );
  final existing = DestinationBook.fromSettings(s).byName(name);
  if (existing != null) return existing.name;
  s.destinationInfo = {...s.destinationInfo, name: <String, dynamic>{}};
  await DatabaseService.saveSettings(s);
  return name;
}
