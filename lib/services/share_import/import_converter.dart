// lib/services/share_import/import_converter.dart
// -------------------------------------------------------------
// تحويل ملف مستورد (Excel / CSV / نص / تصدير محادثة واتساب) إلى نص جاهز
// لصفحة «تحليل النص»، بحيث:
// - كل صف في الجدول يصبح رسالة مستقلة يبدأ بفاصل «—— صف N ——».
// - يُكتب الاسم بعد كلمة الاسم من الإعدادات (مثل «المستفيد:») والمبلغ بعد
//   كلمة المبلغ (مثل «المبلغ:») حتى تلتقطهما شاشتا الإضافة والتسليم تلقائيًا.
// - تُكتشف الأعمدة من عناوينها (الاسم/المبلغ/العملة/الهاتف...) أو من محتواها.
// (ملف Dart نقي بدون Flutter — يعمل داخل Isolate)
// -------------------------------------------------------------

import '../detection/segment_splitter.dart';
import '../detection/text_tokens.dart';
import 'import_models.dart';
import 'import_text_decoding.dart';
import 'whatsapp_export.dart';
import 'xlsx_reader.dart';

/// طلب تحويل (قابل للإرسال إلى Isolate عبر compute)
class ImportRequest {
  final List<int> bytes;
  final String fileName;
  final String? mimeType;
  final ImportOptions options;

  const ImportRequest({
    required this.bytes,
    required this.fileName,
    this.mimeType,
    this.options = const ImportOptions(),
  });
}

/// دالة عليا تُستخدم مع compute()
ImportConversion convertImportRequest(ImportRequest r) =>
    ImportFileConverter.convert(
      bytes: r.bytes,
      fileName: r.fileName,
      mimeType: r.mimeType,
      options: r.options,
    );

class ImportFileConverter {
  ImportFileConverter._();

  /// الامتدادات المدعومة (لنافذة اختيار الملف)
  static const List<String> supportedExtensions = [
    'xlsx',
    'xls',
    'csv',
    'tsv',
    'txt',
    'zip',
  ];

  static const String unsupportedMessage =
      'صيغة الملف غير مدعومة — الملفات المدعومة: Excel (xlsx) و CSV و TXT';

  static ImportConversion convert({
    required List<int> bytes,
    required String fileName,
    String? mimeType,
    ImportOptions options = const ImportOptions(),
  }) {
    try {
      return _convert(bytes, fileName, (mimeType ?? '').toLowerCase(), options);
    } catch (e) {
      return ImportConversion.failure(fileName, 'تعذر قراءة الملف: $e');
    }
  }

  /// نص تمت مشاركته مباشرة من تطبيق آخر (بدون ملف)
  static ImportConversion convertText(
    String text, {
    String fileName = 'نص مشارك',
    ImportOptions options = const ImportOptions(),
  }) {
    try {
      return _convertText(
        text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
        fileName,
        options,
      );
    } catch (e) {
      return ImportConversion.failure(fileName, 'تعذر قراءة النص: $e');
    }
  }

  static String extensionOf(String fileName) {
    final i = fileName.lastIndexOf('.');
    if (i < 0 || i == fileName.length - 1) return '';
    return fileName.substring(i + 1).toLowerCase().trim();
  }

  static ImportConversion _convert(
    List<int> bytes,
    String fileName,
    String mime,
    ImportOptions o,
  ) {
    if (bytes.isEmpty) return ImportConversion.failure(fileName, 'الملف فارغ');
    final ext = extensionOf(fileName);

    if (isZipBytes(bytes)) {
      List<ImportSheet>? sheets;
      Object? firstError;
      try {
        sheets = readXlsxSheets(bytes);
      } on XlsxFormatException {
        return _convertZip(bytes, fileName, o);
      } catch (e) {
        firstError = e;
      }
      if (sheets == null || sheets.every((s) => s.isEmpty)) {
        try {
          final alt = readXlsxWithExcelPackage(bytes);
          if (alt.any((s) => !s.isEmpty)) sheets = alt;
        } catch (e) {
          firstError ??= e;
        }
      }
      if (sheets == null) {
        return ImportConversion.failure(
          fileName,
          'تعذر قراءة ملف Excel${firstError == null ? '' : ' ($firstError)'}',
        );
      }
      return _convertSheets(sheets, fileName, ImportFileKind.excel, o);
    }

    if (isOleBytes(bytes)) {
      return ImportConversion.failure(
        fileName,
        'هذا ملف Excel قديم (xls) أو محمي بكلمة سر — افتحه واحفظه بصيغة xlsx ثم شاركه من جديد',
      );
    }
    if (bytesStartWith(bytes, '%PDF')) {
      return ImportConversion.failure(
        fileName,
        'ملفات PDF غير مدعومة للتحليل — شارك ملف Excel أو CSV أو نص',
      );
    }
    if (looksBinaryBytes(bytes)) {
      return ImportConversion.failure(fileName, unsupportedMessage);
    }

    final text = decodeImportText(bytes);
    if (text.trim().isEmpty) {
      return ImportConversion.failure(fileName, 'الملف فارغ');
    }

    if (looksLikeSpreadsheetMl(text)) {
      return _convertSheets(
        parseSpreadsheetMl(text),
        fileName,
        ImportFileKind.excel,
        o,
      );
    }
    if (looksLikeHtmlTable(text)) {
      return _convertSheets(
        parseHtmlTables(text),
        fileName,
        ImportFileKind.excel,
        o,
      );
    }

    final isCsv =
        ext == 'csv' ||
        ext == 'tsv' ||
        mime.contains('csv') ||
        mime.contains('comma-separated') ||
        mime.contains('tab-separated');
    final isSheetExt = ext == 'xls' || ext == 'xlsx' || ext == 'xlsm';
    if (isCsv || (isSheetExt && detectDelimiter(text) != null)) {
      final sheet = parseDelimitedSheet(
        text,
        delimiter: ext == 'tsv' || mime.contains('tab-separated') ? '\t' : null,
      );
      return _convertSheets([sheet], fileName, ImportFileKind.csv, o);
    }
    return _convertText(text, fileName, o);
  }

