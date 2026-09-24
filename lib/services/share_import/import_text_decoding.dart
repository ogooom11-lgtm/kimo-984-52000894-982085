// lib/services/share_import/import_text_decoding.dart
// -------------------------------------------------------------
// قراءة الملفات النصية المستوردة:
// - فك الترميز: UTF-8 (مع/بدون BOM)، UTF-16، وWindows-1256 (ملفات CSV
//   العربية المحفوظة من Excel على ويندوز).
// - جداول CSV/TSV (مع علامات الاقتباس والأسطر داخل الخلايا).
// - جداول HTML وملفات XML 2003 (كثير من الأنظمة تصدّرها باسم .xls).
// (ملف Dart نقي بدون Flutter)
// -------------------------------------------------------------

import 'dart:convert';

import 'import_models.dart';

// ====================== فك الترميز ======================

/// محارف Windows-1256 للبايتات 0x80..0xFF
const String _cp1256High =
    '\u20AC\u067E\u201A\u0192\u201E\u2026\u2020\u2021\u02C6\u2030\u0679\u2039\u0152\u0686\u0698\u0688'
    '\u06AF\u2018\u2019\u201C\u201D\u2022\u2013\u2014\u06A9\u2122\u0691\u203A\u0153\u200C\u200D\u06BA'
    '\u00A0\u060C\u00A2\u00A3\u00A4\u00A5\u00A6\u00A7\u00A8\u00A9\u06BE\u00AB\u00AC\u00AD\u00AE\u00AF'
    '\u00B0\u00B1\u00B2\u00B3\u00B4\u00B5\u00B6\u00B7\u00B8\u00B9\u061B\u00BB\u00BC\u00BD\u00BE\u061F'
    '\u06C1\u0621\u0622\u0623\u0624\u0625\u0626\u0627\u0628\u0629\u062A\u062B\u062C\u062D\u062E\u062F'
    '\u0630\u0631\u0632\u0633\u0634\u0635\u0636\u00D7\u0637\u0638\u0639\u063A\u0640\u0641\u0642\u0643'
    '\u00E0\u0644\u00E2\u0645\u0646\u0647\u0648\u00E7\u00E8\u00E9\u00EA\u00EB\u0649\u064A\u00EE\u00EF'
    '\u064B\u064C\u064D\u064E\u00F4\u064F\u0650\u00F7\u0651\u00F9\u0652\u00FB\u00FC\u200E\u200F\u06D2';

String _decodeCp1256(List<int> bytes, [int start = 0]) {
  final b = StringBuffer();
  for (var i = start; i < bytes.length; i++) {
    final v = bytes[i] & 0xFF;
    if (v < 0x80) {
      b.writeCharCode(v);
    } else {
      b.write(_cp1256High[v - 0x80]);
    }
  }
  return b.toString();
}

String _decodeUtf16(List<int> bytes, int start, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    final a = bytes[i] & 0xFF;
    final c = bytes[i + 1] & 0xFF;
    units.add(littleEndian ? (a | (c << 8)) : ((a << 8) | c));
  }
  return String.fromCharCodes(units);
}

int _countArabicLetters(String s) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0x0621 && c <= 0x064A) n++;
  }
  return n;
}

/// هل تبدو البايتات UTF-16 بدون BOM؟ (نصف البايتات تقريبًا أصفار)
bool? _utf16WithoutBom(List<int> bytes) {
  final n = bytes.length < 4000 ? bytes.length : 4000;
  if (n < 8) return null;
  var zeroEven = 0, zeroOdd = 0;
  for (var i = 0; i < n; i++) {
    if (bytes[i] == 0) {
      if (i.isEven) {
        zeroEven++;
      } else {
        zeroOdd++;
      }
    }
  }
  final half = n / 2;
  if (zeroOdd > half * 0.3 && zeroEven < half * 0.05) return true; // LE
  if (zeroEven > half * 0.3 && zeroOdd < half * 0.05) return false; // BE
  return null;
}

