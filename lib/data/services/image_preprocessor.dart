import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/errors/app_exceptions.dart';
import 'card_detector.dart';
import 'graphic_region_detector.dart';
import 'image_enhancer.dart';

/// Область обрезки в относительных координатах (0..1) —
/// не зависит от разрешения исходного фото.
class CropRegion {
  const CropRegion({
    this.left = 0.0,
    this.top = 0.0,
    this.right = 1.0,
    this.bottom = 1.0,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  bool get isFull => left <= 0.0 && top <= 0.0 && right >= 1.0 && bottom >= 1.0;
}

/// Результат предобработки: готовые к OCR файлы + признаки качества.
class PreprocessResult {
  const PreprocessResult({
    required this.file,
    required this.warnings,
    this.variants = const [],
    this.autoWarped = false,
    this.colorSource,
    this.cardPhotoSource,
    this.graphicRegions = 0,
  });

  /// Основной вариант (обратно совместимый доступ): первый из [variants].
  final File file;

  /// Предупреждения качества (блик, низкий контраст...) — UI может
  /// подсказать «переснимите», но OCR всё равно запускаем.
  final List<String> warnings;

  /// Все варианты предобработки для многопроходного OCR (в порядке
  /// приоритета). Содержит минимум [file].
  final List<File> variants;

  /// Была ли применена авто-детекция границ визитки (OpenCV) — для
  /// диагностики.
  final bool autoWarped;

  /// Цветной кадр после геометрии (перспектива/поворот) и уменьшения.
  /// Источник для нарезки сегментов: коррекция цвета считается по
  /// собственным пикселям каждого сегмента, а не по всей визитке.
  final File? colorSource;

  /// Кадр для карточки: уже обрезан по контуру и повёрнут, но **до**
  /// маскировки логотипов и нарезки строк. Именно он сохраняется как фото
  /// визитки в карточке (WebP).
  final File? cardPhotoSource;

  /// Сколько графических областей (логотипов) найдено и убрано из кадра.
  final int graphicRegions;
}

/// Предобработка изображения перед OCR:
///  1) декодирование и поворот по EXIF (портретные фото телефонов);
///  2) обрезка по границам визитки (CropRegion из UI);
///  3) коррекция перспективы — авто-поиск контура карточки (OpenCV);
///  4) выявление и удаление графики (логотип, эмблема) из кадра;
///  5) повышение контраста/нормализация яркости для теней и бликов;
///  6) ч/б + мягкое разделение уровней — помогает размытому тексту.
///
/// Реализация на пакете `image` (чистый Dart, без нативных зависимостей).
/// Для продвинутой геометрии (коррекция перспективы, авто-поиск границ,
/// дескью) — OpenCV, см. сравнение в ARCHITECTURE.md.
///
/// Порядок важен: ручная рамка задана в координатах ИСХОДНОГО фото,
/// поэтому обрезка идёт первой, а перспектива исправляется уже внутри
/// выбранной области (иначе рамка съезжала бы по выпрямленной карточке).
class ImagePreprocessor {
  ImagePreprocessor({
    this.targetMaxSide = 1600,
    this.jpegQuality = 92,
    this.detector,
    this.detectCard = false,
    this.graphicDetector = const GraphicRegionDetector(),
    this.removeGraphics = true,
  });

  /// Максимальная сторона после уменьшения: 1600px достаточно для OCR
  /// и заметно ускоряет распознавание на средних телефонах.
  final int targetMaxSide;
  final int jpegQuality;

  /// Детектор контура визитки (OpenCV). Может быть null — тогда шаг
  /// авто-выпрямления пропускается (и препроцессор остаётся чистым Dart,
  /// пригодным для юнит-тестов на хосте).
  final CardDetector? detector;

  /// Включить авто-детекцию границ визитки и коррекцию перспективы.
  final bool detectCard;

  /// Детектор графических областей (логотипов) на карточке.
  final GraphicRegionDetector graphicDetector;

  /// Убирать найденную графику из кадра перед OCR.
  final bool removeGraphics;

  /// То же, что [prepare], но тяжёлая обработка (декодирование, OpenCV,
  /// фильтры) выполняется в отдельном isolate. UI-поток не блокируется,
  /// пока распознавание ждёт результат.
  Future<PreprocessResult> prepareInBackground(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
    double rotationDegrees = 0,
  }) async {
    final dir = Directory(
      p.join((await getTemporaryDirectory()).path, 'preprocessed'),
    );
    await dir.create(recursive: true);
    final detector = this.detector;
    final outDirPath = dir.path;
    final hasDetector = detectCard && detector != null;
    final targetSide = targetMaxSide;
    final quality = jpegQuality;
    final remove = removeGraphics;
    final workSize = detector?.workSize ?? 800;
    final minAreaRatio = detector?.minAreaRatio ?? 0.15;
    final maxAreaRatio = detector?.maxAreaRatio ?? 0.99;
    Map<String, Object?> data;
    try {
      data = await _PreprocessWorker.run(<String, Object?>{
        'sourcePath': sourcePath,
        'outDir': outDirPath,
        'left': crop.left,
        'top': crop.top,
        'right': crop.right,
        'bottom': crop.bottom,
        'rotation': rotationDegrees,
        'targetMaxSide': targetSide,
        'jpegQuality': quality,
        'detectCard': hasDetector,
        'removeGraphics': remove,
        'workSize': workSize,
        'minAreaRatio': minAreaRatio,
        'maxAreaRatio': maxAreaRatio,
      }).timeout(const Duration(seconds: 45));
    } on Object catch (e) {
      // Если isolate/OpenCV в нём недоступны или зависли — не теряем скан:
      // выполняем подготовку в текущем isolate, как раньше.
      _PreprocessWorker.reset();
      stderr.writeln('[PREP] background worker failed ($e), main isolate fallback');
      return prepare(
        sourcePath,
        crop: crop,
        rotationDegrees: rotationDegrees,
      );
    }
    return PreprocessResult(
      file: File(data['file']! as String),
      warnings: (data['warnings']! as List).cast<String>(),
      variants: [
        for (final path in data['variants']! as List) File(path as String),
      ],
      autoWarped: data['autoWarped']! as bool,
      colorSource: data['colorSource'] == null
          ? null
          : File(data['colorSource']! as String),
      cardPhotoSource: data['cardPhotoSource'] == null
          ? null
          : File(data['cardPhotoSource']! as String),
      graphicRegions: data['graphicRegions']! as int,
    );
  }

  /// [outDir] — куда положить результат; по умолчанию временный каталог
  /// приложения (в тестах можно подставить свой).
  Future<PreprocessResult> prepare(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
    double rotationDegrees = 0,
    Directory? outDir,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw ImageProcessingException(
        'Исходное фото не найдено: $sourcePath',
        userMessage: 'Файл фото не найден',
      );
    }

    final Uint8List bytes = await source.readAsBytes();
    final warnings = <String>[];

    var decoded = img.decodeImage(bytes);
    // Иногда image_picker отдаёт HEIC/EXIF-поворот, который не декодится
    // напрямую — пробуем через декодер с другим флагом, затем сдаёмся.
    decoded ??= img.decodeJpg(bytes) ?? img.decodePng(bytes);
    if (decoded == null) {
      throw ImageProcessingException(
        'Не удалось декодировать изображение: $sourcePath',
        userMessage: 'Не удалось прочитать фото',
      );
    }

    var image = decoded;

    // 0. PNG с прозрачностью: без фона «пустые» пиксели станут чёрными
    // при кодировании в JPEG (часть каналов = 0), OCR получит мусор.
    // Композитим на белый фон — иначе, например, скриншоты с alpha ломают OCR.
    if (image.hasAlpha) {
      final background = img.Image(width: image.width, height: image.height);
      background.clear(img.ColorRgb8(255, 255, 255));
      image = img.compositeImage(background, image);
    }

    // 1. EXIF-ориентация: телефоны часто отдают повёрнутое фото.
    try {
      image = img.bakeOrientation(image);
    } on Exception {
      // Нет EXIF — оставляем как есть.
    }

    // 1b. Ручной поворот с формы кадрирования. Выполняется до обрезки,
    //     поэтому CropRegion считается уже в координатах повёрнутого кадра.
    image = rotateForCrop(image, rotationDegrees);

    // 2. Обрезка по границам визитки (относительные координаты UI).
    if (!crop.isFull) {
      final x = _clamp((crop.left * image.width).round(), 0, image.width - 1);
      final y = _clamp((crop.top * image.height).round(), 0, image.height - 1);
      final w = _clamp(
        ((crop.right - crop.left) * image.width).round(),
        1,
        image.width - x,
      );
      final h = _clamp(
        ((crop.bottom - crop.top) * image.height).round(),
        1,
        image.height - y,
      );
      image = img.copyCrop(image, x: x, y: y, width: w, height: h);
    }

    // Ориентация кадра здесь не исправляется: OSD Tesseract недоступен
    // через плагин (см. OcrService._rotatedPasses). Поворот выполняется
    // по hOCR уже после первого прохода — когда видно, что строки
    // вертикальные. Так предобработка остаётся чистой и не тратит
    // секунды на каждом кадре.

    // 3. Коррекция перспективы: ищем контур карточки ВНУТРИ выбранной
    //    области и выпрямляем его (OpenCV warpPerspective). Best-effort:
    //    не нашли — работаем с исходной геометрией.
    var autoWarped = false;
    final detector = this.detector;
    if (detectCard && detector != null) {
      try {
        final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 95));
        final corners = detector.detectFromBytes(jpeg);
        if (corners != null) {
          final warped = detector.warpBytes(jpeg, corners);
          final decodedWarped = warped == null ? null : img.decodeImage(warped);
          if (decodedWarped != null) {
            image = decodedWarped;
            autoWarped = true;
            // Поворот визитки по контуру прямоугольника после перспективного
            // выпрямления. Ориентация определяется по соотношению сторон,
            // а не по направлению текста (чтобы логотип не путал).
            final rot = CardDetector.detectRotationAngle(corners);
            if (rot == 90) {
              image = img.copyRotate(image, angle: 90);
            } else if (rot == 270) {
              image = img.copyRotate(image, angle: 270);
            }
          }
        }
      } on Object {
        // Детекция — best-effort: при любой ошибке идём по исходному фото.
      }
    }

    // Снимок для карточки: после геометрии (обрезка по контуру/поворот),
    // но до маскировки графики и нарезки текстовых строк.
    final cardPhoto = _downscale(image, targetMaxSide);

    // 4. Графика (логотип, эмблема) мешает OCR: «NrxspueA®wnniosuos»
    //    вместо названия компании. Насыщенные пиксели найденных областей
    //    заменяем белым — чёрный текст рядом при этом не страдает.
    var graphicCount = 0;
    if (removeGraphics) {
      try {
        final regions = GraphicRegionDetector.mergeBoxes(
          graphicDetector.detect(image),
        );
        if (regions.isNotEmpty) {
          image = GraphicRegionDetector.whitenSaturated(image, regions);
          graphicCount = regions.length;
        }
      } on Object {
        // Детекция графики — best-effort.
      }
    }

    // 5. Оценка качества: слишком тёмное/светлое фото — предупреждаем.
    final meanBrightness = _meanBrightness(image);
    if (meanBrightness < 60) {
      warnings.add('Фото очень тёмное — текст может быть распознан плохо');
    } else if (meanBrightness > 215) {
      warnings.add('Фото пересвечено — возможны блики');
    }

    // 6. Улучшение контраста (тени/лёгкие блики) + ч/б для стабильности OCR.
    // Внимание: brightness в image 4.x — множитель (1.0 = без изменений,
    // 0 = чёрный), НЕ дельта: 0.05 делало изображение полностью чёрным
    // и оба OCR-движка возвращали пустоту («Текст не распознан»).
    final gray = img.grayscale(image);
    var processed = img.adjustColor(gray, contrast: 1.35, brightness: 1.06);
    processed = img.normalize(processed, min: 16, max: 240);

    // 7. Ограничение размера: быстрее OCR, меньше память.
    processed = _downscale(processed, targetMaxSide);
    final colorSource = _downscale(image, targetMaxSide);

    // 8. Сохраняем варианты для многопроходного OCR. Разные шрифты
    // (декоративный леттерспейсинг в логотипах, мелкий печатный текст)
    // по-разному ведут себя при апскейле: один и тот же кадр стоит
    // прогнать и «как есть», и увеличенным с подрезкой резкости —
    // движок затем выберет вариант с большей уверенностью.
    final dir = outDir?.path ??
        p.join((await getTemporaryDirectory()).path, 'preprocessed');
    await Directory(dir).create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;

    final variants = <File>[];
    variants.add(await _save(processed, dir, 'ocr_${stamp}_base.jpg'));

    final sharpened = _upscaleForOcr(processed);
    if (sharpened.width != processed.width) {
      variants.add(await _save(sharpened, dir, 'ocr_${stamp}_sharp.jpg'));
    }

    // Бинаризация (Otsu) — третий вариант: убирает градиенты теней и
    // неравномерный фон, которые мешают Tesseract на плотном мелком тексте.
    // На равномерных кадрах совпадёт с базовым — кворум тогда просто
    // подтверждает уверенный проход (см. BlockConsensus).
    final binary = _binarizeOtsu(processed);
    variants.add(await _save(binary, dir, 'ocr_${stamp}_bin.jpg'));

    // Цветной кадр — источник для нарезки сегментов: коррекция каждого
    // сегмента считается по его собственным пикселям.
    final colorFile = await _save(colorSource, dir, 'ocr_${stamp}_color.jpg');
    final cardPhotoFile =
        await _save(cardPhoto, dir, 'ocr_${stamp}_card.jpg');

    return PreprocessResult(
      file: variants.first,
      warnings: warnings,
      variants: variants,
      autoWarped: autoWarped,
      colorSource: colorFile,
      cardPhotoSource: cardPhotoFile,
      graphicRegions: graphicCount,
    );
  }

  Future<File> _save(img.Image image, String dir, String name) async {
    final file = File(p.join(dir, name));
    await file.writeAsBytes(img.encodeJpg(image, quality: jpegQuality));
    return file;
  }

  /// Поворот кадра на произвольный угол по часовой стрелке с белым фоном.
  /// Холст расширяется до габаритов повёрнутого прямоугольника — так же,
  /// как его показывает и обрезает экран кадрирования.
  static img.Image rotateForCrop(img.Image source, double degrees) {
    final angle = degrees % 360;
    if (angle.abs() < 0.01) return source;
    final copy = img.Image.from(source)
      ..backgroundColor = img.ColorRgb8(255, 255, 255);
    return img.copyRotate(
      copy,
      angle: angle,
      interpolation: img.Interpolation.cubic,
    );
  }

  /// Апскейл мелких изображений (скриншоты, сжатые фото) + лёгкая
  /// подрезка резкости: Tesseract заметно лучше читает текст, если
  /// кегль хотя бы ~30–40 px. Крупные фото не трогаем — уже достаточно.
  static img.Image _upscaleForOcr(img.Image image, {int minSide = 1400}) {
    final longest = math.max(image.width, image.height);
    if (longest >= minSide) return image;
    final scale = (minSide / longest).clamp(1.0, 3.0);
    final resized = img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.cubic,
    );
    return img.convolution(
      resized,
      filter: const [
        0,
        -0.25,
        0,
        -0.25,
        2.0,
        -0.25,
        0,
        -0.25,
        0,
      ],
      div: 1.0,
    );
  }

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  /// Бинаризация методом Оцу: порог по гистограмме яркости максимизирует
  /// межклассовую дисперсию «фон/текст». Результат — чисто чёрный текст на
  /// белом фоне. Для цветного канала не нужен: изображение уже серое.
  static img.Image _binarizeOtsu(img.Image image) =>
      ImageEnhancer.binarizeOtsu(image);

  /// Средняя яркость (по уменьшенной копии — дёшево).
  static double _meanBrightness(img.Image image) {
    final small = img.copyResize(image, width: 64);
    var sum = 0;
    var count = 0;
    for (final pixel in small) {
      sum += pixel.luminance.toInt();
      count++;
    }
    return count == 0 ? 128 : sum / count;
  }

  static img.Image _downscale(img.Image image, int maxSide) {
    final longest = math.max(image.width, image.height);
    if (longest <= maxSide) return image;
    final scale = maxSide / longest;
    return img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
  }
}

