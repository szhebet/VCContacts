# VCContacts — архитектура, пайплайн, сборка

Приложение для сканирования визиток с **полностью локальной** обработкой:
on-device OCR, локальная БД, ноль сетевых вызовов в рантайме.
Целевые платформы: Android (артефакты для Samsung S22+ и Huawei) и iOS.

---

## 1. Краткая архитектура

Три слоя (clean-подобная вертикаль, без over-engineering):

```
┌──────────────────────────────────────────────────────────┐
│  UI (lib/ui)                                              │
│  Screens: CardsList, Camera, Crop, ScanFlow, Edit, Detail │
│  Widgets: BusinessCardTile, EditableField                 │
└───────────────▲──────────────────────────────────────────┘
                │ state (flutter_bloc: Cubit)
┌───────────────┴──────────────────────────────────────────┐
│  Бизнес-логика (lib/business)                             │
│  ScanCubit — пайплайн фото→черновик                       │
│  EditCardCubit — проверка/редактирование/сохранение        │
│  CardsListCubit — список/поиск/удаление                   │
└───────────────▲──────────────────────────────────────────┘
                │ модели и репозиторий
┌───────────────┴──────────────────────────────────────────┐
│  Данные (lib/data)                                        │
│  OcrService (ML Kit + Tesseract, оба on-device)           │
│  ImagePreprocessor (EXIF, кроп, контраст, ч/б)            │
│  CardParser (regex + эвристики)                           │
│  CardRepository → CardDatabase (sqflite, только локально) │
│  ExportService (vCard/CSV), ContactExportService          │
└──────────────────────────────────────────────────────────┘
```

Зависимости инжектируются через `get_it` (`lib/core/di/injector.dart`) —
UI никогда не создаёт сервисы напрямую, кроме Cubit'ов.

### Структура папок

```
lib/
├── main.dart                    # точка входа, DI, MaterialApp
├── core/
│   ├── di/injector.dart         # service locator
│   ├── errors/app_exceptions.dart
│   └── utils/                   # (зарезервировано)
├── data/
│   ├── models/business_card.dart
│   ├── local/card_database.dart # sqflite
│   ├── repositories/card_repository.dart
│   └── services/                # OCR, парсер, препроцессинг, экспорт
├── business/                    # cubit'ы (scan, edit, cards)
└── ui/
    ├── theme/app_theme.dart
    ├── widgets/
    └── screens/                 # cards_list, camera (crop, scan_flow), edit, detail
test/
└── card_parser_test.dart        # юнит-тесты парсера
android/                         # gradle-конфиг, флаворы samsung/huawei
Dockerfile                       # многостадийная сборка
build.sh                         # сборка в контейнере + копирование APK в apk/
```

### Экраны и навигация

```
CardsListScreen (дом)
  ├── FAB «камера» → CameraScreen → снимок
  │                       └─→ CropScreen (обрезка рамкой)
  │                              └─→ ScanFlowScreen (прогресс пайплайна)
  │                                     └─→ EditCardScreen (проверка/правка)
  │                                            └─→ pop → CardsList
  ├── FAB «галерея» → ImagePicker → CropScreen → … (тот же поток)
  ├── тап по карточке → CardDetailScreen
  │       ├── «Редактировать» → EditCardScreen → pop(обновлённая карточка)
  │       ├── «В контакты» → системный Contact Provider
  │       └── «vCard» → share-sheet
  └── меню → «Экспорт всех в CSV» → share-sheet
```

## 2. Пайплайн сканирования

