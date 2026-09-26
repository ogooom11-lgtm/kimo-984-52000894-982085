// lib/screens/settings_screen.dart
// -------------------------------------------------------------
// صفحة الإعدادات (تصميم مصنّف وهادئ):
//  • صفحة رئيسية فيها مجموعات مرتبة: قراءة الرسائل، التصفية والتنظيف،
//    العملات، الحسابات والشركات، شاشة الفقاعات — مع بحث سريع في أسماء
//    الإعدادات وفي محتوى القوائم نفسها.
//  • كل قسم يفتح في صفحة مستقلة بسيطة بدل صفحة واحدة طويلة ومعجوقة.
//  • الحفظ تلقائي بعد كل تعديل، والحذف يمكن التراجع عنه من الإشعار.
// -------------------------------------------------------------

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../bubble_prefs.dart';
import '../database_service.dart';
import '../models.dart';
import '../services/detection/text_tokens.dart' show normalizeArabic;
import '../services/settings_words.dart';
import '../services/tx_history_service.dart';

// =============================================================
// الألوان المستخدمة لتمييز الأقسام
// =============================================================

const _kBlue = Color(0xFF3B82F6);
const _kGreen = Color(0xFF10B981);
const _kIndigo = Color(0xFF6366F1);
const _kPink = Color(0xFFEC4899);
const _kOrange = Color(0xFFF97316);
const _kRed = Color(0xFFEF4444);
const _kAmber = Color(0xFFF59E0B);
const _kRose = Color(0xFFE11D48);
const _kPurple = Color(0xFF8B5CF6);
const _kTeal = Color(0xFF14B8A6);
const _kCyan = Color(0xFF06B6D4);
const _kSlate = Color(0xFF64748B);
const _kViolet = Color(0xFFA855F7);

