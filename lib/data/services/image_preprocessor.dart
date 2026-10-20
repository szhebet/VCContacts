import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/errors/app_exceptions.dart';

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

  bool get isFull =>
      left <= 0.0 && top <= 0.0 && right >= 1.0 && bottom >= 1.0;
}

/// Результат предобработки: готовые к OCR файлы + признаки качества.
class PreprocessResult {
  const PreprocessResult({
    required this.file,
    required this.warnings,
    this.variants = const [],
  });

  /// Основной вариант (обратно совместимый доступ): первый из [variants].
  final File file;

  /// Предупреждения качества (блик, низкий контраст...) — UI может
  /// подсказать «переснимите», но OCR всё равно запускаем.
  final List<String> warnings;

  /// Все варианты предобработки для многопроходного OCR (в порядке
  /// приоритета). Содержит минимум [file].
  final List<File> variants;
}

/// Предобработка изображения перед OCR:
///  1) декодирование и поворот по EXIF (портретные фото телефонов);
///  2) обрезка по границам визитки (CropRegion из UI);
///  3) повышение контраста/нормализация яркости для теней и бликов;
///  4) ч/б + мягкое разделение уровней — помогает размытому тексту.
///
/// Реализация на пакете `image` (чистый Dart, без нативных зависимостей).
/// Для продвинутой геометрии (коррекция перспективы, авто-поиск границ,
/// дескью) — OpenCV, см. сравнение в ARCHITECTURE.md.
class ImagePreprocessor {
  ImagePreprocessor({this.targetMaxSide = 1600, this.jpegQuality = 92});

  /// Максимальная сторона после уменьшения: 1600px достаточно для OCR
  /// и заметно ускоряет распознавание на средних телефонах.
  final int targetMaxSide;
  final int jpegQuality;

  /// [outDir] — куда положить результат; по умолчанию временный каталог
  /// приложения (в тестах можно подставить свой).
  Future<PreprocessResult> prepare(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
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
    final warnings = <String>[];

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

    // 3. Оценка качества: слишком тёмное/светлое фото — предупреждаем.
    final meanBrightness = _meanBrightness(image);
    if (meanBrightness < 60) {
      warnings.add('Фото очень тёмное — текст может быть распознан плохо');
    } else if (meanBrightness > 215) {
      warnings.add('Фото пересвечено — возможны блики');
    }

    // 4. Улучшение контраста (тени/лёгкие блики) + ч/б для стабильности OCR.
    // Внимание: brightness в image 4.x — множитель (1.0 = без изменений,
    // 0 = чёрный), НЕ дельта: 0.05 делало изображение полностью чёрным
    // и оба OCR-движка возвращали пустоту («Текст не распознан»).
    image = img.grayscale(image);
    image = img.adjustColor(image, contrast: 1.35, brightness: 1.06);
    image = img.normalize(image, min: 16, max: 240);

    // 5. Ограничение размера: быстрее OCR, меньше память.
    image = _downscale(image, targetMaxSide);

    // 6. Сохраняем варианты для многопроходного OCR. Разные шрифты
    // (декоративный леттерспейсинг в логотипах, мелкий печатный текст)
    // по-разному ведут себя при апскейле: один и тот же кадр стоит
    // прогнать и «как есть», и увеличенным с подрезкой резкости —
    // движок затем выберет вариант с большей уверенностью.
    final dir = outDir?.path ??
        p.join((await getTemporaryDirectory()).path, 'preprocessed');
    await Directory(dir).create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;

    final variants = <File>[];
    variants.add(await _save(image, dir, 'ocr_${stamp}_base.jpg'));

    final sharpened = _upscaleForOcr(image);
    if (sharpened.width != image.width) {
      variants.add(await _save(sharpened, dir, 'ocr_${stamp}_sharp.jpg'));
    }

    return PreprocessResult(
      file: variants.first,
      warnings: warnings,
      variants: variants,
    );
  }

  Future<File> _save(img.Image image, String dir, String name) async {
    final file = File(p.join(dir, name));
    await file.writeAsBytes(img.encodeJpg(image, quality: jpegQuality));
    return file;
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
        0, -0.25, 0,
        -0.25, 2.0, -0.25,
        0, -0.25, 0,
      ],
      div: 1.0,
    );
  }

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

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
