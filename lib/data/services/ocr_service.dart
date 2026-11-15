import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../core/errors/app_exceptions.dart';
import 'block_consensus.dart';
import 'card_image_tools.dart';
import 'field_segmenter.dart';
import 'image_region_detector.dart';
import 'layout_analyzer.dart';

/// Слово с позицией на изображении (для вырезания области поля в
/// диагностике и для адресного апскейла мелкого текста).
class OcrWord {
  const OcrWord({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.confidence = 0.0,
    this.lineIndex = 0,
  });

  final String text;
  final int left;
  final int top;
  final int right;
  final int bottom;
  final double confidence;

  /// Номер строки, к которой относится слово (в порядке чтения).
  final int lineIndex;

  int get width => right - left;
  int get height => bottom - top;
}

/// Результат распознавания: чистый текст и построчные блоки.
class OcrResult {
  const OcrResult({
    required this.fullText,
    required this.lines,
    this.containsCyrillic = false,
    this.diagnostic,
    this.confidence = 0.0,
    this.pass = '',
    this.words = const [],
    this.hocr = '',
    this.linesAreFinal = false,
    this.sourcePath = '',
    this.orientationDegrees = 0,
    this.tiltDegrees = 0,
    this.deskewApplied = false,
  });

  final String fullText;

  /// Строки в порядке чтения (сверху вниз, слева направо) —
  /// именно из них parser восстанавливает структуру визитки.
  final List<String> lines;

  /// Признак кириллицы в тексте: ML Kit v2 официально обучен для
  /// латиницы, кириллица распознаётся частично — UI показывает
  /// подсказку проверить поля вручную (см. ARCHITECTURE.md).
  final bool containsCyrillic;

  /// Пошаговая диагностика прохода (для экрана «Диагностика OCR»),
  /// может быть null, если результат построен вручную (тесты).
  final OcrDiagnostic? diagnostic;

  /// Средняя уверенность распознавания (0..1). Для ML Kit — эвристика,
  /// для Tesseract — средний x_wconf. По ней выбирается лучший проход.
  final double confidence;

  /// Метка прохода («вариант × psm») — для диагностики.
  final String pass;

  /// Слова с координатами (только Tesseract hOCR; у ML Kit пока пусто).
  final List<OcrWord> words;

  /// Сырой hOCR-дамп прохода (только Tesseract) — для выгрузки в файл
  /// при расширенной диагностике.
  final String hocr;

  /// Строки уже финальные: повторная сборка строк из слов (по
  /// уверенности) выбросила бы текст, восстановленный при нарезке на
  /// сегменты. Ставится результатом сегментного прохода.
  final bool linesAreFinal;

  /// Файл-источник этого прохода (путь к картинке, которую читал OCR).
  /// Нужен для выгрузки диагностики: координаты слов относятся именно к
  /// этому кадру — после поворота это уже другой файл.
  final String sourcePath;

  /// На сколько градусов по часовой стрелке повёрнут кадр этого прохода,
  /// чтобы текст стал горизонтальным (0/90/180/270). Ноль — кадр читался
  /// как есть. Нужен для диагностики на устройстве: OSD через плагин
  /// Tesseract недоступен, ориентация определяется по hOCR.
  final int orientationDegrees;

  /// Наклон строк до выпрямления (градусы, по часовой стрелке). Ноль —
  /// заметного наклона не было. Значение нужно, чтобы так же выпрямить
  /// сохранённое фото визитки.
  final double tiltDegrees;

  /// Был ли весь кадр выпрямлен на [tiltDegrees] перед нарезкой областей.
  /// Если да, координаты слов/областей уже относятся к выпрямленному
  /// кадру — при позиционировании фото их нельзя поворачивать второй раз.
  final bool deskewApplied;

  bool get isEmpty => fullText.trim().isEmpty;

  /// Есть ли кириллица в тексте — используется для выбора движка.
  static bool hasCyrillic(String text) => _cyrillic.hasMatch(text);

  static final _cyrillic = RegExp(r'[а-яА-ЯёЁ]');
}

/// OCR-сервис: только on-device, без облачных API.
/// Реализация построена на Google ML Kit Text Recognition v2
/// (пакет google_mlkit_text_recognition), модель латиницы вшита в APK.
///
/// Замена движка (Tesseract и т.п.) — через реализацию [TextRecognitionEngine],
/// интерфейс ниже изолирует UI/бизнес-логику от конкретного SDK.
abstract class TextRecognitionEngine {
  /// [pageSegMode] и [variable] — настройки Tesseract (psm, пользовательские
  /// переменные); ML Kit их игнорирует. Многопроходный режим перебирает
  /// комбинации вариант × psm и выбирает лучший результат по confidence.
  /// [language] — переопределение языка для Tesseract (рус/англ/оба).
  Future<OcrResult> recognize(
    File imageFile, {
    int pageSegMode = 3,
    String variable = '',
    String? language,
  });
  Future<void> dispose();
}

/// Итог работы одного движка/прохода — для экрана диагностики.
class EngineDiagnostic {
  const EngineDiagnostic({
    required this.name,
    this.error,
    this.lineCount = 0,
    this.charCount = 0,
    this.hasCyrillic = false,
    this.preview = '',
    this.confidence = 0.0,
  });

  final String name;
  final String? error;
  final int lineCount;
  final int charCount;
  final bool hasCyrillic;

  /// Первые символы распознанного текста (для быстрой оценки качества).
  final String preview;
  final double confidence;

  bool get failed => error != null;
  bool get empty => !failed && charCount == 0;
}

/// Диагностика всего прохода OCR: что вернул каждый движок, кого выбрали.
/// Замер времени этапа OCR
class OcrStageTiming {
  const OcrStageTiming(this.stage, this.milliseconds);

  final String stage;
  final int milliseconds;

  /// Человекочитаемая подпись: миллисекунды или секунды.
  String get label {
    if (milliseconds < 1000) return '$stage: $milliseconds мс';
    return '$stage: ${(milliseconds / 1000).toStringAsFixed(2)} с';
  }
}

/// Статистика по одной текстовой области (после нарезки ML Kit).
class OcrRegionStat {
  const OcrRegionStat({
    required this.index,
    required this.source,
    required this.language,
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.confidence = 0.0,
  });

  /// `tesseract` — область распознана en-rus моделью и зафиксирована,
  /// `mlkit` — английскую область перераспознал ML Kit.
  final String source;

  /// `ru`, `en`, `mixed` или `unknown`.
  final String language;

  final String text;
  final int index;
  final int left;
  final int top;
  final int right;
  final int bottom;
  final double confidence;

  int get chars => text.trim().length;
}

/// Геометрия и результаты предобработки областей.
class OcrGeometryStat {
  const OcrGeometryStat({
    required this.medianAngleDegrees,
    required this.regionsTotal,
    required this.regionsMlKit,
    required this.regionsRectified,
    required this.imageRegions,
    this.rotationApplied = false,
    this.orientationDegrees = 0,
  });

  final double medianAngleDegrees;
  final int regionsTotal;

  /// Сколько областей зафиксировано по результату ML Kit (английские).
  final int regionsMlKit;

  /// Сколько областей распознано Tesseract (русские/смешанные).
  final int regionsRectified;

  /// Сколько областей-картинок (логотипов) выбелено.
  final int imageRegions;

  /// Был ли повёрнут весь кадр для устранения наклона.
  final bool rotationApplied;

  /// На сколько градусов кадр повёрнут перед разметкой, чтобы текст стал
  /// горизонтальным (0/90/180/270). Отличается от [rotationApplied]:
  /// там — мелкий наклон, здесь — поворот «боком/вверх ногами».
  final int orientationDegrees;
}

class OcrDiagnostic {
  const OcrDiagnostic({
    required this.engines,
    this.chosen,
    this.chosenChars = 0,
    this.timings = const [],
    this.regions = const [],
    this.geometry,
    this.imageBoxes = const [],
    this.englishRegions = const [],
  });

  final List<EngineDiagnostic> engines;
  final String? chosen;
  final int chosenChars;
  final List<OcrStageTiming> timings;

  /// Что стало с каждой текстовой областью: движок, язык, текст, bbox.
  final List<OcrRegionStat> regions;

  /// Наклон, число областей, найденные картинки.
  final OcrGeometryStat? geometry;

  /// Выбеленные области картинок в координатах рабочего кадра.
  final List<ImageBox> imageBoxes;

  /// Английские строки, перераспознанные ML Kit и зафиксированные.
  final List<String> englishRegions;
}

/// Движок ML Kit (по умолчанию).
class MlKitTextEngine implements TextRecognitionEngine {
  MlKitTextEngine({TextRecognizer? recognizer})
      : _recognizer =
            recognizer ?? TextRecognizer(script: TextRecognitionScript.latin);

  final TextRecognizer _recognizer;

  @override
  Future<OcrResult> recognize(
    File imageFile, {
    int pageSegMode = 3,
    String variable = '',
    String? language,
  }) async {
    final inputImage = InputImage.fromFilePath(imageFile.path);
    try {
      final recognized = await _recognizer.processImage(inputImage);

      // Сохраняем порядок чтения: блоки ML Kit уже отсортированы,
      // внутри блока — строки.
      final lines = <String>[
        for (final block in recognized.blocks)
          for (final line in block.lines) line.text,
      ].where((l) => l.trim().isNotEmpty).toList(growable: false);

      // ML Kit не отдаёт числовую уверенность: оцениваем эвристикой —
      // доля слов длиной ≥ 3 символов (короткие артефакты не в счёт)
      // и непустота. Значение нужно только для сравнения проходов.
      final words = lines.expand((l) => l.split(RegExp(r'\s+'))).toList();
      final good = words.where((w) => w.length >= 3).length;
      final confidence = words.isEmpty ? 0.0 : good / words.length;

      return OcrResult(
        fullText: recognized.text,
        lines: lines,
        containsCyrillic: OcrResult._cyrillic.hasMatch(recognized.text),
        confidence: confidence,
        pass: 'ML Kit',
        sourcePath: imageFile.path,
      );
    } on Exception catch (e) {
      throw OcrException(
        'ML Kit не смог распознать изображение: $e',
        userMessage: 'Не удалось распознать текст на фото',
        cause: e,
        stage: 'process',
      );
    }
  }

  @override
  Future<void> dispose() => _recognizer.close();
}

