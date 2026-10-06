// lib/widgets/trace_widgets.dart
// -------------------------------------------------------------
// واجهة «مسار الحركة»:
//  • TracePathCard: بطاقة المسار بصفحة التفاصيل (شركة ABC ← مكتب X، أو
//    شركة ABC ← إرسال شركة XYZ، مع السلسلة إذا انلغت وراحت لمكان تاني) +
//    التحذيرات + الأزرار.
//  • showTraceReasons: صفحة «ليش؟» (أسباب اختيار المصدر والمرشحين المرفوضين).
//  • showTraceChooser: اختيار/تغيير المصدر (أو ربط حركة استقبال بحركة مكتب
//    أو إرسال بشركة تانية).
//  • أسماء الحسابات قابلة للضغط وبتفتح الحساب مع تحديد الحركة.
//  • TraceTxEvents: أحداث كل حركة بالمسار (وصلت/تسلّمت/التغت/انعدلت…) كل
//    حدث بسطر لحالو مع تاريخه.
//  • TraceNameFix / TraceAmountFix: لما الاسم/المبلغ مختلف بين حركة المكتب
//    وحركة الشركة: زر «خلّي اسم/مبلغ المكتب متل الشركة» أو العكس، مع رسالة
//    تأكيد.
// -------------------------------------------------------------

