package com.mylist.floating_notes;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.util.DisplayMetrics;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * «الحافظة»: خدمة أمامية تعرض فقاعة عائمة فوق كل التطبيقات:
 * - الفقاعة قابلة للسحب، وتلتصق بأقرب حافة وتتذكر مكانها. حجمها ولونها
 *   وشفافيتها قابلين للتخصيص، والضغطة المطوّلة عليها بتفتح الحافظة وبتلصق
 *   المنسوخ (أو بتخفيها — حسب الإعدادات).
 * - الضغط عليها يفتح لوحة: نوع الملاحظة، مربع نص مع زر لصق، قائمة الملاحظات
 *   بترتيب الإضافة مع فلترة حسب النوع، نسخ/تعديل/«تم»/حذف لكل ملاحظة،
 *   وصفحة إعدادات سريعة داخل اللوحة.
 * تبقى ظاهرة حتى لو خرج المستخدم من التطبيق، وتُفتح كمان من زر «الحافظة»
 * بلوحة الإعدادات السريعة (الستارة).
 */
public class FloatingNotesService extends Service implements NotesStore.Listener {
  static final String ACTION_SHOW = "com.mylist.floating_notes.SHOW";
  static final String ACTION_OPEN = "com.mylist.floating_notes.OPEN";
  static final String ACTION_HIDE = "com.mylist.floating_notes.HIDE";

  private static final String CHANNEL_ID = "floating_notes";
  private static final int NOTIFICATION_ID = 7301;
  /** ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE (أندرويد 14). */
  private static final int FGS_TYPE_SPECIAL_USE = 0x40000000;

  private static final int COLOR_ADD = 0xFF1E88E5;
  private static final int COLOR_EDIT = 0xFFE08600;
  private static final int COLOR_CANCEL = 0xFFE53935;
  private static final int COLOR_DELIVER = 0xFF00A76F;

  /** ألوان الفقاعة (بداية/نهاية التدرّج) — نفس الترتيب بـ Dart. */
  static final int[][] PALETTES = {
    {0xFF3F51B5, 0xFF26A69A},
    {0xFF1565C0, 0xFF00ACC1},
    {0xFF6A1B9A, 0xFFEC407A},
    {0xFFE65100, 0xFFFFB300},
    {0xFF2E7D32, 0xFF66BB6A},
    {0xFF263238, 0xFF607D8B},
    {0xFFC62828, 0xFFF06292},
  };

  private static final int[] BUBBLE_SIZES_DP = {44, 54, 64};
  private static final float[] FONT_SIZES_SP = {13.5f, 15f, 17f};

  private static volatile boolean running = false;

  static boolean isRunning() {
    return running;
  }

  static boolean canDraw(Context c) {
    return Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(c);
  }

  /** يشغّل الخدمة كخدمة أمامية مع [action]. */
  static void start(Context c, String action) {
    Intent i = new Intent(c, FloatingNotesService.class);
    i.setAction(action);
    if (Build.VERSION.SDK_INT >= 26) {
      c.startForegroundService(i);
    } else {
      c.startService(i);
    }
  }

  interface IntCallback {
    void onPick(int index);
  }

  private final Handler handler = new Handler(Looper.getMainLooper());
  private WindowManager wm;

  // الفقاعة
  private FrameLayout bubble;
  private TextView badge;
  private WindowManager.LayoutParams bubbleParams;
  private ValueAnimator snapAnimator;

  /** حجم/لون/وضوح الفقاعة المرسومة حاليًا (لإعادة رسمها بس إذا تغيّروا). */
  private String bubbleKey = "";

  // اللوحة
  private PanelRoot panel;
  private WindowManager.LayoutParams panelParams;
  private ScrollView card;
  private LinearLayout body;
  private EditText input;
  private TextView addButton;
  private TextView cancelEditButton;
  private TextView countView;
  private TextView clearButton;
  private TextView clearDoneButton;
  private TextView copyAllButton;
  private LinearLayout filterRow;
  private LinearLayout notesList;
  private final List<LinearLayout> typeChips = new ArrayList<LinearLayout>();

  // الحالة
  private String selectedType = NotesStore.TYPE_ADD;
  private String filterType = null;
  private long editingId = -1;
  private boolean showSettings = false;
  private boolean clearArmed = false;
  private boolean pendingPaste = false;
  private boolean dark = false;

  // الألوان
  private int cardColor;
  private int textColor;
  private int mutedColor;
  private int fieldColor;
  private int strokeColor;
  private int accent;

  private final Runnable disarmClear =
      new Runnable() {
        @Override
        public void run() {
          clearArmed = false;
          styleClearButton();
        }
      };

  private final Runnable resetCopyAll =
      new Runnable() {
        @Override
        public void run() {
          styleCopyAllButton();
        }
      };

  private final Runnable resetAddText =
      new Runnable() {
        @Override
        public void run() {
          styleAddButton();
        }
      };

  private final Runnable pasteFallback =
      new Runnable() {
        @Override
        public void run() {
          if (pendingPaste) {
            pendingPaste = false;
            pasteFromClipboard();
          }
        }
      };

  // ===========================================================
  // دورة الحياة
  // ===========================================================

  @Override
  public IBinder onBind(Intent intent) {
    return null;
  }