/// Фасад над движками. Основной — ML Kit (латиница, лучшее качество),
/// резервный — Tesseract rus+eng (см. [TesseractTextEngine], т.к. ML Kit
/// latin не обучен для кириллицы и на русских визитках возвращает пустоту).
/// Оба результата оцениваются [_choose]: выигрывает тот, кто увидел
/// кириллицу и дал более полный текст.
class OcrService {
  OcrService({
    TextRecognitionEngine? engine,
    TextRecognitionEngine? fallback,
    LayoutAnalyzer? layoutAnalyzer,
    ImageRegionDetector? imageRegionDetector,
    this.minChars = 10,
    this.tesseractPageSegModes = const [3, 4],
    this.segmenter = const FieldSegmenter(),
    this.consensus = const BlockConsensus(),
    this.enableRegionPipeline = true,
    this.regionPageSegMode = 7,
    this.tiltThresholdDegrees = 5.0,
  })  : _engine = engine ?? MlKitTextEngine(),
        _fallback = fallback,
        _layoutAnalyzer = layoutAnalyzer,
        _imageRegions = imageRegionDetector ?? const ImageRegionDetector();

  final TextRecognitionEngine _engine;
  final TextRecognitionEngine? _fallback;

  /// Разметка текста ML Kit: наклон кадра, текстовые области и их
  /// четырёхугольники. Без него работает только полнокадровый режим.
  final LayoutAnalyzer? _layoutAnalyzer;

  /// Детектор картинок/логотипов: найденные области выбеливаются до OCR.
  final ImageRegionDetector _imageRegions;

  /// Сегментатор мелкого текста: по bbox слов из базового прохода режет
  /// изображение на блоки и перераспознаёт их с апскейлом.
  final FieldSegmenter segmenter;

  /// Кворум заключений по блоку: выбирает лучший результат среди вариантов
  /// предобработки (базовый/резкий/бинаризованный) по уверенности и согласию
  /// проходов друг с другом.
  final BlockConsensus consensus;

  /// Результат короче этого числа символов непригоден: из него не
  /// соберутся поля и не будут показаны «Прочие строки».
  final int minChars;

  /// Режимы сегментации страницы Tesseract для многопроходного режима.
  /// 3 (авто) — рабочий для визиток с логотипом и разрозненными блоками;
  /// 4 (единый столбец) — иногда полнее на плотном тексте. Опытным путём
  /// на тестовых визитках psm 6 и 11 стабильно давали мусор, поэтому
  /// не включены (лишнее время на телефоне).
  final List<int> tesseractPageSegModes;

  /// Включён ли режим областей (ML Kit разметка → нарезка → Tesseract
  /// en-rus → ML Kit для английских полей). Выключено — сразу
  /// полнокадровый режим (отладка).
  final bool enableRegionPipeline;

  /// psm для отдельной строки-области: 7 — «одна текстовая строка».
  final int regionPageSegMode;

  /// Минимальный наклон строк (градусы), при котором весь кадр
  /// поворачивается до нарезки областей. До этого порога наклон
  /// компенсируется при вырезании каждой области, а поворот всего кадра
  /// только тратит время.
  final double tiltThresholdDegrees;

  /// Распознаёт изображение. [variants] — дополнительные варианты
  /// предобработки того же кадра (см. ImagePreprocessor): каждый
  /// прогоняется через Tesseract, лучший по уверенности побеждает.
  ///
  /// [segmentSource] — цветной кадр (тот же ракурс, что и у вариантов):
  /// из него вырезаются сегменты, и коррекция цвета каждого сегмента
  /// считается по его собственным пикселям. В режиме областей он же
  /// служит кадром для ML Kit разметки, выпрямления и коррекции цвета.
  ///
  /// [allowOrientationRetry] и [rotationDegrees] — внутренние: повторный
  /// вызов на повёрнутом кадре не должен снова искать поворот, а угол
  /// накапливается для диагностики.
  Future<OcrResult> recognizeFromFile(
    String path, {
    List<String> variants = const [],
    String? segmentSource,
    bool allowOrientationRetry = true,
    int rotationDegrees = 0,
  }) async {
    final timings = <OcrStageTiming>[];
    int ms() => DateTime.now().millisecondsSinceEpoch;

    final file = File(path);
    if (!await file.exists()) {
      throw OcrException(
        'Файл изображения не найден: $path',
        userMessage: 'Файл фото не найден',
        stage: 'init',
      );
    }

    // 0. Режим областей (основной для визиток):
    //    наклон всего кадра → маскировка логотипов → нарезка текстовых
    //    областей ML Kit → коррекция цвета/размера → en-rus Tesseract,
    //    английские области перераспознаются ML Kit.
    //    Любой сбой не фатален: ниже остаётся полнокадровый резерв.
    final source = segmentSource == null ? null : File(segmentSource);
    if (enableRegionPipeline &&
        _layoutAnalyzer != null &&
        _fallback != null &&
        source != null &&
        await source.exists()) {
      try {
        final regionResult = await _recognizeRegions(source);
        if (regionResult != null) return regionResult;
        debugPrint('[OCR] режим областей дал мусор — полнокадровый резерв');
      } on Object catch (e) {
        debugPrint('[OCR] режим областей не удался ($e), полный кадр');
      }
    }

    // 1. ML Kit — основной движок (лучшее качество на латинице).
    OcrResult? primary;
    Object? primaryError;
    final tMl = ms();
    try {
      primary = await _engine.recognize(file);
    } catch (e) {
      primaryError = e;
    }
    timings.add(OcrStageTiming('ML Kit', ms() - tMl));

    // 2. Tesseract — многопроходно: варианты × psm, выбор по уверенности.
    final fallback = _fallback;
    final passDiagnostics = <EngineDiagnostic>[];
    final variantFiles = <String>[
      file.path,
      ...variants.where((v) => v != path)
    ];
    final tTess = ms();
    // Меньше проходов = быстрее. psm4 часто даёт 0 на части вариантов.
    final passes = await _tesseractPasses(variantFiles, passDiagnostics);
    timings.add(OcrStageTiming('Tesseract (все проходы)', ms() - tTess));
    var secondary = _pickBestTesseract(passes);
    var effectiveVariants = variantFiles;
    var effectiveSegmentSource = segmentSource;

    // Повёрнутые кадры — временные файлы: удаляем их после прогона.
    // Кадр, по которому в итоге распознан текст, оставляем: к нему
    // привязаны координаты слов, и из него диагностика вырезает поля.
    final tempFiles = <String>[];
    String? keepSource;
    try {
      // 3. Ориентация текста. Геометрия карточки (CardDetector) исправляет
      //    только наклон и перспективу, а кадр «боком»/вверх ногами
      //    остаётся. OSD Tesseract через плагин недоступен: плагин отдаёт
      //    GetUTF8Text(), который для PSM_OSD_ONLY пуст (отчёт OSD есть
      //    только у GetOsdText()). Поэтому ориентацию определяем по hOCR:
      //    у боком снятого текста строки вертикальные (bbox выше, чем
      //    шире).
      //
      //    Схема в два шага. Шаг 1 — дешёвый: поворачиваем базовый кадр на
      //    90/180/270 и одним проходом ищем угол, на котором строки
      //    становятся горизонтальными. Шаг 2 — если угол найден, кадр
      //    поворачивается целиком (все варианты и цветной источник), и
      //    полный пайплайн повторяется уже на нём: так сохраняются
      //    варианты предобработки, сегментация и ML Kit — иначе один
      //    проход по повёрнутому JPEG теряет мелкие поля (цифры телефона,
      //    второй e-mail).
      // Tesseract не дал текста, а ML Kit дал (пусть и мусорный): кадр
      // может быть повёрнут — Tesseract на боковом/перевёрнутом кадре
      // возвращает пустоту, а ML Kit латиницей «читает» кириллицу как
      // похожие латинские буквы. Проверяем все положения.
      final noTesseractText = secondary == null || secondary.isEmpty;
      final hasPrimaryText = primary != null && !primary.isEmpty;
      if (allowOrientationRetry &&
          fallback != null &&
          (_needsOrientationRetry(secondary) ||
              (noTesseractText && hasPrimaryText))) {
        final tRot = DateTime.now().millisecondsSinceEpoch;
        // Строки уже дают ось: вертикальные — кадр боком (90/270),
        // горизонтальные — остаётся проверить только 180. Без hOCR
        // (Tesseract пуст) ось неизвестна — проверяем все четыре.
        final angle = await _detectRotation(
          file.path,
          secondary,
          tempFiles,
          candidates: noTesseractText
              ? null
              : (_horizontalFraction(secondary) < 0.6
                  ? const [90, 270]
                  : const [180]),
        );
        timings.add(OcrStageTiming(
          'Ориентация (пробник)',
          DateTime.now().millisecondsSinceEpoch - tRot,
        ));
        if (angle != 0) {
          final rotatedVariants =
              await _rotateMany(variantFiles, angle, tempFiles);
          final rotatedSource = segmentSource == null
              ? null
              : await _rotateToTemp(segmentSource, angle, tempFiles);
          if (rotatedVariants.isNotEmpty) {
            debugPrint('[OCR] ориентация: поворот $angle°, '
                'полный повтор пайплайна');
            final result = await recognizeFromFile(
              rotatedVariants.first,
              variants: rotatedVariants.skip(1).toList(),
              segmentSource: rotatedSource,
              allowOrientationRetry: false,
              rotationDegrees: (rotationDegrees + angle) % 360,
            );
            keepSource = result.sourcePath;
            // Тайминги внешнего пробника добавляем к отчёту повторного
            // прогона, иначе в диагностике не видно его стоимость.
            return _mergeTimings(result, timings);
          }
        }
      }

      // 4. Сегментация: мелкий/неуверенный текст перераспознаём по блокам
      // с апскейлом. Работает поверх лучшего прохода Tesseract, у которого
      // есть bbox слов (hOCR). Ошибки не фатальны — базовый результат уже есть.
      OcrResult? segmented;
      if (fallback != null &&
          secondary != null &&
          secondary.words.isNotEmpty &&
          !secondary.isEmpty &&
          _shouldSegment(secondary)) {
        final tSeg = DateTime.now().millisecondsSinceEpoch;
        segmented = await _segmentPass(
          variantFiles: effectiveVariants,
          segmentSource: effectiveSegmentSource,
          base: secondary,
          engine: fallback,
        );
        timings.add(OcrStageTiming('Сегментация/consensus',
            DateTime.now().millisecondsSinceEpoch - tSeg));
        if (segmented != null) {
          passDiagnostics.add(_engineDiagnostic(
            'Tesseract сегменты (ков ${(segmented.confidence * 100).round()})',
            segmented,
            null,
          ));
        }
      }

      final secondaryBest = _pickBestTesseract([
        if (secondary != null) secondary,
        if (segmented != null) segmented,
      ]);

      // Диагностика в logcat (без данных с фото: только метрики).
      debugPrint('[OCR] ML Kit: ${_describe(primary)} '
          '${primaryError == null ? '' : 'ошибка=$primaryError'}');
      debugPrint('[OCR] Tesseract проходов=${passes.length}, лучший: '
          '${secondaryBest?.pass ?? '—'} '
          '(уверенность=${secondaryBest?.confidence.toStringAsFixed(2) ?? '—'})');

      final best = _choose(primary, secondaryBest);
      debugPrint('[OCR] выбран: ${best?.pass ?? '—'}, '
          'символов=${best?.fullText.length ?? 0}');

      final diagnostic = OcrDiagnostic(
        engines: [
          _engineDiagnostic('ML Kit (latin)', primary, primaryError),
          ...passDiagnostics,
        ],
        chosen: best?.pass,
        chosenChars: best?.fullText.length ?? 0,
        timings: timings,
      );

      if (best != null && best.fullText.trim().length >= minChars) {
        // Чистим итог от мусора. Сначала — по уверенности слов (если проход
        // дал bbox: сюда попадают осколки логотипа/фона с x_wconf ~0.05–0.3),
        // затем — по составу строк. Если чистка съела бы весь текст —
        // оставляем исходный, чтобы не потерять редкий валидный результат.
        // Для сегментного прохода строки уже финальные: пересборка по словам
        // выбросила бы восстановленный текст (см. [OcrResult.linesAreFinal]).
        final baseLines = best.linesAreFinal
            ? best.lines
            : (_cleanByWordConfidence(best) ?? best.lines);
        final cleaned = _cleanLines(baseLines);
        final lines = cleaned.isEmpty ? best.lines : cleaned;
        keepSource = best.sourcePath;
        _logTimings(diagnostic);
        return OcrResult(
          fullText: lines.join('\n'),
          lines: lines,
          containsCyrillic: best.containsCyrillic,
          diagnostic: diagnostic,
          confidence: best.confidence,
          pass: best.pass,
          words: best.words,
          hocr: best.hocr,
          linesAreFinal: best.linesAreFinal,
          sourcePath: best.sourcePath,
          orientationDegrees:
              (best.orientationDegrees + rotationDegrees) % 360,
        );
      }

      // Пригодного текста нет ни у одного движка. Жёсткая ошибка движка
      // (не «пусто») важнее: по ней UI предложит повторить снимок,
      // а не уводить в ручной ввод.
      final hardErrors = [
        primaryError,
      ].whereType<OcrException>().where((e) => e.stage != 'empty');
      if (hardErrors.isNotEmpty) {
        final e = hardErrors.first;
        throw OcrException(
          e.message,
          userMessage: e.userMessage,
          cause: e.cause,
          stage: e.stage,
          diagnostic: diagnostic,
        );
      }

      throw OcrException(
        'OCR вернул пустой текст',
        userMessage: 'Текст не распознан. Попробуйте фото поярче или '
            'заполните карточку вручную',
        stage: 'empty',
        diagnostic: diagnostic,
      );
    } finally {
      // Повёрнутые кадры — временные: убираем, чтобы не копить мусор.
      // Оставляем только тот, по которому распознан итоговый текст.
      for (final f in tempFiles) {
        if (f == keepSource) continue;
        try {
          final file = File(f);
          if (await file.exists()) await file.delete();
        } on Object {
          // Не смогли удалить — не критично (файл во временном каталоге).
        }
      }
    }
  }

