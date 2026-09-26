import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../database_service.dart';
import '../models.dart';
import '../services/period_stats.dart';
import 'add_account_screen.dart';
import 'account_screen.dart';
import 'add_edit_transaction_screen.dart';
import 'operations_log_screen.dart';
import 'transaction_history_screen.dart';

enum _QuickStatusFilter { all, added, received, cancelled }

/// عرض حركات أحد أرقام «ملخص اليوم»
enum _HomeFocus { addedToday, receivedToday, cancelledToday, pending }

/// تصفية قائمة الحسابات في الصفحة الرئيسية
enum _AccountsView { all, office, company }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  Timer? _debounce;
  String _liveQuery = '';
  String _query = '';
  bool _searchFocused = false;

  _QuickStatusFilter _quickFilter = _QuickStatusFilter.all;
  bool _todayOnly = false;
  int? _selectedAccountId;
  _HomeFocus? _focus;
  _AccountsView _accountsView = _AccountsView.all;

  final Map<dynamic, String> _searchBlobCache = {};
  final Map<dynamic, int> _searchStampCache = {};

  @override
  void initState() {
    super.initState();

    _searchCtrl.addListener(() {
      _liveQuery = _searchCtrl.text.trim();
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 220), () {
        if (!mounted) return;
        setState(() => _query = _liveQuery);
      });
      if (mounted) setState(() {});
    });

    _searchFocus.addListener(() {
      if (!mounted) return;
      setState(() => _searchFocused = _searchFocus.hasFocus);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool get _hasActiveSearch =>
      _query.isNotEmpty ||
      _quickFilter != _QuickStatusFilter.all ||
      _todayOnly ||
      _selectedAccountId != null ||
      _focus != null;

  void _clearAllSearch() {
    _searchCtrl.clear();
    _debounce?.cancel();
    setState(() {
      _liveQuery = '';
      _query = '';
      _quickFilter = _QuickStatusFilter.all;
      _todayOnly = false;
      _selectedAccountId = null;
      _focus = null;
    });
  }

  String _statusLabel(TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return "مضافة";
      case TransactionStatus.received:
        return "مستلمة";
      case TransactionStatus.cancelled:
        return "ملغية";
    }
  }

  Color _statusColor(TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return const Color(0xFF1E88E5);
      case TransactionStatus.received:
        return const Color(0xFF00A76F);
      case TransactionStatus.cancelled:
        return const Color(0xFFE53935);
    }
  }

  String _movementLabel(TransactionModel tx) =>
      tx.companyMovementType?.label ?? _statusLabel(tx.status);

  Color _movementColor(TransactionModel tx) {
    switch (tx.companyMovementType) {
      case CompanyMovementType.received:
        return const Color(0xFF00897B);
      case CompanyMovementType.sent:
        return const Color(0xFF5E35B1);
      case CompanyMovementType.receivedCancelled:
        return const Color(0xFFD84315);
      case CompanyMovementType.sentCancelled:
        return const Color(0xFFEF6C00);
      case null:
        return _statusColor(tx.status);
    }
  }

  IconData _movementIcon(TransactionModel tx) {
    switch (tx.companyMovementType) {
      case CompanyMovementType.received:
        return Icons.call_received_rounded;
      case CompanyMovementType.sent:
        return Icons.call_made_rounded;
      case CompanyMovementType.receivedCancelled:
      case CompanyMovementType.sentCancelled:
        return Icons.cancel_rounded;
      case null:
        return tx.status == TransactionStatus.received
            ? Icons.check_rounded
            : tx.status == TransactionStatus.cancelled
            ? Icons.close_rounded
            : Icons.schedule_rounded;
    }
  }

  /// ألوان هادئة ومتناسقة للحسابات (ثابتة لكل حساب)
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

  String _normalizeText(String text) {
    if (text.isEmpty) return '';
    var t = text.replaceAll(
      RegExp(r'[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED]'),
      '',
    );
    final buffer = StringBuffer();
    for (var i = 0; i < t.length; i++) {
      final ch = t[i];
      switch (ch) {
        case 'أ':
        case 'إ':
        case 'آ':
          buffer.write('ا');
          break;
        case 'ة':
          buffer.write('ه');
          break;
        case 'ى':
          buffer.write('ي');
          break;
        case 'ؤ':
          buffer.write('و');
          break;
        case 'ئ':
          buffer.write('ي');
          break;
        default:
          buffer.write(ch);
      }
    }
    return buffer.toString().toLowerCase().trim();
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

  String _formatDateTime(DateTime dt) {
    return "${_formatDay(dt)} ${_formatTime(dt)}";
  }

  String _formatAmount(double v) {
    if (!v.isFinite) return "0,00";

    final s = v.toStringAsFixed(2);
    final parts = s.split('.');

    if (parts.length < 2) {
      return s.replaceAll('.', ',');
    }

    final intPart = parts[0];
    final dec = parts[1];

    final buf = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      final idx = intPart.length - 1 - i;
      buf.write(intPart[idx]);
      if (i % 3 == 2 && idx != 0) {
        buf.write('.');
      }
    }

    final withSep = buf.toString().split('').reversed.join();
    return "$withSep,$dec";
  }

  bool _hasSecondAmount(TransactionModel t) =>
      t.secondAmount != null && t.secondAmount! > 0;

  String _secondCurrencyOf(TransactionModel t) {
    try {
      final value = (t as dynamic).secondCurrency;
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    } catch (_) {}
    return t.currency;
  }

  DateTime _displayMomentOf(TransactionModel t) {
    if (t.companyMovementType?.isCancelled == true) {
      return t.cancelledAt ?? t.date;
    }
    if (t.companyMovementType != null) return t.date;
    switch (t.status) {
      case TransactionStatus.received:
        return t.receivedAt ?? t.date;
      case TransactionStatus.cancelled:
        return t.cancelledAt ?? t.date;
      case TransactionStatus.added:
        return t.date;
    }
  }

  String _displayMomentLabel(TransactionModel t) {
    if (t.companyMovementType?.isCancelled == true) return 'تاريخ إلغاء الحركة';
    if (t.companyMovementType != null) return 'تاريخ حركة الشركة';
    switch (t.status) {
      case TransactionStatus.received:
        return "تاريخ التسليم";
      case TransactionStatus.cancelled:
        return "تاريخ الإلغاء";
      case TransactionStatus.added:
        return "تاريخ الحركة";
    }
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isTodayTx(TransactionModel t) =>
      _isSameDay(_displayMomentOf(t), DateTime.now());

  // ---------------- ملخص اليوم / تركيز النتائج ----------------

  /// لحظة إلغاء الحركة: للمكاتب تاريخ الإلغاء، وللشركات نفس منطق الإحصائيات.
  DateTime? _cancelMomentOf(TransactionModel t) => t.companyMovementType != null
      ? PeriodStats.companyCancelMoment(t)
      : t.cancelledAt;

  /// حركة مكتب لم تُستلم بعد
  bool _isPendingTx(TransactionModel t) =>
      t.companyMovementType == null && t.status == TransactionStatus.added;

  /// آخر نشاط على الحركة (إضافة/تسليم/إلغاء)
  DateTime _lastActivityOf(TransactionModel t) {
    var m = t.date;
    final r = t.receivedAt;
    final c = t.cancelledAt;
    if (r != null && r.isAfter(m)) m = r;
    if (c != null && c.isAfter(m)) m = c;
    return m;
  }

  bool _matchesFocus(TransactionModel t) {
    final focus = _focus;
    if (focus == null) return true;
    final now = DateTime.now();
    switch (focus) {
      case _HomeFocus.addedToday:
        return _isSameDay(t.date, now);
      case _HomeFocus.receivedToday:
        return t.companyMovementType == null &&
            t.receivedAt != null &&
            _isSameDay(t.receivedAt!, now);
      case _HomeFocus.cancelledToday:
        final c = _cancelMomentOf(t);
        return c != null && _isSameDay(c, now);
      case _HomeFocus.pending:
        return _isPendingTx(t);
    }
  }

  String _focusLabel(_HomeFocus f) {
    switch (f) {
      case _HomeFocus.addedToday:
        return 'مضافة اليوم';
      case _HomeFocus.receivedToday:
        return 'مستلمة اليوم';
      case _HomeFocus.cancelledToday:
        return 'ملغاة اليوم';
      case _HomeFocus.pending:
        return 'غير مستلمة';
    }
  }

  IconData _focusIcon(_HomeFocus f) {
    switch (f) {
      case _HomeFocus.addedToday:
        return Icons.add_circle_outline_rounded;
      case _HomeFocus.receivedToday:
        return Icons.task_alt_rounded;
      case _HomeFocus.cancelledToday:
        return Icons.cancel_outlined;
      case _HomeFocus.pending:
        return Icons.hourglass_top_rounded;
    }
  }

  Color _focusColor(_HomeFocus f) {
    switch (f) {
      case _HomeFocus.addedToday:
        return const Color(0xFF1E88E5);
      case _HomeFocus.receivedToday:
        return const Color(0xFF00A76F);
      case _HomeFocus.cancelledToday:
        return const Color(0xFFE53935);
      case _HomeFocus.pending:
        return const Color(0xFFF59E0B);
    }
  }

  /// الضغط على أحد أرقام ملخص اليوم يعرض حركاته مباشرة
  void _applyFocus(_HomeFocus f) {
    _searchFocus.unfocus();
    setState(() {
      _focus = f;
      _quickFilter = _QuickStatusFilter.all;
      _todayOnly = false;
    });
  }

  bool _isMorning() {
    final h = DateTime.now().hour;
    return h >= 4 && h < 12;
  }

  String _greeting() => _isMorning() ? 'صباح الخير' : 'مساء الخير';

  static const List<String> _weekdayNames = [
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];

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

  String _todayLabel() {
    final now = DateTime.now();
    return '${_weekdayNames[(now.weekday - 1) % 7]} ${now.day} ${_monthNames[(now.month - 1) % 12]}';
  }

  /// وقت نسبي مختصر لآخر نشاط على الحساب
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

  int _cacheStampForTx(TransactionModel t) {
    return Object.hash(
      t.key,
      t.accountId,
      t.beneficiary,
      t.amount,
      t.secondAmount,
      t.currency,
      _secondCurrencyOf(t),
      t.status.index,
      t.date.millisecondsSinceEpoch,
      t.receivedAt?.millisecondsSinceEpoch,
      t.cancelledAt?.millisecondsSinceEpoch,
      t.notes,
    );
  }

  String _buildSearchBlob(TransactionModel t, String accountName) {
    final key = t.key ?? t.id;
    final stamp = _cacheStampForTx(t);

    final cachedStamp = _searchStampCache[key];
    if (cachedStamp == stamp && _searchBlobCache.containsKey(key)) {
      return _searchBlobCache[key]!;
    }

    final parts = <String>[
      t.beneficiary,
      accountName,
      t.currency,
      _secondCurrencyOf(t),
      _movementLabel(t),
      _formatDay(t.date),
      _formatTime(t.date),
      _formatDateTime(_displayMomentOf(t)),
      _displayMomentLabel(t),
      t.amount.toString(),
      if (_hasSecondAmount(t)) t.secondAmount!.toString(),
      (t.amount + (t.secondAmount ?? 0)).toString(),
      t.notes,
    ];

    final blob = _normalizeText(parts.join(' '));
    _searchStampCache[key] = stamp;
    _searchBlobCache[key] = blob;
    return blob;
  }

  _ParsedSmartQuery _parseSmartQuery(String raw) {
    String? status;
    String? currency;
    String? account;
    DateTime? date;
    double? amount;
    final terms = <String>[];

    final tokens = raw
        .trim()
        .split(RegExp(r'\s+'))
        .where((e) => e.trim().isNotEmpty)
        .toList();

    for (final token in tokens) {
      final lower = _normalizeText(token);

      if (lower.startsWith('حاله:') || lower.startsWith('status:')) {
        status = lower.split(':').skip(1).join(':').trim();
        continue;
      }

      if (lower.startsWith('عمله:') || lower.startsWith('currency:')) {
        currency = lower.split(':').skip(1).join(':').trim();
        continue;
      }

      if (lower.startsWith('حساب:') || lower.startsWith('account:')) {
        account = lower.split(':').skip(1).join(':').trim();
        continue;
      }

      if (lower.startsWith('تاريخ:') || lower.startsWith('date:')) {
        final value = lower.split(':').skip(1).join(':').trim();
        date = _tryParseDate(value);
        continue;
      }

      if (lower.startsWith('مبلغ:') || lower.startsWith('amount:')) {
        final value = lower.split(':').skip(1).join(':').trim();
        amount = double.tryParse(value.replaceAll(',', '.'));
        continue;
      }

      terms.add(lower);
    }

    return _ParsedSmartQuery(
      terms: terms,
      status: status,
      currency: currency,
      account: account,
      date: date,
      amount: amount,
    );
  }

  DateTime? _tryParseDate(String raw) {
    final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(raw);
    if (match == null) return null;
    final y = int.tryParse(match.group(1)!);
    final m = int.tryParse(match.group(2)!);
    final d = int.tryParse(match.group(3)!);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  bool _matchesStatusText(TransactionModel t, String raw) {
    final s = _normalizeText(raw);

    if (s.contains('مضاف') || s == 'added') {
      return t.status == TransactionStatus.added;
    }
    if (s.contains('مستلم') || s == 'received') {
      return t.status == TransactionStatus.received;
    }
    if (s.contains('ملغي') || s == 'cancelled' || s == 'canceled') {
      return t.status == TransactionStatus.cancelled;
    }
    return false;
  }

  bool _matchesQuickFilter(TransactionModel t) {
    switch (_quickFilter) {
      case _QuickStatusFilter.all:
        return true;
      case _QuickStatusFilter.added:
        return t.status == TransactionStatus.added;
      case _QuickStatusFilter.received:
        return t.status == TransactionStatus.received;
      case _QuickStatusFilter.cancelled:
        return t.status == TransactionStatus.cancelled;
    }
  }

  int _scoreTransaction({
    required TransactionModel t,
    required String accountName,
    required String blob,
    required _ParsedSmartQuery parsed,
  }) {
    int score = 0;
    final name = _normalizeText(t.beneficiary);
    final acc = _normalizeText(accountName);
    final curr1 = _normalizeText(t.currency);
    final curr2 = _normalizeText(_secondCurrencyOf(t));

    for (final term in parsed.terms) {
      if (name == term) {
        score += 30;
      } else if (name.contains(term)) {
        score += 18;
      } else if (acc.contains(term)) {
        score += 14;
      } else if (curr1.contains(term) || curr2.contains(term)) {
        score += 12;
      } else if (blob.contains(term)) {
        score += 8;
      }
    }

    if (parsed.status != null) score += 12;
    if (parsed.currency != null) score += 10;
    if (parsed.account != null) score += 14;
    if (parsed.date != null) score += 10;
    if (parsed.amount != null) score += 16;

    if (_isTodayTx(t)) score += 2;
    return score;
  }

  bool _matchesParsedQuery({
    required TransactionModel t,
    required String accountName,
    required String blob,
    required _ParsedSmartQuery parsed,
  }) {
    if (_selectedAccountId != null && t.accountId != _selectedAccountId) {
      return false;
    }

    if (!_matchesQuickFilter(t)) return false;

    if (_todayOnly && !_isTodayTx(t)) return false;

    if (!_matchesFocus(t)) return false;

    if (parsed.status != null && !_matchesStatusText(t, parsed.status!)) {
      return false;
    }

    if (parsed.currency != null) {
      final currNeed = _normalizeText(parsed.currency!);
      final matchesCurrency =
          _normalizeText(t.currency).contains(currNeed) ||
          _normalizeText(_secondCurrencyOf(t)).contains(currNeed);
      if (!matchesCurrency) return false;
    }

    if (parsed.account != null) {
      if (!_normalizeText(
        accountName,
      ).contains(_normalizeText(parsed.account!))) {
        return false;
      }
    }

    if (parsed.date != null) {
      final d = parsed.date!;
      final same =
          _isSameDay(t.date, d) ||
          (t.receivedAt != null && _isSameDay(t.receivedAt!, d)) ||
          (t.cancelledAt != null && _isSameDay(t.cancelledAt!, d));
      if (!same) return false;
    }

    if (parsed.amount != null) {
      final n = parsed.amount!;
      final matchAmount =
          (t.amount - n).abs() < 0.0001 ||
          ((_hasSecondAmount(t)) && ((t.secondAmount! - n).abs() < 0.0001)) ||
          ((t.amount + (t.secondAmount ?? 0) - n).abs() < 0.0001);
      if (!matchAmount) return false;
    }

    for (final term in parsed.terms) {
      if (!blob.contains(term)) return false;
    }

    return true;
  }

  List<_RankedTx> _buildSearchResults(
    List<TransactionModel> allTx,
    Map<int, Account> accountsById,
  ) {
    final parsed = _parseSmartQuery(_query);
    final hits = <_RankedTx>[];

    for (final t in allTx) {
      final acc = accountsById[t.accountId];
      final accountName = acc?.name ?? "حساب غير معروف";
      final blob = _buildSearchBlob(t, accountName);

      if (!_matchesParsedQuery(
        t: t,
        accountName: accountName,
        blob: blob,
        parsed: parsed,
      )) {
        continue;
      }

      final score = _scoreTransaction(
        t: t,
        accountName: accountName,
        blob: blob,
        parsed: parsed,
      );

      hits.add(
        _RankedTx(tx: t, account: acc, accountName: accountName, score: score),
      );
    }

    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return _displayMomentOf(b.tx).compareTo(_displayMomentOf(a.tx));
    });

    return hits;
  }

  Future<bool?> _confirmDelete(BuildContext context) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text("تأكيد الحذف"),
          content: const Text("هل تريد بالتأكيد حذف هذه الحركة نهائيًا؟"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("إلغاء"),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("حذف نهائي"),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmCancel(BuildContext context) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text("تأكيد الإلغاء"),
          content: const Text("هل تريد بالتأكيد إلغاء هذه الحركة؟"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("لا"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("نعم، إلغاء"),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSearchFilterSheet(
    BuildContext context,
    List<Account> accounts,
  ) async {
    _QuickStatusFilter tmpStatus = _quickFilter;
    bool tmpToday = _todayOnly;
    int? tmpAccountId = _selectedAccountId;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;

        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "فلترة ذكية",
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        "يمكنك أيضًا الكتابة مثل: حالة:مستلمة أو عملة:ريال أو تاريخ:2026-04-06",
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        "الحالة",
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text("الكل"),
                            selected: tmpStatus == _QuickStatusFilter.all,
                            onSelected: (_) => setSheet(() {
                              tmpStatus = _QuickStatusFilter.all;
                            }),
                          ),
                          ChoiceChip(
                            label: const Text("مضافة"),
                            selected: tmpStatus == _QuickStatusFilter.added,
                            onSelected: (_) => setSheet(() {
                              tmpStatus = _QuickStatusFilter.added;
                            }),
                          ),
                          ChoiceChip(
                            label: const Text("مستلمة"),
                            selected: tmpStatus == _QuickStatusFilter.received,
                            onSelected: (_) => setSheet(() {
                              tmpStatus = _QuickStatusFilter.received;
                            }),
                          ),
                          ChoiceChip(
                            label: const Text("ملغية"),
                            selected: tmpStatus == _QuickStatusFilter.cancelled,
                            onSelected: (_) => setSheet(() {
                              tmpStatus = _QuickStatusFilter.cancelled;
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      SwitchListTile.adaptive(
                        value: tmpToday,
                        onChanged: (v) => setSheet(() => tmpToday = v),
                        contentPadding: EdgeInsets.zero,
                        title: const Text("حركات اليوم فقط"),
                        subtitle: const Text("يعتمد على تاريخ الحالة الفعلي"),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int?>(
                        value: tmpAccountId,
                        decoration: const InputDecoration(
                          labelText: "حساب محدد",
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text("كل الحسابات"),
                          ),
                          ...accounts.map(
                            (a) => DropdownMenuItem<int?>(
                              value: a.id,
                              child: Text(a.name),
                            ),
                          ),
                        ],
                        onChanged: (v) => setSheet(() => tmpAccountId = v),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _quickFilter = _QuickStatusFilter.all;
                                  _todayOnly = false;
                                  _selectedAccountId = null;
                                  _focus = null;
                                });
                                Navigator.pop(ctx);
                              },
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text("تصفير"),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () {
                                setState(() {
                                  _quickFilter = tmpStatus;
                                  _todayOnly = tmpToday;
                                  _selectedAccountId = tmpAccountId;
                                });
                                Navigator.pop(ctx);
                              },
                              icon: const Icon(Icons.check_rounded),
                              label: const Text("تطبيق"),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showTxDetailsSheet(
    BuildContext context,
    TransactionModel t,
    String accountName,
    Color accent,
  ) async {
    final cs = Theme.of(context).colorScheme;

    Widget infoTile(String label, String value, IconData icon) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outlineVariant.withOpacity(.25)),
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: accent.withOpacity(.12),
            child: Icon(icon, color: accent),
          ),
          title: Text(label),
          subtitle: Text(value),
        ),
      );
    }

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      builder: (ctx) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    t.beneficiary,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        avatar: CircleAvatar(
                          backgroundColor: _movementColor(t).withOpacity(.14),
                          child: Icon(
                            _movementIcon(t),
                            size: 16,
                            color: _movementColor(t),
                          ),
                        ),
                        label: Text(_statusLabel(t.status)),
                      ),
                      Chip(
                        avatar: CircleAvatar(
                          backgroundColor: accent.withOpacity(.14),
                          child: Icon(
                            Icons.account_balance_wallet_rounded,
                            size: 16,
                            color: accent,
                          ),
                        ),
                        label: Text(accountName),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  infoTile(
                    "المبلغ الأول",
                    "${_formatAmount(t.amount)} ${t.currency}",
                    Icons.payments_outlined,
                  ),
                  if (_hasSecondAmount(t))
                    infoTile(
                      "المبلغ الثاني",
                      "${_formatAmount(t.secondAmount!)} ${_secondCurrencyOf(t)}",
                      Icons.payments_rounded,
                    ),
                  infoTile(
                    "تاريخ الحركة",
                    _formatDateTime(t.date),
                    Icons.event_note_rounded,
                  ),
                  infoTile(
                    _displayMomentLabel(t),
                    _formatDateTime(_displayMomentOf(t)),
                    Icons.access_time_filled_rounded,
                  ),
                  if (t.receivedAt != null)
                    infoTile(
                      "تاريخ التسليم",
                      _formatDateTime(t.receivedAt!),
                      Icons.inventory_2_rounded,
                    ),
                  if (t.cancelledAt != null)
                    infoTile(
                      "تاريخ الإلغاء",
                      _formatDateTime(t.cancelledAt!),
                      Icons.cancel_rounded,
                    ),
                  if (t.notes.trim().isNotEmpty)
                    infoTile("ملاحظات", t.notes.trim(), Icons.notes_rounded),
                  const SizedBox(height: 4),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      openTransactionHistory(context, t);
                    },
                    icon: const Icon(Icons.history_rounded),
                    label: const Text('سجل التعديلات'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
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

        final accountsById = <int, Account>{for (final a in accounts) a.id: a};

        return ValueListenableBuilder(
          valueListenable: DatabaseService.transactionsBox.listenable(),
          builder: (context, Box<TransactionModel> txBox, _) {
            final allTx = txBox.values.toList();
            final searchResults = _hasActiveSearch
                ? _buildSearchResults(allTx, accountsById)
                : <_RankedTx>[];

            // ملخص اليوم + إحصائيات كل حساب (نفس منطق صفحة الإحصائيات:
            // الإضافة بتاريخ الإضافة، والإلغاء بتاريخ الإلغاء)
            final now = DateTime.now();
            final statsByAccount = <int, _AccountStats>{};
            var addedToday = 0;
            var receivedToday = 0;
            var cancelledToday = 0;
            var pendingTotal = 0;

            for (final tx in allTx) {
              final st = statsByAccount.putIfAbsent(
                tx.accountId,
                _AccountStats.new,
              );
              st.total++;
              if (_isSameDay(tx.date, now)) {
                st.today++;
                addedToday++;
              }
              if (_isPendingTx(tx)) {
                st.pending++;
                pendingTotal++;
              }
              if (tx.companyMovementType == null &&
                  tx.receivedAt != null &&
                  _isSameDay(tx.receivedAt!, now)) {
                receivedToday++;
              }
              final cancelAt = _cancelMomentOf(tx);
              if (cancelAt != null && _isSameDay(cancelAt, now)) {
                cancelledToday++;
              }
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

            final focus = _focus;
            final resultsTitle = focus != null && _query.isEmpty
                ? _focusLabel(focus)
                : "نتائج البحث";

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
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      toolbarHeight: 72,
                      centerTitle: false,
                      titleSpacing: 20,
                      backgroundColor: pageBg,
                      foregroundColor: cs.onSurface,
                      surfaceTintColor: Colors.transparent,
                      scrolledUnderElevation: 0,
                      title: _HomeGreeting(
                        greeting: _greeting(),
                        morning: _isMorning(),
                      ),
                      actions: [
                        _HeaderIconButton(
                          icon: Icons.history_rounded,
                          tooltip: 'سجل العمليات',
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const OperationsLogScreen(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                      ],
                    ),

                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AnimatedSize(
                              duration: const Duration(milliseconds: 260),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.topCenter,
                              child: _hasActiveSearch
                                  ? const SizedBox(width: double.infinity)
                                  : Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 16,
                                      ),
                                      child: _TodayHero(
                                        dateText: _todayLabel(),
                                        added: addedToday,
                                        received: receivedToday,
                                        cancelled: cancelledToday,
                                        pending: pendingTotal,
                                        officeCount: officeAccounts.length,
                                        companyCount: companyAccounts.length,
                                        totalMovements: allTx.length,
                                        onTapMetric: _applyFocus,
                                      ),
                                    ),
                            ),
                            _buildSearchBox(context, accounts),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.topCenter,
                              child: (_searchFocused || _hasActiveSearch)
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: _buildQuickFilters(accounts),
                                    )
                                  : const SizedBox(width: double.infinity),
                            ),
                          ],
                        ),
                      ),
                    ),

                    if (!_hasActiveSearch) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 24, 16, 12),
                          child: Row(
                            children: [
                              Text(
                                "الحسابات",
                                style: TextStyle(
                                  color: cs.onSurface,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _CountBadge(count: accounts.length),
                            ],
                          ),
                        ),
                      ),
                      if (showSegments)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: _AccountsSegment(
                              value: view,
                              total: accounts.length,
                              office: officeAccounts.length,
                              company: companyAccounts.length,
                              onChanged: (v) =>
                                  setState(() => _accountsView = v),
                            ),
                          ),
                        ),
                      if (accounts.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
                    ] else ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        resultsTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: cs.onSurface,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 17,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _CountBadge(count: searchResults.length),
                                  ],
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _clearAllSearch,
                                icon: const Icon(Icons.close_rounded),
                                label: const Text("مسح"),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (searchResults.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(16, 18, 16, 0),
                            child: _EmptyStateCard(
                              icon: Icons.search_off_rounded,
                              title: "لا توجد نتائج مطابقة",
                              subtitle: "جرّب كلمات أقل أو استخدم فلترة أدق",
                            ),
                          ),
                        )
                      else
                        SliverList.builder(
                          itemCount: searchResults.length,
                          itemBuilder: (context, index) {
                            final hit = searchResults[index];
                            final t = hit.tx;
                            final acc = hit.account;
                            final accountName = hit.accountName;
                            final accent = _accountAccent(t.accountId);

                            return _AnimatedEntrance(
                              index: index,
                              child: _SearchTxCard(
                                tx: t,
                                accountName: accountName,
                                accent: accent,
                                statusText: _movementLabel(t),
                                statusColor: _movementColor(t),
                                firstAmountText:
                                    "${_formatAmount(t.amount)} ${t.currency}",
                                secondAmountText: _hasSecondAmount(t)
                                    ? "${_formatAmount(t.secondAmount!)} ${_secondCurrencyOf(t)}"
                                    : null,
                                dateText: _formatDay(_displayMomentOf(t)),
                                timeText: _formatTime(_displayMomentOf(t)),
                                dateLabel: _displayMomentLabel(t),
                                onTapDetails: () {
                                  _showTxDetailsSheet(
                                    context,
                                    t,
                                    accountName,
                                    accent,
                                  );
                                },
                                onEdit: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => AddEditTransactionScreen(
                                        account:
                                            acc ??
                                            Account(
                                              id: t.accountId,
                                              name: accountName,
                                              type:
                                                  t.companyMovementType != null
                                                  ? AccountType.company
                                                  : AccountType.office,
                                            ),
                                        existing: t,
                                      ),
                                    ),
                                  );
                                },
                                onSetReceived: () async {
                                  t.applyStatus(TransactionStatus.received);
                                  await t.save();
                                },
                                onSetAdded: () async {
                                  t.applyStatus(TransactionStatus.added);
                                  await t.save();
                                },
                                onCancel: () async {
                                  final ok = await _confirmCancel(context);
                                  if (ok == true) {
                                    if (t.companyMovementType != null) {
                                      t.companyMovementType =
                                          t.companyMovementType!.cancelled;
                                      t.cancelledAt = DateTime.now();
                                    } else {
                                      t.applyStatus(
                                        TransactionStatus.cancelled,
                                      );
                                    }
                                    await t.save();
                                  }
                                },
                                onDeleteFinal: () async {
                                  await t.delete();
                                },
                                confirmDelete: () async {
                                  final ok = await _confirmDelete(context);
                                  return ok == true;
                                },
                              ),
                            );
                          },
                        ),
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

  Widget _buildSearchBox(BuildContext context, List<Account> accounts) {
    final cs = Theme.of(context).colorScheme;
    final isDark = _isDark(context);
    final filtersActive =
        _quickFilter != _QuickStatusFilter.all ||
        _todayOnly ||
        _selectedAccountId != null ||
        _focus != null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: _cardBg(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _searchFocused
              ? cs.primary.withValues(alpha: .70)
              : _outline(context),
          width: _searchFocused ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .16 : .04),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          hintText: "ابحث عن حركة، حساب، عملة، تاريخ…",
          hintStyle: TextStyle(color: cs.onSurfaceVariant),
          prefixIcon: Icon(Icons.search_rounded, color: cs.onSurfaceVariant),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_liveQuery.isNotEmpty)
                IconButton(
                  tooltip: 'مسح',
                  onPressed: () {
                    _searchCtrl.clear();
                    _debounce?.cancel();
                    setState(() {
                      _liveQuery = '';
                      _query = '';
                    });
                  },
                  icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                ),
              IconButton(
                tooltip: 'فلترة',
                onPressed: () => _showSearchFilterSheet(context, accounts),
                icon: Badge(
                  isLabelVisible: filtersActive,
                  smallSize: 8,
                  backgroundColor: cs.primary,
                  child: Icon(Icons.tune_rounded, color: cs.primary),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
    );
  }

  Widget _buildQuickFilters(List<Account> accounts) {
    final cs = Theme.of(context).colorScheme;
    final selectedAccount = accounts
        .where((a) => a.id == _selectedAccountId)
        .cast<Account?>()
        .firstOrNull;
    final focus = _focus;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          if (focus != null)
            _QuickChip(
              text: _focusLabel(focus),
              icon: _focusIcon(focus),
              selected: true,
              closable: true,
              accent: _focusColor(focus),
              onTap: () => setState(() => _focus = null),
            ),
          _QuickChip(
            text: "الكل",
            selected: _quickFilter == _QuickStatusFilter.all,
            onTap: () => setState(() => _quickFilter = _QuickStatusFilter.all),
          ),
          _QuickChip(
            text: "مضافة",
            icon: Icons.schedule_rounded,
            selected: _quickFilter == _QuickStatusFilter.added,
            accent: const Color(0xFF1E88E5),
            onTap: () =>
                setState(() => _quickFilter = _QuickStatusFilter.added),
          ),
          _QuickChip(
            text: "مستلمة",
            icon: Icons.check_circle_outline_rounded,
            selected: _quickFilter == _QuickStatusFilter.received,
            accent: const Color(0xFF00A76F),
            onTap: () =>
                setState(() => _quickFilter = _QuickStatusFilter.received),
          ),
          _QuickChip(
            text: "ملغية",
            icon: Icons.cancel_outlined,
            selected: _quickFilter == _QuickStatusFilter.cancelled,
            accent: const Color(0xFFE53935),
            onTap: () =>
                setState(() => _quickFilter = _QuickStatusFilter.cancelled),
          ),
          _QuickChip(
            text: "اليوم",
            icon: Icons.today_rounded,
            selected: _todayOnly,
            accent: cs.primary,
            onTap: () => setState(() => _todayOnly = !_todayOnly),
          ),
          if (selectedAccount != null)
            _QuickChip(
              text: "حساب: ${selectedAccount.name}",
              selected: true,
              closable: true,
              accent: _accountAccent(selectedAccount.id),
              onTap: () => setState(() => _selectedAccountId = null),
            ),
        ],
      ),
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