  @Override
  public void onCreate() {
    super.onCreate();
    wm = (WindowManager) getSystemService(WINDOW_SERVICE);
    startInForeground();
    running = true;
    NotesStore.addListener(this);
    FloatingNotesPlugin.notifyStateChanged();
    NotesTileService.refresh(this);
  }

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    String action = intent == null ? null : intent.getAction();
    if (ACTION_HIDE.equals(action) || !canDraw(this)) {
      stopSelf();
      return START_NOT_STICKY;
    }
    // كل startForegroundService يتطلب startForeground (حتى لو كانت الخدمة تعمل)
    startInForeground();
    showBubble();
    if (ACTION_OPEN.equals(action)) {
      showPanel();
    }
    return START_STICKY;
  }

  @Override
  public void onDestroy() {
    running = false;
    NotesStore.removeListener(this);
    handler.removeCallbacksAndMessages(null);
    if (snapAnimator != null) {
      snapAnimator.cancel();
    }
    removePanel();
    removeBubble();
    FloatingNotesPlugin.notifyStateChanged();
    NotesTileService.refresh(this);
    super.onDestroy();
  }

  @Override
  public void onConfigurationChanged(Configuration newConfig) {
    super.onConfigurationChanged(newConfig);
    if (bubble != null) {
      clampBubble();
      safeUpdate(bubble, bubbleParams);
    }
    if (panel != null) {
      refreshPanel();
    }
  }

  @Override
  public void onNotesChanged() {
    updateBadge();
    updateNotification();
    if (panel != null && !showSettings) {
      renderNotes();
    }
  }

  @Override
  public void onPrefsChanged() {
    if (!bubbleKey.equals(currentBubbleKey())) {
      rebuildBubble();
    }
    updateNotification();
    if (panel != null) {
      refreshPanel();
    }
  }

  // ===========================================================
  // الإشعار
  // ===========================================================

  private Notification buildNotification() {
    NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
    if (Build.VERSION.SDK_INT >= 26 && nm != null) {
      NotificationChannel channel =
          new NotificationChannel(CHANNEL_ID, "الحافظة العائمة", NotificationManager.IMPORTANCE_LOW);
      channel.setDescription("يظهر ما دامت فقاعة الحافظة على الشاشة");
      channel.setShowBadge(false);
      nm.createNotificationChannel(channel);
    }
    Notification.Builder b =
        Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL_ID)
            : legacyBuilder();
    int pending = NotesStore.pendingCount(this);
    b.setSmallIcon(R.drawable.ic_floating_notes_tile)
        .setContentTitle(NotesStore.title(this))
        .setContentText(
            pending == 0 ? "اضغط لفتح الحافظة" : countLabel(pending) + " • اضغط للفتح")
        .setOngoing(true)
        .setShowWhen(false)
        .setContentIntent(servicePending(ACTION_OPEN, 1));
    addHideAction(b);
    return b.build();
  }

  @SuppressWarnings("deprecation")
  private Notification.Builder legacyBuilder() {
    return new Notification.Builder(this);
  }

  @SuppressWarnings("deprecation")
  private void addHideAction(Notification.Builder b) {
    b.addAction(
        android.R.drawable.ic_menu_close_clear_cancel,
        "إخفاء الفقاعة",
        servicePending(ACTION_HIDE, 2));
  }

  private void startInForeground() {
    Notification n = buildNotification();
    if (Build.VERSION.SDK_INT >= 34) {
      startForeground(NOTIFICATION_ID, n, FGS_TYPE_SPECIAL_USE);
    } else {
      startForeground(NOTIFICATION_ID, n);
    }
  }

  private void updateNotification() {
    if (!running) {
      return;
    }
    try {
      NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
      if (nm != null) {
        nm.notify(NOTIFICATION_ID, buildNotification());
      }
    } catch (Exception ignored) {
    }
  }

  private PendingIntent servicePending(String action, int requestCode) {
    Intent i = new Intent(this, FloatingNotesService.class);
    i.setAction(action);
    int flags = PendingIntent.FLAG_UPDATE_CURRENT;
    if (Build.VERSION.SDK_INT >= 23) {
      flags |= PendingIntent.FLAG_IMMUTABLE;
    }
    return PendingIntent.getService(this, requestCode, i, flags);
  }

  // ===========================================================
  // الفقاعة
  // ===========================================================

  @SuppressWarnings("deprecation")
  private static int overlayType() {
    return Build.VERSION.SDK_INT >= 26
        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        : WindowManager.LayoutParams.TYPE_PHONE;
  }

  private int dp(float v) {
    return Math.round(
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
  }

  private int[] palette() {
    return PALETTES[NotesStore.bubbleColor(this) % PALETTES.length];
  }

  private float idleAlpha() {
    return NotesStore.bubbleAlpha(this) / 100f;
  }

  private String currentBubbleKey() {
    return NotesStore.bubbleSize(this)
        + ":"
        + NotesStore.bubbleColor(this)
        + ":"
        + NotesStore.bubbleAlpha(this);
  }

  private void showBubble() {
    if (bubble != null) {
      return;
    }
    int circle = dp(BUBBLE_SIZES_DP[NotesStore.bubbleSize(this)]);
    int pad = dp(7);
    int[] colors = palette();
    bubbleKey = currentBubbleKey();
    bubble = new FrameLayout(this);
    bubble.setPadding(pad, pad, pad, pad);
    bubble.setClipToPadding(false);
    bubble.setClipChildren(false);

    View disk = new View(this);
    GradientDrawable bg = new GradientDrawable(GradientDrawable.Orientation.TL_BR, colors);
    bg.setShape(GradientDrawable.OVAL);
    bg.setStroke(dp(2.5f), Color.WHITE);
    disk.setBackground(bg);
    disk.setElevation(dp(6));
    bubble.addView(disk, new FrameLayout.LayoutParams(circle, circle, Gravity.CENTER));

    NoteIconView glyph = new NoteIconView(this, NoteIconView.GLYPH_NOTES, 0, Color.WHITE);
    glyph.setElevation(dp(6.5f));
    glyph.setContentDescription(NotesStore.title(this));
    bubble.addView(glyph, new FrameLayout.LayoutParams(circle, circle, Gravity.CENTER));

    badge = new TextView(this);
    badge.setTextColor(Color.WHITE);
    badge.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
    badge.setTypeface(Typeface.DEFAULT_BOLD);
    badge.setGravity(Gravity.CENTER);
    badge.setMinWidth(dp(20));
    badge.setPadding(dp(5), 0, dp(5), 0);
    badge.setBackground(rounded(COLOR_CANCEL, dp(10), dp(1.5f), Color.WHITE));
    badge.setElevation(dp(7));
    bubble.addView(
        badge,
        new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, dp(20), Gravity.TOP | Gravity.RIGHT));
    updateBadge();
    bubble.setAlpha(idleAlpha());

    bubbleParams =
        new WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT);
    bubbleParams.gravity = Gravity.TOP | Gravity.LEFT;
    DisplayMetrics dm = getResources().getDisplayMetrics();
    int[] pos =
        NotesStore.loadPosition(this, dm.widthPixels - circle - 2 * pad, dm.heightPixels / 3);
    bubbleParams.x = pos[0];
    bubbleParams.y = pos[1];
    clampBubble();
    bubble.setOnTouchListener(new BubbleTouch());
    try {
      wm.addView(bubble, bubbleParams);
    } catch (Exception e) {
      bubble = null;
      stopSelf();
    }
  }

  private void removeBubble() {
    if (bubble == null) {
      return;
    }
    try {
      wm.removeView(bubble);
    } catch (Exception ignored) {
    }
    bubble = null;
    badge = null;
  }

  /** بعد تغيير حجم/لون/شفافية الفقاعة (بنفس المكان). */
  private void rebuildBubble() {
    if (bubble == null) {
      return;
    }
    if (snapAnimator != null) {
      snapAnimator.cancel();
    }
    if (bubbleParams != null) {
      NotesStore.savePosition(this, bubbleParams.x, bubbleParams.y);
    }
    removeBubble();
    showBubble();
  }

  private void updateBadge() {
    if (badge == null) {
      return;
    }
    int n = NotesStore.pendingCount(this);
    badge.setText(n > 99 ? "99+" : String.valueOf(n));
    badge.setVisibility(n > 0 ? View.VISIBLE : View.GONE);
  }

  private int bubbleSize() {
    return bubble != null && bubble.getWidth() > 0
        ? bubble.getWidth()
        : dp(BUBBLE_SIZES_DP[NotesStore.bubbleSize(this)] + 14);
  }

  private void clampBubble() {
    if (bubbleParams == null) {
      return;
    }
    DisplayMetrics dm = getResources().getDisplayMetrics();
    int size = bubbleSize();
    int maxX = Math.max(0, dm.widthPixels - size);
    int maxY = Math.max(0, dm.heightPixels - size);
    bubbleParams.x = Math.max(0, Math.min(bubbleParams.x, maxX));
    bubbleParams.y = Math.max(0, Math.min(bubbleParams.y, maxY));
  }

  private void safeUpdate(View v, WindowManager.LayoutParams p) {
    try {
      wm.updateViewLayout(v, p);
    } catch (Exception ignored) {
    }
  }

  /** تلتصق الفقاعة بأقرب حافة (يمين/يسار) بحركة ناعمة وتحفظ مكانها. */
  private void snapToEdge() {
    if (!NotesStore.snapToEdge(this)) {
      NotesStore.savePosition(this, bubbleParams.x, bubbleParams.y);
      return;
    }
    DisplayMetrics dm = getResources().getDisplayMetrics();
    int size = bubbleSize();
    int from = bubbleParams.x;
    int to = from + size / 2 < dm.widthPixels / 2 ? 0 : Math.max(0, dm.widthPixels - size);
    if (snapAnimator != null) {
      snapAnimator.cancel();
    }
    snapAnimator = ValueAnimator.ofInt(from, to);
    snapAnimator.setDuration(220);
    snapAnimator.addUpdateListener(
        new ValueAnimator.AnimatorUpdateListener() {
          @Override
          public void onAnimationUpdate(ValueAnimator animation) {
            if (bubble == null) {
              return;
            }
            bubbleParams.x = ((Integer) animation.getAnimatedValue()).intValue();
            safeUpdate(bubble, bubbleParams);
          }
        });
    snapAnimator.addListener(
        new AnimatorListenerAdapter() {
          @Override
          public void onAnimationEnd(Animator animation) {
            if (bubbleParams != null) {
              NotesStore.savePosition(FloatingNotesService.this, bubbleParams.x, bubbleParams.y);
            }
          }
        });
    snapAnimator.start();
  }

  private void onBubbleLongPress() {
    if (bubble != null) {
      bubble.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
    }
    int action = NotesStore.longPress(this);
    if (action == 1) {
      removePanel();
      stopSelf();
    } else if (action == 0) {
      // نقرأ الحافظة لما تاخد اللوحة التركيز (أندرويد بيمنع القراءة قبلها)
      pendingPaste = true;
      showSettings = false;
      if (panel == null) {
        showPanel();
      } else {
        refreshPanel();
      }
      handler.removeCallbacks(pasteFallback);
      handler.postDelayed(pasteFallback, 600);
    }
  }

  private class BubbleTouch implements View.OnTouchListener {
    private final int slop = ViewConfiguration.get(FloatingNotesService.this).getScaledTouchSlop();
    private int startX;
    private int startY;
    private float downX;
    private float downY;
    private boolean moved;
    private boolean longPressed;

    private final Runnable longPress =
        new Runnable() {
          @Override
          public void run() {
            if (!moved) {
              longPressed = true;
              onBubbleLongPress();
            }
          }
        };

    @Override
    public boolean onTouch(View v, MotionEvent e) {
      float dx = e.getRawX() - downX;
      float dy = e.getRawY() - downY;
      switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN:
          if (snapAnimator != null) {
            snapAnimator.cancel();
          }
          startX = bubbleParams.x;
          startY = bubbleParams.y;
          downX = e.getRawX();
          downY = e.getRawY();
          moved = false;
          longPressed = false;
          v.setAlpha(1f);
          v.animate().scaleX(0.9f).scaleY(0.9f).setDuration(90).start();
          if (NotesStore.longPress(FloatingNotesService.this) != 2) {
            handler.postDelayed(longPress, ViewConfiguration.getLongPressTimeout());
          }
          return true;
        case MotionEvent.ACTION_MOVE:
          if (!moved && (Math.abs(dx) > slop || Math.abs(dy) > slop)) {
            moved = true;
            handler.removeCallbacks(longPress);
          }
          if (moved && !longPressed) {
            bubbleParams.x = startX + Math.round(dx);
            bubbleParams.y = startY + Math.round(dy);
            clampBubble();
            safeUpdate(bubble, bubbleParams);
          }
          return true;
        case MotionEvent.ACTION_UP:
          handler.removeCallbacks(longPress);
          v.animate().scaleX(1f).scaleY(1f).setDuration(120).start();
          v.setAlpha(idleAlpha());
          if (longPressed) {
            return true;
          }
          if (moved) {
            snapToEdge();
          } else {
            togglePanel();
          }
          return true;
        case MotionEvent.ACTION_CANCEL:
          handler.removeCallbacks(longPress);
          v.animate().scaleX(1f).scaleY(1f).setDuration(120).start();
          v.setAlpha(idleAlpha());
          if (moved) {
            snapToEdge();
          }
          return true;
        default:
          return false;
      }
    }
  }

  // ===========================================================
  // اللوحة
  // ===========================================================

  /** جذر اللوحة: خلفية معتمة تغلق اللوحة عند لمسها، وزر الرجوع يغلقها. */
  private class PanelRoot extends FrameLayout {
    PanelRoot(Context context) {
      super(context);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
      if (event.getKeyCode() == KeyEvent.KEYCODE_BACK) {
        if (event.getAction() == KeyEvent.ACTION_UP) {
          if (showSettings) {
            showSettings = false;
            refreshPanel();
          } else {
            removePanel();
          }
        }
        return true;
      }
      return super.dispatchKeyEvent(event);
    }

    @Override
    public void onWindowFocusChanged(boolean hasWindowFocus) {
      super.onWindowFocusChanged(hasWindowFocus);
      if (hasWindowFocus && pendingPaste) {
        pendingPaste = false;
        handler.removeCallbacks(pasteFallback);
        handler.postDelayed(
            new Runnable() {
              @Override
              public void run() {
                pasteFromClipboard();
              }
            },
            80);
      }
    }
  }

  private void togglePanel() {
    if (panel != null) {
      removePanel();
    } else {
      showPanel();
    }
  }

  private boolean systemDark() {
    return (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
        == Configuration.UI_MODE_NIGHT_YES;
  }

  private void applyPalette() {
    int theme = NotesStore.theme(this);
    dark = theme == 2 || (theme == 0 && systemDark());
    cardColor = dark ? 0xFF1B2030 : 0xFFFFFFFF;
    textColor = dark ? 0xFFF1F5F9 : 0xFF1E293B;
    mutedColor = dark ? 0xFF94A3B8 : 0xFF64748B;
    fieldColor = dark ? 0xFF262C3D : 0xFFF1F5F9;
    strokeColor = dark ? 0xFF394155 : 0xFFE2E8F0;
    int[] pal = palette();
    accent = dark ? blend(pal[0], Color.WHITE, 0.25f) : pal[0];
  }

  private void showPanel() {
    if (panel != null) {
      return;
    }
    applyPalette();
    selectedType = NotesStore.lastType(this);
    if (NotesStore.isTypeHidden(this, selectedType)) {
      selectedType = NotesStore.visibleTypes(this).get(0);
    }

    panel = new PanelRoot(this);
    panel.setBackgroundColor(0x80000000);
    panel.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            removePanel();
          }
        });

    card = new ScrollView(this);
    card.setLayoutDirection(View.LAYOUT_DIRECTION_LTR);
    card.setElevation(dp(14));
    card.setClipToOutline(true);
    card.setClickable(true);
    card.setFillViewport(false);
    card.setVerticalScrollBarEnabled(false);
    panel.addView(card, cardParams());

    body = new LinearLayout(this);
    body.setOrientation(LinearLayout.VERTICAL);
    body.setPadding(dp(16), dp(14), dp(16), dp(16));
    card.addView(
        body,
        new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    card.setBackground(rounded(cardColor, dp(24), 0, 0));
    renderPanel();

    panelParams =
        new WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(),
            0,
            PixelFormat.TRANSLUCENT);
    panelParams.gravity = Gravity.TOP | Gravity.LEFT;
    panelParams.softInputMode = softInputMode();
    try {
      wm.addView(panel, panelParams);
    } catch (Exception e) {
      panel = null;
      return;
    }
    // ظهور ناعم
    int pos = NotesStore.panelPosition(this);
    card.setAlpha(0f);
    card.setTranslationY(dp(pos == 2 ? 18 : -14));
    card.animate().alpha(1f).translationY(0f).setDuration(190).start();
  }

  @SuppressWarnings("deprecation")
  private static int softInputMode() {
    return WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        | WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN;
  }

  private FrameLayout.LayoutParams cardParams() {
    DisplayMetrics dm = getResources().getDisplayMetrics();
    int cardWidth = Math.min(dm.widthPixels - dp(24), dp(480));
    int pos = NotesStore.panelPosition(this);
    int gravity =
        pos == 1
            ? Gravity.CENTER
            : (pos == 2
                ? Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL
                : Gravity.TOP | Gravity.CENTER_HORIZONTAL);
    FrameLayout.LayoutParams lp =
        new FrameLayout.LayoutParams(cardWidth, ViewGroup.LayoutParams.WRAP_CONTENT, gravity);
    lp.topMargin = dp(pos == 0 ? 36 : 20);
    lp.bottomMargin = dp(pos == 2 ? 28 : 20);
    return lp;
  }

  /** إعادة رسم اللوحة بنفس النافذة (بعد تغيير الإعدادات أو الوضع الليلي). */
  private void refreshPanel() {
    if (panel == null || card == null) {
      return;
    }
    String draft = input == null ? "" : String.valueOf(input.getText());
    applyPalette();
    card.setBackground(rounded(cardColor, dp(24), 0, 0));
    card.setLayoutParams(cardParams());
    renderPanel();
    if (input != null && draft.length() > 0) {
      input.setText(draft);
      input.setSelection(draft.length());
    }
  }

  private void renderPanel() {
    if (editingId < 0 && NotesStore.isTypeHidden(this, selectedType)) {
      selectedType = NotesStore.visibleTypes(this).get(0);
    }
    body.removeAllViews();
    typeChips.clear();
    input = null;
    addButton = null;
    cancelEditButton = null;
    countView = null;
    clearButton = null;
    clearDoneButton = null;
    copyAllButton = null;
    filterRow = null;
    notesList = null;
    body.addView(buildHeader());
    body.addView(spacer(12));
    if (showSettings) {
      body.addView(buildSettingsView());
      return;
    }
    body.addView(buildTypeRow());
    body.addView(spacer(10));
    body.addView(buildInputRow());
    body.addView(buildAddRow());
    body.addView(spacer(14));
    filterRow = new LinearLayout(this);
    filterRow.setOrientation(LinearLayout.HORIZONTAL);
    filterRow.setGravity(Gravity.CENTER_VERTICAL);
    HorizontalScrollView filterScroll = new HorizontalScrollView(this);
    filterScroll.setHorizontalScrollBarEnabled(false);
    filterScroll.addView(filterRow);
    LinearLayout.LayoutParams fLp = matchWrap();
    fLp.bottomMargin = dp(8);
    body.addView(filterScroll, fLp);
    body.addView(buildListHeader());
    notesList = new LinearLayout(this);
    notesList.setOrientation(LinearLayout.VERTICAL);
    body.addView(notesList, matchWrap());
    selectType(selectedType);
    renderNotes();
  }

  private void removePanel() {
    if (panel == null) {
      return;
    }
    handler.removeCallbacks(disarmClear);
    handler.removeCallbacks(resetAddText);
    handler.removeCallbacks(resetCopyAll);
    handler.removeCallbacks(pasteFallback);
    clearArmed = false;
    pendingPaste = false;
    editingId = -1;
    showSettings = false;
    hideKeyboard();
    try {
      wm.removeView(panel);
    } catch (Exception ignored) {
    }
    panel = null;
    card = null;
    body = null;
    notesList = null;
    input = null;
  }

  private void hideKeyboard() {
    if (input == null) {
      return;
    }
    InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
    if (imm != null) {
      imm.hideSoftInputFromWindow(input.getWindowToken(), 0);
    }
  }

  // عناصر اللوحة تُبنى من اليسار إلى اليمين بترتيب بصري ثابت (العربية على
  // اليمين) حتى لا تعتمد على دعم الاتجاه من اليمين لليسار في التطبيق.

  private View buildHeader() {
    LinearLayout row = hRow();

    NoteIconView close = new NoteIconView(this, NoteIconView.GLYPH_CLOSE, fieldColor, mutedColor);
    close.setContentDescription("إغلاق");
    close.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            removePanel();
          }
        });
    row.addView(close, new LinearLayout.LayoutParams(dp(34), dp(34)));

    NoteIconView settings =
        new NoteIconView(
            this,
            showSettings ? NoteIconView.GLYPH_UNDO : NoteIconView.GLYPH_SETTINGS,
            showSettings ? withAlpha(accent, dark ? 0x55 : 0x22) : fieldColor,
            showSettings ? accent : mutedColor);
    settings.setContentDescription(showSettings ? "رجوع" : "إعدادات الحافظة");
    settings.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            showSettings = !showSettings;
            hideKeyboard();
            refreshPanel();
          }
        });
    LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(dp(34), dp(34));
    sLp.leftMargin = dp(8);
    row.addView(settings, sLp);

    TextView hide = tv("إخفاء", 12.5f, mutedColor, true);
    hide.setGravity(Gravity.CENTER);
    hide.setPadding(dp(12), 0, dp(12), 0);
    hide.setBackground(rounded(fieldColor, dp(17), dp(1), strokeColor));
    hide.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            removePanel();
            stopSelf();
          }
        });
    LinearLayout.LayoutParams hideLp =
        new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(34));
    hideLp.leftMargin = dp(8);
    row.addView(hide, hideLp);

    LinearLayout titles = new LinearLayout(this);
    titles.setOrientation(LinearLayout.VERTICAL);
    TextView title =
        tv(showSettings ? "إعدادات " + NotesStore.title(this) : NotesStore.title(this), 18, textColor, true);
    title.setGravity(Gravity.RIGHT);
    title.setSingleLine(true);
    countView = tv("", 12.5f, mutedColor, false);
    countView.setGravity(Gravity.RIGHT);
    titles.addView(title, matchWrap());
    titles.addView(countView, matchWrap());
    if (showSettings) {
      countView.setText("بتنحفظ فورًا");
    }
    LinearLayout.LayoutParams tLp =
        new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    tLp.leftMargin = dp(8);
    tLp.rightMargin = dp(10);
    row.addView(titles, tLp);

    int[] pal = palette();
    FrameLayout iconWrap = new FrameLayout(this);
    GradientDrawable g = new GradientDrawable(GradientDrawable.Orientation.TL_BR, pal);
    g.setShape(GradientDrawable.OVAL);
    iconWrap.setBackground(g);
    NoteIconView icon = new NoteIconView(this, NoteIconView.GLYPH_NOTES, 0, Color.WHITE);
    iconWrap.addView(icon, new FrameLayout.LayoutParams(dp(40), dp(40), Gravity.CENTER));
    row.addView(iconWrap, new LinearLayout.LayoutParams(dp(40), dp(40)));
    return row;
  }

  private View buildTypeRow() {
    LinearLayout row = hRow();
    List<String> types = NotesStore.visibleTypes(this);
    for (int i = 0; i < types.size(); i++) {
      LinearLayout chip = typeChip(types.get(i));
      typeChips.add(chip);
      LinearLayout.LayoutParams lp =
          new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
      if (i > 0) {
        lp.leftMargin = dp(8);
      }
      row.addView(chip, lp);
    }
    return row;
  }

  private LinearLayout typeChip(final String type) {
    LinearLayout chip = new LinearLayout(this);
    chip.setOrientation(LinearLayout.VERTICAL);
    chip.setGravity(Gravity.CENTER);
    chip.setPadding(dp(4), dp(9), dp(4), dp(8));
    chip.setTag(type);
    NoteIconView icon = new NoteIconView(this, glyphFor(type), colorFor(type), Color.WHITE);
    chip.addView(icon, new LinearLayout.LayoutParams(dp(28), dp(28)));
    TextView label = tv(NotesStore.label(this, type), 12.5f, textColor, true);
    label.setGravity(Gravity.CENTER);
    label.setSingleLine(true);
    label.setPadding(0, dp(5), 0, 0);
    chip.addView(
        label,
        new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    chip.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            selectType(type);
          }
        });
    return chip;
  }

  private void selectType(String type) {
    selectedType = NotesStore.normalizeType(type);
    NotesStore.saveLastType(this, selectedType);
    for (int i = 0; i < typeChips.size(); i++) {
      LinearLayout chip = typeChips.get(i);
      String t = (String) chip.getTag();
      int c = colorFor(t);
      boolean sel = selectedType.equals(t);
      chip.setBackground(
          rounded(
              sel ? withAlpha(c, dark ? 0x44 : 0x1F) : fieldColor,
              dp(14),
              sel ? dp(2) : dp(1),
              sel ? c : strokeColor));
    }
    styleAddButton();
  }

  private View buildInputRow() {
    LinearLayout row = hRow();
    row.setGravity(Gravity.TOP);

    NoteIconView paste =
        new NoteIconView(this, NoteIconView.GLYPH_PASTE, withAlpha(accent, dark ? 0x40 : 0x1A), accent);
    paste.setContentDescription("لصق المنسوخ");
    paste.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            pasteFromClipboard();
          }
        });
    row.addView(paste, new LinearLayout.LayoutParams(dp(42), dp(42)));

    input = new EditText(this);
    input.setHint("اكتب الملاحظة أو الصق المنسوخ…");
    input.setHintTextColor(mutedColor);
    input.setTextColor(textColor);
    input.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSp());
    input.setGravity(Gravity.RIGHT | Gravity.TOP);
    input.setTextDirection(View.TEXT_DIRECTION_RTL);
    input.setMinLines(2);
    input.setMaxLines(6);
    input.setInputType(
        InputType.TYPE_CLASS_TEXT
            | InputType.TYPE_TEXT_FLAG_MULTI_LINE
            | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
    input.setPadding(dp(12), dp(10), dp(12), dp(10));
    input.setBackground(rounded(fieldColor, dp(14), dp(1), strokeColor));
    input.addTextChangedListener(
        new TextWatcher() {
          @Override
          public void beforeTextChanged(CharSequence s, int start, int count, int after) {}

          @Override
          public void onTextChanged(CharSequence s, int start, int before, int count) {}

          @Override
          public void afterTextChanged(Editable s) {
            handler.removeCallbacks(resetAddText);
            styleAddButton();
          }
        });
    LinearLayout.LayoutParams iLp =
        new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    iLp.leftMargin = dp(8);
    row.addView(input, iLp);
    return row;
  }

  private View buildAddRow() {
    LinearLayout row = hRow();
    LinearLayout.LayoutParams rowLp = matchWrap();
    rowLp.topMargin = dp(10);
    row.setLayoutParams(rowLp);

    cancelEditButton = tv("إلغاء التعديل", 13, mutedColor, true);
    cancelEditButton.setGravity(Gravity.CENTER);
    cancelEditButton.setPadding(dp(14), 0, dp(14), 0);
    cancelEditButton.setBackground(rounded(fieldColor, dp(14), dp(1), strokeColor));
    cancelEditButton.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            cancelEdit();
          }
        });
    LinearLayout.LayoutParams cLp =
        new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48));
    cLp.rightMargin = dp(8);
    row.addView(cancelEditButton, cLp);

    addButton = tv("", 15, Color.WHITE, true);
    addButton.setGravity(Gravity.CENTER);
    addButton.setSingleLine(true);
    addButton.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            submitNote();
          }
        });
    row.addView(addButton, new LinearLayout.LayoutParams(0, dp(48), 1f));
    styleAddButton();
    return row;
  }

  private void styleAddButton() {
    if (addButton == null || input == null) {
      return;
    }
    boolean enabled = String.valueOf(input.getText()).trim().length() > 0;
    int c = colorFor(selectedType);
    addButton.setEnabled(enabled);
    addButton.setText(
        editingId >= 0
            ? "حفظ التعديل"
            : "إضافة «" + NotesStore.label(this, selectedType) + "»");
    addButton.setBackground(rounded(enabled ? c : withAlpha(c, 0x66), dp(14), 0, 0));
    if (cancelEditButton != null) {
      cancelEditButton.setVisibility(editingId >= 0 ? View.VISIBLE : View.GONE);
    }
  }

  private void submitNote() {
    if (input == null) {
      return;
    }
    String text = String.valueOf(input.getText()).trim();
    if (text.length() == 0) {
      return;
    }
    boolean editing = editingId >= 0;
    if (editing) {
      NotesStore.update(this, editingId, text, selectedType);
      editingId = -1;
    } else {
      NotesStore.add(this, text, selectedType);
    }
    input.setText("");
    if (addButton != null) {
      addButton.setText(editing ? "✓ تم الحفظ" : "✓ تمت الإضافة");
      addButton.setBackground(rounded(colorFor(selectedType), dp(14), 0, 0));
    }
    if (cancelEditButton != null) {
      cancelEditButton.setVisibility(View.GONE);
    }
    handler.removeCallbacks(resetAddText);
    handler.postDelayed(resetAddText, 1300);
  }

  private void startEdit(long id, String text, String type) {
    editingId = id;
    selectType(type);
    if (input != null) {
      input.setText(text);
      input.setSelection(input.getText().length());
      input.requestFocus();
      InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
      if (imm != null) {
        imm.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT);
      }
    }
    styleAddButton();
    if (card != null) {
      card.smoothScrollTo(0, 0);
    }
  }

  private void cancelEdit() {
    editingId = -1;
    if (input != null) {
      input.setText("");
    }
    styleAddButton();
  }

  /** يلصق نص الحافظة بمربع الكتابة (لازم تكون اللوحة مفتوحة وإلها التركيز). */
  private void pasteFromClipboard() {
    if (input == null) {
      return;
    }
    String text = readClipboard();
    if (text == null || text.trim().length() == 0) {
      toast("ما في نص منسوخ — انسخ شي أول");
      return;
    }
    String current = String.valueOf(input.getText());
    String next = current.trim().length() == 0 ? text.trim() : current.trim() + "\n" + text.trim();
    input.setText(next);
    input.setSelection(input.getText().length());
    input.requestFocus();
  }

  private String readClipboard() {
    try {
      ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
      if (cm == null || !cm.hasPrimaryClip()) {
        return null;
      }
      ClipData clip = cm.getPrimaryClip();
      if (clip == null || clip.getItemCount() == 0) {
        return null;
      }
      CharSequence t = clip.getItemAt(0).coerceToText(this);
      return t == null ? null : t.toString();
    } catch (Exception e) {
      return null;
    }
  }

  private View buildListHeader() {
    LinearLayout row = hRow();
    clearButton = tv("", 12.5f, mutedColor, true);
    clearButton.setPadding(dp(6), dp(6), dp(6), dp(6));
    clearButton.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            if (!clearArmed) {
              clearArmed = true;
              styleClearButton();
              handler.removeCallbacks(disarmClear);
              handler.postDelayed(disarmClear, 3000);
              return;
            }
            clearArmed = false;
            handler.removeCallbacks(disarmClear);
            editingId = -1;
            NotesStore.clear(FloatingNotesService.this);
            styleClearButton();
          }
        });
    row.addView(clearButton, wrapWrap());

    clearDoneButton = tv("مسح المنجزة", 12.5f, COLOR_DELIVER, true);
    clearDoneButton.setPadding(dp(6), dp(6), dp(6), dp(6));
    clearDoneButton.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            int n = NotesStore.clearDone(FloatingNotesService.this);
            if (n > 0) {
              toast("انمسحت " + countLabel(n));
            }
          }
        });
    row.addView(clearDoneButton, wrapWrap());

    copyAllButton = tv("", 12.5f, accent, true);
    copyAllButton.setPadding(dp(6), dp(6), dp(6), dp(6));
    copyAllButton.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            copyAll();
          }
        });
    row.addView(copyAllButton, wrapWrap());

    TextView title = tv("الملاحظات", 14, textColor, true);
    title.setGravity(Gravity.RIGHT);
    row.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
    LinearLayout.LayoutParams lp = matchWrap();
    lp.bottomMargin = dp(6);
    row.setLayoutParams(lp);
    styleClearButton();
    styleCopyAllButton();
    return row;
  }

  private void styleCopyAllButton() {
    if (copyAllButton == null) {
      return;
    }
    copyAllButton.setText(filterType == null ? "نسخ الكل" : "نسخ المعروضة");
    copyAllButton.setTextColor(accent);
  }

  private void styleClearButton() {
    if (clearButton == null) {
      return;
    }
    clearButton.setText(clearArmed ? "اضغط مجددًا للتأكيد" : "مسح الكل");
    clearButton.setTextColor(clearArmed ? COLOR_CANCEL : mutedColor);
  }

  /** ينسخ الملاحظات المعروضة (يلي لسا ما انعلّمت «تم» إذا في منها). */
  private void copyAll() {
    JSONArray arr = NotesStore.load(this);
    List<JSONObject> shown = new ArrayList<JSONObject>();
    List<JSONObject> pending = new ArrayList<JSONObject>();
    for (int i = 0; i < arr.length(); i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null || o.optString("text").trim().length() == 0) {
        continue;
      }
      String type = NotesStore.normalizeType(o.optString("type"));
      if (filterType != null && !filterType.equals(type)) {
        continue;
      }
      shown.add(o);
      if (!o.optBoolean("done", false)) {
        pending.add(o);
      }
    }
    List<JSONObject> list = pending.isEmpty() ? shown : pending;
    if (list.isEmpty()) {
      return;
    }
    boolean numbers = NotesStore.copyNumbers(this);
    boolean types = NotesStore.copyTypes(this);
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < list.size(); i++) {
      JSONObject o = list.get(i);
      if (sb.length() > 0) {
        sb.append('\n');
      }
      if (numbers) {
        sb.append(i + 1).append(". ");
      }
      if (types) {
        sb.append(NotesStore.label(this, NotesStore.normalizeType(o.optString("type")))).append(": ");
      }
      sb.append(o.optString("text").trim());
    }
    if (copyText("notes", sb.toString(), "تم نسخ " + countLabel(list.size()))) {
      if (copyAllButton != null) {
        copyAllButton.setText("✓ تم النسخ");
        copyAllButton.setTextColor(COLOR_DELIVER);
      }
      handler.removeCallbacks(resetCopyAll);
      handler.postDelayed(resetCopyAll, 1500);
      closeAfterCopyIfNeeded();
    }
  }

  private void closeAfterCopyIfNeeded() {
    if (!NotesStore.closeAfterCopy(this)) {
      return;
    }
    handler.postDelayed(
        new Runnable() {
          @Override
          public void run() {
            removePanel();
          }
        },
        450);
  }

  /**
   * ينسخ النص إلى الحافظة. أندرويد 13 وما بعده يعرض تأكيد النسخ بنفسه، لذلك
   * لا نعرض رسالة إضافية هناك.
   */
  private boolean copyText(String label, String text, String toast) {
    try {
      ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
      if (cm == null) {
        return false;
      }
      cm.setPrimaryClip(ClipData.newPlainText(label, text));
    } catch (Exception e) {
      return false;
    }
    if (Build.VERSION.SDK_INT < 33) {
      toast(toast);
    }
    return true;
  }

  private void toast(String text) {
    try {
      Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    } catch (Exception ignored) {
    }
  }

  /** أيقونة النسخ تتحول لعلامة ✓ خضراء لحظة ثم تعود. */
  private void flashCopied(final NoteIconView icon) {
    icon.setGlyph(NoteIconView.GLYPH_DELIVER);
    icon.setColors(0, COLOR_DELIVER);
    handler.postDelayed(
        new Runnable() {
          @Override
          public void run() {
            icon.setGlyph(NoteIconView.GLYPH_COPY);
            icon.setColors(0, mutedColor);
          }
        },
        1200);
  }

  private void renderFilters(JSONArray arr) {
    if (filterRow == null) {
      return;
    }
    filterRow.removeAllViews();
    int total = arr.length();
    if (total == 0) {
      filterType = null;
      ((View) filterRow.getParent()).setVisibility(View.GONE);
      return;
    }
    int[] counts = new int[NotesStore.ALL_TYPES.length];
    for (int i = 0; i < total; i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null) {
        continue;
      }
      String type = NotesStore.normalizeType(o.optString("type"));
      for (int k = 0; k < NotesStore.ALL_TYPES.length; k++) {
        if (NotesStore.ALL_TYPES[k].equals(type)) {
          counts[k]++;
        }
      }
    }
    int kinds = 0;
    for (int k = 0; k < counts.length; k++) {
      if (counts[k] > 0) {
        kinds++;
      }
    }
    if (filterType != null) {
      int idx = -1;
      for (int k = 0; k < NotesStore.ALL_TYPES.length; k++) {
        if (NotesStore.ALL_TYPES[k].equals(filterType)) {
          idx = k;
        }
      }
      if (idx < 0 || counts[idx] == 0) {
        filterType = null;
      }
    }
    // نوع واحد بس: ما في داعي للفلترة
    ((View) filterRow.getParent()).setVisibility(kinds > 1 ? View.VISIBLE : View.GONE);
    if (kinds <= 1) {
      filterType = null;
      return;
    }
    // من اليسار لليمين: الأنواع ثم «الكل» (على اليمين)
    for (int k = 0; k < NotesStore.ALL_TYPES.length; k++) {
      if (counts[k] == 0) {
        continue;
      }
      String type = NotesStore.ALL_TYPES[k];
      filterRow.addView(
          filterChip(NotesStore.label(this, type) + " " + counts[k], type, colorFor(type)));
    }
    filterRow.addView(filterChip("الكل " + total, null, accent));
  }

  private View filterChip(String text, final String type, int color) {
    boolean sel = type == null ? filterType == null : type.equals(filterType);
    TextView chip = tv(text, 12.5f, sel ? Color.WHITE : textColor, true);
    chip.setGravity(Gravity.CENTER);
    chip.setPadding(dp(12), dp(6), dp(12), dp(6));
    chip.setBackground(rounded(sel ? color : fieldColor, dp(14), sel ? 0 : dp(1), strokeColor));
    chip.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            filterType = type;
            styleCopyAllButton();
            renderNotes();
          }
        });
    LinearLayout.LayoutParams lp =
        new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    lp.leftMargin = dp(6);
    chip.setLayoutParams(lp);
    return chip;
  }

  private void renderNotes() {
    if (notesList == null) {
      return;
    }
    notesList.removeAllViews();
    JSONArray arr = NotesStore.load(this);
    renderFilters(arr);
    int n = arr.length();
    int pending = 0;
    int done = 0;
    for (int i = 0; i < n; i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null) {
        continue;
      }
      if (o.optBoolean("done", false)) {
        done++;
      } else {
        pending++;
      }
    }
    if (countView != null) {
      countView.setText(
          n == 0
              ? "لا توجد ملاحظات"
              : (done == 0 ? countLabel(n) : countLabel(pending) + " • " + done + " منجزة"));
    }
    if (clearButton != null) {
      clearButton.setVisibility(n > 0 ? View.VISIBLE : View.GONE);
    }
    if (clearDoneButton != null) {
      clearDoneButton.setVisibility(done > 0 ? View.VISIBLE : View.GONE);
    }
    if (copyAllButton != null) {
      copyAllButton.setVisibility(n > 0 ? View.VISIBLE : View.GONE);
    }
    styleCopyAllButton();
    if (n == 0) {
      TextView empty =
          tv(
              "الحافظة فاضية.\nاكتب ملاحظة أو اضغط 📋 لتلصق المنسوخ، ثم «إضافة».",
              13,
              mutedColor,
              false);
      empty.setGravity(Gravity.CENTER);
      empty.setPadding(dp(8), dp(18), dp(8), dp(12));
      notesList.addView(empty, matchWrap());
      return;
    }
    for (int i = 0; i < n; i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null) {
        continue;
      }
      String type = NotesStore.normalizeType(o.optString("type"));
      if (filterType != null && !filterType.equals(type)) {
        continue;
      }
      notesList.addView(noteRow(o, i + 1));
    }
  }

  private NoteIconView smallAction(int glyph, String description, View.OnClickListener l) {
    NoteIconView v = new NoteIconView(this, glyph, 0, mutedColor);
    v.setContentDescription(description);
    v.setOnClickListener(l);
    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(32), dp(32));
    lp.rightMargin = dp(2);
    v.setLayoutParams(lp);
    return v;
  }

  private View noteRow(JSONObject o, int number) {
    final long id = o.optLong("id");
    final String text = o.optString("text");
    final String type = NotesStore.normalizeType(o.optString("type"));
    final boolean done = o.optBoolean("done", false);
    int typeColor = colorFor(type);

    LinearLayout row = hRow();
    row.setGravity(Gravity.TOP);
    row.setPadding(dp(10), dp(9), dp(10), dp(6));
    GradientDrawable bg = rounded(fieldColor, dp(16), 0, 0);
    row.setBackground(bg);
    LinearLayout.LayoutParams rowLp = matchWrap();
    rowLp.bottomMargin = dp(8);
    row.setLayoutParams(rowLp);

    LinearLayout texts = new LinearLayout(this);
    texts.setOrientation(LinearLayout.VERTICAL);
    TextView bodyText = tv(text, fontSp(), textColor, false);
    bodyText.setGravity(Gravity.RIGHT);
    bodyText.setTextDirection(View.TEXT_DIRECTION_RTL);
    bodyText.setLineSpacing(0, 1.12f);
    if (done) {
      bodyText.setPaintFlags(bodyText.getPaintFlags() | Paint.STRIKE_THRU_TEXT_FLAG);
      bodyText.setAlpha(0.55f);
    }
    texts.addView(bodyText, matchWrap());

    // سطر المعلومات: الأزرار يسار، والرقم/النوع/الوقت يمين
    LinearLayout meta = hRow();
    LinearLayout.LayoutParams metaLp = matchWrap();
    metaLp.topMargin = dp(4);
    meta.setLayoutParams(metaLp);
    final NoteIconView copy =
        smallAction(
            NoteIconView.GLYPH_COPY,
            "نسخ",
            new View.OnClickListener() {
              @Override
              public void onClick(View v) {
                if (copyText("note", text, "تم نسخ الملاحظة")) {
                  flashCopied((NoteIconView) v);
                  closeAfterCopyIfNeeded();
                }
              }
            });
    meta.addView(
        smallAction(
            NoteIconView.GLYPH_DELETE,
            "حذف",
            new View.OnClickListener() {
              @Override
              public void onClick(View v) {
                if (editingId == id) {
                  cancelEdit();
                }
                NotesStore.delete(FloatingNotesService.this, id);
              }
            }));
    meta.addView(
        smallAction(
            NoteIconView.GLYPH_EDIT,
            "تعديل",
            new View.OnClickListener() {
              @Override
              public void onClick(View v) {
                startEdit(id, text, type);
              }
            }));
    NoteIconView doneBtn =
        smallAction(
            done ? NoteIconView.GLYPH_UNDO : NoteIconView.GLYPH_DELIVER,
            done ? "رجّعها" : "تم",
            new View.OnClickListener() {
              @Override
              public void onClick(View v) {
                NotesStore.setDone(FloatingNotesService.this, id, !done);
              }
            });
    if (!done) {
      doneBtn.setColors(0, COLOR_DELIVER);
    }
    meta.addView(doneBtn);
    meta.addView(copy);

    StringBuilder info = new StringBuilder();
    info.append(number).append(" • ").append(NotesStore.label(this, type));
    if (done) {
      info.append(" • منجزة");
    }
    if (NotesStore.showTime(this)) {
      String time = formatTime(o.optLong("at"));
      if (time.length() > 0) {
        info.append(" • ").append(time);
      }
    }
    TextView infoView = tv(info.toString(), 11.5f, typeColor, true);
    infoView.setGravity(Gravity.RIGHT);
    infoView.setSingleLine(true);
    infoView.setTextDirection(View.TEXT_DIRECTION_RTL);
    meta.addView(infoView, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
    texts.addView(meta);

    LinearLayout.LayoutParams tLp =
        new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    tLp.rightMargin = dp(10);
    row.addView(texts, tLp);

    // أيقونة النوع: الضغط عليها بيبدّل النوع
    NoteIconView icon = new NoteIconView(this, glyphFor(type), done ? withAlpha(typeColor, 0x88) : typeColor, Color.WHITE);
    icon.setContentDescription("تغيير النوع");
    icon.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            NotesStore.update(FloatingNotesService.this, id, null, nextType(type));
          }
        });
    row.addView(icon, new LinearLayout.LayoutParams(dp(32), dp(32)));

    // ضغطة مطوّلة على الملاحظة: نسخ نصها
    row.setOnLongClickListener(
        new View.OnLongClickListener() {
          @Override
          public boolean onLongClick(View v) {
            if (copyText("note", text, "تم نسخ الملاحظة")) {
              flashCopied(copy);
              closeAfterCopyIfNeeded();
            }
            return true;
          }
        });
    return row;
  }

  private String nextType(String type) {
    List<String> types = NotesStore.visibleTypes(this);
    int i = types.indexOf(type);
    return types.get((i + 1) % types.size());
  }

  // ===========================================================
  // إعدادات داخل اللوحة
  // ===========================================================

  private View buildSettingsView() {
    LinearLayout box = new LinearLayout(this);
    box.setOrientation(LinearLayout.VERTICAL);

    box.addView(settingLabel("حجم الفقاعة"));
    box.addView(
        segmented(
            new String[] {"صغيرة", "متوسطة", "كبيرة"},
            NotesStore.bubbleSize(this),
            new IntCallback() {
              @Override
              public void onPick(int index) {
                NotesStore.putInt(FloatingNotesService.this, NotesStore.P_BUBBLE_SIZE, index);
              }
            }));

    box.addView(settingLabel("لون الفقاعة"));
    box.addView(colorRow());

    box.addView(settingLabel("وضوح الفقاعة وهي واقفة"));
    final int[] alphas = {100, 80, 60, 40};
    int alphaIndex = 0;
    int currentAlpha = NotesStore.bubbleAlpha(this);
    for (int i = 0; i < alphas.length; i++) {
      if (Math.abs(alphas[i] - currentAlpha) < Math.abs(alphas[alphaIndex] - currentAlpha)) {
        alphaIndex = i;
      }
    }
    box.addView(
        segmented(
            new String[] {"100%", "80%", "60%", "40%"},
            alphaIndex,
            new IntCallback() {
              @Override
              public void onPick(int index) {
                NotesStore.putInt(FloatingNotesService.this, NotesStore.P_BUBBLE_ALPHA, alphas[index]);
              }
            }));

    box.addView(settingLabel("المظهر"));
    box.addView(
        segmented(
            new String[] {"تلقائي", "فاتح", "داكن"},
            NotesStore.theme(this),
            new IntCallback() {
              @Override
              public void onPick(int index) {
                NotesStore.putInt(FloatingNotesService.this, NotesStore.P_THEME, index);
              }
            }));

    box.addView(settingLabel("حجم الخط"));
    box.addView(
        segmented(
            new String[] {"صغير", "عادي", "كبير"},
            NotesStore.fontSize(this),
            new IntCallback() {
              @Override
              public void onPick(int index) {
                NotesStore.putInt(FloatingNotesService.this, NotesStore.P_FONT, index);
              }
            }));

    box.addView(settingLabel("مكان اللوحة"));
    box.addView(
        segmented(
            new String[] {"فوق", "بالنص", "تحت"},
            NotesStore.panelPosition(this),
            new IntCallback() {
              @Override
              public void onPick(int index) {
                NotesStore.putInt(FloatingNotesService.this, NotesStore.P_PANEL_POS, index);
              }
            }));

    box.addView(settingLabel("ضغطة مطوّلة على الفقاعة"));
    box.addView(
        segmented(
            new String[] {"فتح ولصق", "إخفاء", "ولا شي"},
            NotesStore.longPress(this),
            new IntCallback() {
              @Override
              public void onPick(int index) {
                NotesStore.putInt(FloatingNotesService.this, NotesStore.P_LONG_PRESS, index);
              }
            }));

    box.addView(spacer(8));
    box.addView(toggleRow("سكّر اللوحة بعد النسخ", NotesStore.P_CLOSE_AFTER_COPY, NotesStore.closeAfterCopy(this)));
    box.addView(toggleRow("إظهار وقت الملاحظة", NotesStore.P_SHOW_TIME, NotesStore.showTime(this)));
    box.addView(toggleRow("ترقيم «نسخ الكل» (1. 2. 3.)", NotesStore.P_COPY_NUMBERS, NotesStore.copyNumbers(this)));
    box.addView(toggleRow("نوع الملاحظة مع «نسخ الكل»", NotesStore.P_COPY_TYPES, NotesStore.copyTypes(this)));
    box.addView(toggleRow("الفقاعة بتلزق بطرف الشاشة", NotesStore.P_SNAP, NotesStore.snapToEdge(this)));

    TextView tip =
        tv(
            "أسماء الأنواع وإخفاء الأنواع واسم الحافظة بتتغير من التطبيق: الإعدادات ← الحافظة.",
            12,
            mutedColor,
            false);
    tip.setGravity(Gravity.RIGHT);
    tip.setPadding(0, dp(10), 0, dp(10));
    box.addView(tip, matchWrap());

    TextView back = tv("رجوع للملاحظات", 15, Color.WHITE, true);
    back.setGravity(Gravity.CENTER);
    back.setBackground(rounded(accent, dp(14), 0, 0));
    back.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            showSettings = false;
            refreshPanel();
          }
        });
    box.addView(back, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)));
    return box;
  }

  private TextView settingLabel(String text) {
    TextView t = tv(text, 13, mutedColor, true);
    t.setGravity(Gravity.RIGHT);
    LinearLayout.LayoutParams lp = matchWrap();
    lp.topMargin = dp(12);
    lp.bottomMargin = dp(6);
    t.setLayoutParams(lp);
    return t;
  }

  /** أزرار اختيار متلاصقة. الخيار الأول على اليمين. */
  private View segmented(String[] labels, int selected, final IntCallback cb) {
    LinearLayout row = hRow();
    row.setPadding(dp(3), dp(3), dp(3), dp(3));
    row.setBackground(rounded(fieldColor, dp(13), dp(1), strokeColor));
    for (int k = labels.length - 1; k >= 0; k--) {
      final int idx = k;
      boolean sel = k == selected;
      TextView t = tv(labels[k], 12.5f, sel ? Color.WHITE : textColor, true);
      t.setGravity(Gravity.CENTER);
      t.setSingleLine(true);
      if (sel) {
        t.setBackground(rounded(accent, dp(10), 0, 0));
      }
      t.setOnClickListener(
          new View.OnClickListener() {
            @Override
            public void onClick(View v) {
              cb.onPick(idx);
            }
          });
      row.addView(t, new LinearLayout.LayoutParams(0, dp(34), 1f));
    }
    return row;
  }

  private View colorRow() {
    LinearLayout row = hRow();
    row.setGravity(Gravity.CENTER_VERTICAL | Gravity.RIGHT);
    int selected = NotesStore.bubbleColor(this);
    for (int k = PALETTES.length - 1; k >= 0; k--) {
      final int idx = k;
      FrameLayout dot = new FrameLayout(this);
      GradientDrawable g = new GradientDrawable(GradientDrawable.Orientation.TL_BR, PALETTES[k]);
      g.setShape(GradientDrawable.OVAL);
      if (k == selected) {
        g.setStroke(dp(3), textColor);
      }
      dot.setBackground(g);
      if (k == selected) {
        NoteIconView check = new NoteIconView(this, NoteIconView.GLYPH_DELIVER, 0, Color.WHITE);
        dot.addView(check, new FrameLayout.LayoutParams(dp(22), dp(22), Gravity.CENTER));
      }
      dot.setOnClickListener(
          new View.OnClickListener() {
            @Override
            public void onClick(View v) {
              NotesStore.putInt(FloatingNotesService.this, NotesStore.P_BUBBLE_COLOR, idx);
            }
          });
      LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(34), dp(34));
      lp.leftMargin = dp(8);
      row.addView(dot, lp);
    }
    return row;
  }

  private View toggleRow(String title, final String key, final boolean value) {
    LinearLayout row = hRow();
    row.setPadding(dp(4), dp(8), dp(4), dp(8));
    TextView pill = tv(value ? "مفعّل" : "مطفي", 12, value ? Color.WHITE : mutedColor, true);
    pill.setGravity(Gravity.CENTER);
    pill.setBackground(rounded(value ? accent : fieldColor, dp(13), value ? 0 : dp(1), strokeColor));
    row.addView(pill, new LinearLayout.LayoutParams(dp(64), dp(28)));
    TextView label = tv(title, 14, textColor, false);
    label.setGravity(Gravity.RIGHT);
    LinearLayout.LayoutParams lp =
        new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    lp.leftMargin = dp(10);
    row.addView(label, lp);
    row.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            NotesStore.putBool(FloatingNotesService.this, key, !value);
          }
        });
    return row;
  }

  // ===========================================================
  // أدوات
  // ===========================================================

  private float fontSp() {
    return FONT_SIZES_SP[NotesStore.fontSize(this)];
  }

  private LinearLayout hRow() {
    LinearLayout row = new LinearLayout(this);
    row.setOrientation(LinearLayout.HORIZONTAL);
    row.setGravity(Gravity.CENTER_VERTICAL);
    row.setLayoutParams(matchWrap());
    return row;
  }

  private LinearLayout.LayoutParams matchWrap() {
    return new LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
  }

  private LinearLayout.LayoutParams wrapWrap() {
    return new LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
  }

  private View spacer(int heightDp) {
    View v = new View(this);
    v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(heightDp)));
    return v;
  }

  private TextView tv(String text, float sp, int color, boolean bold) {
    TextView t = new TextView(this);
    t.setText(text);
    t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
    t.setTextColor(color);
    if (bold) {
      t.setTypeface(Typeface.DEFAULT_BOLD);
    }
    return t;
  }

  private static GradientDrawable rounded(int color, float radius, int strokeWidth, int strokeColor) {
    GradientDrawable d = new GradientDrawable();
    d.setColor(color);
    d.setCornerRadius(radius);
    if (strokeWidth > 0) {
      d.setStroke(strokeWidth, strokeColor);
    }
    return d;
  }

  private static int withAlpha(int color, int alpha) {
    return (color & 0x00FFFFFF) | (alpha << 24);
  }

  private static int blend(int a, int b, float t) {
    int ar = (a >> 16) & 0xFF;
    int ag = (a >> 8) & 0xFF;
    int ab = a & 0xFF;
    int br = (b >> 16) & 0xFF;
    int bg = (b >> 8) & 0xFF;
    int bb = b & 0xFF;
    int r = Math.round(ar + (br - ar) * t);
    int g = Math.round(ag + (bg - ag) * t);
    int bl = Math.round(ab + (bb - ab) * t);
    return 0xFF000000 | (r << 16) | (g << 8) | bl;
  }

  static int colorFor(String type) {
    if (NotesStore.TYPE_EDIT.equals(type)) {
      return COLOR_EDIT;
    }
    if (NotesStore.TYPE_CANCEL.equals(type)) {
      return COLOR_CANCEL;
    }
    if (NotesStore.TYPE_DELIVER.equals(type)) {
      return COLOR_DELIVER;
    }
    return COLOR_ADD;
  }

  static int glyphFor(String type) {
    if (NotesStore.TYPE_EDIT.equals(type)) {
      return NoteIconView.GLYPH_EDIT;
    }
    if (NotesStore.TYPE_CANCEL.equals(type)) {
      return NoteIconView.GLYPH_CANCEL;
    }
    if (NotesStore.TYPE_DELIVER.equals(type)) {
      return NoteIconView.GLYPH_DELIVER;
    }
    return NoteIconView.GLYPH_ADD;
  }

  static String countLabel(int n) {
    if (n == 0) {
      return "لا توجد ملاحظات";
    }
    if (n == 1) {
      return "ملاحظة واحدة";
    }
    if (n == 2) {
      return "ملاحظتان";
    }
    if (n <= 10) {
      return n + " ملاحظات";
    }
    return n + " ملاحظة";
  }

  private static String formatTime(long millis) {
    if (millis <= 0) {
      return "";
    }
    Date d = new Date(millis);
    Calendar now = Calendar.getInstance();
    Calendar c = Calendar.getInstance();
    c.setTime(d);
    boolean today =
        now.get(Calendar.YEAR) == c.get(Calendar.YEAR)
            && now.get(Calendar.DAY_OF_YEAR) == c.get(Calendar.DAY_OF_YEAR);
    String pattern = today ? "HH:mm" : "yyyy-MM-dd HH:mm";
    return new SimpleDateFormat(pattern, Locale.US).format(d);
  }
}
