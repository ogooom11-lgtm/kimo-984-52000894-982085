// lib/widgets/trace_widgets.dart
// -------------------------------------------------------------
// واجهة «مسار الحركة»:
//  • TracePathCard: بطاقة المسار بصفحة التفاصيل (شركة ABC ← مكتب X، مع
//    السلسلة إذا انلغت من مكتب وراحت لمكتب تاني) + التحذيرات + الأزرار.
//  • showTraceReasons: صفحة «ليش؟» (أسباب اختيار المصدر والمرشحين المرفوضين).
//  • showTraceChooser: اختيار/تغيير المصدر (أو ربط حركة شركة بحركة مكتب).
//  • أسماء الحسابات قابلة للضغط وبتفتح الحساب مع تحديد الحركة.
// -------------------------------------------------------------

import 'package:flutter/material.dart';

import '../models.dart';
import '../screens/account_screen.dart';
import '../screens/transaction_details_screen.dart';
import '../services/trace/trace_service.dart';
import '../services/tx_history_service.dart';
import 'destination_picker.dart' show kDestExternalColor, kDestOfficeColor;

// =============================================================
// ألوان وتسميات
// =============================================================

class TraceUi {
  TraceUi._();

  static const Color company = Color(0xFF0F766E);
  static const Color office = Color(0xFF4F46E5);
  static const Color unknownColor = Color(0xFF64748B);

  static Color statusColor(TraceStatus s) {
    switch (s) {
      case TraceStatus.manual:
        return const Color(0xFF7C3AED);
      case TraceStatus.auto:
        return const Color(0xFF059669);
      case TraceStatus.autoOrder:
        return const Color(0xFF0891B2);
      case TraceStatus.possible:
        return const Color(0xFFD97706);
      case TraceStatus.unknownManual:
      case TraceStatus.unknown:
        return unknownColor;
    }
  }

  static IconData statusIcon(TraceStatus s) {
    switch (s) {
      case TraceStatus.manual:
        return Icons.back_hand_rounded;
      case TraceStatus.auto:
        return Icons.verified_rounded;
      case TraceStatus.autoOrder:
        return Icons.format_list_numbered_rounded;
      case TraceStatus.possible:
        return Icons.help_center_rounded;
      case TraceStatus.unknownManual:
      case TraceStatus.unknown:
        return Icons.help_outline_rounded;
    }
  }

  static String statusLabel(TraceStatus s) {
    final unknown = TraceService.prefs.value.unknown;
    switch (s) {
      case TraceStatus.manual:
        return 'مؤكد يدويًا';
      case TraceStatus.auto:
        return 'مؤكد تلقائيًا';
      case TraceStatus.autoOrder:
        return 'مؤكد بالترتيب';
      case TraceStatus.possible:
        return 'محتمل — بدو اختيار';
      case TraceStatus.unknownManual:
        return '$unknown (حددته أنت)';
      case TraceStatus.unknown:
        return unknown;
    }
  }

  static Color warningColor(TraceWarningKind k) {
    switch (k) {
      case TraceWarningKind.choose:
        return const Color(0xFFD97706);
      case TraceWarningKind.late:
        return const Color(0xFFEA580C);
      case TraceWarningKind.editedOneSide:
        return const Color(0xFF2563EB);
      case TraceWarningKind.valuesDiffer:
        return const Color(0xFFDB2777);
      case TraceWarningKind.confirmedChanged:
        return const Color(0xFF7C3AED);
      case TraceWarningKind.companyCancelled:
        return const Color(0xFFDC2626);
      case TraceWarningKind.notReached:
        return const Color(0xFFB91C1C);
      case TraceWarningKind.brokenLink:
        return const Color(0xFF6B7280);
      case TraceWarningKind.routeChanged:
        return const Color(0xFF9333EA);
      case TraceWarningKind.wrongOffice:
        return const Color(0xFFC2410C);
    }
  }

  static IconData warningIcon(TraceWarningKind k) {
    switch (k) {
      case TraceWarningKind.choose:
        return Icons.rule_rounded;
      case TraceWarningKind.late:
        return Icons.hourglass_bottom_rounded;
      case TraceWarningKind.editedOneSide:
        return Icons.edit_note_rounded;
      case TraceWarningKind.valuesDiffer:
        return Icons.compare_arrows_rounded;
      case TraceWarningKind.confirmedChanged:
        return Icons.published_with_changes_rounded;
      case TraceWarningKind.companyCancelled:
        return Icons.block_rounded;
      case TraceWarningKind.notReached:
        return Icons.wrong_location_rounded;
      case TraceWarningKind.brokenLink:
        return Icons.link_off_rounded;
      case TraceWarningKind.routeChanged:
        return Icons.fork_right_rounded;
      case TraceWarningKind.wrongOffice:
        return Icons.location_off_rounded;
    }
  }

  static const Color destOffice = kDestOfficeColor;
  static const Color destExternal = kDestExternalColor;

  /// وجهة حركة الشركة كما هي بالإعدادات (null = بدون وجهة)
  static Destination? destinationOf(TransactionModel t) =>
      TraceService.destinations.byName(t.destination);

  /// شارة الوجهة («📍 حلب») لحركات الشركات، أو null
  static Widget? destinationPill(TransactionModel t) {
    final name = t.destination?.trim() ?? '';
    if (name.isEmpty || !isCompanyTx(t)) return null;
    final d = destinationOf(t);
    final color = d == null
        ? unknownColor
        : (d.toOffice ? destOffice : destExternal);
    return TracePill(
      text: d == null ? name : '${d.name}${d.toOffice ? '' : ' • مو مكتب'}',
      color: color,
      icon: Icons.place_rounded,
    );
  }

