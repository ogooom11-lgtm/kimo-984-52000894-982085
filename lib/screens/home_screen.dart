import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'timeline_analytics_screen.dart';
import '../database_service.dart';
import '../models.dart';
import 'add_account_screen.dart';
import 'account_screen.dart';
import 'add_edit_transaction_screen.dart';
import 'operations_log_screen.dart';

enum _QuickStatusFilter { all, added, received, cancelled }

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
      _selectedAccountId != null;

  void _clearAllSearch() {
    _searchCtrl.clear();
    _debounce?.cancel();
    setState(() {
      _liveQuery = '';
      _query = '';
      _quickFilter = _QuickStatusFilter.all;
      _todayOnly = false;
      _selectedAccountId = null;
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

  Color _accountAccent(int accountId) {
    final hue = ((accountId * 47) % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, .70, .56).toColor();
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
    final textTheme = Theme.of(context).textTheme;

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

            final txCountByAccount = <int, int>{};
            int receivedToday = 0;
            int cancelledToday = 0;
            int addedCount = 0;
            int officeMovementCount = 0;
            int companyMovementCount = 0;

            for (final tx in allTx) {
              txCountByAccount[tx.accountId] =
                  (txCountByAccount[tx.accountId] ?? 0) + 1;

              if (accountsById[tx.accountId]?.type == AccountType.company) {
                companyMovementCount++;
              } else {
                officeMovementCount++;
              }

              if (tx.status == TransactionStatus.added) addedCount++;
              if (tx.receivedAt != null &&
                  _isSameDay(tx.receivedAt!, DateTime.now())) {
                receivedToday++;
              }
              if (tx.cancelledAt != null &&
                  _isSameDay(tx.cancelledAt!, DateTime.now())) {
                cancelledToday++;
              }
            }

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                backgroundColor: cs.surface,
                floatingActionButtonLocation:
                    FloatingActionButtonLocation.endFloat,
                floatingActionButton: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 70),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingActionButton(
                          heroTag: 'addAccountFab',
                          tooltip: 'إضافة حساب',
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AddAccountScreen(),
                              ),
                            );
                          },
                          child: const Icon(Icons.add_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
                body: CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      expandedHeight: 150,
                      backgroundColor: cs.surface,
                      foregroundColor: cs.onSurface,
                      surfaceTintColor: Colors.transparent,
                      actions: [
                        IconButton(
                          tooltip: 'سجل العمليات',
                          icon: const Icon(Icons.history_rounded),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const OperationsLogScreen(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      flexibleSpace: FlexibleSpaceBar(
                        titlePadding: const EdgeInsetsDirectional.only(
                          start: 20,
                          bottom: 18,
                        ),
                        title: Text(
                          "الحسابات",
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 24,
                            color: cs.onSurface,
                          ),
                        ),
                        background: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topRight,
                              end: Alignment.bottomLeft,
                              colors: [cs.primary.withOpacity(.14), cs.surface],
                            ),
                          ),
                        ),
                      ),
                    ),

                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                        child: Column(
                          children: [
                            _buildSearchBox(context, accounts),
                            const SizedBox(height: 10),
                            _buildQuickFilters(accounts),
                          ],
                        ),
                      ),
                    ),

                    if (!_hasActiveSearch) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: SizedBox(
                            height: 96,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                _StatCard(
                                  title: "حسابات المكاتب",
                                  value: officeAccounts.length.toString(),
                                  icon: Icons.account_balance_wallet_rounded,
                                  accent: const Color(0xFF2563EB),
                                ),
                                _StatCard(
                                  title: "حسابات الشركات",
                                  value: companyAccounts.length.toString(),
                                  icon: Icons.business_rounded,
                                  accent: const Color(0xFF7C3AED),
                                ),
                                _StatCard(
                                  title: "حركات المكاتب",
                                  value: officeMovementCount.toString(),
                                  icon: Icons.receipt_long_rounded,
                                  accent: const Color(0xFF0891B2),
                                ),
                                _StatCard(
                                  title: "حركات الشركات",
                                  value: companyMovementCount.toString(),
                                  icon: Icons.swap_horiz_rounded,
                                  accent: const Color(0xFF0F766E),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                          child: Text(
                            "دليل الحسابات",
                            style: textTheme.titleMedium?.copyWith(
                              color: cs.onSurface,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      if (accounts.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                            child: _EmptyStateCard(
                              icon: Icons.account_balance_wallet_outlined,
                              title: "لا يوجد حسابات حاليًا",
                              subtitle: "ابدأ بإضافة حساب جديد من الزر العائم",
                            ),
                          ),
                        )
                      else ...[
                        if (officeAccounts.isNotEmpty) ...[
                          SliverToBoxAdapter(
                            child: _AccountGroupHeader(
                              title: 'حسابات المكاتب',
                              subtitle: '${officeAccounts.length} حساب',
                              icon: Icons.account_balance_wallet_rounded,
                              accent: const Color(0xFF2563EB),
                            ),
                          ),
                          SliverList.builder(
                            itemCount: officeAccounts.length,
                            itemBuilder: (context, index) {
                              final account = officeAccounts[index];
                              final txCount = txCountByAccount[account.id] ?? 0;

                              return _AnimatedEntrance(
                                index: index,
                                child: _AccountCard(
                                  account: account,
                                  accent: _accountAccent(account.id),
                                  txCount: txCount,
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
                        ],
                        if (companyAccounts.isNotEmpty) ...[
                          SliverToBoxAdapter(
                            child: _AccountGroupHeader(
                              title: 'حسابات الشركات',
                              subtitle: '${companyAccounts.length} حساب',
                              icon: Icons.business_rounded,
                              accent: const Color(0xFF7C3AED),
                            ),
                          ),
                          SliverList.builder(
                            itemCount: companyAccounts.length,
                            itemBuilder: (context, index) {
                              final account = companyAccounts[index];
                              final txCount = txCountByAccount[account.id] ?? 0;

                              return _AnimatedEntrance(
                                index: officeAccounts.length + index,
                                child: _AccountCard(
                                  account: account,
                                  accent: const Color(0xFF7C3AED),
                                  txCount: txCount,
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
                        ],
                      ],
                    ] else ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                          child: Row(
                            children: [
                              Text(
                                "نتائج البحث",
                                style: textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: cs.primary.withOpacity(.14),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: cs.primary.withOpacity(.28),
                                  ),
                                ),
                                child: Text(
                                  "${searchResults.length}",
                                  style: TextStyle(
                                    color: cs.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const Spacer(),
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
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 30, 16, 0),
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

  Widget _buildSearchBox(BuildContext context, List<Account> accounts) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(.08)
            : cs.surfaceContainerHighest.withOpacity(.75),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: _searchFocused
              ? cs.primary.withOpacity(.55)
              : cs.outlineVariant.withOpacity(.55),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? .18 : .06),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          hintText: "ابحث عن حركة، حساب، عملة، حالة، تاريخ...",
          hintStyle: TextStyle(color: cs.onSurfaceVariant.withOpacity(.92)),
          prefixIcon: Icon(Icons.search_rounded, color: cs.onSurfaceVariant),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_liveQuery.isNotEmpty)
                IconButton(
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
                onPressed: () => _showSearchFilterSheet(context, accounts),
                icon: Icon(Icons.tune_rounded, color: cs.primary),
              ),
            ],
          ),
          border: InputBorder.none,
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

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          _QuickChip(
            text: "الكل",
            selected: _quickFilter == _QuickStatusFilter.all,
            onTap: () => setState(() => _quickFilter = _QuickStatusFilter.all),
          ),
          _QuickChip(
            text: "مضافة",
            selected: _quickFilter == _QuickStatusFilter.added,
            onTap: () =>
                setState(() => _quickFilter = _QuickStatusFilter.added),
          ),
          _QuickChip(
            text: "مستلمة",
            selected: _quickFilter == _QuickStatusFilter.received,
            accent: const Color(0xFF00C853),
            onTap: () =>
                setState(() => _quickFilter = _QuickStatusFilter.received),
          ),
          _QuickChip(
            text: "ملغية",
            selected: _quickFilter == _QuickStatusFilter.cancelled,
            accent: const Color(0xFFE53935),
            onTap: () =>
                setState(() => _quickFilter = _QuickStatusFilter.cancelled),
          ),
          _QuickChip(
            text: "اليوم",
            selected: _todayOnly,
            accent: cs.primary,
            onTap: () => setState(() => _todayOnly = !_todayOnly),
          ),
          if (selectedAccount != null)
            _QuickChip(
              text: "حساب: ${selectedAccount.name}",
              selected: true,
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
        if (mounted) {
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
      if (mounted) {
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

class _QuickChip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  final Color? accent;

  const _QuickChip({
    required this.text,
    required this.selected,
    required this.onTap,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final c = accent ?? cs.primary;

    final bg = selected
        ? c.withOpacity(isDark ? .20 : .12)
        : (isDark ? cs.surfaceContainerHigh : cs.surface);

    final border = selected
        ? c.withOpacity(isDark ? .55 : .38)
        : cs.outlineVariant.withOpacity(isDark ? .55 : .85);

    final textColor = selected ? c : cs.onSurface;

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border),
            ),
            child: Text(
              text,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color accent;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 168,
      margin: const EdgeInsetsDirectional.only(end: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [accent.withOpacity(.22), Colors.white.withOpacity(.04)],
        ),
        border: Border.all(color: accent.withOpacity(.24)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: accent.withOpacity(.16),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.white.withOpacity(.72),
                    fontSize: 12,
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
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withOpacity(.45)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 44, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
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

class _AccountGroupHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;

  const _AccountGroupHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              accent.withOpacity(.18),
              cs.surfaceContainerHigh.withOpacity(.72),
            ],
          ),
          border: Border.all(color: accent.withOpacity(.30)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: accent.withOpacity(.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: accent.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                subtitle,
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final Account account;
  final Color accent;
  final int txCount;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _AccountCard({
    required this.account,
    required this.accent,
    required this.txCount,
    required this.onTap,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final light = HSLColor.fromColor(accent).withLightness(.62).toColor();
    final isCompany = account.type == AccountType.company;
    final typeColor = isCompany
        ? const Color(0xFFE9D5FF)
        : const Color(0xFFDBEAFE);
    final typeIcon = isCompany
        ? Icons.business_rounded
        : Icons.account_balance_wallet_rounded;
    final typeLabel = isCompany ? 'شركة' : 'مكتب';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [accent.withOpacity(.95), light.withOpacity(.92)],
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(.28),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        account.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    Container(
                      margin: const EdgeInsetsDirectional.only(end: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: typeColor.withOpacity(.28),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: typeColor.withOpacity(.50)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(typeIcon, color: Colors.white, size: 15),
                          const SizedBox(width: 5),
                          Text(
                            typeLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onMore,
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        "$txCount حركة",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.18),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_forward_rounded,
                        color: Colors.white,
                        size: 18,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? cs.surfaceContainerLow : cs.surface;
    final primaryText = cs.onSurface;
    final secondaryText = cs.onSurfaceVariant;

    final primaryIsReactivate =
        widget.tx.companyMovementType?.isCancelled == true ||
        widget.tx.status == TransactionStatus.cancelled;

    final primaryBg = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: primaryIsReactivate
            ? const Color(0xFFE8F5E9)
            : const Color(0xFFFFEBEE),
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Icon(
            primaryIsReactivate ? Icons.refresh_rounded : Icons.cancel_rounded,
            color: primaryIsReactivate ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 8),
          Text(
            primaryIsReactivate ? "إعادة تفعيل" : "إلغاء",
            style: TextStyle(
              color: primaryIsReactivate ? Colors.green : Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );

    final secondaryBg = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: const Color(0xFFE3F2FD),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            "تعديل",
            style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
          ),
          SizedBox(width: 8),
          Icon(Icons.edit_rounded, color: Colors.blue),
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
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: cardBg,
          border: Border.all(
            color: widget.accent.withOpacity(isDark ? .40 : .24),
          ),
          boxShadow: [
            BoxShadow(
              color: widget.accent.withOpacity(.09),
              blurRadius: 16,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: widget.onTapDetails,
          child: Row(
            children: [
              // نفس المحتوى الحالي كما هو
              Container(
                width: 6,
                height: 132,
                decoration: BoxDecoration(
                  color: widget.statusColor,
                  borderRadius: const BorderRadiusDirectional.only(
                    topStart: Radius.circular(24),
                    bottomStart: Radius.circular(24),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
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
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: widget.statusColor.withOpacity(.12),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: widget.statusColor.withOpacity(.28),
                              ),
                            ),
                            child: Text(
                              widget.statusText,
                              style: TextStyle(
                                color: widget.statusColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _MiniInfoChip(
                            icon: Icons.account_balance_wallet_rounded,
                            label: widget.accountName,
                            color: widget.statusColor,
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
                      const SizedBox(height: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.firstAmountText,
                            style: TextStyle(
                              color: primaryText,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          if (widget.secondAmountText != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              widget.secondAmountText!,
                              style: TextStyle(
                                color: primaryText.withOpacity(.92),
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
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
              ),
            ],
          ),
        ),
      ),
    );

    return AnimatedBuilder(
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final border = color.withOpacity(isDark ? .34 : .22);
    final fill = color.withOpacity(isDark ? .14 : .08);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
