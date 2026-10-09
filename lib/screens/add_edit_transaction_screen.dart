import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/destinations.dart';
import '../services/tx_undo.dart';
import '../widgets/app_messages.dart';
import '../widgets/destination_picker.dart';
import 'settings_screen.dart';

class AddEditTransactionScreen extends StatefulWidget {
  final Account account;
  final TransactionModel? existing;

  const AddEditTransactionScreen({
    super.key,
    required this.account,
    this.existing,
  });

  @override
  State<AddEditTransactionScreen> createState() =>
      _AddEditTransactionScreenState();
}

class _AddEditTransactionScreenState extends State<AddEditTransactionScreen> {
  final _rawController = TextEditingController();
  final _beneficiaryController = TextEditingController();
  final _amountController = TextEditingController();
  final _secondAmountController = TextEditingController();

  DateTime _date = DateTime.now();

  List<String> _currencies = [];
  String? _selectedCurrency;
  String? _selectedSecondCurrency;

  bool _isSaving = false;
  CompanyMovementType _companyMovement = CompanyMovementType.received;

  /// وجهة حركة الشركة (null = بدون)
  DestinationBook _destBook = DestinationBook.empty;
  String? _destination;

  // ===== ألوان متوافقة مع الوضع الفاتح والداكن =====
  ColorScheme get _cs => Theme.of(context).colorScheme;
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _cardColor => _isDark ? _cs.surfaceContainerLow : Colors.white;
  Color get _fieldFill => _isDark
      ? _cs.surfaceContainerHighest.withValues(alpha: .55)
      : Colors.grey.shade50;
  Color get _fieldBorder => _isDark ? _cs.outlineVariant : Colors.grey.shade300;
  Color get _softBorder =>
      _isDark ? _cs.outlineVariant.withValues(alpha: .6) : Colors.grey.shade200;
  Color get _focusBorder => _isDark ? _cs.primary : Colors.blue.shade400;
  Color get _shadowColor =>
      Colors.black.withValues(alpha: _isDark ? 0.25 : 0.05);

  InputDecoration _fieldDecoration({String? hintText, String? labelText}) {
    return InputDecoration(
      hintText: hintText,
      labelText: labelText,
      filled: true,
      fillColor: _fieldFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _fieldBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _fieldBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _focusBorder, width: 1.3),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCurrencies();
    _fillExistingIfNeeded();
  }

  @override
  void dispose() {
    _rawController.dispose();
    _beneficiaryController.dispose();
    _amountController.dispose();
    _secondAmountController.dispose();
    super.dispose();
  }

  void _loadCurrencies() {
    final s = DatabaseService.getSettings();
    _destBook = DestinationBook.fromSettings(s);
    _currencies = (s?.currencyMap.values.toList() ?? []).toSet().toList()
      ..sort();

    if (_currencies.isNotEmpty) {
      _selectedCurrency ??= _currencies.first;
      _selectedSecondCurrency ??= _currencies.first;
    }
  }

  void _fillExistingIfNeeded() {
    if (widget.existing == null) return;

    final t = widget.existing!;
    _beneficiaryController.text = t.beneficiary;
    _amountController.text = _formatThousandsFromNumber(t.amount);
    _secondAmountController.text = t.secondAmount != null
        ? _formatThousandsFromNumber(t.secondAmount!)
        : '';
    _selectedCurrency = t.currency;
    _selectedSecondCurrency = t.secondCurrency;
    _date = t.date;
    _companyMovement = t.companyMovementType ?? CompanyMovementType.received;
    _destination = t.destination;
  }

  Future<void> _pickDestination() async {
    final picked = await showDestinationPicker(
      context,
      book: _destBook,
      current: _destination,
    );
    if (!mounted) return;
    setState(() {
      // ممكن تنضاف وجهة جديدة من القائمة نفسها
      _destBook = DestinationBook.fromSettings(DatabaseService.getSettings());
      if (picked != null) _destination = picked.isEmpty ? null : picked;
    });
  }

