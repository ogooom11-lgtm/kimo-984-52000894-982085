// lib/widgets/import_sheets.dart
// -------------------------------------------------------------
// واجهات استيراد الملفات لتحليل النص:
// - اختيار ما يُفعل بالملف المشارك: تحليل رسائله أو مطابقة غير المستلمة.
// - اختيار الحساب الذي سيُحلَّل الملف عليه (مع اقتراح الحسابات المذكورة فيه).
// - اختيار فترة الرسائل عند مشاركة محادثة واتساب مصدَّرة.
// - طبقة انتظار أثناء قراءة الملف.
// -------------------------------------------------------------

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/share_import/share_import_service.dart';

Color importAccountColor(Account account) {
  if (account.type.isCompany) return const Color(0xFF6D42C1);
  final hue = (account.name.trim().hashCode.abs() % 360).toDouble();
  return HSVColor.fromAHSV(1, hue, 0.62, 0.92).toColor();
}

/// طبقة انتظار بسيطة فوق كل الصفحات (بدون مسار في Navigator)
class ImportBusyOverlay {
  ImportBusyOverlay._(this._entry);

  final OverlayEntry? _entry;
  bool _removed = false;

  static ImportBusyOverlay show(BuildContext context, String label) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return ImportBusyOverlay._(null);
    final entry = OverlayEntry(
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return Material(
          color: Colors.black45,
          child: Center(
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.6),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    return ImportBusyOverlay._(entry);
  }

  void remove() {
    if (_removed) return;
    _removed = true;
    _entry?.remove();
  }
}

/// بطاقة صغيرة تعرض الملف المستورد (الاسم، النوع، عدد الرسائل، الملاحظات)
class ImportSummaryHeader extends StatelessWidget {
  final ImportSummary summary;
  final Color color;
  final bool dense;

