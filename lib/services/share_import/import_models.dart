// lib/services/share_import/import_models.dart
// -------------------------------------------------------------
// نماذج استيراد الملفات لتحليل النص (Excel / CSV / نص / محادثة واتساب).
// (ملف Dart نقي بدون Flutter — يمكن تمريره بين الـ Isolates)
// -------------------------------------------------------------

import '../detection/text_tokens.dart' show normalizeArabic;

/// خلية واحدة من جدول مستورد
class ImportCell {
  /// النص كما يُعرض (بعد تنسيق الأرقام والتواريخ)
  final String text;

  /// القيمة الرقمية إن كانت الخلية رقمًا حقيقيًا في الملف
  final double? number;

  /// الخلية تاريخ/وقت
  final bool isDate;

  const ImportCell(this.text, {this.number, this.isDate = false});

  static const ImportCell empty = ImportCell('');

  bool get isEmpty => text.trim().isEmpty;
}

/// صف من جدول مع رقمه الحقيقي في الملف (يبدأ من 1)
class ImportRow {
  final int number;
  final List<ImportCell> cells;

  const ImportRow(this.number, this.cells);

  bool get isEmpty => cells.every((c) => c.isEmpty);

  ImportCell cellAt(int column) =>
      column < cells.length ? cells[column] : ImportCell.empty;
}

/// ورقة (أو جدول) من ملف
class ImportSheet {
  final String name;
  final List<ImportRow> rows;

  const ImportSheet(this.name, this.rows);

  bool get isEmpty => rows.every((r) => r.isEmpty);
}

/// رسالة واحدة جاهزة للتحليل (نص كامل مع سطر الفاصل أو هيدر واتساب)
class ImportMessage {
  final String text;

  /// وقت الرسالة (لمحادثات واتساب المصدَّرة فقط)
  final DateTime? timestamp;

  const ImportMessage(this.text, {this.timestamp});
}

enum ImportFileKind { excel, csv, whatsapp, list, text }

extension ImportFileKindInfo on ImportFileKind {
  String get label {
    switch (this) {
      case ImportFileKind.excel:
        return 'جدول Excel';
      case ImportFileKind.csv:
        return 'جدول CSV';
      case ImportFileKind.whatsapp:
        return 'محادثة واتساب';
      case ImportFileKind.list:
        return 'قائمة أسطر';
      case ImportFileKind.text:
        return 'نص';
    }
  }
}

/// نتيجة تحويل ملف واحد
class ImportConversion {
  final String fileName;
  final ImportFileKind kind;
  final List<ImportMessage> messages;

  /// ملاحظات للمستخدم (الأعمدة المعتمدة، الصفوف المتجاهلة...)
  final List<String> notes;

  /// سبب الفشل إن لم يمكن قراءة الملف
  final String? error;

  const ImportConversion({
    required this.fileName,
    required this.kind,
    this.messages = const [],
    this.notes = const [],
    this.error,
  });

  factory ImportConversion.failure(String fileName, String error) =>
      ImportConversion(
        fileName: fileName,
        kind: ImportFileKind.text,
        error: error,
      );

  bool get ok => error == null && messages.isNotEmpty;

  int get messageCount => messages.length;

  /// النص الكامل الذي يوضع في صفحة تحليل النص
  String get text => textOf(messages);

  static String textOf(Iterable<ImportMessage> messages) =>
      messages.map((m) => m.text.trimRight()).join('\n');

  /// الأيام المختلفة في محادثة واتساب (للاختيار حسب الفترة)
  List<DateTime> get distinctDays {
    final days = <DateTime>{};
    for (final m in messages) {
      final t = m.timestamp;
      if (t != null) days.add(DateTime(t.year, t.month, t.day));
    }
    final list = days.toList()..sort();
    return list;
  }
}

/// إعدادات التحويل (تُبنى من إعدادات التطبيق)
class ImportOptions {
  /// كلمة الاسم التي تسبق اسم المستفيد في الرسالة الناتجة (مثال: المستفيد)
  final String nameKeyword;

  /// كلمة المبلغ التي تسبق المبلغ (مثال: المبلغ)
  final String amountKeyword;

  /// كل كلمات الاسم في الإعدادات (لتفادي تكرارها في أسطر إضافية)
  final List<String> nameKeywords;

  /// كل كلمات المبلغ في الإعدادات
  final List<String> amountKeywords;

  /// كلمات ورموز العملات (مفاتيح وقيم خريطة العملات)
  final List<String> currencyWords;

  /// لاحقة تضاف لعنوان كل صف (مثال: اسم الملف عند استيراد عدة ملفات)
  final String labelSuffix;

  const ImportOptions({
    this.nameKeyword = 'المستفيد',
    this.amountKeyword = 'المبلغ',
    this.nameKeywords = const ['المستفيد'],
    this.amountKeywords = const ['المبلغ'],
    this.currencyWords = const [],
    this.labelSuffix = '',
  });

  factory ImportOptions.fromSettings({
    required List<String> nameKeywords,
    required List<String> amountKeywords,
    required Map<String, String> currencyMap,
  }) {
    final names = nameKeywords
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final amounts = amountKeywords
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return ImportOptions(
      nameKeyword: _pickKeyword(names, preferred: 'المستفيد'),
      amountKeyword: _pickKeyword(amounts, preferred: 'المبلغ'),
      nameKeywords: names,
      amountKeywords: amounts,
      currencyWords: {
        ...currencyMap.keys,
        ...currencyMap.values,
      }.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
    );
  }

  ImportOptions copyWith({String? labelSuffix}) => ImportOptions(
    nameKeyword: nameKeyword,
    amountKeyword: amountKeyword,
    nameKeywords: nameKeywords,
    amountKeywords: amountKeywords,
    currencyWords: currencyWords,
    labelSuffix: labelSuffix ?? this.labelSuffix,
  );

  static final RegExp _letters = RegExp(r'[a-zA-Z\u0621-\u064A]');

  static String _pickKeyword(List<String> list, {required String preferred}) {
    if (list.isEmpty) return '';
    final pref = normalizeArabic(preferred);
    for (final k in list) {
      if (normalizeArabic(k) == pref) return k;
    }
    // كلمة واضحة (أحرف وطول > 3) أفضل من «ل» و«إلى» ومن الرموز مثل $
    final specific = list
        .where((k) => _letters.hasMatch(k) && k.replaceAll(' ', '').length > 3)
        .toList();
    if (specific.isNotEmpty) return specific.first;
    final withLetters = list.where((k) => _letters.hasMatch(k)).toList();
    return withLetters.isNotEmpty ? withLetters.first : '';
  }
}
