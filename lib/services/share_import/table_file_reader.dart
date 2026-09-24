// lib/services/share_import/table_file_reader.dart
// -------------------------------------------------------------
// قراءة ملف كجدول كما هو (أعمدة وصفوف بدون تفسير) لصفحة «مطابقة غير
// المستلمة» — سواء اختير الملف من داخل الصفحة أو تمت مشاركته مع التطبيق:
// - Excel الحديث (xlsx) بقارئنا الخفيف ثم مكتبة excel كاحتياط.
// - ملفات .xls التي هي في الحقيقة HTML أو XML (تصدير الأنظمة والبنوك).
// - CSV/TSV بأي فاصل مع علامات الاقتباس وأي ترميز (UTF-8/UTF-16/ويندوز).
// - تجاوز أسطر العنوان التي تسبق صف أسماء الأعمدة، وصفوف المجموع.
// - الملفات النصية تُعاد كأسطر أيضًا (لصيغة «الاسم - المبلغ - العملة»).
// (ملف Dart نقي بدون Flutter — يعمل داخل Isolate)
// -------------------------------------------------------------

import 'import_models.dart';
import 'import_text_decoding.dart';
import 'xlsx_reader.dart';

enum TableFileKind { excel, csv, text }

/// طلب قراءة (قابل للإرسال إلى Isolate عبر compute)
class TableFileRequest {
  final List<int> bytes;
  final String fileName;
  final String? mimeType;

  const TableFileRequest({
    required this.bytes,
    required this.fileName,
    this.mimeType,
  });
}

/// دالة عليا تُستخدم مع compute()
TableFileData readTableFileRequest(TableFileRequest r) => TableFileReader.read(
  bytes: r.bytes,
  fileName: r.fileName,
  mimeType: r.mimeType,
);

/// ملف مقروء كجدول
class TableFileData {
  final String fileName;
  final TableFileKind kind;

  /// أسماء الأعمدة (فريدة وغير فارغة)
  final List<String> headers;

  /// صفوف البيانات بعد صف الأعمدة — نص كل خلية بترتيب [headers]
  final List<List<String>> rows;

  /// رقم كل صف من [rows] في الملف الأصلي (للعرض: «صف 12»)
  final List<int> rowNumbers;

  /// أسطر الملف (للملفات النصية) أو أول خلية في كل صف (لجداول العمود
  /// الواحد) — لتجربة صيغة «الاسم - المبلغ - العملة»
  final List<String> lines;

  /// الورقة المقروءة وعدد الأوراق التي فيها بيانات
  final String sheetName;
  final int sheetCount;

  /// ملاحظات القراءة (أسطر عنوان متجاوزة، صف مجموع، أوراق أخرى...)
  final List<String> notes;

  final String? error;

  const TableFileData({
    required this.fileName,
    required this.kind,
    this.headers = const [],
    this.rows = const [],
    this.rowNumbers = const [],
    this.lines = const [],
    this.sheetName = '',
    this.sheetCount = 0,
    this.notes = const [],
    this.error,
  });

  const TableFileData.failure(this.fileName, String this.error)
    : kind = TableFileKind.text,
      headers = const [],
      rows = const [],
      rowNumbers = const [],
      lines = const [],
      sheetName = '',
      sheetCount = 0,
      notes = const [];

  bool get ok => error == null;

  /// جدول فيه عمودان على الأقل وصف بيانات واحد على الأقل
  bool get hasTable => ok && headers.length >= 2 && rows.isNotEmpty;

  String get kindLabel {
    switch (kind) {
      case TableFileKind.excel:
        return 'جدول Excel';
      case TableFileKind.csv:
        return 'جدول CSV';
      case TableFileKind.text:
        return 'ملف نصي';
    }
  }

  /// كل نصوص الملف (لاقتراح الحساب المذكور فيه)
  String get plainText {
    final sb = StringBuffer();
    if (headers.isNotEmpty) sb.writeln(headers.join(' '));
    for (final r in rows) {
      sb.writeln(r.join(' '));
    }
    if (rows.isEmpty) {
      for (final l in lines) {
        sb.writeln(l);
      }
    }
    return sb.toString();
  }

  TableFileData _withNote(String note) => TableFileData(
    fileName: fileName,
    kind: kind,
    headers: headers,
    rows: rows,
    rowNumbers: rowNumbers,
    lines: lines,
    sheetName: sheetName,
    sheetCount: sheetCount,
    notes: [note, ...notes],
    error: error,
  );
}

class TableFileReader {
  TableFileReader._();

  static const String unsupportedMessage =
      'صيغة الملف غير مدعومة — الملفات المدعومة: Excel (xlsx) و CSV و TXT';

  static TableFileData read({
    required List<int> bytes,
    required String fileName,
    String? mimeType,
  }) {
    try {
      return _read(bytes, fileName, (mimeType ?? '').toLowerCase());
    } catch (e) {
      return TableFileData.failure(fileName, 'تعذر قراءة الملف: $e');
    }
  }

