import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database_service.dart';
import '../models.dart';
import '../services/operation_log_service.dart';
import '../services/tx_history_service.dart';
import 'settings_screen.dart';
import 'transaction_history_screen.dart';

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

  final Map<String, List<String>> _undoStacks = {
    'beneficiary': <String>[],
    'amount1': <String>[],
    'amount2': <String>[],
  };

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
  }

  List<String> get _draggableParts {
    final source = _rawController.text.trim();
    if (source.isEmpty) return const [];

    final result = <String>[];
    final seen = <String>{};

    void addPart(String value) {
      var cleaned = value.trim();
      if (cleaned.isEmpty) return;

      cleaned = cleaned
          .replaceAll(RegExp(r'^[\s\-\–\—\•\.\,\،\;\؛\:]+'), '')
          .replaceAll(RegExp(r'[\s\-\–\—\•\.\,\،\;\؛\:]+$'), '');

      if (cleaned.isEmpty) return;
      if (seen.add(cleaned)) result.add(cleaned);
    }

    for (final line in source.split(RegExp(r'[\n\r]+'))) {
      addPart(line);
    }

    for (final chunk in source.split(RegExp(r'[،,؛;]+'))) {
      addPart(chunk);
    }

    for (final word in source.split(RegExp(r'\s+'))) {
      addPart(word);
    }

    return result.take(40).toList();
  }

  bool _canAcceptAmount(String? value) {
    return _extractDigitsOnly(value) != null;
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

  void _setControllerText(TextEditingController controller, String value) {
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _pushUndo(String key, String currentValue) {
    final stack = _undoStacks[key]!;
    if (stack.isEmpty || stack.last != currentValue) {
      stack.add(currentValue);
    }
    if (stack.length > 12) {
      stack.removeAt(0);
    }
  }

  void _undoField(String key, TextEditingController controller) {
    final stack = _undoStacks[key]!;
    if (stack.isEmpty) return;

    final previous = stack.removeLast();
    _setControllerText(controller, previous);

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم التراجع')));
  }

  void _applyDropToBeneficiary(String value) {
    _pushUndo('beneficiary', _beneficiaryController.text);
    _setControllerText(_beneficiaryController, value.trim());
    HapticFeedback.selectionClick();
  }

  void _applyDropToAmount(
    String value,
    TextEditingController controller,
    String undoKey,
  ) {
    final digits = _extractDigitsOnly(value);
    if (digits == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذا النص ليس مبلغًا صالحًا')),
      );
      return;
    }

    _pushUndo(undoKey, controller.text);
    _setControllerText(controller, _formatThousands(digits));
    HapticFeedback.selectionClick();
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
      if (widget.existing != null) {
        final tx = widget.existing!;
        final before = OperationLogService.snapshot(tx);
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
        }
        TxHistoryService.annotate([tx.id], 'تعديل يدوي');
        await tx.save();
        await OperationLogService.log(
          kind: OperationKind.manualEdit,
          title: 'تعديل حركة «${tx.beneficiary}» في «${widget.account.name}»',
          records: [
            OperationTxRecord(
              txId: tx.id,
              before: before,
              after: OperationLogService.snapshot(tx),
            ),
          ],
        );
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
        );

        await DatabaseService.addTransaction(tx);
        await OperationLogService.log(
          kind: OperationKind.manualAdd,
          title: 'إضافة حركة «${tx.beneficiary}» إلى «${widget.account.name}»',
          records: [
            OperationTxRecord(
              txId: tx.id,
              after: OperationLogService.snapshot(tx),
            ),
          ],
        );
      }

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم الحفظ بنجاح ✅')));
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

  Widget _buildHeader(bool isEdit) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [
            Colors.blue.shade700,
            Colors.indigo.shade500,
            Colors.purple.shade400,
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.indigo.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isEdit ? Icons.edit_rounded : Icons.add_circle_rounded,
            color: Colors.white,
            size: 32,
          ),
          const SizedBox(height: 10),
          Text(
            isEdit ? 'تعديل حركة' : 'إضافة حركة جديدة',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'ألصق النص في الأعلى ثم اسحب أي جزء إلى الاسم أو المبلغ. يوجد تراجع سريع عند الخطأ.',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
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
        ],
      ),
    );
  }

  Widget _buildRawInputCard() {
    final parts = _draggableParts;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
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
                'النص الخام',
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
              hintText:
                  'ألصق النص هنا...\nثم اسحب الكلمات أو السطور إلى الحقول أدناه',
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
          const SizedBox(height: 14),
          if (parts.isNotEmpty) ...[
            const Text(
              'عناصر قابلة للسحب',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: parts.map(_buildDraggableChip).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDraggableChip(String text) {
    final chip = Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: _isDark ? _cs.primaryContainer : Colors.blue.shade50,
        border: Border.all(
          color: _isDark
              ? _cs.primary.withValues(alpha: .35)
              : Colors.blue.shade100,
        ),
      ),
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: _isDark ? _cs.onPrimaryContainer : Colors.blueGrey.shade900,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return LongPressDraggable<String>(
      data: text,
      feedback: Material(
        color: Colors.transparent,
        child: Transform.scale(
          scale: 1.04,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: Colors.indigo.shade400,
              boxShadow: [
                BoxShadow(
                  color: Colors.indigo.withValues(alpha: 0.28),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: chip,
    );
  }

  Widget _buildDropTextField({
    required String title,
    required IconData icon,
    required TextEditingController controller,
    required String hint,
    required String undoKey,
    required void Function(String value) onAccept,
    bool Function(String? value)? canAccept,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return DragTarget<String>(
      onWillAccept: canAccept ?? (_) => true,
      onAccept: onAccept,
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isHovering
                ? (_isDark ? _cs.primaryContainer : Colors.blue.shade50)
                : _cardColor,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isHovering ? _focusBorder : _softBorder,
              width: isHovering ? 1.4 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isHovering
                    ? Colors.blue.withValues(alpha: 0.10)
                    : _shadowColor,
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
                  IconButton(
                    tooltip: 'تراجع',
                    onPressed: _undoStacks[undoKey]!.isEmpty
                        ? null
                        : () => setState(() => _undoField(undoKey, controller)),
                    icon: const Icon(Icons.undo_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                keyboardType: keyboardType,
                inputFormatters: inputFormatters,
                decoration: _fieldDecoration(hintText: hint),
              ),
              if (isHovering) ...[
                const SizedBox(height: 8),
                Text(
                  'أفلِت هنا للاستبدال',
                  style: TextStyle(
                    color: _focusBorder,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ],
          ),
        );
      },
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

  Widget _buildInfoCard() {
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
      child: Row(
        children: [
          _miniInfoChip(Icons.flag_rounded, 'الحالة', 'مضافة'),
          const SizedBox(width: 10),
          _miniInfoChip(
            Icons.calendar_month_rounded,
            'التاريخ',
            '${_date.year}/${_date.month.toString().padLeft(2, '0')}/${_date.day.toString().padLeft(2, '0')}',
          ),
        ],
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
          actions: [
            if (isEdit)
              IconButton(
                tooltip: 'سجل التعديلات',
                onPressed: () =>
                    openTransactionHistory(context, widget.existing!),
                icon: const Icon(Icons.history_rounded),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _buildHeader(isEdit),
            const SizedBox(height: 16),
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
                  subtitle: const Text(
                    'أضف العملات من الإعدادات حتى تظهر في هذه الشاشة.',
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

            _buildDropTextField(
              title: 'اسم المستفيد',
              icon: Icons.person_rounded,
              controller: _beneficiaryController,
              hint: 'اكتب الاسم أو اسحب النص إليه',
              undoKey: 'beneficiary',
              onAccept: (value) =>
                  setState(() => _applyDropToBeneficiary(value)),
            ),
            const SizedBox(height: 16),

            _buildDropTextField(
              title: 'المبلغ الأول',
              icon: Icons.payments_rounded,
              controller: _amountController,
              hint: 'اكتب المبلغ أو اسحب رقمًا صالحًا',
              undoKey: 'amount1',
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d٠-٩۰-۹]')),
                DotThousandsInputFormatter(),
              ],
              canAccept: _canAcceptAmount,
              onAccept: (value) => setState(() {
                _applyDropToAmount(value, _amountController, 'amount1');
              }),
            ),
            const SizedBox(height: 12),

            _buildCurrencyDropdown(
              label: 'عملة المبلغ الأول',
              value: _selectedCurrency,
              onChanged: (v) => setState(() => _selectedCurrency = v),
              noCurrencies: noCurrencies,
            ),

            const SizedBox(height: 16),

            _buildDropTextField(
              title: 'المبلغ الثاني',
              icon: Icons.account_balance_wallet_rounded,
              controller: _secondAmountController,
              hint: 'اختياري',
              undoKey: 'amount2',
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d٠-٩۰-۹]')),
                DotThousandsInputFormatter(),
              ],
              canAccept: _canAcceptAmount,
              onAccept: (value) => setState(() {
                _applyDropToAmount(value, _secondAmountController, 'amount2');
              }),
            ),
            const SizedBox(height: 12),

            _buildCurrencyDropdown(
              label: 'عملة المبلغ الثاني',
              value: _selectedSecondCurrency,
              onChanged: (v) => setState(() => _selectedSecondCurrency = v),
              noCurrencies: noCurrencies,
            ),

            const SizedBox(height: 16),
            _buildInfoCard(),
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