/// Рабочая функция isolate: принимает только простые значения и возвращает
/// пути/флаги, чтобы не передавать `File` и нативные объекты между isolate.
Future<Map<String, Object?>> _prepareInIsolate(
  Map<String, Object?> args,
) async {
  final detectCard = args['detectCard'] == true;
  final detector = detectCard
      ? CardDetector(
          workSize: args['workSize']! as int,
          minAreaRatio: args['minAreaRatio']! as double,
          maxAreaRatio: args['maxAreaRatio']! as double,
        )
      : null;
  final preprocessor = ImagePreprocessor(
    targetMaxSide: args['targetMaxSide']! as int,
    jpegQuality: args['jpegQuality']! as int,
    detector: detector,
    detectCard: detectCard,
    removeGraphics: args['removeGraphics'] == true,
  );
  final result = await preprocessor.prepare(
    args['sourcePath']! as String,
    crop: CropRegion(
      left: args['left']! as double,
      top: args['top']! as double,
      right: args['right']! as double,
      bottom: args['bottom']! as double,
    ),
    rotationDegrees: args['rotation']! as double,
    outDir: Directory(args['outDir']! as String),
  );
  return <String, Object?>{
    'file': result.file.path,
    'warnings': result.warnings,
    'variants': [for (final file in result.variants) file.path],
    'autoWarped': result.autoWarped,
    'colorSource': result.colorSource?.path,
    'cardPhotoSource': result.cardPhotoSource?.path,
    'graphicRegions': result.graphicRegions,
  };
}