  Widget _buildDestinationPicker() {
    final name = _destination?.trim() ?? '';
    final color = name.isEmpty
        ? (_isDark ? Colors.white70 : Colors.black54)
        : kDestColor;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('الوجهة', style: TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Material(
            color: color.withValues(alpha: _isDark ? .16 : .07),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _pickDestination,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: color.withValues(alpha: .4)),
                ),
                child: Row(
                  children: [
                    Icon(
                      name.isEmpty
                          ? Icons.not_listed_location_rounded
                          : Icons.place_rounded,
                      color: color,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        name.isEmpty ? 'بدون وجهة' : name,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: color,
                        ),
                      ),
                    ),
                    Icon(Icons.expand_more_rounded, color: color),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _extractDigitsOnly(String? input) {
    if (input == null) return null;

    final normalized = _toEnglishDigits(input).trim();

    if (normalized.isEmpty) return null;

    // إذا احتوى أحرف، نرفضه كمبلغ
    if (!RegExp(r'^[\d\.\,\s]+$').hasMatch(normalized)) {
      return null;
    }

    final digits = normalized.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return null;

    return digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  }

  String _toEnglishDigits(String input) {
    const arabicIndic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const easternArabicIndic = [
      '۰',
      '۱',
      '۲',
      '۳',
      '۴',
      '۵',
      '۶',
      '۷',
      '۸',
      '۹',
    ];

    var result = input;
    for (int i = 0; i < 10; i++) {
      result = result.replaceAll(arabicIndic[i], '$i');
      result = result.replaceAll(easternArabicIndic[i], '$i');
    }
    return result;
  }

  String _formatThousands(String digitsOnly) {
    if (digitsOnly.isEmpty) return '';

    final buffer = StringBuffer();
    for (int i = 0; i < digitsOnly.length; i++) {
      final indexFromEnd = digitsOnly.length - i;
      buffer.write(digitsOnly[i]);
      if (indexFromEnd > 1 && indexFromEnd % 3 == 1) {
        buffer.write('.');
      }
    }
    return buffer.toString();
  }

  String _formatThousandsFromNumber(num value) {
    final asIntString = value.toStringAsFixed(0);
    return _formatThousands(asIntString);
  }

  double _parseAmount(String text) {
    final digits = _extractDigitsOnly(text);
    if (digits == null || digits.isEmpty) return 0.0;
    return double.tryParse(digits) ?? 0.0;
  }

  Future<void> _save() async {
    if (_isSaving) return;

    final amount1 = _parseAmount(_amountController.text);
    final amount2 = _parseAmount(_secondAmountController.text);
    final secondAmount = amount2 > 0 ? amount2 : null;

    if (_beneficiaryController.text.trim().isEmpty ||
        (amount1 == 0.0 && secondAmount == null) ||
        _selectedCurrency == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('أدخل الاسم، ومبلغًا واحدًا على الأقل، واختر العملة'),
        ),
      );
      return;
    }

