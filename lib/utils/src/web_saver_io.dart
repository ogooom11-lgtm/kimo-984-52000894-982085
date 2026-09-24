// تنفيذ لمنصّات غير الويب (لن يُستخدم على الويب).
import 'dart:io';

Future<void> saveBytes({
  required String filename,
  required List<int> bytes,
  String mimeType = 'application/octet-stream',
}) async {
  final dir = await Directory.systemTemp.createTemp('web_saver_');
  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
}
