# floating_notes

إضافة (Plugin) محلية لتطبيق «مدير الحسابات»: **فقاعة ملاحظات عائمة** تظهر فوق
كل التطبيقات (مثل فقاعات المحادثة)، حتى تكتب ملاحظاتك وأنت خارج التطبيق.

- زر «ملاحظات» في الصفحة الرئيسية يُظهر الفقاعة أو يخفيها.
- الفقاعة قابلة للمسك والسحب إلى أي مكان، وتلتصق بأقرب حافة وتتذكر مكانها.
- الضغط عليها يفتح لوحة: اختر أيقونة الملاحظة (إضافة / تعديل / إلغاء / تسليم)،
  اكتب النص، ثم اضغط «إضافة».
- الملاحظات محفوظة في الجهاز بترتيب وقت إضافتها. لكل ملاحظة زر نسخ (أو ضغطة
  مطوّلة) وزر حذف، وفوق القائمة «نسخ الكل» (سطر لكل ملاحظة: «1. إلغاء: النص»)
  و«مسح الكل» بتأكيد.
- تبقى الفقاعة ظاهرة عند الخروج من التطبيق (خدمة أمامية مع إشعار صغير فيه زر
  «إخفاء الفقاعة»).

## AndroidManifest

لا حاجة لتعديل `android/app/src/main/AndroidManifest.xml`: ملف المانيفست الخاص بهذه
الإضافة يُدمج تلقائيًا عند البناء، ويضيف:

```xml
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />

<application>
  <service
    android:name="com.mylist.floating_notes.FloatingNotesService"
    android:exported="false"
    android:foregroundServiceType="specialUse">
    <property
      android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
      android:value="Floating notes bubble shown over other apps so the user can write quick notes" />
  </service>
</application>
```

إذا أردت كتابتها يدويًا في مانيفست التطبيق: أسطر `uses-permission` فوق وسم
`<application>`، ووسم `<service>` داخل `<application>`.

## ملاحظات

- أول مرة يطلب التطبيق إذن **«الظهور فوق التطبيقات الأخرى»**: فعّله لـ«مدير الحسابات»
  ثم ارجع للتطبيق فتظهر الفقاعة تلقائيًا.
- بعض الهواتف (مثل شاومي) فيها إذن إضافي «عرض النوافذ المنبثقة أثناء العمل في
  الخلفية» — فعّله إن لم تظهر الفقاعة خارج التطبيق.
- بعد إضافة الحزمة يجب إعادة بناء التطبيق بالكامل (لا يكفي Hot Reload).