  // ---------------------------------------------------------------------
  // Режим областей: ML Kit разметка → нарезка → en-rus Tesseract → ML Kit
  // ---------------------------------------------------------------------

  /// Основной пайплайн для визитки.
  ///
  /// Порядок (как в задаче):
  ///  1. корректировка наклона всего изображения по средней линии строк;
  ///  2. маскировка логотипов/картинок — их текст не должен попадать в OCR;
  ///  3. нарезка текстовых областей по четырёхугольникам ML Kit;
  ///  4. выпрямление перспективы, коррекция цвета и размера каждой области;
  ///  5. проход en-rus моделью (Tesseract `rus+eng`, psm=7 на строку);
  ///  6. русские/смешанные поля фиксируются, английские перераспознаются
  ///     ML Kit и тоже фиксируются.
  /// Возвращает null, если разметка/распознавание дали мусор: вызывающий
  /// код тогда прогоняет полнокадровый резерв (в нём есть определение
  /// ориентации и выбор лучшего прохода).
  Future<OcrResult?> _recognizeRegions(File source) async {
    final totalWatch = Stopwatch()..start();
    final timings = <OcrStageTiming>[];

    var watch = Stopwatch()..start();
    final decoded = img.decodeImage(await source.readAsBytes());
    timings.add(_timing('декодирование кадра', watch));
    if (decoded == null) {
      throw OcrException(
        'Не удалось прочитать изображение: ${source.path}',
        userMessage: 'Файл фото повреждён',
        stage: 'init',
      );
    }

    // 1. Поиск картинок (логотипы, эмблемы, плашки). Только детекция:
    //    маскировка будет после разметки ML Kit — по ней видно, где текст,
    //    а текст затирать нельзя.
    watch = Stopwatch()..start();
    final imageBoxes = _imageRegions.detect(decoded);
    timings.add(_timing('поиск картинок', watch));

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final tempDir = await Directory.systemTemp.createTemp('vc_ocr_regions_');
    final intermediates = <String>[];
    var workingPath = source.path;
    try {
      // 2. Разметка ML Kit по исходному (немаскированному) кадру.
      watch = Stopwatch()..start();
      var layout = await _layoutAnalyzer!.analyze(File(workingPath));
      timings.add(_timing('ML Kit разметка', watch));
      if (layout.isEmpty) {
        throw const OcrException(
          'ML Kit не нашёл текстовых областей',
          userMessage: 'Текст не распознан. Попробуйте фото поярче',
          stage: 'empty',
        );
      }

      // 2a. Маскировка картинок, не задевая текст. Эвристика по пикселям
      //     принимает крупные жирные буквы за «залитую графику» и раньше
      //     выбеливала их вместе с частью слова (НОТАРИУС → НОТ РИУ,
      //     СТРОЕНИЕ → ТРОЕНИЕ). Маленький бокс, почти целиком лежащий
      //     внутри строки ML Kit, — это буква; крупный логотип оставляем.
      watch = Stopwatch()..start();
      final maskBoxes = _dropTextBoxes(
        imageBoxes,
        layout,
        decoded.width,
        decoded.height,
      );
      var working = decoded;
      if (maskBoxes.isNotEmpty) {
        working = _imageRegions.mask(decoded, maskBoxes);
        workingPath = p.join(source.parent.path, 'ocr_${stamp}_regions.jpg');
        intermediates.add(workingPath);
        await File(workingPath)
            .writeAsBytes(img.encodeJpg(working, quality: 92));
      }
      timings.add(_timing('маскировка картинок', watch));

      // 2b. Ориентация по разметке. ML Kit находит текст и на повёрнутой
      //     визитке, поэтому разметка сама по себе не говорит, что кадр
      //     снят боком/вверх ногами — а от этого зависят порядок областей
      //     (поля перемешиваются: телефон уезжает в компанию) и качество
      //     вырезок. Зато геометрия строк задаёт ось: вертикальные строки
      //     (bbox выше, чем шире, или `line.angle` ~±90) — кадр боком,
      //     иначе остаются только 0/180. Пробник Tesseract на 900 px
      //     проверяет два положения вместо четырёх.
      var orientationDegrees = 0;
      watch = Stopwatch()..start();
      final sideways = _isSideways(layout);
      final orientationAngle = await _detectRotation(
        source.path,
        null,
        intermediates,
        probeSide: 900,
        candidates: sideways ? const [90, 270] : const [0, 180],
        // Кадр уже декодирован — не декодируем его заново на каждый угол.
        sourceImage: decoded,
      );
      if (orientationAngle != 0) {
        final rotated = _rotateForDeskew(working, orientationAngle.toDouble());
        final rotatedPath = p.join(
            source.parent.path, 'ocr_${stamp}_rot$orientationAngle.jpg');
        intermediates.add(rotatedPath);
        await File(rotatedPath)
            .writeAsBytes(img.encodeJpg(rotated, quality: 100));
        try {
          final relayout = await _layoutAnalyzer.analyze(File(rotatedPath));
          if (!relayout.isEmpty) {
            working = rotated;
            workingPath = rotatedPath;
            layout = relayout;
            orientationDegrees = orientationAngle;
          }
        } on Object catch (e) {
          debugPrint('[OCR] разметка после поворота не удалась: $e');
        }
      } else if (sideways) {
        // Tesseract на телефонных фото «боком» может не прочитать ничего
        // (блик, перспектива, мелкий текст). Тогда направление берём по
        // разметке ML Kit: пробуем 90 и 270 и оставляем тот поворот, где
        // строки стали горизонтальными и первая строка оказалась сверху
        // (ML Kit отдаёт блоки в порядке чтения).
        for (final angle in const [90, 270]) {
          final rotated = _rotateForDeskew(working, angle.toDouble());
          final rotatedPath =
              p.join(source.parent.path, 'ocr_${stamp}_rot$angle.jpg');
          intermediates.add(rotatedPath);
          await File(rotatedPath)
              .writeAsBytes(img.encodeJpg(rotated, quality: 100));
          try {
            final relayout = await _layoutAnalyzer.analyze(File(rotatedPath));
            if (relayout.isEmpty || _isSideways(relayout)) continue;
            if (!_startsAtTop(relayout, rotated.height)) continue;
            working = rotated;
            workingPath = rotatedPath;
            layout = relayout;
            orientationDegrees = angle;
            debugPrint('[OCR] ориентация по разметке: поворот $angle°');
            break;
          } on Object catch (e) {
            debugPrint('[OCR] разметка после поворота $angle° не удалась: $e');
          }
        }
      }
      timings.add(_timing('ориентация кадра', watch));

      // 3. Глобальный наклон. Небольшой наклон (до ~5°) можно не трогать:
      //    каждая область вырезается по своему четырёхугольнику ML Kit
      //    (copyRectify), и наклон строки исправляется при нарезке. Но при
      //    сильном наклоне (визитка снята под углом) ломается порядок
      //    чтения: ML Kit группирует строки по горизонтали, поля
      //    перемешиваются, а bbox раздуваются. Такой кадр выпрямляем
      //    целиком и заново размечаем — области становятся почти
      //    горизонтальными.
      final detectedAngle = layout.medianAngleDegrees;
      var deskewApplied = false;
      if (detectedAngle.abs() >= tiltThresholdDegrees &&
          detectedAngle.abs() < 45) {
        watch = Stopwatch()..start();
        final deskewed = _rotateForDeskew(working, -detectedAngle);
        final deskewedPath =
            p.join(source.parent.path, 'ocr_${stamp}_deskew.jpg');
        intermediates.add(deskewedPath);
        await File(deskewedPath)
            .writeAsBytes(img.encodeJpg(deskewed, quality: 100));
        try {
          final relayout = await _layoutAnalyzer.analyze(File(deskewedPath));
          // Оставляем поворот, только если наклон действительно стал
          // меньше: на плохом кадре повторная разметка может «поплыть».
          if (!relayout.isEmpty &&
              relayout.medianAngleDegrees.abs() <
                  detectedAngle.abs() - 1.0) {
            working = deskewed;
            workingPath = deskewedPath;
            layout = relayout;
            deskewApplied = true;
            debugPrint('[OCR] наклон '
                '${detectedAngle.toStringAsFixed(1)}° выпрямлен '
                '(остаток '
                '${relayout.medianAngleDegrees.toStringAsFixed(1)}°)');
          }
        } on Object catch (e) {
          debugPrint('[OCR] разметка после выпрямления наклона не удалась: '
              '$e');
        }
        timings.add(_timing('выпрямление наклона', watch));
      }

      // 3-6. Области: выпрямление, цвет/размер, en-rus, ML Kit для en.
      final lines = <String>[];
      final words = <OcrWord>[];
      final stats = <OcrRegionStat>[];
      final english = <String>[];
      var tesseractChars = 0;
      var tesseractCyrillic = false;
      var mlkitChars = 0;
      var mlkitCount = 0;
      var tesseractCount = 0;
      var confSum = 0.0;
      var confWeight = 0;
      var tessConfSum = 0.0;
      var tessConfWeight = 0;
      var mlConfSum = 0.0;
      var mlConfWeight = 0;
      var index = 0;
      // Тайминги по подэтапам: на телефоне видно, что именно тормозит —
      // выпрямление/цвет, Tesseract по областям или перераспознавание
      // ML Kit.
      var rectifyMs = 0;
      var tessMs = 0;
      var mlkitMs = 0;

      for (final region in readingOrder(layout.regions)) {
        if (region.isEmpty) continue;
        final rawCorners = _quadForRegion(region);
        if (rawCorners.length < 4) continue;
        // ML Kit обрезает строку по глифам и часто «съедает» крайние
        // символы: «+7» в телефоне, первую букву должности/компании.
        // Расширяем четырёхугольник вдоль строки и чуть-чуть по высоте.
        final lineBox = _boxForCorners(rawCorners);
        final padX = math.max(4.0, lineBox.height * 0.5);
        final padY = math.max(2.0, lineBox.height * 0.12);
        final corners = padQuad(
          rawCorners,
          padX,
          padY,
          working.width,
          working.height,
        );
        final box = _boxForCorners(corners);

        // Выпрямление четырёхугольника + апскейл до комфортного кегля.
        final rectWatch = Stopwatch()..start();
        final colorRegion = CardImageTools.rectifyRegion(
          working,
          corners,
          scale: _regionScale(corners),
        );
        // JPEG, а не PNG: вырезка идёт в OCR, потери на q95 незаметны, а
        // кодирование в разы быстрее (на телефоне это сотни мс на кадр).
        final colorPath = p.join(tempDir.path, 'region_${index}_color.jpg');
        await File(colorPath)
            .writeAsBytes(img.encodeJpg(colorRegion, quality: 95));

        // Коррекция цвета по гистограмме САМОЙ области.
        final prepared = CardImageTools.correctColor(colorRegion);
        final ocrPath = p.join(tempDir.path, 'region_${index}_ocr.jpg');
        await File(ocrPath).writeAsBytes(img.encodeJpg(prepared, quality: 95));
        rectifyMs += rectWatch.elapsedMilliseconds;

        // Проход en-rus моделью для попытки распознавания.
        final tessWatch = Stopwatch()..start();
        final tess = await _recognizeRegionWithTesseract(ocrPath);
        tessMs += tessWatch.elapsedMilliseconds;
        var text = tess?.fullText.trim() ?? '';
        var sourceLabel = 'tesseract';
        var language = CardImageTools.classifyLanguage(text);
        var confidence = tess?.confidence ?? 0.0;

        // Совсем короткий мусор («|», «||», «i») — рамки и артефакты.
        // В текст не тащим и ML Kit на него не запускаем: это экономит
        // сотни миллисекунд на плохих кадрах и не засоряет парсер.
        if (text.isNotEmpty && text.length <= 3 && _isJunkLine(text)) continue;

        // Чистый английский — перераспознаём ML Kit и фиксируем его.
        // Русские/смешанные/неопределённые поля остаются за Tesseract.
        if (text.isEmpty || language == RegionLanguage.english) {
          final mlWatch = Stopwatch()..start();
          final ml = await _recognizeRegionWithMlKit(colorPath);
          mlkitMs += mlWatch.elapsedMilliseconds;
          final mlText = ml?.fullText.trim() ?? '';
          final mlLanguage = CardImageTools.classifyLanguage(mlText);
          final better = text.isEmpty ||
              mlLanguage == RegionLanguage.english ||
              mlText.length >= text.length;
          if (mlText.isNotEmpty && better) {
            text = mlText;
            sourceLabel = 'mlkit';
            language = mlLanguage;
            confidence = ml?.confidence ?? 0.0;
          }
        }
        if (text.isEmpty) continue;

        final lineText = text
            .split('\n')
            .map((line) => line.trim())
            .firstWhere((line) => line.isNotEmpty, orElse: () => '');
        if (lineText.isEmpty) continue;

        stats.add(OcrRegionStat(
          index: index,
          source: sourceLabel,
          language: _languageLabel(language),
          text: lineText.length > 120
              ? '${lineText.substring(0, 120)}…'
              : lineText,
          left: box.left,
          top: box.top,
          right: box.right,
          bottom: box.bottom,
          confidence: confidence,
        ));
        lines.add(lineText);
        words.add(OcrWord(
          text: lineText,
          left: box.left,
          top: box.top,
          right: box.right,
          bottom: box.bottom,
          confidence: confidence,
          lineIndex: index,
        ));
        if (sourceLabel == 'mlkit') {
          mlkitCount++;
          mlkitChars += lineText.length;
          english.add(lineText);
          mlConfSum += confidence * lineText.length;
          mlConfWeight += lineText.length;
        } else {
          tesseractCount++;
          tesseractChars += lineText.length;
          tessConfSum += confidence * lineText.length;
          tessConfWeight += lineText.length;
          final lineLanguage = CardImageTools.classifyLanguage(lineText);
          if (lineLanguage == RegionLanguage.russian ||
              lineLanguage == RegionLanguage.mixed) {
            tesseractCyrillic = true;
          }
        }
        confSum += confidence * lineText.length;
        confWeight += lineText.length;
        index++;
        // Даём UI-потоку отрисовать кадр между областями: OCR идёт
        // в фоне, а приложение остаётся отзывчивым для навигации.
        await Future<void>.delayed(Duration.zero);
      }
      timings.add(OcrStageTiming('области: выпрямление/цвет', rectifyMs));
      timings.add(OcrStageTiming('области: Tesseract', tessMs));
      timings.add(OcrStageTiming('области: ML Kit', mlkitMs));

      final fullText = lines.join('\n');
      final confidence = confWeight == 0 ? 0.0 : confSum / confWeight;
      final geometry = OcrGeometryStat(
        medianAngleDegrees: detectedAngle,
        regionsTotal: layout.regions.length,
        regionsMlKit: mlkitCount,
        regionsRectified: tesseractCount,
        imageRegions: maskBoxes.length,
        rotationApplied: deskewApplied,
        orientationDegrees: orientationDegrees,
      );
      final diagnostic = OcrDiagnostic(
        engines: [
          EngineDiagnostic(
            name: 'Tesseract rus+eng (области)',
            lineCount: tesseractCount,
            charCount: tesseractChars,
            hasCyrillic: tesseractCyrillic,
            preview: _regionPreview(stats, 'tesseract'),
            confidence:
                tessConfWeight == 0 ? 0.0 : tessConfSum / tessConfWeight,
          ),
          EngineDiagnostic(
            name: 'ML Kit (английские области)',
            lineCount: mlkitCount,
            charCount: mlkitChars,
            preview: english.take(6).join(' · '),
            confidence: mlConfWeight == 0 ? 0.0 : mlConfSum / mlConfWeight,
          ),
        ],
        chosen: 'области: Tesseract en-rus + ML Kit (en)',
        chosenChars: fullText.length,
        timings: [...timings, _timing('всего', totalWatch)],
        regions: stats,
        geometry: geometry,
        imageBoxes: maskBoxes,
        englishRegions: english,
      );

      debugPrint('[OCR] области: картинок=${maskBoxes.length}, '
          'ориентация=$orientationDegrees°, '
          'наклон=${detectedAngle.toStringAsFixed(1)}° '
          '(${deskewApplied ? 'выпрямлен' : 'без поворота'}), '
          'Tesseract=$tesseractCount, ML Kit=$mlkitCount, '
          'символов=${fullText.length}');

      // Гейт качества. Режим областей умеет «успешно» вернуть мусор:
      // вертикальные полосы по 1 символу, обрезанные строки, перепутанный
      // порядок. Такой результат нельзя отдавать в парсер — отдаём null,
      // чтобы вызывающий код прогнал полнокадровый резерв (там ориентация
      // и выбор прохода уже работают).
      final meaningful = _meaningfulChars(fullText);
      final junkFraction =
          fullText.isEmpty ? 0.0 : _junkChars(lines) / fullText.length;
      if (meaningful < math.max(minChars, 10) ||
          confidence < 0.5 ||
          junkFraction > 0.5) {
        debugPrint('[OCR] области: слабый результат '
            '(букв/цифр=$meaningful, уверенность='
            '${confidence.toStringAsFixed(2)}, '
            'мусор=${(junkFraction * 100).round()}%) — полный кадр');
        return null;
      }

      _logTimings(diagnostic);
      return OcrResult(
        fullText: fullText,
        lines: lines,
        containsCyrillic: OcrResult.hasCyrillic(fullText),
        diagnostic: diagnostic,
        confidence: confidence,
        pass: 'области: en-rus + ML Kit',
        words: words,
        linesAreFinal: true,
        sourcePath: workingPath,
        orientationDegrees: orientationDegrees,
        tiltDegrees: detectedAngle,
        deskewApplied: deskewApplied,
      );
    } finally {
      // Промежуточные кадры (маска/наклон) не нужны: диагностика работает
      // с последним рабочим кадром, остальное удаляем.
      for (final path in intermediates) {
        if (path == workingPath) continue;
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on Object {
          // Не критично: файл мог уже удалиться.
        }
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // Временные файлы могли уже удалиться — не критично.
      }
    }
  }