  static Color reasonColor(TraceReasonTone t) {
    switch (t) {
      case TraceReasonTone.good:
        return const Color(0xFF059669);
      case TraceReasonTone.warn:
        return const Color(0xFFD97706);
      case TraceReasonTone.bad:
        return const Color(0xFFDC2626);
      case TraceReasonTone.info:
        return const Color(0xFF2563EB);
    }
  }

  static IconData reasonIcon(TraceReasonTone t) {
    switch (t) {
      case TraceReasonTone.good:
        return Icons.check_circle_rounded;
      case TraceReasonTone.warn:
        return Icons.warning_amber_rounded;
      case TraceReasonTone.bad:
        return Icons.cancel_rounded;
      case TraceReasonTone.info:
        return Icons.info_rounded;
    }
  }

  static bool isCompanyTx(TransactionModel t) =>
      TraceService.accountById(t.accountId)?.type.isCompany ?? false;

  static String txStatusLabel(TransactionModel t) {
    if (isCompanyTx(t)) return TraceEngine.movementOf(t).label;
    switch (t.status) {
      case TransactionStatus.added:
        return 'مضافة';
      case TransactionStatus.received:
        return 'مستلمة';
      case TransactionStatus.cancelled:
        return 'ملغية';
    }
  }

  static Color txStatusColor(TransactionModel t) {
    if (isCompanyTx(t)) {
      final m = TraceEngine.movementOf(t);
      if (m.isCancelled) return const Color(0xFFDC2626);
      return m.isSent ? const Color(0xFF5E35B1) : const Color(0xFF00897B);
    }
    switch (t.status) {
      case TransactionStatus.added:
        return const Color(0xFF1E88E5);
      case TransactionStatus.received:
        return const Color(0xFF00A76F);
      case TransactionStatus.cancelled:
        return const Color(0xFFDC2626);
    }
  }

  static String txLine(TransactionModel t) =>
      '${t.beneficiary} • ${traceAmount(t.amount)} ${t.currency}'.trim();

  static String when(DateTime d) => TxHistoryFormatter.dateTime(d);

  static String accountTitle(TransactionModel t) {
    final name = TraceService.accountName(t.accountId);
    return isCompanyTx(t) ? 'شركة $name' : name;
  }

  static Color tint(BuildContext context, Color c, [double light = .09]) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return c.withValues(alpha: dark ? light * 2 : light);
  }
}

void _snack(BuildContext context, String msg) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
  );
}

// =============================================================
// التنقل
// =============================================================

/// افتح تفاصيل حركة من معرّفها
Future<void> openTraceTx(BuildContext context, int txId) async {
  final t = TraceService.txById(txId);
  if (t == null) {
    _snack(context, 'الحركة ما عادت موجودة');
    return;
  }
  final acc =
      TraceService.accountById(t.accountId) ??
      Account(id: t.accountId, name: 'حساب #${t.accountId}');
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          TransactionDetailsScreen(account: acc, transactionHiveKey: t.key),
    ),
  );
}

/// افتح حساب الحركة مع تحديدها
Future<void> openTraceAccount(BuildContext context, int txId) async {
  final t = TraceService.txById(txId);
  if (t == null) {
    _snack(context, 'الحركة ما عادت موجودة');
    return;
  }
  final acc = TraceService.accountById(t.accountId);
  if (acc == null) {
    _snack(context, 'الحساب ما عاد موجود');
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AccountScreen(
        account: acc,
        initialSelectedTxIds: {txId},
        selectionTitle: '«${t.beneficiary}» • ${TraceUi.when(t.date)}',
        focusLabel: 'الحركة من مسار الحركة',
      ),
    ),
  );
}

// =============================================================
// عناصر صغيرة مشتركة
// =============================================================

