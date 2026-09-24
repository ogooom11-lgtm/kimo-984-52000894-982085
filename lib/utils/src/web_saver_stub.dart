// Fallback لتفادي أخطاء التحليل إن لم تُطابق أي منصّة.
Future<void> saveBytes({
  required String filename,
  required List<int> bytes,
  String mimeType = 'application/octet-stream',
}) async {
  throw UnsupportedError('web_saver: no implementation for this platform');
}