  /// Поворот всего кадра на [angle] градусов с белым фоном: наклон
  /// устраняется до нарезки областей, поэтому прямоугольники ML Kit
  /// уже почти горизонтальны.
  static img.Image _rotateForDeskew(img.Image image, double angle) {
    final copy = img.Image.from(image);
    copy.backgroundColor = img.ColorRgb8(255, 255, 255);
    return img.copyRotate(
      copy,
      angle: angle,
      interpolation: img.Interpolation.cubic,
    );
  }

  /// Расширяет четырёхугольник строки наружу: вдоль текста на [padX],
  /// поперёк — на [padY]. Точки ограничиваются кадром.
  ///
  /// Зачем: ML Kit строит четырёхугольник по распознанным глифам и
  /// обрезает символы на краях. Из-за этого пропадал «+7» в телефоне и
  /// первая буква названия/должности («сполнительный директор»).
  @visibleForTesting
  static List<LayoutPoint> padQuad(
    List<LayoutPoint> corners,
    double padX,
    double padY,
    int frameWidth,
    int frameHeight,
  ) {
    if (corners.length < 4) return corners;
    final tl = corners[0];
    final tr = corners[1];
    final br = corners[2];
    final bl = corners[3];
    final dx = tr.x - tl.x;
    final dy = tr.y - tl.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return corners;
    final ux = dx / length;
    final uy = dy / length;
    // Перпендикуляр; знак выбираем так, чтобы он смотрел вниз (TL -> BL).
    var vx = -uy;
    var vy = ux;
    if (vx * (bl.x - tl.x) + vy * (bl.y - tl.y) < 0) {
      vx = -vx;
      vy = -vy;
    }
    LayoutPoint move(LayoutPoint p, double along, double across) =>
        LayoutPoint(
          (p.x + ux * along + vx * across)
              .clamp(0.0, (frameWidth - 1).toDouble()),
          (p.y + uy * along + vy * across)
              .clamp(0.0, (frameHeight - 1).toDouble()),
        );
    return [
      move(tl, -padX, -padY),
      move(tr, padX, -padY),
      move(br, padX, padY),
      move(bl, -padX, padY),
    ];
  }