/// يحوّل بايتات ملف نصي إلى نص، مع توحيد نهايات الأسطر إلى \n
String decodeImportText(List<int> bytes) {
  String text;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    text = utf8.decode(bytes.sublist(3), allowMalformed: true);
  } else if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    text = _decodeUtf16(bytes, 2, littleEndian: true);
  } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    text = _decodeUtf16(bytes, 2, littleEndian: false);
  } else {
    final utf16 = _utf16WithoutBom(bytes);
    if (utf16 != null) {
      text = _decodeUtf16(bytes, 0, littleEndian: utf16);
    } else {
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        // ليس UTF-8 صالحًا: غالبًا ملف عربي بترميز ويندوز (ANSI)
        final loose = utf8.decode(bytes, allowMalformed: true);
        final ansi = _decodeCp1256(bytes);
        final bad = '\uFFFD'.allMatches(loose).length;
        text =
            (_countArabicLetters(ansi) > _countArabicLetters(loose) ||
                bad > loose.length * 0.01)
            ? ansi
            : loose;
      }
    }
  }
  return text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u0000', '');
}

// ====================== CSV / TSV ======================

/// يقسم نص CSV إلى صفوف وخلايا مع دعم علامات الاقتباس ("..." و"")
List<List<String>> parseDelimitedText(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var fieldStarted = false;
  final d = delimiter.codeUnitAt(0);
  const quote = 0x22, nl = 0x0A;

  void endField() {
    row.add(field.toString());
    field.clear();
    fieldStarted = false;
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inQuotes) {
      if (c == quote) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == quote) {
          field.writeCharCode(quote);
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.writeCharCode(c);
      }
      continue;
    }
    if (c == quote && !fieldStarted && field.toString().trim().isEmpty) {
      field.clear();
      inQuotes = true;
      fieldStarted = true;
    } else if (c == d) {
      endField();
    } else if (c == nl) {
      endRow();
    } else {
      field.writeCharCode(c);
      if (c != 0x20 && c != 0x09) fieldStarted = true;
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

/// يكتشف فاصل الأعمدة الأنسب (, ; Tab |) أو null إن كان النص عمودًا واحدًا
String? detectDelimiter(String text) {
  final lines = text
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .take(60)
      .toList();
  if (lines.isEmpty) return null;
  final sample = lines.join('\n');
  String? best;
  var bestScore = 0.0;
  for (final d in const ['\t', ';', ',', '|']) {
    if (!sample.contains(d)) continue;
    final rows = parseDelimitedText(sample, d);
    if (rows.isEmpty) continue;
    final counts = <int, int>{};
    for (final r in rows) {
      final n = r.where((c) => c.trim().isNotEmpty).length;
      counts[r.length] = (counts[r.length] ?? 0) + (n > 0 ? 1 : 0);
    }
    var mode = 0, modeRows = 0;
    counts.forEach((len, n) {
      if (n > modeRows || (n == modeRows && len > mode)) {
        mode = len;
        modeRows = n;
      }
    });
    if (mode < 2) continue;
    final multi = rows.where((r) => r.length >= 2).length;
    final score = (modeRows / rows.length) * 0.7 + (multi / rows.length) * 0.3;
    if (score > bestScore + 0.02) {
      bestScore = score;
      best = d;
    }
  }
  return bestScore >= 0.5 ? best : null;
}

/// يحوّل نص CSV/TSV إلى ورقة. يدعم سطر «sep=;» الذي يضيفه Excel.
ImportSheet parseDelimitedSheet(
  String text, {
  String? delimiter,
  String? name,
}) {
  var body = text;
  String? d = delimiter;
  final firstLineEnd = body.indexOf('\n');
  final firstLine = (firstLineEnd < 0 ? body : body.substring(0, firstLineEnd))
      .trim();
  final sep = RegExp(
    r'^"?sep=(.)"?$',
    caseSensitive: false,
  ).firstMatch(firstLine);
  if (sep != null) {
    d = sep.group(1);
    body = firstLineEnd < 0 ? '' : body.substring(firstLineEnd + 1);
  }
  d ??= detectDelimiter(body);
  final rows = <ImportRow>[];
  if (d == null) {
    final lines = body.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty) continue;
      rows.add(ImportRow(i + 1, [ImportCell(t)]));
    }
  } else {
    final parsed = parseDelimitedText(body, d);
    for (var i = 0; i < parsed.length; i++) {
      final cells = parsed[i].map((c) => ImportCell(c.trim())).toList();
      final row = ImportRow(i + 1, cells);
      if (!row.isEmpty) rows.add(row);
    }
  }
  return ImportSheet(name ?? '', rows);
}