```
Фото (камера/галерея)
  │
  ▼
CropScreen — ручная обрезка по границам визитки (относительные координаты)
  │
  ▼
ImagePreprocessor.prepare()
  1) декодирование; поворот по EXIF (bakeOrientation)
  2) обрезка по CropRegion (0..1)
  3) оценка яркости → предупреждения «тёмное/пересвечено»
  4) grayscale + adjustColor(contrast 1.35) + normalize(16..240)
  5) даунскейл до 1600 px по длинной стороне → JPEG q92 во временный каталог
  6) вариант upscale+sharpen (мелкие кадры → ~1400 px, лёгкая подрезка)
   │
   ▼
OcrService.recognizeFromFile()
  ├─ MlKitTextEngine: Text Recognition v2 (latin), модель в APK
  └─ TesseractTextEngine: Tesseract 5 rus+eng, tessdata_best в assets
     многопроходно: {base, sharpen} × psm {3, 4}
     каждый проход — hOCR с x_wconf → средняя уверенность слов
     побеждает проход с макс. (0.7·уверенность + 0.3·длина)
  выбор движка: кириллицу видит только Tesseract;
  у обоих кириллица → более полный текст; чистая латиница → ML Kit
  → OcrResult { fullText, lines[], containsCyrillic, confidence, pass }
  ни один не дал ≥ minChars → OcrException(stage: 'empty') → ручной ввод
  │
  ▼
CardParser.parse()
  линии → извлечение полей по приоритету:
  email → телефон (нормализация E.164) → URL → адрес → должность
  → компания → имя → «прочие строки» (не теряются!)
  │
  ▼
EditCardScreen — человек проверяет/правит; видит предупреждения
  и нераспознанные строки (тап → в заметки)
  │
  ▼
CardRepository.saveDraft() → sqflite (только локально)
```

## 3. Зависимости (pubspec.yaml) и назначение

| Пакет | Версия | Назначение |
|---|---|---|
| camera | ^0.11.0+1 | превью, автофокус, вспышка, съёмка |
| image_picker | ^1.1.2 | выбор фото из галереи |
| google_mlkit_text_recognition | ^0.13.1 | on-device OCR (латиница, модель в APK) |
| flutter_tesseract_ocr | ^0.4.31 | второй OCR-движок (rus+eng), tessdata_best в assets |
| image | ^4.2.0 | предобработка: EXIF, обрезка, контраст, ч/б |
| sqflite | ^2.3.3+1 | локальная БД визиток |
| path_provider | ^2.1.4 | временные каталоги для фото/экспортов |
| flutter_bloc | ^8.1.6 | состояние UI |
| equatable | ^2.0.5 | сравнение состояний |
| get_it | ^8.0.2 | DI / service locator |
| permission_handler | ^11.3.1 | камера, галерея (Android≤12), контакты |
| flutter_contacts | ^1.1.9 | экспорт в контакты устройства |
| share_plus | ^10.1.2 | share-sheet для vCard/CSV |
| intl | ^0.19.0 | форматирование дат |
| uuid | ^4.5.1 | id новых записей |
| path | ^1.9.0 | склейка путей |

Сетевых/http-пакетов **нет**: ни dio, ни http, ни firebase, ни analytics.

## 4. Ключевые классы и сигнатуры

```dart
// lib/data/services/ocr_service.dart
abstract class TextRecognitionEngine {
  Future<OcrResult> recognize(File imageFile);
  Future<void> dispose();
}
class MlKitTextEngine implements TextRecognitionEngine { ... }
class TesseractTextEngine implements TextRecognitionEngine { ... } // rus+eng

class OcrService {
  OcrService({
    TextRecognitionEngine? engine,      // по умолчанию ML Kit
    TextRecognitionEngine? fallback,    // Tesseract rus+eng
    int minChars = 10,                  // порог «пригодного» текста
  });
  Future<OcrResult> recognizeFromFile(String path);
  Future<void> dispose();               // закрывает оба движка
}

class OcrResult {
  final String fullText;
  final List<String> lines;          // порядок чтения
  final bool containsCyrillic;
}

// lib/data/services/image_preprocessor.dart
class ImagePreprocessor {
  Future<PreprocessResult> prepare(String sourcePath, {CropRegion crop});
}

// lib/data/services/card_parser.dart
class CardParser {
  ParsedCard parse(String rawText, {List<String>? ocrLines, bool containsCyrillic});
}

// lib/data/repositories/card_repository.dart
class CardRepository {
  Future<BusinessCard> saveDraft(BusinessCard draft, {String? existingId});
  Future<BusinessCard?> getById(String id);
  Future<List<BusinessCard>> getAll({String? query});
  Future<void> delete(String id);
  Future<int> count();
}

// lib/data/services/export_service.dart
class ExportService {
  String toVCard(BusinessCard card);
  String toCsv(List<BusinessCard> cards);
  Future<XFileResult> shareVCard(BusinessCard card);
  Future<XFileResult> shareCsv(List<BusinessCard> cards);
}

// lib/data/services/contact_export_service.dart
class ContactExportService {
  Future<bool> exportToDeviceContacts(BusinessCard card); // false = отказ в разрешении
}

// lib/business/scan/scan_cubit.dart
class ScanCubit extends Cubit<ScanState> {
  Future<void> processImage(String sourcePath, {CropRegion crop});
  Future<void> retry();
  void reset();
}
```