class TracePill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool strong;

  const TracePill({
    super.key,
    required this.text,
    required this.color,
    this.icon,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    // عرض أقصى حتى يشتغل القص (…) حتى لو كانت الشارة داخل Row بدون حدود
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: _pill(context),
    );
  }

  Widget _pill(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: strong ? color : TraceUi.tint(context, color, .12),
        borderRadius: BorderRadius.circular(999),
        border: strong ? null : Border.all(color: color.withValues(alpha: .22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: strong ? Colors.white : color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: strong ? Colors.white : color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// زر صغير أنيق
class TraceActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;
  final bool filled;

  const TraceActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    if (filled) {
      return FilledButton.icon(
        style: style.copyWith(
          backgroundColor: WidgetStatePropertyAll(color),
          foregroundColor: const WidgetStatePropertyAll(Colors.white),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 17),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      );
    }
    return OutlinedButton.icon(
      style: style.copyWith(
        foregroundColor: WidgetStatePropertyAll(color),
        side: WidgetStatePropertyAll(
          BorderSide(color: color.withValues(alpha: .45)),
        ),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

/// سطر حركة قابل للضغط: اسم الحساب (يفتح الحساب) + الاسم والمبلغ + الوقت
class TraceTxTile extends StatelessWidget {
  final int txId;
  final String? note;
  final Color? noteColor;
  final Widget? trailing;
  final bool dense;

  const TraceTxTile({
    super.key,
    required this.txId,
    this.note,
    this.noteColor,
    this.trailing,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = TraceService.txById(txId);
    if (t == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'حركة محذوفة',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    final isCompany = TraceUi.isCompanyTx(t);
    final color = isCompany ? TraceUi.company : TraceUi.office;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => openTraceTx(context, txId),
      child: Container(
        padding: EdgeInsets.all(dense ? 8 : 10),
        decoration: BoxDecoration(
          color: TraceUi.tint(context, color, .06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: .16)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isCompany ? Icons.business_rounded : Icons.storefront_rounded,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => openTraceAccount(context, txId),
                        child: Text(
                          TraceUi.accountTitle(t),
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: color,
                            decoration: TextDecoration.underline,
                            decorationColor: color.withValues(alpha: .35),
                          ),
                        ),
                      ),
                      TracePill(
                        text: TraceUi.txStatusLabel(t),
                        color: TraceUi.txStatusColor(t),
                      ),
                      if (TraceUi.destinationPill(t) case final pill?) pill,
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    TraceUi.txLine(t),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  Text(
                    TraceUi.when(t.date),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      note!,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: noteColor ?? cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 6), trailing!],
          ],
        ),
      ),
    );
  }
}

/// شارات توافق الاسم/المبلغ/العملة
class TraceMatchChips extends StatelessWidget {
  final TraceMatch m;
  const TraceMatchChips({super.key, required this.m});

  @override
  Widget build(BuildContext context) {
    const good = Color(0xFF059669);
    const warn = Color(0xFFD97706);
    const bad = Color(0xFFDC2626);
    final nameColor = m.exactName
        ? good
        : (m.nameFit == TraceNameFit.similar ? warn : bad);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        TracePill(
          text: m.exactName
              ? (m.usesPast && (m.officeNamePast || m.companyNamePast)
                    ? 'الاسم (السابق) مطابق'
                    : 'الاسم مطابق')
              : (m.nameFit == TraceNameFit.similar
                    ? 'الاسم مشابه'
                    : 'الاسم مختلف'),
          color: nameColor,
          icon: m.exactName ? Icons.check_rounded : Icons.close_rounded,
        ),
        TracePill(
          text: m.amountSame
              ? 'المبلغ نفسه'
              : 'المبلغ ${traceAmount(m.companyAmount)} ≠ ${traceAmount(m.officeAmount)}',
          color: m.amountSame ? good : bad,
          icon: m.amountSame ? Icons.check_rounded : Icons.close_rounded,
        ),
        if (m.currencySame != null)
          TracePill(
            text: m.currencySame! ? 'العملة نفسها' : 'العملة مختلفة',
            color: m.currencySame! ? good : bad,
            icon: m.currencySame! ? Icons.check_rounded : Icons.close_rounded,
          ),
        TracePill(
          text: m.gap.isNegative
              ? 'قبل بـ ${traceDuration(m.gap)}'
              : 'بعد ${traceDuration(m.gap)}',
          color: m.tooEarly || m.tooOld
              ? bad
              : (m.late ? warn : const Color(0xFF2563EB)),
          icon: Icons.schedule_rounded,
        ),
      ],
    );
  }
}

// =============================================================
// توحيد المبلغ (لما يكون مبلغ حركة المكتب غير مبلغ حركة الشركة)
// =============================================================

/// المبلغ مختلف بين حركة المكتب وحركة الشركة؟ (القيم الحالية)
bool traceAmountsDiffer(int officeId, int companyId) {
  final o = TraceService.txById(officeId);
  final c = TraceService.txById(companyId);
  if (o == null || c == null) return false;
  return (o.amount - c.amount).abs() >= 0.005;
}

/// يسأل للتأكيد وبعدين بيعدّل المبلغ. [officeTakesCompany] = حركة المكتب
/// بتاخد مبلغ حركة الشركة (وإلا العكس). بيرجع true إذا انعدل.
Future<bool> confirmTraceAmountFix(
  BuildContext context, {
  required int officeId,
  required int companyId,
  required bool officeTakesCompany,
}) async {
  final o = TraceService.txById(officeId);
  final c = TraceService.txById(companyId);
  if (o == null || c == null) {
    _snack(context, 'الحركة ما عادت موجودة');
    return false;
  }
  final target = officeTakesCompany ? o : c;
  final source = officeTakesCompany ? c : o;
  final currencyDiffers =
      TraceService.result.value
          ?.evaluatePair(officeId, companyId)
          ?.currencySame ==
      false;
  var link = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: StatefulBuilder(
        builder: (ctx, setLocal) {
          final cs = Theme.of(ctx).colorScheme;
          final color = officeTakesCompany ? TraceUi.office : TraceUi.company;
          return AlertDialog(
            icon: Icon(Icons.edit_note_rounded, color: color, size: 34),
            title: Text(
              officeTakesCompany
                  ? 'تعديل مبلغ حركة المكتب'
                  : 'تعديل مبلغ حركة الشركة',
              textAlign: TextAlign.center,
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${TraceUi.accountTitle(target)} • «${target.beneficiary}»',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: 15, height: 1.6),
                      children: [
                        const TextSpan(text: 'المبلغ رح يتغيّر من '),
                        TextSpan(
                          text:
                              '${traceAmount(target.amount)} ${target.currency}'
                                  .trim(),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Color(0xFFDC2626),
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                        const TextSpan(text: ' لـ '),
                        TextSpan(
                          text:
                              '${traceAmount(source.amount)} ${target.currency}'
                                  .trim(),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF059669),
                          ),
                        ),
                        TextSpan(
                          text:
                              ' — متل ${officeTakesCompany ? 'حركة' : 'حركة المكتب'} '
                              '${TraceUi.accountTitle(source)}.',
                        ),
                      ],
                    ),
                  ),
                  if (currencyDiffers) ...[
                    const SizedBox(height: 8),
                    Text(
                      '⚠️ العملة كمان مختلفة (${o.currency} / ${c.currency}) — '
                      'العملة ما رح تتغير.',
                      style: const TextStyle(
                        color: Color(0xFFD97706),
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: link,
                    onChanged: (v) => setLocal(() => link = v ?? true),
                    title: const Text(
                      'وأكّد إنها مصدر الحركة (ربط الحركتين)',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    'التعديل بينسجل بسجل تعديلات الحركة، وفيك تتراجع عنه من '
                    '«سجل العمليات».',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: color),
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.check_rounded),
                label: const Text('تعديل المبلغ'),
              ),
            ],
          );
        },
      ),
    ),
  );
  if (ok != true) return false;
  final value = await TraceService.alignAmount(
    officeId,
    companyId,
    officeTakesCompany: officeTakesCompany,
    link: link,
  );
  if (!context.mounted) return value != null;
  if (value == null) {
    _snack(context, 'تعذّر التعديل: الحركة ما عادت موجودة');
    return false;
  }
  _snack(
    context,
    'تم تعديل مبلغ ${officeTakesCompany ? 'حركة المكتب' : 'حركة الشركة'} '
    'لـ ${traceAmount(value)}${link ? ' وتأكيد المصدر' : ''}',
  );
  return true;
}

