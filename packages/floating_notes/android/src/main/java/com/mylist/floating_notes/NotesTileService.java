package com.mylist.floating_notes;

import android.annotation.TargetApi;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/**
 * زر «الحافظة» بلوحة الإعدادات السريعة (لما تنزّل الستارة، جنب البلوتوث
 * والواي فاي والكشاف). الضغط عليه بيفتح الحافظة العائمة فوق أي تطبيق.
 * إذا الإذن «الظهور فوق التطبيقات» مو ممنوح بيفتح صفحة الإذن.
 */
@TargetApi(Build.VERSION_CODES.N)
public class NotesTileService extends TileService {

  /** يطلب من النظام تحديث شكل الزر (عدد الملاحظات/ظاهرة أو لا). */
  static void refresh(Context context) {
    if (context == null || Build.VERSION.SDK_INT < 24) {
      return;
    }
    try {
      TileService.requestListeningState(
          context, new ComponentName(context, NotesTileService.class));
    } catch (Exception ignored) {
      // الزر مو مضاف للوحة، أو النظام رافض: ما في مشكلة
    }
  }

  @Override
  public void onTileAdded() {
    super.onTileAdded();
    updateTile();
  }

  @Override
  public void onStartListening() {
    super.onStartListening();
    updateTile();
  }

  private void updateTile() {
    Tile tile = getQsTile();
    if (tile == null) {
      return;
    }
    boolean showing = FloatingNotesService.isRunning();
    int pending = NotesStore.pendingCount(this);
    tile.setLabel(NotesStore.title(this));
    tile.setState(showing ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
    String sub = pending == 0 ? "فاضية" : FloatingNotesService.countLabel(pending);
    if (Build.VERSION.SDK_INT >= 29) {
      tile.setSubtitle(sub);
    }
    tile.setContentDescription(NotesStore.title(this) + " • " + sub);
    tile.updateTile();
  }

  @Override
  public void onClick() {
    super.onClick();
    if (isLocked()) {
      unlockAndRun(
          new Runnable() {
            @Override
            public void run() {
              openNotes();
            }
          });
    } else {
      openNotes();
    }
  }

  /** يفتح الحافظة عبر صفحة شفافة قصيرة (حتى تتسكّر الستارة وتبين اللوحة). */
  private void openNotes() {
    Intent i = new Intent(this, NotesTileActivity.class);
    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
    try {
      if (Build.VERSION.SDK_INT >= 34) {
        PendingIntent pi =
            PendingIntent.getActivity(
                this, 7302, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        startActivityAndCollapse(pi);
      } else {
        startActivityAndCollapseCompat(i);
      }
    } catch (Exception e) {
      // احتياط: بعض الأجهزة بترفض، منحاول نفتح الخدمة مباشرة
      try {
        if (FloatingNotesService.canDraw(this)) {
          FloatingNotesService.start(this, FloatingNotesService.ACTION_OPEN);
        }
      } catch (Exception ignored) {
        // النظام ما سمح بتشغيلها من الخلفية
      }
    }
  }

  @SuppressWarnings("deprecation")
  private void startActivityAndCollapseCompat(Intent i) {
    startActivityAndCollapse(i);
  }
}
