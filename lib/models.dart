import 'package:hive/hive.dart';

part 'models.g.dart';

/// الحالة تبع كل عملية
@HiveType(typeId: 0)
enum TransactionStatus {
  @HiveField(0)
  added,
  @HiveField(1)
  received,
  @HiveField(2)
  cancelled,
}

/// نوع الحساب. الحسابات القديمة تُقرأ تلقائيًا كحساب مكتب.
@HiveType(typeId: 6)
enum AccountType {
  @HiveField(0)
  office,
  @HiveField(1)
  company,
}

/// نوع حركة الشركة. الإلغاء جزء من نوع الحركة لأن حركة الشركة لا تمر
/// بدورة «مضافة/مستلمة» الخاصة بحساب المكتب.
@HiveType(typeId: 7)
enum CompanyMovementType {
  @HiveField(0)
  sent,
  @HiveField(1)
  received,
  @HiveField(2)
  sentCancelled,
  @HiveField(3)
  receivedCancelled,
}

extension AccountTypeLabels on AccountType {
  String get label => this == AccountType.company ? 'حساب شركة' : 'حساب مكتب';
  bool get isCompany => this == AccountType.company;
}

extension CompanyMovementLabels on CompanyMovementType {
  bool get isCancelled =>
      this == CompanyMovementType.sentCancelled ||
      this == CompanyMovementType.receivedCancelled;
  bool get isSent =>
      this == CompanyMovementType.sent ||
      this == CompanyMovementType.sentCancelled;
  CompanyMovementType get cancelled => isSent
      ? CompanyMovementType.sentCancelled
      : CompanyMovementType.receivedCancelled;
  String get label {
    switch (this) {
      case CompanyMovementType.sent:
        return 'حركة مرسلة';
      case CompanyMovementType.received:
        return 'حركة استقبال';
      case CompanyMovementType.sentCancelled:
        return 'حركة مرسلة ملغية';
      case CompanyMovementType.receivedCancelled:
        return 'حركة استقبال ملغية';
    }
  }
}

/// الحساب
@HiveType(typeId: 1)
class Account extends HiveObject {
  @HiveField(0)
  int id;

  @HiveField(1)
  String name;

  @HiveField(2)
  List<String> keywords;

  @HiveField(3)
  AccountType type;

  Account({
    required this.id,
    required this.name,
    List<String>? keywords,
    this.type = AccountType.office,
  }) : keywords = keywords ?? [];
}

/// العملية (Transaction)
@HiveType(typeId: 2)
class TransactionModel extends HiveObject {
  @HiveField(0)
  int id;

  @HiveField(1)
  int accountId;

  @HiveField(2)
  String beneficiary;

  @HiveField(3)
  double amount; // المبلغ الأول

  @HiveField(4)
  String currency;

  @HiveField(5)
  String notes;

  @HiveField(6)
  TransactionStatus status;

  @HiveField(7)
  DateTime date;

  @HiveField(8)
  DateTime? receivedAt;

  @HiveField(9)
  DateTime? cancelledAt;

  @HiveField(10)
  double? secondAmount; // المبلغ الثاني (اختياري)

  @HiveField(11)
  String? secondCurrency;

  /// لا تكون null إلا في الحركات القديمة أو حركات حساب المكتب.
  @HiveField(12)
  CompanyMovementType? companyMovementType;

  /// وجهة حركة الشركة (اسم الوجهة كما هو بالإعدادات) — لحركات الشركات بس.
  @HiveField(13)
  String? destination;

  TransactionModel({
    required this.id,
    required this.accountId,
    required this.beneficiary,
    required this.amount,
    required this.currency,
    required this.notes,
    required this.status,
    required this.date,
    this.receivedAt,
    this.cancelledAt,
    this.secondAmount,
    this.secondCurrency,
    this.companyMovementType,
    this.destination,
  });

  double get totalAmount => amount + (secondAmount ?? 0.0);

  bool get hasSecondAmount => secondAmount != null && secondAmount! > 0;

  bool get isCompanyTransaction => companyMovementType != null;

  bool get isCompanyCancelled => effectiveCompanyMovement?.isCancelled ?? false;

