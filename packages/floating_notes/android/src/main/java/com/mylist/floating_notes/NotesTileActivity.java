package com.mylist.floating_notes;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.widget.Toast;

/**
 * صفحة شفافة بتفتح من زر «الحافظة» بلوحة الإعدادات السريعة: بتشغّل
 * الحافظة العائمة (مع فتح اللوحة) وبتتسكّر فورًا. إذا إذن «الظهور فوق
 * التطبيقات» مو ممنوح بتفتح صفحة الإذن.
 */
public class NotesTileActivity extends Activity {
  private boolean handled = false;

  /** بعد ما تصير الصفحة ظاهرة (مسموح تشغيل الخدمة الأمامية). */
  @Override
  protected void onResume() {
    super.onResume();
    if (handled) {
      finish();
      return;
    }
    handled = true;
    try {
      if (FloatingNotesService.canDraw(this)) {
        FloatingNotesService.start(this, FloatingNotesService.ACTION_OPEN);
      } else {
        Toast.makeText(
                this,
                "فعّل «الظهور فوق التطبيقات» لـ «مدير الحسابات» حتى تفتح الحافظة",
                Toast.LENGTH_LONG)
            .show();
        Intent i =
            new Intent(
                Build.VERSION.SDK_INT >= 23
                    ? Settings.ACTION_MANAGE_OVERLAY_PERMISSION
                    : Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + getPackageName()));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(i);
      }
    } catch (Exception ignored) {
    }
    finish();
    noAnimation();
  }

  @SuppressWarnings("deprecation")
  private void noAnimation() {
    overridePendingTransition(0, 0);
  }
}