  /// ملف مضغوط ليس Excel: نبحث بداخله عن ملف نصي (تصدير محادثة واتساب)
  static ImportConversion _convertZip(
    List<int> bytes,
    String fileName,
    ImportOptions o,
  ) {
    final entries = zipTextEntries(bytes);
    if (entries.isEmpty) {
      return ImportConversion.failure(fileName, unsupportedMessage);
    }
    final entry = entries.first;
    final text = decodeImportText(entry.bytes);
    final ImportConversion c;
    if (entry.name.toLowerCase().endsWith('.csv')) {
      c = _convertSheets(
        [parseDelimitedSheet(text)],
        fileName,
        ImportFileKind.csv,
        o,
      );
    } else {
      c = _convertText(text, fileName, o);
    }
    if (!c.ok) return c;
    return ImportConversion(
      fileName: fileName,
      kind: c.kind,
      messages: c.messages,
      notes: ['من داخل الملف المضغوط: ${entry.name}', ...c.notes],
    );
  }

  // ====================== النصوص ======================

  static ImportConversion _convertText(
    String text,
    String fileName,
    ImportOptions o,
  ) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return ImportConversion.failure(fileName, 'النص فارغ');

    if (looksLikeWhatsAppExport(trimmed)) {
      final r = parseWhatsAppExport(trimmed);
      if (r != null && r.messages.isNotEmpty) {
        final notes = <String>[
          'محادثة واتساب مصدَّرة: ${r.messages.length} رسالة',
        ];
        if (r.skipped > 0) {
          notes.add('تم تجاهل ${r.skipped} رسالة نظام أو وسائط أو محذوفة');
        }
        return ImportConversion(
          fileName: fileName,
          kind: ImportFileKind.whatsapp,
          messages: r.messages,
          notes: notes,
        );
      }
    }

    final waCount = SegmentSplitter.countWhatsappHeaders(trimmed);
    if (waCount > 0) {
      return ImportConversion(
        fileName: fileName,
        kind: ImportFileKind.text,
        messages: [ImportMessage(trimmed)],
        notes: ['يحتوي $waCount رسالة واتساب منسوخة'],
      );
    }

    final lines = trimmed.split('\n');
    final nonEmpty = lines.where((l) => l.trim().isNotEmpty).toList();
    final tabbed = nonEmpty.where((l) => l.contains('\t')).length;
    if (nonEmpty.length >= 2 && tabbed >= nonEmpty.length * 0.6) {
      final sheet = parseDelimitedSheet(trimmed, delimiter: '\t');
      final c = _convertSheets([sheet], fileName, ImportFileKind.csv, o);
      if (c.ok) return c;
    }

    final entries = <_LineEntry>[
      for (var i = 0; i < lines.length; i++)
        if (lines[i].trim().isNotEmpty) _LineEntry(i + 1, lines[i].trim()),
    ];
    final list = _ListConverter(o).tryConvert(entries, label: 'سطر');
    if (list != null) {
      return ImportConversion(
        fileName: fileName,
        kind: ImportFileKind.list,
        messages: list.messages,
        notes: list.notes,
      );
    }

    return ImportConversion(
      fileName: fileName,
      kind: ImportFileKind.text,
      messages: [ImportMessage(trimmed)],
      notes: const ['نص بدون هيدر واتساب: سيُحلَّل كرسالة واحدة'],
    );
  }

  // ====================== الجداول ======================

  static ImportConversion _convertSheets(
    List<ImportSheet> sheets,
    String fileName,
    ImportFileKind kind,
    ImportOptions o,
  ) {
    final nonEmpty = sheets.where((s) => !s.isEmpty).toList();
    if (nonEmpty.isEmpty) {
      return ImportConversion.failure(fileName, 'الملف لا يحتوي بيانات');
    }
    final multi = nonEmpty.length > 1;
    final messages = <ImportMessage>[];
    final notes = <String>[];
    for (final sheet in nonEmpty) {
      final r = _TableConverter(
        sheet,
        o,
        sheetLabel: multi ? sheet.name : '',
      ).run();
      messages.addAll(r.messages);
      for (final n in r.notes) {
        notes.add(multi ? '«${sheet.name}»: $n' : n);
      }
    }
    if (messages.isEmpty) {
      return ImportConversion(
        fileName: fileName,
        kind: kind,
        notes: notes,
        error: 'لم أجد في الملف صفوفًا فيها أسماء أو مبالغ',
      );
    }
    if (multi) notes.insert(0, 'تمت قراءة ${nonEmpty.length} أوراق من الملف');
    return ImportConversion(
      fileName: fileName,
      kind: kind,
      messages: messages,
      notes: notes,
    );
  }
}

// ====================== أدوات مشتركة ======================

final RegExp _spaceRe = RegExp(r'\s+');
final RegExp _letterRe = RegExp(r'[a-zA-Z\u0621-\u064A]');
final RegExp _digitRe = RegExp(r'[0-9\u0660-\u0669]');

String _collapse(String s) => s.replaceAll(_spaceRe, ' ').trim();

String _safeLabelPart(String s) =>
    _collapse(s.replaceAll('—', '-').replaceAll('\n', ' '));

/// مفتاح موحّد لعنوان عمود أو كلمة
String _normKey(String s) {
  var t = normalizeArabic(s.replaceAll('\u0640', '')).toLowerCase();
  final b = StringBuffer();
  for (final r in t.runes) {
    if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else {
      b.writeCharCode(r);
    }
  }
  t = b.toString();
  t = t.replaceAll(RegExp(r'''[:：*()\[\]{}"'.،,;؛!؟?/\\|_\-–—]'''), ' ');
  return _collapse(t);
}

/// مفتاح عملة: بدون نقاط ومسافات (ل.س → لس)
String _currencyKey(String s) =>
    normalizeArabic(s).toLowerCase().replaceAll(RegExp(r'[\s.\-_]'), '');

const List<String> _builtinCurrencies = [
  r'$',
  'دولار',
  'دولارات',
  'دولار امريكي',
  'usd',
  r'us$',
  'يورو',
  '€',
  'eur',
  'euro',
  'تركي',
  'ليره تركيه',
  'tl',
  'try',
  '₺',
  'سوري',
  'ليره سوريه',
  'ليره',
  'ل س',
  'sp',
  'syp',
  'ريال',
  'ريال سعودي',
  'sar',
  'درهم',
  'aed',
  'دينار',
  'jod',
  'iqd',
  'kwd',
  'جنيه',
  'egp',
  '£',
  'gbp',
  'استرليني',
];

class _Vocab {
  final Set<String> currency;
  final Set<String> nameKeywordKeys;
  final Set<String> settingsNameKeys;
  final Set<String> amountKeywordKeys;

