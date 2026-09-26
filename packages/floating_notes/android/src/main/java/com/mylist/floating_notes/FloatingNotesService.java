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
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Date;
import java.util.Locale;

/**
 * خدمة أمامية تعرض فقاعة ملاحظات عائمة فوق كل التطبيقات:
 * - الفقاعة قابلة للسحب إلى أي مكان وتلتصق بأقرب حافة وتتذكر مكانها.
 * - الضغط عليها يفتح لوحة: اختيار نوع الملاحظة (إضافة/تعديل/إلغاء/تسليم)،
 *   مربع نص، زر إضافة، وقائمة الملاحظات بترتيب وقت إضافتها.
 * تبقى ظاهرة حتى لو خرج المستخدم من التطبيق، وتُخفى من زر «إخفاء» أو من
 * الإشعار أو من زر الملاحظات في التطبيق.
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
  private static final int COLOR_BUBBLE_START = 0xFF3F51B5;
  private static final int COLOR_BUBBLE_END = 0xFF26A69A;

  private static final String[] TYPES = {
    NotesStore.TYPE_DELIVER, NotesStore.TYPE_CANCEL, NotesStore.TYPE_EDIT, NotesStore.TYPE_ADD
  };

  private static volatile boolean running = false;

  static boolean isRunning() {
    return running;
  }

  static boolean canDraw(Context c) {
    return Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(c);
  }

  private final Handler handler = new Handler(Looper.getMainLooper());
  private WindowManager wm;

  // الفقاعة
  private FrameLayout bubble;
  private TextView badge;
  private WindowManager.LayoutParams bubbleParams;
  private ValueAnimator snapAnimator;

  // اللوحة
  private PanelRoot panel;
  private WindowManager.LayoutParams panelParams;
  private EditText input;
  private TextView addButton;
  private TextView countView;
  private TextView listTitle;
  private TextView clearButton;
  private TextView copyAllButton;
  private LinearLayout notesList;
  private final LinearLayout[] typeChips = new LinearLayout[TYPES.length];
  private String selectedType = NotesStore.TYPE_ADD;
  private boolean clearArmed = false;
  private boolean dark = false;

  private int cardColor;
  private int textColor;
  private int mutedColor;
  private int fieldColor;
  private int strokeColor;

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
    if (bubble != null) {
      try {
        wm.removeView(bubble);
      } catch (Exception ignored) {
      }
      bubble = null;
    }
    FloatingNotesPlugin.notifyStateChanged();
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
      String draft = String.valueOf(input.getText());
      removePanel();
      showPanel();
      input.setText(draft);
    }
  }

  @Override
  public void onNotesChanged() {
    updateBadge();
    if (panel != null) {
      renderNotes();
    }
  }

  private void startInForeground() {
    NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
    if (Build.VERSION.SDK_INT >= 26 && nm != null) {
      NotificationChannel channel =
          new NotificationChannel(
              CHANNEL_ID, "الملاحظات العائمة", NotificationManager.IMPORTANCE_LOW);
      channel.setDescription("يظهر ما دامت فقاعة الملاحظات على الشاشة");
      channel.setShowBadge(false);
      nm.createNotificationChannel(channel);
    }
    Notification.Builder b =
        Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL_ID)
            : new Notification.Builder(this);
    b.setSmallIcon(android.R.drawable.ic_menu_edit)
        .setContentTitle("الملاحظات العائمة")
        .setContentText("اضغط لفتح الملاحظات")
        .setOngoing(true)
        .setShowWhen(false)
        .setContentIntent(servicePending(ACTION_OPEN, 1))
        .addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "إخفاء الفقاعة",
            servicePending(ACTION_HIDE, 2));
    Notification n = b.build();
    if (Build.VERSION.SDK_INT >= 34) {
      startForeground(NOTIFICATION_ID, n, FGS_TYPE_SPECIAL_USE);
    } else {
      startForeground(NOTIFICATION_ID, n);
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

  private void showBubble() {
    if (bubble != null) {
      return;
    }
    int circle = dp(54);
    int pad = dp(7);
    bubble = new FrameLayout(this);
    bubble.setPadding(pad, pad, pad, pad);
    bubble.setClipToPadding(false);
    bubble.setClipChildren(false);

    View disk = new View(this);
    GradientDrawable bg =
        new GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            new int[] {COLOR_BUBBLE_START, COLOR_BUBBLE_END});
    bg.setShape(GradientDrawable.OVAL);
    bg.setStroke(dp(2.5f), Color.WHITE);
    disk.setBackground(bg);
    disk.setElevation(dp(6));
    bubble.addView(disk, new FrameLayout.LayoutParams(circle, circle, Gravity.CENTER));

    NoteIconView glyph = new NoteIconView(this, NoteIconView.GLYPH_NOTES, 0, Color.WHITE);
    glyph.setElevation(dp(6.5f));
    glyph.setContentDescription("الملاحظات");
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

    bubbleParams =
        new WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT);
    bubbleParams.gravity = Gravity.TOP | Gravity.LEFT;
    DisplayMetrics dm = getResources().getDisplayMetrics();
    int[] pos = NotesStore.loadPosition(this, dm.widthPixels - circle - 2 * pad, dm.heightPixels / 3);
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

  private void updateBadge() {
    if (badge == null) {
      return;
    }
    int n = NotesStore.count(this);
    badge.setText(n > 99 ? "99+" : String.valueOf(n));
    badge.setVisibility(n > 0 ? View.VISIBLE : View.GONE);
  }

  private int bubbleSize() {
    return bubble != null && bubble.getWidth() > 0 ? bubble.getWidth() : dp(68);
  }

  private void clampBubble() {
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

  private class BubbleTouch implements View.OnTouchListener {
    private final int slop = ViewConfiguration.get(FloatingNotesService.this).getScaledTouchSlop();
    private int startX;
    private int startY;
    private float downX;
    private float downY;
    private boolean moved;

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
          v.animate().scaleX(0.9f).scaleY(0.9f).setDuration(90).start();
          return true;
        case MotionEvent.ACTION_MOVE:
          if (!moved && (Math.abs(dx) > slop || Math.abs(dy) > slop)) {
            moved = true;
          }
          if (moved) {
            bubbleParams.x = startX + Math.round(dx);
            bubbleParams.y = startY + Math.round(dy);
            clampBubble();
            safeUpdate(bubble, bubbleParams);
          }
          return true;
        case MotionEvent.ACTION_UP:
          v.animate().scaleX(1f).scaleY(1f).setDuration(120).start();
          if (moved) {
            snapToEdge();
          } else {
            togglePanel();
          }
          return true;
        case MotionEvent.ACTION_CANCEL:
          v.animate().scaleX(1f).scaleY(1f).setDuration(120).start();
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
          removePanel();
        }
        return true;
      }
      return super.dispatchKeyEvent(event);
    }
  }

  private void togglePanel() {
    if (panel != null) {
      removePanel();
    } else {
      showPanel();
    }
  }

  private boolean isDark() {
    return (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
        == Configuration.UI_MODE_NIGHT_YES;
  }

  private void applyPalette() {
    dark = isDark();
    cardColor = dark ? 0xFF1E2230 : 0xFFFFFFFF;
    textColor = dark ? 0xFFF1F5F9 : 0xFF1E293B;
    mutedColor = dark ? 0xFF94A3B8 : 0xFF64748B;
    fieldColor = dark ? 0xFF272C3B : 0xFFF1F5F9;
    strokeColor = dark ? 0xFF3A4256 : 0xFFE2E8F0;
  }

  private void showPanel() {
    if (panel != null) {
      return;
    }
    applyPalette();
    selectedType = NotesStore.lastType(this);
    DisplayMetrics dm = getResources().getDisplayMetrics();

    panel = new PanelRoot(this);
    panel.setBackgroundColor(0x73000000);
    panel.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            removePanel();
          }
        });

    ScrollView card = new ScrollView(this);
    card.setLayoutDirection(View.LAYOUT_DIRECTION_LTR);
    card.setBackground(rounded(cardColor, dp(22), 0, 0));
    card.setElevation(dp(12));
    card.setClipToOutline(true);
    card.setClickable(true);
    card.setFillViewport(false);
    int cardWidth = Math.min(dm.widthPixels - dp(28), dp(460));
    FrameLayout.LayoutParams cardLp =
        new FrameLayout.LayoutParams(
            cardWidth, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
    cardLp.topMargin = dp(40);
    cardLp.bottomMargin = dp(20);
    panel.addView(card, cardLp);

    LinearLayout body = new LinearLayout(this);
    body.setOrientation(LinearLayout.VERTICAL);
    body.setPadding(dp(16), dp(14), dp(16), dp(16));
    card.addView(
        body,
        new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

    body.addView(buildHeader());
    body.addView(spacer(12));
    body.addView(buildTypeRow());
    body.addView(spacer(10));
    body.addView(buildInput());
    body.addView(buildAddButton());
    body.addView(spacer(14));
    body.addView(buildListHeader());
    notesList = new LinearLayout(this);
    notesList.setOrientation(LinearLayout.VERTICAL);
    body.addView(
        notesList,
        new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

    panelParams =
        new WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(),
            0,
            PixelFormat.TRANSLUCENT);
    panelParams.gravity = Gravity.TOP | Gravity.LEFT;
    panelParams.softInputMode =
        WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
            | WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN;
    try {
      wm.addView(panel, panelParams);
    } catch (Exception e) {
      panel = null;
      return;
    }
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
    clearArmed = false;
    if (input != null) {
      InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
      if (imm != null) {
        imm.hideSoftInputFromWindow(input.getWindowToken(), 0);
      }
    }
    try {
      wm.removeView(panel);
    } catch (Exception ignored) {
    }
    panel = null;
    notesList = null;
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

    TextView hide = tv("إخفاء الفقاعة", 12.5f, mutedColor, true);
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
    TextView title = tv("ملاحظاتي", 18, textColor, true);
    title.setGravity(Gravity.RIGHT);
    countView = tv("", 12.5f, mutedColor, false);
    countView.setGravity(Gravity.RIGHT);
    titles.addView(title, matchWrap());
    titles.addView(countView, matchWrap());
    LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    tLp.leftMargin = dp(8);
    tLp.rightMargin = dp(10);
    row.addView(titles, tLp);

    NoteIconView icon =
        new NoteIconView(this, NoteIconView.GLYPH_NOTES, COLOR_BUBBLE_START, Color.WHITE);
    row.addView(icon, new LinearLayout.LayoutParams(dp(40), dp(40)));
    return row;
  }

  private View buildTypeRow() {
    LinearLayout row = hRow();
    for (int i = 0; i < TYPES.length; i++) {
      LinearLayout chip = typeChip(TYPES[i]);
      typeChips[i] = chip;
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
    chip.addView(icon, new LinearLayout.LayoutParams(dp(30), dp(30)));
    TextView label = tv(labelFor(type), 12.5f, textColor, true);
    label.setGravity(Gravity.CENTER);
    label.setPadding(0, dp(5), 0, 0);
    chip.addView(label, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
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
    for (int i = 0; i < typeChips.length; i++) {
      LinearLayout chip = typeChips[i];
      if (chip == null) {
        continue;
      }
      String t = (String) chip.getTag();
      int c = colorFor(t);
      boolean sel = selectedType.equals(t);
      chip.setBackground(
          rounded(
              sel ? withAlpha(c, dark ? 0x44 : 0x22) : fieldColor,
              dp(14),
              sel ? dp(2) : dp(1),
              sel ? c : strokeColor));
    }
    styleAddButton();
  }

  private View buildInput() {
    input = new EditText(this);
    input.setHint("اكتب الملاحظة هنا…");
    input.setHintTextColor(mutedColor);
    input.setTextColor(textColor);
    input.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
    input.setGravity(Gravity.RIGHT | Gravity.TOP);
    input.setTextDirection(View.TEXT_DIRECTION_RTL);
    input.setMinLines(2);
    input.setMaxLines(5);
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
    input.setLayoutParams(matchWrap());
    return input;
  }

  private View buildAddButton() {
    addButton = tv("", 15, Color.WHITE, true);
    addButton.setGravity(Gravity.CENTER);
    addButton.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            addNote();
          }
        });
    LinearLayout.LayoutParams lp =
        new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(48));
    lp.topMargin = dp(10);
    addButton.setLayoutParams(lp);
    return addButton;
  }

  private void styleAddButton() {
    if (addButton == null || input == null) {
      return;
    }
    boolean enabled = String.valueOf(input.getText()).trim().length() > 0;
    int c = colorFor(selectedType);
    addButton.setEnabled(enabled);
    addButton.setText("إضافة ملاحظة «" + labelFor(selectedType) + "»");
    addButton.setBackground(rounded(enabled ? c : withAlpha(c, 0x66), dp(14), 0, 0));
  }

  private void addNote() {
    String text = String.valueOf(input.getText()).trim();
    if (text.length() == 0) {
      return;
    }
    NotesStore.add(this, text, selectedType);
    input.setText("");
    addButton.setText("✓ تمت الإضافة");
    addButton.setBackground(rounded(colorFor(selectedType), dp(14), 0, 0));
    handler.removeCallbacks(resetAddText);
    handler.postDelayed(resetAddText, 1300);
  }

  private View buildListHeader() {
    LinearLayout row = hRow();
    clearButton = tv("", 12.5f, mutedColor, true);
    clearButton.setPadding(dp(8), dp(6), dp(8), dp(6));
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
            NotesStore.clear(FloatingNotesService.this);
            styleClearButton();
          }
        });
    row.addView(clearButton, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    copyAllButton = tv("", 12.5f, COLOR_ADD, true);
    copyAllButton.setPadding(dp(8), dp(6), dp(8), dp(6));
    copyAllButton.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            copyAll();
          }
        });
    row.addView(copyAllButton, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    listTitle = tv("", 14, textColor, true);
    listTitle.setGravity(Gravity.RIGHT);
    row.addView(listTitle, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
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
    copyAllButton.setText("نسخ الكل");
    copyAllButton.setTextColor(COLOR_ADD);
  }

  /** ينسخ كل الملاحظات بترتيبها، سطر لكل ملاحظة: «1. إلغاء: النص». */
  private void copyAll() {
    JSONArray arr = NotesStore.load(this);
    StringBuilder sb = new StringBuilder();
    int n = 0;
    for (int i = 0; i < arr.length(); i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o == null) {
        continue;
      }
      String text = o.optString("text").trim();
      if (text.length() == 0) {
        continue;
      }
      n++;
      if (sb.length() > 0) {
        sb.append('\n');
      }
      sb.append(n)
          .append(". ")
          .append(labelFor(NotesStore.normalizeType(o.optString("type"))))
          .append(": ")
          .append(text);
    }
    if (n == 0) {
      return;
    }
    if (copyText("notes", sb.toString(), "تم نسخ " + countLabel(n))) {
      copyAllButton.setText("✓ تم النسخ");
      copyAllButton.setTextColor(COLOR_DELIVER);
      handler.removeCallbacks(resetCopyAll);
      handler.postDelayed(resetCopyAll, 1500);
    }
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
      Toast.makeText(this, toast, Toast.LENGTH_SHORT).show();
    }
    return true;
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

  private void styleClearButton() {
    if (clearButton == null) {
      return;
    }
    clearButton.setText(clearArmed ? "اضغط مجددًا للتأكيد" : "مسح الكل");
    clearButton.setTextColor(clearArmed ? COLOR_CANCEL : mutedColor);
  }

  private void renderNotes() {
    if (notesList == null) {
      return;
    }
    notesList.removeAllViews();
    JSONArray arr = NotesStore.load(this);
    int n = arr.length();
    countView.setText(countLabel(n));
    listTitle.setText("الملاحظات بالترتيب");
    clearButton.setVisibility(n > 0 ? View.VISIBLE : View.GONE);
    copyAllButton.setVisibility(n > 0 ? View.VISIBLE : View.GONE);
    if (n == 0) {
      TextView empty =
          tv("لا توجد ملاحظات بعد.\nاختر نوع الملاحظة واكتبها ثم اضغط «إضافة».", 13, mutedColor, false);
      empty.setGravity(Gravity.CENTER);
      empty.setPadding(dp(8), dp(18), dp(8), dp(12));
      notesList.addView(empty, matchWrap());
      return;
    }
    for (int i = 0; i < n; i++) {
      JSONObject o = arr.optJSONObject(i);
      if (o != null) {
        notesList.addView(noteRow(o, i + 1));
      }
    }
  }

  private View noteRow(JSONObject o, int number) {
    final long id = o.optLong("id");
    final String text = o.optString("text");
    String type = NotesStore.normalizeType(o.optString("type"));

    LinearLayout row = hRow();
    row.setPadding(dp(8), dp(8), dp(10), dp(8));
    row.setBackground(rounded(fieldColor, dp(14), 0, 0));
    LinearLayout.LayoutParams rowLp = matchWrap();
    rowLp.bottomMargin = dp(8);
    row.setLayoutParams(rowLp);

    NoteIconView delete = new NoteIconView(this, NoteIconView.GLYPH_DELETE, 0, mutedColor);
    delete.setContentDescription("حذف");
    delete.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            NotesStore.delete(FloatingNotesService.this, id);
          }
        });
    row.addView(delete, new LinearLayout.LayoutParams(dp(34), dp(34)));

    final NoteIconView copy = new NoteIconView(this, NoteIconView.GLYPH_COPY, 0, mutedColor);
    copy.setContentDescription("نسخ");
    copy.setOnClickListener(
        new View.OnClickListener() {
          @Override
          public void onClick(View v) {
            if (copyText("note", text, "تم نسخ الملاحظة")) {
              flashCopied(copy);
            }
          }
        });
    LinearLayout.LayoutParams copyLp = new LinearLayout.LayoutParams(dp(34), dp(34));
    copyLp.leftMargin = dp(2);
    row.addView(copy, copyLp);

    LinearLayout texts = new LinearLayout(this);
    texts.setOrientation(LinearLayout.VERTICAL);
    TextView body = tv(text, 15, textColor, false);
    body.setGravity(Gravity.RIGHT);
    body.setTextDirection(View.TEXT_DIRECTION_RTL);
    TextView meta =
        tv(number + " • " + labelFor(type) + " • " + formatTime(o.optLong("at")), 11.5f, colorFor(type), true);
    meta.setGravity(Gravity.RIGHT);
    meta.setTextDirection(View.TEXT_DIRECTION_RTL);
    texts.addView(body, matchWrap());
    texts.addView(meta, matchWrap());
    LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    tLp.leftMargin = dp(6);
    tLp.rightMargin = dp(10);
    row.addView(texts, tLp);

    NoteIconView icon = new NoteIconView(this, glyphFor(type), colorFor(type), Color.WHITE);
    row.addView(icon, new LinearLayout.LayoutParams(dp(32), dp(32)));

    // ضغطة مطوّلة على الملاحظة: نسخ نصها أيضًا
    row.setOnLongClickListener(
        new View.OnLongClickListener() {
          @Override
          public boolean onLongClick(View v) {
            if (copyText("note", text, "تم نسخ الملاحظة")) {
              flashCopied(copy);
            }
            return true;
          }
        });
    return row;
  }

  // ===========================================================
  // أدوات
  // ===========================================================

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

  static String labelFor(String type) {
    if (NotesStore.TYPE_EDIT.equals(type)) {
      return "تعديل";
    }
    if (NotesStore.TYPE_CANCEL.equals(type)) {
      return "إلغاء";
    }
    if (NotesStore.TYPE_DELIVER.equals(type)) {
      return "تسليم";
    }
    return "إضافة";
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
