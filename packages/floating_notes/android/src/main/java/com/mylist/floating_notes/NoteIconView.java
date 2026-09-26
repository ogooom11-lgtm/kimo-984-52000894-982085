package com.mylist.floating_notes;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.view.View;

/**
 * أيقونة مرسومة بالكود (بدون ملفات موارد): دائرة ملونة اختيارية وبداخلها رمز
 * (إضافة، تعديل، إلغاء، تسليم، ملاحظات، إغلاق، حذف، نسخ).
 */
final class NoteIconView extends View {
  static final int GLYPH_NOTES = 0;
  static final int GLYPH_ADD = 1;
  static final int GLYPH_EDIT = 2;
  static final int GLYPH_CANCEL = 3;
  static final int GLYPH_DELIVER = 4;
  static final int GLYPH_CLOSE = 5;
  static final int GLYPH_DELETE = 6;
  static final int GLYPH_COPY = 7;

  private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Path path = new Path();
  private final RectF rect = new RectF();

  private int glyph;
  private int circleColor;
  private int glyphColor;

  /** circleColor = 0 يعني رمزًا بدون دائرة. */
  NoteIconView(Context context, int glyph, int circleColor, int glyphColor) {
    super(context);
    this.glyph = glyph;
    this.circleColor = circleColor;
    this.glyphColor = glyphColor;
    fill.setStyle(Paint.Style.FILL);
    stroke.setStyle(Paint.Style.STROKE);
    stroke.setStrokeCap(Paint.Cap.ROUND);
    stroke.setStrokeJoin(Paint.Join.ROUND);
  }

  void setColors(int circleColor, int glyphColor) {
    this.circleColor = circleColor;
    this.glyphColor = glyphColor;
    invalidate();
  }

  void setGlyph(int glyph) {
    this.glyph = glyph;
    invalidate();
  }

  @Override
  protected void onDraw(Canvas canvas) {
    super.onDraw(canvas);
    float w = getWidth();
    float h = getHeight();
    float size = Math.min(w, h);
    float cx = w / 2f;
    float cy = h / 2f;
    if (circleColor != 0) {
      fill.setColor(circleColor);
      canvas.drawCircle(cx, cy, size / 2f, fill);
      drawGlyph(canvas, cx, cy, size * 0.5f);
    } else {
      drawGlyph(canvas, cx, cy, size * 0.62f);
    }
  }

  private void drawGlyph(Canvas c, float cx, float cy, float g) {
    float l = cx - g / 2f;
    float t = cy - g / 2f;
    stroke.setColor(glyphColor);
    stroke.setStrokeWidth(Math.max(2f, g * 0.13f));
    fill.setColor(glyphColor);
    switch (glyph) {
      case GLYPH_ADD:
        c.drawLine(cx, t + g * 0.1f, cx, t + g * 0.9f, stroke);
        c.drawLine(l + g * 0.1f, cy, l + g * 0.9f, cy, stroke);
        break;
      case GLYPH_CANCEL:
      case GLYPH_CLOSE:
        c.drawLine(l + g * 0.18f, t + g * 0.18f, l + g * 0.82f, t + g * 0.82f, stroke);
        c.drawLine(l + g * 0.82f, t + g * 0.18f, l + g * 0.18f, t + g * 0.82f, stroke);
        break;
      case GLYPH_DELIVER:
        path.reset();
        path.moveTo(l + g * 0.1f, t + g * 0.52f);
        path.lineTo(l + g * 0.38f, t + g * 0.8f);
        path.lineTo(l + g * 0.92f, t + g * 0.24f);
        c.drawPath(path, stroke);
        break;
      case GLYPH_EDIT:
        drawPencil(c, cx, cy, g);
        break;
      case GLYPH_DELETE:
        stroke.setStrokeWidth(Math.max(1.5f, g * 0.1f));
        c.drawLine(l + g * 0.14f, t + g * 0.24f, l + g * 0.86f, t + g * 0.24f, stroke);
        c.drawLine(l + g * 0.38f, t + g * 0.1f, l + g * 0.62f, t + g * 0.1f, stroke);
        path.reset();
        path.moveTo(l + g * 0.24f, t + g * 0.34f);
        path.lineTo(l + g * 0.31f, t + g * 0.92f);
        path.lineTo(l + g * 0.69f, t + g * 0.92f);
        path.lineTo(l + g * 0.76f, t + g * 0.34f);
        c.drawPath(path, stroke);
        c.drawLine(l + g * 0.43f, t + g * 0.46f, l + g * 0.45f, t + g * 0.78f, stroke);
        c.drawLine(l + g * 0.57f, t + g * 0.46f, l + g * 0.55f, t + g * 0.78f, stroke);
        break;
      case GLYPH_COPY:
        // ورقتان متراكبتان: الخلفية (حرف L) ثم الأمامية كاملة
        stroke.setStrokeWidth(Math.max(1.5f, g * 0.1f));
        path.reset();
        path.moveTo(l + g * 0.3f, t + g * 0.22f);
        path.lineTo(l + g * 0.3f, t + g * 0.08f);
        path.lineTo(l + g * 0.9f, t + g * 0.08f);
        path.lineTo(l + g * 0.9f, t + g * 0.7f);
        path.lineTo(l + g * 0.78f, t + g * 0.7f);
        c.drawPath(path, stroke);
        rect.set(l + g * 0.1f, t + g * 0.3f, l + g * 0.68f, t + g * 0.92f);
        c.drawRoundRect(rect, g * 0.1f, g * 0.1f, stroke);
        break;
      case GLYPH_NOTES:
      default:
        stroke.setStrokeWidth(Math.max(1.5f, g * 0.1f));
        rect.set(l + g * 0.14f, t + g * 0.04f, l + g * 0.86f, t + g * 0.96f);
        c.drawRoundRect(rect, g * 0.14f, g * 0.14f, stroke);
        float x0 = rect.left + g * 0.16f;
        float x1 = rect.right - g * 0.16f;
        c.drawLine(x0, t + g * 0.32f, x1, t + g * 0.32f, stroke);
        c.drawLine(x0, t + g * 0.5f, x1, t + g * 0.5f, stroke);
        c.drawLine(x0, t + g * 0.68f, x0 + (x1 - x0) * 0.55f, t + g * 0.68f, stroke);
        break;
    }
  }

  /** قلم مائل: الممحاة ثم فاصل ثم الجسم ثم رأس القلم باتجاه الأسفل واليسار. */
  private void drawPencil(Canvas c, float cx, float cy, float g) {
    c.save();
    c.rotate(135f, cx, cy);
    float bodyW = g * 0.28f;
    float len = g * 1.05f;
    float x0 = cx - len / 2f;
    float x1 = cx + len / 2f;
    float tip = g * 0.26f;
    float top = cy - bodyW / 2f;
    float bottom = cy + bodyW / 2f;
    rect.set(x0, top, x0 + g * 0.14f, bottom);
    c.drawRect(rect, fill);
    rect.set(x0 + g * 0.2f, top, x1 - tip, bottom);
    c.drawRect(rect, fill);
    path.reset();
    path.moveTo(x1 - tip + g * 0.04f, top);
    path.lineTo(x1, cy);
    path.lineTo(x1 - tip + g * 0.04f, bottom);
    path.close();
    c.drawPath(path, fill);
    c.restore();
  }
}