  _Vocab(ImportOptions o)
    : currency = {
        for (final c in [..._builtinCurrencies, ...o.currencyWords])
          if (_currencyKey(c).isNotEmpty) _currencyKey(c),
      },
      nameKeywordKeys = {
        for (final k in [...o.nameKeywords, 'المستفيد', 'الاسم', 'اسم'])
          if (_normKey(k).isNotEmpty) _normKey(k),
      },
      settingsNameKeys = {
        for (final k in o.nameKeywords)
          if (_normKey(k).isNotEmpty) _normKey(k),
      },
      amountKeywordKeys = {
        for (final k in [
          ...o.amountKeywords,
          'المبلغ',
          'مبلغ',
          'القيمه',
          'قيمه',
        ])
          if (_normKey(k).isNotEmpty) _normKey(k),
      };

  static String _stripPrefix(String w) {
    for (final p in const ['بال', 'لل', 'ال', 'ب']) {
      if (w.startsWith(p) && w.length > p.length + 1) {
        return w.substring(p.length);
      }
    }
    return w;
  }

  bool isCurrencyText(String text) {
    final k = _currencyKey(text);
    if (k.isEmpty) return false;
    if (currency.contains(k)) return true;
    return currency.contains(
      _currencyKey(_stripPrefix(normalizeArabic(text).trim())),
    );
  }

  /// أول كلمة عملة داخل عنوان (مثل «المبلغ بالدولار» → دولار)
  String currencyInHeader(String raw) {
    if (isCurrencyText(raw)) return raw.trim();
    final words = raw.trim().split(_spaceRe);
    for (var i = 0; i < words.length; i++) {
      if (i + 1 < words.length) {
        final two = '${words[i]} ${words[i + 1]}';
        if (isCurrencyText(two)) return two;
      }
      final w = words[i].replaceAll(RegExp(r'[()\[\]:]'), '');
      if (w.isEmpty || !isCurrencyText(w)) continue;
      final stripped = _stripPrefix(w);
      return currency.contains(_currencyKey(stripped)) ? stripped : w;
    }
    return '';
  }

  /// رمز أو اختصار عملة (وليس كلمة قد تكون اسمًا مثل «تركي» أو «السوري»)
  bool isCurrencySymbolOrCode(String text) {
    final t = text.trim();
    if (!isCurrencyText(t)) return false;
    return !RegExp(r'[\u0621-\u064A]').hasMatch(t) || t.length <= 3;
  }

  /// هل يحتوي النص كلمة اسم من الإعدادات؟ (حتى لا يصبح سطرًا منافسًا للاسم)
  bool isNameKeywordText(String text) {
    final words = _normKey(text).split(' ');
    return words.any(settingsNameKeys.contains);
  }
}

enum _Role {
  unknown,
  serial,
  reference,
  phone,
  status,
  date,
  currency,
  total,
  amount,
  beneficiary,
  sender,
  namePart,
  name,
  notes,
}

class _HeaderInfo {
  final _Role role;
  final String currency;
  final int? suffix;
  const _HeaderInfo(this.role, {this.currency = '', this.suffix});
  static const unknown = _HeaderInfo(_Role.unknown);
}

const Set<String> _indexWords = {
  '#',
  'م',
  'ت',
  'ر',
  'ر م',
  'م ر',
  'رقم',
  'الرقم',
  'تسلسل',
  'التسلسل',
  'الرقم التسلسلي',
  'رقم تسلسلي',
  'no',
  'n',
  'nr',
  'num',
  'number',
  'id',
  'sn',
  's n',
  'serial',
  'seq',
  'index',
};
const Set<String> _referenceWords = {
  'الكود',
  'كود',
  'المرجع',
  'مرجع',
  'الاشعار',
  'اشعار',
  'الايصال',
  'ايصال',
  'الوصل',
  'reference',
  'ref',
  'code',
};
const Set<String> _referencePhrases = {
  'رقم الحواله',
  'رقم العمليه',
  'رقم الاشعار',
  'رقم الايصال',
  'رقم الوصل',
  'رقم المرجع',
  'transaction id',
};
const Set<String> _phoneWords = {
  'هاتف',
  'الهاتف',
  'جوال',
  'الجوال',
  'موبايل',
  'الموبايل',
  'تلفون',
  'التلفون',
  'تليفون',
  'التليفون',
  'واتس',
  'الواتس',
  'واتساب',
  'الواتساب',
  'phone',
  'mobile',
  'tel',
  'telephone',
  'whatsapp',
  'cell',
};
const Set<String> _statusWords = {'الحاله', 'حاله', 'الوضع', 'status', 'state'};
const Set<String> _dateWords = {
  'تاريخ',
  'التاريخ',
  'وقت',
  'الوقت',
  'الساعه',
  'date',
  'time',
  'datetime',
  'timestamp',
};
const Set<String> _currencyHeaderWords = {
  'العمله',
  'عمله',
  'العملات',
  'currency',
  'cur',
  'ccy',
};
const Set<String> _totalWords = {
  'الاجمالي',
  'اجمالي',
  'المجموع',
  'مجموع',
  'الكلي',
  'الصافي',
  'total',
  'net',
  'sum',
};
const Set<String> _amountWords = {
  'المبلغ',
  'مبلغ',
  'المبالغ',
  'مبالغ',
  'القيمه',
  'قيمه',
  'amount',
  'value',
  'amt',
};
const Set<String> _beneficiaryWords = {
  'المستفيد',
  'مستفيد',
  'المستلم',
  'مستلم',
  'beneficiary',
  'receiver',
  'recipient',
  'payee',
};
const Set<String> _beneficiaryPhrases = {
  'المرسل اليه',
  'المحول اليه',
  'المحول له',
  'المرسل له',
};
const Set<String> _senderWords = {'المرسل', 'مرسل', 'المحول', 'sender', 'from'};
const Set<String> _namePartWords = {
  'الكنيه',
  'كنيه',
  'العائله',
  'اللقب',
  'لقب',
  'الشهره',
  'surname',
};
const Set<String> _namePartPhrases = {
  'اسم الاب',
  'اسم الام',
  'اسم العائله',
  'اسم الجد',
  'first name',
  'last name',
  'family name',
  'middle name',
  'father name',
};
const Set<String> _nameWords = {
  'الاسم',
  'اسم',
  'الزبون',
  'زبون',
  'العميل',
  'عميل',
  'الشخص',
  'name',
  'customer',
  'client',
  'person',
};
const Set<String> _notesWords = {
  'ملاحظات',
  'ملاحظه',
  'الملاحظات',
  'الملاحظه',
  'البيان',
  'بيان',
  'الوصف',
  'وصف',
  'التفاصيل',
  'تفاصيل',
  'السبب',
  'note',
  'notes',
  'description',
  'details',
  'remark',
  'remarks',
  'memo',
  'comment',
  'comments',
};
const Set<String> _totalRowWords = {
  'المجموع',
  'مجموع',
  'الاجمالي',
  'اجمالي',
  'المجموع الكلي',
  'الاجمالي العام',
  'الصافي',
  'total',
  'grand total',
  'sum',
};

