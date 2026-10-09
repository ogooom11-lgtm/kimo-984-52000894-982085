// lib/services/app_lock.dart
// -------------------------------------------------------------
// قفل التطبيق من تاريخ معيّن.
//  • أول ما يوصل التاريخ (عند الفتح، أو الرجوع للتطبيق، أو والتطبيق مفتوح)
//    منسجّل إنه وصل بمكانين: صندوق Hive صغير + ملف بمجلد التطبيق.
//  • بعدها التطبيق بيضل مقفول حتى لو رجّعوا تاريخ الموبايل لورا (وحدة من
//    النسختين بتكفي، والناقصة بترجع تنكتب).
//  • ما في سيرفر: مسح بيانات التطبيق أو حذفه وتنزيله من جديد بيمسح العلامة.
// -------------------------------------------------------------

import 'dart:async';
import 'dart:io';

import 'package:hive/hive.dart';

class AppLock {
  AppLock._();

  /// من هاليوم وطالع التطبيق ما بيفتح (صفحة بيضا مع رسالة خطأ)
  static final DateTime lockDate = DateTime(2026, 10, 18);

  static const String boxName = 'app_meta';
  static const String _key = 'k';
  static const String _fileName = '.app_meta';

  /// الساعة (بتتبدّل بالتجربة بس)
  static DateTime Function() clock = DateTime.now;

  static Box<dynamic>? _box;
  static Directory? _dir;
  static bool _locked = false;

  /// التاريخ وصل حسب ساعة الموبايل هلق؟
  static bool get dateReached => !clock().isBefore(lockDate);

  /// مقفول؟ (التاريخ وصل هلق، أو انسجّل قبل إنه وصل)
  static bool get isLocked => _locked || dateReached;

  static File? get _markerFile =>
      _dir == null ? null : File('${_dir!.path}/$_fileName');

  /// بعد Hive.init: بيقرأ إذا انسجّل القفل قبل، وإذا التاريخ وصل بيسجّله.
  /// [dir] = مجلد ملفات التطبيق (مكان النسخة التانية). true = لازم يقفل.
  static Future<bool> init({Directory? dir}) async {
    _dir = dir;
    _locked = false;
    _box = await _openBox();

    var stored = false;
    try {
      stored = _box?.get(_key) != null;
    } catch (_) {}
    if (!stored) {
      try {
        stored = _markerFile?.existsSync() ?? false;
      } catch (_) {}
    }
    if (stored) _locked = true;

    // بيكتب الناقص من النسختين
    if (isLocked) await markLocked();
    return isLocked;
  }

  /// بيسجّل إنه التاريخ وصل (بالمكانين). ما بيرمي أخطاء.
  static Future<void> markLocked() async {
    _locked = true;
    final stamp = clock().millisecondsSinceEpoch;

    try {
      final box = _box;
      if (box != null && box.get(_key) == null) {
        await box.put(_key, stamp);
        await box.flush();
      }
    } catch (_) {}

    try {
      final file = _markerFile;
      if (file != null && !file.existsSync()) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('$stamp', flush: true);
      }
    } catch (_) {}
  }

  /// فحص سريع (عند الرجوع للتطبيق أو كل شوي). true = لازم يقفل.
  static bool check() {
    if (_locked) return true;
    if (!dateReached) return false;
    unawaited(markLocked());
    return true;
  }

  static Future<Box<dynamic>?> _openBox() async {
    try {
      return await Hive.openBox<dynamic>(boxName);
    } catch (_) {
      // الصندوق خربان: منعمل واحد جديد (النسخة التانية بالملف)
      try {
        await Hive.deleteBoxFromDisk(boxName);
        return await Hive.openBox<dynamic>(boxName);
      } catch (_) {
        return null;
      }
    }
  }
}