  /// Четырёхугольник области; при отсутствии corner points строим его из
  /// bounding box (layout analyzer обычно всегда отдаёт 4 точки).
  static List<LayoutPoint> _quadForRegion(OcrRegion region) {
    if (region.corners.length >= 4) return region.corners;
    return [
      LayoutPoint(region.left, region.top),
      LayoutPoint(region.right, region.top),
      LayoutPoint(region.right, region.bottom),
      LayoutPoint(region.left, region.bottom),
    ];
  }

  /// Осевой bbox области — в нём фиксируются слова и координаты для
  /// диагностики (вырезки полей на экране проверки).
  static ImageBox _boxForCorners(List<LayoutPoint> corners) {
    var left = corners.first.x;
    var top = corners.first.y;
    var right = corners.first.x;
    var bottom = corners.first.y;
    for (final point in corners.skip(1)) {
      left = math.min(left, point.x);
      top = math.min(top, point.y);
      right = math.max(right, point.x);
      bottom = math.max(bottom, point.y);
    }
    return ImageBox(
      left: left.round(),
      top: top.round(),
      right: right.round(),
      bottom: bottom.round(),
    );
  }

  /// Апскейл области до целевой высоты строки (~40 px): мелкий адрес и
  /// крупный заголовок после нарезки читаются одинаково уверенно.
  ///
  /// Крупный текст (высота 40+ px) не растягиваем: Tesseract читает его
  /// как есть, а лишний апскейл — это лишние миллисекунды на выпрямление,
  /// коррекцию цвета и кодирование.
  static double _regionScale(List<LayoutPoint> corners) {
    final box = _boxForCorners(corners);
    final height = box.height <= 0 ? 1 : box.height;
    return (40.0 / height).clamp(1.0, 4.0).toDouble();
  }

  Future<OcrResult?> _recognizeRegionWithTesseract(String path) async {
    final fallback = _fallback;
    if (fallback == null) return null;
    try {
      final r = await fallback.recognize(
        File(path),
        pageSegMode: regionPageSegMode,
        variable: '',
        language: 'rus+eng',
      );
      return r.isEmpty ? null : r;
    } on Object catch (e) {
      debugPrint('[OCR] Tesseract по области не удался: $e');
      return null;
    }
  }

  Future<OcrResult?> _recognizeRegionWithMlKit(String path) async {
    try {
      final r = await _engine.recognize(File(path));
      return r.isEmpty ? null : r;
    } on Object catch (e) {
      debugPrint('[OCR] ML Kit по области не удался: $e');
      return null;
    }
  }

  static String _regionPreview(List<OcrRegionStat> stats, String source) =>
      stats
          .where((s) => s.source == source)
          .take(6)
          .map((s) => s.text)
          .join(' · ');

  static String _languageLabel(RegionLanguage language) {
    switch (language) {
      case RegionLanguage.english:
        return 'en';
      case RegionLanguage.russian:
        return 'ru';
      case RegionLanguage.mixed:
        return 'mixed';
      case RegionLanguage.unknown:
        return 'unknown';
    }
  }

  static OcrStageTiming _timing(String stage, Stopwatch watch) {
    watch.stop();
    return OcrStageTiming(stage, watch.elapsedMilliseconds);
  }

  /// Прогон Tesseract по набору файлов (вариант × psm).
  ///
  /// P1: адаптивный перебор. Сначала предпочтительный psm (первый в
  /// [tesseractPageSegModes]) на всех вариантах. Если лучший проход уверен
  /// и содержателен, остальные psm не запускаем — на нормальных визитках
  /// psm4/6 дают 0 символов и только тратят 1-2 секунды. Если результат
  /// слабый, добираем остальные psm на лучшем варианте.
  ///
  /// Ошибки отдельных проходов не фатальны — они попадают в диагностику.
  Future<List<OcrResult>> _tesseractPasses(
    List<String> files,
    List<EngineDiagnostic> diagnostics,
  ) async {
    final results = <OcrResult>[];
    final fallback = _fallback;
    final modes = tesseractPageSegModes;
    if (fallback == null || files.isEmpty || modes.isEmpty) return results;

    Future<void> runPass(int fileIndex, int psm) async {
      final vFile = File(files[fileIndex]);
      final passName =
          '${_variantLabel(fileIndex, files[fileIndex])}/psm$psm';
      try {
        final r = await fallback.recognize(
          vFile,
          pageSegMode: psm,
          variable: '',
        );
        final withPass = OcrResult(
          fullText: r.fullText,
          lines: r.lines,
          containsCyrillic: r.containsCyrillic,
          confidence: r.confidence,
          pass: passName,
          words: r.words,
          hocr: r.hocr,
          sourcePath: vFile.path,
        );
        results.add(withPass);
        diagnostics.add(_engineDiagnostic(
          'Tesseract $passName (ков ${(r.confidence * 100).round()})',
          withPass,
          null,
        ));
      } catch (e) {
        diagnostics.add(EngineDiagnostic(
          name: 'Tesseract $passName',
          error: e.toString(),
        ));
      }
    }

    // Этап 1: основной psm на всех вариантах предобработки.
    for (var i = 0; i < files.length; i++) {
      await runPass(i, modes.first);
    }

    // Этап 2: остальные psm — только если основной проход слабый.
    final best = _pickBestTesseract(results);
    if (best != null && !_needsMorePasses(best)) return results;
    final targetIndex = best == null
        ? 0
        : (files.contains(best.sourcePath)
            ? files.indexOf(best.sourcePath)
            : 0);
    for (final psm in modes.skip(1)) {
      await runPass(targetIndex, psm);
    }
    return results;
  }

  /// Нужно ли добирать альтернативные psm: уверенный и достаточно длинный
  /// текст дальше не улучшаем (экономия 1-2 с на телефоне).
  static bool _needsMorePasses(OcrResult best) {
    if (best.isEmpty) return true;
    if (best.confidence < 0.68) return true;
    return _cleanLines(best.lines).join(' ').trim().length < 40;
  }

  /// Нужен ли перебор поворотов кадра.
  ///
  /// Два сигнала:
  ///   * строки вертикальные — кадр снят боком (90/270);
  ///   * текст горизонтальный, но уверенность низкая — возможно, кадр
  ///     перевёрнут (180): Tesseract читает такие строки, но плохо.
  /// Пустой результат не трогаем: если текста нет, поворот не поможет.
  static bool _needsOrientationRetry(OcrResult? best) {
    if (best == null || best.isEmpty) return false;
    if (_horizontalFraction(best) < 0.6) return true;
    return best.confidence < 0.5;
  }

  /// Кадр снят боком? Два независимых сигнала от ML Kit: вертикальные
  /// bbox строк (выше, чем шире) и угол самой строки ~±90°. Второй нужен
  /// на случай, если ML Kit вернул строку с горизонтальным bbox, но
  /// отметил поворот.
  static bool _isSideways(PageLayout layout) {
    if (_verticalFraction(layout) >= 0.5) return true;
    final angles = <double>[];
    for (final r in layout.regions) {
      if (r.angle.isFinite && r.angle.abs() >= 45 && r.angle.abs() <= 135) {
        angles.add(r.angle);
      }
    }
    return angles.isNotEmpty && angles.length * 2 >= layout.regions.length;
  }

