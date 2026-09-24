// lib/services/share_import/share_import_controller.dart
// -------------------------------------------------------------
// استقبال الملفات التي يشاركها المستخدم مع التطبيق (أندرويد):
// ملف Excel / CSV / نص / محادثة واتساب → قراءة الملف → ثم:
// - «تحليل الرسائل»: اختيار الحساب → صفحة «تحليل النص» بالنص الجاهز.
// - «مطابقة غير المستلمة» (ملف جدول واحد): اختيار الحساب → صفحة المطابقة
//   والملف محمَّل فيها مباشرة.
// يُشغَّل من الصفحة الرئيسية بعد انتهاء شاشة البداية.
// -------------------------------------------------------------

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_intake/share_intake.dart';

import '../../database_service.dart';
import '../../models.dart';
import '../../screens/parse_text_screen.dart';
import '../../screens/unreceived_reconcile_screen.dart';
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
    TableFileData? table;
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
          // ملف واحد: نقرؤه أيضًا كجدول لخيار «مطابقة غير المستلمة»
          if (!multi) {
            table = await ShareImportService.readTable(
              bytes: bytes,
              fileName: f.name,
              mimeType: f.mimeType,
            );
          }
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

    final analyzable = conversions.any((c) => c.ok);
    final isChat = conversions.any(
      (c) => c.ok && c.kind == ImportFileKind.whatsapp,
    );
    final reconcile = isChat ? null : _reconcileInfo(table);

    if (!analyzable && reconcile == null) {
      ctx = contextOf();
      if (ctx == null || !ctx.mounted) return;
      await _showFailure(ctx, [
        ..._readableErrors(item.errors),
        for (final c in conversions)
          '${c.fileName}: ${c.error ?? 'لا توجد بيانات قابلة للتحليل'}',
      ]);
      return;
    }

    // ملف جدول واحد: تحليل رسائله أم مطابقته مع غير المستلمة؟
    if (reconcile != null) {
      ctx = contextOf();
      if (ctx == null || !ctx.mounted) return;
      final messages = conversions
          .where((c) => c.ok)
          .fold<int>(0, (sum, c) => sum + c.messages.length);
      final analyzeProblem = conversions
          .map((c) => c.error ?? '')
          .firstWhere(
            (e) => e.isNotEmpty,
            orElse: () => 'لا توجد بيانات قابلة للتحليل',
          );
      final action = await showSharedFileActionSheet(
        ctx,
        fileTitle: reconcile.table.fileName,
        kindLabel: reconcile.table.kindLabel,
        analyzeDetail: analyzable ? '$messages رسالة' : null,
        analyzeUnavailable: analyzable ? null : analyzeProblem,
        reconcileDetail: reconcile.detail,
      );
      if (action == null) return;
      if (action == SharedFileAction.reconcile) {
        await _openReconcile(reconcile, item.errors);
        return;
      }
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

  /// إمكانية مطابقة الملف: جدول بعمودين على الأقل، أو أسطر بصيغة
  /// «الاسم - المبلغ - العملة» (بنفس ترتيب صفحة المطابقة). null = غير ممكن.
  ({TableFileData table, int count, String unit, String detail})?
  _reconcileInfo(TableFileData? t) {
    if (t == null || !t.ok) return null;
    if (t.kind == TableFileKind.text || t.headers.length < 2) {
      final n = UnreceivedReconcileScreen.dashListLength(t.lines);
      if (n > 0) {
        return (
          table: t,
          count: n,
          unit: 'سطر للمطابقة',
          detail: '$n سطر بصيغة الاسم - المبلغ - العملة',
        );
      }
    }
    if (!t.hasTable) return null;
    return (
      table: t,
      count: t.rows.length,
      unit: 'صف للمطابقة',
      detail: '${t.rows.length} صف • ${t.headers.length} أعمدة',
    );
  }

  /// اختيار الحساب ثم فتح صفحة «مطابقة غير المستلمة» والملف محمَّل فيها
  Future<void> _openReconcile(
    ({TableFileData table, int count, String unit, String detail}) info,
    List<String> errors,
  ) async {
    final accounts = DatabaseService.accountsBox.values.toList();
    if (accounts.isEmpty) {
      _snack('لا توجد حسابات بعد — أضف حسابًا ثم شارك الملف من جديد');
      return;
    }
    final table = info.table;
    final mentions = await ShareImportService.countAccountMentions(
      table.plainText,
      accounts,
    );
    final ctx = contextOf();
    if (ctx == null || !ctx.mounted) return;
    final account = await showImportAccountPicker(
      ctx,
      title: 'اختر الحساب لمطابقة الملف عليه',
      summary: ImportSummary(
        fileNames: [table.fileName],
        kindLabel: table.kindLabel,
        messageCount: info.count,
        countUnit: info.unit,
        notes: table.notes,
        errors: _readableErrors(errors),
      ),
      accounts: accounts,
      mentions: mentions,
    );
    if (account == null || contextOf() == null || _disposed) return;
    openPage(UnreceivedReconcileScreen(account: account, initialTable: table));
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
