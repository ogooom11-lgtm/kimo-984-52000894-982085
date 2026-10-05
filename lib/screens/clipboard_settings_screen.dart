// lib/screens/clipboard_settings_screen.dart
// -------------------------------------------------------------
// إعدادات «الحافظة» (الفقاعة العائمة فوق التطبيقات):
//  • إظهار/إخفاء/فتح الحافظة، وإذن «الظهور فوق التطبيقات».
//  • زر «الحافظة» بلوحة الإعدادات السريعة (الستارة): إضافته بضغطة على
//    أندرويد 13+، وشرح الطريقة على الأقدم.
//  • شكل الفقاعة (الحجم، اللون، الوضوح)، اللوحة (المظهر، الخط، المكان،
//    الاسم)، الأنواع (أسماؤها وإخفاؤها)، والسلوك (الضغطة المطوّلة، النسخ...).
// كل تغيير بيوصل للفقاعة فورًا.
// -------------------------------------------------------------

import 'dart:async';

import 'package:floating_notes/floating_notes.dart';
import 'package:flutter/material.dart';

class ClipboardSettingsScreen extends StatefulWidget {
  const ClipboardSettingsScreen({super.key});

  @override
  State<ClipboardSettingsScreen> createState() =>
      _ClipboardSettingsScreenState();
}

