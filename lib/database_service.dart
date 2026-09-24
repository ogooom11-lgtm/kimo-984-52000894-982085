import 'package:hive/hive.dart';
import 'models.dart';

class DatabaseService {
  // ===========================
  // 🗃️ أسماء الصناديق
  // ===========================
  static const String accountsBoxName = "accounts";
  static const String transactionsBoxName = "transactions";
  static const String settingsBoxName = "settings";
  static const String parsesBoxName = "parses";

  // ===========================
  // 🚀 التهيئة
  // ===========================
  /// افتح جميع الصناديق (يُستدعى عند إقلاع التطبيق)
  static Future<void> init() async {
    await Hive.openBox<Account>(accountsBoxName);
    await Hive.openBox<TransactionModel>(transactionsBoxName);
    await Hive.openBox<Settings>(settingsBoxName);
    await Hive.openBox<ParsedText>(parsesBoxName);

    // ✅ اختيارية: ترحيل مفاتيح int قديمة (لو كنت سابقًا تستخدم put(id))
    // await migrateTransactionsIntKeysToString(); // فعّله مرة لو احتجت
    // await migrateParsesIntKeysToString();       // فعّله مرة لو احتجت
  }

  // ===========================
  // 📦 مراجع الصناديق
  // ===========================
  static Box<Account> get accountsBox => Hive.box<Account>(accountsBoxName);
  static Box<TransactionModel> get transactionsBox =>
      Hive.box<TransactionModel>(transactionsBoxName);
  static Box<Settings> get settingsBox => Hive.box<Settings>(settingsBoxName);
  static Box<ParsedText> get parsesBox => Hive.box<ParsedText>(parsesBoxName);

  // ====================================================================
  // 📌 الحسابات (Accounts)
  // ملاحظة: نفترض أن Account يمتد HiveObject (مستحسن)، وإن لم يكن فالدوال أدناه تعمل أيضًا.
  // ====================================================================

  /// إضافة حساب بمفتاح Hive تلقائي
  static Future<void> addAccount(Account account) async {
    await accountsBox.add(account);
  }

  /// جلب جميع الحسابات
  static Future<List<Account>> getAccounts() async {
    return accountsBox.values.toList();
  }

  /// حذف حساب بمفتاح Hive (إن عرفت المفتاح)
  static Future<void> deleteAccountByHiveKey(dynamic hiveKey) async {
    if (accountsBox.containsKey(hiveKey)) {
      await accountsBox.delete(hiveKey);
    }
  }

  /// حذف حساب عبر المعرّف التجاري داخل الموديل (إن كان لديه حقل id)
  static Future<void> deleteAccountByBusinessId(int businessId) async {
    final key = _findKeyByPredicate<Account>(
      accountsBox,
      (a) => (a.id == businessId),
    );
    if (key != null) await accountsBox.delete(key);
  }

  /// مسح جميع الحسابات
  static Future<void> clearAccounts() async {
    await accountsBox.clear();
  }

  // ====================================================================
  // 📌 العمليات (Transactions)
  // استراتيجية محكمة:
  // - إضافة: add(tx)
  // - تحديث: tx.save() إن كان داخل الصندوق، أو تحديث الموجود ثم save()
  // - حذف: إمّا بمفتاح Hive أو بالبحث عن id التجاري داخل الموديل
  // ====================================================================

  /// إضافة حركة بمفتاح تلقائي
  static Future<void> addTransaction(TransactionModel tx) async {
    await transactionsBox.add(tx);
  }

  /// تحديث حركة بدون تغيير مفتاح Hive (يتفادى أخطاء "نفس الـ instance بمفتاحين")
  static Future<void> updateTransaction(TransactionModel tx) async {
    final box = transactionsBox;

    // لو الـ instance نفسها محفوظة داخل الصندوق
    if (tx is HiveObject && tx.isInBox) {
      await tx.save();
      return;
    }

    // ابحث عن السجل الموجود بنفس "الـ id التجاري" داخل الموديل
    final existingKey = _findKeyByPredicate<TransactionModel>(
      box,
      (t) => (t.id == tx.id),
    );

    if (existingKey != null) {
      final existing = box.get(existingKey)!;
      // انسخ الحقول المتغيرة
      existing
        ..status = tx.status
        ..date = tx.date
        ..amount = tx.amount
        ..secondAmount = tx.secondAmount
        ..currency = tx.currency
        ..secondCurrency = tx.secondCurrency
        ..beneficiary = tx.beneficiary
        ..accountId = tx.accountId
        ..notes = tx.notes
        ..receivedAt = tx.receivedAt
        ..cancelledAt = tx.cancelledAt;

      await existing.save(); // تحديث في مكانه بدون تغيير المفتاح
      // تحديث في مكانه بدون تغيير المفتاح
    } else {
      // غير موجود مسبقًا: أضفه كمُدخل جديد بمفتاح تلقائي
      await box.add(tx);
    }
  }