## 5. Логика парсинга полей

### Телефон (regex + нормализация)

Кандидат: `\+?\d[\d\s\-.()]{5,20}\d|\b\d{6,12}\b`, затем фильтры:
- 7–15 цифр; отбрасываются диапазоны лет `2015 - 2024`;
- признак «телефонность»: есть `+`, разделители `-()` или ≥10 цифр.

Нормализация (E.164, РФ-приоритет):

| Вход | Результат |
|---|---|
| `+7 (999) 123-45-67` | `+79991234567` |
| `8 999 123-45-67` | `+79991234567` |
| `999 123 45 67` | `+79991234567` |
| `(495) 123-45-67` | `+74951234567` |
| `+1 (555) 123-4567` | `+15551234567` |

Если найдено несколько телефонов — берётся лучший по приоритету
(`+7…` → `+…` → первый), UI показывает предупреждение «найдено телефонов: N».

### Email

`[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}` + очистка
конечной пунктуации. Из строки email домен маскируется, чтобы не превратиться в сайт.

### Сайт

- явный `https?://…` / `www.…` — берётся как есть;
- «голый» домен — только с известным TLD **и** с lookahead `(?![a-zA-Z0-9-])`,
  чтобы `ACME Corp.` не стал `acme.co`;
- расширения файлов (`.pdf`, `.jpg` …) отбрасываются.

### Имя

Каждая строка оценивается баллами (`_scoreName`):
- 0 — контакты/адрес/цифры/организационные формы;
- 3 — ровно два слова, каждое с заглавной («Иванов Иван», «Jane Doe»);
- 2 — одно слово с заглавной или три слова с заглавными;
- строка «Имя — Должность» сплитится, имя уходит в кандидаты, должность — в поле.
Побеждает кандидат с максимальным баллом ≥ 2.

### Должность / компания

Подстрочные ключевые словари ru/en:
`менеджер|директор|основатель|…|ceo|cto|founder|head of|senior…` и
`ооо|зао|пао|ип|llc|ltd|inc|corp|gmbh|…` + наличие `«кавычек»`.
Организационная форма в поле должности отрезается.

### Адрес

Токенизация строки и сверка с токенами
`ул|улица|пр|проспект|пер|наб|д|дом|офис|…|street|st|avenue|blvd|suite…`
+ 6-значный почтовый индекс РФ как сильный сигнал.

### Что не распозналось

Все незанятые строки возвращаются в `ParsedCard.unmatchedLines` —
экран редактирования показывает их списком, тап добавляет строку в заметки.
**Ничего не теряется.**

## 6. Обработка ошибок и краевых случаев

| Случай | Поведение |
|---|---|
| Блики / пересвет | предобработка нормализует уровни; UI предупреждает «фото пересвечено — возможны блики» |
| Тени / темнота | normalize + brightness; предупреждение «фото очень тёмное» |
| Поворот текста на карточке | ML Kit устойчив к небольшим углам; EXIF-поворот фото запекается; крупный поворот — подсказка пере-снять |
| Поворот фото телефона | `bakeOrientation` (EXIF) |
| Несколько языков на карточке | парсер ru+en словарями одновременно; кириллица помечается флагом `containsCyrillic` + предупреждение проверить поля |
| Пустой OCR | не авария: экран ручного ввода с подсказкой; предыдущее фото не теряется («Повторить») |
| Нет разрешения на камеру | объяснение + переход в настройки при permanent denial; альтернатива — галерея |
| Файл фото не декодируется | ImageProcessingException → экран ошибки с повтором |
| Сбой БД | DatabaseException с человекочитаемым сообщением |
| Несколько телефонов/email | сохраняется первый по приоритету + предупреждение |
| Выход из экрана камеры в фон | контроллер отпускается (иначе экран захвата «залипает») |
| Пустая карточка | «Сохранить» неактивно |

