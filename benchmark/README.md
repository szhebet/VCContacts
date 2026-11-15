# Бенчмарки OCR

Два независимых замера:

| Стенд | Что меряет | Команда |
|---|---|---|
| `ocr_benchmark_test.dart` | полнокадровый резерв (Tesseract на хосте) на 4 фото | `flutter test benchmark/ocr_benchmark_test.dart` |
| `device_benchmark_test.dart` | парсер на реальных `result.json` с устройства | `flutter test benchmark/device_benchmark_test.dart` |

Результаты складываются в `results.csv` и `results_device.csv`
(колонки `change_number,score,description,fixes`).

## Локальные данные (в git не попадают)

Фото визиток и эталоны — персональные данные, поэтому они в `.gitignore`:

- `corpus/` — фотографии для полнокадрового стенда;
- `expected.json` — эталонные поля к ним;
- `device_corpus/` — реальные `result.json` с устройства;
- `device_expected.json` — эталонные поля для device-replay;
- `last_run*.json` — сгенерированные отчёты.

Чтобы запустить стенды локально:

```bash
cp benchmark/expected.example.json benchmark/expected.json
mkdir -p benchmark/corpus && cp /путь/к/фото/*.jpg benchmark/corpus/
# отредактируйте expected.json под свои фото

cp benchmark/device_expected.example.json benchmark/device_expected.json
mkdir -p benchmark/device_corpus
# положите туда result.json из Download/VCContacts/diagnostics/<штамп>/
```

Если данных нет — тесты просто пропускаются (печатают пояснение), сборка
и остальные тесты не страдают.

## Что эти стенды принципиально не проверяют

- **Детекцию границ визитки и `warpPerspective` (OpenCV).**
  `ocr_benchmark_test.dart` создаёт `ImagePreprocessor(detector: null,
  detectCard: false)` и подаёт уже подготовленные фото — `CardDetector`
  в нём не вызывается. Поэтому регрессия в поиске контура/повороте
  не меняет `results.csv` (исторически он оставался 95.8 даже когда
  устройство распознавало карточки плохо).
- **Полный device-пайплайн (ML Kit layout → области → ориентация).**
  `device_benchmark_test.dart` читает готовый `full_text` из `result.json`
  и прогоняет только `CardParser`; изображения и препроцессор не
  участвуют.

Изменения в `CardDetector`/`ImagePreprocessor` нужно проверять на
устройстве: просканировать 3–5 карточек под разными углами и посмотреть
в `summary.txt` строку «Визитка выпрямлена» и `auto_warped` в
`result.json`. Для автоматизации такого прогона нужен device/integration
тест — на хосте Linux нативная библиотека OpenCV из APK недоступна.

## Внутренние тесты

```bash
flutter test                       # все юнит-тесты
flutter analyze
```
