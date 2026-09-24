// lib/services/share_import/whatsapp_export.dart
// -------------------------------------------------------------
// تحويل ملف «تصدير الدردشة» من واتساب (txt) إلى نفس صيغة الرسائل المنسوخة
// التي تفهمها شاشات التحليل:  [24/09, 10:30] الاسم: النص
// يدعم صيغ أندرويد وآيفون، الأرقام العربية، نظام 12 ساعة (ص/م AM/PM)،
// ويتجاهل رسائل النظام والوسائط المحذوفة.
// (ملف Dart نقي بدون Flutter)
// -------------------------------------------------------------

import 'import_models.dart';

class WhatsAppExportResult {
  final List<ImportMessage> messages;

  /// رسائل تم تجاهلها (رسائل نظام/وسائط/محذوفة)
  final int skipped;

  const WhatsAppExportResult(this.messages, this.skipped);
}

final RegExp _bidiRe = RegExp(
  r'[\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
);

/// يطبّع سطر الهيدر للمطابقة (أرقام عربية → لاتينية، حذف علامات الاتجاه)
/// ويعيد لكل محرف ناتج موضعه في السطر الأصلي.
({String text, List<int> origin}) _normalizeLine(String line) {
  final b = StringBuffer();
  final origin = <int>[];
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if ((c >= 0x200E && c <= 0x200F) ||
        (c >= 0x202A && c <= 0x202E) ||
        (c >= 0x2066 && c <= 0x2069) ||
        c == 0xFEFF) {
      continue;
    }
    if (c >= 0x0660 && c <= 0x0669) {
      b.writeCharCode(0x30 + c - 0x0660);
    } else if (c >= 0x06F0 && c <= 0x06F9) {
      b.writeCharCode(0x30 + c - 0x06F0);
    } else if (c == 0x202F || c == 0x00A0) {
      b.writeCharCode(0x20);
    } else if (c == 0x060C) {
      b.write(',');
    } else {
      b.writeCharCode(c);
    }
    origin.add(i);
  }
  return (text: b.toString(), origin: origin);
}

const String _datePart =
    r'(\d{1,4})[\/.\-](\d{1,2})[\/.\-](\d{1,4}),?\s+(\d{1,2})[:.](\d{2})(?:[:.](\d{2}))?\s*([AaPp]\.?\s?[Mm]\.?|ص|م|صباحا|مساء|مساءً|صباحًا)?';

/// أندرويد: 24/09/2026, 10:30 - الاسم: النص
final RegExp _androidRe = RegExp('^$_datePart\\s*[-–]\\s+(.*)\$');

/// آيفون: [24/09/2026, 10:30:15] الاسم: النص
final RegExp _iosRe = RegExp('^\\[$_datePart\\]\\s*(.*)\$');

class _Header {
  final int a, b, c, hour, minute;
  final String? ampm;
  final String rest;
  const _Header(
    this.a,
    this.b,
    this.c,
    this.hour,
    this.minute,
    this.ampm,
    this.rest,
  );
}

_Header? _matchHeader(String line) {
  final n = _normalizeLine(line);
  final normalized = n.text;
  final m = _androidRe.firstMatch(normalized) ?? _iosRe.firstMatch(normalized);
  if (m == null) return null;
  final minute = int.parse(m.group(5)!);
  final hour = int.parse(m.group(4)!);
  if (minute > 59 || hour > 23) return null;
  // بقية السطر (المرسل والنص) تؤخذ من السطر الأصلي حتى تبقى الأرقام كما هي
  final restNorm = m.group(8) ?? '';
  final restStart = normalized.length - restNorm.length;
  final rest = restStart >= normalized.length
      ? ''
      : line.substring(n.origin[restStart]).replaceAll(_bidiRe, '');
  return _Header(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    hour,
    minute,
    m.group(7),
    rest,
  );
}

final List<RegExp> _placeholderRes = [
  RegExp(
    r'^<[^<>]*(omitted|attached|مضمن|مرفق|الوسائط|وسائط)[^<>]*>$',
    caseSensitive: false,
  ),
  RegExp(r'\((file attached|ملف مرفق)\)\s*$', caseSensitive: false),
  RegExp(
    r'^(image|video|audio|sticker|gif|document|contact card) omitted$',
    caseSensitive: false,
  ),
  RegExp(
    r'^(this message was deleted|you deleted this message|waiting for this message.*)$',
    caseSensitive: false,
  ),
  RegExp(
    r'^(تم حذف هذه الرسالة|لقد حذفت هذه الرسالة|حذفت هذه الرسالة|في انتظار هذه الرسالة.*)\.?$',
  ),
  RegExp(r'^null$'),
];