  static Future<void> setTxStatus(
    TransactionModel t,
    TransactionStatus s, {
    DateTime? at,
  }) async {
    final ts = at ?? DateTime.now();
    switch (s) {
      case TransactionStatus.added:
        t.status = TransactionStatus.added;
        t.receivedAt = null;
        t.cancelledAt = null;
        break;
      case TransactionStatus.received:
        t.status = TransactionStatus.received;
        t.receivedAt = ts;
        t.cancelledAt = null;
        break;
      case TransactionStatus.cancelled:
        t.status = TransactionStatus.cancelled;
        t.cancelledAt = ts;
        t.receivedAt = null;
        break;
    }
    if (t is HiveObject && t.isInBox) {
      await t.save();
    } else {
      await updateTransaction(t);
    }
  }

  /// جلب جميع الحركات
  static Future<List<TransactionModel>> getAllTransactions() async {
    return transactionsBox.values.toList();
  }

  /// جلب حركات حساب معيّن (مرتبة تنازليًا حسب التاريخ)
  static List<TransactionModel> getTransactionsForAccount(int accountId) {
    return transactionsBox.values
        .where((t) => t.accountId == accountId)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  /// إيجاد حركة عبر "الـ id التجاري" داخل الموديل
  static TransactionModel? findTransactionByBusinessId(int businessId) {
    try {
      return transactionsBox.values.firstWhere((t) => t.id == businessId);
    } catch (_) {
      return null;
    }
  }

  /// حذف حركة بمفتاح Hive (إن كنت تعرفه)
  static Future<void> deleteTransactionByHiveKey(dynamic hiveKey) async {
    if (transactionsBox.containsKey(hiveKey)) {
      await transactionsBox.delete(hiveKey);
    }
  }

  /// حذف حركة عبر "الـ id التجاري" داخل الموديل (بدون معرفة مفتاح Hive)
  static Future<void> deleteTransactionByBusinessId(int businessId) async {
    final key = _findKeyByPredicate<TransactionModel>(
      transactionsBox,
      (t) => (t.id == businessId),
    );
    if (key != null) await transactionsBox.delete(key);
  }

  /// مسح جميع الحركات
  static Future<void> clearTransactions() async {
    await transactionsBox.clear();
  }

  // ====================================================================
  // 📌 الإعدادات (Settings)
  // ====================================================================

  /// حفظ إعدادات التطبيق بمفتاح ثابت
  static Future<void> saveSettings(Settings settings) async {
    await settingsBox.put("app_settings", settings);
  }

  /// جلب إعدادات التطبيق
  static Settings? getSettings() {
    return settingsBox.get("app_settings");
  }

  /// حذف إعدادات التطبيق
  static Future<void> clearSettings() async {
    await settingsBox.delete("app_settings");
  }

  // ====================================================================
  // 📌 المحفوظات (Parsed Texts)
  // التوحيد على add(...) لتفادي مفاتيح int كبيرة.
  // ====================================================================

  /// إضافة نصّ محلَّل بمفتاح تلقائي
  static Future<void> addParsedText(ParsedText item) async {
    await parsesBox.add(item);
  }

  /// جميع المحفوظات مرتبة (الأحدث أولًا)
  static List<ParsedText> getAllParses() {
    final list = parsesBox.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// حذف محفوظ بمفتاح Hive
  static Future<void> deleteParsedTextByHiveKey(dynamic hiveKey) async {
    if (parsesBox.containsKey(hiveKey)) {
      await parsesBox.delete(hiveKey);
    }
  }

  /// حذف محفوظ عبر "الـ id التجاري" داخل الموديل (إن وُجد)
  static Future<void> deleteParsedTextByBusinessId(int businessId) async {
    final key = _findKeyByPredicate<ParsedText>(
      parsesBox,
      (p) => (p.id == businessId),
    );
    if (key != null) await parsesBox.delete(key);
  }

  /// مسح كل المحفوظات
  static Future<void> clearParses() async {
    await parsesBox.clear();
  }

  // ====================================================================
  // 🧰 أدوات مساعدة عامة
  // ====================================================================

  /// البحث عن مفتاح Hive عبر شرط على القيمة داخل الصندوق
  static dynamic _findKeyByPredicate<T>(
    Box<T> box,
    bool Function(T value) test,
  ) {
    for (final key in box.keys) {
      final value = box.get(key);
      if (value != null && test(value)) return key;
    }
    return null;
  }

  // ====================================================================
  // 🔄 (اختياري) أدوات ترحيل إن كنت خزّنت سابقًا بمفاتيح int عبر put(id)
  // شغّلها مرة ثم عطّلها.
  // ====================================================================

  static Future<void> migrateTransactionsIntKeysToString() async {
    final box = transactionsBox;
    final keys = box.keys.toList();

    for (final k in keys) {
      if (k is int && k > 0xFFFFFFFF) {
        // نقل من مفتاح int كبير إلى مفتاح نصي (تجنّبًا للخطأ)
        final v = box.get(k);
        if (v != null) {
          await box.put(k.toString(), v);
          await box.delete(k);
        }
      }
    }
  }

  static Future<void> migrateParsesIntKeysToString() async {
    final box = parsesBox;
    final keys = box.keys.toList();

    for (final k in keys) {
      if (k is int && k > 0xFFFFFFFF) {
        final v = box.get(k);
        if (v != null) {
          await box.put(k.toString(), v);
          await box.delete(k);
        }
      }
    }
  }
}