class _ParsedSmartQuery {
  final List<String> terms;
  final String? status;
  final String? currency;
  final String? account;
  final DateTime? date;
  final double? amount;

  const _ParsedSmartQuery({
    required this.terms,
    this.status,
    this.currency,
    this.account,
    this.date,
    this.amount,
  });
}

class _RankedTx {
  final TransactionModel tx;
  final Account? account;
  final String accountName;
  final int score;

  const _RankedTx({
    required this.tx,
    required this.account,
    required this.accountName,
    required this.score,
  });
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

// ---------------- الترويسة ----------------

class _HomeGreeting extends StatelessWidget {
  final String greeting;
  final bool morning;

  const _HomeGreeting({required this.greeting, required this.morning});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              morning ? Icons.wb_sunny_rounded : Icons.nightlight_round,
              size: 16,
              color: morning
                  ? const Color(0xFFF59E0B)
                  : _fg(context, const Color(0xFF6366F1)),
            ),
            const SizedBox(width: 6),
            Text(
              greeting,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'مدير الحسابات',
          style: TextStyle(
            fontSize: 23,
            height: 1.15,
            fontWeight: FontWeight.w900,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: _cardBg(context),
        foregroundColor: cs.onSurface,
        side: BorderSide(color: _outline(context)),
      ),
      icon: Icon(icon),
    );
  }
}