// =============================================================
// الصفحة الرئيسية للإعدادات
// =============================================================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final _SettingsStore _store;
  late final Listenable _accountsListenable;
  late final Listenable _listenable;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = _SettingsStore()..attach();
    _accountsListenable = DatabaseService.accountsBox.listenable();
    _listenable = Listenable.merge([_store, _accountsListenable]);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // لا نترك تعديلًا معلّقًا إذا خرج المستخدم من التطبيق
    if (state != AppLifecycleState.resumed) _store.flush();
  }

  Future<void> _open(Widget page) async {
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  _WordSpec _spec(WordListKind kind) => _specOf(kind);

  List<_HubGroup> _buildGroups() {
    final s = _store.settings;

    _HubTile wordTile(WordListKind kind) {
      final spec = _spec(kind);
      final list = SettingsWords.listOf(s, kind);
      return _HubTile(
        icon: spec.icon,
        color: spec.color,
        title: spec.title,
        subtitle: spec.subtitle,
        count: list.length,
        searchText: '${spec.subtitle} ${spec.keywords}',
        contents: list,
        onTap: () => _open(_WordListPage(store: _store, spec: spec)),
      );
    }

    final currencies = _store.groupedCurrencies();
    final accounts = DatabaseService.accountsBox.values.toList();
    final accountWords = <String>[for (final a in accounts) ...a.keywords];
    final actions = s.bubbleQuickActions;

    return [
      _HubGroup(
        title: 'قراءة الرسائل',
        icon: Icons.auto_awesome_rounded,
        tiles: [
          wordTile(WordListKind.nameKeyword),
          wordTile(WordListKind.amountKeyword),
          _HubTile(
            icon: Icons.calculate_rounded,
            color: _kIndigo,
            title: 'قيم الكلمات',
            subtitle: 'كلمات تُقرأ كأرقام، مثل: ستمئة = 600',
            count: s.amountWordValues.length,
            searchText: 'رقم ارقام عدد مبلغ بالحروف',
            contents: s.amountWordValues.keys.toList(),
            onTap: () => _open(_WordValuesPage(store: _store)),
          ),
          wordTile(WordListKind.cancelKeyword),
          wordTile(WordListKind.editKeyword),
        ],
      ),
      _HubGroup(
        title: 'التصفية والتنظيف',
        icon: Icons.filter_alt_rounded,
        tiles: [
          wordTile(WordListKind.forbidden),
          wordTile(WordListKind.forbiddenPhrase),
          wordTile(WordListKind.ignored),
          wordTile(WordListKind.lineIgnored),
        ],
      ),
      _HubGroup(
        title: 'العملات',
        icon: Icons.payments_rounded,
        tiles: [
          _HubTile(
            icon: Icons.currency_exchange_rounded,
            color: _kPurple,
            title: 'العملات والاختصارات',
            subtitle: currencies.isEmpty
                ? 'لا توجد عملات بعد'
                : '${currencies.length} عملة • ${s.currencyMap.length} اختصار',
            count: currencies.length,
            searchText: 'عمله عملات اختصار رمز دولار ريال ليره',
            contents: [...currencies.keys, ...s.currencyMap.keys],
            onTap: () => _open(_CurrenciesPage(store: _store)),
          ),
          _HubTile(
            icon: Icons.percent_rounded,
            color: _kTeal,
            title: 'تقسيم الحركات حسب العملة',
            subtitle: 'قسمة مبالغ الحركات المحفوظة لعملة معيّنة',
            searchText: 'تقسيم قسمه حركات عمله اداه',
            onTap: () => _openSplitTool(context, _store),
          ),
        ],
      ),
      _HubGroup(
        title: 'الحسابات والشركات',
        icon: Icons.account_balance_wallet_rounded,
        tiles: [
          _HubTile(
            icon: Icons.manage_search_rounded,
            color: _kTeal,
            title: 'كلمات الحسابات',
            subtitle: 'تساعد على اختيار الحساب تلقائيًا عند التحليل',
            count: accountWords.length,
            searchText: 'حساب حسابات اختيار تلقائي',
            contents: [...accounts.map((a) => a.name), ...accountWords],
            onTap: () => _open(_AccountKeywordsPage(store: _store)),
          ),
          wordTile(WordListKind.companyUser),
        ],
      ),
      _HubGroup(
        title: 'شاشة الفقاعات',
        icon: Icons.bubble_chart_rounded,
        tiles: [
          _HubTile(
            icon: Icons.palette_rounded,
            color: _kPink,
            title: 'المظهر والسلوك',
            subtitle: 'حجم الخط، الألوان، طريقة العرض والتنبيهات',
            searchText:
                'مظهر تصميم الوان لون خط حجم مضغوط تكرار دليل مرسل ترتيب تمديد',
            onTap: () => _open(_BubbleAppearancePage(store: _store)),
          ),
          _HubTile(
            icon: Icons.touch_app_rounded,
            color: _kCyan,
            title: 'الأزرار السريعة',
            subtitle: 'أزرار داخل الفقاعة: أصفار، اسم جاهز، عملة…',
            count: actions.length,
            searchText: 'ازرار زر سريع اصفار',
            contents: actions.map((a) => a.label).toList(),
            onTap: () => _open(_QuickActionsPage(store: _store)),
          ),
          wordTile(WordListKind.readyName),
        ],
      ),
    ];
  }

  List<_HubGroup> _filter(List<_HubGroup> groups) {
    final q = _norm(_query.trim());
    if (q.isEmpty) return groups;
    final out = <_HubGroup>[];
    for (final g in groups) {
      final tiles = <_HubTile>[];
      for (final t in g.tiles) {
        if (_norm('${t.title} ${t.searchText} ${g.title}').contains(q)) {
          tiles.add(t);
          continue;
        }
        final hit = t.contents.firstWhere(
          (c) => _norm(c).contains(q),
          orElse: () => '',
        );
        if (hit.isNotEmpty) tiles.add(t.withMatch('يحتوي: «$hit»'));
      }
      if (tiles.isNotEmpty) {
        out.add(_HubGroup(title: g.title, icon: g.icon, tiles: tiles));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop ?? false;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        // عند فتح الإعدادات من شاشة أخرى: نحفظ فورًا قبل أن تعيد الشاشة
        // السابقة قراءة الإعدادات.
        if (didPop) _store.flush();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: _pageBg(context),
          body: SafeArea(
            bottom: false,
            child: ListenableBuilder(
              listenable: _listenable,
              builder: (context, _) {
                final groups = _filter(_buildGroups());
                return ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(16, canPop ? 4 : 14, 16, 130),
                  children: [
                    _HubHeader(saving: _store.isSaving, showBack: canPop),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _searchCtrl,
                      textInputAction: TextInputAction.search,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: _fieldDecoration(
                        context,
                        hint: 'ابحث عن إعداد أو كلمة…',
                        icon: Icons.search_rounded,
                        suffix: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'مسح',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _query = '');
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (groups.isEmpty)
                      _EmptyHint(
                        icon: Icons.search_off_rounded,
                        text:
                            'لا يوجد إعداد أو كلمة مطابقة لـ «${_query.trim()}»',
                      )
                    else
                      for (final g in groups) ...[
                        _GroupLabel(title: g.title, icon: g.icon),
                        _GroupCard(tiles: g.tiles),
                        const SizedBox(height: 22),
                      ],
                    const _AutoSaveFooter(),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// الحالة المشتركة + الحفظ التلقائي
// =============================================================

class _SettingsStore extends ChangeNotifier {
  _SettingsStore()
    : settings = _copyOf(DatabaseService.getSettings() ?? _defaults()) {
    _sortAll();
  }

  /// نسخة قابلة للتعديل من الإعدادات (تُحفظ تلقائيًا بعد كل تعديل)
  Settings settings;

  Timer? _saveTimer;
  bool _writing = false;
  bool _disposed = false;
  Listenable? _boxListenable;

  bool get isSaving => _writing || (_saveTimer?.isActive ?? false);

  static Settings _defaults() => Settings(
    nameKeywords: ['المستلم', 'الأسم', 'المستفيد', 'الاسم', 'إلى', 'ل', 'لـ'],
    amountKeywords: ['المبلغ', 'قيمة', 'amount', r'$'],
    currencyMap: {r'$': 'دولار'},
    ignoredWords: [],
    lineIgnoredWords: [],
    cancelKeywords: ['الغاء'],
    editKeywords: ['تعديل'],
    amountWordValues: {},
    bubbleReadyNames: [],
    bubbleQuickActions: [
      BubbleQuickActionConfig(
        id: 1,
        label: '00',
        iconKey: 'zeros',
        actionType: 'appendZeros',
        value: '2',
      ),
      BubbleQuickActionConfig(
        id: 2,
        label: 'اسم جاهز',
        iconKey: 'person',
        actionType: 'setName',
      ),
    ],
  );

  static Settings _copyOf(Settings s) => Settings(
    nameKeywords: List<String>.from(s.nameKeywords),
    amountKeywords: List<String>.from(s.amountKeywords),
    currencyMap: Map<String, String>.from(s.currencyMap),
    ignoredWords: List<String>.from(s.ignoredWords),
    lineIgnoredWords: List<String>.from(s.lineIgnoredWords),
    cancelKeywords: List<String>.from(s.cancelKeywords),
    editKeywords: List<String>.from(s.editKeywords),
    amountWordValues: Map<String, double>.from(s.amountWordValues),
    bubbleReadyNames: List<String>.from(s.bubbleReadyNames),
    companyUserNames: List<String>.from(s.companyUserNames),
    bubbleQuickActions: s.bubbleQuickActions
        .map(
          (a) => BubbleQuickActionConfig(
            id: a.id,
            label: a.label,
            iconKey: a.iconKey,
            actionType: a.actionType,
            value: a.value,
            iconAbove: a.iconAbove,
          ),
        )
        .toList(),
    forbiddenWords: List<String>.from(s.forbiddenWords),
    forbiddenPhrases: List<String>.from(s.forbiddenPhrases),
    bubbleUiPrefs: Map<String, dynamic>.from(s.bubbleUiPrefs),
  );

  void attach() {
    final l = DatabaseService.settingsBox.listenable();
    l.addListener(_onStoredChanged);
    _boxListenable = l;
  }

  void _onStoredChanged() {
    if (_disposed) return;
    final stored = DatabaseService.getSettings();
    if (stored != null && !identical(stored, settings) && !isSaving) {
      // تغيّرت الإعدادات من مكان آخر (استعادة نسخة احتياطية أو إضافة كلمة من
      // شاشة الفقاعات): نعيد تحميلها حتى لا نكتب فوقها بنسخة قديمة.
      settings = _copyOf(stored);
      _sortAll();
    }
    notifyListeners();
  }

  /// يُستدعى بعد كل تعديل: يحدّث الواجهة ويجدول الحفظ.
  void changed() {
    if (_disposed) {
      unawaited(DatabaseService.saveSettings(settings));
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _write);
    notifyListeners();
  }

  Future<void> _write() async {
    _saveTimer = null;
    if (_disposed) return;
    _writing = true;
    notifyListeners();
    try {
      await DatabaseService.saveSettings(settings);
    } catch (e) {
      debugPrint('Settings save failed: $e');
    } finally {
      _writing = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// حفظ فوري لأي تعديل ما زال بانتظار الحفظ.
  void flush() {
    final t = _saveTimer;
    if (t == null || !t.isActive) return;
    t.cancel();
    _saveTimer = null;
    unawaited(DatabaseService.saveSettings(settings));
  }

  @override
  void dispose() {
    flush();
    _boxListenable?.removeListener(_onStoredChanged);
    _disposed = true;
    super.dispose();
  }

  // ---------------- القوائم ----------------

  static bool _same(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  void _sortAll() {
    for (final k in WordListKind.values) {
      SettingsWords.listOf(settings, k).sort(_ci);
    }
  }

  List<String> listOf(WordListKind k) => SettingsWords.listOf(settings, k);

  /// يضيف عناصر جديدة (بدون تكرار) ويعيد عدد ما أُضيف فعلًا.
  int addWords(WordListKind k, Iterable<String> values) {
    final list = listOf(k);
    var added = 0;
    for (final raw in values) {
      final v = raw.trim();
      if (v.isEmpty || list.any((e) => _same(e, v))) continue;
      list.add(v);
      added++;
    }
    if (added > 0) {
      list.sort(_ci);
      changed();
    }
    return added;
  }

  void removeWord(WordListKind k, String word) {
    if (listOf(k).remove(word)) changed();
  }

  /// يعدّل عنصرًا. يعيد false إذا كان الاسم الجديد موجودًا مسبقًا.
  bool renameWord(WordListKind k, String oldWord, String newWord) {
    final v = newWord.trim();
    final list = listOf(k);
    if (v.isEmpty) return false;
    if (list.any((e) => e != oldWord && _same(e, v))) return false;
    final i = list.indexOf(oldWord);
    if (i < 0) return false;
    list[i] = v;
    list.sort(_ci);
    changed();
    return true;
  }

  void clearWords(WordListKind k) {
    final list = listOf(k);
    if (list.isEmpty) return;
    list.clear();
    changed();
  }

  // ---------------- قيم الكلمات ----------------

  void setWordValue(String word, double value) {
    settings.amountWordValues[word] = value;
    changed();
  }

  void removeWordValue(String word) {
    if (settings.amountWordValues.remove(word) != null) changed();
  }

  // ---------------- العملات ----------------

  /// العملات مجمّعة حسب الاسم المعروض: الاسم ← [الاختصارات...]
  Map<String, List<String>> groupedCurrencies() {
    final m = <String, List<String>>{};
    for (final e in settings.currencyMap.entries) {
      (m[e.value.trim()] ??= []).add(e.key);
    }
    for (final list in m.values) {
      list.sort(_ci);
    }
    return Map.fromEntries(
      m.entries.toList()..sort((a, b) => _ci(a.key, b.key)),
    );
  }

  List<String> currencyNames() =>
      settings.currencyMap.values
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort(_ci);

  String? currencyOfAlias(String alias) {
    for (final e in settings.currencyMap.entries) {
      if (_same(e.key, alias)) return e.value.trim();
    }
    return null;
  }

  /// يضيف اختصارًا لعملة (أو ينشئ عملة جديدة). يعيد رسالة خطأ أو null.
  String? addCurrencyAlias(String alias, String displayName) {
    final a = alias.trim();
    final d = displayName.trim();
    if (a.isEmpty || d.isEmpty) return 'أدخل الاختصار واسم العملة';
    final owner = currencyOfAlias(a);
    if (owner != null) return '«$a» موجود مسبقًا ضمن «$owner»';
    settings.currencyMap[a] = d;
    changed();
    return null;
  }

  void removeCurrencyAlias(String alias) {
    if (settings.currencyMap.remove(alias) != null) changed();
  }

  void renameCurrency(String oldName, String newName) {
    final v = newName.trim();
    if (v.isEmpty || v == oldName) return;
    final keys = settings.currencyMap.entries
        .where((e) => e.value.trim() == oldName)
        .map((e) => e.key)
        .toList();
    for (final k in keys) {
      settings.currencyMap[k] = v;
    }
    changed();
  }

  /// يحذف العملة كاملة ويعيد اختصاراتها المحذوفة (للتراجع).
  Map<String, String> deleteCurrency(String name) {
    final removed = <String, String>{};
    settings.currencyMap.removeWhere((k, v) {
      if (v.trim() != name) return false;
      removed[k] = v;
      return true;
    });
    if (removed.isNotEmpty) changed();
    return removed;
  }

  void restoreCurrencyAliases(Map<String, String> entries) {
    if (entries.isEmpty) return;
    settings.currencyMap.addAll(entries);
    changed();
  }

  /// يضيف مجموعة عملات شائعة بعدة اختصارات. يعيد عدد الاختصارات المضافة.
  int addCommonCurrencies() {
    const common = <String, String>{
      'QAR': 'ريال قطري',
      '﷼': 'ريال قطري',
      'ريال': 'ريال قطري',
      'ريال قطري': 'ريال قطري',
      r'$': 'دولار',
      'USD': 'دولار',
      'Dollar': 'دولار',
      'دولار': 'دولار',
      'EUR': 'يورو',
      '€': 'يورو',
      'يورو': 'يورو',
      'GBP': 'جنيه',
      '£': 'جنيه',
      'Sterling': 'جنيه',
      'جنيه': 'جنيه',
      'TRY': 'ليرة تركية',
      '₺': 'ليرة تركية',
      'ليرة': 'ليرة تركية',
      'ليرة تركية': 'ليرة تركية',
      'SYP': 'ليرة سورية',
      'ل.س': 'ليرة سورية',
      'ليرة سورية': 'ليرة سورية',
      'EGP': 'جنيه مصري',
      'جنيه مصري': 'جنيه مصري',
    };
    var added = 0;
    common.forEach((alias, name) {
      if (currencyOfAlias(alias) == null) {
        settings.currencyMap[alias] = name;
        added++;
      }
    });
    if (added > 0) changed();
    return added;
  }

  // ---------------- شاشة الفقاعات ----------------

  BubbleUiPrefs get bubblePrefs => BubbleUiPrefs.fromSettings(settings);

  void setBubblePrefs(BubbleUiPrefs p) {
    settings.bubbleUiPrefs = p.toMap();
    changed();
  }

  void addQuickAction(BubbleQuickActionConfig action, {int? at}) {
    final list = settings.bubbleQuickActions;
    if (at != null && at >= 0 && at <= list.length) {
      list.insert(at, action);
    } else {
      list.add(action);
    }
    changed();
  }

  /// يحذف الزر ويعيد موضعه السابق (للتراجع)، أو -1 إن لم يوجد.
  int removeQuickAction(BubbleQuickActionConfig action) {
    final list = settings.bubbleQuickActions;
    final i = list.indexWhere((a) => a.id == action.id);
    if (i >= 0) {
      list.removeAt(i);
      changed();
    }
    return i;
  }
}

// =============================================================
// تعريف قوائم الكلمات
// =============================================================

class _WordSpec {
  final WordListKind kind;
  final String title;

  /// وصف قصير يظهر في الصفحة الرئيسية
  final String subtitle;

  /// شرح كامل يظهر أعلى صفحة القسم
  final String description;
  final String hint;
  final IconData icon;
  final Color color;

  /// كلمات إضافية للبحث
  final String keywords;
  final List<String> presets;

  const _WordSpec({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.hint,
    required this.icon,
    required this.color,
    this.keywords = '',
    this.presets = const [],
  });
}

const List<_WordSpec> _wordSpecs = [
  _WordSpec(
    kind: WordListKind.nameKeyword,
    title: 'كلمات الاسم',
    subtitle: 'كلمات تسبق اسم المستفيد في الرسالة',
    description:
        'الكلمات التي تساعد التطبيق على معرفة اسم المستفيد أو المستلم داخل الرسالة، مثل: المستفيد، الاسم، إلى.',
    hint: 'أضف كلمة، مثل: المستفيد',
    icon: Icons.person_search_rounded,
    color: _kBlue,
    keywords: 'اسم المستفيد المستلم',
  ),
  _WordSpec(
    kind: WordListKind.amountKeyword,
    title: 'كلمات المبلغ',
    subtitle: 'كلمات تدل على قيمة المبلغ',
    description:
        'الكلمات التي يُكتشف بها المبلغ أثناء التحليل، مثل: المبلغ، قيمة، amount.',
    hint: 'أضف كلمة، مثل: المبلغ',
    icon: Icons.payments_rounded,
    color: _kGreen,
    keywords: 'مبلغ قيمه سعر',
    presets: ['المبلغ', 'المبلغ:', 'قيمة', 'السعر', 'السعر:', 'amount', r'$'],
  ),
  _WordSpec(
    kind: WordListKind.cancelKeyword,
    title: 'كلمات الإلغاء',
    subtitle: 'تجعل الرسالة عملية إلغاء',
    description:
        'إذا ظهرت إحدى هذه الكلمات داخل رسالة، تُعامل الفقاعة كعملية إلغاء.',
    hint: 'أضف كلمة، مثل: الغاء',
    icon: Icons.cancel_schedule_send_rounded,
    color: _kPink,
    keywords: 'الغاء ملغي',
  ),
  _WordSpec(
    kind: WordListKind.editKeyword,
    title: 'كلمات التعديل',
    subtitle: 'تجعل الرسالة تعديلًا لحركة موجودة',
    description:
        'إذا ظهرت إحدى هذه الكلمات داخل رسالة، تُعامل الفقاعة كتعديل لحركة موجودة: '
        'يُبحث عن الحركة بالاسم، ثم تختار الحركة وتختار ما تريد تعديله (الاسم أو المبلغ أو العملة).',
    hint: 'أضف كلمة، مثل: تعديل',
    icon: Icons.edit_note_rounded,
    color: _kAmber,
    keywords: 'تعديل تصحيح تغيير',
    presets: ['تعديل', 'تعديل:', 'تصحيح', 'عدل'],
  ),
  _WordSpec(
    kind: WordListKind.forbidden,
    title: 'الكلمات الممنوعة',
    subtitle: 'لا تدخل ضمن الاسم أبدًا',
    description:
        'كلمات لا يمكن أن تكون جزءًا من الاسم: يتوقف عندها تحديد الاسم، وإذا انتهى بها سطر فإن السطر الذي يليه لا يُعتبر اسم المستفيد (مثل: المرسل).',
    hint: 'أضف كلمة، مثل: المرسل',
    icon: Icons.block_rounded,
    color: _kOrange,
    keywords: 'ممنوع حظر المرسل',
  ),
  _WordSpec(
    kind: WordListKind.forbiddenPhrase,
    title: 'الجمل الممنوعة',
    subtitle: 'تنبيه واضح عند ظهورها في الرسالة',
    description:
        'إذا ظهرت جملة من هذه القائمة داخل رسالة يتم تمييزها بوضوح في الفقاعات والتنبيه عليها قبل الحفظ.',
    hint: 'أضف جملة، مثل: لا تسلم',
    icon: Icons.gpp_bad_rounded,
    color: _kRed,
    keywords: 'ممنوع تحذير تنبيه جمله',
  ),
  _WordSpec(
    kind: WordListKind.ignored,
    title: 'الكلمات المهملة',
    subtitle: 'تُتجاهل أثناء التحليل',
    description: 'أي كلمة هنا سيتم تجاهلها أثناء قراءة وتحليل الحركة.',
    hint: 'أضف كلمة لتجاهلها',
    icon: Icons.visibility_off_rounded,
    color: _kAmber,
    keywords: 'تجاهل مهمل',
  ),
  _WordSpec(
    kind: WordListKind.lineIgnored,
    title: 'تجاهل السطر كاملًا',
    subtitle: 'السطر الذي يحتوي الكلمة لا يُقرأ',
    description:
        'إذا ظهرت كلمة من هذه القائمة في سطر، يتم تجاهل السطر كاملًا أثناء التحليل.',
    hint: 'أضف كلمة تُسقط السطر',
    icon: Icons.playlist_remove_rounded,
    color: _kRose,
    keywords: 'تجاهل سطر',
  ),
  _WordSpec(
    kind: WordListKind.readyName,
    title: 'الأسماء الجاهزة',
    subtitle: 'أسماء تختارها بسرعة من أزرار الفقاعة',
    description:
        'أسماء محفوظة يمكن اعتمادها من الأزرار السريعة داخل الفقاعة بدل كتابتها كل مرة.',
    hint: 'أضف اسمًا جاهزًا',
    icon: Icons.person_pin_circle_rounded,
    color: _kSlate,
    keywords: 'اسماء جاهزه',
  ),
  _WordSpec(
    kind: WordListKind.companyUser,
    title: 'مستخدمو الشركة',
    subtitle: 'رسائلهم تُسجّل كحركات مرسلة',
    description:
        'في شاشة الفقاعات لحساب الشركة: إذا كان مرسل الرسالة موجودًا هنا تُسجّل الحركة «مرسلة»، وإلا تُسجّل حركة «استقبال». ويمكن تعديل النوع يدويًا قبل الحفظ.',
    hint: 'أضف اسم المستخدم كما يظهر في الرسائل',
    icon: Icons.groups_rounded,
    color: _kViolet,
    keywords: 'شركه مستخدم مرسل استقبال',
  ),
];

_WordSpec _specOf(WordListKind kind) =>
    _wordSpecs.firstWhere((s) => s.kind == kind);

// =============================================================
// صفحة قائمة كلمات (تُستخدم لكل القوائم)
// =============================================================

class _WordListPage extends StatefulWidget {
  final _SettingsStore store;
  final _WordSpec spec;

  const _WordListPage({required this.store, required this.spec});

  @override
  State<_WordListPage> createState() => _WordListPageState();
}

class _WordListPageState extends State<_WordListPage> {
  final _ctrl = TextEditingController();
  String _text = '';

  _SettingsStore get _store => widget.store;
  _WordSpec get _spec => widget.spec;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<String> _entries(String raw) =>
      raw.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  void _add() {
    final parts = _entries(_ctrl.text);
    if (parts.isEmpty) return;
    final added = _store.addWords(_spec.kind, parts);
    if (added == 0) {
      _snack(
        context,
        parts.length == 1
            ? '«${parts.first}» موجودة مسبقًا'
            : 'كل العناصر موجودة مسبقًا',
      );
      return;
    }
    _ctrl.clear();
    setState(() => _text = '');
    if (parts.length > 1) _snack(context, 'أُضيف $added من ${parts.length}');
  }

  void _remove(String word) {
    _store.removeWord(_spec.kind, word);
    _snack(
      context,
      'حُذفت «$word»',
      onUndo: () => _store.addWords(_spec.kind, [word]),
    );
  }

  Future<void> _edit(String word) async {
    final value = await _promptText(
      context,
      title: 'تعديل',
      initial: word,
      hint: _spec.hint,
      icon: _spec.icon,
    );
    if (value == null || value == word || !mounted) return;
    if (!_store.renameWord(_spec.kind, word, value)) {
      _snack(context, '«$value» موجودة مسبقًا');
    }
  }

  void _addPresets() {
    final added = _store.addWords(_spec.kind, _spec.presets);
    _snack(
      context,
      added == 0 ? 'الكلمات الشائعة موجودة كلها' : 'أُضيفت $added كلمة شائعة',
    );
  }

  Future<void> _copyAll(List<String> list) async {
    await Clipboard.setData(ClipboardData(text: list.join('\n')));
    if (!mounted) return;
    _snack(context, 'نُسخت ${list.length} عنصر');
  }

  Future<void> _clearAll(List<String> list) async {
    final ok = await _confirm(
      context,
      title: 'حذف الكل',
      message: 'حذف كل عناصر «${_spec.title}» (${list.length})؟',
      confirmLabel: 'حذف الكل',
      danger: true,
    );
    if (!ok || !mounted) return;
    final backup = List<String>.from(list);
    _store.clearWords(_spec.kind);
    _snack(
      context,
      'حُذفت كل العناصر',
      onUndo: () => _store.addWords(_spec.kind, backup),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SubPageScaffold(
      store: _store,
      title: _spec.title,
      icon: _spec.icon,
      color: _spec.color,
      description: _spec.description,
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        final list = _store.listOf(_spec.kind);
        final typed = _text.trim();
        final q = _norm(typed);
        final visible = q.isEmpty
            ? list
            : list.where((e) => _norm(e).contains(q)).toList();
        final exists =
            typed.isNotEmpty &&
            !typed.contains('\n') &&
            list.any((e) => _SettingsStore._same(e, typed));

        return [
          TextField(
            controller: _ctrl,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.done,
            onChanged: (v) => setState(() => _text = v),
            onSubmitted: (_) => _add(),
            decoration: _fieldDecoration(
              context,
              hint: _spec.hint,
              icon: Icons.edit_note_rounded,
              helper: exists ? 'موجودة مسبقًا في القائمة' : null,
              suffix: Padding(
                padding: const EdgeInsets.all(5),
                child: IconButton.filled(
                  tooltip: 'إضافة',
                  onPressed: typed.isEmpty || exists ? null : _add,
                  icon: const Icon(Icons.add_rounded),
                ),
              ),
            ),
          ),
          if (_spec.presets.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _addPresets,
                icon: const Icon(Icons.playlist_add_rounded),
                label: const Text('إضافة الكلمات الشائعة'),
              ),
            ),
          ],
          const SizedBox(height: 18),
          _SectionTitle(
            text: q.isEmpty
                ? 'العناصر (${list.length})'
                : 'المطابقة (${visible.length} من ${list.length})',
            trailing: list.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SmallIconButton(
                        icon: Icons.copy_rounded,
                        tooltip: 'نسخ القائمة',
                        onPressed: () => _copyAll(list),
                      ),
                      _SmallIconButton(
                        icon: Icons.delete_sweep_rounded,
                        tooltip: 'حذف الكل',
                        color: cs.error,
                        onPressed: () => _clearAll(list),
                      ),
                    ],
                  ),
          ),
          if (list.isEmpty)
            _EmptyHint(
              icon: _spec.icon,
              color: _spec.color,
              text: 'القائمة فارغة — اكتب في الحقل بالأعلى ثم اضغط +',
            )
          else if (visible.isEmpty)
            _EmptyHint(
              icon: Icons.search_off_rounded,
              text: 'لا توجد عناصر مطابقة — اضغط + لإضافة «$typed»',
            )
          else
            _Card(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final w in visible)
                    _WordChip(
                      text: w,
                      color: _spec.color,
                      onTap: () => _edit(w),
                      onDelete: () => _remove(w),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          const _TipText(
            'اضغط على العنصر لتعديله و × لحذفه. يمكنك لصق عدة عناصر دفعة واحدة (كل عنصر في سطر).',
          ),
        ];
      },
    );
  }
}

// =============================================================
// صفحة قيم الكلمات
// =============================================================

class _WordValuesPage extends StatefulWidget {
  final _SettingsStore store;

  const _WordValuesPage({required this.store});

  @override
  State<_WordValuesPage> createState() => _WordValuesPageState();
}

class _WordValuesPageState extends State<_WordValuesPage> {
  final _wordCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();

  _SettingsStore get _store => widget.store;

  @override
  void dispose() {
    _wordCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  void _add() {
    final word = _wordCtrl.text.trim();
    final value = _parseNumber(_valueCtrl.text);
    if (word.isEmpty || value == null || value <= 0) {
      _snack(context, 'أدخل الكلمة وقيمتها الرقمية بشكل صحيح');
      return;
    }
    final replaced = _store.settings.amountWordValues.containsKey(word);
    _store.setWordValue(word, value);
    _wordCtrl.clear();
    _valueCtrl.clear();
    _snack(
      context,
      replaced ? 'تم تحديث قيمة «$word»' : 'أُضيفت «$word» = ${_fmtNum(value)}',
    );
  }

  Future<void> _edit(String word, double current) async {
    final raw = await _promptText(
      context,
      title: 'قيمة «$word»',
      initial: _fmtNum(current),
      hint: 'القيمة الرقمية',
      icon: Icons.pin_rounded,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    if (raw == null || !mounted) return;
    final value = _parseNumber(raw);
    if (value == null || value <= 0) {
      _snack(context, 'أدخل رقمًا أكبر من صفر');
      return;
    }
    _store.setWordValue(word, value);
  }

  void _remove(String word, double value) {
    _store.removeWordValue(word);
    _snack(
      context,
      'حُذفت «$word»',
      onUndo: () => _store.setWordValue(word, value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SubPageScaffold(
      store: _store,
      title: 'قيم الكلمات',
      icon: Icons.calculate_rounded,
      color: _kIndigo,
      description:
          'اربط أي كلمة بقيمة رقمية ليستخدمها التطبيق أثناء اكتشاف المبلغ. مثال: «ستمئة» = 600.',
      builder: (context) {
        final entries = _store.settings.amountWordValues.entries.toList()
          ..sort((a, b) => _ci(a.key, b.key));
        return [
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _wordCtrl,
                        textInputAction: TextInputAction.next,
                        decoration: _fieldDecoration(
                          context,
                          hint: 'الكلمة، مثل: ستمئة',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _valueCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _add(),
                        decoration: _fieldDecoration(context, hint: 'القيمة'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('إضافة'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _SectionTitle(text: 'القيم المعرّفة (${entries.length})'),
          if (entries.isEmpty)
            const _EmptyHint(
              icon: Icons.calculate_outlined,
              color: _kIndigo,
              text: 'لا توجد قيم بعد.',
            )
          else
            _Card(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) _ListDivider(indent: 16),
                    ListTile(
                      onTap: () => _edit(entries[i].key, entries[i].value),
                      contentPadding: const EdgeInsetsDirectional.only(
                        start: 16,
                        end: 4,
                      ),
                      title: Text(
                        entries[i].key,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ValuePill(
                            text: _fmtNum(entries[i].value),
                            color: _kIndigo,
                          ),
                          _SmallIconButton(
                            icon: Icons.delete_outline_rounded,
                            tooltip: 'حذف',
                            color: Theme.of(context).colorScheme.error,
                            onPressed: () =>
                                _remove(entries[i].key, entries[i].value),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 14),
          const _TipText('اضغط على أي قيمة لتعديلها.'),
        ];
      },
    );
  }
}

// =============================================================
// صفحة العملات
// =============================================================

class _CurrenciesPage extends StatefulWidget {
  final _SettingsStore store;

  const _CurrenciesPage({required this.store});

  @override
  State<_CurrenciesPage> createState() => _CurrenciesPageState();
}

class _CurrenciesPageState extends State<_CurrenciesPage> {
  _SettingsStore get _store => widget.store;

  Future<void> _addCurrency({String? presetName}) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _NewCurrencyDialog(
        names: _store.currencyNames(),
        presetName: presetName,
        ownerOf: _store.currencyOfAlias,
      ),
    );
    if (result == null || !mounted) return;
    final error = _store.addCurrencyAlias(result.$1, result.$2);
    if (error != null) _snack(context, error);
  }

  void _addCommon() {
    final added = _store.addCommonCurrencies();
    _snack(
      context,
      added == 0
          ? 'العملات الشائعة موجودة كلها'
          : 'أُضيف $added اختصار لعملات شائعة',
    );
  }

  Future<void> _rename(String name) async {
    final v = await _promptText(
      context,
      title: 'إعادة تسمية العملة',
      initial: name,
      hint: 'الاسم المعروض الجديد',
    );
    if (v == null || !mounted) return;
    _store.renameCurrency(name, v);
  }

  Future<void> _delete(String name, int aliases) async {
    final ok = await _confirm(
      context,
      title: 'حذف العملة',
      message: 'سيتم حذف «$name» مع اختصاراتها ($aliases). هل تريد المتابعة؟',
      confirmLabel: 'حذف',
      danger: true,
    );
    if (!ok || !mounted) return;
    final removed = _store.deleteCurrency(name);
    _snack(
      context,
      'حُذفت عملة «$name»',
      onUndo: () => _store.restoreCurrencyAliases(removed),
    );
  }

  void _removeAlias(String alias, String name) {
    _store.removeCurrencyAlias(alias);
    _snack(
      context,
      'حُذف «$alias» من «$name»',
      onUndo: () => _store.addCurrencyAlias(alias, name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SubPageScaffold(
      store: _store,
      title: 'العملات والاختصارات',
      icon: Icons.currency_exchange_rounded,
      color: _kPurple,
      description:
          'كل عملة تضم عدة اختصارات أو أسماء (مثل: \$ و USD و دولار) تُعامل كلها كعملة واحدة أثناء التحليل.',
      actions: [
        IconButton(
          tooltip: 'إضافة العملات الشائعة',
          onPressed: _addCommon,
          icon: const Icon(Icons.playlist_add_rounded),
        ),
      ],
      builder: (context) {
        final groups = _store.groupedCurrencies();
        return [
          FilledButton.tonalIcon(
            onPressed: () => _addCurrency(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة عملة أو اختصار'),
          ),
          const SizedBox(height: 18),
          _SectionTitle(text: 'العملات (${groups.length})'),
          if (groups.isEmpty)
            const _EmptyHint(
              icon: Icons.currency_exchange_rounded,
              color: _kPurple,
              text:
                  'لا توجد عملات بعد — أضف عملة، أو اضغط زر العملات الشائعة في الأعلى.',
            )
          else
            for (final e in groups.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _CurrencyCard(
                  name: e.key,
                  aliases: e.value,
                  onAddAlias: () => _addCurrency(presetName: e.key),
                  onRemoveAlias: (a) => _removeAlias(a, e.key),
                  onRename: () => _rename(e.key),
                  onDelete: () => _delete(e.key, e.value.length),
                ),
              ),
          const SizedBox(height: 10),
          _SectionTitle(text: 'أدوات'),
          _Card(
            padding: EdgeInsets.zero,
            child: _HubTileView(
              tile: _HubTile(
                icon: Icons.percent_rounded,
                color: _kTeal,
                title: 'تقسيم الحركات حسب العملة',
                subtitle: 'قسمة مبالغ الحركات المحفوظة لعملة معيّنة',
                onTap: () => _openSplitTool(context, _store),
              ),
            ),
          ),
        ];
      },
    );
  }
}

class _CurrencyCard extends StatelessWidget {
  final String name;
  final List<String> aliases;
  final VoidCallback onAddAlias;
  final ValueChanged<String> onRemoveAlias;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _CurrencyCard({
    required this.name,
    required this.aliases,
    required this.onAddAlias,
    required this.onRemoveAlias,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Card(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 6, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _IconBadge(
                icon: Icons.payments_rounded,
                color: _kPurple,
                size: 38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${aliases.length} اختصار / اسم',
                      style: TextStyle(color: _muted(context), fontSize: 12),
                    ),
                  ],
                ),
              ),
              _SmallIconButton(
                icon: Icons.edit_rounded,
                tooltip: 'إعادة تسمية',
                onPressed: onRename,
              ),
              _SmallIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: 'حذف العملة',
                color: cs.error,
                onPressed: onDelete,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in aliases)
                  _WordChip(
                    text: a,
                    color: _kPurple,
                    onDelete: () => onRemoveAlias(a),
                  ),
                _AddChip(label: 'اختصار', onPressed: onAddAlias),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NewCurrencyDialog extends StatefulWidget {
  final List<String> names;
  final String? presetName;
  final String? Function(String alias) ownerOf;

  const _NewCurrencyDialog({
    required this.names,
    required this.ownerOf,
    this.presetName,
  });

  @override
  State<_NewCurrencyDialog> createState() => _NewCurrencyDialogState();
}

class _NewCurrencyDialogState extends State<_NewCurrencyDialog> {
  final _aliasCtrl = TextEditingController();
  late final _nameCtrl = TextEditingController(text: widget.presetName ?? '');
  String? _error;

  @override
  void dispose() {
    _aliasCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final alias = _aliasCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    if (alias.isEmpty || name.isEmpty) {
      setState(() => _error = 'أدخل الاختصار واسم العملة');
      return;
    }
    final owner = widget.ownerOf(alias);
    if (owner != null) {
      setState(() => _error = '«$alias» موجود مسبقًا ضمن «$owner»');
      return;
    }
    Navigator.pop(context, (alias, name));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final forExisting = widget.presetName != null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(
          forExisting ? 'اختصار جديد لـ «${widget.presetName}»' : 'إضافة عملة',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _aliasCtrl,
                autofocus: true,
                textInputAction: forExisting
                    ? TextInputAction.done
                    : TextInputAction.next,
                onSubmitted: forExisting ? (_) => _submit() : null,
                decoration: _fieldDecoration(
                  context,
                  hint: 'الاختصار أو الاسم، مثل: QAR أو ﷼',
                  icon: Icons.alternate_email_rounded,
                ),
              ),
              if (!forExisting) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _nameCtrl,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                  decoration: _fieldDecoration(
                    context,
                    hint: 'اسم العملة المعروض، مثل: ريال قطري',
                    icon: Icons.label_important_outline_rounded,
                  ),
                ),
                if (widget.names.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'أو أضفه إلى عملة موجودة:',
                    style: TextStyle(color: _muted(context), fontSize: 12.5),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final n in widget.names)
                        ChoiceChip(
                          label: Text(n),
                          selected: _nameCtrl.text.trim() == n,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() => _nameCtrl.text = n),
                        ),
                    ],
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(
                    color: cs.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(onPressed: _submit, child: const Text('إضافة')),
        ],
      ),
    );
  }
}

// =============================================================
// أداة تقسيم الحركات حسب العملة
// =============================================================

Future<void> _openSplitTool(BuildContext context, _SettingsStore store) async {
  final currencies = store.currencyNames();
  if (currencies.isEmpty) {
    _snack(context, 'أضف عملة واحدة على الأقل أولًا');
    return;
  }
  final count = await showDialog<int>(
    context: context,
    builder: (_) => _CurrencySplitDialog(currencies: currencies),
  );
  if (count == null || !context.mounted) return;
  _snack(context, 'تم تقسيم $count حركة');
}

class _CurrencySplitDialog extends StatefulWidget {
  final List<String> currencies;

  const _CurrencySplitDialog({required this.currencies});

  @override
  State<_CurrencySplitDialog> createState() => _CurrencySplitDialogState();
}

class _CurrencySplitDialogState extends State<_CurrencySplitDialog> {
  late String _selected = widget.currencies.first;
  final _divisorCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _divisorCtrl.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final divisor = _parseNumber(_divisorCtrl.text);
    if (divisor == null || divisor <= 0 || divisor == 1) {
      setState(() => _error = 'أدخل رقمًا أكبر من صفر ومختلفًا عن 1');
      return;
    }
    final matching = DatabaseService.transactionsBox.values
        .where(
          (tx) =>
              tx.currency == _selected ||
              (tx.secondAmount != null && tx.secondCurrency == _selected),
        )
        .toList();
    if (matching.isEmpty) {
      setState(() => _error = 'لا توجد حركات محفوظة بعملة $_selected');
      return;
    }
    final ok = await _confirm(
      context,
      title: 'تأكيد القسمة',
      message:
          'سيتم تقسيم مبالغ ${matching.length} حركة محفوظة بعملة $_selected على ${_fmtNum(divisor)}. لا يمكن التراجع تلقائيًا.',
      confirmLabel: 'تقسيم',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final source = 'أداة تقسيم المبالغ (÷ ${_fmtNum(divisor)})';
    for (final tx in matching) {
      TxHistoryService.annotate([tx.id], source);
      if (tx.currency == _selected) tx.amount /= divisor;
      if (tx.secondAmount != null && tx.secondCurrency == _selected) {
        tx.secondAmount = tx.secondAmount! / divisor;
      }
      await tx.save();
    }
    if (!mounted) return;
    Navigator.pop(context, matching.length);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text(
          'تقسيم الحركات المسجّلة',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'تُطبَّق مرة واحدة على الحركات المحفوظة فقط، ولا تؤثر على الحركات الجديدة.',
                style: TextStyle(color: _muted(context), height: 1.5),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                value: _selected,
                items: [
                  for (final c in widget.currencies)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _selected = v ?? _selected),
                decoration: _fieldDecoration(
                  context,
                  label: 'العملة',
                  icon: Icons.payments_rounded,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _divisorCtrl,
                enabled: !_busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: _fieldDecoration(
                  context,
                  label: 'المقسوم عليه',
                  hint: 'مثال: 100',
                  icon: Icons.percent_rounded,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(
                    color: cs.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 14),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: _busy ? null : _apply,
            child: const Text('تقسيم الحركات'),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// صفحة كلمات الحسابات
// =============================================================

class _AccountKeywordsPage extends StatefulWidget {
  final _SettingsStore store;

  const _AccountKeywordsPage({required this.store});

  @override
  State<_AccountKeywordsPage> createState() => _AccountKeywordsPageState();
}

class _AccountKeywordsPageState extends State<_AccountKeywordsPage> {
  late final Listenable _accounts = DatabaseService.accountsBox.listenable();
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _addKeyword(Account account) async {
    final value = await _promptText(
      context,
      title: 'كلمة جديدة لـ «${account.name}»',
      hint: 'كلمة أو اسم مختصر يدل على الحساب',
      icon: Icons.add_link_rounded,
      confirmLabel: 'إضافة',
    );
    if (value == null || !mounted) return;
    if (account.keywords.any((e) => _SettingsStore._same(e, value))) {
      _snack(context, 'الكلمة موجودة لهذا الحساب مسبقًا');
      return;
    }
    account.keywords = List<String>.from(account.keywords)
      ..add(value)
      ..sort(_ci);
    await account.save();
  }

  Future<void> _removeKeyword(Account account, String word) async {
    account.keywords = List<String>.from(account.keywords)..remove(word);
    await account.save();
    if (!mounted) return;
    _snack(
      context,
      'حُذفت «$word» من «${account.name}»',
      onUndo: () async {
        if (!account.isInBox || account.keywords.contains(word)) return;
        account.keywords = List<String>.from(account.keywords)
          ..add(word)
          ..sort(_ci);
        await account.save();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SubPageScaffold(
      store: widget.store,
      title: 'كلمات الحسابات',
      icon: Icons.manage_search_rounded,
      color: _kTeal,
      description:
          'كلمات إضافية لكل حساب تساعد التطبيق على اختيار الحساب تلقائيًا عند لصق نص أو استيراد ملف (مثل اسم مختصر أو اسم الشخص المسؤول).',
      extraListenable: _accounts,
      builder: (context) {
        final accounts = DatabaseService.accountsBox.values.toList()
          ..sort((a, b) => _ci(a.name, b.name));
        final q = _norm(_query.trim());
        final visible = q.isEmpty
            ? accounts
            : accounts
                  .where(
                    (a) =>
                        _norm(a.name).contains(q) ||
                        a.keywords.any((k) => _norm(k).contains(q)),
                  )
                  .toList();
        return [
          if (accounts.length > 4) ...[
            TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              onChanged: (v) => setState(() => _query = v),
              decoration: _fieldDecoration(
                context,
                hint: 'ابحث عن حساب أو كلمة…',
                icon: Icons.search_rounded,
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (accounts.isEmpty)
            const _EmptyHint(
              icon: Icons.account_balance_wallet_outlined,
              color: _kTeal,
              text: 'لا توجد حسابات بعد — أضف حسابًا من الصفحة الرئيسية أولًا.',
            )
          else if (visible.isEmpty)
            const _EmptyHint(
              icon: Icons.search_off_rounded,
              text: 'لا يوجد حساب مطابق',
            )
          else
            for (final a in visible)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _AccountKeywordsCard(
                  account: a,
                  onAdd: () => _addKeyword(a),
                  onRemove: (w) => _removeKeyword(a, w),
                ),
              ),
        ];
      },
    );
  }
}

class _AccountKeywordsCard extends StatelessWidget {
  final Account account;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  const _AccountKeywordsCard({
    required this.account,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isCompany = account.type.isCompany;
    final color = isCompany ? _kPurple : _kTeal;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _IconBadge(
                icon: isCompany
                    ? Icons.business_rounded
                    : Icons.account_balance_wallet_rounded,
                color: color,
                size: 38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${account.type.label} • ${account.keywords.length} كلمة',
                      style: TextStyle(color: _muted(context), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final w in account.keywords)
                _WordChip(text: w, color: color, onDelete: () => onRemove(w)),
              _AddChip(label: 'كلمة', onPressed: onAdd),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================
// صفحة مظهر الفقاعات وسلوكها
// =============================================================

class _BubbleAppearancePage extends StatelessWidget {
  final _SettingsStore store;

  const _BubbleAppearancePage({required this.store});

  void _reset(BuildContext context) {
    final previous = store.bubblePrefs;
    store.setBubblePrefs(const BubbleUiPrefs());
    _snack(
      context,
      'تمت استعادة التصميم الافتراضي',
      onUndo: () => store.setBubblePrefs(previous),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SubPageScaffold(
      store: store,
      title: 'مظهر الفقاعات وسلوكها',
      icon: Icons.palette_rounded,
      color: _kPink,
      description:
          'غيّر شكل شاشة تحليل الرسائل (الفقاعات): حجم الخط، الألوان، ما يظهر في الشاشة وطريقة الترتيب والتنبيهات. تظهر التغييرات في المعاينة مباشرة.',
      actions: [
        IconButton(
          tooltip: 'استعادة الافتراضي',
          onPressed: () => _reset(context),
          icon: const Icon(Icons.restart_alt_rounded),
        ),
      ],
      builder: (context) {
        final p = store.bubblePrefs;
        void set(BubbleUiPrefs v) => store.setBubblePrefs(v);

        return [
          const _SectionTitle(text: 'معاينة'),
          _Card(child: _BubblePreview(prefs: p)),
          const SizedBox(height: 20),
          const _SectionTitle(text: 'الخط والعرض'),
          _Card(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SliderRow(
                  icon: Icons.format_size_rounded,
                  title: 'حجم خط الكلمات',
                  valueText: p.tokenFontSize.toStringAsFixed(0),
                  value: p.tokenFontSize,
                  min: BubbleUiPrefs.minFontSize,
                  max: BubbleUiPrefs.maxFontSize,
                  divisions:
                      (BubbleUiPrefs.maxFontSize - BubbleUiPrefs.minFontSize)
                          .round(),
                  onChanged: (v) => set(p.copyWith(tokenFontSize: v)),
                ),
                const _ListDivider(),
                _SwitchRow(
                  icon: Icons.density_small_rounded,
                  title: 'عرض مضغوط',
                  subtitle: 'فقاعات أصغر ومسافات أقل لعرض رسائل أكثر',
                  value: p.compact,
                  onChanged: (v) => set(p.copyWith(compact: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle(text: 'ما يظهر في الشاشة'),
          _Card(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SwitchRow(
                  icon: Icons.person_outline_rounded,
                  title: 'اسم المرسل والوقت',
                  subtitle: 'يظهر أعلى كل فقاعة',
                  value: p.showSenderHeader,
                  onChanged: (v) => set(p.copyWith(showSenderHeader: v)),
                ),
                const _ListDivider(),
                _SwitchRow(
                  icon: Icons.legend_toggle_rounded,
                  title: 'دليل الألوان',
                  subtitle: 'شرح مختصر لألوان الفقاعات أعلى الشاشة',
                  value: p.showLegend,
                  onChanged: (v) => set(p.copyWith(showLegend: v)),
                ),
                const _ListDivider(),
                _SwitchRow(
                  icon: Icons.touch_app_outlined,
                  title: 'الأزرار السريعة',
                  subtitle: 'الأزرار المعرّفة في صفحة «الأزرار السريعة»',
                  value: p.showQuickActions,
                  onChanged: (v) => set(p.copyWith(showQuickActions: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle(text: 'الترتيب والسلوك'),
          _Card(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SwitchRow(
                  icon: Icons.sort_rounded,
                  title: 'غير المكتمل أولًا',
                  subtitle:
                      'ترتيب الفقاعات الناقصة قبل الجاهزة (وإلا الترتيب الزمني)',
                  value: p.incompleteFirst,
                  onChanged: (v) => set(p.copyWith(incompleteFirst: v)),
                ),
                const _ListDivider(),
                _SwitchRow(
                  icon: Icons.keyboard_double_arrow_left_rounded,
                  title: 'تمديد الاسم تلقائيًا',
                  subtitle:
                      'عند الضغط على كلمة يمتد الاسم حتى نهاية السطر أو أول كلمة ممنوعة/رقم/عملة',
                  value: p.autoExtendName,
                  onChanged: (v) => set(p.copyWith(autoExtendName: v)),
                ),
                const _ListDivider(),
                _SwitchRow(
                  icon: Icons.gpp_maybe_rounded,
                  title: 'تأكيد قبل حفظ رسالة فيها جملة ممنوعة',
                  subtitle: 'يظهر تنبيه يعرض الجمل الممنوعة قبل الحفظ',
                  value: p.confirmForbiddenPhrase,
                  onChanged: (v) => set(p.copyWith(confirmForbiddenPhrase: v)),
                ),
                const _ListDivider(),
                _SliderRow(
                  icon: Icons.content_copy_rounded,
                  title: 'فحص التكرار',
                  subtitle:
                      'البحث عن حركة بنفس الاسم والمبلغ والعملة خلال آخر ${p.duplicateDays} يومًا',
                  valueText: '${p.duplicateDays} يوم',
                  value: p.duplicateDays.clamp(1, 90).toDouble(),
                  min: 1,
                  max: 90,
                  divisions: 89,
                  onChanged: (v) => set(p.copyWith(duplicateDays: v.round())),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle(text: 'الألوان'),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ColorRow(
                  label: 'لون الاسم',
                  selected: p.nameColor,
                  onPick: (c) => set(p.copyWith(nameColor: c)),
                ),
                const SizedBox(height: 16),
                _ColorRow(
                  label: 'لون المبلغ',
                  selected: p.amountColor,
                  onPick: (c) => set(p.copyWith(amountColor: c)),
                ),
                const SizedBox(height: 16),
                _ColorRow(
                  label: 'لون العملة',
                  selected: p.currencyColor,
                  onPick: (c) => set(p.copyWith(currencyColor: c)),
                ),
              ],
            ),
          ),
        ];
      },
    );
  }
}

/// معاينة مصغّرة لفقاعة تعكس التفضيلات الحالية.
class _BubblePreview extends StatelessWidget {
  final BubbleUiPrefs prefs;

  const _BubblePreview({required this.prefs});

  @override
  Widget build(BuildContext context) {
    final p = prefs;
    final cs = Theme.of(context).colorScheme;
    final dark = _isDark(context);

    Widget chip(String text, Color? color, {bool strike = false}) {
      final fg = color == null
          ? cs.onSurface.withValues(alpha: .78)
          : Color.lerp(
              color,
              dark ? Colors.white : Colors.black,
              dark ? .28 : .22,
            )!;
      return Container(
        padding: p.compact
            ? const EdgeInsets.symmetric(horizontal: 7, vertical: 4)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: (color ?? cs.onSurface).withValues(
            alpha: color == null ? .06 : .14,
          ),
          borderRadius: BorderRadius.circular(p.compact ? 10 : 14),
          border: Border.all(
            color: (color ?? cs.onSurface).withValues(
              alpha: color == null ? .14 : .75,
            ),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: fg,
            fontSize: p.tokenFontSize,
            fontWeight: FontWeight.w700,
            decoration: strike ? TextDecoration.lineThrough : null,
            decorationColor: fg,
          ),
        ),
      );
    }

    Widget legendDot(String label, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 11.5, color: _muted(context))),
      ],
    );

    Widget quickButton(String label, IconData icon) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withValues(alpha: .30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: cs.primary,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (p.showLegend) ...[
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              legendDot('اسم', p.nameColorValue),
              legendDot('مبلغ', p.amountColorValue),
              legendDot('عملة', p.currencyColorValue),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(p.compact ? 10 : 14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.showSenderHeader) ...[
                Row(
                  children: [
                    Icon(
                      Icons.person_rounded,
                      size: 15,
                      color: _muted(context),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'محمد • 10:30',
                      style: TextStyle(
                        fontSize: 12,
                        color: _muted(context),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: p.compact ? 6 : 10),
              ],
              Wrap(
                spacing: p.compact ? 6 : 8,
                runSpacing: p.compact ? 6 : 8,
                children: [
                  chip('المستفيد', null),
                  chip('أحمد', p.nameColorValue),
                  chip('علي', p.nameColorValue),
                  chip('500', p.amountColorValue),
                  chip('دولار', p.currencyColorValue),
                  chip('المرسل', const Color(0xFFD84315), strike: true),
                ],
              ),
              if (p.showQuickActions) ...[
                SizedBox(height: p.compact ? 8 : 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    quickButton('00', Icons.exposure_zero_rounded),
                    quickButton('اسم جاهز', Icons.person_add_alt_1_rounded),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ColorRow extends StatelessWidget {
  final String label;
  final int selected;
  final ValueChanged<int> onPick;

  const _ColorRow({
    required this.label,
    required this.selected,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in BubbleUiPrefs.palette)
              InkWell(
                onTap: () => onPick(c),
                customBorder: const CircleBorder(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == selected ? cs.onSurface : Colors.transparent,
                      width: 2.4,
                    ),
                    boxShadow: c == selected
                        ? [
                            BoxShadow(
                              color: Color(c).withValues(alpha: .45),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                  child: c == selected
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// =============================================================
// صفحة الأزرار السريعة
// =============================================================

const List<String> _actionTypes = [
  'appendZeros',
  'setName',
  'clearStage',
  'setCurrency',
];

const List<String> _actionIconKeys = [
  'zeros',
  'person',
  'clear',
  'currency',
  'flash',
  'check',
];

String _actionTypeTitle(String type) {
  switch (type) {
    case 'appendZeros':
      return 'إضافة أصفار للمبلغ';
    case 'setName':
      return 'اعتماد اسم جاهز';
    case 'clearStage':
      return 'مسح المختار';
    case 'setCurrency':
      return 'تغيير العملة';
    default:
      return 'زر مخصص';
  }
}

String _defaultIconFor(String type) {
  switch (type) {
    case 'appendZeros':
      return 'zeros';
    case 'setName':
      return 'person';
    case 'clearStage':
      return 'clear';
    case 'setCurrency':
      return 'currency';
    default:
      return 'flash';
  }
}

IconData _actionIconData(String key) {
  switch (key) {
    case 'zeros':
      return Icons.exposure_zero_rounded;
    case 'person':
      return Icons.person_add_alt_1_rounded;
    case 'clear':
      return Icons.backspace_rounded;
    case 'currency':
      return Icons.currency_exchange_rounded;
    case 'flash':
      return Icons.bolt_rounded;
    case 'check':
      return Icons.task_alt_rounded;
    default:
      return Icons.tune_rounded;
  }
}

class _QuickActionsPage extends StatefulWidget {
  final _SettingsStore store;

  const _QuickActionsPage({required this.store});

  @override
  State<_QuickActionsPage> createState() => _QuickActionsPageState();
}

class _QuickActionsPageState extends State<_QuickActionsPage> {
  _SettingsStore get _store => widget.store;

  Future<void> _add() async {
    final action = await showModalBottomSheet<BubbleQuickActionConfig>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _QuickActionSheet(currencyNames: _store.currencyNames()),
    );
    if (action == null || !mounted) return;
    _store.addQuickAction(action);
    _snack(context, 'أُضيف زر «${action.label}»');
  }

  void _remove(BubbleQuickActionConfig action) {
    final index = _store.removeQuickAction(action);
    if (index < 0) return;
    _snack(
      context,
      'حُذف زر «${action.label}»',
      onUndo: () => _store.addQuickAction(action, at: index),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SubPageScaffold(
      store: _store,
      title: 'الأزرار السريعة',
      icon: Icons.touch_app_rounded,
      color: _kCyan,
      description:
          'أزرار تظهر داخل كل فقاعة في شاشة التحليل لتنفيذ أوامر سريعة: إضافة أصفار للمبلغ، اعتماد اسم جاهز، مسح المختار أو تغيير العملة.',
      builder: (context) {
        final actions = _store.settings.bubbleQuickActions;
        return [
          FilledButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة زر جديد'),
          ),
          const SizedBox(height: 18),
          _SectionTitle(text: 'الأزرار (${actions.length})'),
          if (actions.isEmpty)
            const _EmptyHint(
              icon: Icons.touch_app_outlined,
              color: _kCyan,
              text: 'لا توجد أزرار بعد.',
            )
          else
            _Card(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const _ListDivider(indent: 70),
                    _QuickActionRow(
                      action: actions[i],
                      onDelete: () => _remove(actions[i]),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 14),
          const _TipText(
            'تظهر هذه الأزرار داخل الفقاعات عند تفعيل «الأزرار السريعة» في صفحة المظهر والسلوك.',
          ),
        ];
      },
    );
  }
}

class _QuickActionRow extends StatelessWidget {
  final BubbleQuickActionConfig action;
  final VoidCallback onDelete;

  const _QuickActionRow({required this.action, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final details = [
      _actionTypeTitle(action.actionType),
      if (action.value.isNotEmpty) action.value,
      if (action.iconAbove) 'الأيقونة فوق',
    ].join(' • ');
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(start: 14, end: 4),
      leading: _IconBadge(
        icon: _actionIconData(action.iconKey),
        color: _kCyan,
        size: 40,
      ),
      title: Text(
        action.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        details,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _muted(context), fontSize: 12.5),
      ),
      trailing: _SmallIconButton(
        icon: Icons.delete_outline_rounded,
        tooltip: 'حذف الزر',
        color: Theme.of(context).colorScheme.error,
        onPressed: onDelete,
      ),
    );
  }
}

class _QuickActionSheet extends StatefulWidget {
  final List<String> currencyNames;

  const _QuickActionSheet({required this.currencyNames});

  @override
  State<_QuickActionSheet> createState() => _QuickActionSheetState();
}

class _QuickActionSheetState extends State<_QuickActionSheet> {
  String _type = _actionTypes.first;
  String _icon = _defaultIconFor(_actionTypes.first);
  bool _iconAbove = false;
  final _labelCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _labelCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  String get _valueHint {
    switch (_type) {
      case 'appendZeros':
        return 'عدد الأصفار (من 1 إلى 6)، مثل: 2';
      case 'setCurrency':
        return 'اسم العملة، مثل: دولار';
      case 'setName':
        return 'اسم محدد، أو اتركه فارغًا لعرض قائمة الأسماء الجاهزة';
      default:
        return '';
    }
  }

  void _submit() {
    final label = _labelCtrl.text.trim();
    var value = _valueCtrl.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'أدخل نص الزر');
      return;
    }
    if (_type == 'appendZeros') {
      value = _asciiDigits(value);
      final n = int.tryParse(value);
      if (n == null || n < 1 || n > 6) {
        setState(() => _error = 'أدخل عدد الأصفار (رقم من 1 إلى 6)');
        return;
      }
    }
    if (_type == 'setCurrency' && value.isEmpty) {
      setState(() => _error = 'أدخل اسم العملة');
      return;
    }
    Navigator.pop(
      context,
      BubbleQuickActionConfig(
        id: DateTime.now().millisecondsSinceEpoch,
        label: label,
        iconKey: _icon,
        actionType: _type,
        value: _type == 'clearStage' ? '' : value,
        iconAbove: _iconAbove,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final needsValue = _type != 'clearStage';

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'زر سريع جديد',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 16),
              const _SectionTitle(text: 'نوع الزر'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in _actionTypes)
                    ChoiceChip(
                      avatar: Icon(
                        _actionIconData(_defaultIconFor(t)),
                        size: 18,
                      ),
                      label: Text(_actionTypeTitle(t)),
                      selected: _type == t,
                      showCheckmark: false,
                      onSelected: (_) => setState(() {
                        _type = t;
                        _icon = _defaultIconFor(t);
                        _error = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _labelCtrl,
                textInputAction: needsValue
                    ? TextInputAction.next
                    : TextInputAction.done,
                decoration: _fieldDecoration(
                  context,
                  label: 'نص الزر',
                  hint: 'مثل: 00 أو اسم',
                  icon: Icons.label_outline_rounded,
                ),
              ),
              if (needsValue) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _valueCtrl,
                  keyboardType: _type == 'appendZeros'
                      ? TextInputType.number
                      : TextInputType.text,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: _fieldDecoration(
                    context,
                    label: 'القيمة',
                    hint: _valueHint,
                    icon: Icons.edit_note_rounded,
                  ),
                ),
              ],
              if (_type == 'setCurrency' &&
                  widget.currencyNames.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in widget.currencyNames)
                      ActionChip(
                        label: Text(c),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _valueCtrl.text = c),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              const _SectionTitle(text: 'الأيقونة'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final k in _actionIconKeys)
                    ChoiceChip(
                      label: Icon(_actionIconData(k), size: 20),
                      selected: _icon == k,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _icon = k),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _iconAbove,
                onChanged: (v) => setState(() => _iconAbove = v),
                title: const Text(
                  'الأيقونة فوق النص',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(
                    color: cs.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('إلغاء'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('إضافة'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================
// عناصر الواجهة المشتركة
// =============================================================

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _pageBg(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return _isDark(context) ? cs.surface : cs.surfaceContainerLow;
}

Color _cardBg(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return _isDark(context) ? cs.surfaceContainer : cs.surfaceContainerLowest;
}

Color _outline(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return cs.outlineVariant.withValues(alpha: _isDark(context) ? .30 : .55);
}

Color _muted(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

/// لون الأيقونات/النصوص الملوّنة بتباين مناسب للوضعين.
Color _fg(BuildContext context, Color c) => _isDark(context)
    ? Color.lerp(c, Colors.white, .25)!
    : Color.lerp(c, Colors.black, .10)!;

/// خلفية خفيفة بلون القسم.
Color _tint(
  BuildContext context,
  Color c, {
  double light = .12,
  double dark = .20,
}) => c.withValues(alpha: _isDark(context) ? dark : light);

String _norm(String s) => normalizeArabic(s).toLowerCase();

int _ci(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

/// تحويل الأرقام العربية/الفارسية إلى أرقام لاتينية.
String _asciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0);
    } else if (r == 0x066B) {
      b.write('.');
    } else if (r == 0x066C) {
      // فاصل الآلاف العربي
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

double? _parseNumber(String raw) =>
    double.tryParse(_asciiDigits(raw.trim()).replaceAll(',', '.'));

String _fmtNum(double v) => v == v.roundToDouble()
    ? v.toStringAsFixed(0)
    : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

InputDecoration _fieldDecoration(
  BuildContext context, {
  String? hint,
  String? label,
  IconData? icon,
  Widget? suffix,
  String? helper,
}) {
  final cs = Theme.of(context).colorScheme;
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: BorderSide(color: _outline(context)),
  );
  return InputDecoration(
    hintText: hint,
    labelText: label,
    helperText: helper,
    helperStyle: TextStyle(color: cs.error, fontWeight: FontWeight.w600),
    prefixIcon: icon == null ? null : Icon(icon, size: 20),
    suffixIcon: suffix,
    filled: true,
    fillColor: _cardBg(context),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: border,
    enabledBorder: border,
    disabledBorder: border,
    focusedBorder: border.copyWith(
      borderSide: BorderSide(color: cs.primary, width: 1.4),
    ),
  );
}

void _snack(BuildContext context, String message, {VoidCallback? onUndo}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: Duration(milliseconds: onUndo == null ? 2200 : 4500),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      action: onUndo == null
          ? null
          : SnackBarAction(label: 'تراجع', onPressed: onUndo),
    ),
  );
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'تأكيد',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          content: Text(message, style: const TextStyle(height: 1.5)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              style: danger
                  ? FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
    },
  );
  return result ?? false;
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
  IconData icon = Icons.edit_rounded,
  String confirmLabel = 'حفظ',
  TextInputType? keyboardType,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      title: title,
      hint: hint,
      initial: initial,
      icon: icon,
      confirmLabel: confirmLabel,
      keyboardType: keyboardType,
    ),
  );
}

class _TextPromptDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String initial;
  final IconData icon;
  final String confirmLabel;
  final TextInputType? keyboardType;

  const _TextPromptDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.icon,
    required this.confirmLabel,
    this.keyboardType,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initial.length,
        );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(
          widget.title,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        content: TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: widget.keyboardType,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: _fieldDecoration(
            context,
            hint: widget.hint,
            icon: widget.icon,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
        ],
      ),
    );
  }
}

/// هيكل موحّد لصفحات الأقسام.
class _SubPageScaffold extends StatelessWidget {
  final _SettingsStore store;
  final String title;
  final IconData icon;
  final Color color;
  final String description;
  final List<Widget> actions;
  final Listenable? extraListenable;
  final List<Widget> Function(BuildContext context) builder;

  const _SubPageScaffold({
    required this.store,
    required this.title,
    required this.icon,
    required this.color,
    required this.description,
    required this.builder,
    this.actions = const [],
    this.extraListenable,
  });

  @override
  Widget build(BuildContext context) {
    final bg = _pageBg(context);
    final listenable = extraListenable == null
        ? store
        : Listenable.merge([store, extraListenable]);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          centerTitle: false,
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19),
          ),
          actions: [
            ListenableBuilder(
              listenable: store,
              builder: (context, _) =>
                  _SaveStatus(saving: store.isSaving, dense: true),
            ),
            ...actions,
            const SizedBox(width: 6),
          ],
        ),
        body: ListenableBuilder(
          listenable: listenable,
          builder: (context, _) => ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              16,
              6,
              16,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              _IntroCard(icon: icon, color: color, text: description),
              const SizedBox(height: 18),
              ...builder(context),
            ],
          ),
        ),
      ),
    );
  }
}

class _HubTile {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final int? count;
  final String searchText;
  final List<String> contents;
  final VoidCallback onTap;

  /// سبب ظهور العنصر في نتائج البحث (عند التطابق مع محتوى القائمة)
  final String? matchNote;

  const _HubTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.count,
    this.searchText = '',
    this.contents = const [],
    this.matchNote,
  });

  _HubTile withMatch(String note) => _HubTile(
    icon: icon,
    color: color,
    title: title,
    subtitle: subtitle,
    onTap: onTap,
    count: count,
    searchText: searchText,
    contents: contents,
    matchNote: note,
  );
}

class _HubGroup {
  final String title;
  final IconData icon;
  final List<_HubTile> tiles;

  const _HubGroup({
    required this.title,
    required this.icon,
    required this.tiles,
  });
}

class _HubHeader extends StatelessWidget {
  final bool saving;
  final bool showBack;

  const _HubHeader({required this.saving, required this.showBack});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (showBack) ...[const BackButton(), const SizedBox(width: 2)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'الإعدادات',
                style: TextStyle(
                  fontSize: 28,
                  height: 1.2,
                  fontWeight: FontWeight.w900,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'خصّص طريقة قراءة الرسائل وتحليلها',
                style: TextStyle(
                  fontSize: 13.5,
                  color: _muted(context),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _SaveStatus(saving: saving),
      ],
    );
  }
}

class _SaveStatus extends StatelessWidget {
  final bool saving;
  final bool dense;

  const _SaveStatus({required this.saving, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final color = saving ? _muted(context) : _fg(context, _kGreen);
    final label = saving ? 'جارٍ الحفظ…' : 'محفوظ تلقائيًا';
    final icon = saving
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(Icons.cloud_done_rounded, size: 17, color: color);

    if (dense) {
      return Tooltip(
        message: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: KeyedSubtree(key: ValueKey(saving), child: icon),
            ),
          ),
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String title;
  final IconData icon;

  const _GroupLabel({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final color = _fg(context, Theme.of(context).colorScheme.primary);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              color: color,
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final List<_HubTile> tiles;

  const _GroupCard({required this.tiles});

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const _ListDivider(indent: 68),
            _HubTileView(tile: tiles[i]),
          ],
        ],
      ),
    );
  }
}

class _HubTileView extends StatelessWidget {
  final _HubTile tile;

  const _HubTileView({required this.tile});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final note = tile.matchNote;
    return InkWell(
      onTap: tile.onTap,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 10, 12),
        child: Row(
          children: [
            _IconBadge(icon: tile.icon, color: tile.color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tile.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    note ?? tile.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: note == null
                          ? FontWeight.w500
                          : FontWeight.w700,
                      color: note == null
                          ? _muted(context)
                          : _fg(context, tile.color),
                    ),
                  ),
                ],
              ),
            ),
            if (tile.count != null) ...[
              const SizedBox(width: 8),
              _ValuePill(text: '${tile.count}', color: tile.color),
            ],
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right_rounded,
              color: _muted(context).withValues(alpha: .7),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _Card({required this.child, this.padding = const EdgeInsets.all(14)});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _cardBg(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: _outline(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

class _IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _IconBadge({required this.icon, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _tint(context, color),
        borderRadius: BorderRadius.circular(size * .32),
      ),
      child: Icon(icon, size: size * .52, color: _fg(context, color)),
    );
  }
}

class _ValuePill extends StatelessWidget {
  final String text;
  final Color color;

  const _ValuePill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 28),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: _tint(context, color, light: .10, dark: .18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: _fg(context, color),
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _IntroCard({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _tint(context, color, light: .07, dark: .12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: .20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconBadge(icon: icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.55,
                fontWeight: FontWeight.w500,
                color: cs.onSurface.withValues(alpha: .86),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const _SectionTitle({required this.text, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: _muted(context),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _SmallIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  const _SmallIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      onPressed: onPressed,
      icon: Icon(icon, color: color ?? _muted(context)),
    );
  }
}

class _WordChip extends StatelessWidget {
  final String text;
  final Color color;
  final VoidCallback? onTap;
  final VoidCallback onDelete;

  const _WordChip({
    required this.text,
    required this.color,
    required this.onDelete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InputChip(
      label: Text(text),
      onPressed: onTap,
      onDeleted: onDelete,
      deleteIcon: const Icon(Icons.close_rounded, size: 16),
      deleteButtonTooltipMessage: 'حذف',
      backgroundColor: _tint(context, color, light: .07, dark: .14),
      side: BorderSide(
        color: color.withValues(alpha: _isDark(context) ? .30 : .22),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 13.5,
        color: cs.onSurface,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
    );
  }
}

class _AddChip extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _AddChip({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final color = _fg(context, Theme.of(context).colorScheme.primary);
    return ActionChip(
      avatar: Icon(Icons.add_rounded, size: 18, color: color),
      label: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
      backgroundColor: Colors.transparent,
      side: BorderSide(color: color.withValues(alpha: .40)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 10),
      secondary: Icon(icon, color: _muted(context)),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: _muted(context), fontSize: 12.5, height: 1.35),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.icon,
    required this.title,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.subtitle,
    this.divisions,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: _muted(context)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: _muted(context),
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _ValuePill(text: valueText, color: cs.primary),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueText,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ListDivider extends StatelessWidget {
  final double indent;

  const _ListDivider({this.indent = 56});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: indent,
      endIndent: 14,
      color: _outline(context),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const _EmptyHint({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color == null ? _muted(context) : _fg(context, color!);
    return _Card(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: Column(
        children: [
          Icon(icon, size: 34, color: c.withValues(alpha: .75)),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted(context), height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _TipText extends StatelessWidget {
  final String text;

  const _TipText(this.text);

  @override
  Widget build(BuildContext context) {
    final c = _muted(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline_rounded, size: 16, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: c, fontSize: 12.5, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _AutoSaveFooter extends StatelessWidget {
  const _AutoSaveFooter();

  @override
  Widget build(BuildContext context) {
    final c = _muted(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_done_outlined, size: 16, color: c),
          const SizedBox(width: 6),
          Text(
            'تُحفظ التغييرات تلقائيًا فور إجرائها',
            style: TextStyle(color: c, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