    if (secondAmount != null && _selectedSecondCurrency == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('اختر عملة للمبلغ الثاني')));
      return;
    }

    setState(() => _isSaving = true);

    try {
      // الحركة اللي انعدّلت فعلًا (للتراجع)
      TransactionModel? edited;
      if (widget.existing != null) {
        final tx = widget.existing!;
        final before = TxEditSnapshot.of(tx);
        tx.beneficiary = _beneficiaryController.text.trim();
        tx.amount = amount1;
        tx.secondAmount = secondAmount;
        tx.currency = _selectedCurrency!;
        tx.secondCurrency = secondAmount != null
            ? _selectedSecondCurrency
            : null;
        tx.date = _date;
        if (widget.account.type.isCompany) {
          tx.companyMovementType = _companyMovement;
          tx.destination = _destination;
        }
        await tx.save();
        if (!before.sameAs(TxEditSnapshot.of(tx))) {
          await TxUndo.rememberEdit(tx.id, before);
          edited = tx;
        }
      } else {
        final tx = TransactionModel(
          id: DatabaseService.newTransactionId(),
          accountId: widget.account.id,
          beneficiary: _beneficiaryController.text.trim(),
          amount: amount1,
          secondAmount: secondAmount,
          currency: _selectedCurrency!,
          secondCurrency: secondAmount != null ? _selectedSecondCurrency : null,
          notes: '',
          status: TransactionStatus.added,
          date: _date,
          companyMovementType: widget.account.type.isCompany
              ? _companyMovement
              : null,
          destination: widget.account.type.isCompany ? _destination : null,
        );

        await DatabaseService.addTransaction(tx);
      }

      if (!mounted) return;

      final messenger = ScaffoldMessenger.of(context);
      if (edited != null) {
        final tx = edited;
        AppMessages.showWithUndo(messenger, 'تم حفظ التعديل', () async {
          final ok = await TxUndo.undoEdit(tx);
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  ok ? 'تم التراجع عن التعديل' : 'تعذّر التراجع عن التعديل',
                ),
              ),
            );
        });
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('تم الحفظ بنجاح ✅')),
        );
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذّر الحفظ: $e')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Widget _buildCompanyMovementSelector() {
    if (!widget.account.type.isCompany) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: _isDark ? .16 : .06),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Colors.deepPurple.withValues(alpha: _isDark ? .45 : .2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'نوع حركة الشركة',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          Row(
            children: [CompanyMovementType.sent, CompanyMovementType.received]
                .map((type) {
                  final selected = _companyMovement.isSent == type.isSent;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(
                        end: type == CompanyMovementType.sent ? 8 : 0,
                      ),
                      child: ChoiceChip(
                        selected: selected,
                        label: Text(type.label),
                        avatar: Icon(
                          type.isSent
                              ? Icons.call_made_rounded
                              : Icons.call_received_rounded,
                          color: selected
                              ? (_isDark
                                    ? Colors.deepPurple.shade200
                                    : Colors.deepPurple)
                              : null,
                        ),
                        onSelected: (_) =>
                            setState(() => _companyMovement = type),
                        selectedColor: Colors.deepPurple.withValues(
                          alpha: _isDark ? .35 : .14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                    ),
                  );
                })
                .toList(),
          ),
          _buildDestinationPicker(),
        ],
      ),
    );
  }

  Widget _buildRawInputCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: _shadowColor,
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.text_fields_rounded),
              SizedBox(width: 8),
              Text(
                'النص',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rawController,
            minLines: 4,
            maxLines: 7,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              filled: true,
              fillColor: _fieldFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: _fieldBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: _fieldBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: _focusBorder, width: 1.4),
              ),
              suffixIcon: _rawController.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'مسح النص',
                      onPressed: () {
                        _rawController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextFieldCard({
    required String title,
    required IconData icon,
    required TextEditingController controller,
    String? hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _softBorder),
        boxShadow: [
          BoxShadow(
            color: _shadowColor,
            blurRadius: 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            decoration: _fieldDecoration(hintText: hint),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrencyDropdown({
    required String label,
    required String? value,
    required ValueChanged<String?> onChanged,
    required bool noCurrencies,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: _shadowColor,
            blurRadius: 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: DropdownButtonFormField<String>(
        value: value,
        items: _currencies
            .map((c) => DropdownMenuItem<String>(value: c, child: Text(c)))
            .toList(),
        onChanged: noCurrencies ? null : onChanged,
        dropdownColor: _isDark ? _cs.surfaceContainerHigh : null,
        decoration: _fieldDecoration(labelText: label),
      ),
    );
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  /// تاريخ ووقت الحركة
  Future<void> _pickDateTime() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (!mounted) return;
    final t = time ?? TimeOfDay.fromDateTime(_date);
    setState(() {
      _date = DateTime(day.year, day.month, day.day, t.hour, t.minute);
    });
  }

  Widget _buildDateTimeCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: _shadowColor,
            blurRadius: 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _pickDateTime,
        child: Row(
          children: [
            _miniInfoChip(
              Icons.calendar_month_rounded,
              'التاريخ',
              '${_date.year}/${_two(_date.month)}/${_two(_date.day)}',
            ),
            const SizedBox(width: 10),
            _miniInfoChip(
              Icons.access_time_rounded,
              'الوقت',
              '${_two(_date.hour)}:${_two(_date.minute)}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniInfoChip(IconData icon, String title, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: _fieldFill,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _softBorder),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: _isDark ? _cs.primary : Colors.indigo.shade400,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: _isDark
                          ? _cs.onSurfaceVariant
                          : Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton(bool isEdit) {
    return AnimatedScale(
      scale: _isSaving ? 0.98 : 1,
      duration: const Duration(milliseconds: 180),
      child: SizedBox(
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: _isSaving
                  ? (_isDark
                        ? [Colors.grey.shade700, Colors.grey.shade800]
                        : [Colors.grey.shade400, Colors.grey.shade500])
                  : [Colors.indigo.shade500, Colors.blue.shade600],
              begin: Alignment.centerRight,
              end: Alignment.centerLeft,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.indigo.withValues(alpha: _isDark ? 0.35 : 0.22),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ElevatedButton.icon(
            onPressed: _isSaving ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              disabledBackgroundColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.save_rounded, color: Colors.white),
            label: Text(
              _isSaving
                  ? 'جارٍ الحفظ...'
                  : (isEdit ? 'تحديث الحركة' : 'حفظ الحركة'),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final noCurrencies = _currencies.isEmpty;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _isDark ? null : const Color(0xFFF6F8FC),
        appBar: AppBar(
          elevation: 0,
          centerTitle: true,
          backgroundColor: Colors.transparent,
          foregroundColor: _cs.onSurface,
          title: Text(isEdit ? 'تعديل الحركة' : 'إضافة حركة'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _buildCompanyMovementSelector(),
            if (widget.account.type.isCompany) const SizedBox(height: 16),
            _buildRawInputCard(),
            const SizedBox(height: 16),

            if (noCurrencies)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: _isDark
                      ? Colors.amber.withValues(alpha: .12)
                      : Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: _isDark
                        ? Colors.amber.withValues(alpha: .40)
                        : Colors.amber.shade200,
                  ),
                ),
                child: ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text(
                    'لا توجد عملات مُعرّفة بعد',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );

                      setState(() {
                        _loadCurrencies();
                      });
                    },
                    child: const Text('فتح الإعدادات'),
                  ),
                ),
              ),

            _buildTextFieldCard(
              title: 'اسم المستفيد',
              icon: Icons.person_rounded,
              controller: _beneficiaryController,
            ),
            const SizedBox(height: 16),

            _buildTextFieldCard(
              title: 'المبلغ الأول',
              icon: Icons.payments_rounded,
              controller: _amountController,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d٠-٩۰-۹]')),
                DotThousandsInputFormatter(),
              ],
            ),
            const SizedBox(height: 12),

            _buildCurrencyDropdown(
              label: 'عملة المبلغ الأول',
              value: _selectedCurrency,
              onChanged: (v) => setState(() => _selectedCurrency = v),
              noCurrencies: noCurrencies,
            ),

            const SizedBox(height: 16),

            _buildTextFieldCard(
              title: 'المبلغ الثاني',
              icon: Icons.account_balance_wallet_rounded,
              controller: _secondAmountController,
              hint: 'اختياري',
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d٠-٩۰-۹]')),
                DotThousandsInputFormatter(),
              ],
            ),
            const SizedBox(height: 12),

            _buildCurrencyDropdown(
              label: 'عملة المبلغ الثاني',
              value: _selectedSecondCurrency,
              onChanged: (v) => setState(() => _selectedSecondCurrency = v),
              noCurrencies: noCurrencies,
            ),

            const SizedBox(height: 16),
            _buildDateTimeCard(),
            const SizedBox(height: 20),
            _buildSaveButton(isEdit),
          ],
        ),
      ),
    );
  }
}

class DotThousandsInputFormatter extends TextInputFormatter {
  const DotThousandsInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = _toEnglishDigits(newValue.text);
    final digitsOnly = raw.replaceAll(RegExp(r'[^\d]'), '');

    if (digitsOnly.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    final formatted = _formatThousands(digitsOnly);

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  static String _toEnglishDigits(String input) {
    const arabicIndic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const easternArabicIndic = [
      '۰',
      '۱',
      '۲',
      '۳',
      '۴',
      '۵',
      '۶',
      '۷',
      '۸',
      '۹',
    ];

    var result = input;
    for (int i = 0; i < 10; i++) {
      result = result.replaceAll(arabicIndic[i], '$i');
      result = result.replaceAll(easternArabicIndic[i], '$i');
    }
    return result;
  }

  static String _formatThousands(String digitsOnly) {
    final chars = digitsOnly.split('');
    final buffer = StringBuffer();

    for (int i = 0; i < chars.length; i++) {
      final indexFromEnd = chars.length - i;
      buffer.write(chars[i]);
      if (indexFromEnd > 1 && indexFromEnd % 3 == 1) {
        buffer.write('.');
      }
    }

    return buffer.toString();
  }
}
