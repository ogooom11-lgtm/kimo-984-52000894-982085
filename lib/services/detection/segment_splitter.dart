// lib/services/detection/segment_splitter.dart
// -------------------------------------------------------------
// تقسيم النص إلى رسائل (مقاطع) — مشترك بين شاشة الفقاعات وشاشة التسليم:
// 1) هيدر واتساب المنسوخ:  [24/09, 10:30] الاسم: ...
// 2) فاصل صفوف الملفات المستوردة:  —— صف 5 ——
//    (يضيفه محوّل الملفات حتى يصبح كل صف في Excel/CSV رسالة مستقلة)
// النص بدون أي هيدر أو فاصل = رسالة واحدة (نفس السلوك القديم تمامًا).
// (ملف Dart نقي بدون Flutter)
// -------------------------------------------------------------

import 'text_tokens.dart' show digitsOnly;

/// مقطع خام قبل تحويله إلى نوع المقطع الخاص بكل شاشة
class RawSegment {
  final String header;
  final String senderName;
  final DateTime? timestamp;
  final List<String> lines;

  /// true إذا جاء المقطع من صف ملف مستورد (فاصل «—— صف N ——»)
  final bool fromImportRow;

  const RawSegment({
    required this.header,
    required this.senderName,
    required this.timestamp,
    required this.lines,
    this.fromImportRow = false,
  });
}

class SegmentSplitter {
  SegmentSplitter._();

  /// هيدر واتساب عند نسخ الرسائل: [24/09, 10:30] الاسم:
  static final RegExp whatsappHeader = RegExp(
    r'\[\s*([0-9\u0660-\u0669]{1,2})\/[\u200F\u200E]?\s*([0-9\u0660-\u0669]{1,2})\s*[,،]\s*([0-9\u0660-\u0669]{1,2})\s*:\s*([0-9\u0660-\u0669]{2})\s*\]\s*([^:\n]+?)\s*:',
    multiLine: true,
  );

  static const String rowMarkerEdge = '——';

  /// سطر فاصل كامل: «—— صف 5 ——» أو «—— سطر 3 • ملف.xlsx ——»
  static final RegExp rowMarker = RegExp(
    r'^[ \t\u200E\u200F]*——[ \t]*((?:صف|سطر|رسالة)[ \t]*[0-9\u0660-\u0669]+[^\n]*?)[ \t]*——[ \t\u200E\u200F]*$',
    multiLine: true,
  );

  /// يبني سطر الفاصل لعنوان معيّن (مثال: «صف 5»)
  static String rowMarkerLine(String label) =>
      '$rowMarkerEdge ${label.trim()} $rowMarkerEdge';

  static bool hasRowMarkers(String text) => rowMarker.hasMatch(text);

  /// عدد رسائل واتساب (الهيدرات) في النص
  static int countWhatsappHeaders(String text) =>
      whatsappHeader.allMatches(text.replaceAll('\r', '')).length;

  /// يقسم النص إلى مقاطع.
  /// [headerlessLabel]: عنوان المقطع عندما لا يوجد أي هيدر (يختلف بين الشاشات).
  static List<RawSegment> split(
    String input, {
    String headerlessLabel = '',
    DateTime? now,
  }) {
    final text = input.replaceAll('\r', '');
    final clock = now ?? DateTime.now();
    final markers = rowMarker.allMatches(text).toList();
    final headers = whatsappHeader.allMatches(text).toList();

    if (markers.isEmpty) {
      if (headers.isEmpty) {
        return [
          RawSegment(
            header: headerlessLabel,
            senderName: '',
            timestamp: null,
            lines: _lines(text),
          ),
        ];
      }
      // السلوك القديم: كل هيدر يبدأ رسالة، وما قبل أول هيدر يُتجاهل
      final out = <RawSegment>[];
      for (var i = 0; i < headers.length; i++) {
        final m = headers[i];
        final end = (i + 1 < headers.length)
            ? headers[i + 1].start
            : text.length;
        out.add(_fromHeader(m, text.substring(m.end, end), clock));
      }
      return out;
    }

    // نص فيه فواصل صفوف (وقد يحتوي أيضًا رسائل واتساب قبلها أو بعدها)
    final bounds = <_Bound>[
      for (final m in markers) _Bound(m, true),
      for (final m in headers)
        if (!markers.any((k) => m.start < k.end && m.end > k.start))
          _Bound(m, false),
    ]..sort((a, b) => a.match.start.compareTo(b.match.start));

    final out = <RawSegment>[];
    final preamble = text.substring(0, bounds.first.match.start);
    if (preamble.trim().isNotEmpty) {
      out.add(
        RawSegment(
          header: headerlessLabel,
          senderName: '',
          timestamp: null,
          lines: _trimBlankEdges(_lines(preamble)),
        ),
      );
    }
    for (var i = 0; i < bounds.length; i++) {
      final b = bounds[i];
      final end = (i + 1 < bounds.length)
          ? bounds[i + 1].match.start
          : text.length;
      final body = text.substring(b.match.end, end);
      if (b.isMarker) {
        out.add(
          RawSegment(
            header: (b.match.group(1) ?? '').trim(),
            senderName: '',
            timestamp: null,
            lines: _trimBlankEdges(_lines(body)),
            fromImportRow: true,
          ),
        );
      } else {
        out.add(_fromHeader(b.match, body, clock));
      }
    }
    return out;
  }

  static List<String> _lines(String body) =>
      body.split('\n').map((e) => e.trimRight()).toList();

  static List<String> _trimBlankEdges(List<String> lines) {
    var start = 0;
    var end = lines.length;
    while (start < end && lines[start].trim().isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].trim().isEmpty) {
      end--;
    }
    return lines.sublist(start, end);
  }

  static int _toInt(String s) => int.tryParse(digitsOnly(s)) ?? 0;

  static RawSegment _fromHeader(RegExpMatch m, String body, DateTime now) {
    final dd = _toInt(m.group(1)!);
    final mo = _toInt(m.group(2)!);
    final hh = _toInt(m.group(3)!);
    final mi = _toInt(m.group(4)!);

    DateTime? ts;
    try {
      ts = DateTime(now.year, mo, dd, hh, mi);
      // الهيدر لا يحتوي السنة: تاريخ بعد اليوم بأكثر من يومين يعني
      // أن الرسالة من السنة الماضية (مثلًا رسائل كانون الأول تُحلَّل في كانون الثاني)
      if (ts.isAfter(now.add(const Duration(days: 2)))) {
        ts = DateTime(now.year - 1, mo, dd, hh, mi);
      }
    } catch (_) {}

    return RawSegment(
      header: m.group(0)!.trim(),
      senderName: m.group(5)!.trim(),
      timestamp: ts,
      lines: _lines(body),
    );
  }
}

class _Bound {
  final RegExpMatch match;
  final bool isMarker;
  const _Bound(this.match, this.isMarker);
}
