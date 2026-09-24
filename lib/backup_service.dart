import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'database_service.dart';
import 'models.dart';

class BackupStats {
  final int accountsCount;
  final int transactionsCount;
  final int parsesCount;
  final int currenciesCount;
  final int nameKeywordsCount;
  final int amountKeywordsCount;
  final int ignoredWordsCount;
  final double primaryAmountTotal;
  final double secondaryAmountTotal;
  final bool hasSettings;

  const BackupStats({
    required this.accountsCount,
    required this.transactionsCount,
    required this.parsesCount,
    required this.currenciesCount,
    required this.nameKeywordsCount,
    required this.amountKeywordsCount,
    required this.ignoredWordsCount,
    required this.primaryAmountTotal,
    required this.secondaryAmountTotal,
    required this.hasSettings,
  });
}

class BackupDashboardData {
  final BackupStats stats;
  final List<Account> accounts;
  final List<TransactionModel> transactions;
  final List<ParsedText> parses;
  final Settings? settings;

  const BackupDashboardData({
    required this.stats,
    required this.accounts,
    required this.transactions,
    required this.parses,
    required this.settings,
  });
}

class PickedBackupFile {
  final String path;
  final Map<String, dynamic> payload;
  final BackupStats stats;
  final DateTime? createdAt;

  const PickedBackupFile({
    required this.path,
    required this.payload,
    required this.stats,
    required this.createdAt,
  });
}

class BackupService {
  static Future<BackupDashboardData> loadDashboard() async {
    final accounts = await DatabaseService.getAccounts();
    final transactions = await DatabaseService.getAllTransactions();
    final parses = DatabaseService.getAllParses();
    final settings = DatabaseService.getSettings();

    transactions.sort((a, b) => b.date.compareTo(a.date));

    final stats = _buildStats(
      accounts: accounts,
      transactions: transactions,
      parses: parses,
      settings: settings,
    );

    return BackupDashboardData(
      stats: stats,
      accounts: accounts,
      transactions: transactions,
      parses: parses,
      settings: settings,
    );
  }

  static Future<String?> exportBackupToChosenFolder() async {
    final accounts = await DatabaseService.getAccounts();
    final transactions = await DatabaseService.getAllTransactions();
    final parses = DatabaseService.getAllParses();
    final settings = DatabaseService.getSettings();

    final payload = <String, dynamic>{
      'app': 'my_list',
      'backupVersion': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'accounts': accounts.map(_accountToMap).toList(),
      'transactions': transactions.map(_transactionToMap).toList(),
      'settings': settings == null ? null : _settingsToMap(settings),
      'parses': parses.map(_parsedTextToMap).toList(),
    };

    final jsonString = const JsonEncoder.withIndent('  ').convert(payload);

    final selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'اختر مجلد حفظ النسخة الاحتياطية',
    );

    if (selectedDirectory == null || selectedDirectory.trim().isEmpty) {
      return null;
    }

    final timestamp = _compactStamp(DateTime.now());
    final fileName = 'my_list_backup_$timestamp.json';
    final filePath = '$selectedDirectory${Platform.pathSeparator}$fileName';

    final file = File(filePath);
    await file.writeAsString(jsonString, flush: true);