Все исключения — иерархия `AppException` с полем `userMessage` (RU);
stack trace в UI не показывается.

## 7. Приватность

- **ML Kit on-device**: пакет `google_mlkit_text_recognition` использует
  *on-device API* с моделью латиницы, **встроенной в APK**. Такой API не
  отправляет изображения/текст в облако (Cloud API ML Kit — отдельные
  зависимости, здесь не подключены).
- Доказательство «на месте»:
  1. в `AndroidManifest.xml` нет `INTERNET`-разрешения и Firebase/аналитики —
     приложение физически не может открыть сокет (Android);
  2. `adb shell dumpsys package com.vccontacts.app | grep permission` —
     только CAMERA/CONTACTS/MEDIA;
  3. профилировщик трафика (`adb shell` + tcpdump / Wireshark через
     USB-мост) при съёмке/распознавании — 0 пакетов;
  4. Charles/Proxyman на телефоне — запросов нет;
  5. `flutter pub deps` — в графе нет http-клиентов/SDK аналитики.
- iOS: `NSLocalNetworkUsageDescription` не нужен; Info.plist без
  background modes; ATS не используется, т.к. сетевых вызовов нет.
- Исключено из зависимостей: http/dio, firebase_*, google_sign_in,
  cloud_*, telemetry/аналитика, Crashlytics, Sentry, любые SDK рекламы.

### Кириллица: гибрид ML Kit + Tesseract (реализовано)

ML Kit Text Recognition v2 официально обучен для латиницы, китайского,
японского, корейского и деванагари. **Кириллица не входит в список
поддерживаемых скриптов**: на практике русские визитки дают пустой или
мусорный текст. Поэтому вторым движком добавлен **Tesseract 5**:

- `flutter_tesseract_ocr ^0.4.31` — AAR `tesseract4android` лежит внутри
  пакета (`android/libs/`), сеть на сборке не нужна; бинарь содержит
  **Tesseract 5.5.1** (та же версия, что в апстрим-`tesseract4android:4.8.0`);
- `assets/tessdata/{rus,eng}.traineddata` — **tessdata_best** (~30 МБ на
  оба языка). Дают небольшую, но устойчивую прибавку к качеству на
  печатном тексте и цифрах по сравнению с `tessdata_fast` (~8 МБ);
- `assets/tessdata_config.json` — список файлов для копирования плагином
  в песочницу приложения при первом вызове (офлайн);
- **многопроходный режим**: Tesseract запускается на каждом варианте
  предобработки (`base`, `upscale+sharpen`) с `psm` из набора {3, 4};
  результат каждого прохода — hOCR, из которого берётся средняя
  уверенность слов (`x_wconf`). Победитель выбирается по score =
  `0.7·уверенность + 0.3·нормализованная длина`. Опытным путём на
  тестовых визитках `psm 6`/`psm 11` стабильно давали мусор — исключены;
  `psm 0` (`PSM_AUTO_OSD`, дефолт плагина) возвращает пустоту.

`OcrService` запускает ML Kit и многопроходный Tesseract и выбирает
результат (`_choose`): пустой отбрасывается; если кириллицу нашёл только
один — берётся он; если оба — более длинный текст; для чистой латиницы
приоритет у ML Kit (качество выше). Жёсткий сбой ML Kit не ломает
сценарий, пока Tesseract вернул пригодный текст. Если итог короче
`minChars` (10) символов — `OcrException(stage: 'empty')` и предложение
ручного ввода.

Проверено на тестовых визитках (`testphoto/VC_test.png` — русская
нотариуса, `testphoto/vc_test2.png` — латинский леттерспейсинг):
многопроходный Tesseract на `psm 3` + upscale+sharpen даёт полный текст,
включая ФИО и адрес. Побочно найден и исправлен баг препроцессинга: PNG
с прозрачностью после кодирования в JPEG давал чёрный фон — теперь alpha
композитится на белый.

## 8. Сборка, оптимизация размера, цели

### Флаворы (android/app/build.gradle.kts)

| Флавор | applicationId | GMS | Назначение |
|---|---|---|---|
| `samsung` | `com.vccontacts.app` | да | Samsung S22 и новее (Play services на месте) |
| `huawei` | `com.vccontacts.app.huawei` | нет (флаг `useGms=false`) | Huawei без Google Play services |

