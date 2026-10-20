import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../core/errors/app_exceptions.dart';

  /// Результат распознавания: чистый текст и построчные блоки.
class OcrResult {
  const OcrResult({
    required this.fullText,
    required this.lines,
    this.containsCyrillic = false,
    this.diagnostic,
    this.confidence = 0.0,
    this.pass = '',
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
  Future<OcrResult> recognize(
    File imageFile, {
    int pageSegMode = 3,
    String variable = '',
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
class OcrDiagnostic {
  const OcrDiagnostic({
    required this.engines,
    this.chosen,
    this.chosenChars = 0,
  });

  final List<EngineDiagnostic> engines;
  final String? chosen;
  final int chosenChars;
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
    this.minChars = 10,
    this.tesseractPageSegModes = const [3, 4],
  })  : _engine = engine ?? MlKitTextEngine(),
        _fallback = fallback;

  final TextRecognitionEngine _engine;
  final TextRecognitionEngine? _fallback;

  /// Результат короче этого числа символов непригоден: из него не
  /// соберутся поля и не будут показаны «Прочие строки».
  final int minChars;

  /// Режимы сегментации страницы Tesseract для многопроходного режима.
  /// 3 (авто) — рабочий для визиток с логотипом и разрозненными блоками;
  /// 4 (единый столбец) — иногда полнее на плотном тексте. Опытным путём
  /// на тестовых визитках psm 6 и 11 стабильно давали мусор, поэтому
  /// не включены (лишнее время на телефоне).
  final List<int> tesseractPageSegModes;

  /// Распознаёт изображение. [variants] — дополнительные варианты
  /// предобработки того же кадра (см. ImagePreprocessor): каждый
  /// прогоняется через Tesseract, лучший по уверенности побеждает.
  Future<OcrResult> recognizeFromFile(
    String path, {
    List<String> variants = const [],
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw OcrException(
        'Файл изображения не найден: $path',
        userMessage: 'Файл фото не найден',
        stage: 'init',
      );
    }

    // 1. ML Kit — основной движок (лучшее качество на латинице).
    OcrResult? primary;
    Object? primaryError;
    try {
      primary = await _engine.recognize(file);
    } catch (e) {
      primaryError = e;
    }

    // 2. Tesseract — многопроходно: варианты × psm, выбор по уверенности.
    final fallback = _fallback;
    final passes = <OcrResult>[];
    final passDiagnostics = <EngineDiagnostic>[];
    if (fallback != null) {
      final files = <String>[file.path, ...variants.where((v) => v != path)];
      for (var v = 0; v < files.length; v++) {
        final vFile = File(files[v]);
        final variantName = v == 0 ? 'base' : 'sharp';
        for (final psm in tesseractPageSegModes) {
          final passName = '$variantName/psm$psm';
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
            );
            passes.add(withPass);
            passDiagnostics.add(_engineDiagnostic(
              'Tesseract $passName (ков ${(r.confidence * 100).round()})',
              withPass,
              null,
            ));
          } catch (e) {
            passDiagnostics.add(EngineDiagnostic(
              name: 'Tesseract $passName',
              error: e.toString(),
            ));
          }
        }
      }
    }

    final secondary = _pickBestTesseract(passes);

    // Диагностика в logcat (без данных с фото: только метрики).
    debugPrint('[OCR] ML Kit: ${_describe(primary)} '
        '${primaryError == null ? '' : 'ошибка=$primaryError'}');
    debugPrint('[OCR] Tesseract проходов=${passes.length}, лучший: '
        '${secondary?.pass ?? '—'} '
        '(уверенность=${secondary?.confidence.toStringAsFixed(2) ?? '—'})');

    final best = _choose(primary, secondary);
    debugPrint('[OCR] выбран: ${best?.pass ?? '—'}, '
        'символов=${best?.fullText.length ?? 0}');

    final diagnostic = OcrDiagnostic(
      engines: [
        _engineDiagnostic('ML Kit (latin)', primary, primaryError),
        ...passDiagnostics,
      ],
      chosen: best?.pass,
      chosenChars: best?.fullText.length ?? 0,
    );

    if (best != null && best.fullText.trim().length >= minChars) {
      return OcrResult(
        fullText: best.fullText,
        lines: best.lines,
        containsCyrillic: best.containsCyrillic,
        diagnostic: diagnostic,
        confidence: best.confidence,
        pass: best.pass,
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
  }

  /// Лучший проход Tesseract: сначала максимум «полезного текста» с
  /// кириллицей, затем по уверенности и длине. Пустые не рассматриваем.
  static OcrResult? _pickBestTesseract(List<OcrResult> passes) {
    final nonEmpty = passes.where((r) => !r.isEmpty).toList();
    if (nonEmpty.isEmpty) return null;

    // Оценка прохода: уверенность × нормализованная длина. Уверенность
    // решает при близкой длине, длина — при близкой уверенности.
    double score(OcrResult r) {
      final len = r.fullText.trim().length;
      return r.confidence * 0.7 + (len.clamp(0, 400) / 400.0) * 0.3;
    }

    nonEmpty.sort((a, b) => score(b).compareTo(score(a)));
    return nonEmpty.first;
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
  ///  - если кириллицу нашёл только один — берём его;
  ///  - если нашли оба — более полный текст;
  ///  - кириллицы нет ни у кого (чистая латиница) — ML Kit, он качественнее.
  OcrResult? _choose(OcrResult? primary, OcrResult? secondary) {
    final p = primary;
    final s = secondary;
    if (p == null || p.isEmpty) return (s != null && !s.isEmpty) ? s : null;
    if (s == null || s.isEmpty) return p;
    if (p.containsCyrillic != s.containsCyrillic) {
      return p.containsCyrillic ? p : s;
    }
    if (p.containsCyrillic) {
      return p.fullText.length >= s.fullText.length ? p : s;
    }
    return p;
  }

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
  }
}
