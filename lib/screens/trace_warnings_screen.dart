// lib/screens/trace_warnings_screen.dart
// -------------------------------------------------------------
// صفحة «التحذيرات» لتتبّع مصدر الحركة:
//  • التحذيرات: اسم مو مطابق، مبلغ/عملة مختلفة، أكتر من احتمال، حركة قديمة،
//    تعديل بطرف واحد، ملغاة بالشركة وفعّالة بالمكتب، ما راحت لمكتب...
//    مع أزرار «هي نفسها / مو هي / مجهول / تأكيد / تجاهل».
//  • لسا ما راحت: حركات الاستقبال بالشركات يلي لسا ما انربطت بحركة مكتب
//    (أو إرسال بشركة تانية).
//  • مصدرها مجهول: حركات المكاتب بدون مصدر معروف (والإرسال المحتمل بس).
// -------------------------------------------------------------

import 'package:flutter/material.dart';

import '../services/trace/trace_service.dart';
import '../widgets/trace_widgets.dart';

enum _Filter {
  all,
  choose,
  name,
  money,
  late,
  edits,
  status,
  notReached,
  route,
  broken,
}

extension on _Filter {
  String get label {
    switch (this) {
      case _Filter.all:
        return 'الكل';
      case _Filter.choose:
        return 'بدها اختيار';
      case _Filter.name:
        return 'الاسم';
      case _Filter.money:
        return 'المبلغ والعملة';
      case _Filter.late:
        return 'قديمة';
      case _Filter.edits:
        return 'تعديلات';
      case _Filter.status:
        return 'الحالة';
      case _Filter.notReached:
        return 'ما راحت لمكتب';
      case _Filter.route:
        return 'المسار والوجهة';
      case _Filter.broken:
        return 'ربط مكسور';
    }
  }

  bool matches(TraceWarning w) {
    switch (this) {
      case _Filter.all:
        return true;
      case _Filter.choose:
        return w.kind == TraceWarningKind.choose;
      case _Filter.name:
        return w.kind == TraceWarningKind.choose &&
            w.issues.contains(TraceIssue.nameNotExact);
      case _Filter.money:
        return w.kind == TraceWarningKind.choose &&
            (w.issues.contains(TraceIssue.amountDiffers) ||
                w.issues.contains(TraceIssue.currencyDiffers));
      case _Filter.late:
        return w.kind == TraceWarningKind.late;
      case _Filter.edits:
        return w.kind == TraceWarningKind.editedOneSide ||
            w.kind == TraceWarningKind.valuesDiffer ||
            w.kind == TraceWarningKind.confirmedChanged;
      case _Filter.status:
        return w.kind == TraceWarningKind.companyCancelled;
      case _Filter.notReached:
        return w.kind == TraceWarningKind.notReached;
      case _Filter.route:
        return w.kind == TraceWarningKind.routeChanged ||
            w.kind == TraceWarningKind.wrongOffice;
      case _Filter.broken:
        return w.kind == TraceWarningKind.brokenLink;
    }
  }
}

class TraceWarningsScreen extends StatefulWidget {
  /// 0 = التحذيرات، 1 = لسا ما راحت، 2 = مصدرها مجهول
  final int initialTab;

  const TraceWarningsScreen({super.key, this.initialTab = 0});

  @override
  State<TraceWarningsScreen> createState() => _TraceWarningsScreenState();
}

