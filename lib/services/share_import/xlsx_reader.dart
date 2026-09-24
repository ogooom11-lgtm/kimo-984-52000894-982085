// lib/services/share_import/xlsx_reader.dart
// -------------------------------------------------------------
// قارئ خفيف لملفات Excel الحديثة (xlsx) لغرض تحليل النص:
// - يقرأ القيم المحفوظة للخلايا (بما فيها نتائج المعادلات).
// - يدعم النصوص المشتركة والنصوص المضمنة والأرقام والتواريخ (حسب التنسيق).
// - يتجاوز الأوراق المخفية ويحافظ على ترتيب الأوراق في الملف.
// عند فشله نجرب مكتبة excel كاحتياط.
// (ملف Dart نقي بدون Flutter)
// -------------------------------------------------------------

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xls;

import 'import_models.dart';
import 'import_text_decoding.dart';

bool isZipBytes(List<int> b) =>
    b.length > 4 &&
    b[0] == 0x50 &&
    b[1] == 0x4B &&
    b[2] == 0x03 &&
    b[3] == 0x04;

/// ملف OLE قديم (xls 97-2003 أو ملف Office محمي بكلمة سر)
bool isOleBytes(List<int> b) =>
    b.length > 8 &&
    b[0] == 0xD0 &&
    b[1] == 0xCF &&
    b[2] == 0x11 &&
    b[3] == 0xE0 &&
    b[4] == 0xA1 &&
    b[5] == 0xB1 &&
    b[6] == 0x1A &&
    b[7] == 0xE1;

class XlsxFormatException implements Exception {
  final String message;
  const XlsxFormatException(this.message);
  @override
  String toString() => message;
}

final RegExp _attrRe = RegExp(r'([\w:.-]+)\s*=\s*"([^"]*)"');