  /// نوع حركة الشركة الفعلي: الحركات التي أُلغيت عبر الحالة (بيانات قديمة أو
  /// إلغاء جماعي قديم) تُعامل كحركات ملغية.
  CompanyMovementType? get effectiveCompanyMovement {
    final m = companyMovementType;
    if (m == null) return null;
    if (!m.isCancelled && status == TransactionStatus.cancelled) {
      return m.cancelled;
    }
    return m;
  }

  void cancelCompanyMovement() {
    if (companyMovementType != null) {
      companyMovementType = companyMovementType!.cancelled;
      cancelledAt = DateTime.now();
    }
  }

  void applyStatus(TransactionStatus s, {DateTime? at}) {
    final ts = at ?? DateTime.now();
    switch (s) {
      case TransactionStatus.added:
        status = TransactionStatus.added;
        receivedAt = null;
        cancelledAt = null;
        break;
      case TransactionStatus.received:
        status = TransactionStatus.received;
        receivedAt = ts;
        cancelledAt = null;
        break;
      case TransactionStatus.cancelled:
        status = TransactionStatus.cancelled;
        cancelledAt = ts;
        receivedAt = null;
        break;
    }
  }
}

@HiveType(typeId: 5)
class BubbleQuickActionConfig {
  @HiveField(0)
  int id;

  @HiveField(1)
  String label;

  @HiveField(2)
  String iconKey;

  @HiveField(3)
  String actionType;

  @HiveField(4)
  String value;

  @HiveField(5)
  bool iconAbove;

  /// لون الزر (ARGB). null = لون التطبيق.
  @HiveField(6)
  int? colorValue;

  /// false = الزر مخفي مؤقتًا (بدون حذف).
  @HiveField(7)
  bool enabled;

  /// شكل الزر: outlined / filled / tonal / text
  @HiveField(8)
  String style;

  /// بأي فقاعات بيظهر: add / edit / cancel (فاضية = بالكل).
  @HiveField(9)
  List<String> modes;

  /// نوع الحساب: '' = الكل، 'office' = حسابات المكاتب، 'company' = الشركات.
  @HiveField(10)
  String scope;

  /// العرض: '' = أيقونة ونص، 'icon' = أيقونة بس، 'text' = نص بس.
  @HiveField(11)
  String display;

  BubbleQuickActionConfig({
    required this.id,
    required this.label,
    required this.iconKey,
    required this.actionType,
    this.value = '',
    this.iconAbove = false,
    this.colorValue,
    this.enabled = true,
    this.style = 'outlined',
    List<String>? modes,
    this.scope = '',
    this.display = '',
  }) : modes = modes ?? <String>[];

  BubbleQuickActionConfig copy({
    int? id,
    String? label,
    String? iconKey,
    String? actionType,
    String? value,
    bool? iconAbove,
    int? colorValue,
    bool clearColor = false,
    bool? enabled,
    String? style,
    List<String>? modes,
    String? scope,
    String? display,
  }) => BubbleQuickActionConfig(
    id: id ?? this.id,
    label: label ?? this.label,
    iconKey: iconKey ?? this.iconKey,
    actionType: actionType ?? this.actionType,
    value: value ?? this.value,
    iconAbove: iconAbove ?? this.iconAbove,
    colorValue: clearColor ? null : (colorValue ?? this.colorValue),
    enabled: enabled ?? this.enabled,
    style: style ?? this.style,
    modes: List<String>.of(modes ?? this.modes),
    scope: scope ?? this.scope,
    display: display ?? this.display,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'label': label,
    'iconKey': iconKey,
    'actionType': actionType,
    'value': value,
    'iconAbove': iconAbove,
    if (colorValue != null) 'color': colorValue,
    'enabled': enabled,
    'style': style,
    'modes': List<String>.of(modes),
    'scope': scope,
    'display': display,
  };