  static String _extensionOf(String fileName) {
    final i = fileName.lastIndexOf('.');
    if (i < 0 || i == fileName.length - 1) return '';
    return fileName.substring(i + 1).toLowerCase().trim();
  }

  static TableFileData _read(List<int> bytes, String fileName, String mime) {
    if (bytes.isEmpty) return TableFileData.failure(fileName, 'الملف فارغ');

    if (isZipBytes(bytes)) {
      List<ImportSheet>? sheets;
      Object? firstError;
      try {
        sheets = readXlsxSheets(bytes);
      } on XlsxFormatException {
        return _readZip(bytes, fileName);
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
        return TableFileData.failure(
          fileName,
          'تعذر قراءة ملف Excel${firstError == null ? '' : ' ($firstError)'}',
        );
      }
      return _fromSheets(sheets, fileName, TableFileKind.excel);
    }

    if (isOleBytes(bytes)) {
      return TableFileData.failure(
        fileName,
        'هذا ملف Excel قديم (xls) أو محمي بكلمة سر — افتحه واحفظه بصيغة xlsx ثم أعد المحاولة',
      );
    }
    if (bytesStartWith(bytes, '%PDF')) {
      return TableFileData.failure(
        fileName,
        'ملفات PDF غير مدعومة — استخدم ملف Excel أو CSV أو نص',
      );
    }
    if (looksBinaryBytes(bytes)) {
      return TableFileData.failure(fileName, unsupportedMessage);
    }
    return _fromText(
      decodeImportText(bytes),
      fileName,
      ext: _extensionOf(fileName),
      mime: mime,
    );
  }

  /// ملف مضغوط ليس Excel: نقرأ ملف CSV أو ملفًا نصيًا من داخله
  static TableFileData _readZip(List<int> bytes, String fileName) {
    final entries = zipTextEntries(bytes);
    if (entries.isEmpty) {
      return TableFileData.failure(fileName, unsupportedMessage);
    }
    final entry = entries.firstWhere(
      (e) => e.name.toLowerCase().endsWith('.csv'),
      orElse: () => entries.first,
    );
    final t = _fromText(
      decodeImportText(entry.bytes),
      fileName,
      ext: _extensionOf(entry.name),
    );
    return t.ok ? t._withNote('من داخل الملف المضغوط: ${entry.name}') : t;
  }

  static TableFileData _fromText(
    String text,
    String fileName, {
    String ext = '',
    String mime = '',
  }) {
    if (text.trim().isEmpty) {
      return TableFileData.failure(fileName, 'الملف فارغ');
    }
    if (looksLikeSpreadsheetMl(text)) {
      return _fromSheets(
        parseSpreadsheetMl(text),
        fileName,
        TableFileKind.excel,
      );
    }
    if (looksLikeHtmlTable(text)) {
      return _fromSheets(parseHtmlTables(text), fileName, TableFileKind.excel);
    }

    final lines = _linesOf(text);
    final tab = ext == 'tsv' || mime.contains('tab-separated');
    final isCsv =
        tab ||
        ext == 'csv' ||
        mime.contains('csv') ||
        mime.contains('comma-separated');
    final isSheetExt = ext == 'xls' || ext == 'xlsx' || ext == 'xlsm';
    final delimiter = tab ? '\t' : detectDelimiter(text);
    if (isCsv || (isSheetExt && delimiter != null)) {
      return _fromSheets(
        [parseDelimitedSheet(text, delimiter: delimiter)],
        fileName,
        TableFileKind.csv,
        lines: lines,
      );
    }

    // ملف نصي: الأسطر (لصيغة «الاسم - المبلغ - العملة») + جدول إن كان مفصولًا
    if (delimiter != null) {
      final t = _fromSheets(
        [parseDelimitedSheet(text, delimiter: delimiter)],
        fileName,
        TableFileKind.text,
        lines: lines,
      );
      if (t.ok) return t;
    }
    return TableFileData(
      fileName: fileName,
      kind: TableFileKind.text,
      lines: lines,
      sheetCount: 1,
    );
  }

  static final RegExp _sepLineRe = RegExp(
    r'^"?sep=.\"?$',
    caseSensitive: false,
  );

  static List<String> _linesOf(String text) {
    final out = <String>[];
    for (final l in text.split('\n')) {
      final t = l.trim();
      if (t.isEmpty) continue;
      if (out.isEmpty && _sepLineRe.hasMatch(t)) continue;
      out.add(t);
    }
    return out;
  }

