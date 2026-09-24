// lib/services/share_import/share_import_service.dart
// -------------------------------------------------------------
// خدمات استيراد الملفات لصفحة تحليل النص (تعمل على كل المنصات):
// - بناء إعدادات التحويل من إعدادات التطبيق.
// - تحويل الملف داخل Isolate حتى لا تتجمد الواجهة مع الملفات الكبيرة.
// - عدّ مرات ذكر كل حساب في النص (لترتيب قائمة اختيار الحساب).
// -------------------------------------------------------------

import 'package:flutter/foundation.dart';

import '../../database_service.dart';
import '../../models.dart';
import 'import_converter.dart';
import 'import_models.dart';

export 'import_converter.dart' show ImportFileConverter;
export 'import_models.dart';

/// ملخص ما تم استيراده (يُعرض أعلى صفحة تحليل النص)
class ImportSummary {
  final List<String> fileNames;
  final String kindLabel;
  final int messageCount;
  final List<String> notes;

  /// ملفات لم يمكن قراءتها (الاسم: السبب)
  final List<String> errors;

  const ImportSummary({
    required this.fileNames,
    required this.kindLabel,
    required this.messageCount,
    this.notes = const [],
    this.errors = const [],
  });

  String get title {
    if (fileNames.isEmpty) return 'نص مستورد';
    if (fileNames.length == 1) return fileNames.first;
    return '${fileNames.length} ملفات';
  }
}

class ShareImportService {
  ShareImportService._();

  /// إعدادات التحويل من إعدادات التطبيق (كلمة الاسم/المبلغ والعملات)
  static ImportOptions optionsFromSettings() {
    try {
      final s = DatabaseService.getSettings();
      if (s == null) {
        return ImportOptions.fromSettings(
          nameKeywords: const ['المستفيد', 'إلى', 'ل', 'لـ'],
          amountKeywords: const ['المبلغ', 'قيمة', 'amount', r'$'],
          currencyMap: const {r'$': 'دولار'},
        );
      }
      return ImportOptions.fromSettings(
        nameKeywords: s.nameKeywords,
        amountKeywords: s.amountKeywords,
        currencyMap: s.currencyMap,
      );
    } catch (_) {
      return const ImportOptions();
    }
  }

  /// تحويل بايتات ملف إلى رسائل (داخل Isolate عند الإمكان)
  static Future<ImportConversion> convertBytes({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
    required ImportOptions options,
  }) async {
    final request = ImportRequest(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
      options: options,
    );
    try {
      return await compute(convertImportRequest, request);
    } catch (_) {
      // احتياط: بعض البيئات لا تسمح بإنشاء Isolate
      return convertImportRequest(request);
    }
  }

  /// يدمج نتائج عدة ملفات في نص واحد + ملخص
  static ({String text, ImportSummary summary}) combine(
    List<ImportConversion> conversions, {
    List<List<ImportMessage>>? selectedMessages,
    List<String> extraErrors = const [],
  }) {
    final ok = <ImportConversion>[];
    final chosen = <List<ImportMessage>>[];
    final errors = <String>[...extraErrors];
    for (var i = 0; i < conversions.length; i++) {
      final c = conversions[i];
      if (c.ok) {
        ok.add(c);
        chosen.add(
          selectedMessages != null && i < selectedMessages.length
              ? selectedMessages[i]
              : c.messages,
        );
      } else {
        errors.add('${c.fileName}: ${c.error ?? 'لا توجد بيانات'}');
      }
    }
    final text = [
      for (final list in chosen)
        if (list.isNotEmpty) ImportConversion.textOf(list),
    ].join('\n');
    final kinds = ok.map((c) => c.kind.label).toSet().toList();
    final count = chosen.fold<int>(0, (sum, l) => sum + l.length);
    final notes = <String>[
      if (count > 1000) 'ملف كبير ($count رسالة): قد يستغرق التحليل بعض الوقت',
      for (final c in ok)
        for (final n in c.notes) ok.length > 1 ? '${c.fileName}: $n' : n,
    ];
    return (
      text: text,
      summary: ImportSummary(
        fileNames: ok.map((c) => c.fileName).toList(),
        kindLabel: kinds.join(' + '),
        messageCount: count,
        notes: notes,
        errors: errors,
      ),
    );
  }

  /// عدد مرات ذكر كل حساب (اسمه أو كلماته المفتاحية) في النص
  static Future<Map<int, int>> countAccountMentions(
    String text,
    List<Account> accounts,
  ) async {
    if (text.trim().isEmpty || accounts.isEmpty) return const {};
    final keywords = <int, List<String>>{
      for (final a in accounts) a.id: [a.name, ...a.keywords],
    };
    final request = (text: text, keywords: keywords);
    try {
      return await compute(_countMentions, request);
    } catch (_) {
      return _countMentions(request);
    }
  }
}

String _normalizeForAccountMatch(String value) {
  var s = value.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '').toLowerCase();
  s = s.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
  s = s.replaceAll('ى', 'ي').replaceAll('ئ', 'ي').replaceAll('ؤ', 'و');
  s = s.replaceAll('ة', 'ه');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

Map<int, int> _countMentions(
  ({String text, Map<int, List<String>> keywords}) request,
) {
  final normalized = _normalizeForAccountMatch(request.text);
  final out = <int, int>{};
  request.keywords.forEach((id, words) {
    final seen = <String>{};
    var count = 0;
    for (final w in words) {
      final k = _normalizeForAccountMatch(w);
      if (k.isEmpty || !seen.add(k)) continue;
      count += RegExp(RegExp.escape(k)).allMatches(normalized).length;
    }
    if (count > 0) out[id] = count;
  });
  return out;
}
