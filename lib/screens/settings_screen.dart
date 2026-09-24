// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';
import '../bubble_prefs.dart';
import '../database_service.dart';
import '../models.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Settings? settings;

  // Controllers (إضافة عناصر جديدة عامة)
  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  final _cancelController = TextEditingController();
  final _ignoredController = TextEditingController();
  final _lineIgnoredController = TextEditingController();
  final _amountWordController = TextEditingController();
  final _amountWordValueController = TextEditingController();
  final _readyNameController = TextEditingController();
  final _companyUserNameController = TextEditingController();
  final _currencyDivisorController = TextEditingController();
  final _bubbleActionLabelController = TextEditingController();
  final _bubbleActionValueController = TextEditingController();
  final _forbiddenController = TextEditingController();
  final _forbiddenPhraseController = TextEditingController();

  // تفضيلات تصميم شاشة الفقاعات
  BubbleUiPrefs _bubblePrefs = const BubbleUiPrefs();

  // إضافة مجموعة/عملة جديدة (alias + display name)
  final _currencyKeyController = TextEditingController();
  final _currencyValueController = TextEditingController();

  // حقل إضافة alias داخل كل مجموعة (name → controller)
  final Map<String, TextEditingController> _aliasCtrls = {};
  final Map<int, TextEditingController> _accountKeywordCtrls = {};
  String _bubbleActionType = 'appendZeros';
  String _bubbleActionIcon = 'zeros';
  bool _bubbleActionIconAbove = false;

  @override
  void initState() {
    super.initState();
    // بنية الإعدادات كما هي (alias → displayName)
    settings =
        DatabaseService.getSettings() ??
        Settings(
          nameKeywords: [
            "المستلم",
            "الأسم",
            "المستفيد",
            "الاسم",
            "إلى",
            "ل",
            "لـ",
          ],
          amountKeywords: ["المبلغ", "قيمة", "amount", "\$"],
          currencyMap: {"\$": "دولار"},
          ignoredWords: [],
          lineIgnoredWords: [],
          cancelKeywords: ["الغاء"],
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

    // حوّل كل القوائم إلى نسخ قابلة للتعديل
    settings = Settings(
      nameKeywords: List<String>.from(settings!.nameKeywords),
      amountKeywords: List<String>.from(settings!.amountKeywords),
      currencyMap: Map<String, String>.from(settings!.currencyMap),
      ignoredWords: List<String>.from(settings!.ignoredWords),
      lineIgnoredWords: List<String>.from(settings!.lineIgnoredWords),
      cancelKeywords: List<String>.from(settings!.cancelKeywords),
      amountWordValues: Map<String, double>.from(settings!.amountWordValues),
      bubbleReadyNames: List<String>.from(settings!.bubbleReadyNames),
      companyUserNames: List<String>.from(settings!.companyUserNames),
      bubbleQuickActions: settings!.bubbleQuickActions
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
      forbiddenWords: List<String>.from(settings!.forbiddenWords),
      forbiddenPhrases: List<String>.from(settings!.forbiddenPhrases),
      bubbleUiPrefs: Map<String, dynamic>.from(settings!.bubbleUiPrefs),
    );
    _bubblePrefs = BubbleUiPrefs.fromSettings(settings);

    _sortAll();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _cancelController.dispose();
    _ignoredController.dispose();
    _lineIgnoredController.dispose();
    _amountWordController.dispose();
    _amountWordValueController.dispose();
    _readyNameController.dispose();
    _companyUserNameController.dispose();
    _currencyDivisorController.dispose();
    _bubbleActionLabelController.dispose();
    _bubbleActionValueController.dispose();
    _forbiddenController.dispose();
    _forbiddenPhraseController.dispose();
    _currencyKeyController.dispose();
    _currencyValueController.dispose();
    for (final c in _aliasCtrls.values) {
      c.dispose();
    }
    for (final c in _accountKeywordCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ===== Utilities =====
  int _ci(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

  void _sortAll() {
    if (settings == null) return;
    settings!.nameKeywords.sort(_ci);
    settings!.amountKeywords.sort(_ci);
    settings!.cancelKeywords.sort(_ci);
    settings!.bubbleReadyNames.sort(_ci);
    settings!.companyUserNames.sort(_ci);
    settings!.ignoredWords.sort(_ci);
    settings!.lineIgnoredWords.sort(_ci);
    settings!.forbiddenWords.sort(_ci);
    settings!.forbiddenPhrases.sort(_ci);
    setState(() {});
  }

  void _updateBubblePrefs(BubbleUiPrefs prefs) {
    setState(() {
      _bubblePrefs = prefs;
      settings!.bubbleUiPrefs = prefs.toMap();
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  Future<bool> _confirm(String title, String msg) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              content: Text(msg),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('تأكيد'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  // إضافة كلمة لقوائم عامة
  void _safeAddTo(List<String> list, TextEditingController c) {
    final v = c.text.trim();
    if (v.isEmpty) return;
    if (!list.any((e) => e.toLowerCase() == v.toLowerCase())) {
      list.add(v);
      _sortAll();
    } else {
      _showSnack('موجودة مسبقًا');
    }
    c.clear();
  }

  void _safeAddAmountWordValue() {
    final word = _amountWordController.text.trim();
    final rawValue = _amountWordValueController.text.trim().replaceAll(
      ',',
      '.',
    );
    final value = double.tryParse(rawValue);
    if (word.isEmpty || value == null || value <= 0) {
      _showSnack('أدخل الكلمة وقيمتها الرقمية بشكل صحيح');
      return;
    }

    settings!.amountWordValues[word] = value;
    _amountWordController.clear();
    _amountWordValueController.clear();
    setState(() {});
  }

  Future<void> _deleteAmountWordValue(String word) async {
    final ok = await _confirm('تأكيد الحذف', 'حذف قيمة "$word"؟');
    if (!ok) return;
    settings!.amountWordValues.remove(word);
    setState(() {});
  }

  String _bubbleActionTitle(String type) {
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

  IconData _bubbleActionIconData(String key) {
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

  void _safeAddBubbleAction() {
    final label = _bubbleActionLabelController.text.trim();
    final value = _bubbleActionValueController.text.trim();

    if (label.isEmpty) {
      _showSnack('أدخل نص الزر');
      return;
    }
    if ((_bubbleActionType == 'appendZeros' ||
            _bubbleActionType == 'setCurrency') &&
        value.isEmpty) {
      _showSnack('هذا النوع يحتاج قيمة');
      return;
    }

    settings!.bubbleQuickActions.add(
      BubbleQuickActionConfig(
        id: DateTime.now().millisecondsSinceEpoch,
        label: label,
        iconKey: _bubbleActionIcon,
        actionType: _bubbleActionType,
        value: value,
        iconAbove: _bubbleActionIconAbove,
      ),
    );

    _bubbleActionLabelController.clear();
    _bubbleActionValueController.clear();
    setState(() {});
  }

  Future<void> _deleteBubbleAction(BubbleQuickActionConfig action) async {
    final ok = await _confirm('تأكيد الحذف', 'حذف زر "${action.label}"؟');
    if (!ok) return;
    settings!.bubbleQuickActions.removeWhere((a) => a.id == action.id);
    setState(() {});
  }

  // ===== عملات: عمليات أساسية =====

  // 1) جدول alias → displayName (كما في settings.currencyMap)
  Map<String, String> get _curMap => settings!.currencyMap;

  // 2) تجميع بحسب displayName: name → [aliases...]
  Map<String, List<String>> _groupedByName() {
    final m = <String, List<String>>{};
    for (final e in _curMap.entries) {
      final name = e.value.trim();
      (m[name] ??= []).add(e.key);
    }
    // فرز داخلي
    for (final k in m.keys) {
      m[k]!.sort(_ci);
    }
    // فرز بالمفاتيح (الأسماء)
    final sorted = Map.fromEntries(
      m.entries.toList()..sort((a, b) => _ci(a.key, b.key)),
    );
    return sorted;
  }

  // 3) إضافة عملة/مجموعة جديدة (alias + displayName)
  void _safeAddCurrency() {
    final alias = _currencyKeyController.text.trim();
    final name = _currencyValueController.text.trim();
    if (alias.isEmpty || name.isEmpty) {
      _showSnack('أدخل الاختصار/الاسم + الاسم المعروض');
      return;
    }
    final exists = _curMap.keys.any(
      (e) => e.toLowerCase() == alias.toLowerCase(),
    );
    if (exists) {
      _showSnack('الاختصار/الاسم موجود مسبقًا');
      return;
    }
    _curMap[alias] = name;
    _currencyKeyController.clear();
    _currencyValueController.clear();
    setState(() {});
  }

  // 4) إضافة Alias إلى مجموعة اسم معروض معيّنة
  void _addAliasToDisplayName(String displayName) {
    final ctrl = _aliasCtrls.putIfAbsent(
      displayName,
      () => TextEditingController(),
    );
    final alias = ctrl.text.trim();
    if (alias.isEmpty) return;

    final exists = _curMap.keys.any(
      (e) => e.toLowerCase() == alias.toLowerCase(),
    );
    if (exists) {
      _showSnack('هذا الـ Alias موجود مسبقًا');
      return;
    }
    _curMap[alias] = displayName;
    ctrl.clear();
    setState(() {});
  }

  // 5) حذف Alias واحد
  Future<void> _deleteAlias(String alias, String displayName) async {
    final ok = await _confirm('تأكيد الحذف', 'حذف "$alias" من "$displayName"؟');
    if (!ok) return;
    _curMap.remove(alias);
    setState(() {});
  }

  // 6) إعادة تسمية الاسم المعروض لمجموعة كاملة
  Future<void> _renameDisplayName(String oldName) async {
    final ctrl = TextEditingController(text: oldName);
    String? newName;
    await showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            'إعادة تسمية العملة',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          content: TextField(
            controller: ctrl,
            decoration: _inputDecoration(
              context,
              hint: 'الاسم المعروض الجديد',
              icon: Icons.edit_rounded,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final v = ctrl.text.trim();
                newName = v.isEmpty ? null : v;
                Navigator.pop(ctx);
              },
              child: const Text('اعتماد'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (newName == null || newName == oldName) return;

    // عدّل كل الإدخالات التي قيمتها oldName → newName
    final toChange = _curMap.entries
        .where((e) => e.value == oldName)
        .map((e) => e.key)
        .toList();
    for (final alias in toChange) {
      _curMap[alias] = newName!;
    }
    setState(() {});
  }

  // 7) حذف مجموعة كاملة
  Future<void> _deleteGroup(String displayName) async {
    final ok = await _confirm(
      'حذف العملة',
      'سيتم حذف جميع الاختصارات/الأسماء تحت "$displayName". هل تريد المتابعة؟',
    );
    if (!ok) return;
    final keys = _curMap.entries
        .where((e) => e.value == displayName)
        .map((e) => e.key)
        .toList();
    for (final k in keys) {
      _curMap.remove(k);
    }
    setState(() {});
  }

  Future<void> _saveSettings() async {
    if (settings == null) return;
    await DatabaseService.saveSettings(settings!);
    _showSnack('تم حفظ الإعدادات ✅');
  }

  Future<void> _showCurrencySplitDialog() async {
    final currencies = settings!.currencyMap.values.toSet().toList()..sort();
    if (currencies.isEmpty) {
      _showSnack('أضف عملة واحدة على الأقل أولاً');
      return;
    }
    String selected = currencies.first;
    _currencyDivisorController.clear();
    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('تقسيم الحركات المسجّلة'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'تُطبّق مرة واحدة على الحركات المحفوظة فقط، ولا تؤثر على الحركات الجديدة.',
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  value: selected,
                  items: currencies
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) =>
                      setDialogState(() => selected = v ?? selected),
                  decoration: const InputDecoration(
                    labelText: 'العملة',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _currencyDivisorController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'المقسوم عليه',
                    hintText: 'مثال: 100',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () async {
                  final divisor = double.tryParse(
                    _currencyDivisorController.text.trim().replaceAll(',', '.'),
                  );
                  if (divisor == null || divisor <= 0 || divisor == 1) {
                    _showSnack('أدخل رقمًا أكبر من صفر ومختلفًا عن 1');
                    return;
                  }
                  final matching = DatabaseService.transactionsBox.values
                      .where(
                        (tx) =>
                            tx.currency == selected ||
                            (tx.secondAmount != null &&
                                tx.secondCurrency == selected),
                      )
                      .toList();
                  final approved = await _confirm(
                    'تأكيد القسمة',
                    'سيتم تقسيم مبالغ ${matching.length} حركة محفوظة بعملة $selected على $divisor. لا يمكن التراجع تلقائيًا.',
                  );
                  if (!approved) return;
                  for (final tx in matching) {
                    if (tx.currency == selected) tx.amount /= divisor;
                    if (tx.secondAmount != null &&
                        tx.secondCurrency == selected)
                      tx.secondAmount = tx.secondAmount! / divisor;
                    await tx.save();
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  _showSnack(
                    'تم تقسيم ${matching.length} حركة بعملة $selected',
                  );
                },
                child: const Text('تقسيم الحركات'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===== Presets =====
  void _addAmountKeywordPresets() {
    const presets = [
      'المبلغ',
      'المبلغ:',
      'قيمة',
      'السعر',
      'السعر:',
      'amount',
      '\$',
    ];
    for (final p in presets) {
      if (!settings!.amountKeywords.any(
        (e) => e.toLowerCase() == p.toLowerCase(),
      )) {
        settings!.amountKeywords.add(p);
      }
    }
    _sortAll();
    _showSnack('أُضيفت كلمات المبلغ الشائعة');
  }

  void _addCommonCurrencies() {
    // أضف عدة aliases تحت نفس الاسم المعروض
    void addAlias(String alias, String display) {
      if (!_curMap.keys.any((e) => e.toLowerCase() == alias.toLowerCase())) {
        _curMap[alias] = display;
      }
    }

    addAlias('QAR', 'ريال قطري');
    addAlias('﷼', 'ريال قطري');
    addAlias('ريال', 'ريال قطري');
    addAlias('ريال قطري', 'ريال قطري');

    addAlias('\$', 'دولار');
    addAlias('USD', 'دولار');
    addAlias('Dollar', 'دولار');
    addAlias('دولار', 'دولار');

    addAlias('EUR', 'يورو');
    addAlias('€', 'يورو');
    addAlias('يورو', 'يورو');

    addAlias('GBP', 'جنيه');
    addAlias('£', 'جنيه');
    addAlias('Sterling', 'جنيه');
    addAlias('جنيه', 'جنيه');

    addAlias('TRY', 'ليرة تركية');
    addAlias('₺', 'ليرة تركية');
    addAlias('ليرة', 'ليرة تركية');
    addAlias('ليرة تركية', 'ليرة تركية');

    addAlias('SYP', 'ليرة سورية');
    addAlias('ل.س', 'ليرة سورية');
    addAlias('ليرة سورية', 'ليرة سورية');

    addAlias('EGP', 'جنيه مصري');
    addAlias('جنيه مصري', 'جنيه مصري');

    setState(() {});
    _showSnack('أُضيفت مجموعة عملات شائعة (بعدة اختصارات/أسماء)');
  }

  // ===== UI Helpers =====
  Color _pageBg(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? const Color(0xFF0F131A)
        : const Color(0xFFF5F7FB);
  }

  Color _cardColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? const Color(0xFF171D26)
        : Colors.white;
  }

  Color _softColor(BuildContext context, Color color) {
    final theme = Theme.of(context);
    return color.withOpacity(theme.brightness == Brightness.dark ? .18 : .10);
  }

  Color _mutedText(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return scheme.onSurface.withOpacity(.62);
  }

  InputDecoration _inputDecoration(
    BuildContext context, {
    required String hint,
    IconData? icon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon, size: 20),
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withOpacity(.65),
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: scheme.outlineVariant.withOpacity(.22)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(
          color: scheme.primary.withOpacity(.65),
          width: 1.2,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    );
  }

  Widget _iconBubble(
    BuildContext context,
    IconData icon,
    Color color, {
    double size = 44,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _softColor(context, color),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(.16)),
      ),
      child: Icon(icon, color: color, size: size * .50),
    );
  }

  Widget _countPill(BuildContext context, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: _softColor(context, color),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(.18)),
      ),
      child: Text(
        '$count عنصر',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _modernIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    return Tooltip(
      message: tooltip,
      child: IconButton.filledTonal(
        style: IconButton.styleFrom(
          backgroundColor: _softColor(context, c),
          foregroundColor: c,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
      ),
    );
  }

  Widget _emptyMessage(
    String text, {
    IconData icon = Icons.info_outline_rounded,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(.48),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withOpacity(.20)),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSurfaceVariant, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroHeader() {
    final scheme = Theme.of(context).colorScheme;
    final grouped = _groupedByName();

    Widget stat({
      required IconData icon,
      required String label,
      required String value,
      required Color color,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: _softColor(context, color),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withOpacity(.15)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 7),
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  height: 1,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _mutedText(context),
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant.withOpacity(.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? .18 : .06,
            ),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconBubble(
                context,
                Icons.tune_rounded,
                scheme.primary,
                size: 50,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'إعدادات التحليل',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'تحكم بالكلمات والعملات التي يعتمد عليها التطبيق أثناء قراءة الحركات.',
                      style: TextStyle(
                        color: _mutedText(context),
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              stat(
                icon: Icons.person_search_rounded,
                label: 'أسماء',
                value: '${settings!.nameKeywords.length}',
                color: Colors.blue,
              ),
              const SizedBox(width: 8),
              stat(
                icon: Icons.payments_rounded,
                label: 'مبالغ',
                value: '${settings!.amountKeywords.length}',
                color: Colors.green,
              ),
              const SizedBox(width: 8),
              stat(
                icon: Icons.currency_exchange_rounded,
                label: 'عملات',
                value: '${grouped.length}',
                color: Colors.deepPurple,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chipWrap({
    required List<String> list,
    required Color color,
    required void Function(String item) onDelete,
  }) {
    final scheme = Theme.of(context).colorScheme;
    if (list.isEmpty) {
      return _emptyMessage('لا توجد عناصر بعد — أضف عنصرًا من الحقل بالأسفل.');
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: list
          .map(
            (word) => InputChip(
              label: Text(word),
              avatar: Icon(Icons.tag_rounded, size: 16, color: color),
              backgroundColor: _softColor(context, color),
              labelStyle: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
              side: BorderSide(color: color.withOpacity(.16)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              deleteIcon: Icon(
                Icons.close_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              onDeleted: () => onDelete(word),
            ),
          )
          .toList(),
    );
  }

  Widget _addRow({
    required String hint,
    required TextEditingController controller,
    required VoidCallback onAdd,
    IconData icon = Icons.add_rounded,
    Widget? trailing,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 520;
        final input = TextField(
          controller: controller,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onAdd(),
          decoration: _inputDecoration(context, hint: hint, icon: icon),
        );

        final addButton = FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
          label: const Text('إضافة'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              input,
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: addButton),
                  if (trailing != null) ...[const SizedBox(width: 8), trailing],
                ],
              ),
            ],
          );
        }

        return Row(
          key: const ValueKey('inputs'),
          children: [
            Expanded(child: input),
            const SizedBox(width: 10),
            addButton,
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        );
      },
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    int? count,
    required List<Widget> children,
    List<Widget> headerActions = const [],
  }) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: scheme.outlineVariant.withOpacity(.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? .16 : .045,
            ),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _iconBubble(context, icon, color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 17.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        if (count != null) _countPill(context, count, color),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: _mutedText(context),
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (headerActions.isNotEmpty) ...[
                const SizedBox(width: 8),
                Wrap(spacing: 4, children: headerActions),
              ],
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _buildKeywordSection(
    String title,
    List<String> list,
    TextEditingController controller, {
    required IconData icon,
    required Color color,
    required String subtitle,
    String addHint = 'أدخل كلمة',
    List<Widget> headerActions = const [],
  }) {
    return _sectionCard(
      icon: icon,
      title: title,
      subtitle: subtitle,
      color: color,
      count: list.length,
      headerActions: headerActions,
      children: [
        _chipWrap(
          list: list,
          color: color,
          onDelete: (w) async {
            final ok = await _confirm('تأكيد الحذف', 'حذف "$w"؟');
            if (ok) setState(() => list.remove(w));
          },
        ),
        const SizedBox(height: 12),
        _addRow(
          hint: addHint,
          controller: controller,
          icon: icon,
          onAdd: () => setState(() => _safeAddTo(list, controller)),
        ),
      ],
    );
  }

  Widget _buildAmountWordValuesSection() {
    final entries = settings!.amountWordValues.entries.toList()
      ..sort((a, b) => _ci(a.key, b.key));
    const color = Colors.indigo;

    return _sectionCard(
      icon: Icons.calculate_rounded,
      title: 'قيم الكلمات',
      subtitle:
          'اربط أي كلمة بقيمة رقمية ليستخدمها التطبيق أثناء اكتشاف المبلغ. مثال: ستمئة = 600.',
      color: color,
      count: entries.length,
      children: [
        if (entries.isEmpty)
          _emptyMessage('لا توجد قيم كلمات بعد.')
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: entries.map((entry) {
              final isInt = entry.value == entry.value.roundToDouble();
              final valueText = isInt
                  ? entry.value.toStringAsFixed(0)
                  : entry.value.toStringAsFixed(2);
              return InputChip(
                avatar: const Icon(Icons.functions_rounded, size: 16),
                label: Text('${entry.key} = $valueText'),
                backgroundColor: _softColor(context, color),
                side: BorderSide(color: color.withOpacity(.16)),
                onDeleted: () => _deleteAmountWordValue(entry.key),
              );
            }).toList(),
          ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 560;
            final wordField = TextField(
              controller: _amountWordController,
              textInputAction: TextInputAction.next,
              decoration: _inputDecoration(
                context,
                hint: 'الكلمة مثل: ستمئة',
                icon: Icons.text_fields_rounded,
              ),
            );
            final valueField = TextField(
              controller: _amountWordValueController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _safeAddAmountWordValue(),
              decoration: _inputDecoration(
                context,
                hint: 'القيمة مثل: 600',
                icon: Icons.pin_rounded,
              ),
            );
            final addButton = FilledButton.icon(
              onPressed: _safeAddAmountWordValue,
              icon: const Icon(Icons.add_rounded),
              label: const Text('إضافة'),
            );

            if (narrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  wordField,
                  const SizedBox(height: 10),
                  valueField,
                  const SizedBox(height: 10),
                  addButton,
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: wordField),
                const SizedBox(width: 10),
                Expanded(child: valueField),
                const SizedBox(width: 10),
                addButton,
              ],
            );
          },
        ),
      ],
    );
  }

  // ===== تخصيص شاشة الفقاعات =====
  Widget _colorRow({
    required String label,
    required int selected,
    required ValueChanged<int> onPick,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: BubbleUiPrefs.palette.map((c) {
              final isSel = c == selected;
              return InkWell(
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
                      color: isSel ? scheme.onSurface : Colors.transparent,
                      width: 2.4,
                    ),
                    boxShadow: isSel
                        ? [
                            BoxShadow(
                              color: Color(c).withValues(alpha: .45),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                  child: isSel
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _prefSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required IconData icon,
  }) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      secondary: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(subtitle, style: TextStyle(color: _mutedText(context))),
    );
  }

  Widget _bubblePreview() {
    final p = _bubblePrefs;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    Widget chip(String text, Color? color, {bool strike = false}) {
      final fg = color == null
          ? scheme.onSurface.withValues(alpha: .78)
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
          color: (color ?? scheme.onSurface).withValues(
            alpha: color == null ? .06 : .14,
          ),
          borderRadius: BorderRadius.circular(p.compact ? 10 : 14),
          border: Border.all(
            color: (color ?? scheme.onSurface).withValues(
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

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Wrap(
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
    );
  }

  Widget _buildBubbleCustomizationSection() {
    const color = Colors.indigo;
    final p = _bubblePrefs;
    return _sectionCard(
      icon: Icons.palette_rounded,
      title: 'تخصيص شاشة الفقاعات',
      subtitle:
          'غيّر شكل وطريقة عمل شاشة تحليل الحركات (الفقاعات): حجم الخط، الألوان، طريقة العرض والتنبيهات.',
      color: color,
      headerActions: [
        _modernIconButton(
          tooltip: 'استعادة الافتراضي',
          onPressed: () => _updateBubblePrefs(const BubbleUiPrefs()),
          icon: Icons.restart_alt_rounded,
          color: color,
        ),
      ],
      children: [
        _bubblePreview(),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.format_size_rounded),
            const SizedBox(width: 8),
            const Text(
              'حجم خط الكلمات',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Expanded(
              child: Slider(
                value: p.tokenFontSize,
                min: BubbleUiPrefs.minFontSize,
                max: BubbleUiPrefs.maxFontSize,
                divisions:
                    (BubbleUiPrefs.maxFontSize - BubbleUiPrefs.minFontSize)
                        .round(),
                label: p.tokenFontSize.toStringAsFixed(0),
                onChanged: (v) =>
                    _updateBubblePrefs(p.copyWith(tokenFontSize: v)),
              ),
            ),
            Text(
              p.tokenFontSize.toStringAsFixed(0),
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ],
        ),
        _prefSwitch(
          title: 'عرض مضغوط',
          subtitle: 'فقاعات أصغر ومسافات أقل لعرض رسائل أكثر',
          value: p.compact,
          icon: Icons.density_small_rounded,
          onChanged: (v) => _updateBubblePrefs(p.copyWith(compact: v)),
        ),
        _prefSwitch(
          title: 'إظهار المرسل والوقت',
          subtitle: 'اسم مرسل الرسالة ووقتها أعلى كل فقاعة',
          value: p.showSenderHeader,
          icon: Icons.person_outline_rounded,
          onChanged: (v) => _updateBubblePrefs(p.copyWith(showSenderHeader: v)),
        ),
        _prefSwitch(
          title: 'إظهار دليل الألوان',
          subtitle: 'شرح مختصر لألوان الفقاعات أعلى الشاشة',
          value: p.showLegend,
          icon: Icons.legend_toggle_rounded,
          onChanged: (v) => _updateBubblePrefs(p.copyWith(showLegend: v)),
        ),
        _prefSwitch(
          title: 'إظهار الأزرار السريعة',
          subtitle: 'أزرار الفقاعة المعرفة في قسم «أزرار الفقاعة»',
          value: p.showQuickActions,
          icon: Icons.touch_app_outlined,
          onChanged: (v) => _updateBubblePrefs(p.copyWith(showQuickActions: v)),
        ),
        _prefSwitch(
          title: 'غير المكتمل أولًا',
          subtitle: 'ترتيب الفقاعات الناقصة قبل الجاهزة (وإلا الترتيب الزمني)',
          value: p.incompleteFirst,
          icon: Icons.sort_rounded,
          onChanged: (v) => _updateBubblePrefs(p.copyWith(incompleteFirst: v)),
        ),
        _prefSwitch(
          title: 'تمديد الاسم تلقائيًا',
          subtitle:
              'عند الضغط على كلمة يمتد الاسم حتى نهاية السطر أو أول كلمة ممنوعة/رقم/عملة',
          value: p.autoExtendName,
          icon: Icons.keyboard_double_arrow_left_rounded,
          onChanged: (v) => _updateBubblePrefs(p.copyWith(autoExtendName: v)),
        ),
        _prefSwitch(
          title: 'تأكيد قبل حفظ رسالة فيها جملة ممنوعة',
          subtitle: 'يظهر تنبيه يعرض الجمل الممنوعة قبل الحفظ',
          value: p.confirmForbiddenPhrase,
          icon: Icons.gpp_maybe_rounded,
          onChanged: (v) =>
              _updateBubblePrefs(p.copyWith(confirmForbiddenPhrase: v)),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Icon(Icons.manage_search_rounded),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'فحص التكرار (نفس الاسم والمبلغ والعملة): آخر ${p.duplicateDays} يومًا',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        Slider(
          value: p.duplicateDays.clamp(1, 90).toDouble(),
          min: 1,
          max: 90,
          divisions: 89,
          label: '${p.duplicateDays}',
          onChanged: (v) =>
              _updateBubblePrefs(p.copyWith(duplicateDays: v.round())),
        ),
        const SizedBox(height: 6),
        _colorRow(
          label: 'لون الاسم',
          selected: p.nameColor,
          onPick: (c) => _updateBubblePrefs(p.copyWith(nameColor: c)),
        ),
        _colorRow(
          label: 'لون المبلغ',
          selected: p.amountColor,
          onPick: (c) => _updateBubblePrefs(p.copyWith(amountColor: c)),
        ),
        _colorRow(
          label: 'لون العملة',
          selected: p.currencyColor,
          onPick: (c) => _updateBubblePrefs(p.copyWith(currencyColor: c)),
        ),
        Text(
          'اضغط «حفظ الإعدادات» لتطبيق التغييرات.',
          style: TextStyle(
            color: _mutedText(context),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildBubbleActionsSection() {
    const color = Colors.cyan;
    final scheme = Theme.of(context).colorScheme;
    final actions = settings!.bubbleQuickActions;
    final actionTypes = <String>[
      'appendZeros',
      'setName',
      'clearStage',
      'setCurrency',
    ];
    final iconKeys = <String>['zeros', 'person', 'clear', 'currency', 'flash'];

    return _sectionCard(
      icon: Icons.touch_app_rounded,
      title: 'أزرار الفقاعة',
      subtitle:
          'أزرار سريعة تظهر داخل BubbleScreen وتنفذ أوامر مثل إضافة أصفار، اعتماد اسم، مسح المختار، أو تغيير العملة.',
      color: color,
      count: actions.length,
      children: [
        if (actions.isEmpty)
          _emptyMessage('لا توجد أزرار مخصصة بعد.')
        else
          ...actions.map(
            (action) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withOpacity(.48),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: scheme.outlineVariant.withOpacity(.22),
                ),
              ),
              child: Row(
                children: [
                  _iconBubble(
                    context,
                    _bubbleActionIconData(action.iconKey),
                    color,
                    size: 38,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          action.label,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${_bubbleActionTitle(action.actionType)}${action.value.isEmpty ? '' : ' • ${action.value}'}',
                          style: TextStyle(
                            color: _mutedText(context),
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'حذف الزر',
                    onPressed: () => _deleteBubbleAction(action),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: _bubbleActionType,
          items: actionTypes
              .map(
                (type) => DropdownMenuItem(
                  value: type,
                  child: Text(_bubbleActionTitle(type)),
                ),
              )
              .toList(),
          onChanged: (value) =>
              setState(() => _bubbleActionType = value ?? _bubbleActionType),
          decoration: _inputDecoration(
            context,
            hint: 'نوع الزر',
            icon: Icons.rule_rounded,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 620;
            final labelField = TextField(
              controller: _bubbleActionLabelController,
              decoration: _inputDecoration(
                context,
                hint: 'نص الزر مثل: 00 أو اسم',
                icon: Icons.label_outline_rounded,
              ),
            );
            final valueField = TextField(
              controller: _bubbleActionValueController,
              decoration: _inputDecoration(
                context,
                hint: _bubbleActionType == 'appendZeros'
                    ? 'عدد الأصفار مثل: 2'
                    : _bubbleActionType == 'setCurrency'
                    ? 'اسم العملة مثل: دولار'
                    : _bubbleActionType == 'setName'
                    ? 'اتركها فارغة لعرض قائمة الأسماء الجاهزة'
                    : 'اتركها فارغة',
                icon: Icons.edit_note_rounded,
              ),
            );
            if (narrow) {
              return Column(
                children: [labelField, const SizedBox(height: 10), valueField],
              );
            }
            return Row(
              children: [
                Expanded(child: labelField),
                const SizedBox(width: 10),
                Expanded(child: valueField),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...iconKeys.map(
              (key) => ChoiceChip(
                selected: _bubbleActionIcon == key,
                label: Icon(_bubbleActionIconData(key), size: 18),
                onSelected: (_) => setState(() => _bubbleActionIcon = key),
              ),
            ),
            FilterChip(
              selected: _bubbleActionIconAbove,
              avatar: const Icon(Icons.vertical_align_top_rounded, size: 18),
              label: const Text('الأيقونة فوق'),
              onSelected: (value) =>
                  setState(() => _bubbleActionIconAbove = value),
            ),
            FilledButton.icon(
              onPressed: _safeAddBubbleAction,
              icon: const Icon(Icons.add_rounded),
              label: const Text('إضافة الزر'),
            ),
          ],
        ),
      ],
    );
  }

  TextEditingController _accountKeywordControllerFor(Account account) {
    return _accountKeywordCtrls.putIfAbsent(
      account.id,
      () => TextEditingController(),
    );
  }

  Future<void> _addKeywordToAccount(Account account) async {
    final ctrl = _accountKeywordControllerFor(account);
    final value = ctrl.text.trim();
    if (value.isEmpty) return;

    final exists = account.keywords.any(
      (e) => e.toLowerCase() == value.toLowerCase(),
    );
    if (exists) {
      _showSnack('الكلمة موجودة لهذا الحساب مسبقًا');
      return;
    }

    account.keywords = List<String>.from(account.keywords)..add(value);
    account.keywords.sort(_ci);
    await account.save();
    ctrl.clear();
    if (mounted) setState(() {});
  }

  Future<void> _deleteAccountKeyword(Account account, String word) async {
    final ok = await _confirm(
      'تأكيد الحذف',
      'حذف "$word" من كلمات حساب "${account.name}"؟',
    );
    if (!ok) return;

    account.keywords = List<String>.from(account.keywords)..remove(word);
    await account.save();
    if (mounted) setState(() {});
  }

  Widget _buildAccountKeywordsSection() {
    final accounts = DatabaseService.accountsBox.values.toList()
      ..sort((a, b) => _ci(a.name, b.name));
    final total = accounts.fold<int>(
      0,
      (sum, account) => sum + account.keywords.length,
    );
    const color = Colors.teal;
    final scheme = Theme.of(context).colorScheme;

    return _sectionCard(
      icon: Icons.manage_search_rounded,
      title: 'كلمات الحسابات',
      subtitle:
          'كلمات إضافية تساعد التطبيق على اختيار الحساب تلقائيًا عند لصق النص.',
      color: color,
      count: total,
      children: [
        if (accounts.isEmpty)
          _emptyMessage(
            'لا توجد حسابات بعد — أضف حسابًا أولًا.',
            icon: Icons.account_balance_wallet_rounded,
          ),
        ...accounts.map((account) {
          final ctrl = _accountKeywordControllerFor(account);

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withOpacity(.48),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: scheme.outlineVariant.withOpacity(.20)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _iconBubble(
                      context,
                      Icons.account_circle_rounded,
                      color,
                      size: 38,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${account.keywords.length} كلمة مخصصة',
                            style: TextStyle(
                              color: _mutedText(context),
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _chipWrap(
                  list: account.keywords,
                  color: color,
                  onDelete: (word) => _deleteAccountKeyword(account, word),
                ),
                const SizedBox(height: 12),
                _addRow(
                  hint: 'أدخل كلمة أو اسم مختصر يدل على هذا الحساب',
                  controller: ctrl,
                  icon: Icons.add_link_rounded,
                  onAdd: () => _addKeywordToAccount(account),
                ),
              ],
            ),
          );
        }).toList(),
      ],
    );
  }

  // ===== واجهة العملات (تجميع حسب الاسم المعروض) =====
  Widget _buildCurrenciesGroupedSection() {
    final scheme = Theme.of(context).colorScheme;
    final grouped = _groupedByName();
    const color = Colors.deepPurple;

    return _sectionCard(
      icon: Icons.currency_exchange_rounded,
      title: 'العملات',
      subtitle: 'كل مجموعة تحتوي على عدة اختصارات أو أسماء تُعامل كعملة واحدة.',
      color: color,
      count: grouped.length,
      headerActions: [
        _modernIconButton(
          tooltip: 'إضافة مجموعة عملات شائعة',
          onPressed: _addCommonCurrencies,
          icon: Icons.playlist_add_rounded,
          color: color,
        ),
      ],
      children: [
        if (grouped.isEmpty)
          _emptyMessage(
            'لا توجد عملات بعد — أضف من الأسفل.',
            icon: Icons.currency_exchange_rounded,
          ),
        ...grouped.entries.map((entry) {
          final displayName = entry.key;
          final aliases = entry.value;
          final ctrl = _aliasCtrls.putIfAbsent(
            displayName,
            () => TextEditingController(),
          );

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withOpacity(.48),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: scheme.outlineVariant.withOpacity(.20)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _iconBubble(
                      context,
                      Icons.account_balance_wallet_rounded,
                      color,
                      size: 38,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${aliases.length} اختصار / اسم',
                            style: TextStyle(
                              color: _mutedText(context),
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _modernIconButton(
                      tooltip: 'إعادة تسمية الاسم المعروض',
                      onPressed: () => _renameDisplayName(displayName),
                      icon: Icons.edit_rounded,
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 6),
                    _modernIconButton(
                      tooltip: 'حذف المجموعة كاملة',
                      onPressed: () => _deleteGroup(displayName),
                      icon: Icons.delete_forever_rounded,
                      color: Colors.red,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _chipWrap(
                  list: aliases,
                  color: color,
                  onDelete: (alias) => _deleteAlias(alias, displayName),
                ),
                const SizedBox(height: 12),
                _addRow(
                  hint: 'أدخل اختصار/اسم إضافي لهذه العملة',
                  controller: ctrl,
                  icon: Icons.add_link_rounded,
                  onAdd: () => _addAliasToDisplayName(displayName),
                ),
              ],
            ),
          );
        }).toList(),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _softColor(context, color),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: color.withOpacity(.14)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.add_circle_outline_rounded, color: color),
                  const SizedBox(width: 8),
                  Text(
                    'إضافة عملة/مجموعة جديدة',
                    style: TextStyle(color: color, fontWeight: FontWeight.w900),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 620;

                  final aliasField = TextField(
                    controller: _currencyKeyController,
                    textInputAction: TextInputAction.next,
                    decoration: _inputDecoration(
                      context,
                      hint: 'اختصار/اسم مثل: QAR أو ﷼ أو ريال',
                      icon: Icons.alternate_email_rounded,
                    ),
                  );

                  final displayField = TextField(
                    controller: _currencyValueController,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => setState(_safeAddCurrency),
                    decoration: _inputDecoration(
                      context,
                      hint: 'الاسم المعروض مثال: ريال قطري',
                      icon: Icons.label_important_outline_rounded,
                    ),
                  );

                  final addButton = FilledButton.icon(
                    onPressed: () => setState(_safeAddCurrency),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('إضافة'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  );

                  if (narrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        aliasField,
                        const SizedBox(height: 10),
                        displayField,
                        const SizedBox(height: 10),
                        addButton,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(flex: 4, child: aliasField),
                      const SizedBox(width: 10),
                      Expanded(flex: 5, child: displayField),
                      const SizedBox(width: 10),
                      addButton,
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _noteBox() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withOpacity(.55),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant.withOpacity(.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lightbulb_outline_rounded,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'ملاحظة: كل اختصار/اسم (Alias) تحت نفس الاسم المعروض يُعامل كعملة واحدة أثناء التحليل.',
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                height: 1.45,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (settings == null) {
      return const Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _pageBg(context),
        appBar: AppBar(
          title: const Text('الإعدادات'),
          centerTitle: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: _pageBg(context),
          actions: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: IconButton.filledTonal(
                tooltip: 'حفظ',
                onPressed: _saveSettings,
                icon: const Icon(Icons.save_rounded),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            decoration: BoxDecoration(
              color: _pageBg(context).withOpacity(.96),
              border: Border(
                top: BorderSide(color: scheme.outlineVariant.withOpacity(.18)),
              ),
            ),
            child: FilledButton.icon(
              onPressed: _saveSettings,
              icon: const Icon(Icons.save_rounded),
              label: const Text('حفظ الإعدادات'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 18),
          children: [
            _heroHeader(),
            _buildKeywordSection(
              'كلمات الاسم',
              settings!.nameKeywords,
              _nameController,
              icon: Icons.person_search_rounded,
              color: Colors.blue,
              subtitle:
                  'الكلمات التي تساعد التطبيق على معرفة اسم المستفيد أو المستلم.',
              addHint: 'أدخل كلمة تخص الاسم مثل: المستفيد',
            ),
            _buildKeywordSection(
              'كلمات المبلغ',
              settings!.amountKeywords,
              _amountController,
              icon: Icons.numbers_rounded,
              color: Colors.green,
              subtitle:
                  'الكلمات التي تُستخدم لاكتشاف قيمة المبلغ أثناء التحليل.',
              addHint: 'أدخل كلمة تخص المبلغ مثل: المبلغ، السعر، .',
              headerActions: [
                _modernIconButton(
                  tooltip: 'إضافة كلمات شائعة',
                  onPressed: _addAmountKeywordPresets,
                  icon: Icons.playlist_add_rounded,
                  color: Colors.green,
                ),
              ],
            ),
            _buildAmountWordValuesSection(),
            _buildKeywordSection(
              'كلمات الإلغاء',
              settings!.cancelKeywords,
              _cancelController,
              icon: Icons.cancel_schedule_send_rounded,
              color: Colors.pink,
              subtitle:
                  'إذا ظهرت إحدى هذه الكلمات داخل رسالة، ستُعامل الفقاعة كعملية إلغاء.',
              addHint: 'أدخل كلمة إلغاء مثل: الغاء، إلغاء، ملغي',
            ),
            _buildKeywordSection(
              'الأسماء الجاهزة',
              settings!.bubbleReadyNames,
              _readyNameController,
              icon: Icons.person_pin_circle_rounded,
              color: Colors.blueGrey,
              subtitle:
                  'أسماء محفوظة يمكن استخدامها من أزرار الفقاعة بدل كتابتها كل مرة.',
              addHint: 'أدخل اسمًا جاهزًا',
            ),
            _buildKeywordSection(
              'أسماء مستخدمي الشركة',
              settings!.companyUserNames,
              _companyUserNameController,
              icon: Icons.group_rounded,
              color: Colors.deepPurple,
              subtitle:
                  'في BubbleScreen: إذا كان مرسل الرسالة موجودًا هنا تُسجّل الحركة مرسلة، وإلا تُسجّل حركة استقبال. ويمكن تعديل النوع يدويًا قبل الحفظ.',
              addHint: 'أدخل اسم المستخدم كما يظهر في الرسائل',
            ),
            _buildBubbleActionsSection(),
            _buildBubbleCustomizationSection(),
            _buildKeywordSection(
              'الكلمات الممنوعة',
              settings!.forbiddenWords,
              _forbiddenController,
              icon: Icons.block_rounded,
              color: Colors.deepOrange,
              subtitle:
                  'كلمات لا يمكن أن تكون جزءًا من الاسم: يتوقف عندها تحديد الاسم، وإذا انتهى بها سطر فإن السطر الذي يليه لا يُعتبر اسم المستفيد (مثل: المرسل).',
              addHint: 'أدخل كلمة ممنوعة مثل: المرسل',
            ),
            _buildKeywordSection(
              'الجمل الممنوعة',
              settings!.forbiddenPhrases,
              _forbiddenPhraseController,
              icon: Icons.gpp_bad_rounded,
              color: Colors.red.shade700,
              subtitle:
                  'إذا ظهرت جملة من هذه القائمة داخل رسالة يتم تمييزها بوضوح في الفقاعات والتنبيه عليها قبل الحفظ.',
              addHint: 'أدخل جملة ممنوعة مثل: لا تسلم',
            ),
            _buildKeywordSection(
              'الكلمات المهملة',
              settings!.ignoredWords,
              _ignoredController,
              icon: Icons.visibility_off_rounded,
              color: Colors.orange,
              subtitle: 'أي كلمة هنا سيتم تجاهلها أثناء قراءة وتحليل الحركة.',
              addHint: 'أدخل كلمة لتجاهلها أثناء التحليل',
            ),
            _buildKeywordSection(
              'كلمات تجاهل السطر كاملًا',
              settings!.lineIgnoredWords,
              _lineIgnoredController,
              icon: Icons.block_rounded,
              color: Colors.red,
              subtitle:
                  'إذا ظهرت كلمة من هذه القائمة في السطر سيتم تجاهل السطر كاملًا.',
              addHint: 'إذا وُجدت الكلمة في السطر، يتم تجاهل السطر كاملًا',
            ),
            _buildAccountKeywordsSection(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: FilledButton.tonalIcon(
                onPressed: _showCurrencySplitDialog,
                icon: const Icon(Icons.calculate_rounded),
                label: const Text('تقسيم الحركات المسجّلة حسب العملة'),
              ),
            ),
            _buildCurrenciesGroupedSection(),
            _noteBox(),
          ],
        ),
      ),
    );
  }
}
