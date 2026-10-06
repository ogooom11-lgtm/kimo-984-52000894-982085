// lib/screens/all_stats_customize_screen.dart
// -------------------------------------------------------------
// تخصيص صفحة «إحصائيات كل الحسابات»:
//  • الأقسام: الترتيب (سحب)، الإظهار، الاسم، اللون — لكل نوع حسابات.
//  • الحسابات: إخفاء حسابات + ترتيب يدوي (سحب).
//  • الملخص السريع: الحسابات جوّا البطاقات، المبالغ، التغيّر، الأصفار.
//  • الشكل: الأعمدة، الحجم، الهيدر والبطاقات.
//  • العنوان والتصدير.
// كل تغيير بينحفظ فورًا وبيبين بالصفحة.
// -------------------------------------------------------------

import 'dart:async';

import 'package:flutter/material.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/all_stats_prefs.dart';

class AllStatsCustomizeScreen extends StatefulWidget {
  final AccountType initialType;

  const AllStatsCustomizeScreen({
    super.key,
    this.initialType = AccountType.office,
  });

  @override
  State<AllStatsCustomizeScreen> createState() =>
      _AllStatsCustomizeScreenState();
}

class _AllStatsCustomizeScreenState extends State<AllStatsCustomizeScreen> {
  late AccountType _type = widget.initialType;
  late final TextEditingController _title = TextEditingController(
    text: AllStatsPrefsStore.load().title,
  );
  Timer? _titleDebounce;

  AllStatsPrefs get _p => AllStatsPrefsStore.prefs.value;

  void _save(AllStatsPrefs p) {
    AllStatsPrefsStore.save(p);
    setState(() {});
  }

  @override
  void dispose() {
    _titleDebounce?.cancel();
    final t = _title.text.trim();
    if (t != _p.title) {
      // بعد ما يخلص الإطار الحالي (الشجرة مقفولة أثناء dispose)
      Future.microtask(
        () => AllStatsPrefsStore.save(
          AllStatsPrefsStore.prefs.value.copyWith(title: t),
        ),
      );
    }
    _title.dispose();
    super.dispose();
  }