  static TableFileData _fromSheets(
    List<ImportSheet> sheets,
    String fileName,
    TableFileKind kind, {
    List<String>? lines,
  }) {
    final nonEmpty = sheets.where((s) => !s.isEmpty).toList();
    if (nonEmpty.isEmpty) {
      return TableFileData.failure(fileName, 'الملف لا يحتوي بيانات');
    }
    final sheet = nonEmpty.first;
    final rows = sheet.rows.where((r) => !r.isEmpty).toList();
    final notes = <String>[
      if (nonEmpty.length > 1)
        'الملف فيه ${nonEmpty.length} أوراق — تمت قراءة الورقة الأولى «${sheet.name}»',
    ];

    final headerIndex = headerRowIndex(rows);
    if (headerIndex > 0) {
      final what = headerIndex == 1
          ? 'سطر عنوان'
          : headerIndex == 2
          ? 'سطرَي عنوان'
          : '$headerIndex أسطر عنوان';
      notes.add('تم تجاوز $what قبل صف الأعمدة');
    }
    final headerRow = rows[headerIndex];
    final data = rows.sublist(headerIndex + 1);

    // الأعمدة: كل عمود له عنوان أو فيه بيانات
    var width = 0;
    for (final r in rows.skip(headerIndex)) {
      if (r.cells.length > width) width = r.cells.length;
    }
    final columns = <int>[];
    final headers = <String>[];
    final used = <String>{};
    for (var c = 0; c < width; c++) {
      final title = _collapse(headerRow.cellAt(c).text);
      if (title.isEmpty && !data.any((r) => !r.cellAt(c).isEmpty)) continue;
      final base = title.isNotEmpty
          ? title
          : 'عمود ${kind == TableFileKind.excel ? _columnLetter(c) : '${c + 1}'}';
      var name = base;
      for (var n = 2; !used.add(name.toLowerCase()); n++) {
        name = '$base ($n)';
      }
      columns.add(c);
      headers.add(name);
    }

    final outRows = <List<String>>[];
    final numbers = <int>[];
    var totals = 0;
    for (final r in data) {
      if (isTotalRow(r)) {
        totals++;
        continue;
      }
      outRows.add([for (final c in columns) _collapse(r.cellAt(c).text)]);
      numbers.add(r.number);
    }
    if (totals > 0) {
      notes.add(
        totals == 1
            ? 'تم تجاهل صف المجموع'
            : totals == 2
            ? 'تم تجاهل صفَّي مجموع'
            : 'تم تجاهل $totals صفوف مجموع',
      );
    }

    return TableFileData(
      fileName: fileName,
      kind: kind,
      headers: headers,
      rows: outRows,
      rowNumbers: numbers,
      lines:
          lines ??
          [
            for (final r in rows)
              _collapse(r.cells.firstWhere((c) => !c.isEmpty).text),
          ],
      sheetName: sheet.name,
      sheetCount: nonEmpty.length,
      notes: notes,
    );
  }

  /// صف أسماء الأعمدة. إذا بدأ الملف بأسطر عنوان (خلية نصية واحدة مثل
  /// «كشف حوالات شهر 5») يليها صف عناوين نصية نبدأ من صف العناوين،
  /// وفي غير ذلك يبقى الصف الأول هو صف الأعمدة (كما كان).
  static int headerRowIndex(List<ImportRow> rows) {
    for (var i = 0; i < rows.length && i < 8; i++) {
      final cells = rows[i].cells.where((c) => !c.isEmpty).toList();
      // بدأت البيانات (أرقام/تواريخ) قبل ظهور صف عناوين
      if (cells.any(_isValueCell)) return 0;
      if (cells.length >= 2) return i;
    }
    return 0;
  }

  static bool _isValueCell(ImportCell c) =>
      c.number != null || c.isDate || _valueLikeRe.hasMatch(_collapse(c.text));

  static const Set<String> _totalWords = {
    'مجموع',
    'المجموع',
    'المجموع الكلي',
    'اجمالي',
    'الاجمالي',
    'الاجمالي الكلي',
    'اجمالي المبلغ',
    'اجمالي المبالغ',
    'مجموع المبالغ',
    'total',
    'totals',
    'grand total',
    'sum',
    'subtotal',
    'sub total',
  };

  /// نص عبارة عن رقم أو مبلغ أو تاريخ (بدون حروف)
  static final RegExp _valueLikeRe = RegExp(
    r'^[\s0-9\u0660-\u0669.,٬٫+\-/:$€£%()]+$',
  );

  /// صف مجموع: نصوصه كلها كلمات مثل «المجموع» أو «الإجمالي» والباقي أرقام
  static bool isTotalRow(ImportRow r) {
    var words = 0;
    for (final c in r.cells) {
      if (c.isEmpty || c.number != null) continue;
      final t = _collapse(c.text);
      if (_valueLikeRe.hasMatch(t)) continue;
      final key = t
          .toLowerCase()
          .replaceAll(RegExp('[:：.]'), '')
          .replaceAll(RegExp('[أإآ]'), 'ا')
          .trim();
      if (!_totalWords.contains(key)) return false;
      words++;
    }
    return words > 0;
  }

  static String _collapse(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _columnLetter(int col) {
    var n = col + 1;
    var out = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      out = String.fromCharCode(65 + r) + out;
      n = (n - 1) ~/ 26;
    }
    return out;
  }
}
