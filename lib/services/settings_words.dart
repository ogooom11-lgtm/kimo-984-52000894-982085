// lib/services/settings_words.dart
// إضافة/إزالة كلمات من قوائم الإعدادات مباشرة (يُستخدم من قائمة الضغط المطوّل
// على الكلمات في شاشة الفقاعات) مع الحفظ الفوري في قاعدة البيانات.

import '../database_service.dart';
import '../models.dart';
import 'detection/text_tokens.dart';

enum WordListKind {
  forbidden,
  forbiddenPhrase,
  nameKeyword,
  amountKeyword,
  ignored,
  lineIgnored,
  cancelKeyword,
  readyName,
  companyUser,
}

extension WordListKindInfo on WordListKind {
  String get label {
    switch (this) {
      case WordListKind.forbidden:
        return 'الكلمات الممنوعة';
      case WordListKind.forbiddenPhrase:
        return 'الجمل الممنوعة';
      case WordListKind.nameKeyword:
        return 'كلمات الاسم';
      case WordListKind.amountKeyword:
        return 'كلمات المبلغ';
      case WordListKind.ignored:
        return 'الكلمات المهملة';
      case WordListKind.lineIgnored:
        return 'كلمات تجاهل السطر';
      case WordListKind.cancelKeyword:
        return 'كلمات الإلغاء';
      case WordListKind.readyName:
        return 'الأسماء الجاهزة';
      case WordListKind.companyUser:
        return 'أسماء مستخدمي الشركة';
    }
  }
}

class SettingsWords {
  static Settings defaults() => Settings(
    nameKeywords: ['المستفيد', 'إلى', 'ل', 'لـ'],
    amountKeywords: ['المبلغ', 'قيمة', 'amount', '\$'],
    currencyMap: {'\$': 'دولار'},
    ignoredWords: [],
    cancelKeywords: ['الغاء'],
  );

  static Settings load() => DatabaseService.getSettings() ?? defaults();

  static List<String> listOf(Settings s, WordListKind k) {
    switch (k) {
      case WordListKind.forbidden:
        return s.forbiddenWords;
      case WordListKind.forbiddenPhrase:
        return s.forbiddenPhrases;
      case WordListKind.nameKeyword:
        return s.nameKeywords;
      case WordListKind.amountKeyword:
        return s.amountKeywords;
      case WordListKind.ignored:
        return s.ignoredWords;
      case WordListKind.lineIgnored:
        return s.lineIgnoredWords;
      case WordListKind.cancelKeyword:
        return s.cancelKeywords;
      case WordListKind.readyName:
        return s.bubbleReadyNames;
      case WordListKind.companyUser:
        return s.companyUserNames;
    }
  }

  static void _setList(Settings s, WordListKind k, List<String> v) {
    switch (k) {
      case WordListKind.forbidden:
        s.forbiddenWords = v;
        break;
      case WordListKind.forbiddenPhrase:
        s.forbiddenPhrases = v;
        break;
      case WordListKind.nameKeyword:
        s.nameKeywords = v;
        break;
      case WordListKind.amountKeyword:
        s.amountKeywords = v;
        break;
      case WordListKind.ignored:
        s.ignoredWords = v;
        break;
      case WordListKind.lineIgnored:
        s.lineIgnoredWords = v;
        break;
      case WordListKind.cancelKeyword:
        s.cancelKeywords = v;
        break;
      case WordListKind.readyName:
        s.bubbleReadyNames = v;
        break;
      case WordListKind.companyUser:
        s.companyUserNames = v;
        break;
    }
  }

  static bool contains(Settings s, WordListKind k, String word) {
    final key = normalizeText(word);
    if (key.isEmpty) return false;
    return listOf(s, k).any((e) => normalizeText(e) == key);
  }

  /// يضيف الكلمة ويحفظ. يعيد false إذا كانت موجودة مسبقًا أو فارغة.
  static Future<bool> add(WordListKind k, String word) async {
    final value = word.trim();
    if (value.isEmpty) return false;
    final s = load();
    if (contains(s, k, value)) return false;
    _setList(s, k, [...listOf(s, k), value]);
    await DatabaseService.saveSettings(s);
    return true;
  }

  static Future<bool> remove(WordListKind k, String word) async {
    final key = normalizeText(word);
    if (key.isEmpty) return false;
    final s = load();
    final current = listOf(s, k);
    final next = current.where((e) => normalizeText(e) != key).toList();
    if (next.length == current.length) return false;
    _setList(s, k, next);
    await DatabaseService.saveSettings(s);
    return true;
  }

  /// العملات المعرفة (الأسماء المعروضة بدون تكرار)
  static List<String> currencyNames(Settings s) =>
      s.currencyMap.values.map((e) => e.trim()).toSet().toList()..sort();

  /// اسم العملة التي يتبع لها الاختصار (إن وجد)
  static String? currencyOfAlias(Settings s, String alias) {
    final key = normalizeText(alias);
    for (final e in s.currencyMap.entries) {
      if (normalizeText(e.key) == key) return e.value;
    }
    return null;
  }

  static Future<bool> addCurrencyAlias(String alias, String displayName) async {
    final a = alias.trim();
    final d = displayName.trim();
    if (a.isEmpty || d.isEmpty) return false;
    final s = load();
    if (currencyOfAlias(s, a) != null) return false;
    s.currencyMap = {...s.currencyMap, a: d};
    await DatabaseService.saveSettings(s);
    return true;
  }

  static Future<bool> removeCurrencyAlias(String alias) async {
    final key = normalizeText(alias);
    final s = load();
    final next = <String, String>{};
    var removed = false;
    s.currencyMap.forEach((k, v) {
      if (normalizeText(k) == key) {
        removed = true;
      } else {
        next[k] = v;
      }
    });
    if (!removed) return false;
    s.currencyMap = next;
    await DatabaseService.saveSettings(s);
    return true;
  }

  static Future<bool> setAmountWordValue(String word, double value) async {
    final w = word.trim();
    if (w.isEmpty || value <= 0) return false;
    final s = load();
    s.amountWordValues = {...s.amountWordValues, w: value};
    await DatabaseService.saveSettings(s);
    return true;
  }
}
