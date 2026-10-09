import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';
import 'add_account_screen.dart';
import 'account_screen.dart';

/// تصفية قائمة الحسابات في الصفحة الرئيسية
enum _AccountsView { all, office, company }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  _AccountsView _accountsView = _AccountsView.all;

  static const List<Color> _accentPalette = [
    Color(0xFF2563EB),
    Color(0xFF059669),
    Color(0xFF7C3AED),
    Color(0xFFD97706),
    Color(0xFFDB2777),
    Color(0xFF0891B2),
    Color(0xFFEA580C),
    Color(0xFF4F46E5),
    Color(0xFF0D9488),
    Color(0xFFDC2626),
    Color(0xFF0284C7),
    Color(0xFF65A30D),
  ];

  Color _accountAccent(int accountId) {
    final mixed = (accountId ~/ 7) + (accountId % 97);
    return _accentPalette[mixed.abs() % _accentPalette.length];
  }

  String _formatDay(DateTime dt) {
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return "${dt.year}-$mm-$dd";
  }

  String _formatTime(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return "$hh:$mm";
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isPendingTx(TransactionModel t) =>
      t.companyMovementType == null && t.status == TransactionStatus.added;

  DateTime _lastActivityOf(TransactionModel t) {
    var m = t.date;
    final r = t.receivedAt;
    final c = t.cancelledAt;
    if (r != null && r.isAfter(m)) m = r;
    if (c != null && c.isAfter(m)) m = c;
    return m;
  }

  static const List<String> _monthNames = [
    'يناير',
    'فبراير',
    'مارس',
    'أبريل',
    'مايو',
    'يونيو',
    'يوليو',
    'أغسطس',
    'سبتمبر',
    'أكتوبر',
    'نوفمبر',
    'ديسمبر',
  ];

  String _relativeTime(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.isNegative || diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} د';
    if (_isSameDay(d, now)) return 'اليوم ${_formatTime(d)}';
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (days == 1) return 'أمس';
    if (days == 2) return 'منذ يومين';
    if (days <= 10) return 'منذ $days أيام';
    if (d.year == now.year) return '${d.day} ${_monthNames[d.month - 1]}';
    return _formatDay(d);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pageBg = _pageBg(context);

    return ValueListenableBuilder(
      valueListenable: DatabaseService.accountsBox.listenable(),
      builder: (context, Box<Account> accountsBox, _) {
        final accounts = accountsBox.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        final officeAccounts = accounts
            .where((account) => account.type == AccountType.office)
            .toList();
        final companyAccounts = accounts
            .where((account) => account.type == AccountType.company)
            .toList();

        return ValueListenableBuilder(
          valueListenable: DatabaseService.transactionsBox.listenable(),
          builder: (context, Box<TransactionModel> txBox, _) {
            final now = DateTime.now();
            final statsByAccount = <int, _AccountStats>{};
            for (final tx in txBox.values) {
              final st = statsByAccount.putIfAbsent(
                tx.accountId,
                _AccountStats.new,
              );
              st.total++;
              if (_isSameDay(tx.date, now)) st.today++;
              if (_isPendingTx(tx)) st.pending++;
              final last = _lastActivityOf(tx);
              final prev = st.lastActivity;
              if (prev == null || last.isAfter(prev)) st.lastActivity = last;
            }

            final showSegments =
                officeAccounts.isNotEmpty && companyAccounts.isNotEmpty;
            final view = showSegments ? _accountsView : _AccountsView.all;
            final sections = <_AccountSection>[
              if (view == _AccountsView.all && showSegments) ...[
                _AccountSection(
                  title: 'حسابات المكاتب',
                  icon: Icons.storefront_rounded,
                  accounts: officeAccounts,
                ),
                _AccountSection(
                  title: 'حسابات الشركات',
                  icon: Icons.business_rounded,
                  accounts: companyAccounts,
                ),
              ] else if (view == _AccountsView.office)
                _AccountSection(accounts: officeAccounts)
              else if (view == _AccountsView.company)
                _AccountSection(accounts: companyAccounts)
              else
                _AccountSection(accounts: accounts),
            ];

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                backgroundColor: pageBg,
                floatingActionButtonLocation:
                    FloatingActionButtonLocation.endFloat,
                floatingActionButton: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 70),
                    child: FloatingActionButton(
                      heroTag: 'addAccountFab',
                      tooltip: 'إضافة حساب',
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                      onPressed: _openAddAccount,
                      child: const Icon(Icons.add_rounded),
                    ),
                  ),
                ),
                body: CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      toolbarHeight: 64,
                      centerTitle: false,
                      titleSpacing: 20,
                      backgroundColor: pageBg,
                      foregroundColor: cs.onSurface,
                      surfaceTintColor: Colors.transparent,
                      scrolledUnderElevation: 0,
                      title: Text(
                        'الرئيسية',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (showSegments)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: _AccountsSegment(
                            value: view,
                            total: accounts.length,
                            office: officeAccounts.length,
                            company: companyAccounts.length,
                            onChanged: (v) => setState(() => _accountsView = v),
                          ),
                        ),
                      ),
                    if (accounts.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: _NoAccountsCard(onAdd: _openAddAccount),
                        ),
                      )
                    else
                      for (final section in sections) ...[
                        if (section.title != null)
                          SliverToBoxAdapter(
                            child: _SectionHeader(
                              title: section.title!,
                              icon: section.icon ?? Icons.folder_rounded,
                              count: section.accounts.length,
                            ),
                          ),
                        SliverList.builder(
                          itemCount: section.accounts.length,
                          itemBuilder: (context, index) {
                            final account = section.accounts[index];
                            final stats =
                                statsByAccount[account.id] ?? _AccountStats();
                            final last = stats.lastActivity;

                            return _AnimatedEntrance(
                              index: index,
                              child: _AccountTile(
                                account: account,
                                accent: _accountAccent(account.id),
                                stats: stats,
                                lastActivityText: last == null
                                    ? null
                                    : _relativeTime(last),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          AccountScreen(account: account),
                                    ),
                                  );
                                },
                                onMore: () =>
                                    _showAccountActions(context, account),
                              ),
                            );
                          },
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 6)),
                      ],
                    const SliverToBoxAdapter(child: SizedBox(height: 120)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openAddAccount() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddAccountScreen()),
    );
  }

  Future<void> _showAccountActions(
    BuildContext context,
    Account account,
  ) async {
    final scheme = Theme.of(context).colorScheme;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: scheme.surface,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.edit, color: Colors.blue),
                ),
                title: const Text(
                  'تعديل اسم الحساب',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _renameAccount(context, account);
                },
              ),
              const Divider(indent: 16, endIndent: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.delete_rounded, color: scheme.error),
                ),
                title: Text(
                  'حذف الحساب نهائيًا',
                  style: TextStyle(
                    color: scheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _deleteAccountWithConfirm(context, account);
                },
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _renameAccount(BuildContext context, Account account) async {
    final ctrl = TextEditingController(text: account.name);

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تعديل اسم الحساب'),
          content: TextField(
            controller: ctrl,
            decoration: InputDecoration(
              labelText: 'الاسم الجديد',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
            ),
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => Navigator.pop(context, true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      final newName = ctrl.text.trim();
      if (newName.isNotEmpty && newName != account.name) {
        account.name = newName;
        await account.save();
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('تم تعديل الاسم')));
        }
      }
    }
  }

  Future<void> _deleteAccountWithConfirm(
    BuildContext context,
    Account account,
  ) async {
    final theme = Theme.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد الحذف'),
          content: Text(
            'هل تريد حذف الحساب "${account.name}"؟\nسيتم حذف جميع الحركات المرتبطة به.',
            style: const TextStyle(height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.errorContainer,
                foregroundColor: theme.colorScheme.onErrorContainer,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      await account.delete();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم حذف الحساب')));
      }
    }
  }
}