Map<String, String> _attrs(String raw) {
  final out = <String, String>{};
  for (final m in _attrRe.allMatches(raw)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

/// قيمة سمة بدون الاعتماد على بادئة النطاق (r:id أو x:id ...)
String? _attrEndingWith(Map<String, String> a, String name) {
  if (a.containsKey(name)) return a[name];
  for (final e in a.entries) {
    if (e.key.endsWith(':$name')) return e.value;
  }
  return null;
}

final RegExp _escapedCharRe = RegExp(r'_x([0-9A-Fa-f]{4})_');

String _xmlText(String raw) {
  var s = decodeXmlEntities(raw);
  if (s.contains('_x')) {
    s = s.replaceAllMapped(
      _escapedCharRe,
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    );
  }
  return s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

final RegExp _phoneticRe = RegExp(
  r'<(?:\w+:)?rPh\b.*?</(?:\w+:)?rPh>',
  dotAll: true,
);
final RegExp _tRe = RegExp(
  r'<(?:\w+:)?t\b[^>]*?(?:/>|>(.*?)</(?:\w+:)?t>)',
  dotAll: true,
);

/// نص عنصر يحتوي وسوم t (مع دمج أجزاء النص المنسق)
String _richText(String inner) {
  final cleaned = inner.contains('rPh')
      ? inner.replaceAll(_phoneticRe, '')
      : inner;
  final b = StringBuffer();
  for (final m in _tRe.allMatches(cleaned)) {
    b.write(_xmlText(m.group(1) ?? ''));
  }
  return b.toString();
}

List<String> _parseSharedStrings(String? xml) {
  if (xml == null) return const [];
  final siRe = RegExp(
    r'<(?:\w+:)?si\b[^>]*?(?:/>|>(.*?)</(?:\w+:)?si>)',
    dotAll: true,
  );
  return [for (final m in siRe.allMatches(xml)) _richText(m.group(1) ?? '')];
}

/// تنسيق أرقام يمثل تاريخًا/وقتًا؟
bool _isDateFormatCode(String code) {
  final lower = code.toLowerCase().trim();
  if (lower.isEmpty || lower == 'general' || lower == '@') return false;
  var s = lower
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\\.'), '')
      .replaceAll(RegExp(r'[_*].'), '');
  // [h] [mm] [ss] = وقت منقضٍ، باقي الأقواس (العملة/اللون/اللغة) تُحذف
  final elapsed = RegExp(r'\[(h+|m+|s+)\]').hasMatch(s);
  s = s.replaceAll(RegExp(r'\[[^\]]*\]'), '');
  if (elapsed) return true;
  return RegExp(r'[ydhs]').hasMatch(s) ||
      (s.contains('m') && !s.contains('e+') && !s.contains('e-'));
}

bool _isTimeOnlyCode(String code) {
  final s = code
      .toLowerCase()
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '');
  return !s.contains('y') && !s.contains('d') && s.contains('h');
}

const Map<int, String> _builtinDateFormats = {
  14: 'mm-dd-yy',
  15: 'd-mmm-yy',
  16: 'd-mmm',
  17: 'mmm-yy',
  18: 'h:mm AM/PM',
  19: 'h:mm:ss AM/PM',
  20: 'h:mm',
  21: 'h:mm:ss',
  22: 'm/d/yy h:mm',
  45: 'mm:ss',
  46: '[h]:mm:ss',
  47: 'mmss.0',
};

class _DateStyles {
  /// فهرس النمط → true = وقت فقط، false = تاريخ
  final Map<int, bool> styles;
  const _DateStyles(this.styles);
}

_DateStyles _parseDateStyles(String? xml) {
  if (xml == null) return const _DateStyles({});
  final custom = <int, String>{};
  final numFmtRe = RegExp(r'<(?:\w+:)?numFmt\b([^>]*?)/?>');
  for (final m in numFmtRe.allMatches(xml)) {
    final a = _attrs(m.group(1) ?? '');
    final id = int.tryParse(a['numFmtId'] ?? '');
    if (id != null) custom[id] = decodeXmlEntities(a['formatCode'] ?? '');
  }
  final xfsBlock = RegExp(
    r'<(?:\w+:)?cellXfs\b[^>]*>(.*?)</(?:\w+:)?cellXfs>',
    dotAll: true,
  ).firstMatch(xml);
  final styles = <int, bool>{};
  if (xfsBlock != null) {
    final xfRe = RegExp(r'<(?:\w+:)?xf\b([^>]*?)(?:/>|>)', dotAll: true);
    var i = 0;
    for (final m in xfRe.allMatches(xfsBlock.group(1) ?? '')) {
      final a = _attrs(m.group(1) ?? '');
      final id = int.tryParse(a['numFmtId'] ?? '') ?? 0;
      String? code = custom[id] ?? _builtinDateFormats[id];
      final isBuiltinDate =
          (id >= 14 && id <= 22) ||
          (id >= 27 && id <= 36) ||
          (id >= 45 && id <= 47) ||
          (id >= 50 && id <= 58);
      if (code != null && _isDateFormatCode(code)) {
        styles[i] = _isTimeOnlyCode(code);
      } else if (code == null && isBuiltinDate) {
        styles[i] = false;
      }
      i++;
    }
  }
  return _DateStyles(styles);
}

int _columnIndex(String ref) {
  var col = 0;
  for (var i = 0; i < ref.length; i++) {
    final c = ref.codeUnitAt(i);
    if (c >= 65 && c <= 90) {
      col = col * 26 + (c - 64);
    } else if (c >= 97 && c <= 122) {
      col = col * 26 + (c - 96);
    } else {
      break;
    }
  }
  return col - 1;
}

DateTime _excelSerialToDate(double serial, bool date1904) {
  final base = date1904 ? DateTime.utc(1904, 1, 1) : DateTime.utc(1899, 12, 30);
  final ms = (serial * 86400000).round();
  return base.add(Duration(milliseconds: ms));
}

final RegExp _rowRe = RegExp(
  r'<(?:\w+:)?row\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?row>)',
  dotAll: true,
);
final RegExp _cellRe = RegExp(
  r'<(?:\w+:)?c\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?c>)',
  dotAll: true,
);
final RegExp _vRe = RegExp(
  r'<(?:\w+:)?v\b[^>]*>(.*?)</(?:\w+:)?v>',
  dotAll: true,
);
final RegExp _isRe = RegExp(
  r'<(?:\w+:)?is\b[^>]*>(.*?)</(?:\w+:)?is>',
  dotAll: true,
);

const int _maxRows = 20000;
const int _maxColumns = 200;

List<ImportRow> _parseSheetRows(
  String xml,
  List<String> shared,
  _DateStyles dates,
  bool date1904,
) {
  final rows = <ImportRow>[];
  var lastRow = 0;
  for (final rm in _rowRe.allMatches(xml)) {
    final ra = _attrs(rm.group(1) ?? '');
    final rowNo = int.tryParse(ra['r'] ?? '') ?? (lastRow + 1);
    lastRow = rowNo;
    final inner = rm.group(2);
    if (inner == null || inner.isEmpty) continue;
    final cells = <ImportCell>[];
    var lastCol = -1;
    for (final cm in _cellRe.allMatches(inner)) {
      final ca = _attrs(cm.group(1) ?? '');
      final ref = ca['r'];
      final col = ref != null ? _columnIndex(ref) : lastCol + 1;
      lastCol = col;
      if (col < 0 || col >= _maxColumns) continue;
      final body = cm.group(2) ?? '';
      final type = ca['t'] ?? 'n';
      final style = int.tryParse(ca['s'] ?? '');
      final v = _vRe.firstMatch(body)?.group(1);

      ImportCell cell;
      switch (type) {
        case 's':
          final idx = int.tryParse((v ?? '').trim());
          final text = (idx != null && idx >= 0 && idx < shared.length)
              ? shared[idx]
              : '';
          cell = ImportCell(text.trim());
          break;
        case 'inlineStr':
          final isM = _isRe.firstMatch(body);
          cell = ImportCell(_richText(isM?.group(1) ?? '').trim());
          break;
        case 'str':
          cell = ImportCell(_xmlText(v ?? '').trim());
          break;
        case 'b':
          cell = ImportCell((v ?? '').trim() == '1' ? 'TRUE' : 'FALSE');
          break;
        case 'e':
          cell = ImportCell.empty;
          break;
        case 'd':
          final dt = DateTime.tryParse((v ?? '').trim());
          cell = dt == null
              ? ImportCell(_xmlText(v ?? '').trim())
              : ImportCell(formatImportDate(dt), isDate: true);
          break;
        default:
          final raw = (v ?? '').trim();
          final num = double.tryParse(raw);
          if (num == null) {
            cell = ImportCell(_xmlText(raw));
          } else if (style != null && dates.styles.containsKey(style)) {
            final timeOnly = dates.styles[style]! || num.abs() < 1;
            final dt = _excelSerialToDate(num, date1904);
            cell = ImportCell(
              timeOnly ? formatImportTime(dt) : formatImportDate(dt),
              isDate: true,
            );
          } else {
            cell = ImportCell(formatImportNumber(num), number: num);
          }
      }
      while (cells.length < col) {
        cells.add(ImportCell.empty);
      }
      if (cells.length == col) {
        cells.add(cell);
      } else {
        cells[col] = cell;
      }
    }
    final row = ImportRow(rowNo, cells);
    if (!row.isEmpty) rows.add(row);
    if (rows.length >= _maxRows) break;
  }
  return rows;
}

String _resolveTarget(String target) {
  var t = target.replaceAll('\\', '/');
  if (t.startsWith('/')) return t.substring(1);
  while (t.startsWith('./')) {
    t = t.substring(2);
  }
  if (t.startsWith('../')) return t.substring(3);
  return 'xl/$t';
}

/// يقرأ أوراق ملف xlsx (الظاهرة فقط وبالترتيب)
List<ImportSheet> readXlsxSheets(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);

  String? read(String path) {
    final f =
        archive.findFile(path) ??
        archive.files.cast<ArchiveFile?>().firstWhere(
          (e) => e!.name.toLowerCase() == path.toLowerCase(),
          orElse: () => null,
        );
    if (f == null || !f.isFile) return null;
    final data = f.content;
    if (data is List<int>) return utf8.decode(data, allowMalformed: true);
    return null;
  }

  final workbook = read('xl/workbook.xml');
  if (workbook == null) {
    throw const XlsxFormatException('الملف ليس ملف Excel (xlsx)');
  }
  final shared = _parseSharedStrings(read('xl/sharedStrings.xml'));
  final dates = _parseDateStyles(read('xl/styles.xml'));
  final date1904 = RegExp(
    r'date1904\s*=\s*"(1|true)"',
    caseSensitive: false,
  ).hasMatch(workbook);

  final relTargets = <String, String>{};
  final rels = read('xl/_rels/workbook.xml.rels') ?? '';
  for (final m in RegExp(
    r'<(?:\w+:)?Relationship\b([^>]*?)/?>',
  ).allMatches(rels)) {
    final a = _attrs(m.group(1) ?? '');
    final id = a['Id'];
    final target = a['Target'];
    if (id != null && target != null) relTargets[id] = _resolveTarget(target);
  }

  final sheets = <ImportSheet>[];
  final seenPaths = <String>{};
  for (final m in RegExp(
    r'<(?:\w+:)?sheet\b([^>]*?)/?>',
  ).allMatches(workbook)) {
    final a = _attrs(m.group(1) ?? '');
    final state = (a['state'] ?? '').toLowerCase();
    if (state == 'hidden' || state == 'veryhidden') continue;
    final rid = _attrEndingWith(a, 'id');
    final path = rid == null ? null : relTargets[rid];
    if (path == null || !seenPaths.add(path)) continue;
    final xml = read(path);
    if (xml == null) continue;
    final name = decodeXmlEntities(a['name'] ?? 'ورقة ${sheets.length + 1}');
    sheets.add(
      ImportSheet(name, _parseSheetRows(xml, shared, dates, date1904)),
    );
  }

  // احتياط: علاقات تالفة → نقرأ ملفات الأوراق مباشرة
  if (sheets.isEmpty) {
    final sheetFiles =
        archive.files
            .where(
              (f) =>
                  f.isFile &&
                  RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name),
            )
            .map((f) => f.name)
            .toList()
          ..sort((a, b) {
            int n(String s) =>
                int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(s)!.group(1)!) ??
                0;
            return n(a).compareTo(n(b));
          });
    for (final path in sheetFiles) {
      final xml = read(path);
      if (xml == null) continue;
      sheets.add(
        ImportSheet(
          'ورقة ${sheets.length + 1}',
          _parseSheetRows(xml, shared, dates, date1904),
        ),
      );
    }
  }
  return sheets;
}