// ====================== HTML / XML (ملفات .xls النصية) ======================

final RegExp _tagRe = RegExp(r'<[^>]+>');
final RegExp _entityRe = RegExp(r'&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

const Map<String, String> _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
};

/// فك ترميز كيانات XML/HTML (&amp; &#1575; ...)
String decodeXmlEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entityRe, (m) {
    final e = m.group(1)!;
    if (e.startsWith('#')) {
      final isHex = e.length > 1 && (e[1] == 'x' || e[1] == 'X');
      final code = int.tryParse(
        isHex ? e.substring(2) : e.substring(1),
        radix: isHex ? 16 : 10,
      );
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    }
    return _namedEntities[e.toLowerCase()] ?? m.group(0)!;
  });
}

String _htmlCellText(String inner) {
  var s = inner.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(_tagRe, '');
  s = decodeXmlEntities(s).replaceAll('\u00A0', ' ');
  return s
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
}

bool looksLikeHtmlTable(String text) {
  final head = text.length > 200000 ? text.substring(0, 200000) : text;
  final lower = head.toLowerCase();
  return lower.contains('<table') &&
      (lower.contains('<td') || lower.contains('<th'));
}

/// كل جدول HTML يصبح ورقة
List<ImportSheet> parseHtmlTables(String html) {
  final sheets = <ImportSheet>[];
  final tableRe = RegExp(
    r'<table\b[^>]*>(.*?)</table>',
    caseSensitive: false,
    dotAll: true,
  );
  final rowRe = RegExp(
    r'<tr\b[^>]*>(.*?)(?=<tr\b|</tr>|$)',
    caseSensitive: false,
    dotAll: true,
  );
  final cellRe = RegExp(
    r'<t([dh])\b([^>]*)>(.*?)(?=<t[dh]\b|</t[dh]>|</tr>|$)',
    caseSensitive: false,
    dotAll: true,
  );
  var t = 0;
  for (final table in tableRe.allMatches(html)) {
    t++;
    final rows = <ImportRow>[];
    var r = 0;
    for (final row in rowRe.allMatches(table.group(1) ?? '')) {
      r++;
      final cells = <ImportCell>[];
      for (final cell in cellRe.allMatches(row.group(1) ?? '')) {
        final text = _htmlCellText(cell.group(3) ?? '');
        cells.add(ImportCell(text));
        final span = RegExp(
          r'colspan\s*=\s*"?(\d+)',
          caseSensitive: false,
        ).firstMatch(cell.group(2) ?? '');
        final extra = (int.tryParse(span?.group(1) ?? '') ?? 1) - 1;
        for (var k = 0; k < extra && k < 50; k++) {
          cells.add(ImportCell.empty);
        }
      }
      final ir = ImportRow(r, cells);
      if (!ir.isEmpty) rows.add(ir);
    }
    if (rows.isNotEmpty) sheets.add(ImportSheet('جدول $t', rows));
  }
  return sheets;
}

bool looksLikeSpreadsheetMl(String text) {
  final head = text.length > 4000 ? text.substring(0, 4000) : text;
  return head.contains('urn:schemas-microsoft-com:office:spreadsheet') ||
      (head.contains('<Workbook') && text.contains('<Worksheet'));
}