  static BubbleQuickActionConfig fromMap(Map<dynamic, dynamic> m, {int? id}) {
    final rawModes = m['modes'];
    final color = m['color'];
    return BubbleQuickActionConfig(
      id: m['id'] is num
          ? (m['id'] as num).toInt()
          : (id ?? DateTime.now().millisecondsSinceEpoch),
      label: m['label']?.toString() ?? '',
      iconKey: m['iconKey']?.toString() ?? 'flash',
      actionType: m['actionType']?.toString() ?? 'clearStage',
      value: m['value']?.toString() ?? '',
      iconAbove: m['iconAbove'] == true,
      colorValue: color is num ? color.toInt() : null,
      enabled: m['enabled'] != false,
      style: m['style']?.toString() ?? 'outlined',
      modes: rawModes is List
          ? [for (final x in rawModes) x.toString()]
          : <String>[],
      scope: m['scope']?.toString() ?? '',
      display: m['display']?.toString() ?? '',
    );
  }
}

/// الإعدادات
@HiveType(typeId: 3)
class Settings extends HiveObject {
  @HiveField(0)
  List<String> nameKeywords;

  @HiveField(1)
  List<String> amountKeywords;

  @HiveField(2)
  Map<String, String> currencyMap;

  @HiveField(3)
  List<String> ignoredWords;
  @HiveField(4)
  List<String> lineIgnoredWords;
  @HiveField(5)
  List<String> cancelKeywords;
  @HiveField(6)
  Map<String, double> amountWordValues;
  @HiveField(7)
  List<String> bubbleReadyNames;
  @HiveField(8)
  List<BubbleQuickActionConfig> bubbleQuickActions;

  /// الأسماء التي تعتبر رسائلها «مرسلة» في حسابات الشركة.
  @HiveField(9)
  List<String> companyUserNames;

  /// كلمات ممنوعة: لا يمكن أن تكون جزءًا من الاسم، ويتوقف عندها تمديد الاسم،
  /// وإذا انتهى بها السطر فالسطر الذي يليه لا يُعتبر سطر اسم.
  @HiveField(10)
  List<String> forbiddenWords;

  /// جمل ممنوعة: عند ظهورها في الرسالة يتم تنبيه المستخدم وإظهارها بوضوح.
  @HiveField(11)
  List<String> forbiddenPhrases;

  /// تفضيلات تصميم شاشة الفقاعات (حجم الخط، الألوان، ...).
  /// تُقرأ عبر [BubbleUiPrefs] في lib/bubble_prefs.dart.
  @HiveField(12)
  Map<String, dynamic> bubbleUiPrefs;

  /// كلمات تجعل الرسالة «تعديل حركة موجودة» في شاشة الفقاعات.
  @HiveField(13)
  List<String> editKeywords;

  /// الوجهات (لحركات الشركات): اختصار ← اسم الوجهة (متل العملات).
  @HiveField(14)
  Map<String, String> destinationMap;

  /// معلومات كل وجهة: اسم الوجهة ← {'office': bool, 'accounts': [id...]}.
  /// كل وجهة لازم يكون إلها مدخل هون (حتى لو بدون اختصارات).
  @HiveField(15)
  Map<String, dynamic> destinationInfo;

  Settings({
    required this.nameKeywords,
    required this.amountKeywords,
    required this.currencyMap,
    required this.ignoredWords,
    this.lineIgnoredWords = const [],
    this.cancelKeywords = const ['الغاء'],
    this.amountWordValues = const {},
    this.bubbleReadyNames = const [],
    this.bubbleQuickActions = const [],
    this.companyUserNames = const [],
    this.forbiddenWords = const [],
    this.forbiddenPhrases = const [],
    this.bubbleUiPrefs = const {},
    this.editKeywords = const ['تعديل'],
    this.destinationMap = const {},
    this.destinationInfo = const {},
  });
}

@HiveType(typeId: 4)
class ParsedText extends HiveObject {
  @HiveField(0)
  int id;

  @HiveField(1)
  String title; // عنوان اختياري من المستخدم

  @HiveField(2)
  String originalText; // النص الأصلي الكامل

  @HiveField(3)
  List<String> selectedLines; // الأسطر التي اختارها من Bubble

  @HiveField(4)
  List<String> finalLines; // الناتج بعد Filter

  @HiveField(5)
  DateTime createdAt;

  ParsedText({
    required this.id,
    required this.title,
    required this.originalText,
    required this.selectedLines,
    required this.finalLines,
    required this.createdAt,
  });
}