    return file.path;
  }

  static Future<PickedBackupFile?> pickBackupFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      allowMultiple: false,
      withData: false,
      dialogTitle: 'اختر ملف النسخة الاحتياطية',
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final path = result.files.single.path;
    if (path == null || path.trim().isEmpty) {
      return null;
    }

    final file = File(path);
    final content = await file.readAsString();
    final decoded = jsonDecode(content);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ملف النسخة الاحتياطية غير صالح');
    }

    final stats = _statsFromPayload(decoded);
    final createdAt = _tryParseDate(decoded['createdAt']);

    return PickedBackupFile(
      path: path,
      payload: decoded,
      stats: stats,
      createdAt: createdAt,
    );
  }

  static Future<void> restoreBackup(PickedBackupFile backup) async {
    final payload = backup.payload;

    final accountsJson = _asMapList(payload['accounts']);
    final transactionsJson = _asMapList(payload['transactions']);
    final parsesJson = _asMapList(payload['parses']);
    final settingsJson = payload['settings'];

    await DatabaseService.accountsBox.clear();
    await DatabaseService.transactionsBox.clear();
    await DatabaseService.parsesBox.clear();
    await DatabaseService.clearSettings();

    for (final item in accountsJson) {
      await DatabaseService.addAccount(_accountFromMap(item));
    }

    for (final item in transactionsJson) {
      await DatabaseService.addTransaction(_transactionFromMap(item));
    }

    if (settingsJson is Map<String, dynamic>) {
      await DatabaseService.saveSettings(_settingsFromMap(settingsJson));
    }

    for (final item in parsesJson) {
      await DatabaseService.addParsedText(_parsedTextFromMap(item));
    }
  }

  static BackupStats _buildStats({
    required List<Account> accounts,
    required List<TransactionModel> transactions,
    required List<ParsedText> parses,
    required Settings? settings,
  }) {
    double primary = 0;
    double secondary = 0;

    for (final tx in transactions) {
      primary += tx.amount;
      secondary += tx.secondAmount ?? 0;
    }

    return BackupStats(
      accountsCount: accounts.length,
      transactionsCount: transactions.length,
      parsesCount: parses.length,
      currenciesCount: settings?.currencyMap.length ?? 0,
      nameKeywordsCount: settings?.nameKeywords.length ?? 0,
      amountKeywordsCount: settings?.amountKeywords.length ?? 0,
      ignoredWordsCount: settings?.ignoredWords.length ?? 0,
      primaryAmountTotal: primary,
      secondaryAmountTotal: secondary,
      hasSettings: settings != null,
    );
  }

  static BackupStats _statsFromPayload(Map<String, dynamic> payload) {
    final accounts = _asMapList(payload['accounts']);
    final transactions = _asMapList(payload['transactions']);
    final parses = _asMapList(payload['parses']);
    final settings = payload['settings'];

    double primary = 0;
    double secondary = 0;

    for (final item in transactions) {
      primary += _toDouble(item['amount']);
      secondary += _toDouble(item['secondAmount']);
    }

    final currencyMap = settings is Map<String, dynamic>
        ? _stringMap(settings['currencyMap'])
        : <String, String>{};

    final nameKeywords = settings is Map<String, dynamic>
        ? _stringList(settings['nameKeywords'])
        : <String>[];

    final amountKeywords = settings is Map<String, dynamic>
        ? _stringList(settings['amountKeywords'])
        : <String>[];

    final ignoredWords = settings is Map<String, dynamic>
        ? _stringList(settings['ignoredWords'])
        : <String>[];

    return BackupStats(
      accountsCount: accounts.length,
      transactionsCount: transactions.length,
      parsesCount: parses.length,
      currenciesCount: currencyMap.length,
      nameKeywordsCount: nameKeywords.length,
      amountKeywordsCount: amountKeywords.length,
      ignoredWordsCount: ignoredWords.length,
      primaryAmountTotal: primary,
      secondaryAmountTotal: secondary,
      hasSettings: settings is Map<String, dynamic>,
    );
  }

  static Map<String, dynamic> _accountToMap(Account a) {
    return {
      'id': a.id,
      'name': a.name,
      'keywords': a.keywords,
      'type': a.type.name,
    };
  }

  static Account _accountFromMap(Map<String, dynamic> map) {
    return Account(
      id: _toInt(map['id']),
      name: (map['name'] ?? '').toString(),
      keywords: _stringList(map['keywords']),
      type: _accountTypeFromAny(map['type']),
    );
  }

  static Map<String, dynamic> _transactionToMap(TransactionModel t) {
    return {
      'id': t.id,
      'accountId': t.accountId,
      'beneficiary': t.beneficiary,
      'amount': t.amount,
      'currency': t.currency,
      'notes': t.notes,
      'status': t.status.name,
      'date': t.date.toIso8601String(),
      'receivedAt': t.receivedAt?.toIso8601String(),
      'cancelledAt': t.cancelledAt?.toIso8601String(),
      'secondAmount': t.secondAmount,
      'secondCurrency': t.secondCurrency,
      'companyMovementType': t.companyMovementType?.name,
    };
  }

  static TransactionModel _transactionFromMap(Map<String, dynamic> map) {
    return TransactionModel(
      id: _toInt(map['id']),
      accountId: _toInt(map['accountId']),
      beneficiary: (map['beneficiary'] ?? '').toString(),
      amount: _toDouble(map['amount']),
      currency: (map['currency'] ?? '').toString(),
      notes: (map['notes'] ?? '').toString(),
      status: _statusFromAny(map['status']),
      date: _toDate(map['date']),
      receivedAt: _tryParseDate(map['receivedAt']),
      cancelledAt: _tryParseDate(map['cancelledAt']),
      secondAmount: map['secondAmount'] == null
          ? null
          : _toDouble(map['secondAmount']),
      secondCurrency: map['secondCurrency']?.toString(),
      companyMovementType: _companyMovementTypeFromAny(
        map['companyMovementType'],
      ),
    );
  }

  static Map<String, dynamic> _settingsToMap(Settings s) {
    return {
      'nameKeywords': s.nameKeywords,
      'amountKeywords': s.amountKeywords,
      'currencyMap': s.currencyMap,
      'ignoredWords': s.ignoredWords,
      'lineIgnoredWords': s.lineIgnoredWords,
      'cancelKeywords': s.cancelKeywords,
      'amountWordValues': s.amountWordValues,
      'bubbleReadyNames': s.bubbleReadyNames,
      'bubbleQuickActions': s.bubbleQuickActions
          .map(
            (a) => {
              'id': a.id,
              'label': a.label,
              'iconKey': a.iconKey,
              'actionType': a.actionType,
              'value': a.value,
              'iconAbove': a.iconAbove,
            },
          )
          .toList(),
      'companyUserNames': s.companyUserNames,
      'forbiddenWords': s.forbiddenWords,
      'forbiddenPhrases': s.forbiddenPhrases,
      'bubbleUiPrefs': s.bubbleUiPrefs,
    };
  }

  static Settings _settingsFromMap(Map<String, dynamic> map) {
    return Settings(
      nameKeywords: _stringList(map['nameKeywords']),
      amountKeywords: _stringList(map['amountKeywords']),
      currencyMap: _stringMap(map['currencyMap']),
      ignoredWords: _stringList(map['ignoredWords']),
      lineIgnoredWords: _stringList(map['lineIgnoredWords']),
      cancelKeywords: _stringList(map['cancelKeywords']).isEmpty
          ? const ['الغاء']
          : _stringList(map['cancelKeywords']),
      amountWordValues: _doubleMap(map['amountWordValues']),
      bubbleReadyNames: _stringList(map['bubbleReadyNames']),
      bubbleQuickActions: _bubbleActionsFromAny(map['bubbleQuickActions']),
      companyUserNames: _stringList(map['companyUserNames']),
      forbiddenWords: _stringList(map['forbiddenWords']),
      forbiddenPhrases: _stringList(map['forbiddenPhrases']),
      bubbleUiPrefs: map['bubbleUiPrefs'] is Map
          ? (map['bubbleUiPrefs'] as Map).map(
              (key, value) => MapEntry(key.toString(), value),
            )
          : <String, dynamic>{},
    );
  }

  static Map<String, double> _doubleMap(dynamic value) {
    if (value is! Map) return {};
    final out = <String, double>{};
    for (final entry in value.entries) {
      final key = entry.key?.toString().trim() ?? '';
      final raw = entry.value;
      final parsed = raw is num
          ? raw.toDouble()
          : double.tryParse(raw?.toString().replaceAll(',', '.') ?? '');
      if (key.isNotEmpty && parsed != null) out[key] = parsed;
    }
    return out;
  }

  static List<BubbleQuickActionConfig> _bubbleActionsFromAny(dynamic value) {
    if (value is! List) return const [];
    final out = <BubbleQuickActionConfig>[];
    for (final item in value) {
      if (item is! Map) continue;
      out.add(
        BubbleQuickActionConfig(
          id: item['id'] is num
              ? (item['id'] as num).toInt()
              : DateTime.now().millisecondsSinceEpoch + out.length,
          label: item['label']?.toString() ?? '',
          iconKey: item['iconKey']?.toString() ?? 'bolt',
          actionType: item['actionType']?.toString() ?? 'clearStage',
          value: item['value']?.toString() ?? '',
          iconAbove: item['iconAbove'] == true,
        ),
      );
    }
    return out;
  }

  static Map<String, dynamic> _parsedTextToMap(ParsedText p) {
    return {
      'id': p.id,
      'title': p.title,
      'originalText': p.originalText,
      'selectedLines': p.selectedLines,
      'finalLines': p.finalLines,
      'createdAt': p.createdAt.toIso8601String(),
    };
  }

  static ParsedText _parsedTextFromMap(Map<String, dynamic> map) {
    return ParsedText(
      id: _toInt(map['id']),
      title: (map['title'] ?? '').toString(),
      originalText: (map['originalText'] ?? '').toString(),
      selectedLines: _stringList(map['selectedLines']),
      finalLines: _stringList(map['finalLines']),
      createdAt: _toDate(map['createdAt']),
    );
  }

  static List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return <String>[];
    return raw.map((e) => e.toString()).toList();
  }

  static Map<String, String> _stringMap(dynamic raw) {
    if (raw is! Map) return <String, String>{};
    final out = <String, String>{};
    for (final entry in raw.entries) {
      out[entry.key.toString()] = entry.value.toString();
    }
    return out;
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static DateTime _toDate(dynamic raw) {
    final parsed = _tryParseDate(raw);
    return parsed ?? DateTime.now();
  }

  static DateTime? _tryParseDate(dynamic raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    try {
      return DateTime.parse(text);
    } catch (_) {
      return null;
    }
  }

  static TransactionStatus _statusFromAny(dynamic raw) {
    if (raw is int && raw >= 0 && raw < TransactionStatus.values.length) {
      return TransactionStatus.values[raw];
    }

    final text = raw?.toString().trim() ?? '';
    for (final status in TransactionStatus.values) {
      if (status.name == text) return status;
    }

    return TransactionStatus.added;
  }

  static AccountType _accountTypeFromAny(dynamic raw) {
    final text = raw?.toString().trim();
    return text == AccountType.company.name
        ? AccountType.company
        : AccountType.office;
  }

  static CompanyMovementType? _companyMovementTypeFromAny(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    for (final type in CompanyMovementType.values) {
      if (type.name == text) return type;
    }
    return null;
  }

  static String _compactStamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}_${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
  }
}