/// ملفات «XML Spreadsheet 2003»
List<ImportSheet> parseSpreadsheetMl(String xml) {
  final sheets = <ImportSheet>[];
  final wsRe = RegExp(
    r'<(?:\w+:)?Worksheet\b([^>]*)>(.*?)</(?:\w+:)?Worksheet>',
    dotAll: true,
  );
  final rowRe = RegExp(
    r'<(?:\w+:)?Row\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?Row>)',
    dotAll: true,
  );
  final cellRe = RegExp(
    r'<(?:\w+:)?Cell\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?Cell>)',
    dotAll: true,
  );
  final dataRe = RegExp(
    r'<(?:\w+:)?Data\b([^>]*)>(.*?)</(?:\w+:)?Data>',
    dotAll: true,
  );
  final nameAttr = RegExp(r'(?:\w+:)?Name\s*=\s*"([^"]*)"');
  final indexAttr = RegExp(r'(?:\w+:)?Index\s*=\s*"(\d+)"');
  final typeAttr = RegExp(r'(?:\w+:)?Type\s*=\s*"(\w+)"');

  var w = 0;
  for (final ws in wsRe.allMatches(xml)) {
    w++;
    final name = decodeXmlEntities(
      nameAttr.firstMatch(ws.group(1) ?? '')?.group(1) ?? 'ورقة $w',
    );
    final rows = <ImportRow>[];
    var rowNo = 0;
    for (final row in rowRe.allMatches(ws.group(2) ?? '')) {
      final idx = int.tryParse(
        indexAttr.firstMatch(row.group(1) ?? '')?.group(1) ?? '',
      );
      rowNo = idx ?? rowNo + 1;
      final cells = <ImportCell>[];
      for (final cell in cellRe.allMatches(row.group(2) ?? '')) {
        final cIdx = int.tryParse(
          indexAttr.firstMatch(cell.group(1) ?? '')?.group(1) ?? '',
        );
        if (cIdx != null) {
          while (cells.length < cIdx - 1 && cells.length < 500) {
            cells.add(ImportCell.empty);
          }
        }
        final data = dataRe.firstMatch(cell.group(2) ?? '');
        if (data == null) {
          cells.add(ImportCell.empty);
          continue;
        }
        final type = typeAttr.firstMatch(data.group(1) ?? '')?.group(1) ?? '';
        final raw = decodeXmlEntities(
          (data.group(2) ?? '').replaceAll(_tagRe, ''),
        ).trim();
        if (type == 'Number') {
          final v = double.tryParse(raw);
          cells.add(
            v == null
                ? ImportCell(raw)
                : ImportCell(formatImportNumber(v), number: v),
          );
        } else if (type == 'DateTime') {
          final dt = DateTime.tryParse(raw);
          cells.add(
            dt == null
                ? ImportCell(raw)
                : ImportCell(formatImportDate(dt), isDate: true),
          );
        } else {
          cells.add(ImportCell(raw));
        }
      }
      final ir = ImportRow(rowNo, cells);
      if (!ir.isEmpty) rows.add(ir);
    }
    if (rows.isNotEmpty) sheets.add(ImportSheet(name, rows));
  }
  return sheets;
}

// ====================== تنسيق القيم ======================

/// رقم للعرض داخل الرسالة: بدون فواصل آلاف، وبحد أقصى رقمين عشريين
/// (حتى لا تُقرأ 1.500 كألف وخمسمئة عند التحليل)
String formatImportNumber(double v) {
  if (v.isNaN || v.isInfinite) return '';
  final rounded = v.roundToDouble();
  if ((v - rounded).abs() < 1e-9 && rounded.abs() < 1e15) {
    return rounded.toInt().toString();
  }
  var s = v.toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

String _two(int v) => v.toString().padLeft(2, '0');

/// تاريخ للعرض: yyyy/MM/dd (مع الوقت إن وُجد)
String formatImportDate(DateTime d, {bool withTime = true}) {
  final date = '${d.year}/${_two(d.month)}/${_two(d.day)}';
  if (!withTime || (d.hour == 0 && d.minute == 0)) return date;
  return '$date ${_two(d.hour)}:${_two(d.minute)}';
}

String formatImportTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