class _AnimatedEntrance extends StatelessWidget {
  final int index;
  final Widget child;

  const _AnimatedEntrance({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    final duration = Duration(milliseconds: 280 + (index * 35).clamp(0, 240));
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        return Transform.translate(
          offset: Offset(0, (1 - value) * 22),
          child: Opacity(opacity: value, child: child),
        );
      },
    );
  }
}

/// إحصائيات مختصرة لكل حساب (تُحسب مرة واحدة في كل بناء)
class _AccountStats {
  int total = 0;
  int today = 0;
  int pending = 0;
  DateTime? lastActivity;
}

class _AccountSection {
  final String? title;
  final IconData? icon;
  final List<Account> accounts;

  const _AccountSection({required this.accounts, this.title, this.icon});
}

// ---------------- ألوان مشتركة ----------------

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

/// لون نص/أيقونة ملوّن بتباين مناسب للوضعين الفاتح والداكن
Color _fg(BuildContext context, Color c) => _isDark(context)
    ? Color.lerp(c, Colors.white, .25)!
    : Color.lerp(c, Colors.black, .10)!;

// ---------------- قائمة الحسابات ----------------

class _AccountsSegment extends StatelessWidget {
  final _AccountsView value;
  final int total;
  final int office;
  final int company;
  final ValueChanged<_AccountsView> onChanged;