bool _hasWord(List<String> words, Set<String> vocab) => words.any(
  (w) => vocab.contains(w) || vocab.contains(_Vocab._stripPrefix(w)),
);

bool _hasPhrase(String key, Set<String> phrases) {
  final padded = ' $key ';
  return phrases.any((p) => padded.contains(' $p '));
}

_HeaderInfo _classifyHeader(String raw, _Vocab v) {
  var key = _normKey(raw);
  if (raw.trim() == '#') return const _HeaderInfo(_Role.serial);
  if (key.isEmpty) return _HeaderInfo.unknown;
  int? suffix;
  final sm = RegExp(r'^(.*?)\s*(\d{1,2})$').firstMatch(key);
  if (sm != null && (sm.group(1) ?? '').isNotEmpty) {
    suffix = int.tryParse(sm.group(2)!);
    key = sm.group(1)!.trim();
  }
  final words = key.split(' ');

  if (_indexWords.contains(key)) return const _HeaderInfo(_Role.serial);
  if (_hasPhrase(key, _referencePhrases) || _hasWord(words, _referenceWords)) {
    return const _HeaderInfo(_Role.reference);
  }
  if (_hasWord(words, _phoneWords)) return const _HeaderInfo(_Role.phone);
  if (_hasWord(words, _statusWords)) return const _HeaderInfo(_Role.status);
  if (_hasWord(words, _dateWords) || key == 'اليوم' || key == 'day') {
    return const _HeaderInfo(_Role.date);
  }
  if (_hasWord(words, _currencyHeaderWords)) {
    return _HeaderInfo(_Role.currency, suffix: suffix);
  }
  final headerCurrency = v.currencyInHeader(raw);
  if (_hasWord(words, _totalWords)) {
    return _HeaderInfo(_Role.total, currency: headerCurrency, suffix: suffix);
  }
  if (_hasWord(words, _amountWords) || headerCurrency.isNotEmpty) {
    return _HeaderInfo(_Role.amount, currency: headerCurrency, suffix: suffix);
  }
  if (_hasPhrase(key, _beneficiaryPhrases) ||
      _hasWord(words, _beneficiaryWords)) {
    return const _HeaderInfo(_Role.beneficiary);
  }
  if (_hasWord(words, _senderWords)) return const _HeaderInfo(_Role.sender);
  if (_hasPhrase(key, _namePartPhrases) || _hasWord(words, _namePartWords)) {
    return const _HeaderInfo(_Role.namePart);
  }
  if (_hasWord(words, _nameWords)) return const _HeaderInfo(_Role.name);
  if (_hasWord(words, _notesWords)) return const _HeaderInfo(_Role.notes);
  return _HeaderInfo.unknown;
}

/// مبلغ داخل خلية: 500 أو 1,500,000 أو 500$ أو $500 أو 500 دولار
({String amount, String currency, double value})? _amountOf(
  ImportCell cell,
  _Vocab v, {
  bool lenient = false,
}) {
  if (cell.isDate) return null;
  if (cell.number != null) {
    return (amount: cell.text, currency: '', value: cell.number!);
  }
  final text = _collapse(cell.text);
  if (text.isEmpty || !_digitRe.hasMatch(text)) return null;
  final m = RegExp(
    r'^(.*?)([+-]?[0-9\u0660-\u0669][0-9\u0660-\u0669.,٬٫\s]*[0-9\u0660-\u0669]|[0-9\u0660-\u0669])(.*)$',
  ).firstMatch(text);
  if (m == null) return null;
  final prefix = m.group(1)!.trim();
  final number = m.group(2)!.replaceAll(RegExp(r'\s'), '');
  final suffix = m.group(3)!.trim();
  if (_digitRe.hasMatch(suffix) || _digitRe.hasMatch(prefix)) return null;
  if (number.contains('/') || number.contains(':')) return null;
  String currency = '';
  if (prefix.isNotEmpty) {
    if (!v.isCurrencyText(prefix)) return null;
    currency = prefix;
  }
  if (suffix.isNotEmpty) {
    if (v.isCurrencyText(suffix)) {
      currency = currency.isEmpty ? suffix : currency;
    } else if (!lenient || suffix.split(' ').length > 3) {
      return null;
    } else {
      currency = currency.isEmpty ? suffix : currency;
    }
  }
  final value = _numberValue(number);
  return (amount: number, currency: currency, value: value);
}

String _asciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

/// قيمة رقم نصي: 1,500,000 → 1500000 ، 12,50 → 12.5 ، ١٥٠٠ → 1500
double _numberValue(String number) {
  var t = _asciiDigits(
    squashDigitSeparators(number.trim()),
  ).replaceAll('\u066B', '.').replaceAll('\u066C', '');
  if (t.contains(',') && !t.contains('.')) t = t.replaceAll(',', '.');
  t = t.replaceAll(',', '').replaceAll(RegExp(r'[^0-9.+\-]'), '');
  return double.tryParse(t) ?? 0;
}

final RegExp _dateTextRe = RegExp(r'^\d{1,4}[/.\-]\d{1,2}[/.\-]\d{1,4}');

bool _isIdLike(ImportCell c) {
  final t = c.text.trim();
  if (isPhoneLike(t)) return true;
  final d = digitsOnly(t);
  if (d.length < 10 ||
      d.length != t.replaceAll(RegExp(r'[\s+\-]'), '').length) {
    return false;
  }
  final trailingZeros = d.length - d.replaceFirst(RegExp(r'0+$'), '').length;
  return trailingZeros < 5;
}

class _ColStats {
  int nonEmpty = 0;
  int numeric = 0;
  int idLike = 0;
  int textual = 0;
  int currency = 0;
  int date = 0;
  int words = 0;
  int length = 0;
  bool sequential = false;

  double ratio(int n) => nonEmpty == 0 ? 0 : n / nonEmpty;
  double get avgWords => textual == 0 ? 0 : words / textual;
  double get avgLength => textual == 0 ? 0 : length / textual;