  void _onTitleChanged(String _) {
    _titleDebounce?.cancel();
    _titleDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final t = _title.text.trim();
      if (t != _p.title) _save(_p.copyWith(title: t));
    });
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('رجوع للافتراضي؟'),
          content: const Text(
            'كل التخصيص (الأقسام، الألوان، الأسماء، الحسابات المخفية والترتيب '
            'والشكل) بيرجع متل الأول.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('رجوع للافتراضي'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    _titleDebounce?.cancel();
    _title.text = '';
    final p = _p;
    // الفترة ونوع الحسابات الحاليين بيضلّوا
    _save(AllStatsPrefs(period: p.period, accountType: p.accountType));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('تم الرجوع للإعدادات الافتراضية')),
      );
  }

  // ==========================
  // أدوات مشتركة
  // ==========================

  Widget _section({
    required String title,
    required IconData icon,
    String? hint,
    required List<Widget> children,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 19, color: cs.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _switch({
    required String title,
    String? subtitle,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      secondary: Icon(icon, color: value ? cs.primary : cs.onSurfaceVariant),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: const TextStyle(fontSize: 12.5)),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _choice<T>({
    required String title,
    required IconData icon,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T> onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: cs.onSurfaceVariant),
              const SizedBox(width: 14),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<T>(
            showSelectedIcon: false,
            segments: [
              for (final e in options.entries)
                ButtonSegment<T>(value: e.key, label: Text(e.value)),
            ],
            selected: {value},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ],
      ),
    );
  }

  // ==========================
  // نوع الحسابات + المعاينة
  // ==========================

  Widget _typeSwitch() {
    return SegmentedButton<AccountType>(
      segments: const [
        ButtonSegment(
          value: AccountType.office,
          icon: Icon(Icons.account_balance_wallet_rounded),
          label: Text('حسابات المكاتب'),
        ),
        ButtonSegment(
          value: AccountType.company,
          icon: Icon(Icons.business_rounded),
          label: Text('حسابات الشركات'),
        ),
      ],
      selected: {_type},
      onSelectionChanged: (s) => setState(() => _type = s.first),
    );
  }

  Widget _preview(AllStatsPrefs p) {
    final cs = Theme.of(context).colorScheme;
    final metrics = p.visibleMetrics(_type);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'معاينة: ${p.title.isEmpty ? 'إحصائيات ${_type.label}' : p.title}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: cs.onSurfaceVariant,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 8),
          if (metrics.isEmpty)
            Text(
              'كل الأقسام مخفية — فعّل قسم واحد على الأقل.',
              style: TextStyle(color: Colors.orange.shade800),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in metrics)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: p.compact ? 10 : 12,
                      vertical: p.compact ? 7 : 9,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                        colors: p.gradientOf(m, _type),
                      ),
                      borderRadius: BorderRadius.circular(p.compact ? 12 : 16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          statsMetricIcon(m, company: _type.isCompany),
                          color: Colors.white,
                          size: 17,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          p.labelOf(m, _type),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ==========================
  // الأقسام
  // ==========================

  List<Widget> _metricsSection(AllStatsPrefs p) {
    final list = p.metricsFor(_type);
    return [
      ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorder: (oldIndex, newIndex) {
          final next = [...list];
          if (newIndex > oldIndex) newIndex -= 1;
          next.insert(newIndex, next.removeAt(oldIndex));
          _save(p.withMetrics(_type, next));
        },
        children: [
          for (var i = 0; i < list.length; i++) _metricTile(p, list[i], i),
        ],
      ),
    ];
  }

  Widget _metricTile(AllStatsPrefs p, StatsMetricPref m, int index) {
    final cs = Theme.of(context).colorScheme;
    final company = _type.isCompany;
    final label = p.labelOf(m.metric, _type);
    final original = statsDefaultLabel(m.metric, company: company);
    return Padding(
      key: ValueKey('metric_${_type.name}_${m.metric.name}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 14,
                ),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            Tooltip(
              message: 'تغيير اللون',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _pickColor(p, m),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                      colors: p.gradientOf(m.metric, _type),
                    ),
                  ),
                  child: Icon(
                    statsMetricIcon(m.metric, company: company),
                    color: Colors.white,
                    size: 19,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _rename(p, m),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: m.visible ? null : cs.onSurfaceVariant,
                                decoration: m.visible
                                    ? null
                                    : TextDecoration.lineThrough,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.edit_rounded,
                            size: 14,
                            color: cs.onSurfaceVariant,
                          ),
                        ],
                      ),
                      Text(
                        m.label.isNotEmpty
                            ? 'الاسم الأصلي: $original'
                            : (m.visible ? 'ظاهر' : 'مخفي'),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Switch(
              value: m.visible,
              onChanged: (v) => _save(
                p.updateMetric(_type, m.metric, (x) => x.copyWith(visible: v)),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Future<void> _pickColor(AllStatsPrefs p, StatsMetricPref m) async {
    final current = p.colorIndexOf(m.metric, _type);
    final original = statsDefaultColor(m.metric, company: _type.isCompany);
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'لون «${p.labelOf(m.metric, _type)}»',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var i = 0; i < kStatsPalette.length; i++)
                        InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.pop(ctx, i),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    begin: Alignment.topRight,
                                    end: Alignment.bottomLeft,
                                    colors: kStatsPalette[i].colors,
                                  ),
                                  border: Border.all(
                                    color: i == current
                                        ? cs.onSurface
                                        : Colors.transparent,
                                    width: 3,
                                  ),
                                ),
                                child: i == current
                                    ? const Icon(
                                        Icons.check_rounded,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                i == original
                                    ? '${kStatsPalette[i].name} (الأصلي)'
                                    : kStatsPalette[i].name,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    _save(
      p.updateMetric(
        _type,
        m.metric,
        (x) => x.copyWith(color: picked == original ? -1 : picked),
      ),
    );
  }

  Future<void> _rename(AllStatsPrefs p, StatsMetricPref m) async {
    final original = statsDefaultLabel(m.metric, company: _type.isCompany);
    final ctrl = TextEditingController(text: p.labelOf(m.metric, _type));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('اسم القسم'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (v) => Navigator.pop(ctx, v),
            decoration: InputDecoration(
              helperText: 'الاسم الأصلي: $original',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('الاسم الأصلي'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (result == null || !mounted) return;
    var label = result.trim();
    if (label == original) label = '';
    _save(p.updateMetric(_type, m.metric, (x) => x.copyWith(label: label)));
  }

  // ==========================
  // الحسابات
  // ==========================

  List<Widget> _accountsSection(AllStatsPrefs p) {
    final cs = Theme.of(context).colorScheme;
    final accounts = DatabaseService.accountsBox.values
        .where((a) => a.type == _type)
        .toList();
    if (accounts.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            'ما في حسابات من هالنوع بعد.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ];
    }
    final order = p.orderFor(_type);
    accounts.sort((a, b) {
      final ia = order.indexOf(a.id);
      final ib = order.indexOf(b.id);
      if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
      if (ia >= 0) return -1;
      if (ib >= 0) return 1;
      return a.name.compareTo(b.name);
    });
    final manual = p.sortMode == AccountSortMode.manual;
    final ids = [for (final a in accounts) a.id];
    final hiddenCount = ids.where(p.isHidden).length;
    return [
      _switch(
        title: 'ترتيب يدوي',
        subtitle: manual
            ? 'الحسابات بتنعرض بالترتيب يلي تحت — اسحب ⠿ لتغييره'
            : 'فعّلها لتعرض الحسابات بالترتيب يلي بتختاره',
        icon: Icons.low_priority_rounded,
        value: manual,
        onChanged: (v) => _save(
          p.copyWith(
            sortMode: v ? AccountSortMode.manual : AccountSortMode.priority,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'ظاهر ${ids.length - hiddenCount} من ${ids.length}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: hiddenCount == 0
                  ? null
                  : () => _save(
                      p.copyWith(
                        hiddenAccounts: Set.unmodifiable(
                          p.hiddenAccounts.difference(ids.toSet()),
                        ),
                      ),
                    ),
              child: const Text('إظهار الكل'),
            ),
            TextButton(
              onPressed: order.isEmpty
                  ? null
                  : () => _save(p.withOrder(_type, const [])),
              child: const Text('ترتيب أبجدي'),
            ),
          ],
        ),
      ),
      ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorder: (oldIndex, newIndex) {
          final next = [...ids];
          if (newIndex > oldIndex) newIndex -= 1;
          next.insert(newIndex, next.removeAt(oldIndex));
          var np = p.withOrder(_type, next);
          if (np.sortMode != AccountSortMode.manual) {
            np = np.copyWith(sortMode: AccountSortMode.manual);
          }
          _save(np);
        },
        children: [
          for (var i = 0; i < accounts.length; i++)
            _accountTile(p, accounts[i], i),
        ],
      ),
    ];
  }

  Widget _accountTile(AllStatsPrefs p, Account a, int index) {
    final cs = Theme.of(context).colorScheme;
    final hidden = p.isHidden(a.id);
    return Padding(
      key: ValueKey('acc_${a.id}'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: hidden
            ? cs.surfaceContainerHighest.withValues(alpha: .35)
            : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: hidden ? cs.onSurfaceVariant : null,
                  decoration: hidden ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            IconButton(
              tooltip: hidden ? 'إظهار' : 'إخفاء',
              onPressed: () => _save(p.withAccountHidden(a.id, !hidden)),
              icon: Icon(
                hidden
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: hidden ? cs.onSurfaceVariant : cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================
  // البناء
  // ==========================

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _p;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تخصيص الإحصائيات'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'رجوع للافتراضي',
              onPressed: _confirmReset,
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _typeSwitch(),
            const SizedBox(height: 12),
            _preview(p),
            const SizedBox(height: 16),
            _section(
              title: 'الأقسام',
              icon: Icons.view_agenda_rounded,
              hint:
                  'اسحب ⠿ لتغيير الترتيب، واضغط على الدائرة لتغيير اللون أو '
                  'على الاسم لتغييره. الإعداد لـ${_type.isCompany ? 'حسابات الشركات' : 'حسابات المكاتب'}.',
              children: _metricsSection(p),
            ),
            _section(
              title: 'الحسابات',
              icon: Icons.account_balance_wallet_rounded,
              hint:
                  'الحساب المخفي ما بيبين بالصفحة وما بينحسب بالمجاميع '
                  '(بيضل موجود بالبرنامج عادي).',
              children: _accountsSection(p),
            ),
            _section(
              title: 'الملخص السريع',
              icon: Icons.space_dashboard_rounded,
              children: [
                _switch(
                  title: 'إظهار الملخص السريع',
                  subtitle: 'البطاقات الكبيرة بأعلى الصفحة',
                  icon: Icons.space_dashboard_rounded,
                  value: p.showQuickStats,
                  onChanged: (v) => _save(p.copyWith(showQuickStats: v)),
                ),
                _switch(
                  title: 'الحسابات جوّا البطاقات',
                  subtitle: 'أسماء الحسابات مع عددها بكل بطاقة',
                  icon: Icons.format_list_bulleted_rounded,
                  value: p.showAccountsInQuick,
                  onChanged: (v) => _save(p.copyWith(showAccountsInQuick: v)),
                ),
                if (p.showAccountsInQuick)
                  _choice<int>(
                    title: 'كم حساب بكل بطاقة',
                    icon: Icons.filter_list_rounded,
                    value: p.quickAccountsLimit,
                    options: const {0: 'الكل', 3: '3', 5: '5', 10: '10'},
                    onChanged: (v) => _save(p.copyWith(quickAccountsLimit: v)),
                  ),
                _switch(
                  title: 'المبالغ حسب العملة',
                  subtitle: 'مجموع كل عملة جوّا بطاقة الملخص',
                  icon: Icons.payments_rounded,
                  value: p.quickShowAmounts,
                  onChanged: (v) => _save(p.copyWith(quickShowAmounts: v)),
                ),
                _switch(
                  title: 'التغيّر عن الفترة السابقة',
                  subtitle: 'السهم والنسبة والفرق (بكل البطاقات)',
                  icon: Icons.trending_up_rounded,
                  value: p.showDelta,
                  onChanged: (v) => _save(p.copyWith(showDelta: v)),
                ),
                _switch(
                  title: 'إخفاء الحسابات يلي ما إلها حركات',
                  subtitle: 'بالفترة المختارة (جوّا البطاقات وبطاقات الحسابات)',
                  icon: Icons.filter_alt_off_rounded,
                  value: p.hideZeroAccounts,
                  onChanged: (v) => _save(p.copyWith(hideZeroAccounts: v)),
                ),
              ],
            ),
            _section(
              title: 'الشكل',
              icon: Icons.dashboard_customize_rounded,
              children: [
                _choice<int>(
                  title: 'أعمدة الملخص السريع',
                  icon: Icons.view_column_rounded,
                  value: p.columns,
                  options: const {0: 'تلقائي', 1: 'عمود واحد', 2: 'عمودين'},
                  onChanged: (v) => _save(p.copyWith(columns: v)),
                ),
                _choice<bool>(
                  title: 'حجم البطاقات',
                  icon: Icons.photo_size_select_small_rounded,
                  value: p.compact,
                  options: const {false: 'عادي', true: 'مضغوط'},
                  onChanged: (v) => _save(p.copyWith(compact: v)),
                ),
                _switch(
                  title: 'الهيدر',
                  subtitle: 'العنوان والفترة المختارة بالأعلى',
                  icon: Icons.view_headline_rounded,
                  value: p.showHeader,
                  onChanged: (v) => _save(p.copyWith(showHeader: v)),
                ),
                _switch(
                  title: 'بطاقات كل الحسابات',
                  subtitle: 'بطاقة لكل قسم مع تفاصيل العملات',
                  icon: Icons.widgets_rounded,
                  value: p.showGlobalCards,
                  onChanged: (v) => _save(p.copyWith(showGlobalCards: v)),
                ),
                _switch(
                  title: 'بطاقات كل حساب لحالو',
                  subtitle: 'تفاصيل كل حساب على حدة',
                  icon: Icons.account_balance_wallet_rounded,
                  value: p.showAccountCards,
                  onChanged: (v) => _save(p.copyWith(showAccountCards: v)),
                ),
                _switch(
                  title: 'صفوف العملات',
                  subtitle: 'تفاصيل العملات جوّا البطاقات',
                  icon: Icons.currency_exchange_rounded,
                  value: p.showCurrencyRows,
                  onChanged: (v) => _save(p.copyWith(showCurrencyRows: v)),
                ),
              ],
            ),
            _section(
              title: 'العنوان والتصدير',
              icon: Icons.ios_share_rounded,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: TextField(
                    controller: _title,
                    onChanged: _onTitleChanged,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'عنوان الصفحة (بالهيدر والصورة)',
                      hintText: 'إحصائيات ${_type.label}',
                      helperText: 'فاضي = العنوان الأصلي',
                      prefixIcon: const Icon(Icons.title_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                _switch(
                  title: 'إخفاء الهيدر بالصورة',
                  subtitle: 'لما تحفظ الصورة أو تشاركها',
                  icon: Icons.image_rounded,
                  value: p.hideHeaderInExport,
                  onChanged: (v) => _save(p.copyWith(hideHeaderInExport: v)),
                ),
              ],
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.error,
                side: BorderSide(color: cs.error.withValues(alpha: .4)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _confirmReset,
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('رجوع للإعدادات الافتراضية'),
            ),
          ],
        ),
      ),
    );
  }
}