  /// Первая строка разметки в верхней половине кадра — признак верного
  /// поворота: ML Kit отдаёт блоки в порядке чтения, поэтому после
  /// правильного разворота первая строка оказывается сверху, а не снизу.
  static bool _startsAtTop(PageLayout layout, int frameHeight) {
    if (layout.regions.isEmpty || frameHeight <= 0) return false;
    final first = layout.regions.first;
    return (first.top + first.bottom) / 2 < frameHeight / 2;
  }

  /// Доля строк с вертикальным bbox.
  static double _verticalFraction(PageLayout layout) {
    var vertical = 0;
    var total = 0;
    for (final r in layout.regions) {
      final width = r.right - r.left;
      final height = r.bottom - r.top;
      if (width <= 0 || height <= 0) continue;
      total++;
      if (height > width * 1.5) vertical++;
    }
    return total == 0 ? 0.0 : vertical / total;
  }

  /// Убирает из боксов «картинок» те, что накрывают найденный ML Kit
  /// текст. Эвристика по пикселям принимает крупные жирные буквы за
  /// «залитую графику» и выбеливала их вместе с частью слова
  /// (НОТАРИУС → НОТ РИУ, СТРОЕНИЕ → ТРОЕНИЕ). Маленький бокс, почти
  /// целиком лежащий внутри текстовой строки, — это буква. Крупный
  /// логотип оставляем, даже если он задевает текст.
  static List<ImageBox> _dropTextBoxes(
    List<ImageBox> boxes,
    PageLayout layout,
    int frameWidth,
    int frameHeight,
  ) {
    if (boxes.isEmpty || layout.regions.isEmpty) return boxes;
    final frameArea = frameWidth * frameHeight;
    if (frameArea <= 0) return boxes;
    final text = [
      for (final r in layout.regions)
        ImageBox(
          left: r.left.floor(),
          top: r.top.floor(),
          right: r.right.ceil(),
          bottom: r.bottom.ceil(),
        ),
    ];
    final out = <ImageBox>[];
    for (final box in boxes) {
      if (box.area == 0) continue;
      var covered = 0.0;
      var linesInside = 0;
      for (final t in text) {
        final w = math.min(box.right, t.right) - math.max(box.left, t.left);
        final h = math.min(box.bottom, t.bottom) - math.max(box.top, t.top);
        if (w > 0 && h > 0) covered += w * h;
        final cx = (t.left + t.right) / 2;
        final cy = (t.top + t.bottom) / 2;
        if (cx >= box.left &&
            cx <= box.right &&
            cy >= box.top &&
            cy <= box.bottom) {
          linesInside++;
        }
      }
      final cover = covered / box.area;
      final small = box.area / frameArea < 0.01;
      if (cover >= 0.3 && small) continue;
      // Тёмная карточка целиком проходит эвристику «залитой картинки».
      // Если внутри бокса несколько строк текста — это фон карточки, а не
      // логотип: выбеливать его нельзя, иначе пропадут все контакты.
      if (linesInside >= 2) continue;
      out.add(box);
    }
    return out;
  }

  /// Порядок чтения областей: сверху вниз, внутри визуальной строки —
  /// слева направо. ML Kit отдаёт блоки в порядке разметки, но на
  /// многоколоночных визитках соседние колонки перемешиваются, и поля
  /// уезжают не туда. Допуск по вертикали — половина медианной высоты
  /// строки, чтобы слова одной строки не разъезжались.
  @visibleForTesting
  static List<OcrRegion> readingOrder(List<OcrRegion> regions) {
    final list = [...regions];
    final heights = [
      for (final r in list) r.bottom - r.top,
    ].where((h) => h > 0).toList()
      ..sort();
    final tolerance =
        heights.isEmpty ? 8.0 : heights[heights.length ~/ 2] * 0.6;
    list.sort((a, b) {
      final dy = a.top - b.top;
      if (dy.abs() > tolerance) return dy < 0 ? -1 : 1;
      final dx = a.left - b.left;
      if (dx.abs() > 1) return dx < 0 ? -1 : 1;
      return a.top.compareTo(b.top);
    });
    return list;
  }

  /// Доля символов в горизонтальных строках (bbox шире, чем выше).
  ///
  /// Tesseract находит строки и у повёрнутого на 90° текста — они просто
  /// вертикальные. Это самый надёжный признак ориентации: 1.0 — текст
  /// горизонтальный, ~0 — кадр боком. Для результатов без bbox (ML Kit,
  /// тесты) возвращаем 1.0, чтобы не штрафовать их вслепую.
  static double _horizontalFraction(OcrResult? r) {
    if (r == null || r.words.isEmpty) return 1.0;
    final byLine = <int, List<OcrWord>>{};
    for (final w in r.words) {
      if (w.text.trim().isEmpty) continue;
      byLine.putIfAbsent(w.lineIndex, () => []).add(w);
    }
    var horizontal = 0;
    var total = 0;
    for (final words in byLine.values) {
      var left = words.first.left;
      var top = words.first.top;
      var right = words.first.right;
      var bottom = words.first.bottom;
      var chars = 0;
      for (final w in words) {
        if (w.left < left) left = w.left;
        if (w.top < top) top = w.top;
        if (w.right > right) right = w.right;
        if (w.bottom > bottom) bottom = w.bottom;
        chars += w.text.trim().length;
      }
      total += chars;
      if ((right - left) >= (bottom - top)) horizontal += chars;
    }
    return total == 0 ? 1.0 : horizontal / total;
  }

  /// Шаг 1 определения ориентации: какой поворот делает строки
  /// горизонтальными. Возвращает 0, если текущая ориентация лучше.
  ///
  /// Сравниваем [_passScore] базового прохода и повёрнутых копий: у
  /// вертикальных строк оценка вдвое ниже, поэтому «боком» проигрывает
  /// даже при более высокой уверенности Tesseract (он умеет читать
  /// повёрнутый текст, но порядок строк и полей при этом страдает).
  ///
  /// [probeSide] — уменьшить кадр перед анализом (для режима областей:
  /// там не нужна полная точность, а 3 прохода по 900px заметно дешевле).
  /// Без базового результата проверяются все четыре положения, включая 0.
  Future<int> _detectRotation(
    String sourcePath,
    OcrResult? base,
    List<String> tempFiles, {
    int? probeSide,
    List<int>? candidates,
    img.Image? sourceImage,
  }) async {
    final fallback = _fallback;
    if (fallback == null) return 0;
    final psm = tesseractPageSegModes.isEmpty ? 3 : tesseractPageSegModes.first;
    var bestAngle = 0;
    var bestScore = base == null ? 0.0 : _passScore(base);
    final angles = candidates ??
        (base == null ? const [0, 90, 180, 270] : const [90, 180, 270]);
    for (final angle in angles) {
      final rotatedPath = await _rotateToTemp(
        sourcePath,
        angle,
        tempFiles,
        maxSide: probeSide,
        sourceImage: sourceImage,
      );
      if (rotatedPath == null) continue;
      try {
        final r = await fallback.recognize(
          File(rotatedPath),
          pageSegMode: psm,
          variable: '',
        );
        final wrapped = OcrResult(
          fullText: r.fullText,
          lines: r.lines,
          containsCyrillic: r.containsCyrillic,
          confidence: r.confidence,
          pass: 'rot$angle/psm$psm',
          words: r.words,
          hocr: r.hocr,
          sourcePath: rotatedPath,
          orientationDegrees: angle,
        );
        final score = _passScore(wrapped);
        if (score > bestScore * 1.05 && score > bestScore + 0.02) {
          bestAngle = angle;
          bestScore = score;
        }
        // Уверенный кадр «как есть» — 180 проверять не нужно: это самый
        // частый случай, экономит второй пробный проход. Для пары 90/270
        // ранний выход не делаем: перевёрнутый на 180° текст Tesseract
        // тоже читает, и можно выбрать неверное направление.
        if (bestAngle == angle &&
            angle == 0 &&
            score >= _confidentPassScore &&
            _horizontalFraction(wrapped) >= 0.9) {
          break;
        }
      } on Object catch (e) {
        debugPrint('[OCR] поворот $angle° не распознан: $e');
      }
    }
    return bestAngle;
  }

  /// Поворачивает несколько кадров на один угол (шаг 2 ориентации).
  /// Возвращает пустой список, если хотя бы один кадр не удалось повернуть.
  static Future<List<String>> _rotateMany(
    List<String> paths,
    int angle,
    List<String> tempFiles,
  ) async {
    final out = <String>[];
    for (final path in paths) {
      final rotated = await _rotateToTemp(path, angle, tempFiles);
      if (rotated == null) return const [];
      out.add(rotated);
    }
    return out;
  }