/// Долгоживущий isolate для подготовки фото.
///
/// `Isolate.run` на каждое фото пересоздавал нативный контекст OpenCV;
/// на устройстве после первого фото очередь могла зависнуть. Здесь isolate
/// создаётся один раз и обрабатывает все фото по очереди. При ошибке/зависании
/// вызывающий код делает reset() и fallback в текущий isolate.
class _PreprocessWorker {
  static Isolate? _isolate;
  static SendPort? _sendPort;
  static ReceivePort? _receivePort;
  static Future<void>? _starting;
  static int _nextId = 1;
  static final Map<int, Completer<Map<String, Object?>>> _pending = {};

  static Future<Map<String, Object?>> run(Map<String, Object?> args) async {
    await _ensureStarted();
    final send = _sendPort;
    if (send == null) {
      throw StateError('preprocessor isolate is not running');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    send.send(<String, Object?>{'id': id, 'args': args});
    return completer.future;
  }

  static Future<void> _ensureStarted() async {
    if (_sendPort != null) return;
    _starting ??= _start();
    await _starting;
    _starting = null;
  }

  static Future<void> _start() async {
    final receive = ReceivePort();
    final ready = Completer<SendPort>();
    _receivePort?.close();
    _receivePort = receive;
    receive.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is Map) {
        final id = message['id'];
        final completer = id is int ? _pending.remove(id) : null;
        if (completer == null || completer.isCompleted) return;
        final error = message['error'];
        if (error != null) {
          completer.completeError(StateError(error.toString()));
          return;
        }
        final result = message['result'];
        if (result is Map) {
          completer.complete(result.cast<String, Object?>());
        } else {
          completer.completeError(StateError('invalid preprocessor response'));
        }
      }
    });

    final isolate = await Isolate.spawn(
      _preprocessWorkerEntry,
      receive.sendPort,
    );
    _isolate = isolate;
    _sendPort = await ready.future.timeout(const Duration(seconds: 5));
  }

  static void reset() {
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } on Object {
      // Isolate уже завершился.
    }
    _isolate = null;
    _sendPort = null;
    _receivePort?.close();
    _receivePort = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('preprocessor worker reset'));
      }
    }
    _pending.clear();
    _starting = null;
  }
}

void _preprocessWorkerEntry(SendPort main) {
  final receive = ReceivePort();
  main.send(receive.sendPort);
  Future<void> queue = Future<void>.value();
  receive.listen((message) {
    queue = queue.then((_) => _handlePreprocessRequest(main, message));
  });
}

Future<void> _handlePreprocessRequest(
  SendPort main,
  Object? message,
) async {
  if (message is! Map) return;
  final id = message['id'];
  try {
    final args = (message['args'] as Map).cast<String, Object?>();
    final result = await _prepareInIsolate(args);
    main.send(<String, Object?>{'id': id, 'result': result});
  } on Object catch (e) {
    main.send(<String, Object?>{'id': id, 'error': e.toString()});
  }
}
