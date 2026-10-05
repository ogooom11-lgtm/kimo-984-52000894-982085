# floating_notes («الحافظة»)

إضافة (Plugin) محلية لتطبيق «مدير الحسابات»: **فقاعة ملاحظات عائمة** تظهر فوق
كل التطبيقات (مثل فقاعات المحادثة)، حتى تكتب ملاحظاتك وتنسخها وأنت خارج التطبيق.

- زر «الحافظة» في الصفحة الرئيسية يُظهر الفقاعة أو يخفيها (ضغطة مطوّلة عليه =
  إعدادات الحافظة).
- **زر «الحافظة» بلوحة الإعدادات السريعة** (لما تنزّل الستارة، جنب البلوتوث
  والواي فاي والكشاف): ضغطة عليه بتفتح الحافظة فوق أي تطبيق. على أندرويد 13+
  التطبيق بيقدر يطلب إضافته بضغطة (الإعدادات ← الحافظة)، وعلى الأقدم: نزّل
  الستارة ← ✏️ تعديل ← اسحب «الحافظة» لفوق.
- الفقاعة قابلة للمسك والسحب، وتلتصق بأقرب حافة وتتذكر مكانها. حجمها ولونها
  ووضوحها قابلين للتخصيص. الضغطة المطوّلة عليها: «فتح ولصق المنسوخ» (أو إخفاء،
  أو ولا شي).
- اللوحة: اختر نوع الملاحظة (إضافة / تعديل / إلغاء / تسليم — أسماؤها قابلة
  للتغيير والأنواع غير المستعملة بتنخفى)، اكتب أو الصق المنسوخ 📋، ثم «إضافة».
- لكل ملاحظة: نسخ (أو ضغطة مطوّلة)، تعديل، «تم» (بتنشطب وما بتنحسب)، حذف،
  والضغط على أيقونتها بيبدّل نوعها. فوق القائمة: فلترة حسب النوع، «نسخ الكل»
  (الترقيم والنوع اختياريين)، «مسح المنجزة»، و«مسح الكل» بتأكيد.
- زر ⚙ داخل اللوحة لأهم الإعدادات (الحجم، اللون، الوضوح، المظهر، الخط، مكان
  اللوحة، الضغطة المطوّلة، سكّر بعد النسخ...). كل الإعدادات كمان من التطبيق.
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

  <!-- زر لوحة الإعدادات السريعة -->
  <service
    android:name="com.mylist.floating_notes.NotesTileService"
    android:exported="true"
    android:icon="@drawable/ic_floating_notes_tile"
    android:label="@string/floating_notes_tile_label"
    android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
    <intent-filter>
      <action android:name="android.service.quicksettings.action.QS_TILE" />
    </intent-filter>
  </service>

  <!-- صفحة شفافة قصيرة: بتسكّر الستارة وبتفتح الحافظة -->
  <activity
    android:name="com.mylist.floating_notes.NotesTileActivity"
    android:exported="false"
    android:excludeFromRecents="true"
    android:noHistory="true"
    android:taskAffinity=""
    android:theme="@android:style/Theme.Translucent.NoTitleBar" />
</application>
```

## ملاحظات

- أول مرة يطلب التطبيق إذن **«الظهور فوق التطبيقات الأخرى»**: فعّله لـ«مدير الحسابات»
  ثم ارجع للتطبيق فتظهر الفقاعة تلقائيًا. (زر الستارة بيفتح صفحة الإذن إذا مو ممنوح.)
- بعض الهواتف (مثل شاومي) فيها إذن إضافي «عرض النوافذ المنبثقة أثناء العمل في
  الخلفية» — فعّله إن لم تظهر الفقاعة خارج التطبيق.
- أندرويد 10+ ما بيسمح بقراءة المنسوخ إلا للتطبيق الظاهر، لهيك «لصق المنسوخ»
  بيشتغل من داخل لوحة الحافظة (والضغطة المطوّلة على الفقاعة بتفتح اللوحة أول).
- بعد تحديث الحزمة يجب إعادة بناء التطبيق بالكامل (لا يكفي Hot Reload).