class _TraceWarningsScreenState extends State<TraceWarningsScreen> {
  late int _tab = widget.initialTab.clamp(0, 2);
  _Filter _filter = _Filter.all;
  bool _showDismissed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: dark ? null : const Color(0xFFF6F8FC),
        appBar: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
          centerTitle: true,
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'التحذيرات',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              ),
              Text(
                'مصدر ووجهة الحركات',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            ValueListenableBuilder<bool>(
              valueListenable: TraceService.computing,
              builder: (context, busy, _) => busy
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: 'إعادة الفحص',
                      onPressed: () => TraceService.schedule(immediate: true),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
            ),
          ],
        ),
        body: ValueListenableBuilder<TraceResult?>(
          valueListenable: TraceService.result,
          builder: (context, r, _) {
            if (r == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return _body(context, r);
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context, TraceResult r) {
    final active = r.activeWarnings;
    final notReached = _notReached(r);
    final unknown = _unknownSources(r);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: _tabs(
              context,
              active.length,
              notReached.length,
              unknown.length,
            ),
          ),
        ),
        if (_tab == 0) ..._warningsTab(context, r),
        if (_tab == 1) ..._txListTab(context, r, notReached, company: true),
        if (_tab == 2) ..._txListTab(context, r, unknown, company: false),
        SliverToBoxAdapter(
          child: SizedBox(height: 28 + MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }

  Widget _tabs(BuildContext context, int a, int b, int c) {
    final cs = Theme.of(context).colorScheme;
    Widget tab(int i, String label, int n, IconData icon) {
      final selected = _tab == i;
      return Expanded(
        child: Material(
          color: selected ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _tab = i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Column(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$label ($n)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: selected ? cs.onPrimary : cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          tab(0, 'التحذيرات', a, Icons.warning_amber_rounded),
          tab(1, 'لسا ما راحت', b, Icons.hourglass_empty_rounded),
          tab(2, 'مصدرها مجهول', c, Icons.help_outline_rounded),
        ],
      ),
    );
  }

  // ---------------------------------------------------------
  // التحذيرات
  // ---------------------------------------------------------

  List<Widget> _warningsTab(BuildContext context, TraceResult r) {
    final cs = Theme.of(context).colorScheme;
    final base = [
      for (final w in r.warnings)
        if (_showDismissed || !r.isDismissed(w)) w,
    ];
    final dismissedCount = r.warnings.where(r.isDismissed).length;
    final counts = <_Filter, int>{
      for (final f in _Filter.values) f: base.where(f.matches).length,
    };
    final shown = base.where(_filter.matches).toList();
    return [
      SliverToBoxAdapter(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              for (final f in _Filter.values)
                if (f == _Filter.all || counts[f]! > 0 || _filter == f)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: ChoiceChip(
                      label: Text('${f.label} (${counts[f]})'),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                      showCheckmark: false,
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: _filter == f ? cs.onPrimary : cs.onSurface,
                      ),
                      selectedColor: cs.primary,
                    ),
                  ),
            ],
          ),
        ),
      ),
      if (dismissedCount > 0)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _showDismissed = !_showDismissed),
                icon: Icon(
                  _showDismissed
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 18,
                ),
                label: Text(
                  _showDismissed
                      ? 'إخفاء المتجاهلة'
                      : 'عرض المتجاهلة ($dismissedCount)',
                ),
              ),
            ),
          ),
        ),
      if (shown.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: _empty(
            context,
            icon: Icons.verified_user_rounded,
            title: 'ما في تحذيرات',
            text:
                'كل حركات المكاتب يلي إلها مصدر بشركة مربوطة صح، أو ما في '
                'شي بدو انتباهك هلق.',
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          sliver: SliverList.builder(
            itemCount: shown.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _WarningCard(warning: shown[i], result: r),
            ),
          ),
        ),
    ];
  }

  // ---------------------------------------------------------
  // القوائم
  // ---------------------------------------------------------

  /// حركات الشركات يلي ما وصلت لمكتب: يلي وجهتها تابعة لمكتب أولًا، بعدين
  /// آخر 7 أيام. يلي وجهتها مو تابعة لمكتب ما منستناها فما بتطلع هون.
  List<int> _notReached(TraceResult r) {
    final since = DateTime.now().subtract(const Duration(days: 7));
    final must = <CompanyTrace>[];
    final recent = <CompanyTrace>[];
    for (final ct in r.company.values) {
      if (ct.reached || ct.cancelled || ct.external) continue;
      if (ct.mustReach) {
        must.add(ct);
      } else if (ct.waitingSince.isAfter(since)) {
        recent.add(ct);
      }
    }
    int byOverdue(CompanyTrace a, CompanyTrace b) {
      if (a.overdue != b.overdue) return a.overdue ? -1 : 1;
      return b.waitingSince.compareTo(a.waitingSince);
    }

    must.sort(byOverdue);
    recent.sort((a, b) => b.waitingSince.compareTo(a.waitingSince));
    return [
      for (final c in must) c.companyId,
      for (final c in recent) c.companyId,
    ];
  }

  /// حركات المكاتب بدون مصدر معروف (ضمن مدة التحذيرات)، المحتملة أولًا.
  /// حركات الإرسال بلا مصدر عادية (أغلبها من زباين)، فبتطلع بس المحتملة.
  List<int> _unknownSources(TraceResult r) {
    final days = r.prefs.warnDays;
    final since = days > 0
        ? DateTime.now().subtract(Duration(days: days))
        : null;
    final list = <int>[];
    for (final t in r.office.values) {
      if (t.status.linked) continue;
      final tx = TraceService.txById(t.officeId);
      if (tx == null) continue;
      if (since != null && tx.date.isBefore(since)) continue;
      if (t.status != TraceStatus.possible && TraceUi.isCompanyTx(tx)) {
        continue;
      }
      list.add(t.officeId);
    }
    list.sort((a, b) {
      final pa = r.office[a]!.status == TraceStatus.possible ? 0 : 1;
      final pb = r.office[b]!.status == TraceStatus.possible ? 0 : 1;
      if (pa != pb) return pa.compareTo(pb);
      final ta = TraceService.txById(a)!.date;
      final tb = TraceService.txById(b)!.date;
      return tb.compareTo(ta);
    });
    return list;
  }

  List<Widget> _txListTab(
    BuildContext context,
    TraceResult r,
    List<int> ids, {
    required bool company,
  }) {
    if (ids.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _empty(
            context,
            icon: company
                ? Icons.task_alt_rounded
                : Icons.travel_explore_rounded,
            title: company ? 'كل الحركات وصلت' : 'ما في حركات مجهولة المصدر',
            text: company
                ? 'ما في حركات استقبال بالشركات (آخر 7 أيام أو وجهتها تابعة '
                      'لمكتب) ناطرة ${r.prefs.sentAsDest ? 'مكتب أو إرسال' : 'مكتب'}.'
                : 'كل حركات المكاتب الأخيرة إلها مصدر معروف.',
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            company
                ? 'حركات استقبال بالشركات لسا ما انربطت بحركة مكتب'
                      '${r.prefs.sentAsDest ? ' ولا إرسال بشركة تانية' : ''}: '
                      'يلي وجهتها تابعة لمكتب أولًا، وبعدين آخر 7 أيام. (يلي '
                      'وجهتها مو تابعة لمكتب ما بتطلع هون.)'
                : 'حركات المكاتب الأخيرة بدون مصدر (حسب مدة التحذيرات '
                      'بالإعدادات): المحتملة (بدها اختيار) أولًا.'
                      '${r.prefs.sentAsDest ? ' حركات الإرسال بتطلع هون بس إذا إلها مصدر محتمل.' : ''}',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        sliver: SliverList.builder(
          itemCount: ids.length,
          itemBuilder: (context, i) {
            final id = ids[i];
            String? note;
            Color? noteColor;
            Widget? trailing;
            if (company) {
              final ct = r.company[id]!;
              final waited = DateTime.now().difference(ct.waitingSince);
              if (ct.overdue) {
                note = 'ما راحت لمكتب • صار إلها ${traceDuration(waited)}';
                noteColor = const Color(0xFFB91C1C);
              } else if (ct.mustReach) {
                note =
                    'وجهتها «${ct.destination}» • ناطرة من ${traceDuration(waited)}';
                noteColor = const Color(0xFFD97706);
              } else if (ct.officeIds.isNotEmpty) {
                final last = TraceService.txById(ct.officeIds.last);
                final lastSent = last != null && TraceUi.isCompanyTx(last);
                note =
                    '${lastSent ? 'انلغى الإرسال' : 'انلغت من المكتب'} • '
                    'ناطرة من ${traceDuration(waited)}';
              } else {
                note = 'ناطرة من ${traceDuration(waited)}';
              }
              if (ct.possibleOfficeIds.isNotEmpty) {
                note = '$note • في حركة محتملة';
              }
              trailing = IconButton(
                tooltip: r.prefs.sentAsDest
                    ? 'ربط بمكتب أو إرسال'
                    : 'ربط بحركة مكتب',
                onPressed: () => showTraceChooser(context, id),
                icon: const Icon(Icons.add_link_rounded, color: TraceUi.office),
              );
            } else {
              final t = r.office[id]!;
              if (t.status == TraceStatus.possible) {
                note = 'محتمل: ${t.issues.map((x) => x.label).join(' • ')}';
                noteColor = const Color(0xFFD97706);
              } else {
                note = TraceUi.statusLabel(t.status);
              }
              trailing = IconButton(
                tooltip: 'اختيار المصدر',
                onPressed: () => showTraceChooser(context, id),
                icon: const Icon(
                  Icons.swap_horiz_rounded,
                  color: TraceUi.company,
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TraceTxTile(
                txId: id,
                note: note,
                noteColor: noteColor,
                trailing: trailing,
              ),
            );
          },
        ),
      ),
    ];
  }

  Widget _empty(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String text,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: .08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 40, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// بطاقة تحذير
// =============================================================

class _WarningCard extends StatelessWidget {
  final TraceWarning warning;
  final TraceResult result;

  const _WarningCard({required this.warning, required this.result});

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final dismissed = result.isDismissed(warning);
    final color = dismissed
        ? cs.onSurfaceVariant
        : TraceUi.warningColor(warning.kind);
    final officeId = warning.officeId;
    final companyId = warning.companyId;
    final ot = officeId == null ? null : result.office[officeId];

    return Container(
      decoration: BoxDecoration(
        color: dark ? cs.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .28)),
        boxShadow: dark
            ? null
            : [
                BoxShadow(
                  color: const Color(0xFF1E293B).withValues(alpha: .05),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: TraceUi.tint(context, color, .12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  TraceUi.warningIcon(warning.kind),
                  color: color,
                  size: 21,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dismissed ? '${warning.title} (متجاهَل)' : warning.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      warning.detail,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: cs.onSurface.withValues(alpha: .85),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (officeId != null) ...[
            TraceTxTile(txId: officeId, dense: true),
            const SizedBox(height: 8),
          ],
          if (warning.kind == TraceWarningKind.choose && ot != null)
            ..._candidates(context, ot)
          else if (companyId != null) ...[
            TraceTxTile(txId: companyId, dense: true),
            if (officeId != null) ...[
              TraceNameFix(officeId: officeId, companyId: companyId),
              TraceAmountFix(officeId: officeId, companyId: companyId),
            ],
            const SizedBox(height: 8),
          ],
          _actions(context, dismissed, ot),
        ],
      ),
    );
  }

  List<Widget> _candidates(BuildContext context, OfficeTrace ot) {
    final cs = Theme.of(context).colorScheme;
    final officeId = ot.officeId;
    return [
      Text(
        ot.candidates.length == 1 ? 'الاحتمال:' : 'الاحتمالات:',
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 12.5,
          color: cs.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 6),
      for (final m in ot.candidates.take(4))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: TraceUi.tint(context, const Color(0xFFD97706), .05),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TraceTxTile(
                  txId: m.companyId,
                  dense: true,
                  note: m.nameNote,
                  noteColor: const Color(0xFFD97706),
                ),
                const SizedBox(height: 8),
                TraceMatchChips(m: m),
                TraceNameFix(officeId: officeId, companyId: m.companyId),
                TraceAmountFix(officeId: officeId, companyId: m.companyId),
                const SizedBox(height: 8),
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
                        await TraceService.linkManually(officeId, m.companyId);
                        if (context.mounted) _snack(context, 'تم تأكيد المصدر');
                      },
                    ),
                    TraceActionButton(
                      icon: Icons.close_rounded,
                      label: 'مو هي',
                      color: const Color(0xFFDC2626),
                      onPressed: () async {
                        await TraceService.reject(officeId, m.companyId);
                        if (context.mounted) _snack(context, 'تم الاستبعاد');
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      if (ot.candidates.length > 4)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'و${ot.candidates.length - 4} احتمال تاني — اضغط «كل الخيارات»',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
    ];
  }

  Widget _actions(BuildContext context, bool dismissed, OfficeTrace? ot) {
    final cs = Theme.of(context).colorScheme;
    final officeId = warning.officeId;
    final companyId = warning.companyId;
    final buttons = <Widget>[];
    switch (warning.kind) {
      case TraceWarningKind.choose:
        if (officeId != null) {
          buttons.add(
            TraceActionButton(
              icon: Icons.help_outline_rounded,
              label: 'ولا وحدة (${result.prefs.unknown})',
              color: TraceUi.unknownColor,
              onPressed: () async {
                await TraceService.markUnknown(officeId);
                if (context.mounted) {
                  _snack(context, 'تم تحديد المصدر «${result.prefs.unknown}»');
                }
              },
            ),
          );
          buttons.add(
            TraceActionButton(
              icon: Icons.list_alt_rounded,
              label: 'كل الخيارات',
              color: TraceUi.company,
              onPressed: () => showTraceChooser(context, officeId),
            ),
          );
        }
      case TraceWarningKind.late:
      case TraceWarningKind.editedOneSide:
      case TraceWarningKind.valuesDiffer:
        if (officeId != null && companyId != null) {
          buttons.add(
            TraceActionButton(
              icon: Icons.verified_rounded,
              label: 'تأكيد الربط',
              color: const Color(0xFF059669),
              onPressed: () async {
                await TraceService.linkManually(officeId, companyId);
                if (context.mounted) _snack(context, 'تم تأكيد الربط');
              },
            ),
          );
          buttons.add(
            TraceActionButton(
              icon: Icons.swap_horiz_rounded,
              label: 'تغيير المصدر',
              color: TraceUi.company,
              onPressed: () => showTraceChooser(context, officeId),
            ),
          );
        }
      case TraceWarningKind.confirmedChanged:
        if (officeId != null && companyId != null) {
          buttons.add(
            TraceActionButton(
              icon: Icons.verified_rounded,
              label: 'تأكيد من جديد',
              color: const Color(0xFF059669),
              onPressed: () async {
                await TraceService.linkManually(officeId, companyId);
                if (context.mounted) _snack(context, 'تم التأكيد من جديد');
              },
            ),
          );
        }
      case TraceWarningKind.companyCancelled:
        break;
      case TraceWarningKind.notReached:
        if (companyId != null) {
          buttons.add(
            TraceActionButton(
              icon: Icons.add_link_rounded,
              label: result.prefs.sentAsDest
                  ? 'ربط بمكتب أو إرسال'
                  : 'ربط بحركة مكتب',
              color: TraceUi.office,
              onPressed: () => showTraceChooser(context, companyId),
            ),
          );
        }
      case TraceWarningKind.brokenLink:
        if (officeId != null) {
          buttons.add(
            TraceActionButton(
              icon: Icons.autorenew_rounded,
              label: 'رجوع للتلقائي',
              color: cs.primary,
              onPressed: () => TraceService.resetToAuto(officeId),
            ),
          );
        }
      case TraceWarningKind.routeChanged:
      case TraceWarningKind.wrongOffice:
        if (officeId != null) {
          buttons.add(
            TraceActionButton(
              icon: Icons.swap_horiz_rounded,
              label: 'تغيير المصدر',
              color: TraceUi.company,
              onPressed: () => showTraceChooser(context, officeId),
            ),
          );
        }
        if (companyId != null) {
          buttons.add(
            TraceActionButton(
              icon: Icons.place_rounded,
              label: 'فتح حركة الشركة',
              color: TraceUi.destExternal,
              onPressed: () => openTraceTx(context, companyId),
            ),
          );
        }
    }
    final reasonsId = officeId ?? companyId;
    if (reasonsId != null) {
      buttons.add(
        TraceActionButton(
          icon: Icons.psychology_alt_rounded,
          label: 'ليش؟',
          color: cs.primary,
          onPressed: () => showTraceReasons(context, reasonsId),
        ),
      );
    }
    if (warning.dismissable) {
      buttons.add(
        TextButton.icon(
          onPressed: () => dismissed
              ? TraceService.undismiss(warning.sig)
              : TraceService.dismiss(warning),
          icon: Icon(
            dismissed ? Icons.undo_rounded : Icons.visibility_off_rounded,
            size: 18,
          ),
          label: Text(dismissed ? 'إرجاع' : 'تجاهل'),
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