  /// Поворачивает кадр на [angle] градусов по часовой стрелке и пишет
  /// временный JPEG. Возвращает путь или null при сбое декодирования.
  ///
  /// [maxSide] — предварительно уменьшить длинную сторону (быстрый пробник).
  static Future<String?> _rotateToTemp(
    String path,
    int angle,
    List<String> tempFiles, {
    int? maxSide,
    img.Image? sourceImage,
  }) async {
    try {
      final decoded =
          sourceImage ?? img.decodeImage(await File(path).readAsBytes());
      if (decoded == null) return null;
      var source = decoded;
      if (maxSide != null) {
        final longest =
            source.width > source.height ? source.width : source.height;
        if (longest > maxSide) {
          final scale = maxSide / longest;
          source = img.copyResize(
            source,
            width: (source.width * scale).round(),
            height: (source.height * scale).round(),
            interpolation: img.Interpolation.average,
          );
        }
      }
      final rotated = img.copyRotate(source, angle: angle);
      // Один общий каталог на все повороты: файлы удаляются в finally,
      // а каталог не плодится на каждый кадр.
      final dir = Directory(p.join(Directory.systemTemp.path, 'ocr_rot'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final out = File(p.join(dir.path, 'rot${angle}_$stamp.jpg'));
      await out.writeAsBytes(img.encodeJpg(rotated, quality: 100));
      tempFiles.add(out.path);
      return out.path;
    } on Object catch (e) {
      debugPrint('[OCR] поворот кадра на $angle° не удался: $e');
      return null;
    }
  }

  /// Перераспознаёт «проблемные» блоки [base] с апскейлом и выбором по
  /// кворуму.
  ///
  /// Берём bbox слов лучшего прохода, отбираем мелкие/неуверенные, группируем
  /// в блоки и **расширяем их до полных строк** — чтобы перенос строки
  /// внутри адреса не разрывал блок на несвязанные куски.
  ///
  /// Каждый блок вырезается в нескольких вариантах:
  ///   * из цветного кадра с **собственной** коррекцией цвета сегмента
  ///     (уровни/контраст считаются по пикселям самого сегмента), плюс
  ///     вариант с бинаризацией Оцу по его же гистограмме;
  ///   * из глобальных вариантов предобработки (base/sharp/bin).
  /// По каждому блоку собираем кандидаты и [consensus] выбирает лучший по
  /// уверенности и согласию проходов — «кворум заключений».
  ///
  /// Восстановленный текст **заменяет** покрытые строки базового прохода
  /// на месте: так сохраняются порядок чтения и связность соседних строк
  /// (адрес не распадается на «город» и «улицу» отдельными полями).
  Future<OcrResult?> _segmentPass({
    required List<String> variantFiles,
    required String? segmentSource,
    required OcrResult base,
    required TextRecognitionEngine engine,
  }) async {
    try {
      final problems = segmenter.problemWords(base.words);
      if (problems.isEmpty) return null;
      final blocks = segmenter.groupIntoBlocks(problems);
      if (blocks.isEmpty) return null;

      // Связность: блок расширяется до полных строк, которых коснулся.
      // P1: не больше [_maxSegmentBlocks] блоков за проход — сегментация
      // дорогая (несколько вырезаний и OCR на блок), а хвостовые блоки
      // обычно дают тот же текст, что и базовый проход.
      final fullBlocks = segmenter
          .expandToFullLines(blocks, base.words)
          .take(_maxSegmentBlocks)
          .toList();

      final outDir = Directory('${Directory.systemTemp.path}/ocr_segments');
      final recoveries = <_SegmentRecovery>[];
      for (var i = 0; i < fullBlocks.length; i++) {
        final words = fullBlocks[i];
        final box = FieldSegmenter.unionBoxes(words);
        if (box == null) continue;
        final coveredLines = words.map((w) => w.lineIndex).toSet();

        // Язык определяется по составу блока: чистая латиница (e-mail,
        // домен, английское название) читается точнее только `eng`, чистая
        // кириллица — только `rus`, смешанный блок — `rus+eng`.
        final hintLanguage =
            _detectLanguageForText(words.map((w) => w.text).toList());

        final candidates = <OcrResult>[];
        final stamp = DateTime.now().microsecondsSinceEpoch;

        // 1. Сегмент из цветного кадра: коррекция цвета — по его же
        //    пикселям (а не по всей визитке).
        if (segmentSource != null) {
          for (final binarize in const [false, true]) {
            final path = await segmenter.cropAndUpscale(
              imagePath: segmentSource,
              box: box,
              outDir: outDir.path,
              name: 'seg_${i}_color${binarize ? '_bin' : ''}_$stamp.jpg',
              enhanceColors: true,
              binarize: binarize,
            );
            final r = await _recognizeSegment(
              path,
              engine,
              hintLanguage: hintLanguage,
            );
            if (r != null) candidates.add(r);
          }
        }

        // 2. Глобальные варианты предобработки — уже приведены к общему виду.
        for (var v = 0; v < variantFiles.length; v++) {
          final path = await segmenter.cropAndUpscale(
            imagePath: variantFiles[v],
            box: box,
            outDir: outDir.path,
            name: 'seg_${i}_v${v}_$stamp.jpg',
            enhanceColors: false,
          );
          final r = await _recognizeSegment(
            path,
            engine,
            hintLanguage: hintLanguage,
          );
          if (r != null) candidates.add(r);
        }

        if (candidates.isEmpty) continue;

        // Кворум: победитель по уверенности + согласию вариантов.
        final best = consensus.pickBest(candidates);
        if (best == null) continue;
        final recovered = best.lines
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty && !_isJunkLine(line))
            .toList();
        if (recovered.isEmpty) continue;
        recoveries.add(_SegmentRecovery(coveredLines, recovered));
      }
      if (recoveries.isEmpty) return null;

      // Базовые строки — с индексами (нужны, чтобы понять, какие строки
      // блок заменил).
      final baseLines = _cleanLinesWithIndex(base);
      final merged = _mergeSegmentLines(baseLines, recoveries);
      if (merged.isEmpty) return null;

      final mergedText = merged.join('\n');
      return OcrResult(
        fullText: mergedText,
        lines: merged,
        containsCyrillic:
            base.containsCyrillic || OcrResult._cyrillic.hasMatch(mergedText),
        confidence: base.confidence,
        pass: '${base.pass}+seg',
        // bbox слов — из полнокадрового базового прохода: координаты
        // сегментов относительны вырезанному блоку и здесь неприменимы.
        words: base.words,
        hocr: base.hocr,
        linesAreFinal: true,
        sourcePath: base.sourcePath,
      );
    } on Object catch (e) {
      debugPrint('[OCR] сегментация не удалась: $e');
      return null;
    }
  }

  /// Распознаёт один вырезанный сегмент. Ошибка не фатальна — остальные
  /// кандидаты остаются.
  Future<OcrResult?> _recognizeSegment(
    String? path,
    TextRecognitionEngine engine, {
    String? hintLanguage,
  }) async {
    if (path == null) return null;
    try {
      final r = await engine.recognize(
        File(path),
        pageSegMode: 6,
        variable: '',
        language: hintLanguage,
      );
      return r.isEmpty ? null : r;
    } on Object {
      return null;
    }
  }

  /// Человекочитаемая метка варианта предобработки по имени файла:
  /// `…_base.jpg` → `base`, `…_sharp.jpg` → `sharp`, `…_bin.jpg` → `bin`.
  /// Фолбэк — `base` для первого файла, `varN` для остальных.
  static String _variantLabel(int index, String path) {
    final name = path.toLowerCase();
    if (name.endsWith('_base.jpg') || name.endsWith('/base.jpg')) return 'base';
    if (name.endsWith('_sharp.jpg') || name.endsWith('/sharp.jpg')) {
      return 'sharp';
    }
    if (name.endsWith('_bin.jpg') || name.endsWith('/bin.jpg')) return 'bin';
    return index == 0 ? 'base' : 'var$index';
  }

  /// Определяет язык для сегмента по составу символов: чистый английский →
  /// `eng`, чистый русский → `rus`, смешанный или неопределённый → `rus+eng`.
  static String _detectLanguageForText(List<String> lines) {
    var cyr = 0;
    var lat = 0;
    for (final l in lines) {
      for (var i = 0; i < l.length; i++) {
        final c = l.codeUnitAt(i);
        if (c >= 0x0400 && c <= 0x04FF) cyr++;
        if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) lat++;
      }
    }
    if (cyr == 0 && lat > 0) return 'eng';
    if (lat == 0 && cyr > 0) return 'rus';
    if (cyr == 0 && lat == 0) return 'rus+eng';
    // Смешанный — лучше оставить оба языка
    return 'rus+eng';
  }

  /// Строки базового прохода вместе с индексом строки hOCR.
  ///
  /// Индекс нужен, чтобы понять, какие именно строки заменил
  /// восстановленный сегмент: иначе порядок чтения терялся бы и адрес
  /// распадался бы на части.
  static List<_IndexedLine> _cleanLinesWithIndex(OcrResult r) {
    if (r.words.isEmpty) {
      return [
        for (var i = 0; i < r.lines.length; i++)
          _IndexedLine(i, r.lines[i].trim()),
      ];
    }
    final kept = r.words
        .where((w) => w.text.trim().isNotEmpty && _isConfidentWord(w))
        .toList();
    if (kept.isEmpty) {
      return [
        for (var i = 0; i < r.lines.length; i++)
          _IndexedLine(i, r.lines[i].trim()),
      ];
    }
    final byLine = <int, List<OcrWord>>{};
    for (final w in kept) {
      byLine.putIfAbsent(w.lineIndex, () => []).add(w);
    }
    final ids = byLine.keys.toList()..sort();
    final out = <_IndexedLine>[];
    for (final id in ids) {
      final text = byLine[id]!.map((w) => w.text.trim()).join(' ').trim();
      if (text.isNotEmpty) out.add(_IndexedLine(id, text));
    }
    return out;
  }

  /// Подставляет восстановленные сегменты на место покрытых ими строк.
  ///
  /// Благодаря замене «на месте» сохраняются и порядок чтения, и связь
  /// соседних строк: адрес «г. Примерск» + «мкр-н Примерный» остаётся
  /// двумя строками одного адреса, а не разлетается по разным полям.
  static List<String> _mergeSegmentLines(
    List<_IndexedLine> baseLines,
    List<_SegmentRecovery> recoveries,
  ) {
    final out = <String>[];
    final emitted = <int>{};
    for (final line in baseLines) {
      var matched = -1;
      for (var i = 0; i < recoveries.length; i++) {
        if (recoveries[i].coveredLines.contains(line.index)) {
          matched = i;
          break;
        }
      }
      if (matched >= 0) {
        if (!emitted.contains(matched)) {
          emitted.add(matched);
          out.addAll(recoveries[matched].lines);
        }
        continue;
      }
      if (line.text.isNotEmpty) out.add(line.text);
    }
    // Сегменты, строки которых не попали в базовый проход (их вырезали по
    // уверенности) — добавляем в конец, чтобы не потерять текст.
    for (var i = 0; i < recoveries.length; i++) {
      if (!emitted.contains(i)) out.addAll(recoveries[i].lines);
    }
    return out;
  }

  /// Оценка прохода: уверенность + длина осмысленного текста + доля
  /// «нормальных» слов. Одной уверенности мало (Tesseract бывает уверен в
  /// мусоре), одной длины — тем более: перевёрнутый текст длиннее, но
  /// бесполезнее.
  ///
  /// Вертикальные строки (кадр снят боком) штрафуются вдвое: Tesseract
  /// умеет читать такой текст, но порядок строк и полей при этом страдает,
  /// поэтому горизонтальный проход должен побеждать.
  static double _passScore(OcrResult r) {
    final lines = _cleanLines(r.lines);
    final text = lines.join(' ').trim();
    final lengthScore = text.length.clamp(0, 400) / 400.0;
    final words =
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final meaningful = words.where((w) {
      final cleaned = w.replaceAll(RegExp(r'[^0-9A-Za-zА-Яа-яЁё]'), '');
      return cleaned.length >= 3;
    }).length;
    final plausibility = words.isEmpty ? 0.0 : meaningful / words.length;
    final base = r.confidence * 0.65 + lengthScore * 0.20 + plausibility * 0.15;
    return base * (0.5 + 0.5 * _horizontalFraction(r));
  }