On-device ML Kit с вшитой моделью работает и без GMS — базовое
распознавание латиницы на Huawei сохраняется.

### Размер и сжатие

- `--split-per-abi` + `--target-platform android-arm64` — только arm64-v8a
  (S22+, все современные Huawei; по требованию задачи другие ABI не
  собираем). Фактический размер release-APK: **~42.4 МБ** — из них
  ~30 МБ tessdata_best (rus+eng), ~4.9 МБ `libtesseract.so` +
  leptonica, ~11 МБ `libflutter`+`libapp`, ~11 МБ пайплайн ML Kit.
- App Bundle (`.aab`) — по умолчанию **не собирается** (`BUILD_AAB=false`);
  включается `--build-arg BUILD_AAB=true` для Play Store/Huawei
  AppGallery.
- Вынос моделей: латинская модель ML Kit уже в AAR внутри APK,
  traineddata Tesseract — в `assets/` (оба вшиты в APK — это и есть
  гарантия «офлайн после установки»).
- Дальнейшее сжатие: R8/proguard (включено в release Gradle по умолчанию
  в Flutter), `--obfuscate --split-debug-info` для уменьшения кода,
  пересмотр иконки-вектора на PNG по плотностям.

### Docker-сборка

`Dockerfile` — 4 стадии:

1. **toolchain** — Ubuntu 22.04, JDK 17, Android SDK (platform 34,
   build-tools 34; Flutter при сборке может доустановить `platforms;android-35`
   под `flutter_plugin_android_lifecycle` — качает с dl.google.com),
   Flutter 3.24.5 (кэшируется между сборками кода);
2. **code** — `flutter pub get` (отдельный слой под кэш pub), копирование
   исходников, генерация `gradle-wrapper.jar`;
3. **test** — `flutter analyze` + `flutter test` (билд артефактов
   не пойдёт, пока тесты красные);
4. **artifacts** — `flutter build apk --split-per-abi` для
   `samsung` и `huawei` + `appbundle`, артефакты в `/out`.

`build.sh` собирает образ с нужным флавором и копирует содержимое
`/out` в `./apk` на локальном диске (папка `apk/` создана по прямому
указанию; исходное ТЗ task.md называло `build/`):

```bash
./build.sh              # samsung + huawei
./build.sh huawei       # только Huawei
./build.sh --test       # только анализ и тесты
```

## 9. План тестирования на реальных фото

1. **Юнит** (уже в `test/`): парсер на фикстурах — русская/английская
   визитка, форматы телефонов, краевые случаи (годы, pdf, индексы).
2. **Девайсная матрица**: Samsung S22/S23/S24 (Android 14+), Huawei
   P40/Mate 40 (без GMS), старый Huawei с armeabi-v7a, iPhone (iOS 16+).
3. **Фото-матрица** (по 3–5 карточек на кейс):
   - идеальный свет, карточка под 90°;
   - блик от лампы (наклонный), тень от руки;
   - карточка под углом 30–45° (перспектива);
   - матовый/глянцевый ламинат;
   - тёмный фон/светлый фон, мелкий 6pt-шрифт;
   - вертикально и горизонтально снятая карточка;
   - карточка с кириллицей, только латиницей, смешанная (RU+EN);
   - карточка с QR (распознавание полей не должно ломаться);
   - фото из галереи (скан/фото со старого телефона, PNG/JPEG/HEIC).
4. **Сценарии UX**: пустой OCR → ручной ввод; запрет камеры → permanent
   → настройки; экспорт в контакты (дубликаты не создаются при повторе —
   проверить вручную); CSV открывается в Excel с кириллицей (BOM);
   визитка переживает перезапуск приложения.
5. **Приватность**: `tcpdump` на USB-мосте во время полного цикла — 0
   исходящих пакетов; `adb shell` проверка permissions.
6. **Производительность**: время пайплайна ≤ 3 c на S22 (замер через
   логи ScanCubit), память без утечек после 20 сканов подряд.

## 10. Альтернативы и сравнение

