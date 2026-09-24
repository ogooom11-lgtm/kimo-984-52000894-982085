import 'package:flutter/material.dart';
import '../database_service.dart';
import '../models.dart';

class AddAccountScreen extends StatefulWidget {
  const AddAccountScreen({super.key});

  @override
  State<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends State<AddAccountScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;
  AccountType _accountType = AccountType.office;

  String _normalizeAccountName(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  bool _accountNameAlreadyExists(String name) {
    final normalizedName = _normalizeAccountName(name);

    return DatabaseService.accountsBox.values.any(
      (account) => _normalizeAccountName(account.name) == normalizedName,
    );
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("اكتب اسم الحساب")));
      return;
    }

    if (_accountNameAlreadyExists(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("يوجد حساب بهذا الاسم مسبقًا")),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final account = Account(
        id: DateTime.now().millisecondsSinceEpoch,
        name: name,
        type: _accountType,
      );
      await DatabaseService.addAccount(account);

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("تمت إضافة الحساب ✅")));

      // ارجع للصفحة السابقة بعد نجاح الحفظ
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("تعذّرت الإضافة: $e")));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _pageBackground(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? const Color(0xFF0F141B)
        : const Color(0xFFF6F7FB);
  }

  Color _cardColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? const Color(0xFF151B24)
        : Colors.white;
  }

  Color _softFill(BuildContext context, Color color) {
    final theme = Theme.of(context);
    return color.withOpacity(theme.brightness == Brightness.dark ? 0.20 : 0.10);
  }

  BoxDecoration _modernCardDecoration(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return BoxDecoration(
      color: _cardColor(context),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(
        color: scheme.outlineVariant.withOpacity(
          theme.brightness == Brightness.dark ? 0.22 : 0.32,
        ),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(
            theme.brightness == Brightness.dark ? 0.22 : 0.06,
          ),
          blurRadius: 28,
          offset: const Offset(0, 14),
        ),
      ],
    );
  }

  Widget _buildHero(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            scheme.primary,
            Color.lerp(scheme.primary, scheme.secondary, 0.55) ??
                scheme.primary,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.24),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.18),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.22)),
            ),
            child: const Icon(
              Icons.account_balance_wallet_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "إضافة حساب جديد",
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  "اكتب اسم الحساب ليظهر لاحقًا ضمن الحسابات والحركات.",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withOpacity(0.86),
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _modernCardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _softFill(context, scheme.primary),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  Icons.edit_note_rounded,
                  color: scheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "بيانات الحساب",
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'نوع الحساب',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: AccountType.values.map((type) {
              final selected = _accountType == type;
              final color = type.isCompany ? Colors.deepPurple : scheme.primary;
              return Expanded(
                child: Padding(
                  padding: EdgeInsetsDirectional.only(
                    end: type == AccountType.office ? 8 : 0,
                  ),
                  child: ChoiceChip(
                    selected: selected,
                    onSelected: (_) => setState(() => _accountType = type),
                    avatar: Icon(
                      type.isCompany
                          ? Icons.business_rounded
                          : Icons.storefront_rounded,
                      size: 19,
                      color: selected ? color : null,
                    ),
                    label: Text(type.label),
                    selectedColor: color.withOpacity(.14),
                    side: BorderSide(
                      color: selected ? color : scheme.outlineVariant,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: "اسم الحساب",
              hintText: "مثال: حساب محمد / حساب الشركة",
              prefixIcon: Icon(
                Icons.person_outline_rounded,
                color: scheme.primary,
              ),
              suffixIcon: _controller.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: "مسح",
                      onPressed: _saving
                          ? null
                          : () {
                              _controller.clear();
                              setState(() {});
                            },
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              fillColor: theme.brightness == Brightness.dark
                  ? const Color(0xFF101720)
                  : const Color(0xFFF2F4F8),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 16,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(
                  color: scheme.outlineVariant.withOpacity(0.35),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: scheme.primary, width: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _softFill(context, scheme.primary),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: scheme.primary.withOpacity(0.12)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  color: scheme.primary,
                  size: 21,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _accountType.isCompany
                        ? "حساب الشركة يميّز الحركات المرسلة والاستقبال تلقائيًا من أسماء المستخدمين في الإعدادات."
                        : "يفضّل اختيار اسم واضح ومختصر حتى يسهل تمييز الحساب داخل التطبيق.",
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.textTheme.bodyMedium?.color?.withOpacity(
                        0.78,
                      ),
                      height: 1.4,
                      fontWeight: FontWeight.w500,
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

  Widget _buildSaveButton(BuildContext context) {
    final canSave = !_saving && _controller.text.trim().isNotEmpty;

    return FilledButton.icon(
      onPressed: canSave ? _save : null,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: _saving
            ? const SizedBox(
                key: ValueKey('loader'),
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.check_circle_rounded, key: ValueKey('icon')),
      ),
      label: Text(_saving ? "جارٍ الحفظ..." : "حفظ الحساب"),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _pageBackground(context),
        appBar: AppBar(
          title: const Text("إضافة حساب"),
          centerTitle: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: _pageBackground(context),
          foregroundColor: scheme.onSurface,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHero(context),
                const SizedBox(height: 18),
                _buildInputCard(context),
              ],
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            decoration: BoxDecoration(
              color: _pageBackground(context).withOpacity(0.96),
              border: Border(
                top: BorderSide(color: scheme.outlineVariant.withOpacity(0.25)),
              ),
            ),
            child: _buildSaveButton(context),
          ),
        ),
      ),
    );
  }
}