// ---------------- ملخص اليوم ----------------

class _TodayHero extends StatelessWidget {
  final String dateText;
  final int added;
  final int received;
  final int cancelled;
  final int pending;
  final int officeCount;
  final int companyCount;
  final int totalMovements;
  final ValueChanged<_HomeFocus> onTapMetric;

  const _TodayHero({
    required this.dateText,
    required this.added,
    required this.received,
    required this.cancelled,
    required this.pending,
    required this.officeCount,
    required this.companyCount,
    required this.totalMovements,
    required this.onTapMetric,
  });

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final colors = dark
        ? const [Color(0xFF0B4F4A), Color(0xFF137A70)]
        : const [Color(0xFF0F766E), Color(0xFF26A69A)];
    const white = Colors.white;

    Widget glow(double size, double alpha) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: white.withValues(alpha: alpha),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: colors,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: dark ? .22 : .30),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          PositionedDirectional(top: -46, end: -34, child: glow(160, .08)),
          PositionedDirectional(bottom: -60, start: -26, child: glow(140, .06)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.insights_rounded, color: white, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'ملخص اليوم',
                        style: TextStyle(
                          color: white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: white.withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        dateText,
                        style: const TextStyle(
                          color: white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _HeroMetric(
                        value: added,
                        label: 'مضافة اليوم',
                        icon: Icons.add_circle_outline_rounded,
                        onTap: added > 0
                            ? () => onTapMetric(_HomeFocus.addedToday)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _HeroMetric(
                        value: received,
                        label: 'مستلمة اليوم',
                        icon: Icons.task_alt_rounded,
                        onTap: received > 0
                            ? () => onTapMetric(_HomeFocus.receivedToday)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _HeroMetric(
                        value: cancelled,
                        label: 'ملغاة اليوم',
                        icon: Icons.cancel_outlined,
                        onTap: cancelled > 0
                            ? () => onTapMetric(_HomeFocus.cancelledToday)
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Material(
                  color: white.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: pending > 0
                        ? () => onTapMetric(_HomeFocus.pending)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.hourglass_top_rounded,
                            color: white,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              pending > 0
                                  ? 'غير مستلمة: $pending حركة'
                                  : 'لا توجد حركات غير مستلمة',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: white,
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                          if (pending > 0)
                            Icon(
                              Icons.chevron_right_rounded,
                              color: white.withValues(alpha: .85),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'المكاتب: $officeCount  •  الشركات: $companyCount  •  كل الحركات: $totalMovements',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: white.withValues(alpha: .80),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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

class _HeroMetric extends StatelessWidget {
  final int value;
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _HeroMetric({
    required this.value,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    return Material(
      color: white.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: white.withValues(alpha: .90), size: 19),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  '$value',
                  style: const TextStyle(
                    color: white,
                    fontWeight: FontWeight.w900,
                    fontSize: 24,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: white.withValues(alpha: .86),
                  fontWeight: FontWeight.w600,
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- عناصر صغيرة ----------------

class _CountBadge extends StatelessWidget {
  final int count;

  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 26),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _fg(context, cs.primary),
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String text;
  final Color color;

  const _StatusPill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: _fg(context, color),
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  final Color? accent;
  final IconData? icon;
  final bool closable;

  const _QuickChip({
    required this.text,
    required this.selected,
    required this.onTap,
    this.accent,
    this.icon,
    this.closable = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = _isDark(context);
    final c = accent ?? cs.primary;
    final fg = selected ? _fg(context, c) : cs.onSurface;
    final bg = selected
        ? c.withValues(alpha: dark ? .22 : .13)
        : _cardBg(context);
    final border = selected
        ? c.withValues(alpha: dark ? .55 : .40)
        : _outline(context);

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Material(
        color: bg,
        shape: StadiumBorder(side: BorderSide(color: border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: selected ? fg : _fg(context, c)),
                  const SizedBox(width: 6),
                ],
                Text(
                  text,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                if (closable) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.close_rounded, size: 15, color: fg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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

// ---------------- الحالات الفارغة ----------------

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
            'ابدأ بإضافة أول حساب',
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'أنشئ حساب مكتب أو شركة لتبدأ بتسجيل الحركات وتحليل الرسائل.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
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

class _EmptyStateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyStateCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _cardBg(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _outline(context)),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primary.withValues(alpha: .10),
            ),
            child: Icon(icon, size: 32, color: _fg(context, cs.primary)),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SearchTxCard extends StatefulWidget {
  final TransactionModel tx;
  final String accountName;
  final Color accent;
  final String statusText;
  final Color statusColor;
  final String firstAmountText;
  final String? secondAmountText;
  final String dateText;
  final String timeText;
  final String dateLabel;
  final VoidCallback onTapDetails;
  final VoidCallback onEdit;
  final Future<void> Function() onSetReceived;
  final Future<void> Function() onSetAdded;
  final Future<void> Function() onCancel;
  final Future<void> Function() onDeleteFinal;
  final Future<bool> Function() confirmDelete;

  const _SearchTxCard({
    super.key,
    required this.tx,
    required this.accountName,
    required this.accent,
    required this.statusText,
    required this.statusColor,
    required this.firstAmountText,
    required this.secondAmountText,
    required this.dateText,
    required this.timeText,
    required this.dateLabel,
    required this.onTapDetails,
    required this.onEdit,
    required this.onSetReceived,
    required this.onSetAdded,
    required this.onCancel,
    required this.onDeleteFinal,
    required this.confirmDelete,
  });

  @override
  State<_SearchTxCard> createState() => _SearchTxCardState();
}

class _SearchTxCardState extends State<_SearchTxCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _deleteController;
  bool _deleting = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _deleteController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    );
  }

  @override
  void dispose() {
    _deleteController.dispose();
    super.dispose();
  }

  Future<void> _handleDelete() async {
    if (_deleting || _busy) return;
    final ok = await widget.confirmDelete();
    if (!ok) return;

    setState(() {
      _busy = true;
      _deleting = true;
    });

    await _deleteController.forward();
    await widget.onDeleteFinal();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = _isDark(context);
    final primaryText = cs.onSurface;
    final secondaryText = cs.onSurfaceVariant;

    final primaryIsReactivate =
        widget.tx.companyMovementType?.isCancelled == true ||
        widget.tx.status == TransactionStatus.cancelled;

    final swipeBase = primaryIsReactivate
        ? const Color(0xFF16A34A)
        : const Color(0xFFDC2626);
    final swipeFg = _fg(context, swipeBase);
    const editBase = Color(0xFF2563EB);
    final editFg = _fg(context, editBase);

    // السحب باتجاه القراءة (من اليمين لليسار): إلغاء / إعادة تفعيل
    final primaryBg = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: swipeBase.withValues(alpha: isDark ? .22 : .12),
      ),
      alignment: AlignmentDirectional.centerStart,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            primaryIsReactivate ? Icons.refresh_rounded : Icons.cancel_rounded,
            color: swipeFg,
          ),
          const SizedBox(width: 8),
          Text(
            primaryIsReactivate ? "إعادة تفعيل" : "إلغاء",
            style: TextStyle(color: swipeFg, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );

    // السحب بالعكس: تعديل
    final secondaryBg = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: editBase.withValues(alpha: isDark ? .22 : .12),
      ),
      alignment: AlignmentDirectional.centerEnd,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "تعديل",
            style: TextStyle(color: editFg, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Icon(Icons.edit_rounded, color: editFg),
        ],
      ),
    );

    final card = Dismissible(
      key: ValueKey("search-tx-${widget.tx.key ?? widget.tx.id}"),
      direction: DismissDirection.horizontal,
      background: primaryBg,
      secondaryBackground: secondaryBg,
      confirmDismiss: (dir) async {
        if (_busy || _deleting) return false;

        if (dir == DismissDirection.startToEnd) {
          if (widget.tx.companyMovementType != null) {
            if (widget.tx.companyMovementType!.isCancelled) {
              widget.onEdit();
            } else {
              await widget.onCancel();
            }
          } else if (widget.tx.status == TransactionStatus.cancelled) {
            await widget.onSetAdded();
          } else {
            await widget.onCancel();
          }
          return false;
        }

        if (dir == DismissDirection.endToStart) {
          widget.onEdit();
          return false;
        }

        return false;
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: _cardBg(context),
          border: Border.all(color: _outline(context)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .14 : .04),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTapDetails,
            child: Stack(
              children: [
                // شريط لون الحالة على طرف البطاقة
                PositionedDirectional(
                  start: 0,
                  top: 0,
                  bottom: 0,
                  width: 5,
                  child: ColoredBox(color: widget.statusColor),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(17, 14, 8, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.tx.beneficiary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: primaryText,
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _StatusPill(
                            text: widget.statusText,
                            color: widget.statusColor,
                          ),
                          const SizedBox(width: 6),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.firstAmountText,
                        style: TextStyle(
                          color: primaryText,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                      if (widget.secondAmountText != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.secondAmountText!,
                          style: TextStyle(
                            color: primaryText.withValues(alpha: .90),
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _MiniInfoChip(
                            icon: Icons.account_balance_wallet_rounded,
                            label: widget.accountName,
                            color: _fg(context, widget.accent),
                          ),
                          _MiniInfoChip(
                            icon: Icons.event_rounded,
                            label: widget.dateText,
                            color: secondaryText,
                          ),
                          _MiniInfoChip(
                            icon: Icons.schedule_rounded,
                            label: widget.timeText,
                            color: secondaryText,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: _busy ? null : widget.onTapDetails,
                            icon: const Icon(Icons.article_outlined, size: 18),
                            label: const Text("تفاصيل"),
                          ),
                          const Spacer(),
                          PopupMenuButton<String>(
                            enabled: !_busy,
                            icon: Icon(
                              Icons.more_vert_rounded,
                              color: secondaryText,
                            ),
                            color: cs.surfaceContainerHighest,
                            onSelected: (val) async {
                              switch (val) {
                                case 'details':
                                  widget.onTapDetails();
                                  break;
                                case 'history':
                                  await openTransactionHistory(
                                    context,
                                    widget.tx,
                                  );
                                  break;
                                case 'received':
                                  await widget.onSetReceived();
                                  break;
                                case 'added':
                                  await widget.onSetAdded();
                                  break;
                                case 'cancel':
                                  await widget.onCancel();
                                  break;
                                case 'edit':
                                  widget.onEdit();
                                  break;
                                case 'delete':
                                  await _handleDelete();
                                  break;
                              }
                            },
                            itemBuilder: (ctx) {
                              final isCompany =
                                  widget.tx.companyMovementType != null;
                              return [
                                const PopupMenuItem(
                                  value: 'details',
                                  child: Text("تفاصيل"),
                                ),
                                const PopupMenuItem(
                                  value: 'history',
                                  child: Text("سجل التعديلات"),
                                ),
                                if (!isCompany)
                                  const PopupMenuItem(
                                    value: 'received',
                                    child: Text("تمييز كـ مستلمة"),
                                  ),
                                if (!isCompany)
                                  const PopupMenuItem(
                                    value: 'added',
                                    child: Text("تمييز كـ مضافة"),
                                  ),
                                if (!isCompany)
                                  const PopupMenuItem(
                                    value: 'cancel',
                                    child: Text("إلغاء الحركة"),
                                  ),
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text(
                                    isCompany
                                        ? 'تغيير النوع (مرسلة / استقبال)'
                                        : 'تعديل',
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(
                                    "حذف نهائي",
                                    style: TextStyle(color: cs.error),
                                  ),
                                ),
                              ];
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: AnimatedBuilder(
        animation: _deleteController,
        builder: (context, child) {
          final p = _deleteController.value;
          final fade = 1 - p;
          final scale = 1 - (0.16 * Curves.easeIn.transform(p));
          final slideX = 36 * Curves.easeInOut.transform(p);

          return IgnorePointer(
            ignoring: _busy,
            child: Transform.translate(
              offset: Offset(slideX, 0),
              child: Transform.scale(
                alignment: Alignment.center,
                scale: scale,
                child: Opacity(
                  opacity: fade.clamp(0, 1),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      child!,
                      if (_deleting)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _ShatterPainter(
                                progress: p,
                                color: widget.statusColor,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
        child: card,
      ),
    );
  }
}

class _MiniInfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MiniInfoChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);

    final border = color.withValues(alpha: isDark ? .34 : .22);
    final fill = color.withValues(alpha: isDark ? .14 : .08);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShatterPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _ShatterPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final opacity = (1 - progress).clamp(0.0, 1.0);
    final fadePaint = Paint()..color = Colors.white.withOpacity(.05 * opacity);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(24)),
      fadePaint,
    );

    final particlePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withOpacity(0.85 * opacity);

    final whitePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white.withOpacity(0.65 * opacity);

    const cols = 6;
    const rows = 4;
    final cellW = size.width / cols;
    final cellH = size.height / rows;

    int index = 0;
    for (int y = 0; y < rows; y++) {
      for (int x = 0; x < cols; x++) {
        final center = Offset((x + .5) * cellW, (y + .5) * cellH);

        final angle = (index * 37) * math.pi / 180.0;
        final travel =
            (30 + (index % 5) * 12) * Curves.easeOut.transform(progress);
        final dx = math.cos(angle) * travel;
        final dy = math.sin(angle) * travel - (12 * progress);

        final rect = Rect.fromCenter(
          center: center.translate(dx, dy),
          width: cellW * (0.42 - 0.16 * progress),
          height: cellH * (0.32 - 0.12 * progress),
        );

        final round = RRect.fromRectAndRadius(rect, const Radius.circular(6));
        canvas.drawRRect(round, index.isEven ? particlePaint : whitePaint);

        index++;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ShatterPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