class _ClipboardSettingsScreenState extends State<ClipboardSettingsScreen>
    with WidgetsBindingObserver {
  FloatingNotesPrefs _prefs = const FloatingNotesPrefs();
  bool _loaded = false;
  bool _showing = false;
  bool _canDraw = true;
  bool _canRequestTile = false;
  int _pending = 0;
  int _done = 0;
  StreamSubscription<String>? _sub;
  Timer? _saveTimer;
  final _titleCtrl = TextEditingController();
  final Map<FloatingNoteType, TextEditingController> _labelCtrls = {
    for (final t in FloatingNoteType.values) t: TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = FloatingNotes.changes.listen((e) {
      if (e == 'prefs') {
        _loadPrefs(updateFields: false);
      } else {
        _loadState();
      }
    });
    _loadPrefs(updateFields: true);
    _loadState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _flushSave();
    _titleCtrl.dispose();
    for (final c in _labelCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadState();
  }

  Future<void> _loadPrefs({required bool updateFields}) async {
    final p = await FloatingNotes.getPrefs();
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _loaded = true;
      if (updateFields) {
        _titleCtrl.text = p.title;
        for (final t in FloatingNoteType.values) {
          _labelCtrls[t]!.text = p.labels[t] ?? '';
        }
      }
    });
  }

  Future<void> _loadState() async {
    final showing = await FloatingNotes.isShowing();
    final canDraw = await FloatingNotes.canDrawOverlays();
    final canTile = await FloatingNotes.canRequestTile();
    final notes = await FloatingNotes.getNotes();
    if (!mounted) return;
    setState(() {
      _showing = showing;
      _canDraw = canDraw;
      _canRequestTile = canTile;
      _done = notes.where((n) => n.done).length;
      _pending = notes.length - _done;
    });
  }

  void _set(FloatingNotesPrefs p, {bool debounce = false}) {
    setState(() => _prefs = p);
    _saveTimer?.cancel();
    if (debounce) {
      _saveTimer = Timer(const Duration(milliseconds: 500), _flushSave);
    } else {
      unawaited(FloatingNotes.setPrefs(p));
    }
  }

  void _flushSave() {
    final t = _saveTimer;
    if (t == null) return;
    t.cancel();
    _saveTimer = null;
    unawaited(FloatingNotes.setPrefs(_prefs));
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _show({bool open = false}) async {
    if (!await FloatingNotes.canDrawOverlays()) {
      await FloatingNotes.openPermissionSettings();
      return;
    }
    final ok = await FloatingNotes.show(openPanel: open);
    if (!ok) _snack('تعذّر إظهار الحافظة');
    await _loadState();
  }

  Future<void> _hide() async {
    await FloatingNotes.hide();
    await _loadState();
    _snack('انخفت الحافظة (ملاحظاتك محفوظة)');
  }

  Future<void> _requestTile() async {
    final r = await FloatingNotes.requestAddTile();
    if (!mounted) return;
    switch (r) {
      case FloatingTileResult.added:
        _snack('✓ انضاف زر «${_prefs.displayTitle}» للوحة الإشعارات');
      case FloatingTileResult.already:
        _snack('الزر مضاف من قبل — نزّل الستارة وبتلاقيه');
      case FloatingTileResult.notAdded:
        _snack('ما انضاف الزر');
      case FloatingTileResult.unsupported:
      case FloatingTileResult.error:
        _snack('ما قدرنا نضيفه تلقائيًا — اتبع الخطوات تحت');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: dark ? null : const Color(0xFFF6F8FC),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          title: Text(
            'إعدادات ${_prefs.displayTitle}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19),
          ),
        ),
        body: !FloatingNotes.isSupported
            ? _centerNote(
                context,
                Icons.phone_android_rounded,
                'الحافظة العائمة متوفرة على أندرويد بس.',
              )
            : !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  4,
                  16,
                  32 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  _heroCard(context),
                  if (!_canDraw) ...[
                    const SizedBox(height: 12),
                    _permissionCard(context),
                  ],
                  const SizedBox(height: 18),
                  _title(context, 'زر بلوحة الإشعارات'),
                  _tileCard(context),
                  const SizedBox(height: 18),
                  _title(context, 'شكل الفقاعة'),
                  _card(
                    context,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label(context, 'الحجم'),
                        _segmented(
                          const ['صغيرة', 'متوسطة', 'كبيرة'],
                          _prefs.bubbleSize,
                          (i) => _set(_prefs.copyWith(bubbleSize: i)),
                        ),
                        const SizedBox(height: 14),
                        _label(context, 'اللون'),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (
                              var i = 0;
                              i < FloatingNotesPrefs.palettes.length;
                              i++
                            )
                              _colorDot(context, i),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _label(
                          context,
                          'وضوحها وهي واقفة: ${_prefs.bubbleAlpha}%',
                        ),
                        Slider(
                          value: _prefs.bubbleAlpha.toDouble(),
                          min: 30,
                          max: 100,
                          divisions: 7,
                          label: '${_prefs.bubbleAlpha}%',
                          onChanged: (v) => setState(
                            () => _prefs = _prefs.copyWith(
                              bubbleAlpha: v.round(),
                            ),
                          ),
                          onChangeEnd: (v) =>
                              _set(_prefs.copyWith(bubbleAlpha: v.round())),
                        ),
                        _switch(
                          context,
                          'بتلزق بطرف الشاشة',
                          'بعد ما تسحبها بترجع لأقرب طرف',
                          _prefs.snapToEdge,
                          (v) => _set(_prefs.copyWith(snapToEdge: v)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  _title(context, 'اللوحة'),
                  _card(
                    context,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label(context, 'الاسم'),
                        TextField(
                          controller: _titleCtrl,
                          decoration: _input(
                            context,
                            hint: 'الحافظة',
                            icon: Icons.title_rounded,
                          ),
                          onChanged: (v) =>
                              _set(_prefs.copyWith(title: v), debounce: true),
                        ),
                        const SizedBox(height: 14),
                        _label(context, 'المظهر'),
                        _segmented(
                          const ['تلقائي', 'فاتح', 'داكن'],
                          _prefs.theme,
                          (i) => _set(_prefs.copyWith(theme: i)),
                        ),
                        const SizedBox(height: 14),
                        _label(context, 'حجم الخط'),
                        _segmented(
                          const ['صغير', 'عادي', 'كبير'],
                          _prefs.fontSize,
                          (i) => _set(_prefs.copyWith(fontSize: i)),
                        ),
                        const SizedBox(height: 14),
                        _label(context, 'مكان اللوحة'),
                        _segmented(
                          const ['فوق', 'بالنص', 'تحت'],
                          _prefs.panelPosition,
                          (i) => _set(_prefs.copyWith(panelPosition: i)),
                        ),
                        _switch(
                          context,
                          'إظهار وقت الملاحظة',
                          'جنب رقم الملاحظة ونوعها',
                          _prefs.showTime,
                          (v) => _set(_prefs.copyWith(showTime: v)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  _title(context, 'أنواع الملاحظات'),
                  _card(context, _typesEditor(context)),
                  const SizedBox(height: 18),
                  _title(context, 'السلوك'),
                  _card(
                    context,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label(context, 'ضغطة مطوّلة على الفقاعة'),
                        _segmented(
                          const ['فتح ولصق المنسوخ', 'إخفاء', 'ولا شي'],
                          _prefs.longPress,
                          (i) => _set(_prefs.copyWith(longPress: i)),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'فتح ولصق: انسخ أي نص (من واتساب مثلًا) وبعدين اضغط '
                          'مطوّل على الفقاعة — بتفتح اللوحة والنص ملصوق جاهز.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        _switch(
                          context,
                          'سكّر اللوحة بعد النسخ',
                          'بعد نسخ ملاحظة أو «نسخ الكل»',
                          _prefs.closeAfterCopy,
                          (v) => _set(_prefs.copyWith(closeAfterCopy: v)),
                        ),
                        _switch(
                          context,
                          'ترقيم «نسخ الكل»',
                          '1. … 2. … 3. …',
                          _prefs.copyNumbers,
                          (v) => _set(_prefs.copyWith(copyNumbers: v)),
                        ),
                        _switch(
                          context,
                          'نوع الملاحظة مع «نسخ الكل»',
                          'مثل: «إلغاء: النص»',
                          _prefs.copyTypes,
                          (v) => _set(_prefs.copyWith(copyTypes: v)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'كل التغييرات بتوصل للفقاعة فورًا. ومن جوّا اللوحة كمان في '
                    'زر ⚙ لأهم الإعدادات.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
      ),
    );
  }

  // ---------------------------------------------------------
  // البطاقات
  // ---------------------------------------------------------

  Widget _heroCard(BuildContext context) {
    final pal = FloatingNotesPrefs.palettes[_prefs.bubbleColor];
    final c1 = Color(pal[0]);
    final c2 = Color(pal[1]);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c1, c2],
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: c1.withValues(alpha: .28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Opacity(
                opacity: _prefs.bubbleAlpha / 100,
                child: Container(
                  width: const [44.0, 54.0, 64.0][_prefs.bubbleSize],
                  height: const [44.0, 54.0, 64.0][_prefs.bubbleSize],
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [c1, c2]),
                    border: Border.all(color: Colors.white, width: 2.5),
                  ),
                  child: const Icon(
                    Icons.sticky_note_2_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _prefs.displayTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_showing ? 'ظاهرة فوق التطبيقات' : 'مخفية'} • '
                      '${_pending == 0 ? 'فاضية' : '$_pending ملاحظة'}'
                      '${_done == 0 ? '' : ' • $_done منجزة'}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .9),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: c1,
                  ),
                  onPressed: () => _show(open: true),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('فتح الحافظة'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white70),
                  ),
                  onPressed: _showing ? _hide : () => _show(),
                  icon: Icon(
                    _showing
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                  label: Text(_showing ? 'إخفاء الفقاعة' : 'إظهار الفقاعة'),
                ),
              ),
            ],
          ),
          if (_done > 0) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () async {
                final n = await FloatingNotes.clearDone();
                await _loadState();
                if (mounted) _snack('انمسحت $n ملاحظة منجزة');
              },
              icon: const Icon(Icons.cleaning_services_rounded),
              label: const Text('مسح الملاحظات المنجزة'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _permissionCard(BuildContext context) {
    const c = Color(0xFFD97706);
    return _card(
      context,
      Row(
        children: [
          const Icon(Icons.layers_clear_rounded, color: c),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'لازم تسمح لـ «مدير الحسابات» بالظهور فوق التطبيقات حتى تبين '
              'الحافظة.',
              style: TextStyle(fontWeight: FontWeight.w700, height: 1.4),
            ),
          ),
          TextButton(
            onPressed: FloatingNotes.openPermissionSettings,
            child: const Text('السماح'),
          ),
        ],
      ),
      border: c.withValues(alpha: .4),
    );
  }

  Widget _tileCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget step(int n, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: cs.primary.withValues(alpha: .12),
            child: Text(
              '$n',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: cs.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
        ],
      ),
    );
    return _card(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.dashboard_customize_rounded,
                  color: cs.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'لما تنزّل الستارة (جنب البلوتوث والواي فاي والكشاف) بيطلع '
                  'زر «${_prefs.displayTitle}» — ضغطة عليه بتفتحها فوق أي تطبيق.',
                  style: const TextStyle(height: 1.45),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_canRequestTile)
            FilledButton.icon(
              onPressed: _requestTile,
              icon: const Icon(Icons.add_to_home_screen_rounded),
              label: const Text('إضافة الزر للوحة الإشعارات'),
            ),
          const SizedBox(height: 10),
          Text(
            _canRequestTile ? 'أو يدويًا:' : 'طريقة إضافته:',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          step(1, 'نزّل الستارة من فوق لتحت مرتين حتى تبين كل الأزرار.'),
          step(2, 'اضغط ✏️ (تعديل) أو ⋮ ← «تعديل الأزرار».'),
          step(
            3,
            'دوّر على «${_prefs.displayTitle}» واسحبه لفوق مع باقي الأزرار.',
          ),
        ],
      ),
    );
  }

  Widget _typesEditor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const colors = {
      FloatingNoteType.add: Color(0xFF1E88E5),
      FloatingNoteType.edit: Color(0xFFE08600),
      FloatingNoteType.cancel: Color(0xFFE53935),
      FloatingNoteType.deliver: Color(0xFF00A76F),
    };
    const icons = {
      FloatingNoteType.add: Icons.add_rounded,
      FloatingNoteType.edit: Icons.edit_rounded,
      FloatingNoteType.cancel: Icons.close_rounded,
      FloatingNoteType.deliver: Icons.check_rounded,
    };
    final visibleCount = FloatingNoteType.values
        .where((t) => !_prefs.hiddenTypes.contains(t))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'غيّر اسم أي نوع، أو اخفي الأنواع يلي ما بتستعملها من لوحة الإضافة '
          '(الملاحظات القديمة بتضل ظاهرة).',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.45,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        for (final t in FloatingNoteType.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: colors[t],
                  child: Icon(icons[t], size: 18, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _labelCtrls[t],
                    decoration: _input(context, hint: t.label),
                    onChanged: (v) => _set(
                      _prefs.copyWith(labels: {..._prefs.labels, t: v.trim()}),
                      debounce: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Switch(
                  value: !_prefs.hiddenTypes.contains(t),
                  onChanged: (v) {
                    if (!v && visibleCount <= 1) {
                      _snack('لازم يضل نوع واحد ظاهر على الأقل');
                      return;
                    }
                    final hidden = {..._prefs.hiddenTypes};
                    v ? hidden.remove(t) : hidden.add(t);
                    _set(_prefs.copyWith(hiddenTypes: hidden));
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------
  // عناصر صغيرة
  // ---------------------------------------------------------

  Widget _colorDot(BuildContext context, int i) {
    final pal = FloatingNotesPrefs.palettes[i];
    final selected = _prefs.bubbleColor == i;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => _set(_prefs.copyWith(bubbleColor: i)),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [Color(pal[0]), Color(pal[1])]),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: selected
            ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
            : null,
      ),
    );
  }

  Widget _segmented(List<String> labels, int selected, ValueChanged<int> pick) {
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (var i = 0; i < labels.length; i++)
          ButtonSegment(value: i, label: Text(labels[i])),
      ],
      selected: {selected.clamp(0, labels.length - 1)},
      onSelectionChanged: (s) => pick(s.first),
    );
  }

  Widget _switch(
    BuildContext context,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _title(BuildContext context, String text) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w900,
        fontSize: 14.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
  );

  Widget _card(BuildContext context, Widget child, {Color? border}) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? cs.surfaceContainer : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: border ?? cs.outlineVariant.withValues(alpha: .4),
        ),
      ),
      child: child,
    );
  }

  InputDecoration _input(BuildContext context, {String? hint, IconData? icon}) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      hintText: hint,
      isDense: true,
      prefixIcon: icon == null ? null : Icon(icon),
      filled: true,
      fillColor: cs.surfaceContainerHighest.withValues(alpha: .35),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _centerNote(BuildContext context, IconData icon, String text) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
