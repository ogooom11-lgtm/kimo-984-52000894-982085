// واجهة موحّدة مع استيراد شرطي حسب المنصّة.
import 'src/web_saver_stub.dart'
if (dart.library.html) 'src/web_saver_web.dart'
if (dart.library.io) 'src/web_saver_io.dart' as impl;

/// حفظ بايتات كملف (اسم + نوع MIME).
Future<void> saveBytes({
  required String filename,
  required List<int> bytes,
  String mimeType = 'application/octet-stream',
}) {
  return impl.saveBytes(
    filename: filename,
    bytes: bytes,
    mimeType: mimeType,
  );
}