import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../screens/account_screen.dart';
import '../screens/transaction_details_screen.dart';
import '../services/trace/trace_service.dart';
import '../services/trace/trace_timeline.dart';
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

  /// حركة إرسال بشركة (بدور الوجهة)
  static const Color sent = Color(0xFF5E35B1);

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

  /// حركة «إرسال» بحساب شركة بدور الوجهة (مصدرها استقبال بشركة تانية)
  static bool isSentDest(TransactionModel t) =>
      TraceService.prefs.value.sentAsDest &&
      isCompanyTx(t) &&
      TraceEngine.movementOf(t).isSent;

  /// تسمية طرفي الربط لحركة الوجهة [officeId]: (المصدر، الوجهة) =
  /// («الشركة»، «المكتب») أو («الاستقبال»، «الإرسال»)
  static (String, String) pairSides(int officeId) =>
      TraceService.isSentDest(officeId)
      ? ('الاستقبال', 'الإرسال')
      : ('الشركة', 'المكتب');

  /// لون طرف الوجهة [officeId]: المكتب، أو الإرسال
  static Color destColor(int officeId) =>
      TraceService.isSentDest(officeId) ? sent : office;

  /// لون وأيقونة الحركة: مكتب / شركة (استقبال) / إرسال (بدور الوجهة)
  static (Color, IconData) txLook(TransactionModel t) {
    if (!isCompanyTx(t)) return (office, Icons.storefront_rounded);
    if (isSentDest(t)) return (sent, Icons.outbox_rounded);
    return (company, Icons.business_rounded);
  }

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

  static const Color delivered = Color(0xFF059669);
  static const Color cancelled = Color(0xFFDC2626);

  /// اسم حدث الوصول («وصلت للمكتب» / «وصلت للشركة» / «انبعتت من الشركة»)
  static String arrivalLabel(TransactionModel t) =>
      traceArrivalLabel(t, isCompany: isCompanyTx(t));

  /// التسليم/الإلغاء مع تاريخه («التغت: 2026-10-02 09:10») أو null
  static (String, Color)? statusWhen(TransactionModel t) {
    String at(DateTime? d) => d == null ? '' : ': ${when(d)}';
    if (isCompanyTx(t)) {
      if (!t.isCompanyCancelled) return null;
      return ('التغت بالشركة${at(t.cancelledAt)}', cancelled);
    }
    switch (t.status) {
      case TransactionStatus.added:
        return null;
      case TransactionStatus.received:
        return ('تسلّمت${at(t.receivedAt)}', delivered);
      case TransactionStatus.cancelled:
        return ('التغت${at(t.cancelledAt)}', cancelled);
    }
  }

  static Color eventColor(TraceEventKind k) {
    switch (k) {
      case TraceEventKind.arrived:
        return office;
      case TraceEventKind.sent:
        return company;
      case TraceEventKind.delivered:
        return delivered;
      case TraceEventKind.cancelled:
        return cancelled;
      case TraceEventKind.reopened:
        return const Color(0xFFD97706);
      case TraceEventKind.deleted:
        return unknownColor;
      case TraceEventKind.restored:
        return const Color(0xFF0D9488);
      case TraceEventKind.edited:
        return const Color(0xFF7C3AED);
      case TraceEventKind.moved:
        return const Color(0xFF8D6E63);
      case TraceEventKind.destination:
        return destOffice;
      case TraceEventKind.linked:
        return const Color(0xFF0284C7);
    }
  }

  static IconData eventIcon(TraceEventKind k) {
    switch (k) {
      case TraceEventKind.arrived:
        return Icons.call_received_rounded;
      case TraceEventKind.sent:
        return Icons.call_made_rounded;
      case TraceEventKind.delivered:
        return Icons.check_circle_rounded;
      case TraceEventKind.cancelled:
        return Icons.cancel_rounded;
      case TraceEventKind.reopened:
        return Icons.undo_rounded;
      case TraceEventKind.deleted:
        return Icons.delete_outline_rounded;
      case TraceEventKind.restored:
        return Icons.restore_from_trash_rounded;
      case TraceEventKind.edited:
        return Icons.edit_rounded;
      case TraceEventKind.moved:
        return Icons.drive_file_move_rounded;
      case TraceEventKind.destination:
        return Icons.place_rounded;
      case TraceEventKind.linked:
        return Icons.link_rounded;
    }
  }

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
    final (color, txIcon) = TraceUi.txLook(t);
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
            Icon(txIcon, size: 20, color: color),
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
                    '${TraceUi.arrivalLabel(t)}: ${TraceUi.when(t.date)}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  if (TraceUi.statusWhen(t) case (final text, final c))
                    Text(
                      text,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: c,
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
  final (srcSide, destSide) = TraceUi.pairSides(officeId);
  final currencyDiffers =
      TraceService.result.value
          ?.evaluatePair(officeId, companyId)
          ?.currencySame ==
      false;
  final confirmed = TraceService.isConfirmedPair(officeId, companyId);
  var link = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: StatefulBuilder(
        builder: (ctx, setLocal) {
          final cs = Theme.of(ctx).colorScheme;
          final color = officeTakesCompany
              ? TraceUi.destColor(officeId)
              : TraceUi.company;
          return AlertDialog(
            icon: Icon(Icons.edit_note_rounded, color: color, size: 34),
            title: Text(
              officeTakesCompany
                  ? 'تعديل مبلغ حركة $destSide'
                  : 'تعديل مبلغ حركة $srcSide',
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
                              ' — متل ${officeTakesCompany ? 'حركة' : 'حركة $destSide'} '
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
                  _alignLinkOption(
                    confirmed: confirmed,
                    value: link,
                    onChanged: (v) => setLocal(() => link = v),
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
  final linkNow = link && !confirmed;
  final value = await TraceService.alignAmount(
    officeId,
    companyId,
    officeTakesCompany: officeTakesCompany,
    link: linkNow,
  );
  if (!context.mounted) return value != null;
  if (value == null) {
    _snack(context, 'تعذّر التعديل: الحركة ما عادت موجودة');
    return false;
  }
  _snack(
    context,
    'تم تعديل مبلغ ${officeTakesCompany ? 'حركة $destSide' : 'حركة $srcSide'} '
    'لـ ${traceAmount(value)}${linkNow ? ' وتأكيد المصدر' : ''}',
  );
  return true;
}

/// بحوار التوحيد: «وأكّد إنها مصدر الحركة»، أو سطر «الربط مؤكد» إذا الربط
/// بين الحركتين مؤكد من قبل.
Widget _alignLinkOption({
  required bool confirmed,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  if (confirmed) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(Icons.verified_rounded, size: 18, color: Color(0xFF7C3AED)),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'الربط بين الحركتين مؤكد من قبل',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
  return CheckboxListTile(
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    value: value,
    onChanged: (v) => onChanged(v ?? true),
    title: const Text(
      'وأكّد إنها مصدر الحركة (ربط الحركتين)',
      style: TextStyle(fontWeight: FontWeight.w700),
    ),
  );
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
    final (srcSide, destSide) = TraceUi.pairSides(officeId);
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
                  'المبلغ مختلف: ب$srcSide ${traceAmount(c.amount)} '
                  'وب$destSide ${traceAmount(o.amount)}',
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
                label: 'خلّي مبلغ $destSide ${traceAmount(c.amount)}',
                color: TraceUi.destColor(officeId),
                onPressed: () => fix(true),
              ),
              TraceActionButton(
                icon: Icons.edit_rounded,
                label: 'خلّي مبلغ $srcSide ${traceAmount(o.amount)}',
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
// توحيد الاسم (لما يكون اسم حركة المكتب غير اسم حركة الشركة)
// =============================================================

const Color _nameFixColor = Color(0xFFD97706);
final RegExp _nameSpaceRe = RegExp(r'\s+');

/// الاسم مختلف بين حركة المكتب وحركة الشركة؟ (القيم الحالية وبنفس مقارنة
/// التتبّع: الهمزات والمسافات و«عبد الله/عبدالله» ما بتفرق)
bool traceNamesDiffer(int officeId, int companyId) {
  final o = TraceService.txById(officeId);
  final c = TraceService.txById(companyId);
  if (o == null || c == null) return false;
  return _namesDiffer(o.beneficiary, c.beneficiary);
}

bool _namesDiffer(String a, String b) =>
    TraceEngine.keysOf(a).join(' ') != TraceEngine.keysOf(b).join(' ');

/// وصف الفرق بين اسمين متشابهين («كلمة زيادة: «علي»»…) أو null
String? traceNameDiffNote(String a, String b) =>
    similarNameNote(TraceEngine.keysOf(a), TraceEngine.keysOf(b));

/// كلمات [name] مع تمييز الكلمات يلي مو موجودة بـ [other] (بلون [hi]).
/// [underline] = خط تحت الكلمة المميزة (وإلا بتورث زخرفة النص).
List<InlineSpan> _nameDiffSpans(
  String name,
  String other,
  Color hi, {
  bool underline = true,
}) {
  final words = [
    for (final w in name.trim().split(_nameSpaceRe))
      if (w.isNotEmpty) w,
  ];
  if (words.isEmpty) {
    return const [
      TextSpan(
        text: 'بلا اسم',
        style: TextStyle(fontStyle: FontStyle.italic),
      ),
    ];
  }
  final otherKeys = <String>{
    ...TraceEngine.keysOf(other),
    for (final w in other.trim().split(_nameSpaceRe)) ...TraceEngine.keysOf(w),
  };
  final present = [
    for (final w in words)
      TraceEngine.keysOf(w).isEmpty ||
          TraceEngine.keysOf(w).any(otherKeys.contains),
  ];
  // «عبد الله» هون و«عبدالله» هونيك
  for (var i = 0; i + 1 < words.length; i++) {
    final pair = TraceEngine.keysOf('${words[i]} ${words[i + 1]}');
    if (pair.length == 1 && otherKeys.contains(pair.first)) {
      present[i] = true;
      present[i + 1] = true;
    }
  }
  final hiStyle = TextStyle(
    color: hi,
    fontWeight: FontWeight.w900,
    decoration: underline ? TextDecoration.underline : null,
    decorationColor: hi.withValues(alpha: .6),
  );
  return [
    for (var i = 0; i < words.length; i++) ...[
      if (i > 0) const TextSpan(text: ' '),
      TextSpan(text: words[i], style: present[i] ? null : hiStyle),
    ],
  ];
}

/// يسأل للتأكيد وبعدين بيعدّل الاسم. [officeTakesCompany] = حركة المكتب
/// بتاخد اسم حركة الشركة (وإلا العكس). بيرجع true إذا انعدل.
Future<bool> confirmTraceNameFix(
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
  final oldName = target.beneficiary.trim();
  final newName = source.beneficiary.trim();
  final (srcSide, destSide) = TraceUi.pairSides(officeId);
  if (newName.isEmpty) {
    _snack(
      context,
      'اسم ${officeTakesCompany ? 'حركة $srcSide' : 'حركة $destSide'} فاضي',
    );
    return false;
  }
  final note = traceNameDiffNote(o.beneficiary, c.beneficiary);
  final amountDiffers = (o.amount - c.amount).abs() >= 0.005;
  final confirmed = TraceService.isConfirmedPair(officeId, companyId);
  var link = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: StatefulBuilder(
        builder: (ctx, setLocal) {
          final cs = Theme.of(ctx).colorScheme;
          final color = officeTakesCompany
              ? TraceUi.destColor(officeId)
              : TraceUi.company;
          const red = Color(0xFFDC2626);
          const green = Color(0xFF059669);
          Widget nameBox(
            String label,
            String name,
            String other,
            Color tone, {
            bool strike = false,
          }) {
            return Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: TraceUi.tint(ctx, tone, .07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: tone.withValues(alpha: .3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: tone,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: _nameDiffSpans(
                          name,
                          other,
                          tone,
                          underline: !strike,
                        ),
                      ),
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.4,
                        fontWeight: FontWeight.w700,
                        color: strike
                            ? cs.onSurface.withValues(alpha: .7)
                            : cs.onSurface,
                        decoration: strike ? TextDecoration.lineThrough : null,
                        decorationColor: tone,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            icon: Icon(
              Icons.drive_file_rename_outline_rounded,
              color: color,
              size: 34,
            ),
            title: Text(
              officeTakesCompany
                  ? 'تعديل اسم حركة $destSide'
                  : 'تعديل اسم حركة $srcSide',
              textAlign: TextAlign.center,
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${TraceUi.accountTitle(target)} • '
                            '${traceAmount(target.amount)} ${target.currency}'
                        .trim(),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'الاسم رح يتغيّر:',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  nameBox('قبل', oldName, newName, red, strike: true),
                  nameBox('بعد', newName, oldName, green),
                  const SizedBox(height: 6),
                  Text(
                    'متل ${officeTakesCompany ? 'حركة' : 'حركة $destSide'} '
                    '${TraceUi.accountTitle(source)}.',
                    style: const TextStyle(fontSize: 14, height: 1.4),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 15,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            note,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (amountDiffers) ...[
                    const SizedBox(height: 8),
                    Text(
                      '⚠️ المبلغ كمان مختلف (ب$srcSide ${traceAmount(c.amount)} '
                      'وب$destSide ${traceAmount(o.amount)}) — المبلغ ما رح '
                      'يتغيّر، فيك توحّده من صندوق «المبلغ مختلف».',
                      style: const TextStyle(
                        color: Color(0xFFD97706),
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  _alignLinkOption(
                    confirmed: confirmed,
                    value: link,
                    onChanged: (v) => setLocal(() => link = v),
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
                label: const Text('تعديل الاسم'),
              ),
            ],
          );
        },
      ),
    ),
  );
  if (ok != true) return false;
  final linkNow = link && !confirmed;
  final value = await TraceService.alignName(
    officeId,
    companyId,
    officeTakesCompany: officeTakesCompany,
    link: linkNow,
  );
  if (!context.mounted) return value != null;
  if (value == null) {
    _snack(context, 'تعذّر التعديل: الحركة ما عادت موجودة');
    return false;
  }
  _snack(
    context,
    'تم تعديل اسم ${officeTakesCompany ? 'حركة $destSide' : 'حركة $srcSide'} '
    'لـ «$value»${linkNow ? ' وتأكيد المصدر' : ''}',
  );
  return true;
}

/// صندوق «الاسم مختلف» مع زرّين: اسم المكتب متل الشركة، أو العكس
class TraceNameFix extends StatelessWidget {
  final int officeId;
  final int companyId;

  /// بعد التعديل (مثلًا سكّر القائمة)
  final VoidCallback? onDone;

  const TraceNameFix({
    super.key,
    required this.officeId,
    required this.companyId,
    this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final o = TraceService.txById(officeId);
    final c = TraceService.txById(companyId);
    if (o == null || c == null || !_namesDiffer(o.beneficiary, c.beneficiary)) {
      return const SizedBox.shrink();
    }
    const color = _nameFixColor;
    final cs = Theme.of(context).colorScheme;
    final note = traceNameDiffNote(o.beneficiary, c.beneficiary);
    final (srcSide, destSide) = TraceUi.pairSides(officeId);
    Future<void> fix(bool officeTakesCompany) async {
      final done = await confirmTraceNameFix(
        context,
        officeId: officeId,
        companyId: companyId,
        officeTakesCompany: officeTakesCompany,
      );
      if (done) onDone?.call();
    }

    Widget line(String label, Color tone, String name, String other) {
      return Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              constraints: const BoxConstraints(minWidth: 52),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: TraceUi.tint(context, tone, .12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: tone,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: _nameDiffSpans(name, other, color)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TraceUi.tint(context, color, .06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.badge_rounded, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  note == null ? 'الاسم مختلف' : 'الاسم مختلف • $note',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          line(srcSide, TraceUi.company, c.beneficiary, o.beneficiary),
          line(
            destSide,
            TraceUi.destColor(officeId),
            o.beneficiary,
            c.beneficiary,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (c.beneficiary.trim().isNotEmpty)
                TraceActionButton(
                  icon: Icons.edit_rounded,
                  label: 'خلّي اسم $destSide متل $srcSide',
                  color: TraceUi.destColor(officeId),
                  onPressed: () => fix(true),
                ),
              if (o.beneficiary.trim().isNotEmpty)
                TraceActionButton(
                  icon: Icons.edit_rounded,
                  label: 'خلّي اسم $srcSide متل $destSide',
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
            : (TraceUi.isCompanyTx(tx)
                  ? 'ما في حركة استقبال مطابقة بشركة تانية'
                  : 'ما في حركة شركة مطابقة'),
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
    final sentOn = r.prefs.sentAsDest;
    final prevTx = prev == null ? null : TraceService.txById(prev);
    final prevSent = prevTx != null && TraceUi.isCompanyTx(prevTx);
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
            title: ct.cancelled
                ? 'ملغاة بالشركة'
                : (sentOn
                      ? 'لسا ما راحت لمكتب ولا إرسال'
                      : 'لسا ما وصلت لأي مكتب'),
            line: ct.overdue
                ? 'صار إلها ${traceDuration(waited)} — وجهتها «${ct.destination}» '
                      'تابعة لمكتب'
                : (ct.mustReach
                      ? 'وجهتها «${ct.destination}» — لازم توصل لمكتب'
                            '${sentOn ? ' أو تنبعت' : ''}'
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
            connector: prev != null
                ? (prevSent ? 'انلغى الإرسال' : 'انلغت من المكتب')
                : null,
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
    } else if (ct != null && ct.reachedSent) {
      headColor = const Color(0xFF059669);
      headLabel = 'راحت لشركة (إرسال)';
      headIcon = Icons.outbox_rounded;
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
              compact: compact,
            ),
          if (!compact &&
              isOffice &&
              ot.status == TraceStatus.possible &&
              ot.candidates.isNotEmpty) ...[
            const SizedBox(height: 10),
            _possibleBox(context, ot),
          ],
          if (!compact && isOffice && ot.status.linked && ot.link != null) ...[
            TraceNameFix(officeId: tx.id, companyId: ot.link!.companyId),
            TraceAmountFix(officeId: tx.id, companyId: ot.link!.companyId),
          ],
          if (ct?.activeOfficeId case final activeId?
              when !compact && !isOffice) ...[
            TraceNameFix(officeId: activeId, companyId: tx.id),
            TraceAmountFix(officeId: activeId, companyId: tx.id),
          ],
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
          TraceNameFix(officeId: tx.id, companyId: top.companyId),
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
          label: r.prefs.sentAsDest
              ? (ct.reached ? 'تغيير الوجهة' : 'ربط بمكتب أو إرسال')
              : (ct.reached ? 'تغيير المكتب' : 'ربط بحركة مكتب'),
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

  /// صفحة السجل: أحداث الحالة بس (التعديلات معروضة بالسجل نفسه)
  final bool compact;

  const _StopRow({
    required this.stop,
    required this.first,
    required this.last,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = stop.txId == null ? null : TraceService.txById(stop.txId!);
    final look = t == null ? null : TraceUi.txLook(t);
    final color = stop.placeholderColor ?? look?.$1 ?? TraceUi.unknownColor;
    final icon =
        stop.placeholderIcon ?? look?.$2 ?? Icons.delete_outline_rounded;
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
                  TraceTxEvents(txId: t.id, includeEdits: !compact),
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

// =============================================================
// أحداث الحركة: كل تغيير بسطر لحالو مع تاريخه
// =============================================================

/// «وصلت للمكتب • 2026-10-01 14:20»، «التغت • 2026-10-02 09:10 (بعد 19 ساعة
/// من الوصول)»، «انعدل المبلغ من 900 إلى 1.000 دولار»…
class TraceTxEvents extends StatefulWidget {
  final int txId;

  /// مع التعديلات (الاسم/المبلغ/الوجهة…)، وإلا الحالة بس
  final bool includeEdits;

  const TraceTxEvents({
    super.key,
    required this.txId,
    this.includeEdits = true,
  });

  @override
  State<TraceTxEvents> createState() => _TraceTxEventsState();
}

class _TraceTxEventsState extends State<TraceTxEvents> {
  /// التعديلات الظاهرة قبل «كل التغييرات» (أحداث الحالة بتبين دايمًا)
  static const int _collapsedEdits = 3;

  List<TxHistoryEntry> _history = const [];
  Timer? _debounce;
  bool _expanded = false;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    TxHistoryService.revision.addListener(_onHistory);
    _load();
  }

  @override
  void didUpdateWidget(covariant TraceTxEvents oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.txId != widget.txId) {
      _history = const [];
      _expanded = false;
      _load();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    TxHistoryService.revision.removeListener(_onHistory);
    super.dispose();
  }

  void _onHistory() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _load);
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    List<TxHistoryEntry> entries;
    try {
      entries = await TxHistoryService.entriesFor(widget.txId);
    } catch (_) {
      return;
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() => _history = entries);
  }

  @override
  Widget build(BuildContext context) {
    final t = TraceService.txById(widget.txId);
    if (t == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final all = traceTxEvents(
      t,
      isCompany: TraceUi.isCompanyTx(t),
      history: _history,
      includeEdits: widget.includeEdits,
      formatter: const TxHistoryFormatter(
        accountNameOf: TraceService.accountName,
      ),
    );
    final edits = [
      for (final e in all)
        if (!e.kind.isStatus) e,
    ];
    var shown = all;
    final collapsible = edits.length > _collapsedEdits;
    if (collapsible && !_expanded) {
      final keep = edits.sublist(edits.length - _collapsedEdits).toSet();
      shown = [
        for (final e in all)
          if (e.kind.isStatus || keep.contains(e)) e,
      ];
    }
    final hidden = all.length - shown.length;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      decoration: BoxDecoration(
        color: TraceUi.tint(context, cs.onSurface, .035),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in shown) _row(context, e, t.date),
          if (collapsible)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                ),
                label: Text(
                  _expanded
                      ? 'إخفاء التعديلات القديمة'
                      : 'كل التغييرات (+$hidden)',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, TraceTxEvent e, DateTime start) {
    final cs = Theme.of(context).colorScheme;
    final color = TraceUi.eventColor(e.kind);
    final at = e.at;
    String? gap;
    if (at != null &&
        (e.kind == TraceEventKind.delivered ||
            e.kind == TraceEventKind.cancelled) &&
        !at.isBefore(start)) {
      gap = 'بعد ${traceDuration(at.difference(start))} من الوصول';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: TraceUi.tint(context, color, .14),
              shape: BoxShape.circle,
            ),
            child: Icon(TraceUi.eventIcon(e.kind), size: 13, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: e.label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                          color: e.kind.isStatus ? color : cs.onSurface,
                        ),
                      ),
                      TextSpan(
                        text:
                            '  •  ${at == null ? 'الوقت مو معروف' : TraceUi.when(at)}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (e.detail != null)
                  Text(
                    e.detail!,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                if (gap != null)
                  Text(
                    gap,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: color,
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
                : (TraceService.prefs.value.sentAsDest
                      ? 'حركات قريبة ما انربطت (مكاتب وإرسال)'
                      : 'حركات مكاتب قريبة ما انربطت'),
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
      final noun = TraceService.isSentDest(opt.txId)
          ? 'حركة الإرسال'
          : 'حركة المكتب';
      final ok = await _confirm(
        '$noun مربوطة',
        '$noun هي مربوطة يدويًا بحركة شركة تانية: '
            '${TraceService.describeTx(opt.heldBy!)}.\nبدك تربطها بهالحركة بدالها؟',
      );
      if (!ok) return;
    }
    if (activeManual) {
      final ok = await _confirm(
        'في ربط يدوي',
        'هالحركة مربوطة يدويًا ب${TraceService.destNoun(active)} تانية: '
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
    // صندوق «الاسم مختلف» بس للحركات يلي ممكن تكون هي نفسها (مو لكل حركات
    // الفترة)
    final plausible = <int>{
      ...candidateIds,
      ...current,
      ...?r.company[widget.txId]?.possibleOfficeIds,
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
    final sentOn = r.prefs.sentAsDest;
    final isSent = isOffice && TraceService.isSentDest(widget.txId);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isOffice
                    ? 'اختار مصدر الحركة'
                    : (sentOn ? 'اختار وين راحت' : 'اختار حركة المكتب'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isOffice
                    ? (isSent
                          ? 'حركات الاستقبال بالشركات التانية من 7 أيام قبل '
                                'حركة الإرسال لحد يوم بعدها. الأقرب تطابقًا أولًا.'
                          : 'حركات الشركات من 7 أيام قبل حركة المكتب لحد يوم '
                                'بعدها. الأقرب تطابقًا أولًا.')
                    : (sentOn
                          ? 'حركات المكاتب والإرسال بالشركات التانية من وقت '
                                'الرسالة لحد 7 أيام بعدها.'
                          : 'حركات المكاتب من وقت الرسالة لحد 7 أيام بعدها.'),
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
                            if (o.match.nameFit != TraceNameFit.different ||
                                plausible.contains(o.txId))
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: TraceNameFix(
                                  officeId: isOffice ? widget.txId : o.txId,
                                  companyId: isOffice ? o.txId : widget.txId,
                                  onDone: () {
                                    if (mounted) Navigator.pop(context);
                                  },
                                ),
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