final RegExp _editedSuffixRe = RegExp(
  r'\s*<(this message was edited|تم تعديل هذه الرسالة)>\s*$',
  caseSensitive: false,
);

bool _isPlaceholder(String body) {
  final t = body.trim();
  if (t.isEmpty) return true;
  return _placeholderRes.any((re) => re.hasMatch(t));
}

/// هل يبدو النص تصديرًا لمحادثة واتساب؟
bool looksLikeWhatsAppExport(String text) {
  var headers = 0, lines = 0;
  for (final raw in text.split('\n').take(400)) {
    if (raw.trim().isEmpty) continue;
    lines++;
    final h = _matchHeader(raw.trim());
    if (h != null) headers++;
  }
  if (headers < 2) return false;
  return headers >= lines * 0.2;
}

String _two(int v) => v.toString().padLeft(2, '0');

WhatsAppExportResult? parseWhatsAppExport(String text) {
  final rawLines = text.split('\n');
  final headers = <int, _Header>{};
  for (var i = 0; i < rawLines.length; i++) {
    final t = rawLines[i].trim();
    if (t.isEmpty) continue;
    final h = _matchHeader(t);
    if (h != null) headers[i] = h;
  }
  if (headers.length < 2) return null;

  // ترتيب اليوم/الشهر: نعتمد على القيم > 12 ثم على تسلسل التواريخ
  final list = headers.values.toList();
  final yearFirst = list.where((h) => h.a > 31).length > list.length / 2;
  bool dayFirst;
  if (yearFirst) {
    dayFirst = false;
  } else {
    final aOver = list.any((h) => h.a > 12);
    final bOver = list.any((h) => h.b > 12);
    if (aOver && !bOver) {
      dayFirst = true;
    } else if (bOver && !aOver) {
      dayFirst = false;
    } else {
      int violations(bool df) {
        var v = 0;
        DateTime? prev;
        for (final h in list) {
          final d = _dateOf(h, df, false);
          if (d == null) continue;
          if (prev != null && d.isBefore(prev)) v++;
          prev = d;
        }
        return v;
      }

      dayFirst = violations(true) <= violations(false);
    }
  }

  final messages = <ImportMessage>[];
  var skipped = 0;
  final keys = headers.keys.toList()..sort();
  for (var k = 0; k < keys.length; k++) {
    final start = keys[k];
    final end = k + 1 < keys.length ? keys[k + 1] : rawLines.length;
    final h = headers[start]!;
    final colon = h.rest.indexOf(': ');
    if (colon <= 0) {
      skipped++; // رسالة نظام (انضمام/تشفير...) بدون مرسل
      continue;
    }
    final sender = h.rest.substring(0, colon).trim();
    final firstLine = h.rest.substring(colon + 2);
    final body = <String>[
      firstLine,
      for (var i = start + 1; i < end; i++) rawLines[i].trimRight(),
    ];
    while (body.isNotEmpty && body.last.trim().isEmpty) {
      body.removeLast();
    }
    if (body.isNotEmpty) {
      body[body.length - 1] = body.last.replaceFirst(_editedSuffixRe, '');
    }
    final joined = body.join('\n').replaceAll(_bidiRe, '').trim();
    final dt = _dateOf(h, dayFirst, yearFirst);
    if (sender.isEmpty || dt == null || _isPlaceholder(joined)) {
      skipped++;
      continue;
    }
    final safeSender = sender.replaceAll(':', ' ').replaceAll('\n', ' ');
    final header =
        '[${_two(dt.day)}/${_two(dt.month)}, ${_two(dt.hour)}:${_two(dt.minute)}] $safeSender:';
    messages.add(ImportMessage('$header $joined', timestamp: dt));
  }
  return WhatsAppExportResult(messages, skipped);
}

DateTime? _dateOf(_Header h, bool dayFirst, bool yearFirst) {
  int year, month, day;
  if (yearFirst) {
    year = h.a;
    month = h.b;
    day = h.c;
  } else {
    year = h.c;
    month = dayFirst ? h.b : h.a;
    day = dayFirst ? h.a : h.b;
  }
  if (year < 100) year += 2000;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  var hour = h.hour;
  final ap = (h.ampm ?? '')
      .toLowerCase()
      .replaceAll('.', '')
      .replaceAll(' ', '');
  final isPm = ap.startsWith('p') || ap == 'م' || ap.startsWith('مساء');
  final isAm = ap.startsWith('a') || ap == 'ص' || ap.startsWith('صباح');
  if (isPm && hour < 12) hour += 12;
  if (isAm && hour == 12) hour = 0;
  return DateTime(year, month, day, hour, h.minute);
}