  const ImportSummaryHeader({
    super.key,
    required this.summary,
    required this.color,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: dense ? 38 : 44,
          height: dense ? 38 : 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(Icons.description_rounded, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                summary.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${summary.kindLabel} • ${summary.messageCount} ${summary.countUnit}',
                style: TextStyle(color: muted, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// يعرض اختيار الحساب لتحليل الملف (أو مطابقته) عليه. يعيد null عند الإلغاء.
Future<Account?> showImportAccountPicker(
  BuildContext context, {
  required ImportSummary summary,
  required List<Account> accounts,
  Map<int, int> mentions = const {},
  String title = 'اختر الحساب لتحليل الملف عليه',
}) {
  return showModalBottomSheet<Account>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _AccountPickerSheet(
      summary: summary,
      accounts: accounts,
      mentions: mentions,
      title: title,
    ),
  );
}

class _AccountPickerSheet extends StatefulWidget {
  final ImportSummary summary;
  final List<Account> accounts;
  final Map<int, int> mentions;
  final String title;

  const _AccountPickerSheet({
    required this.summary,
    required this.accounts,
    required this.mentions,
    required this.title,
  });

  @override
  State<_AccountPickerSheet> createState() => _AccountPickerSheetState();
}

class _AccountPickerSheetState extends State<_AccountPickerSheet> {
  final _search = TextEditingController();
  bool _showNotes = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final q = _norm(_search.text);
    final filtered = widget.accounts
        .where(
          (a) =>
              q.isEmpty ||
              _norm(a.name).contains(q) ||
              a.keywords.any((k) => _norm(k).contains(q)),
        )
        .toList();
    final suggested =
        filtered.where((a) => (widget.mentions[a.id] ?? 0) > 0).toList()..sort(
          (a, b) => (widget.mentions[b.id] ?? 0).compareTo(
            widget.mentions[a.id] ?? 0,
          ),
        );
    final others = filtered
        .where((a) => (widget.mentions[a.id] ?? 0) == 0)
        .toList();
    final summary = widget.summary;
    final hasDetails = summary.notes.isNotEmpty || summary.errors.isNotEmpty;

    Widget sectionLabel(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        text,
        style: TextStyle(
          color: cs.primary,
          fontWeight: FontWeight.w800,
          fontSize: 12.5,
        ),
      ),
    );

    Widget tile(Account a) {
      final color = importAccountColor(a);
      final count = widget.mentions[a.id] ?? 0;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: color.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => Navigator.pop(context, a),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [color, Color.lerp(color, Colors.white, .35)!],
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                      ),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      a.type.isCompany
                          ? Icons.business_rounded
                          : Icons.wallet_rounded,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          a.type.label,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (count > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'مذكور $count',
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w800,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_left_rounded, color: color),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final maxHeight = MediaQuery.of(context).size.height * .82;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ImportSummaryHeader(
                      summary: summary,
                      color: cs.primary,
                      dense: true,
                    ),
                    if (hasDetails)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: () =>
                              setState(() => _showNotes = !_showNotes),
                          icon: Icon(
                            _showNotes
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                          ),
                          label: Text(
                            summary.errors.isNotEmpty
                                ? 'تفاصيل (${summary.errors.length} تنبيه)'
                                : 'تفاصيل القراءة',
                          ),
                        ),
                      ),
                    if (hasDetails && _showNotes) ...[
                      for (final e in summary.errors)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '⚠️ $e',
                            style: TextStyle(color: cs.error, fontSize: 12.5),
                          ),
                        ),
                      for (final n in summary.notes)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '• $n',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              if (widget.accounts.length > 6) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'ابحث عن حساب...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ],
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 4),
                  children: [
                    if (suggested.isNotEmpty) ...[
                      sectionLabel('مقترح (مذكور في الملف)'),
                      for (final a in suggested) tile(a),
                    ],
                    if (others.isNotEmpty) ...[
                      sectionLabel(
                        suggested.isEmpty ? 'الحسابات' : 'باقي الحسابات',
                      ),
                      for (final a in others) tile(a),
                    ],
                    if (filtered.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('لا يوجد حساب بهذا الاسم')),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ما يفعله المستخدم بالملف الذي شاركه مع التطبيق
enum SharedFileAction { analyze, reconcile }

/// يسأل المستخدم: تحليل رسائل الملف أم مطابقته مع الحوالات غير المستلمة؟
/// يعرض تحت كل خيار تفاصيله أو سبب عدم توفره. يعيد null عند الإلغاء.
Future<SharedFileAction?> showSharedFileActionSheet(
  BuildContext context, {
  required String fileTitle,
  required String kindLabel,
  String? analyzeDetail,
  String? analyzeUnavailable,
  String? reconcileDetail,
  String? reconcileUnavailable,
}) {
  return showModalBottomSheet<SharedFileAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final cs = theme.colorScheme;
      return Directionality(
        textDirection: TextDirection.rtl,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'ماذا تريد أن تفعل بالملف؟',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.table_chart_rounded,
                        color: cs.primary,
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fileTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            kindLabel,
                            style: TextStyle(
                              color: theme.textTheme.bodySmall?.color,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _ActionOption(
                icon: Icons.auto_awesome_rounded,
                color: cs.primary,
                title: 'تحليل الرسائل',
                subtitle:
                    'كل صف يصبح رسالة في صفحة تحليل النص لإضافة الحوالات أو تسليمها',
                detail: analyzeDetail,
                unavailable: analyzeUnavailable,
                onTap: () => Navigator.pop(ctx, SharedFileAction.analyze),
              ),
              const SizedBox(height: 10),
              _ActionOption(
                icon: Icons.compare_arrows_rounded,
                color: cs.tertiary,
                title: 'مطابقة غير المستلمة',
                subtitle:
                    'قارن الملف مع الحوالات غير المستلمة في الحساب الذي تختاره',
                detail: reconcileDetail,
                unavailable: reconcileUnavailable,
                onTap: () => Navigator.pop(ctx, SharedFileAction.reconcile),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ActionOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? detail;

  /// سبب عدم توفر الخيار (null = متاح)
  final String? unavailable;
  final VoidCallback onTap;

  const _ActionOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.detail,
    this.unavailable,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.color;
    final reason = unavailable;
    final enabled = reason == null;
    final c = enabled ? color : cs.outline;
    return Material(
      color: c.withValues(alpha: enabled ? .08 : .06),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [c, Color.lerp(c, Colors.white, .35)!],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: enabled ? null : muted,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: muted,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                    if (enabled && detail != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: .13),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          detail!,
                          style: TextStyle(
                            color: c,
                            fontWeight: FontWeight.w800,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                    if (reason != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: cs.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              reason,
                              style: TextStyle(
                                color: cs.error,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (enabled) ...[
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Icon(Icons.chevron_left_rounded, color: c),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

String _dayLabel(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';

/// يختار المستخدم أي رسائل محادثة واتساب سيحللها.
/// يعيد كل الرسائل مباشرة إذا كانت من يوم واحد، وnull عند الإلغاء.
Future<List<ImportMessage>?> pickWhatsAppRange(
  BuildContext context,
  ImportConversion conversion,
) async {
  final all = conversion.messages;
  final days = conversion.distinctDays;
  if (days.length <= 1) return all;

  final last = days.last;
  List<ImportMessage> since(DateTime from) => all
      .where((m) => m.timestamp == null || !m.timestamp!.isBefore(from))
      .toList();

  final options = <({String title, List<ImportMessage> messages})>[];
  void addOption(String title, List<ImportMessage> list) {
    if (list.isEmpty) return;
    if (options.any((o) => o.messages.length == list.length)) return;
    options.add((title: title, messages: list));
  }

  addOption('آخر يوم في المحادثة (${_dayLabel(last)})', since(last));
  addOption(
    'آخر 3 أيام من المحادثة',
    since(last.subtract(const Duration(days: 2))),
  );
  addOption(
    'آخر 7 أيام من المحادثة',
    since(last.subtract(const Duration(days: 6))),
  );
  addOption(
    'آخر 30 يومًا من المحادثة',
    since(last.subtract(const Duration(days: 29))),
  );
  addOption('كل الرسائل', all);

  const custom = -1;
  final choice = await showModalBottomSheet<int>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * .8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            const Text(
              'أي رسائل تريد تحليلها؟',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              'المحادثة فيها ${all.length} رسالة من ${_dayLabel(days.first)} إلى ${_dayLabel(last)}',
              style: TextStyle(color: Theme.of(ctx).textTheme.bodySmall?.color),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < options.length; i++)
              Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    i == options.length - 1
                        ? Icons.all_inclusive_rounded
                        : Icons.event_note_rounded,
                  ),
                  title: Text(
                    options[i].title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  trailing: Text('${options[i].messages.length} رسالة'),
                  onTap: () => Navigator.pop(ctx, i),
                ),
              ),
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.date_range_rounded),
                title: const Text(
                  'اختيار فترة محددة...',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, custom),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return null;
  if (choice >= 0 && choice < options.length) return options[choice].messages;
  if (!context.mounted) return null;

  final range = await showDateRangePicker(
    context: context,
    firstDate: days.first,
    lastDate: last,
    initialDateRange: DateTimeRange(
      start: last.subtract(const Duration(days: 6)).isBefore(days.first)
          ? days.first
          : last.subtract(const Duration(days: 6)),
      end: last,
    ),
    helpText: 'اختر فترة الرسائل',
    saveText: 'اعتماد',
  );
  if (range == null) return null;
  final end = DateTime(range.end.year, range.end.month, range.end.day + 1);
  return all.where((m) {
    final t = m.timestamp;
    if (t == null) return true;
    return !t.isBefore(range.start) && t.isBefore(end);
  }).toList();
}