  static _ColStats of(List<ImportRow> rows, int col, _Vocab v) {
    final s = _ColStats();
    final ints = <int>[];
    for (final r in rows) {
      final c = r.cellAt(col);
      if (c.isEmpty) continue;
      s.nonEmpty++;
      final t = _collapse(c.text);
      if (c.isDate || _dateTextRe.hasMatch(_asciiDigits(t))) {
        s.date++;
        continue;
      }
      if (_isIdLike(c)) {
        s.idLike++;
      } else if (_amountOf(c, v) != null) {
        s.numeric++;
        final iv = c.number?.round() ?? int.tryParse(digitsOnly(t));
        if (iv != null && digitsOnly(t).length == t.length) ints.add(iv);
      }
      if (v.isCurrencyText(t)) {
        s.currency++;
      } else if (_letterRe.hasMatch(t) && !_digitRe.hasMatch(t)) {
        s.textual++;
        s.words += t.split(' ').length;
        s.length += t.length;
      }
    }
    if (ints.length >= 3 && ints.first <= 2) {
      var steps = 0;
      for (var i = 1; i < ints.length; i++) {
        if (ints[i] == ints[i - 1] + 1) steps++;
      }
      s.sequential = steps >= (ints.length - 1) * 0.8;
    }
    return s;
  }
}

class _AmountCol {
  final int col;
  final String headerCurrency;
  final int? suffix;
  const _AmountCol(this.col, this.headerCurrency, this.suffix);
}

class _TableResult {
  final List<ImportMessage> messages;
  final List<String> notes;
  const _TableResult(this.messages, this.notes);
}