| Вопрос | Варианты | Рекомендация |
|---|---|---|
| OCR | **ML Kit v2 on-device** vs Tesseract 5 vs облачные API | **Гибрид**: ML Kit — лучшее качество/скорость на латинице, модель в APK; Tesseract 5 rus+eng — кириллица, многопроходно (варианты × psm, выбор по уверенности), tessdata_best ~30 МБ в APK. Облачные API запрещены ТЗ |
| БД | **sqflite** vs Isar | **sqflite**: стабильная поддержка, SQL-поиск, миграции версий, предсказуемый размер. Isar 3 заморожена (v4 меняет API), выигрыш в скорости для тысяч визиток не критичен |
| Предобработка | **image (Dart)** vs opencv_dart vs нативная обёртка | **image** для MVP: без нативных .so, детерминированная сборка. Для продакшена (авто-поиск границ, дескью/перспектива, морфология против бликов) — OpenCV: `opencv_dart` (ffigen-биндинги, +15–40 МБ .so, нужен strip/раздельные ABI) либо тонкая Kotlin-обёртка над `Imgproc` через MethodChannel (минимальный размер, но поддержка двух платформ дороже). Интерфейс `ImagePreprocessor` позволяет подменить движок без правок UI |
| Навигация | Navigator vs go_router | Для 6 экранов — Navigator 1.0 (меньше зависимостей). При росте числа экранов/диплинков — go_router |
| Состояние | flutter_bloc vs provider/riverpod | **flutter_bloc**: явные состояния, тестируемые cubit'ы, командный стандарт |

## 11. План MVP (пошагово)

1. **Каркас**: pubspec, тема, DI, модель `BusinessCard`, sqflite-схема.
2. **Пайплайн без UI**: `ImagePreprocessor` → `OcrService` (ML Kit + Tesseract) →
   `CardParser` + юнит-тесты парсера на фикстурах.
3. **Съёмка**: CameraScreen (разрешения, превью, затвор, вспышка),
   CropScreen, ScanFlowScreen (прогресс).
4. **Проверка**: EditCardScreen (поля, предупреждения, unmatched-строки),
   сохранение через CardRepository.
5. **Список и детали**: CardsListScreen (поиск, удаление), CardDetailScreen.
6. **Экспорт**: vCard + CSV + share, затем `flutter_contacts` с разрешениями.
7. **Полировка**: ошибки/краевые случаи (§6), предупреждение о кириллице.
8. **Сборка**: Android-флаворы samsung/huawei, Dockerfile + build.sh,
   --split-per-abi + AAB.
9. **iOS**: `flutter create . --platforms=ios`, Info.plist (камера,
   NSPhotoLibraryUsageDescription), сборка через Xcode.
10. После MVP: OpenCV-препроцессинг, Tesseract для кириллицы, обложка
    с фото на карточке в списке.

## 12. Чеклист перед релизом

- [ ] Все разрешения запрашиваются с rationale и не ломают UX при отказе
- [ ] `flutter analyze` — 0 issues, все тесты зелёные
- [ ] Release-подпись (keystore) вместо debug-ключа; ключ — в CI-secrets
- [ ] `--obfuscate --split-debug-info` для release-сборки, debug-символы не в APK
- [ ] Проверено: приложение работает в авиарежиме от начала до конца
- [ ] tcpdump/proxy-снiffer: 0 сетевых пакетов при полном цикле
- [ ] `adb shell dumpsys package` — только нужные permissions
- [ ] APK arm64 ≤ 35 МБ; размер установлен на S22 и Huawei
- [ ] Huawei-сборка установлена на устройство без GMS — OCR работает
- [ ] Экспорт в контакты: контакт не дублируется, все поля на месте
- [ ] CSV открывается в Excel/Numbers с кириллицей
- [ ] Пустой OCR, битое фото, запрет камеры — обработаны, без крашей
- [ ] Фоновое переключение из камеры и обратно — превью восстанавливается
- [ ] Data Safety (Google Play) и Privacy Nutrition Labels (Apple) —
      «данные не собираются/не отправляются»
- [ ] Политика приватности: одно предложение «все данные остаются на устройстве»
- [ ] Скриншоты и описание для магазинов (офлайн-фича подчёркнута)
- [ ] versionCode/versionName выставлены; AAB протестирован через
      internal testing track