/// ملفات نصية داخل ملف مضغوط (مثل تصدير محادثة واتساب مع الوسائط)
List<({String name, List<int> bytes})> zipTextEntries(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final out = <({String name, List<int> bytes})>[];
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final name = f.name.replaceAll('\\', '/');
    final lower = name.toLowerCase();
    if (lower.startsWith('__macosx/')) continue;
    if (!lower.endsWith('.txt') && !lower.endsWith('.csv')) continue;
    final data = f.content;
    if (data is List<int>) out.add((name: name.split('/').last, bytes: data));
  }
  int rank(String n) {
    final l = n.toLowerCase();
    if (l.contains('whatsapp') || l == '_chat.txt') return 0;
    return l.endsWith('.txt') ? 1 : 2;
  }

  out.sort((a, b) {
    final r = rank(a.name).compareTo(rank(b.name));
    return r != 0 ? r : b.bytes.length.compareTo(a.bytes.length);
  });
  return out;
}

/// قراءة احتياطية عبر مكتبة excel (لا تقرأ نتائج المعادلات)
List<ImportSheet> readXlsxWithExcelPackage(List<int> bytes) {
  final book = xls.Excel.decodeBytes(bytes);
  final sheets = <ImportSheet>[];
  book.tables.forEach((name, sheet) {
    final rows = <ImportRow>[];
    final data = sheet.rows;
    for (var r = 0; r < data.length && rows.length < _maxRows; r++) {
      final cells = <ImportCell>[];
      for (final d in data[r]) {
        final v = d?.value;
        if (v == null || v is xls.FormulaCellValue) {
          cells.add(ImportCell.empty);
        } else if (v is xls.IntCellValue) {
          final n = v.value.toDouble();
          cells.add(ImportCell(formatImportNumber(n), number: n));
        } else if (v is xls.DoubleCellValue) {
          cells.add(ImportCell(formatImportNumber(v.value), number: v.value));
        } else if (v is xls.DateCellValue) {
          cells.add(
            ImportCell(
              formatImportDate(DateTime(v.year, v.month, v.day)),
              isDate: true,
            ),
          );
        } else {
          cells.add(ImportCell(v.toString().trim()));
        }
      }
      final row = ImportRow(r + 1, cells);
      if (!row.isEmpty) rows.add(row);
    }
    sheets.add(ImportSheet(name, rows));
  });
  return sheets;
}
