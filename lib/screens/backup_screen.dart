import 'package:flutter/material.dart';

import '../backup_service.dart';
import '../models.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  BackupDashboardData? _data;
  bool _loading = true;
  bool _working = false;
  String? _lastBackupPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dashboard = await BackupService.loadDashboard();
      if (!mounted) return;
      setState(() {
        _data = dashboard;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showSnack('حدث خطأ أثناء تحميل البيانات: $e');
    }
  }

  Future<void> _exportBackup() async {
    if (_working) return;
    setState(() => _working = true);

    try {
      final path = await BackupService.exportBackupToChosenFolder();
      if (!mounted) return;

      if (path == null) {
        _showSnack('تم إلغاء الحفظ');
      } else {
        setState(() => _lastBackupPath = path);
        _showSnack('تم حفظ النسخة الاحتياطية بنجاح');
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack('فشل حفظ النسخة الاحتياطية: $e');
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _importBackup() async {
    if (_working) return;

    try {
      final picked = await BackupService.pickBackupFile();
      if (!mounted || picked == null) return;

      final ok = await _showImportDialog(picked);
      if (ok != true || !mounted) return;

      setState(() => _working = true);
      await BackupService.restoreBackup(picked);

      if (!mounted) return;
      await _load();
      _showSnack('تم استيراد النسخة الاحتياطية واستبدال البيانات الحالية');
    } catch (e) {
      if (!mounted) return;
      _showSnack('فشل الاستيراد: $e');
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<bool?> _showImportDialog(PickedBackupFile picked) {
    final s = picked.stats;

    return showDialog<bool>(
      context: context,
      builder: (_) {
        final scheme = Theme.of(context).colorScheme;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            title: const Text('استيراد نسخة احتياطية'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MiniInfoRow(
                  icon: Icons.folder_open_rounded,
                  label: 'الملف',
                  value: picked.path.split(RegExp(r'[\\/]+')).last,
                ),
                const SizedBox(height: 10),
                _MiniInfoRow(
                  icon: Icons.schedule_rounded,
                  label: 'تاريخ النسخة',
                  value: _fmtDateTime(picked.createdAt),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TinyChip(label: 'الحسابات ${s.accountsCount}'),
                    _TinyChip(label: 'الحركات ${s.transactionsCount}'),
                    _TinyChip(label: 'النصوص ${s.parsesCount}'),
                    _TinyChip(label: 'العملات ${s.currenciesCount}'),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'سيتم استبدال البيانات الحالية بالكامل بهذه النسخة.',
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('إلغاء'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.restore_rounded),
                label: const Text('استيراد'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              scheme.primary.withOpacity(0.08),
              scheme.surface,
              scheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
              children: [
                _HeroBackupCard(
                  title: 'النسخ الاحتياطي',
                  subtitle:
                  'صفحة مخصصة لحفظ نسخة من بياناتك واستيرادها واستعراضها بشكل سريع.',
                  lastPath: _lastBackupPath,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _ActionCard(
                        title: 'إنشاء نسخة',
                        subtitle: 'اختر مجلدًا مثل Download واحفظ ملف JSON',
                        icon: Icons.backup_rounded,
                        onTap: _working ? null : _exportBackup,
                        loading: _working,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionCard(
                        title: 'استيراد نسخة',
                        subtitle: 'اختر ملف النسخة لاستعادة البيانات الحالية',
                        icon: Icons.restore_page_rounded,
                        onTap: _working ? null : _importBackup,
                        loading: false,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _StatsSection(data: _data!),
                const SizedBox(height: 18),
                _SectionCard(
                  title: 'استعراض سريع للبيانات',
                  icon: Icons.dataset_rounded,
                  child: Column(
                    children: [
                      _PreviewAccounts(accounts: _data!.accounts),
                      const SizedBox(height: 12),
                      _PreviewTransactions(
                        transactions: _data!.transactions,
                      ),
                      const SizedBox(height: 12),
                      _PreviewParses(parses: _data!.parses),
                      const SizedBox(height: 12),
                      _PreviewSettings(settings: _data!.settings),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmtDateTime(DateTime? dt) {
    if (dt == null) return 'غير معروف';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}/${two(dt.month)}/${two(dt.day)}  ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _HeroBackupCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? lastPath;

  const _HeroBackupCard({
    required this.title,
    required this.subtitle,
    required this.lastPath,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            scheme.primary,
            Color.lerp(scheme.primary, scheme.tertiary, 0.40) ?? scheme.primary,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.25),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              _RoundIcon(icon: Icons.shield_rounded),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'أمان بياناتك',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: const TextStyle(
              color: Colors.white,
              height: 1.45,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.16),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.22)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lastPath == null
                        ? 'لم يتم إنشاء نسخة في هذه الجلسة بعد'
                        : 'آخر نسخة: ${lastPath!.split(RegExp(r'[\\/]+')).last}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsSection extends StatelessWidget {
  final BackupDashboardData data;

  const _StatsSection({required this.data});

  @override
  Widget build(BuildContext context) {
    final s = data.stats;

    return _SectionCard(
      title: 'ملخص البيانات الحالية',
      icon: Icons.analytics_rounded,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'الحسابات',
                  value: '${s.accountsCount}',
                  icon: Icons.account_balance_wallet_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatTile(
                  label: 'الحركات',
                  value: '${s.transactionsCount}',
                  icon: Icons.swap_horiz_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'النصوص',
                  value: '${s.parsesCount}',
                  icon: Icons.text_snippet_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatTile(
                  label: 'العملات',
                  value: '${s.currenciesCount}',
                  icon: Icons.currency_exchange_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'إجمالي المبلغ الأول',
                  value: s.primaryAmountTotal.toStringAsFixed(2),
                  icon: Icons.looks_one_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatTile(
                  label: 'إجمالي المبلغ الثاني',
                  value: s.secondaryAmountTotal.toStringAsFixed(2),
                  icon: Icons.looks_two_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewAccounts extends StatelessWidget {
  final List<Account> accounts;

  const _PreviewAccounts({required this.accounts});

  @override
  Widget build(BuildContext context) {
    return _InnerBlock(
      title: 'الحسابات',
      icon: Icons.people_alt_rounded,
      child: accounts.isEmpty
          ? const _EmptyLine(text: 'لا توجد حسابات حاليًا')
          : Column(
        children: accounts.take(5).map((a) {
          return _LineTile(
            title: a.name,
            subtitle: 'المعرّف: ${a.id}',
          );
        }).toList(),
      ),
    );
  }
}

class _PreviewTransactions extends StatelessWidget {
  final List<TransactionModel> transactions;

  const _PreviewTransactions({required this.transactions});

  @override
  Widget build(BuildContext context) {
    return _InnerBlock(
      title: 'آخر الحركات',
      icon: Icons.receipt_long_rounded,
      child: transactions.isEmpty
          ? const _EmptyLine(text: 'لا توجد حركات')
          : Column(
        children: transactions.take(5).map((t) {
          final second = t.hasSecondAmount
              ? ' + ${t.secondAmount!.toStringAsFixed(2)} ${t.secondCurrency ?? ''}'
              : '';
          return _LineTile(
            title: t.beneficiary.isEmpty ? 'بدون اسم' : t.beneficiary,
            subtitle:
            '${t.amount.toStringAsFixed(2)} ${t.currency}$second',
            trailing: _StatusBadge(status: t.status),
          );
        }).toList(),
      ),
    );
  }
}

class _PreviewParses extends StatelessWidget {
  final List<ParsedText> parses;

  const _PreviewParses({required this.parses});

  @override
  Widget build(BuildContext context) {
    return _InnerBlock(
      title: 'النصوص المحفوظة',
      icon: Icons.notes_rounded,
      child: parses.isEmpty
          ? const _EmptyLine(text: 'لا توجد نصوص محفوظة')
          : Column(
        children: parses.take(4).map((p) {
          return _LineTile(
            title: p.title.isEmpty ? 'بدون عنوان' : p.title,
            subtitle:
            'أسطر مختارة: ${p.selectedLines.length} • أسطر نهائية: ${p.finalLines.length}',
          );
        }).toList(),
      ),
    );
  }
}

class _PreviewSettings extends StatelessWidget {
  final Settings? settings;

  const _PreviewSettings({required this.settings});

  @override
  Widget build(BuildContext context) {
    if (settings == null) {
      return const _InnerBlock(
        title: 'الإعدادات',
        icon: Icons.settings_rounded,
        child: _EmptyLine(text: 'لا توجد إعدادات محفوظة بعد'),
      );
    }

    return _InnerBlock(
      title: 'الإعدادات',
      icon: Icons.settings_rounded,
      child: Column(
        children: [
          _LineTile(
            title: 'كلمات الاسم',
            subtitle: '${settings!.nameKeywords.length} عنصر',
          ),
          _LineTile(
            title: 'كلمات المبلغ',
            subtitle: '${settings!.amountKeywords.length} عنصر',
          ),
          _LineTile(
            title: 'العملات المعرّفة',
            subtitle: '${settings!.currencyMap.length} عنصر',
          ),
          _LineTile(
            title: 'الكلمات المتجاهلة',
            subtitle: '${settings!.ignoredWords.length} عنصر',
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface.withOpacity(0.88),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.45)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final bool loading;

  const _ActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = onTap == null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withOpacity(disabled ? 0.55 : 0.95),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: scheme.outlineVariant.withOpacity(0.42)),
          ),
          child: SizedBox(
            height: 125,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                loading
                    ? const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.8),
                )
                    : Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: scheme.primary),
                ),
                const Spacer(),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
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

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(0.78),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _InnerBlock extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _InnerBlock({
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(0.65),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _LineTile({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final TransactionStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    late final String text;
    late final Color color;

    switch (status) {
      case TransactionStatus.added:
        text = 'مضافة';
        color = Colors.blue;
        break;
      case TransactionStatus.received:
        text = 'مستلمة';
        color = Colors.green;
        break;
      case TransactionStatus.cancelled:
        text = 'ملغاة';
        color = Colors.red;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _TinyChip extends StatelessWidget {
  final String label;

  const _TinyChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 12.5,
        ),
      ),
    );
  }
}

class _MiniInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MiniInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyLine extends StatelessWidget {
  final String text;

  const _EmptyLine({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;

  const _RoundIcon({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white),
    );
  }
}