String _columnLetter(int col) {
  var n = col + 1;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

class _TableConverter {
  final ImportSheet sheet;
  final ImportOptions o;
  final String sheetLabel;
  final _Vocab v;

  _TableConverter(this.sheet, this.o, {this.sheetLabel = ''}) : v = _Vocab(o);

  String _label(int rowNo, {String extra = '', String word = 'صف'}) {
    final parts = <String>['$word $rowNo'];
    if (sheetLabel.trim().isNotEmpty) parts.add(_safeLabelPart(sheetLabel));
    if (o.labelSuffix.trim().isNotEmpty) {
      parts.add(_safeLabelPart(o.labelSuffix));
    }
    if (extra.trim().isNotEmpty) parts.add(_safeLabelPart(extra));
    return parts.join(' • ');
  }

  _TableResult run() {
    final rows = sheet.rows.where((r) => !r.isEmpty).toList();
    if (rows.isEmpty) return const _TableResult([], []);

    var width = 0;
    for (final r in rows) {
      var w = r.cells.length;
      while (w > 0 && r.cells[w - 1].isEmpty) {
        w--;
      }
      if (w > width) width = w;
    }
    final used = <int>[
      for (var c = 0; c < width; c++)
        if (rows.any((r) => !r.cellAt(c).isEmpty)) c,
    ];
    if (used.length <= 1) {
      return _singleColumn(rows, used.isEmpty ? 0 : used.first);
    }

    final headerIdx = _findHeader(rows);
    final headerRow = headerIdx >= 0 ? rows[headerIdx] : null;
    final data = rows.sublist(headerIdx + 1);
    final notes = <String>[];
    if (headerIdx > 0) notes.add('تم تجاهل $headerIdx سطر عنوان فوق الجدول');
    if (data.isEmpty) return _TableResult(const [], notes);

    String headerOf(int c) =>
        headerRow == null ? '' : _collapse(headerRow.cellAt(c).text);
    final infos = <int, _HeaderInfo>{
      for (final c in used)
        c: headerRow == null
            ? _HeaderInfo.unknown
            : _classifyHeader(headerOf(c), v),
    };
    final stats = <int, _ColStats>{
      for (final c in used) c: _ColStats.of(data, c, v),
    };

    // ---------- الاسم ----------
    List<int> byRole(_Role r) => [
      for (final c in used)
        if (infos[c]!.role == r) c,
    ];
    var nameCols = <int>[];
    final beneficiary = byRole(_Role.beneficiary);
    final names = byRole(_Role.name);
    final parts = byRole(_Role.namePart);
    final senders = byRole(_Role.sender);
    if (beneficiary.isNotEmpty) {
      nameCols = beneficiary;
    } else if (names.isNotEmpty) {
      nameCols = [...names, ...parts]..sort();
    } else if (parts.isNotEmpty) {
      nameCols = parts;
    } else if (senders.isNotEmpty) {
      nameCols = senders;
    }

    // ---------- المبالغ ----------
    var amounts = <_AmountCol>[
      for (final c in used)
        if (infos[c]!.role == _Role.amount)
          _AmountCol(c, infos[c]!.currency, infos[c]!.suffix),
    ];
    final totals = byRole(_Role.total);
    if (amounts.isEmpty && totals.isNotEmpty) {
      amounts = [
        for (final c in totals)
          _AmountCol(c, infos[c]!.currency, infos[c]!.suffix),
      ];
    }

    // ---------- العملة ----------
    final currencyCols = byRole(_Role.currency);

    // ---------- اكتشاف من المحتوى للأعمدة غير المعروفة ----------
    final unknown = [
      for (final c in used)
        if (infos[c]!.role == _Role.unknown) c,
    ];
    final skippedIndex = <int>{};
    for (final c in unknown) {
      if (stats[c]!.sequential) skippedIndex.add(c);
    }
    final contentPhone = <int>{};
    final contentDate = <int>{};
    for (final c in unknown) {
      if (skippedIndex.contains(c)) continue;
      final s = stats[c]!;
      if (s.ratio(s.idLike) >= 0.6) {
        contentPhone.add(c);
      } else if (s.ratio(s.date) >= 0.6) {
        contentDate.add(c);
      }
    }
    bool free(int c) =>
        infos[c]!.role == _Role.unknown &&
        !skippedIndex.contains(c) &&
        !contentPhone.contains(c) &&
        !contentDate.contains(c);

    if (currencyCols.isEmpty) {
      for (final c in used) {
        if (free(c) && stats[c]!.ratio(stats[c]!.currency) >= 0.6) {
          currencyCols.add(c);
        }
      }
    }
    if (amounts.isEmpty) {
      int? best;
      var bestRatio = 0.0;
      for (final c in used) {
        if (!free(c) || currencyCols.contains(c)) continue;
        final r = stats[c]!.ratio(stats[c]!.numeric);
        if (r >= 0.6 && r > bestRatio + 0.001) {
          best = c;
          bestRatio = r;
        }
      }
      if (best != null) amounts = [_AmountCol(best, '', null)];
    }
    if (nameCols.isEmpty) {
      int? best;
      var bestRatio = 0.0;
      for (final c in used) {
        if (!free(c) || currencyCols.contains(c)) continue;
        if (amounts.any((a) => a.col == c)) continue;
        final s = stats[c]!;
        final r = s.ratio(s.textual);
        if (r >= 0.6 &&
            s.avgWords <= 6 &&
            s.avgLength <= 45 &&
            r > bestRatio + 0.001) {
          best = c;
          bestRatio = r;
        }
      }
      if (best != null) nameCols = [best];
    }

    if (nameCols.isEmpty && amounts.isEmpty) {
      return _rowsAsText(data, headerRow, used, notes);
    }

    // ربط كل عمود مبلغ بعمود عملته
    final currencyFor = <int, int>{};
    if (currencyCols.isNotEmpty) {
      for (final a in amounts) {
        int? pick;
        if (a.suffix != null) {
          for (final c in currencyCols) {
            if (infos[c]!.suffix == a.suffix) pick = c;
          }
        }
        if (pick == null && currencyCols.length == 1) pick = currencyCols.first;
        if (pick == null) {
          final right = currencyCols.where((c) => c > a.col).toList();
          final left = currencyCols.where((c) => c < a.col).toList();
          pick = right.isNotEmpty
              ? right.first
              : (left.isNotEmpty ? left.last : null);
        }
        if (pick != null) currencyFor[a.col] = pick;
      }
    }

    // الأعمدة الإضافية (تظهر كسطر «العنوان: القيمة»)
    final amountCols = amounts.map((a) => a.col).toSet();
    final extras = <int>[];
    for (final c in used) {
      if (nameCols.contains(c) ||
          amountCols.contains(c) ||
          currencyCols.contains(c)) {
        continue;
      }
      final role = infos[c]!.role;
      if (skippedIndex.contains(c) || contentDate.contains(c)) continue;
      if (role == _Role.serial ||
          role == _Role.date ||
          role == _Role.status ||
          role == _Role.total) {
        continue;
      }
      if (headerRow == null) {
        // بدون عناوين: نضيف فقط الأعمدة النصية حتى لا تربك الأرقام كشف المبلغ
        final s = stats[c]!;
        if (s.ratio(s.textual) < 0.6) continue;
      }
      extras.add(c);
    }

    // ملاحظة الأعمدة المعتمدة
    String colName(int c) {
      final h = headerOf(c);
      return h.isNotEmpty ? '«$h»' : 'العمود ${_columnLetter(c)}';
    }

    final used0 = <String>[];
    if (nameCols.isNotEmpty) {
      used0.add('الاسم ← ${nameCols.map(colName).join(' + ')}');
    }
    if (amounts.isNotEmpty) {
      used0.add('المبلغ ← ${amounts.map((a) => colName(a.col)).join('، ')}');
    }
    if (currencyCols.isNotEmpty) {
      used0.add('العملة ← ${currencyCols.map(colName).join('، ')}');
    }
    if (used0.isNotEmpty) notes.add('الأعمدة: ${used0.join(' • ')}');

    // ---------- بناء الرسائل ----------
    final messages = <ImportMessage>[];
    var noAmount = 0, empty = 0, totalRows = 0, splitRows = 0;
    for (var i = 0; i < data.length; i++) {
      final row = data[i];
      final name = _collapse(
        nameCols
            .map((c) => _collapse(row.cellAt(c).text))
            .where((s) => s.isNotEmpty)
            .join(' '),
      );
      final found = <({String amount, String currency, double value})>[];
      for (final a in amounts) {
        final cell = row.cellAt(a.col);
        if (cell.isEmpty) continue;
        var parsed = _amountOf(cell, v, lenient: true);
        if (parsed == null) {
          final t = _collapse(cell.text);
          if (_letterRe.hasMatch(t) && !v.isCurrencyText(t)) {
            parsed = (amount: t, currency: '', value: 1);
          } else {
            continue;
          }
        }
        if (parsed.value == 0) continue;
        var cur = '';
        final cc = currencyFor[a.col];
        if (cc != null) cur = _collapse(row.cellAt(cc).text);
        if (cur.isEmpty) cur = a.headerCurrency;
        if (cur.isEmpty) cur = parsed.currency;
        found.add((amount: parsed.amount, currency: cur, value: parsed.value));
      }

      if (name.isEmpty && found.isEmpty) {
        empty++;
        continue;
      }
      if (name.isNotEmpty && _totalRowWords.contains(_normKey(name))) {
        totalRows++;
        continue;
      }
      if (amounts.isNotEmpty && found.isEmpty) {
        noAmount++;
        continue;
      }
      if (name.isEmpty &&
          i == data.length - 1 &&
          found.length == 1 &&
          messages.length >= 2) {
        // صف أخير بلا اسم ومبلغه = مجموع ما قبله → صف مجموع
        final col = amounts.first.col;
        var sum = 0.0;
        for (var k = 0; k < i; k++) {
          final p = _amountOf(data[k].cellAt(col), v, lenient: true);
          if (p != null) sum += p.value;
        }
        if ((sum - found.first.value).abs() <= (sum.abs() * 0.005) + 0.01) {
          totalRows++;
          continue;
        }
      }

      final extraLines = <String>[];
      for (final c in extras) {
        final value = _collapse(row.cellAt(c).text);
        if (value.isEmpty) continue;
        final h = headerOf(c);
        if (h.isEmpty || v.isNameKeywordText(h)) {
          extraLines.add(value);
        } else {
          extraLines.add('$h: $value');
        }
      }

      if (found.length > 1) splitRows++;
      final pieces = found.isEmpty ? [null] : found;
      for (final p in pieces) {
        final lines = <String>[
          SegmentSplitter.rowMarkerLine(
            _label(
              row.number,
              extra: found.length > 1
                  ? (p!.currency.isNotEmpty ? p.currency : p.amount)
                  : '',
            ),
          ),
          if (name.isNotEmpty) _nameLine(name),
          if (p != null) _amountLine(p.amount, p.currency),
          ...extraLines,
        ];
        messages.add(ImportMessage(lines.join('\n')));
      }
    }

    if (noAmount > 0) notes.add('تم تجاهل $noAmount صف بدون مبلغ');
    if (totalRows > 0) notes.add('تم تجاهل $totalRows صف مجموع');
    if (empty > 0) notes.add('تم تجاهل $empty صف فارغ');
    if (splitRows > 0) {
      notes.add(
        '$splitRows صف فيه أكثر من مبلغ: قُسم كل صف إلى رسالة لكل مبلغ',
      );
    }
    return _TableResult(messages, notes);
  }

  String _nameLine(String name) =>
      o.nameKeyword.trim().isEmpty ? name : '${o.nameKeyword.trim()}: $name';

  String _amountLine(String amount, String currency) {
    final value = _collapse('$amount $currency');
    return o.amountKeyword.trim().isEmpty
        ? value
        : '${o.amountKeyword.trim()}: $value';
  }

  int _findHeader(List<ImportRow> rows) {
    var best = -1;
    var bestScore = 0;
    final limit = rows.length < 6 ? rows.length : 6;
    for (var i = 0; i < limit; i++) {
      final cells = rows[i].cells.where((c) => !c.isEmpty).toList();
      if (cells.length < 2) continue;
      if (cells.any(
        (c) => c.number != null || c.isDate || _amountOf(c, v) != null,
      )) {
        continue;
      }
      var roles = 0, currencies = 0;
      for (final c in cells) {
        final info = _classifyHeader(c.text, v);
        if (info.role == _Role.unknown) continue;
        if (info.role == _Role.amount &&
            info.currency.isNotEmpty &&
            v.isCurrencyText(c.text)) {
          currencies++;
        } else {
          roles++;
        }
      }
      final score = roles * 2 + currencies;
      if ((roles >= 1 || currencies >= 2) && score > bestScore) {
        best = i;
        bestScore = score;
      }
    }
    return best;
  }

  /// جدول بدون أعمدة واضحة: كل صف رسالة نصية (الخلايا مفصولة بـ « - »)
  _TableResult _rowsAsText(
    List<ImportRow> data,
    ImportRow? header,
    List<int> used,
    List<String> notes,
  ) {
    final entries = <_LineEntry>[
      for (final r in data)
        _LineEntry(
          r.number,
          used
              .map((c) => _collapse(r.cellAt(c).text))
              .where((s) => s.isNotEmpty)
              .join(' - '),
        ),
    ];
    final list = _ListConverter(
      o,
      sheetLabel: sheetLabel,
    ).tryConvert(entries, label: 'صف', force: true);
    return _TableResult(list?.messages ?? const [], [
      ...notes,
      ...?list?.notes,
    ]);
  }

  _TableResult _singleColumn(List<ImportRow> rows, int col) {
    final entries = <_LineEntry>[
      for (final r in rows)
        if (!r.cellAt(col).isEmpty)
          _LineEntry(r.number, r.cellAt(col).text.trim()),
    ];
    if (entries.isEmpty) return const _TableResult([], []);
    final messageLike = entries
        .where((e) => e.text.contains('\n') || e.text.length > 80)
        .length;
    final lc = _ListConverter(o, sheetLabel: sheetLabel);
    if (messageLike >= entries.length * 0.5) {
      return _TableResult(
        [for (final e in entries) lc.rawMessage(e, 'صف')],
        const ['كل خلية في العمود اعتُبرت رسالة مستقلة'],
      );
    }
    final list = lc.tryConvert(entries, label: 'صف', force: true);
    return _TableResult(list?.messages ?? const [], list?.notes ?? const []);
  }
}

// ====================== قوائم الأسطر ======================

class _LineEntry {
  final int number;
  final String text;
  const _LineEntry(this.number, this.text);
}

class _ListLine {
  final String name;
  final String amount;
  final String currency;
  final String rest;
  const _ListLine(this.name, this.amount, this.currency, this.rest);
}

class _ListConverter {
  final ImportOptions o;
  final String sheetLabel;
  final _Vocab v;

  _ListConverter(this.o, {this.sheetLabel = ''}) : v = _Vocab(o);

  String _label(String word, int n) {
    final parts = <String>['$word $n'];
    if (sheetLabel.trim().isNotEmpty) parts.add(_safeLabelPart(sheetLabel));
    if (o.labelSuffix.trim().isNotEmpty) {
      parts.add(_safeLabelPart(o.labelSuffix));
    }
    return parts.join(' • ');
  }

  ImportMessage rawMessage(_LineEntry e, String word) => ImportMessage(
    '${SegmentSplitter.rowMarkerLine(_label(word, e.number))}\n${e.text.trim()}',
  );

  ImportMessage _structured(_LineEntry e, _ListLine p, String word) {
    final lines = <String>[
      SegmentSplitter.rowMarkerLine(_label(word, e.number)),
      o.nameKeyword.trim().isEmpty
          ? p.name
          : '${o.nameKeyword.trim()}: ${p.name}',
      if (o.amountKeyword.trim().isEmpty)
        _collapse('${p.amount} ${p.currency}')
      else
        '${o.amountKeyword.trim()}: ${_collapse('${p.amount} ${p.currency}')}',
      if (p.rest.isNotEmpty) p.rest,
    ];
    return ImportMessage(lines.join('\n'));
  }

  /// يحوّل الأسطر إذا كانت قائمة «الاسم - المبلغ - العملة».
  /// [force]: عند التحويل من جدول نقبل حتى لو قلّت نسبة الأسطر المفهومة.
  ({List<ImportMessage> messages, List<String> notes})? tryConvert(
    List<_LineEntry> entries, {
    required String label,
    bool force = false,
  }) {
    if (entries.isEmpty) return null;
    final parsed = <_ListLine?>[for (final e in entries) parseLine(e.text)];
    final ok = parsed.whereType<_ListLine>().length;
    final isList = ok >= 2 && ok >= entries.length * 0.6;
    if (!isList && !force) return null;

    final messages = <ImportMessage>[];
    var titles = 0, raw = 0;
    for (var i = 0; i < entries.length; i++) {
      final p = parsed[i];
      final e = entries[i];
      if (p != null) {
        messages.add(_structured(e, p, label));
        continue;
      }
      // سطر عنوان في البداية (بدون أرقام) يُتجاهل
      if (isList && messages.isEmpty && !_digitRe.hasMatch(e.text)) {
        titles++;
        continue;
      }
      raw++;
      messages.add(rawMessage(e, label));
    }
    final notes = <String>[];
    if (isList) {
      notes.add('قائمة: كل سطر فيه اسم ومبلغ اعتُبر رسالة مستقلة ($ok سطر)');
    }
    if (titles > 0) notes.add('تم تجاهل $titles سطر عنوان');
    if (isList && raw > 0) notes.add('$raw سطر لم تُفهم صيغته وأضيف كما هو');
    return (messages: messages, notes: notes);
  }

  static final RegExp _numberingRe = RegExp(
    r'^[(\[]?[0-9\u0660-\u0669]{1,3}[)\].\-:]$|^[•*▪●◦·\-–]$',
  );

  bool _isKeyword(String token) {
    final k = _normKey(token);
    return v.nameKeywordKeys.contains(k) ||
        v.amountKeywordKeys.contains(k) ||
        _phoneWords.contains(k) ||
        phoneWordKeys.contains(k);
  }

  /// سطر مثل: «أحمد علي - 500 - دولار» أو «أحمد علي 500$» أو «500 دولار أحمد»
  _ListLine? parseLine(String line) {
    var s = line.trim();
    if (s.isEmpty || s.length > 160 || s.contains('\n')) return null;
    s = s.replaceAll(RegExp(r'\s*[|\t]\s*'), ' ');
    s = s.replaceAll(RegExp(r'\s+[-–—]+\s+'), ' ');
    s = s.replaceAll(
      RegExp(
        r'(?<=[^\s0-9\u0660-\u0669])[-–—]+|[-–—]+(?=[^\s0-9\u0660-\u0669])',
      ),
      ' ',
    );
    s = s.replaceAll(RegExp(r'[،,؛;]\s+'), ' ');
    s = s.replaceAll(RegExp(r':\s*'), ' ');
    var tokens = s.split(_spaceRe).where((t) => t.isNotEmpty).toList();
    if (tokens.isNotEmpty && _numberingRe.hasMatch(tokens.first)) {
      tokens = tokens.sublist(1);
    }
    if (tokens.length < 2) return null;

    // فصل العملة الملتصقة بالرقم: 500$ أو $500 أو 500دولار
    final expanded = <String>[];
    final attached = RegExp(
      r'^([^\d\u0660-\u0669]*?)([0-9\u0660-\u0669][0-9\u0660-\u0669.,٬٫]*)([^\d\u0660-\u0669]*)$',
    );
    for (final t in tokens) {
      final m = attached.firstMatch(t);
      if (m != null && (m.group(1)!.isNotEmpty || m.group(3)!.isNotEmpty)) {
        final pre = m.group(1)!, num = m.group(2)!, post = m.group(3)!;
        final preOk = pre.isEmpty || v.isCurrencyText(pre);
        final postOk = post.isEmpty || v.isCurrencyText(post);
        if (preOk && postOk) {
          if (pre.isNotEmpty) expanded.add(pre);
          expanded.add(num);
          if (post.isNotEmpty) expanded.add(post);
          continue;
        }
      }
      expanded.add(t);
    }
    tokens = expanded;

    bool isNumber(String t) =>
        _digitRe.hasMatch(t) &&
        RegExp(
          r'^[+]?[0-9\u0660-\u0669][0-9\u0660-\u0669.,٬٫]*$',
        ).hasMatch(t) &&
        !isPhoneLike(t) &&
        (double.tryParse(
                  digitsOnly(squashDigitSeparators(t).split('.').first),
                ) ??
                0) >
            0;

    // أول رقم ليس هاتفًا ولا تاريخًا
    var amountIdx = -1;
    for (var i = 0; i < tokens.length; i++) {
      if (isNumber(tokens[i])) {
        // رقم ترقيم صغير في أول السطر يتبعه اسم ثم رقم آخر → ترقيم
        if (i == 0 &&
            digitsOnly(tokens[i]).length <= 2 &&
            tokens.skip(1).any(isNumber) &&
            tokens.length > 2 &&
            _letterRe.hasMatch(tokens[1])) {
          continue;
        }
        amountIdx = i;
        break;
      }
    }
    if (amountIdx < 0) return null;

    final used = <int>{amountIdx};
    // العملة: كلمة/كلمتان بعد الرقم أو قبله مباشرة
    var currency = '';
    if (amountIdx + 2 < tokens.length) {
      final two = '${tokens[amountIdx + 1]} ${tokens[amountIdx + 2]}';
      if (v.isCurrencyText(two)) {
        currency = two;
        used.addAll([amountIdx + 1, amountIdx + 2]);
      }
    }
    if (currency.isEmpty &&
        amountIdx + 1 < tokens.length &&
        v.isCurrencyText(tokens[amountIdx + 1])) {
      currency = tokens[amountIdx + 1];
      used.add(amountIdx + 1);
    }
    if (currency.isEmpty &&
        amountIdx > 0 &&
        v.isCurrencySymbolOrCode(tokens[amountIdx - 1])) {
      currency = tokens[amountIdx - 1];
      used.add(amountIdx - 1);
    }

    bool isNameToken(int i) {
      final t = tokens[i];
      if (used.contains(i) ||
          !_letterRe.hasMatch(t) ||
          _digitRe.hasMatch(t) ||
          _isKeyword(t)) {
        return false;
      }
      // كلمة عملة قبل المبلغ قد تكون جزءًا من الاسم (تركي العلي، أحمد السوري)
      if (i < amountIdx) return !v.isCurrencySymbolOrCode(t);
      return !v.isCurrencyText(t);
    }

    // الاسم: الكلمات قبل المبلغ، وإلا الكلمات بعده
    var nameIdx = <int>[];
    for (var i = 0; i < amountIdx; i++) {
      if (used.contains(i)) continue;
      if (isNameToken(i)) {
        nameIdx.add(i);
      } else if (!_isKeyword(tokens[i]) && nameIdx.isNotEmpty) {
        nameIdx = <int>[];
      }
    }
    if (nameIdx.isEmpty) {
      for (var i = amountIdx + 1; i < tokens.length; i++) {
        if (used.contains(i)) continue;
        if (isNameToken(i)) {
          nameIdx.add(i);
        } else if (nameIdx.isNotEmpty) {
          break;
        }
      }
    }
    if (nameIdx.isEmpty || nameIdx.length > 6) return null;
    if (nameIdx.length == 1 &&
        tokens[nameIdx.first]
                .replaceAll(RegExp(r'[^a-zA-Z\u0621-\u064A]'), '')
                .length <
            2) {
      return null;
    }
    used.addAll(nameIdx);

    final rest = <String>[
      for (var i = 0; i < tokens.length; i++)
        if (!used.contains(i) && !_isKeyword(tokens[i])) tokens[i],
    ];
    return _ListLine(
      nameIdx.map((i) => tokens[i]).join(' '),
      tokens[amountIdx],
      currency,
      rest.join(' '),
    );
  }
}