  /// Пересобирает строки из слов, отбрасывая низкоуверенные (осколки
  /// логотипа/фона обычно имеют `x_wconf` 0.05–0.3). Слова с нулевой
  /// уверенностью не трогаем — движок мог её не сообщать.
  ///
  /// Порядок слов внутри строки сохраняем как в исходном результате
  /// (hOCR уже отдаёт слова в порядке чтения; для повёрнутых на 90°
  /// визиток геометрическая сортировка по `left` переворачивает текст).
  ///
  /// Возвращает null, если слов нет (тогда чистка по bbox неприменима) или
  /// если фильтр удалил бы весь текст.
  static List<String>? _cleanByWordConfidence(OcrResult r) {
    if (r.words.isEmpty) return null;

    final kept = r.words
        .where((w) => w.text.trim().isNotEmpty && _isConfidentWord(w))
        .toList();
    if (kept.isEmpty) return null;

    final byLine = <int, List<OcrWord>>{};
    for (final w in kept) {
      byLine.putIfAbsent(w.lineIndex, () => []).add(w);
    }
    final ids = byLine.keys.toList()..sort();
    final lines = <String>[];
    for (final id in ids) {
      final text = byLine[id]!.map((w) => w.text.trim()).join(' ').trim();
      if (text.isNotEmpty) lines.add(text);
    }
    return lines.isEmpty ? null : lines;
  }

  /// Score, при котором кадр «как есть» считается уверенным и проверка
  /// 180° не нужна.
  static const double _confidentPassScore = 0.65;

  /// Порог уверенности слова (`x_wconf`): ниже — считаем артефактом.
  static const double _minWordConfidence = 0.45;

  /// Пониженный порог для слов с цифрами: Tesseract часто не уверен в
  /// коротких группах цифр («(999)» в телефоне — x_wconf ~0.3), но именно
  /// они несут код оператора. Цифры в логотипах встречаются редко.
  static const double _minDigitWordConfidence = 0.25;

  static bool _isConfidentWord(OcrWord w) {
    if (w.confidence <= 0.0 || w.confidence >= _minWordConfidence) return true;
    if (w.confidence < _minDigitWordConfidence) return false;
    // Только фрагменты телефонного вида: минимум три цифры. Одиночная
    // цифра с низкой уверенностью — почти всегда артефакт («ПРИМЕР 2»).
    final digits = RegExp(r'\d').allMatches(w.text).length;
    return digits >= 3;
  }

  /// Максимум блоков, которые перераспознаются с апскейлом за проход.
  static const int _maxSegmentBlocks = 6;

  /// Нужна ли сегментация поверх базового прохода.
  ///
  /// Сегментация стоит секунды на телефоне, а на уверенном полном тексте
  /// почти никогда не меняет поля. Запускаем её только для слабого или
  /// короткого результата (мелкий адрес, размытый текст).
  static bool _shouldSegment(OcrResult base) {
    if (base.isEmpty || base.words.isEmpty) return false;
    if (base.confidence < 0.72) return true;
    final length = _cleanLines(base.lines).join(' ').trim().length;
    return length < 80;
  }

  /// Чистит список строк от мусора распознавания, сохраняя порядок.
  static List<String> _cleanLines(List<String> lines) {
    final out = <String>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || _isJunkLine(line)) continue;
      out.add(line);
    }
    return out;
  }

  /// Сколько букв/цифр в тексте — для гейта качества режима областей.
  static int _meaningfulChars(String text) =>
      RegExp(r'[0-9A-Za-zА-Яа-яЁё]').allMatches(text).length;

  /// Сколько символов приходятся на «мусорные» строки (без слова из 3+
  /// значащих символов).
  static int _junkChars(List<String> lines) {
    var junk = 0;
    for (final line in lines) {
      if (_isJunkLine(line)) junk += line.trim().length;
    }
    return junk;
  }

  /// Отбрасывает явный мусор распознавания: строки без единого «слова»
  /// длиной ≥ 3 значащих символов. На визитках осмысленный текст (имена,
  /// адреса, телефоны) всегда содержит такое слово, а артефакты логотипа и
  /// фона — нет: это «осколки» из 1–2 символов.
  static bool _isJunkLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return true;
    final tokens = t.split(RegExp(r'[^0-9A-Za-zА-Яа-яЁё]+'));
    return !tokens.any((tok) => tok.length >= 3);
  }

  /// Лучший проход Tesseract по [_passScore]: уверенность, длина и
  /// правдоподобность слов. Пустые не рассматриваем.
  static OcrResult? _pickBestTesseract(List<OcrResult> passes) {
    final nonEmpty = passes.where((r) => !r.isEmpty).toList();
    if (nonEmpty.isEmpty) return null;

    nonEmpty.sort((a, b) => _passScore(b).compareTo(_passScore(a)));
    return nonEmpty.first;
  }

  /// Добавляет к результату тайминги внешнего прогона (пробник
  /// ориентации), не теряя диагностику внутреннего.
  static OcrResult _mergeTimings(OcrResult result, List<OcrStageTiming> extra) {
    final d = result.diagnostic;
    if (d == null || extra.isEmpty) return result;
    final merged = OcrResult(
      fullText: result.fullText,
      lines: result.lines,
      containsCyrillic: result.containsCyrillic,
      diagnostic: OcrDiagnostic(
        engines: d.engines,
        chosen: d.chosen,
        chosenChars: d.chosenChars,
        timings: [
          for (final t in extra)
            OcrStageTiming('до поворота: ${t.stage}', t.milliseconds),
          ...d.timings,
        ],
        regions: d.regions,
        geometry: d.geometry,
        imageBoxes: d.imageBoxes,
        englishRegions: d.englishRegions,
      ),
      confidence: result.confidence,
      pass: result.pass,
      words: result.words,
      hocr: result.hocr,
      linesAreFinal: result.linesAreFinal,
      sourcePath: result.sourcePath,
      orientationDegrees: result.orientationDegrees,
      tiltDegrees: result.tiltDegrees,
      deskewApplied: result.deskewApplied,
    );
    _logTimings(merged.diagnostic);
    return merged;
  }

  /// Пишет в logcat разбивку по этапам (по убыванию времени). На телефоне
  /// это основной способ понять, что занимает большую часть OCR.
  static void _logTimings(OcrDiagnostic? diagnostic) {
    if (diagnostic == null || diagnostic.timings.isEmpty) return;
    final sorted = [...diagnostic.timings]
      ..sort((a, b) => b.milliseconds.compareTo(a.milliseconds));
    var total = 0;
    for (final t in diagnostic.timings) {
      total += t.milliseconds;
    }
    debugPrint('[OCR][timing] итого=$total мс: '
        '${sorted.map((t) => '${t.stage}=${t.milliseconds}').join(', ')}');
  }

  static EngineDiagnostic _engineDiagnostic(
    String name,
    OcrResult? result,
    Object? error,
  ) {
    if (error != null) {
      return EngineDiagnostic(name: name, error: error.toString());
    }
    final r = result;
    if (r == null) return EngineDiagnostic(name: name, error: 'нет результата');
    final text = r.fullText.trim();
    return EngineDiagnostic(
      name: name,
      lineCount: r.lines.length,
      charCount: text.length,
      hasCyrillic: r.containsCyrillic,
      preview: text.length > 200 ? '${text.substring(0, 200)}…' : text,
      confidence: r.confidence,
    );
  }

  /// Краткое описание результата движка для logcat (без текста с фото).
  static String _describe(OcrResult? r) {
    if (r == null) return '—';
    return 'строк=${r.lines.length}, символов=${r.fullText.length}, '
        'кириллица=${r.containsCyrillic}';
  }

  /// Выбор лучшего результата:
  ///  - пустой/отсутствующий отбрасывается;
  ///  - чистая латиница у обоих — ML Kit (он качественнее на латинице);
  ///  - иначе побеждает кандидат с лучшим [_passScore]; кириллический
  ///    результат получает небольшой бонус (ML Kit latin её не знает), но
  ///    не безусловную победу: уверенный мусор не должен вытеснять
  ///    осмысленный текст.
  OcrResult? _choose(OcrResult? primary, OcrResult? secondary) {
    final p = primary;
    final s = secondary;
    if (p == null || p.isEmpty) return (s != null && !s.isEmpty) ? s : null;
    if (s == null || s.isEmpty) return p;

    if (!p.containsCyrillic && !s.containsCyrillic) return p;

    var pScore = _passScore(p);
    var sScore = _passScore(s);
    if (p.containsCyrillic != s.containsCyrillic) {
      if (p.containsCyrillic) {
        pScore += _cyrillicBonus;
      } else {
        sScore += _cyrillicBonus;
      }
    }
    return pScore >= sScore ? p : s;
  }

  /// Небольшой бонус кириллическому кандидату: на русских визитках ML Kit
  /// возвращает латинский мусор, поэтому при близкой уверенности выгоднее
  /// проверить русский результат.
  static const double _cyrillicBonus = 0.08;

  Future<void> dispose() async {
    try {
      await _engine.dispose();
    } on Exception {
      // Уже закрыт — не критично.
    }
    final fallback = _fallback;
    if (fallback != null) {
      try {
        await fallback.dispose();
      } on Exception {
        // ditto
      }
    }
    final layout = _layoutAnalyzer;
    if (layout != null) {
      try {
        await layout.dispose();
      } on Exception {
        // ditto
      }
    }
  }
}

/// Строка базового прохода с индексом строки hOCR.
class _IndexedLine {
  const _IndexedLine(this.index, this.text);

  final int index;
  final String text;
}

/// Восстановленный по сегменту текст: какие строки базового прохода он
/// закрывает и что теперь стоит на их месте.
class _SegmentRecovery {
  const _SegmentRecovery(this.coveredLines, this.lines);

  final Set<int> coveredLines;
  final List<String> lines;
}