/// صندوق «المبلغ مختلف» مع زرّين: مبلغ المكتب متل الشركة، أو العكس
class TraceAmountFix extends StatelessWidget {
  final int officeId;
  final int companyId;

  /// بعد التعديل (مثلًا سكّر القائمة)
  final VoidCallback? onDone;

  const TraceAmountFix({
    super.key,
    required this.officeId,
    required this.companyId,
    this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final o = TraceService.txById(officeId);
    final c = TraceService.txById(companyId);
    if (o == null || c == null || (o.amount - c.amount).abs() < 0.005) {
      return const SizedBox.shrink();
    }
    const red = Color(0xFFDC2626);
    Future<void> fix(bool officeTakesCompany) async {
      final done = await confirmTraceAmountFix(
        context,
        officeId: officeId,
        companyId: companyId,
        officeTakesCompany: officeTakesCompany,
      );
      if (done) onDone?.call();
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TraceUi.tint(context, red, .06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: red.withValues(alpha: .22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.price_change_rounded, size: 18, color: red),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'المبلغ مختلف: بالشركة ${traceAmount(c.amount)} '
                  'وبالمكتب ${traceAmount(o.amount)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    color: red,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TraceActionButton(
                icon: Icons.edit_rounded,
                label: 'خلّي مبلغ المكتب ${traceAmount(c.amount)}',
                color: TraceUi.office,
                onPressed: () => fix(true),
              ),
              TraceActionButton(
                icon: Icons.edit_rounded,
                label: 'خلّي مبلغ الشركة ${traceAmount(o.amount)}',
                color: TraceUi.company,
                onPressed: () => fix(false),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================
// بطاقة مسار الحركة
// =============================================================

class _Stop {
  final int? txId;
  final bool current;
  final bool dashed;
  final String? connector;
  final bool connectorWarn;

  /// للمحطة الوهمية («مجهول» / «لسا ما وصلت لمكتب»)
  final String? placeholderTitle;
  final String? placeholderLine;
  final Color? placeholderColor;
  final IconData? placeholderIcon;

  const _Stop.tx(
    int this.txId, {
    this.current = false,
    this.dashed = false,
    this.connector,
    this.connectorWarn = false,
  }) : placeholderTitle = null,
       placeholderLine = null,
       placeholderColor = null,
       placeholderIcon = null;

  const _Stop.placeholder({
    required String title,
    String? line,
    required Color color,
    required IconData icon,
    this.connector,
    this.connectorWarn = false,
  }) : txId = null,
       current = false,
       dashed = true,
       placeholderTitle = title,
       placeholderLine = line,
       placeholderColor = color,
       placeholderIcon = icon;
}

class TracePathCard extends StatelessWidget {
  final TransactionModel tx;

  /// بدون التحذيرات والأزرار (لصفحة السجل)
  final bool compact;

  const TracePathCard({super.key, required this.tx, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TraceResult?>(
      valueListenable: TraceService.result,
      builder: (context, r, _) {
        if (r == null) return _loading(context);
        if (!r.isTraced(tx.id)) return const SizedBox.shrink();
        return _buildCard(context, r);
      },
    );
  }

  Widget _shell(BuildContext context, {required Widget child, Color? border}) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF151A22) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: border ?? theme.dividerColor.withValues(alpha: .14),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .18 : .05),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _loading(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _shell(
      context,
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'عم نحلل مسار الحركة…',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  List<_Stop> _officeStops(TraceResult r, OfficeTrace t) {
    final stops = <_Stop>[];
    final link = t.link;
    if (t.status.linked && link != null) {
      stops.add(_Stop.tx(link.companyId));
      final chain = r.company[link.companyId]?.officeIds ?? <int>[tx.id];
      int? prev;
      for (final oid in chain) {
        final m = r.office[oid]?.link;
        String? conn;
        if (m != null) {
          if (prev != null && m.rerouteFrom != null) {
            conn = 'رجعت بعد الإلغاء بـ ${traceDuration(m.gap)}';
          } else if (prev != null) {
            conn = 'بعد ${traceDuration(m.gap)} من رسالة الشركة';
          } else {
            conn = m.gap.isNegative
                ? 'قبل رسالة الشركة بـ ${traceDuration(m.gap)}'
                : 'بعد ${traceDuration(m.gap)}';
          }
        }
        stops.add(
          _Stop.tx(
            oid,
            current: oid == tx.id,
            connector: conn,
            connectorWarn: m?.late ?? false,
          ),
        );
        prev = oid;
      }
      if (!chain.contains(tx.id)) stops.add(_Stop.tx(tx.id, current: true));
      return stops;
    }
    if (t.status == TraceStatus.possible && t.candidates.isNotEmpty) {
      stops.add(_Stop.tx(t.candidates.first.companyId, dashed: true));
      stops.add(
        _Stop.tx(
          tx.id,
          current: true,
          connector: t.candidates.length > 1
              ? 'محتمل • ${t.candidates.length} احتمالات'
              : 'محتمل',
          connectorWarn: true,
        ),
      );
      return stops;
    }
    stops.add(
      _Stop.placeholder(
        title: r.prefs.unknown,
        line: t.status == TraceStatus.unknownManual
            ? 'حددته أنت'
            : 'ما في حركة شركة مطابقة',
        color: TraceUi.unknownColor,
        icon: Icons.help_outline_rounded,
      ),
    );
    stops.add(_Stop.tx(tx.id, current: true));
    return stops;
  }

  List<_Stop> _companyStops(TraceResult r, CompanyTrace ct) {
    final stops = <_Stop>[_Stop.tx(tx.id, current: true)];
    int? prev;
    for (final oid in ct.officeIds) {
      final m = r.office[oid]?.link;
      String? conn;
      if (m != null) {
        conn = prev != null && m.rerouteFrom != null
            ? 'رجعت بعد الإلغاء بـ ${traceDuration(m.gap)}'
            : 'بعد ${traceDuration(m.gap)}';
      }
      stops.add(
        _Stop.tx(oid, connector: conn, connectorWarn: m?.late ?? false),
      );
      prev = oid;
    }
    if (ct.activeOfficeId == null) {
      if (ct.possibleOfficeIds.isNotEmpty) {
        stops.add(
          _Stop.tx(
            ct.possibleOfficeIds.first,
            dashed: true,
            connector: 'محتملة — بدها تأكيد',
            connectorWarn: true,
          ),
        );
      } else {
        final waited = DateTime.now().difference(ct.waitingSince);
        stops.add(
          _Stop.placeholder(
            title: ct.cancelled ? 'ملغاة بالشركة' : 'لسا ما وصلت لأي مكتب',
            line: ct.overdue
                ? 'صار إلها ${traceDuration(waited)} — وجهتها «${ct.destination}» '
                      'تابعة لمكتب'
                : (ct.mustReach
                      ? 'وجهتها «${ct.destination}» — لازم توصل لمكتب'
                      : (ct.external
                            ? 'وجهتها «${ct.destination}» مو تابعة لمكتب — عادي'
                            : null)),
            color: ct.overdue
                ? const Color(0xFFB91C1C)
                : (ct.mustReach
                      ? const Color(0xFFD97706)
                      : (ct.external
                            ? TraceUi.destExternal
                            : TraceUi.unknownColor)),
            icon: ct.cancelled
                ? Icons.block_rounded
                : Icons.hourglass_empty_rounded,
            connector: prev != null ? 'انلغت من المكتب' : null,
            connectorWarn: prev != null,
          ),
        );
      }
    }
    return stops;
  }

  Widget _buildCard(BuildContext context, TraceResult r) {
    final cs = Theme.of(context).colorScheme;
    final ot = r.office[tx.id];
    final ct = r.company[tx.id];
    final isOffice = ot != null;

    final Color headColor;
    final String headLabel;
    final IconData headIcon;
    if (isOffice) {
      headColor = TraceUi.statusColor(ot.status);
      headLabel = TraceUi.statusLabel(ot.status);
      headIcon = TraceUi.statusIcon(ot.status);
    } else if (ct != null && ct.reached) {
      headColor = const Color(0xFF059669);
      headLabel = 'وصلت لمكتب';
      headIcon = Icons.check_circle_rounded;
    } else if (ct != null && ct.overdue) {
      headColor = const Color(0xFFB91C1C);
      headLabel = 'ما راحت لمكتب';
      headIcon = Icons.wrong_location_rounded;
    } else if (ct != null && ct.external && !ct.cancelled) {
      headColor = TraceUi.destExternal;
      headLabel = 'وجهتها مو مكتب';
      headIcon = Icons.place_rounded;
    } else {
      headColor = TraceUi.unknownColor;
      headLabel = ct?.cancelled ?? false ? 'ملغاة' : 'لسا ما وصلت';
      headIcon = Icons.hourglass_empty_rounded;
    }

    final stops = isOffice ? _officeStops(r, ot) : _companyStops(r, ct!);
    final warnings = compact ? const <TraceWarning>[] : r.warningsFor(tx.id);

    return _shell(
      context,
      border: headColor.withValues(alpha: .22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: TraceUi.tint(context, headColor, .12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.alt_route_rounded, color: headColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'مسار الحركة',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: cs.onSurface,
                      ),
                    ),
                    Text(
                      isOffice ? 'من وين إجت هالحركة' : 'لوين راحت هالحركة',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: TraceService.computing,
                builder: (context, busy, _) => busy
                    ? const Padding(
                        padding: EdgeInsetsDirectional.only(end: 6),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              Flexible(
                child: TracePill(
                  text: headLabel,
                  color: headColor,
                  icon: headIcon,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < stops.length; i++)
            _StopRow(
              stop: stops[i],
              first: i == 0,
              last: i == stops.length - 1,
            ),
          if (!compact &&
              isOffice &&
              ot.status == TraceStatus.possible &&
              ot.candidates.isNotEmpty) ...[
            const SizedBox(height: 10),
            _possibleBox(context, ot),
          ],
          if (!compact && isOffice && ot.status.linked && ot.link != null)
            TraceAmountFix(officeId: tx.id, companyId: ot.link!.companyId),
          if (!compact && !isOffice && ct?.activeOfficeId != null)
            TraceAmountFix(officeId: ct!.activeOfficeId!, companyId: tx.id),
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final w in warnings) TraceWarningLine(warning: w, result: r),
          ],
          const SizedBox(height: 10),
          _actions(context, r, ot, ct),
        ],
      ),
    );
  }

  Widget _possibleBox(BuildContext context, OfficeTrace ot) {
    const amber = Color(0xFFD97706);
    final top = ot.candidates.first;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TraceUi.tint(context, amber, .08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: amber.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            ot.issues.contains(TraceIssue.tie)
                ? 'في أكتر من احتمال وما منخمّن. هي الحركة الأقرب، هي نفسها؟'
                : 'ما في تطابق تام${top.nameNote == null ? '' : ' (${top.nameNote})'}. هي نفسها؟',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          TraceMatchChips(m: top),
          TraceAmountFix(officeId: tx.id, companyId: top.companyId),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TraceActionButton(
                icon: Icons.check_rounded,
                label: 'هي نفسها',
                color: const Color(0xFF059669),
                filled: true,
                onPressed: () async {
                  await TraceService.linkManually(tx.id, top.companyId);
                  if (context.mounted) _snack(context, 'تم تأكيد المصدر');
                },
              ),
              TraceActionButton(
                icon: Icons.close_rounded,
                label: 'مو هي',
                color: const Color(0xFFDC2626),
                onPressed: () async {
                  await TraceService.reject(tx.id, top.companyId);
                  if (context.mounted) _snack(context, 'تم الاستبعاد');
                },
              ),
              if (ot.candidates.length > 1)
                TraceActionButton(
                  icon: Icons.list_alt_rounded,
                  label: 'كل الاحتمالات (${ot.candidates.length})',
                  color: amber,
                  onPressed: () => showTraceChooser(context, tx.id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actions(
    BuildContext context,
    TraceResult r,
    OfficeTrace? ot,
    CompanyTrace? ct,
  ) {
    final cs = Theme.of(context).colorScheme;
    final buttons = <Widget>[
      TraceActionButton(
        icon: Icons.help_outline_rounded,
        label: 'ليش؟',
        color: cs.primary,
        onPressed: () => showTraceReasons(context, tx.id),
      ),
    ];
    if (!compact && ot != null) {
      final link = ot.link;
      if ((ot.status == TraceStatus.auto ||
              ot.status == TraceStatus.autoOrder) &&
          link != null) {
        buttons.add(
          TraceActionButton(
            icon: Icons.verified_rounded,
            label: 'تأكيد',
            color: const Color(0xFF059669),
            onPressed: () async {
              await TraceService.linkManually(tx.id, link.companyId);
              if (context.mounted) _snack(context, 'تم تأكيد المصدر');
            },
          ),
        );
      }
      buttons.add(
        TraceActionButton(
          icon: Icons.swap_horiz_rounded,
          label: 'تغيير المصدر',
          color: TraceUi.company,
          onPressed: () => showTraceChooser(context, tx.id),
        ),
      );
      final hasDecision = TraceService.decisions.byOffice.containsKey(tx.id);
      buttons.add(
        PopupMenuButton<String>(
          tooltip: 'خيارات أكتر',
          icon: Icon(Icons.more_horiz_rounded, color: cs.onSurfaceVariant),
          onSelected: (v) async {
            switch (v) {
              case 'unknown':
                await TraceService.markUnknown(tx.id);
              case 'auto':
                await TraceService.resetToAuto(tx.id);
              case 'reject':
                if (link != null) {
                  await TraceService.reject(tx.id, link.companyId);
                }
            }
          },
          itemBuilder: (_) => [
            if (ot.status != TraceStatus.unknownManual)
              PopupMenuItem(
                value: 'unknown',
                child: Text('المصدر «${r.prefs.unknown}»'),
              ),
            if (link != null && ot.status != TraceStatus.manual)
              const PopupMenuItem(
                value: 'reject',
                child: Text('مو هي (استبعاد هالمصدر)'),
              ),
            if (hasDecision)
              const PopupMenuItem(
                value: 'auto',
                child: Text('رجوع للربط التلقائي'),
              ),
          ],
        ),
      );
    } else if (!compact && ct != null) {
      buttons.add(
        TraceActionButton(
          icon: Icons.add_link_rounded,
          label: ct.reached ? 'تغيير المكتب' : 'ربط بحركة مكتب',
          color: TraceUi.office,
          onPressed: () => showTraceChooser(context, tx.id),
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: buttons,
    );
  }
}

class _StopRow extends StatelessWidget {
  final _Stop stop;
  final bool first;
  final bool last;

  const _StopRow({required this.stop, required this.first, required this.last});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = stop.txId == null ? null : TraceService.txById(stop.txId!);
    final isCompany = t != null && TraceUi.isCompanyTx(t);
    final color =
        stop.placeholderColor ??
        (t == null
            ? TraceUi.unknownColor
            : (isCompany ? TraceUi.company : TraceUi.office));
    final icon =
        stop.placeholderIcon ??
        (t == null
            ? Icons.delete_outline_rounded
            : (isCompany ? Icons.business_rounded : Icons.storefront_rounded));
    final lineColor = cs.outlineVariant.withValues(alpha: .8);
    const warnColor = Color(0xFFD97706);

    final content = Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: stop.current
            ? TraceUi.tint(context, color, .10)
            : TraceUi.tint(context, color, .045),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: stop.dashed
              ? (stop.placeholderColor ?? warnColor).withValues(alpha: .55)
              : color.withValues(alpha: stop.current ? .35 : .16),
          width: stop.current || stop.dashed ? 1.4 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (t != null)
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => openTraceAccount(context, t.id),
                        child: Text(
                          TraceUi.accountTitle(t),
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14.5,
                            color: color,
                            decoration: TextDecoration.underline,
                            decorationColor: color.withValues(alpha: .35),
                          ),
                        ),
                      )
                    else
                      Text(
                        stop.placeholderTitle ?? 'حركة محذوفة',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14.5,
                          color: color,
                        ),
                      ),
                    if (t != null)
                      TracePill(
                        text: TraceUi.txStatusLabel(t),
                        color: TraceUi.txStatusColor(t),
                      ),
                    if (t != null)
                      if (TraceUi.destinationPill(t) case final pill?) pill,
                    if (stop.current)
                      TracePill(text: 'هالحركة', color: color, strong: true),
                    if (stop.dashed && t != null)
                      const TracePill(text: 'محتمل', color: warnColor),
                  ],
                ),
                if (t != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    TraceUi.txLine(t),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  Text(
                    TraceUi.when(t.date),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ] else if (stop.placeholderLine != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    stop.placeholderLine!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (t != null && !stop.current)
            IconButton(
              tooltip: 'فتح الحركة',
              visualDensity: VisualDensity.compact,
              onPressed: () => openTraceTx(context, t.id),
              icon: Icon(Icons.open_in_new_rounded, size: 19, color: color),
            ),
        ],
      ),
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 30,
            child: Column(
              children: [
                Container(
                  width: 2,
                  height: stop.connector == null ? 10 : 30,
                  color: first ? Colors.transparent : lineColor,
                ),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: stop.current
                        ? color
                        : TraceUi.tint(context, color, .14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 16,
                    color: stop.current ? Colors.white : color,
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: last ? Colors.transparent : lineColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (stop.connector != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6, top: 2),
                      child: TracePill(
                        text: stop.connector!,
                        color: stop.connectorWarn
                            ? warnColor
                            : cs.onSurfaceVariant,
                        icon: Icons.south_rounded,
                      ),
                    )
                  else
                    const SizedBox(height: 4),
                  content,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// سطر تحذير داخل بطاقة المسار
class TraceWarningLine extends StatelessWidget {
  final TraceWarning warning;
  final TraceResult result;

  const TraceWarningLine({
    super.key,
    required this.warning,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dismissed = result.isDismissed(warning);
    final color = dismissed
        ? cs.onSurfaceVariant
        : TraceUi.warningColor(warning.kind);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: TraceUi.tint(context, color, dismissed ? .04 : .08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(TraceUi.warningIcon(warning.kind), size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dismissed ? '${warning.title} (متجاهَل)' : warning.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: color,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  warning.detail,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: cs.onSurface.withValues(alpha: .85),
                  ),
                ),
              ],
            ),
          ),
          if (warning.dismissable)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: color,
              ),
              onPressed: () => dismissed
                  ? TraceService.undismiss(warning.sig)
                  : TraceService.dismiss(warning),
              child: Text(dismissed ? 'إرجاع' : 'تجاهل'),
            ),
        ],
      ),
    );
  }
}

// =============================================================
// «ليش؟»
// =============================================================

Future<void> showTraceReasons(BuildContext context, int txId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _ReasonsSheet(txId: txId),
  );
}

class _ReasonsSheet extends StatelessWidget {
  final int txId;
  const _ReasonsSheet({required this.txId});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .72,
        minChildSize: .4,
        maxChildSize: .95,
        builder: (context, controller) => ValueListenableBuilder<TraceResult?>(
          valueListenable: TraceService.result,
          builder: (context, r, _) {
            if (r == null || !r.isTraced(txId)) {
              return const Center(child: Text('ما في معلومات بعد'));
            }
            return _content(context, r, controller);
          },
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    TraceResult r,
    ScrollController controller,
  ) {
    final cs = Theme.of(context).colorScheme;
    final ex = r.explain(txId);
    final ot = r.office[txId];
    final since = TxHistoryService.trackingSince;
    final p = r.prefs;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
      children: [
        Row(
          children: [
            Icon(Icons.psychology_alt_rounded, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ot != null ? 'ليش هاد المصدر؟' : 'ليش هالمسار؟',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            if (ot != null)
              TracePill(
                text: TraceUi.statusLabel(ot.status),
                color: TraceUi.statusColor(ot.status),
                icon: TraceUi.statusIcon(ot.status),
              ),
          ],
        ),
        const SizedBox(height: 12),
        for (final reason in ex.reasons)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  TraceUi.reasonIcon(reason.tone),
                  size: 19,
                  color: TraceUi.reasonColor(reason.tone),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    reason.text,
                    style: const TextStyle(fontSize: 13.5, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
        if (ot != null && ot.status == TraceStatus.possible) ...[
          const SizedBox(height: 6),
          Text(
            'الاحتمالات',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          for (final m in ot.candidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TraceTxTile(
                txId: m.companyId,
                note: m.issues.map((i) => i.label).join(' • '),
                noteColor: const Color(0xFFD97706),
              ),
            ),
        ],
        if (ex.rejected.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            ot != null
                ? 'حركات قريبة ما انختارت'
                : 'حركات مكاتب قريبة ما انربطت',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          for (final x in ex.rejected)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TraceTxTile(
                txId: x.txId,
                dense: true,
                note: '✖ ${x.reason}',
                noteColor: const Color(0xFFDC2626),
              ),
            ),
        ],
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            'الحدود الحالية: الوقت العادي ${p.normalHoursSafe} ساعة، أقصى وقت '
            '${p.maxHoursSafe} ساعة، سماحية ${p.earlyMinutes} دقيقة (من الإعدادات '
            '← تتبّع مصدر الحركة).'
            '${since == null ? '' : '\nسجل التعديلات بلّش بتاريخ ${TxHistoryFormatter.day(since)}؛ الأسماء والمبالغ القديمة قبلها مو معروفة.'}',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================
// اختيار/تغيير المصدر
// =============================================================

Future<void> showTraceChooser(BuildContext context, int txId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _ChooserSheet(txId: txId),
  );
}

class _ChooserSheet extends StatefulWidget {
  final int txId;
  const _ChooserSheet({required this.txId});

  @override
  State<_ChooserSheet> createState() => _ChooserSheetState();
}

class _ChooserSheetState extends State<_ChooserSheet> {
  final TextEditingController _search = TextEditingController();
  String _q = '';
  bool _working = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('لا'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إيه'),
            ),
          ],
        ),
      ),
    );
    return ok ?? false;
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
      if (!mounted) return;
      Navigator.pop(context);
      _snack(context, done);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _pick(TraceResult r, TraceOption opt, bool isOffice) async {
    if (isOffice) {
      // حركة شركة ماسكتها حركة مكتب تانية
      final heldBy = opt.heldBy;
      if (heldBy != null && opt.heldManually) {
        final ok = await _confirm(
          'مربوطة يدويًا',
          'هالحركة مربوطة يدويًا بحركة تانية: '
              '${TraceService.describeTx(heldBy)}.\nبدك تنقل الربط لهون؟',
        );
        if (!ok) return;
      }
      await _run(() async {
        if (heldBy != null && opt.heldManually) {
          await TraceService.resetToAuto(heldBy);
        }
        await TraceService.linkManually(widget.txId, opt.txId);
      }, 'تم تحديد المصدر');
      return;
    }
    // من جهة الشركة: opt.txId حركة مكتب
    final ct = r.company[widget.txId];
    final active = ct?.activeOfficeId;
    final activeManual =
        active != null &&
        active != opt.txId &&
        r.office[active]?.status == TraceStatus.manual;
    if (opt.heldBy != null && opt.heldManually) {
      final ok = await _confirm(
        'حركة المكتب مربوطة',
        'حركة المكتب هي مربوطة يدويًا بحركة شركة تانية: '
            '${TraceService.describeTx(opt.heldBy!)}.\nبدك تربطها بهالحركة بدالها؟',
      );
      if (!ok) return;
    }
    if (activeManual) {
      final ok = await _confirm(
        'في ربط يدوي',
        'هالحركة مربوطة يدويًا بحركة مكتب تانية: '
            '${TraceService.describeTx(active)}.\nبدك تنقل الربط؟',
      );
      if (!ok) return;
    }
    await _run(() async {
      if (activeManual) await TraceService.resetToAuto(active);
      await TraceService.linkManually(opt.txId, widget.txId);
    }, 'تم الربط');
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        // الكيبورد ما يغطي قائمة البحث
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: .85,
          minChildSize: .5,
          maxChildSize: .95,
          builder: (context, controller) {
            final r = TraceService.result.value;
            if (r == null || !r.isTraced(widget.txId)) {
              return const Center(child: Text('ما في معلومات بعد'));
            }
            return _content(context, r, controller);
          },
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    TraceResult r,
    ScrollController controller,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isOffice = r.office.containsKey(widget.txId);
    final ot = r.office[widget.txId];
    final current = isOffice
        ? <int>{if (ot?.link != null) ot!.link!.companyId}
        : <int>{...?r.company[widget.txId]?.officeIds};
    final candidateIds = <int>{
      if (ot != null)
        for (final m in ot.candidates) m.companyId,
    };
    final q = _q.trim().toLowerCase();
    final all = r.optionsFor(widget.txId);
    final options = [
      for (final o in all)
        if (q.isEmpty || _matches(o, q)) o,
    ];
    // الاحتمالات أولًا
    options.sort((a, b) {
      final ca = candidateIds.contains(a.txId) ? 0 : 1;
      final cb = candidateIds.contains(b.txId) ? 0 : 1;
      return ca.compareTo(cb);
    });
    final hasDecision =
        isOffice && TraceService.decisions.byOffice.containsKey(widget.txId);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isOffice ? 'اختار مصدر الحركة' : 'اختار حركة المكتب',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isOffice
                    ? 'حركات الشركات من 7 أيام قبل حركة المكتب لحد يوم بعدها. '
                          'الأقرب تطابقًا أولًا.'
                    : 'حركات المكاتب من وقت الرسالة لحد 7 أيام بعدها.',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _search,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: 'دوّر بالاسم أو المبلغ أو الحساب…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: options.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'ما في حركات مناسبة بهالفترة',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                  itemCount: options.length,
                  itemBuilder: (context, i) {
                    final o = options[i];
                    final selected = current.contains(o.txId);
                    final heldNote = o.heldBy == null
                        ? null
                        : 'مربوطة حاليًا بـ ${TraceService.describeTx(o.heldBy!)}';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFF059669)
                                : Colors.transparent,
                            width: 1.6,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TraceTxTile(
                              txId: o.txId,
                              note: heldNote,
                              noteColor: const Color(0xFF7C3AED),
                              trailing: selected
                                  ? const Icon(
                                      Icons.check_circle_rounded,
                                      color: Color(0xFF059669),
                                    )
                                  : null,
                            ),
                            if (!o.match.amountSame)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: TraceAmountFix(
                                  officeId: isOffice ? widget.txId : o.txId,
                                  companyId: isOffice ? o.txId : widget.txId,
                                  onDone: () {
                                    if (mounted) Navigator.pop(context);
                                  },
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Expanded(child: TraceMatchChips(m: o.match)),
                                  const SizedBox(width: 8),
                                  TraceActionButton(
                                    icon: Icons.link_rounded,
                                    label: selected ? 'تأكيد' : 'اختيار',
                                    color: const Color(0xFF059669),
                                    filled: true,
                                    onPressed: _working
                                        ? null
                                        : () => _pick(r, o, isOffice),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (isOffice)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  TraceActionButton(
                    icon: Icons.help_outline_rounded,
                    label: 'المصدر «${r.prefs.unknown}»',
                    color: TraceUi.unknownColor,
                    onPressed: _working
                        ? null
                        : () => _run(
                            () => TraceService.markUnknown(widget.txId),
                            'تم تحديد المصدر «${r.prefs.unknown}»',
                          ),
                  ),
                  if (hasDecision)
                    TraceActionButton(
                      icon: Icons.autorenew_rounded,
                      label: 'رجوع للتلقائي',
                      color: cs.primary,
                      onPressed: _working
                          ? null
                          : () => _run(
                              () => TraceService.resetToAuto(widget.txId),
                              'رجع الربط للتلقائي',
                            ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  bool _matches(TraceOption o, String q) {
    final t = TraceService.txById(o.txId);
    if (t == null) return false;
    final text =
        '${TraceService.accountName(t.accountId)} ${t.beneficiary} '
                '${traceAmount(t.amount)} ${t.amount} ${t.currency}'
            .toLowerCase();
    return text.contains(q);
  }
}
