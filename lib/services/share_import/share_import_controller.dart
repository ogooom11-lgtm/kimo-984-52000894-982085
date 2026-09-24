// lib/services/share_import/share_import_controller.dart
// -------------------------------------------------------------
// استقبال الملفات التي يشاركها المستخدم مع التطبيق (أندرويد):
// ملف Excel / CSV / نص / محادثة واتساب → قراءة الملف → اختيار الحساب →
// فتح صفحة «تحليل النص» بالنص الجاهز والحساب المختار.
// يُشغَّل من الصفحة الرئيسية بعد انتهاء شاشة البداية.
// -------------------------------------------------------------

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_intake/share_intake.dart';

import '../../database_service.dart';
import '../../models.dart';
import '../../screens/parse_text_screen.dart';
import '../../widgets/import_sheets.dart';
import 'share_import_service.dart';

class ShareImportController {
  ShareImportController({required this.contextOf, required this.openPage});

  /// سياق صالح لعرض النوافذ (null إذا لم تعد الصفحة موجودة)
  final BuildContext? Function() contextOf;

  /// يفتح صفحة جديدة فوق الصفحات الحالية
  final void Function(Widget page) openPage;

  StreamSubscription<void>? _sub;
  bool _running = false;
  bool _again = false;
  bool _disposed = false;

  void start() {
    if (!ShareIntake.isSupported || _disposed) return;
    _sub ??= ShareIntake.onPending.listen((_) => _drain());
    unawaited(_drain());
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _drain() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        final items = await ShareIntake.takePending();
        for (final item in items) {
          if (_disposed) return;
          try {
            await _handle(item);
          } catch (e) {
            debugPrint('ShareImportController: $e');
          }
        }
      } while (_again && !_disposed);
    } finally {
      _running = false;
    }
  }

  Future<void> _handle(SharedIntake item) async {
    if (item.isEmpty) return;
    var ctx = contextOf();
    if (ctx == null) {
      _cleanup(item);
      return;
    }

    final options = ShareImportService.optionsFromSettings();
    final multi = item.files.length > 1;
    final conversions = <ImportConversion>[];
    final busy = ImportBusyOverlay.show(
      ctx,
      item.files.isEmpty ? 'جارٍ تجهيز النص...' : 'جارٍ قراءة الملف...',
    );
    try {
      for (final f in item.files) {
        try {
          final bytes = await File(f.path).readAsBytes();
          conversions.add(
            await ShareImportService.convertBytes(
              bytes: bytes,
              fileName: f.name,
              mimeType: f.mimeType,
              options: multi ? options.copyWith(labelSuffix: f.name) : options,
            ),
          );
        } catch (e) {
          conversions.add(
            ImportConversion.failure(f.name, 'تعذر فتح الملف: $e'),
          );
        }
      }
      if (item.files.isEmpty && item.hasText) {
        final subject = (item.subject ?? '').trim();
        conversions.add(
          ImportFileConverter.convertText(
            item.text!,
            fileName: subject.isNotEmpty ? subject : 'نص مشارك',
            options: options,
          ),
        );
      }
    } finally {
      busy.remove();
      _cleanup(item);
    }

    if (!conversions.any((c) => c.ok)) {
      ctx = contextOf();
      if (ctx == null || !ctx.mounted) return;
      await _showFailure(ctx, [
        ..._readableErrors(item.errors),
        for (final c in conversions)
          '${c.fileName}: ${c.error ?? 'لا توجد بيانات قابلة للتحليل'}',
      ]);
      return;
    }

    // محادثات واتساب: اختيار فترة الرسائل
    final selected = <List<ImportMessage>>[];
    for (final c in conversions) {
      if (c.ok && c.kind == ImportFileKind.whatsapp) {
        ctx = contextOf();
        if (ctx == null || !ctx.mounted) return;
        final picked = await pickWhatsAppRange(ctx, c);
        if (picked == null) return;
        selected.add(picked);
      } else {
        selected.add(c.messages);
      }
    }

    final combined = ShareImportService.combine(
      conversions,
      selectedMessages: selected,
      extraErrors: _readableErrors(item.errors),
    );
    if (combined.text.trim().isEmpty) {
      _snack('لا توجد رسائل في الفترة المختارة');
      return;
    }

    final accounts = DatabaseService.accountsBox.values.toList();
    Account? account;
    if (accounts.isNotEmpty) {
      final mentions = await ShareImportService.countAccountMentions(
        combined.text,
        accounts,
      );
      ctx = contextOf();
      if (ctx == null || !ctx.mounted) return;
      account = await showImportAccountPicker(
        ctx,
        summary: combined.summary,
        accounts: accounts,
        mentions: mentions,
      );
      if (account == null) return;
    } else {
      _snack('لا توجد حسابات بعد — أضف حسابًا ثم اختره في صفحة التحليل');
    }

    if (contextOf() == null || _disposed) return;
    openPage(
      ParseTextScreen(
        initialText: combined.text,
        initialAccount: account,
        importSummary: combined.summary,
      ),
    );
  }

  void _snack(String message) {
    final ctx = contextOf();
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.maybeOf(
      ctx,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// رسائل الأخطاء القادمة من أندرويد بصيغة مفهومة
  List<String> _readableErrors(List<String> errors) {
    const codes = {
      'too_large': 'الملف كبير جدًا (أكثر من 30 ميغابايت)',
      'cannot open': 'تعذر فتح الملف',
      'blocked': 'مسار غير مسموح',
    };
    return [
      for (final e in errors)
        e.replaceAllMapped(
          RegExp(r': (too_large|cannot open|blocked)$'),
          (m) => ': ${codes[m.group(1)]}',
        ),
    ];
  }

  void _cleanup(SharedIntake item) {
    for (final f in item.files) {
      try {
        final file = File(f.path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _showFailure(BuildContext context, List<String> reasons) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          icon: const Icon(Icons.error_outline_rounded),
          title: const Text('تعذر تحليل الملف'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in reasons.toSet())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('• $r'),
                  ),
                const SizedBox(height: 6),
                const Text(
                  'الملفات المدعومة: Excel (xlsx) و CSV و TXT ومحادثات واتساب المصدَّرة (txt أو zip).',
                  style: TextStyle(fontSize: 12.5),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('حسنًا'),
            ),
          ],
        ),
      ),
    );
  }
}
