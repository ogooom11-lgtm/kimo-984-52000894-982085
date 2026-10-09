// lib/screens/settings_screen.dart
// -------------------------------------------------------------
// صفحة الإعدادات: العملات والوجهات. الحفظ تلقائي بعد كل تعديل، والحذف
// يمكن التراجع عنه من الإشعار.
// -------------------------------------------------------------

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/destinations.dart';
import '../widgets/destination_picker.dart' show kDestColor;

const _kGreen = Color(0xFF10B981);
const _kPurple = Color(0xFF8B5CF6);
const _kTeal = Color(0xFF14B8A6);

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = _SettingsStore()..attach();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.dispose();
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
    if (mounted) setState(() {});
  }

  List<_HubGroup> _buildGroups() {
    final currencies = _store.currencyNames();
    final dests = _store.destinationBook;

    return [
      _HubGroup(
        title: 'العملات',
        icon: Icons.payments_rounded,
        tiles: [
          _HubTile(
            icon: Icons.currency_exchange_rounded,
            color: _kPurple,
            title: 'العملات',
            subtitle: currencies.isEmpty
                ? 'لا توجد عملات'
                : currencies.take(4).join('، ') +
                      (currencies.length > 4 ? '…' : ''),
            count: currencies.length,
            onTap: () => _open(_CurrenciesPage(store: _store)),
          ),
          _HubTile(
            icon: Icons.percent_rounded,
            color: _kTeal,
            title: 'تقسيم الحركات حسب العملة',
            onTap: () => _openSplitTool(context, _store),
          ),
        ],
      ),
      _HubGroup(
        title: 'الوجهات',
        icon: Icons.place_rounded,
        tiles: [
          _HubTile(
            icon: Icons.place_rounded,
            color: kDestColor,
            title: 'الوجهات',
            subtitle: dests.isEmpty
                ? 'لا توجد وجهات'
                : dests.names.take(4).join('، ') +
                      (dests.items.length > 4 ? '…' : ''),
            count: dests.isEmpty ? null : dests.items.length,
            onTap: () => _open(_DestinationsPage(store: _store)),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop ?? false;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _store.flush();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: _pageBg(context),
          body: SafeArea(
            bottom: false,
            child: ListenableBuilder(
              listenable: _store,
              builder: (context, _) {
                final groups = _buildGroups();
                return ListView(
                  padding: EdgeInsets.fromLTRB(16, canPop ? 4 : 14, 16, 130),
                  children: [
                    _HubHeader(saving: _store.isSaving, showBack: canPop),
                    const SizedBox(height: 22),
                    for (final g in groups) ...[
                      _GroupLabel(title: g.title, icon: g.icon),
                      _GroupCard(tiles: g.tiles),
                      const SizedBox(height: 22),
                    ],
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
    : settings = _copyOf(DatabaseService.getSettings() ?? _defaults());

  /// نسخة قابلة للتعديل من الإعدادات (تُحفظ تلقائيًا بعد كل تعديل)
  Settings settings;

  Timer? _saveTimer;
  bool _writing = false;
  bool _disposed = false;
  Listenable? _boxListenable;

  bool get isSaving => _writing || (_saveTimer?.isActive ?? false);

  static Settings _defaults() => Settings(
    nameKeywords: [],
    amountKeywords: [],
    currencyMap: {r'$': 'دولار'},
    ignoredWords: [],
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
    bubbleQuickActions: s.bubbleQuickActions.map((a) => a.copy()).toList(),
    forbiddenWords: List<String>.from(s.forbiddenWords),
    forbiddenPhrases: List<String>.from(s.forbiddenPhrases),
    bubbleUiPrefs: Map<String, dynamic>.from(s.bubbleUiPrefs),
    destinationMap: Map<String, String>.from(s.destinationMap),
    destinationInfo: {
      for (final e in s.destinationInfo.entries)
        e.key: e.value is Map
            ? Map<String, dynamic>.from(e.value as Map)
            : <String, dynamic>{'office': false},
    },
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
      // تغيّرت الإعدادات من مكان آخر (مثل إضافة وجهة من صفحة الحركة):
      // نعيد تحميلها حتى لا نكتب فوقها بنسخة قديمة.
      settings = _copyOf(stored);
    }
    notifyListeners();
  }

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

  static bool _same(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  // ---------------- العملات ----------------

  /// أسماء العملات (بدون تكرار)
  List<String> currencyNames() =>
      settings.currencyMap.values
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort(_ci);

  String? _currencyOwnerOf(String text) {
    for (final e in settings.currencyMap.entries) {
      if (_same(e.key, text) || _same(e.value, text)) return e.value.trim();
    }
    return null;
  }

  /// يضيف عملة جديدة. يعيد رسالة خطأ أو null.
  String? addCurrency(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'أدخل اسم العملة';
    final owner = _currencyOwnerOf(n);
    if (owner != null) return '«$owner» موجودة مسبقًا';
    settings.currencyMap[n] = n;
    changed();
    return null;
  }

  /// يعيد تسمية العملة. يعيد رسالة خطأ أو null.
  String? renameCurrency(String oldName, String newName) {
    final v = newName.trim();
    if (v.isEmpty || v == oldName) return null;
    final owner = _currencyOwnerOf(v);
    if (owner != null && owner != oldName) return '«$owner» موجودة مسبقًا';
    final keys = settings.currencyMap.entries
        .where((e) => e.value.trim() == oldName)
        .map((e) => e.key)
        .toList();
    for (final k in keys) {
      settings.currencyMap[k] = v;
    }
    changed();
    return null;
  }

  /// يحذف العملة ويعيد ما حُذف (للتراجع).
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

  void restoreCurrency(Map<String, String> entries) {
    if (entries.isEmpty) return;
    settings.currencyMap.addAll(entries);
    changed();
  }

  /// يضيف العملات الشائعة. يعيد عدد العملات المضافة.
  int addCommonCurrencies() {
    const common = [
      'دولار',
      'يورو',
      'ريال قطري',
      'ليرة تركية',
      'ليرة سورية',
      'جنيه',
      'جنيه مصري',
    ];
    var added = 0;
    for (final name in common) {
      if (_currencyOwnerOf(name) == null) {
        settings.currencyMap[name] = name;
        added++;
      }
    }
    if (added > 0) changed();
    return added;
  }

  // ---------------- الوجهات ----------------

  DestinationBook get destinationBook => DestinationBook.fromSettings(settings);

  /// يضيف وجهة جديدة. يعيد رسالة خطأ أو null.
  String? addDestination(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'أدخل اسم الوجهة';
    final owner = destinationBook.byName(n);
    if (owner != null) return '«${owner.name}» موجودة مسبقًا';
    settings.destinationInfo[n] = <String, dynamic>{};
    changed();
    return null;
  }

  /// يعيد تسمية الوجهة. يعيد رسالة خطأ أو null.
  String? renameDestination(String oldName, String newName) {
    final v = newName.trim();
    if (v.isEmpty || v == oldName) return null;
    final owner = destinationBook.byName(v);
    if (owner != null && owner.key != destinationKey(oldName)) {
      return '«${owner.name}» موجودة مسبقًا';
    }
    final raw = settings.destinationInfo.remove(oldName);
    settings.destinationInfo[v] = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    final keys = settings.destinationMap.entries
        .where((e) => e.value.trim() == oldName)
        .map((e) => e.key)
        .toList();
    for (final k in keys) {
      settings.destinationMap[k] = v;
    }
    settings.destinationMap.removeWhere(
      (k, value) => destinationKey(k) == destinationKey(v),
    );
    changed();
    return null;
  }

  /// يحذف الوجهة ويعيد ما حُذف (للتراجع).
  (Map<String, dynamic>, Map<String, String>) deleteDestination(String name) {
    final info = <String, dynamic>{};
    final raw = settings.destinationInfo.remove(name);
    if (raw != null) info[name] = raw;
    final aliases = <String, String>{};
    settings.destinationMap.removeWhere((k, v) {
      if (v.trim() != name) return false;
      aliases[k] = v;
      return true;
    });
    changed();
    return (info, aliases);
  }

  void restoreDestination((Map<String, dynamic>, Map<String, String>) data) {
    settings.destinationInfo.addAll(data.$1);
    settings.destinationMap.addAll(data.$2);
    changed();
  }
}

// =============================================================
// صفحة العملات
// =============================================================

class _CurrenciesPage extends StatelessWidget {
  final _SettingsStore store;

  const _CurrenciesPage({required this.store});

  Future<void> _add(BuildContext context) async {
    final v = await _promptText(
      context,
      title: 'إضافة عملة',
      hint: 'اسم العملة',
      icon: Icons.payments_rounded,
      confirmLabel: 'إضافة',
    );
    if (v == null || !context.mounted) return;
    final error = store.addCurrency(v);
    if (error != null) _snack(context, error);
  }

  void _addCommon(BuildContext context) {
    final added = store.addCommonCurrencies();
    _snack(
      context,
      added == 0 ? 'العملات الشائعة موجودة كلها' : 'أُضيفت $added عملة',
    );
  }

  Future<void> _rename(BuildContext context, String name) async {
    final v = await _promptText(
      context,
      title: 'إعادة تسمية العملة',
      initial: name,
      hint: 'اسم العملة',
    );
    if (v == null || !context.mounted) return;
    final error = store.renameCurrency(name, v);
    if (error != null) _snack(context, error);
  }

  Future<void> _delete(BuildContext context, String name) async {
    final ok = await _confirm(
      context,
      title: 'حذف العملة',
      message: 'حذف «$name»؟',
      confirmLabel: 'حذف',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    final removed = store.deleteCurrency(name);
    _snack(
      context,
      'حُذفت عملة «$name»',
      onUndo: () => store.restoreCurrency(removed),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SubPageScaffold(
      store: store,
      title: 'العملات',
      actions: [
        IconButton(
          tooltip: 'إضافة العملات الشائعة',
          onPressed: () => _addCommon(context),
          icon: const Icon(Icons.playlist_add_rounded),
        ),
      ],
      builder: (context) {
        final names = store.currencyNames();
        return [
          FilledButton.tonalIcon(
            onPressed: () => _add(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة عملة'),
          ),
          const SizedBox(height: 18),
          _SectionTitle(text: 'العملات (${names.length})'),
          if (names.isEmpty)
            const _EmptyHint(
              icon: Icons.currency_exchange_rounded,
              color: _kPurple,
              text: 'لا توجد عملات',
            )
          else
            _NameList(
              names: names,
              icon: Icons.payments_rounded,
              color: _kPurple,
              onRename: (n) => _rename(context, n),
              onDelete: (n) => _delete(context, n),
            ),
        ];
      },
    );
  }
}

// =============================================================
// صفحة الوجهات
// =============================================================

class _DestinationsPage extends StatelessWidget {
  final _SettingsStore store;

  const _DestinationsPage({required this.store});

  Future<void> _add(BuildContext context) async {
    final v = await _promptText(
      context,
      title: 'إضافة وجهة',
      hint: 'اسم الوجهة',
      icon: Icons.place_rounded,
      confirmLabel: 'إضافة',
    );
    if (v == null || !context.mounted) return;
    final error = store.addDestination(v);
    if (error != null) _snack(context, error);
  }

  Future<void> _rename(BuildContext context, String name) async {
    final v = await _promptText(
      context,
      title: 'إعادة تسمية الوجهة',
      initial: name,
      hint: 'اسم الوجهة',
    );
    if (v == null || !context.mounted) return;
    final error = store.renameDestination(name, v);
    if (error != null) _snack(context, error);
  }

  Future<void> _delete(BuildContext context, String name) async {
    final ok = await _confirm(
      context,
      title: 'حذف الوجهة',
      message: 'حذف «$name»؟',
      confirmLabel: 'حذف',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    final removed = store.deleteDestination(name);
    _snack(
      context,
      'حُذفت «$name»',
      onUndo: () => store.restoreDestination(removed),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SubPageScaffold(
      store: store,
      title: 'الوجهات',
      builder: (context) {
        final names = store.destinationBook.names;
        return [
          FilledButton.tonalIcon(
            onPressed: () => _add(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة وجهة'),
          ),
          const SizedBox(height: 18),
          _SectionTitle(text: 'الوجهات (${names.length})'),
          if (names.isEmpty)
            const _EmptyHint(
              icon: Icons.place_rounded,
              color: kDestColor,
              text: 'لا توجد وجهات',
            )
          else
            _NameList(
              names: names,
              icon: Icons.place_rounded,
              color: kDestColor,
              onRename: (n) => _rename(context, n),
              onDelete: (n) => _delete(context, n),
            ),
        ];
      },
    );
  }
}

/// قائمة أسماء (عملات/وجهات) مع إعادة تسمية وحذف
class _NameList extends StatelessWidget {
  final List<String> names;
  final IconData icon;
  final Color color;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onDelete;

  const _NameList({
    required this.names,
    required this.icon,
    required this.color,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < names.length; i++) ...[
            if (i > 0) const _ListDivider(indent: 66),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 6, 8),
              child: Row(
                children: [
                  _IconBadge(icon: icon, color: color, size: 38),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      names[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  _SmallIconButton(
                    icon: Icons.edit_rounded,
                    tooltip: 'إعادة تسمية',
                    onPressed: () => onRename(names[i]),
                  ),
                  _SmallIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'حذف',
                    color: cs.error,
                    onPressed: () => onDelete(names[i]),
                  ),
                ],
              ),
            ),
          ],
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
    for (final tx in matching) {
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

Color _fg(BuildContext context, Color c) => _isDark(context)
    ? Color.lerp(c, Colors.white, .25)!
    : Color.lerp(c, Colors.black, .10)!;

Color _tint(
  BuildContext context,
  Color c, {
  double light = .12,
  double dark = .20,
}) => c.withValues(alpha: _isDark(context) ? dark : light);

int _ci(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

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
  final List<Widget> actions;
  final List<Widget> Function(BuildContext context) builder;

  const _SubPageScaffold({
    required this.store,
    required this.title,
    required this.builder,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final bg = _pageBg(context);

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
          listenable: store,
          builder: (context, _) => ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              16,
              6,
              16,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            children: builder(context),
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
  final String? subtitle;
  final int? count;
  final VoidCallback onTap;

  const _HubTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.count,
  });
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
          child: Text(
            'الإعدادات',
            style: TextStyle(
              fontSize: 28,
              height: 1.2,
              fontWeight: FontWeight.w900,
              color: cs.onSurface,
            ),
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
    final subtitle = tile.subtitle;
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
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        color: _muted(context),
                      ),
                    ),
                  ],
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

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w800,
          color: _muted(context),
        ),
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
