import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/share_import/share_import_service.dart';
import '../utils/chunked_task.dart';
import '../widgets/import_sheets.dart';
import '../widgets/operation_progress_bar.dart';
import 'bubble_screen.dart';
import 'verify_receive_screen.dart';

class ParseTextScreen extends StatefulWidget {
  final String? initialText;
  final bool pasteFromClipboardOnOpen;

  /// حساب محدد مسبقًا (عند فتح الصفحة من ملف تمت مشاركته مع التطبيق)
  final Account? initialAccount;

  /// ملخص الملف المستورد (يظهر فوق النص)
  final ImportSummary? importSummary;

  const ParseTextScreen({
    super.key,
    this.initialText,
    this.pasteFromClipboardOnOpen = false,
    this.initialAccount,
    this.importSummary,
  });

  @override
  State<ParseTextScreen> createState() => _ParseTextScreenState();
}

class _ParseTextScreenState extends State<ParseTextScreen>
    with TickerProviderStateMixin {
  final _text = TextEditingController();

  Account? _selectedAccount;
  bool _isBusy = false;

  /// الملف المستورد حاليًا (مشاركة من تطبيق آخر أو زر «استيراد ملف»)
  ImportSummary? _importSummary;
  bool _importDetailsOpen = false;

  /// تقدم العملية الجارية (شريط سفلي بالنسبة المئوية)
  final ValueNotifier<OperationProgress?> _progress =
      ValueNotifier<OperationProgress?>(null);

  late final AnimationController _pulseController;
  late final AnimationController _fadeController;
  late final Animation<double> _pulseAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();

    _pulseAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOutCubic,
    );

    _importSummary = widget.importSummary;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final initial = widget.initialText?.trim() ?? '';
      final preset = _resolveAccount(widget.initialAccount);
      if (initial.isNotEmpty) {
        setState(() {
          _text.text = initial;
          if (preset != null) _selectedAccount = preset;
        });
        // الحساب اختاره المستخدم مسبقًا (مشاركة ملف) → لا حاجة للكشف التلقائي
        if (preset == null) unawaited(_detectAccountsWithCountAsync(initial));
      } else if (preset != null) {
        setState(() => _selectedAccount = preset);
      } else if (widget.pasteFromClipboardOnOpen) {
        unawaited(_paste());
      }
    });
  }

  /// نفس كائن الحساب الموجود في الصندوق (حتى يطابق عناصر القائمة المنسدلة)
  Account? _resolveAccount(Account? account) {
    if (account == null) return null;
    for (final a in DatabaseService.accountsBox.values) {
      if (identical(a, account)) return a;
    }
    for (final a in DatabaseService.accountsBox.values) {
      if (a.id == account.id) return a;
    }
    return null;
  }

  @override
  void dispose() {
    _text.dispose();
    _pulseController.dispose();
    _fadeController.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _setProgress(OperationProgress? p) {
    if (mounted) _progress.value = p;
  }

  void _setBusy(bool value) {
    if (!mounted) return;
    setState(() => _isBusy = value);
    if (!value) _setProgress(null);
  }

  /// لونا الحساب (الأساسي والثاني للتدرج). الشركات: بنفسجي ← وردي زاهي
  /// (بدل اللون الباهت السابق)، والمكاتب: لون من اسم الحساب مع درجة قريبة.
  (Color, Color) _palette(Account? account) {
    if (account == null) {
      return (const Color(0xFF2563EB), const Color(0xFF0D9488));
    }
    if (account.type.isCompany) {
      return (const Color(0xFF7C3AED), const Color(0xFFDB2777));
    }
    final hue = (account.name.trim().hashCode.abs() % 360).toDouble();
    return (
      HSVColor.fromAHSV(1, hue, 0.70, 0.86).toColor(),
      HSVColor.fromAHSV(1, (hue + 38) % 360, 0.62, 0.84).toColor(),
    );
  }

  Color _accountBaseColor(Account? account) => _palette(account).$1;

  List<Color> _buildGradient(Account? account, Brightness brightness) {
    final (a, b) = _palette(account);
    if (brightness == Brightness.dark) {
      return [
        Color.lerp(a, Colors.black, 0.62)!,
        const Color(0xFF0B1020),
        Color.lerp(b, Colors.black, 0.70)!,
      ];
    }
    return [
      Color.lerp(a, Colors.white, 0.84)!,
      Color.lerp(b, Colors.white, 0.90)!,
      const Color(0xFFF8FAFC),
    ];
  }

  Color _cardColorFor(Account? account, Brightness brightness) {
    final base = _accountBaseColor(account);
    return brightness == Brightness.dark
        ? Color.lerp(base, const Color(0xFF111827), 0.86)!
        : Colors.white.withValues(alpha: 0.92);
  }

  Future<void> _paste() async {
    if (_isBusy) return;
    _setBusy(true);
    _setProgress(
      const OperationProgress(
        label: 'جارٍ قراءة الحافظة...',
        done: 0,
        total: 0,
      ),
    );

    String clip = '';
    try {
      final data = await Clipboard.getData('text/plain');
      clip = data?.text ?? '';
    } catch (_) {
      clip = '';
    }

    if (clip.isEmpty) {
      _setBusy(false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("📋 الحافظة فارغة")));
      }
      return;
    }

    _setProgress(
      const OperationProgress(label: 'جارٍ لصق النص...', done: 0, total: 0),
    );
    await yieldToUi();
    if (!mounted) return;
    setState(() => _text.text = clip);
    await yieldToUi();
    _setBusy(false);
    await _detectAccountsWithCountAsync(clip);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// استيراد ملف (Excel / CSV / نص / محادثة واتساب) إلى مربع النص
  Future<void> _importFile() async {
    if (_isBusy) return;
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ImportFileConverter.supportedExtensions,
        allowMultiple: true,
        withData: true,
      );
    } catch (e) {
      _snack('تعذر فتح نافذة اختيار الملف: $e');
      return;
    }
    if (picked == null || picked.files.isEmpty || !mounted) return;

    final files = picked.files;
    final options = ShareImportService.optionsFromSettings();
    final conversions = <ImportConversion>[];
    _setBusy(true);
    try {
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        _setProgress(
          OperationProgress(
            label: 'جارٍ قراءة ${f.name}...',
            done: i,
            total: files.length,
          ),
        );
        await yieldToUi();
        final bytes = f.bytes;
        if (bytes == null) {
          conversions.add(
            ImportConversion.failure(f.name, 'تعذر قراءة محتوى الملف'),
          );
          continue;
        }
        conversions.add(
          await ShareImportService.convertBytes(
            bytes: bytes,
            fileName: f.name,
            options: files.length > 1
                ? options.copyWith(labelSuffix: f.name)
                : options,
          ),
        );
      }
    } finally {
      _setBusy(false);
    }
    if (!mounted) return;

    if (!conversions.any((c) => c.ok)) {
      _snack(
        conversions
            .map((c) => '${c.fileName}: ${c.error ?? 'لا توجد بيانات'}')
            .join('\n'),
      );
      return;
    }

    final selected = <List<ImportMessage>>[];
    for (final c in conversions) {
      if (c.ok && c.kind == ImportFileKind.whatsapp) {
        final range = await pickWhatsAppRange(context, c);
        if (range == null || !mounted) return;
        selected.add(range);
      } else {
        selected.add(c.messages);
      }
    }

    final combined = ShareImportService.combine(
      conversions,
      selectedMessages: selected,
    );
    if (combined.text.trim().isEmpty) {
      _snack('لا توجد رسائل في الفترة المختارة');
      return;
    }

    var text = combined.text;
    final current = _text.text.trim();
    if (current.isNotEmpty) {
      final mode = await showDialog<String>(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('يوجد نص في المربع'),
            content: const Text(
              'هل تريد استبدال النص الحالي بمحتوى الملف أم إضافة الملف بعده؟',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'append'),
                child: const Text('إضافة بعده'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'replace'),
                child: const Text('استبدال'),
              ),
            ],
          ),
        ),
      );
      if (mode == null || !mounted) return;
      if (mode == 'append') text = '$current\n$text';
    }

    setState(() {
      _text.text = text;
      _importSummary = combined.summary;
      _importDetailsOpen = combined.summary.errors.isNotEmpty;
    });
    _snack('تم تجهيز ${combined.summary.messageCount} رسالة من الملف');
    if (_selectedAccount == null) {
      await _detectAccountsWithCountAsync(combined.text);
    }
  }

  Widget _buildImportCard(Color color, Brightness brightness) {
    final summary = _importSummary!;
    final cs = Theme.of(context).colorScheme;
    final hasDetails = summary.notes.isNotEmpty || summary.errors.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
      decoration: BoxDecoration(
        color: brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.05)
            : color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ImportSummaryHeader(summary: summary, color: color),
              ),
              IconButton(
                tooltip: 'إخفاء',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _importSummary = null),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          if (hasDetails)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _importDetailsOpen = !_importDetailsOpen),
                icon: Icon(
                  _importDetailsOpen
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                ),
                label: Text(
                  summary.errors.isNotEmpty
                      ? 'تفاصيل القراءة (${summary.errors.length} تنبيه)'
                      : 'تفاصيل القراءة',
                ),
              ),
            ),
          if (hasDetails && _importDetailsOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                        style: const TextStyle(fontSize: 12.5, height: 1.4),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// تحديد الحساب من النص على دفعات (حتى لا يتجمد التطبيق مع النصوص الطويلة)
  Future<void> _detectAccountsWithCountAsync(String text) async {
    final accounts = DatabaseService.accountsBox.values.toList();
    if (accounts.isEmpty || text.trim().isEmpty) return;

    _setBusy(true);
    const label = 'جارٍ تحديد الحساب من النص...';
    _setProgress(
      OperationProgress(label: label, done: 0, total: accounts.length),
    );
    await yieldToUi();

    final Map<Account, int> matches = {};
    try {
      final normalizedText = _normalizeForAccountMatch(text);
      await runTimeSliced(
        total: accounts.length,
        isCancelled: () => !mounted,
        onProgress: (done, total) => _setProgress(
          OperationProgress(label: label, done: done, total: total),
        ),
        work: (i) {
          final account = accounts[i];
          var count = 0;
          for (final keyword in _accountMatchKeywords(account)) {
            final normalizedKeyword = _normalizeForAccountMatch(keyword);
            if (normalizedKeyword.isEmpty) continue;
            final regex = RegExp(RegExp.escape(normalizedKeyword));
            count += regex.allMatches(normalizedText).length;
          }
          if (count > 0) matches[account] = count;
        },
      );
    } finally {
      _setBusy(false);
    }

    if (matches.isEmpty || !mounted) return;

    if (matches.length == 1) {
      setState(() => _selectedAccount = matches.keys.first);
      return;
    }

    final selected = await _showAccountPicker(matches);
    if (selected != null && mounted) {
      setState(() => _selectedAccount = selected);
    }
  }

  String _stripDiacritics(String s) =>
      s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');

  String _normalizeForAccountMatch(String value) {
    var s = _stripDiacritics(value).toLowerCase();
    s = s.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
    s = s.replaceAll('ى', 'ي').replaceAll('ئ', 'ي').replaceAll('ؤ', 'و');
    s = s.replaceAll('ة', 'ه');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<String> _accountMatchKeywords(Account account) {
    final seen = <String>{};
    final out = <String>[];

    for (final value in <String>[account.name, ...account.keywords]) {
      final trimmed = value.trim();
      final normalized = _normalizeForAccountMatch(trimmed);
      if (trimmed.isEmpty || normalized.isEmpty || !seen.add(normalized)) {
        continue;
      }
      out.add(trimmed);
    }

    return out;
  }

  Future<Account?> _showAccountPicker(Map<Account, int> matches) async {
    final sortedEntries = matches.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return showGeneralDialog<Account>(
      context: context,
      barrierLabel: 'accounts',
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, __, ___) {
        final brightness = Theme.of(context).brightness;

        return SafeArea(
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.90,
                constraints: const BoxConstraints(
                  maxWidth: 520,
                  maxHeight: 560,
                ),
                decoration: BoxDecoration(
                  color: brightness == Brightness.dark
                      ? const Color(0xFF0F172A)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 30,
                      color: Colors.black26,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(28),
                          ),
                          gradient: LinearGradient(
                            colors: [
                              _palette(_selectedAccount).$1,
                              _palette(_selectedAccount).$2,
                            ],
                            begin: Alignment.topRight,
                            end: Alignment.bottomLeft,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.18),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(
                                Icons.account_balance_wallet_rounded,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "تم العثور على عدة حسابات",
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    "اختر الحساب الأنسب لإسناد الحركات إليه",
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: ListView.separated(
                          padding: const EdgeInsets.all(16),
                          shrinkWrap: true,
                          itemCount: sortedEntries.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final entry = sortedEntries[index];
                            final account = entry.key;
                            final count = entry.value;
                            final color = _accountBaseColor(account);

                            return InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => Navigator.pop(context, account),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 220),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: brightness == Brightness.dark
                                      ? Colors.white.withOpacity(0.04)
                                      : color.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: color.withOpacity(0.22),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 46,
                                      height: 46,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            color,
                                            Color.lerp(
                                              color,
                                              Colors.white,
                                              0.35,
                                            )!,
                                          ],
                                          begin: Alignment.topRight,
                                          end: Alignment.bottomLeft,
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: const Icon(
                                        Icons.wallet_rounded,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            account.name,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 15,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            "تم العثور عليه $count مرة",
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.color
                                                  ?.withOpacity(0.85),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (count > 1)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color.withOpacity(0.12),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.trending_up_rounded,
                                              size: 16,
                                              color: color,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              "أقوى تطابق",
                                              style: TextStyle(
                                                color: color,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
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
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text("إلغاء"),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, animation, __, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  bool _validate() {
    final raw = _text.text.trim();

    if (_selectedAccount == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("🧾 اختر حساب أولًا")));
      return false;
    }

    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("✍️ ألصق النص المراد تحليله")),
      );
      return false;
    }

    return true;
  }

  Future<void> _goBubble() async {
    if (!_validate()) return;
    // شاشة الفقاعات تحلل الرسائل على دفعات وتعرض نسبة التقدم بنفسها،
    // لذلك ننتقل فورًا بدون أي انتظار.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BubbleScreen(
          account: _selectedAccount!,
          rawText: _text.text.trim(),
        ),
      ),
    );
  }

  Future<void> _goVerifyReceive() async {
    if (!_validate()) return;

    _setBusy(true);
    _setProgress(
      const OperationProgress(
        label: 'جارٍ تجهيز صفحة التسليم...',
        done: 0,
        total: 0,
      ),
    );
    // نعطي الواجهة فرصة لرسم شريط التقدم قبل بناء الصفحة التالية
    await yieldToUi();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _setBusy(false);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VerifyReceiveScreen(
          account: _selectedAccount!,
          rawText: _text.text.trim(),
        ),
      ),
    );
  }

  Widget _buildHeaderCard(Brightness brightness) {
    final (selectedColor, secondColor) = _palette(_selectedAccount);
    final isCompany = _selectedAccount?.type.isCompany ?? false;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [selectedColor, secondColor],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: selectedColor.withValues(alpha: 0.32),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          ScaleTransition(
            scale: _pulseAnimation,
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.16),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                isCompany ? Icons.business_rounded : Icons.auto_awesome_rounded,
                color: Colors.white,
                size: 30,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selectedAccount == null
                      ? "تحليل النص واختيار الحساب"
                      : _selectedAccount!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _selectedAccount == null
                      ? "اختر الحساب، ثم ألصق النص أو استعرض ملفًا، وبعدها اضغط إضافة أو تسليم"
                      : "${_selectedAccount!.type.label} • ألصق النص أو استعرض ملفًا ثم اختر إضافة أو تسليم",
                  style: const TextStyle(color: Colors.white, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon, Color color) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
      ],
    );
  }

  int get _lineCount =>
      _text.text.split('\n').where((l) => l.trim().isNotEmpty).length;

  void _clearText() {
    if (_text.text.isEmpty) return;
    final previous = _text.text;
    final previousSummary = _importSummary;
    setState(() {
      _text.clear();
      _importSummary = null;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('تم مسح النص'),
          action: SnackBarAction(
            label: 'تراجع',
            onPressed: () {
              if (!mounted) return;
              setState(() {
                _text.text = previous;
                _importSummary = previousSummary;
              });
            },
          ),
        ),
      );
  }

  /// بطاقة بخلفية شفافة أنيقة
  Widget _glassCard({
    required Widget child,
    required Color color,
    required Brightness brightness,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        color: _cardColorFor(_selectedAccount, brightness),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: color.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(
              alpha: brightness == Brightness.dark ? 0.10 : 0.10,
            ),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }

  InputDecoration _fieldDecoration({
    required Color color,
    required Brightness brightness,
    String? label,
    String? hint,
    Widget? prefixIcon,
    double radius = 18,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: prefixIcon,
      filled: true,
      fillColor: brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.05)
          : Color.lerp(color, Colors.white, 0.95),
      alignLabelWithHint: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: BorderSide(color: color.withValues(alpha: 0.16)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: BorderSide(color: color, width: 1.5),
      ),
    );
  }

  /// زرا «إضافة» و«تسليم» ثابتان أسفل الشاشة (مع شريط التقدم فوقهما)
  Widget _buildBottomBar(Brightness brightness) {
    final (a, b) = _palette(_selectedAccount);
    final dark = brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0F172A) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OperationProgressBar(
                progress: _progress,
                color: a,
                padding: const EdgeInsets.only(bottom: 10),
              ),
              Row(
                children: [
                  Expanded(
                    child: _GradientActionButton(
                      label: 'إضافة',
                      icon: Icons.add_task_rounded,
                      colors: [a, Color.lerp(a, b, 0.35)!],
                      onPressed: _isBusy ? null : _goBubble,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _GradientActionButton(
                      label: 'تسليم',
                      icon: Icons.send_rounded,
                      colors: [Color.lerp(a, b, 0.65)!, b],
                      onPressed: _isBusy ? null : _goVerifyReceive,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;

    return ValueListenableBuilder(
      valueListenable: DatabaseService.accountsBox.listenable(),
      builder: (context, Box<Account> box, _) {
        final accounts = box.values.toList();
        final selectedColor = _accountBaseColor(_selectedAccount);
        final pageGradient = _buildGradient(_selectedAccount, brightness);
        final onPage = brightness == Brightness.dark
            ? Colors.white
            : const Color(0xFF0F172A);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            extendBodyBehindAppBar: true,
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: const Text(
                'تحليل النص',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              centerTitle: true,
              foregroundColor: onPage,
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              actions: [
                // استعراض ملف: زر أعلى الصفحة (بدل مكانه تحت زر اللصق)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 10),
                  child: FilledButton.tonalIcon(
                    onPressed: _isBusy ? null : _importFile,
                    icon: const Icon(Icons.folder_open_rounded, size: 19),
                    label: const Text('استعراض ملف'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: selectedColor.withValues(alpha: 0.14),
                      foregroundColor: brightness == Brightness.dark
                          ? Colors.white
                          : Color.lerp(selectedColor, Colors.black, 0.25),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: _buildBottomBar(brightness),
            body: Stack(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: pageGradient,
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                    ),
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        _buildHeaderCard(brightness),
                        const SizedBox(height: 16),
                        _glassCard(
                          color: selectedColor,
                          brightness: brightness,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSectionTitle(
                                'الحساب',
                                Icons.account_balance_wallet_rounded,
                                selectedColor,
                              ),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<Account>(
                                value: _selectedAccount,
                                isExpanded: true,
                                borderRadius: BorderRadius.circular(20),
                                icon: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: selectedColor,
                                ),
                                items: accounts
                                    .map(
                                      (a) => DropdownMenuItem<Account>(
                                        value: a,
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 14,
                                              height: 14,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                gradient: LinearGradient(
                                                  colors: [
                                                    _palette(a).$1,
                                                    _palette(a).$2,
                                                  ],
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                '${a.name} • ${a.type.label}',
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() => _selectedAccount = v);
                                },
                                decoration: _fieldDecoration(
                                  color: selectedColor,
                                  brightness: brightness,
                                  label: 'اختر الحساب',
                                  prefixIcon: Icon(
                                    Icons.wallet_rounded,
                                    color: selectedColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        _glassCard(
                          color: selectedColor,
                          brightness: brightness,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildSectionTitle(
                                      'النص المراد تحليله',
                                      Icons.text_snippet_rounded,
                                      selectedColor,
                                    ),
                                  ),
                                  if (_text.text.trim().isNotEmpty)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: selectedColor.withValues(
                                          alpha: 0.10,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Text(
                                        '$_lineCount سطر',
                                        style: TextStyle(
                                          color: selectedColor,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  if (_text.text.isNotEmpty)
                                    IconButton(
                                      tooltip: 'مسح النص',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: _isBusy ? null : _clearText,
                                      icon: Icon(
                                        Icons.delete_sweep_rounded,
                                        color: selectedColor,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (_importSummary != null)
                                _buildImportCard(selectedColor, brightness),
                              TextField(
                                controller: _text,
                                maxLines: 14,
                                minLines: 8,
                                onChanged: (_) => setState(() {}),
                                style: const TextStyle(height: 1.55),
                                decoration: _fieldDecoration(
                                  color: selectedColor,
                                  brightness: brightness,
                                  hint:
                                      '✏️ ألصق هنا الرسائل أو النص المراد تحليله...',
                                  radius: 22,
                                ),
                              ),
                              const SizedBox(height: 12),
                              _GradientActionButton(
                                label: 'لصق وتحليل الحساب تلقائيًا',
                                icon: Icons.content_paste_go_rounded,
                                colors: [
                                  selectedColor,
                                  Color.lerp(
                                    selectedColor,
                                    _palette(_selectedAccount).$2,
                                    0.5,
                                  )!,
                                ],
                                height: 50,
                                onPressed: _isBusy ? null : _paste,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// زر بتدرج لوني (إضافة / تسليم / لصق)
class _GradientActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback? onPressed;
  final double height;

  const _GradientActionButton({
    required this.label,
    required this.icon,
    required this.colors,
    required this.onPressed,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1 : 0.55,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: colors.first.withValues(alpha: 0.32),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onPressed,
            child: SizedBox(
              height: height,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