  const _AccountsSegment({
    required this.value,
    required this.total,
    required this.office,
    required this.company,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = <(_AccountsView, String, int)>[
      (_AccountsView.all, 'الكل', total),
      (_AccountsView.office, 'المكاتب', office),
      (_AccountsView.company, 'الشركات', company),
    ];

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: _SegmentButton(
                label: item.$2,
                count: item.$3,
                selected: value == item.$1,
                onTap: () => onChanged(item.$1),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? _cardBg(context) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: _isDark(context) ? .20 : .06,
                      ),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: selected ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: selected
                        ? _fg(context, cs.primary)
                        : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final int count;

  const _SectionHeader({
    required this.title,
    required this.icon,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 10),
      child: Row(
        children: [
          Icon(icon, size: 16, color: muted),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              color: muted,
              fontWeight: FontWeight.w800,
              fontSize: 13.5,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '• $count',
            style: TextStyle(
              color: muted.withValues(alpha: .8),
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- بطاقة الحساب ----------------

class _AccountTile extends StatelessWidget {
  final Account account;
  final Color accent;
  final _AccountStats stats;
  final String? lastActivityText;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _AccountTile({
    required this.account,
    required this.accent,
    required this.stats,
    required this.lastActivityText,
    required this.onTap,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurfaceVariant;
    final isCompany = account.type == AccountType.company;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: _cardBg(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _outline(context)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onMore,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 4, 12),
            child: Row(
              children: [
                _AccountAvatar(name: account.name, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              account.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _TypeBadge(isCompany: isCompany),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          _MetaText(
                            icon: Icons.receipt_long_rounded,
                            text: '${stats.total} حركة',
                            color: muted,
                          ),
                          if (stats.pending > 0)
                            _MetaText(
                              icon: Icons.hourglass_top_rounded,
                              text: '${stats.pending} غير مستلمة',
                              color: _fg(context, const Color(0xFFEA580C)),
                            ),
                          if (stats.today > 0)
                            _MetaText(
                              icon: Icons.bolt_rounded,
                              text: '${stats.today} اليوم',
                              color: _fg(context, const Color(0xFF0D9488)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'خيارات الحساب',
                      visualDensity: VisualDensity.compact,
                      onPressed: onMore,
                      icon: Icon(Icons.more_horiz_rounded, color: muted),
                    ),
                    if (lastActivityText != null)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 10),
                        child: Text(
                          lastActivityText!,
                          style: TextStyle(
                            color: muted.withValues(alpha: .85),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountAvatar extends StatelessWidget {
  final String name;
  final Color color;

  const _AccountAvatar({required this.name, required this.color});

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? '؟'
        : trimmed.characters.first.toUpperCase();
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [color, Color.lerp(color, Colors.white, .30)!],
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: .28),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 20,
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final bool isCompany;

  const _TypeBadge({required this.isCompany});

  @override
  Widget build(BuildContext context) {
    final base = isCompany ? const Color(0xFF8B5CF6) : const Color(0xFF3B82F6);
    final fg = _fg(context, base);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: base.withValues(alpha: _isDark(context) ? .20 : .11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCompany ? Icons.business_rounded : Icons.storefront_rounded,
            size: 12,
            color: fg,
          ),
          const SizedBox(width: 4),
          Text(
            isCompany ? 'شركة' : 'مكتب',
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaText extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _MetaText({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// ---------------- الحالة الفارغة ----------------

class _NoAccountsCard extends StatelessWidget {
  final VoidCallback onAdd;

  const _NoAccountsCard({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
      decoration: BoxDecoration(
        color: _cardBg(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _outline(context)),
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFF0F766E), Color(0xFF26A69A)],
              ),
            ),
            child: const Icon(
              Icons.account_balance_wallet_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'لا توجد حسابات',
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة حساب'),
          ),
        ],
      ),
    );
  }
}
