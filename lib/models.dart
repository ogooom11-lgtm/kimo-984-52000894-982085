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

  BubbleQuickActionConfig({
    required this.id,
    required this.label,
    required this.iconKey,
    required this.actionType,
    this.value = '',
    this.iconAbove = false,
  });
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
