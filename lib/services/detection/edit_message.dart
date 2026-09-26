// lib/services/detection/edit_message.dart
// -------------------------------------------------------------
// رسائل التعديل في شاشة الفقاعات:
// - تصنيف الرسالة (إضافة / تعديل / إلغاء) حسب الكلمات المفتاحية في الإعدادات.
// - اقتراح التعديلات على حركة موجودة: مقارنة الاسم والمبلغ والعملة المكتشفة
//   في الرسالة مع قيم الحركة الحالية، والمستخدم يختار ما يريد تعديله.
//
// Dart نقي (بدون Flutter) حتى يُختبر مباشرة.
// -------------------------------------------------------------

enum MessageKind { add, edit, cancel }

/// نوع الرسالة حسب الكلمات المفتاحية. كلمات الإلغاء أولًا (كما كان سابقًا)،
/// ثم كلمات التعديل، وإلا فهي إضافة.
/// [normalize] نفس التطبيع المستخدم في الشاشة (عربي + أحرف صغيرة + مسافات).
MessageKind classifyMessage(
  String text, {
  required List<String> cancelKeywords,
  required List<String> editKeywords,
  required String Function(String) normalize,
}) {
  final t = normalize(text);
  if (t.isEmpty) return MessageKind.add;
  bool hit(List<String> words) {
    for (final w in words) {
      final k = normalize(w);
      if (k.isNotEmpty && t.contains(k)) return true;
    }
    return false;
  }

  if (hit(cancelKeywords)) return MessageKind.cancel;
  if (hit(editKeywords)) return MessageKind.edit;
  return MessageKind.add;
}

enum EditField { name, amount, currency }

extension EditFieldInfo on EditField {
  String get label {
    switch (this) {
      case EditField.name:
        return 'الاسم';
      case EditField.amount:
        return 'المبلغ';
      case EditField.currency:
        return 'العملة';
    }
  }
}

/// اقتراح تعديل حقل واحد من حقول الحركة
class EditProposal {
  final EditField field;

  /// القيمة الحالية في الحركة (للعرض)
  final String oldText;

  /// القيمة المكتشفة في الرسالة (null = لم تُكتشف)
  final String? newText;

  /// هل تختلف القيمة المكتشفة عن الحالية؟
  final bool changes;

  const EditProposal({
    required this.field,
    required this.oldText,
    required this.newText,
    required this.changes,
  });

  /// يمكن اختياره للتعديل: قيمة مكتشفة ومختلفة
  bool get available => newText != null && changes;

  /// الجملة الكاملة، مثل: «المبلغ: من 300 إلى 500»
  String get sentence => '${field.label}: من $oldText إلى ${newText ?? '—'}';

  @override
  String toString() => sentence;
}

/// يقارن ما اكتُشف في الرسالة مع قيم الحركة الحالية (بالترتيب: الاسم، المبلغ،
/// العملة).
List<EditProposal> buildEditProposals({
  required String oldName,
  required double oldAmount,
  required String oldCurrency,
  String? newName,
  double? newAmount,
  String? newCurrency,
  required String Function(String) normalizeName,
  required bool Function(String a, String b) sameCurrency,
  required String Function(double) formatAmount,
}) {
  final name = newName?.trim() ?? '';
  final hasName = name.isNotEmpty && normalizeName(name).isNotEmpty;
  final hasAmount = newAmount != null && newAmount.isFinite && newAmount > 0;
  final currency = newCurrency?.trim() ?? '';
  final hasCurrency = currency.isNotEmpty;
  return [
    EditProposal(
      field: EditField.name,
      oldText: oldName.trim(),
      newText: hasName ? name : null,
      changes: hasName && normalizeName(name) != normalizeName(oldName),
    ),
    EditProposal(
      field: EditField.amount,
      oldText: formatAmount(oldAmount),
      newText: hasAmount ? formatAmount(newAmount) : null,
      changes: hasAmount && (newAmount - oldAmount).abs() > 0.0001,
    ),
    EditProposal(
      field: EditField.currency,
      oldText: oldCurrency.trim(),
      newText: hasCurrency ? currency : null,
      changes: hasCurrency && !sameCurrency(currency, oldCurrency),
    ),
  ];
}

/// الاختيار المبدئي عند اختيار الحركة: المبلغ والعملة إذا تغيّرا. الاسم لا
/// يُختار تلقائيًا لأنه غالبًا اسم البحث نفسه (يختاره المستخدم إن أراد).
Set<EditField> defaultEditSelection(List<EditProposal> proposals) => {
  for (final p in proposals)
    if (p.available && p.field != EditField.name) p.field,
};

/// الحقول التي ستُعدَّل فعلًا: المختارة والمتاحة معًا
Set<EditField> effectiveEditFields(
  List<EditProposal> proposals,
  Set<EditField> chosen,
) => {
  for (final p in proposals)
    if (p.available && chosen.contains(p.field)) p.field,
};
