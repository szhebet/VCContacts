import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors/app_exceptions.dart';
import 'image_preprocessor.dart';

/// Прямоугольник текстовой области в пикселях (для обрезки фото визитки).
class PhotoBox {
  const PhotoBox(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;
}

/// Хранение фотографий визитки и владельца.
///
/// Файлы лежат в каталоге данных приложения (`Documents/card_photos`),
/// а не в кэше: фото не должно исчезать после очистки кэша. Обе картинки
/// сжимаются в WebP (lossy) с ограничением длинной стороны 1600 px.
class CardPhotoService {
  CardPhotoService({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;

  static const int maxSide = 1600;
  static const int quality = 80;

  /// Сохраняет фото визитки с обрезкой [crop] (доли 0..1) в WebP.
  /// [rotationDegrees] — ручной поворот с формы кадрирования (по часовой
  /// стрелке); координаты [crop] относятся уже к повёрнутому кадру.
  /// Возвращает путь к новому файлу.
  Future<String> saveCardPhoto(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
    double rotationDegrees = 0,
  }) async {
    final image = ImagePreprocessor.rotateForCrop(
      _decode(await _read(sourcePath)),
      rotationDegrees,
    );
    return _write(cropAndResize(image, crop), 'card');
  }

  /// Сохраняет фото владельца визитки в WebP. Поддерживает ручной поворот
  /// и обрезку (координаты — относительно повёрнутого кадра).
  Future<String> saveOwnerPhoto(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
    double rotationDegrees = 0,
  }) async {
    final image = ImagePreprocessor.rotateForCrop(
      _decode(await _read(sourcePath)),
      rotationDegrees,
    );
    return _write(cropAndResize(image, crop), 'owner');
  }

  /// Позиционирует фото визитки после OCR:
  ///  * поворачивает на [orientationDegrees] (та же ориентация, что применил
  ///    OCR-пайплайн);
  ///  * убирает остаточный наклон строк [tiltDegrees];
  ///  * если контур карточки не был найден ([cropToText]) — обрезает по
  ///    объединению текстовых областей с запасом.
  ///
  /// [boxesAlreadyDeskewed] — OCR уже выпрямил кадр целиком, поэтому
  /// [textBoxes] заданы в координатах выпрямленного кадра. В этом случае
  /// фото всё равно поворачивается на [tiltDegrees], но прямоугольники
  /// повторно не пересчитываются.
  ///
  /// Возвращает путь к новому WebP; старый файл удаляет вызывающий.
  Future<String> repositionCardPhoto(
    String sourcePath, {
    int orientationDegrees = 0,
    double tiltDegrees = 0,
    List<PhotoBox> textBoxes = const [],
    bool cropToText = false,
    bool boxesAlreadyDeskewed = false,
  }) async {
    final image = _decode(await _read(sourcePath));
    final positioned = repositionImage(
      image,
      orientationDegrees: orientationDegrees,
      tiltDegrees: tiltDegrees,
      textBoxes: textBoxes,
      cropToText: cropToText,
      boxesAlreadyDeskewed: boxesAlreadyDeskewed,
    );
    return _write(positioned, 'card');
  }

  /// Чистая геометрия позиционирования — тестируется на хосте.
  ///
  /// Порядок важен: сначала ориентация (0/90/180/270), затем устранение
  /// мелкого наклона, затем обрезка по текстовым областям. Области
  /// пересчитываются в координаты наклонённого кадра, иначе после дескью
  /// вырезка уезжала бы в сторону. Координаты областей относятся к
  /// повёрнутому OCR-кадру — тому же, что был у OCR после ориентации.
  ///
  /// Если [boxesAlreadyDeskewed] — OCR выпрямил кадр целиком, и области
  /// уже заданы в координатах выпрямленного кадра: пересчёт не нужен,
  /// иначе наклон был бы применён дважды.
  static img.Image repositionImage(
    img.Image source, {
    int orientationDegrees = 0,
    double tiltDegrees = 0,
    List<PhotoBox> textBoxes = const [],
    bool cropToText = false,
    bool boxesAlreadyDeskewed = false,
  }) {
    var image = ImagePreprocessor.rotateForCrop(
      source,
      (orientationDegrees % 360).toDouble(),
    );

    final tilt = tiltDegrees % 360;
    final applyTilt = tilt.abs() >= 1.0 && tilt.abs() < 45;
    final boxes = cropToText && textBoxes.isNotEmpty
        ? (applyTilt && !boxesAlreadyDeskewed
            ? _rotateBoxes(textBoxes, image.width, image.height, -tilt)
            : textBoxes)
        : const <PhotoBox>[];

    if (applyTilt) {
      image = ImagePreprocessor.rotateForCrop(image, -tilt);
    }
    if (boxes.isNotEmpty) {
      final cropped = _cropToBoxes(image, boxes);
      if (cropped != null) image = cropped;
    }
    return image;
  }

  /// Пересчитывает прямоугольники в координаты кадра, повёрнутого на
  /// [degrees] по часовой стрелке (так же, как `img.copyRotate`).
  static List<PhotoBox> _rotateBoxes(
    List<PhotoBox> boxes,
    int width,
    int height,
    double degrees,
  ) {
    final rad = (degrees % 360) * math.pi / 180;
    final ca = math.cos(rad);
    final sa = math.sin(rad);
    final dw2 = 0.5 * ((width * ca).abs() + (height * sa).abs());
    final dh2 = 0.5 * ((width * sa).abs() + (height * ca).abs());
    final w2 = 0.5 * width;
    final h2 = 0.5 * height;

    double mapX(double x, double y) =>
        dw2 + (x - w2) * ca + (y - h2) * sa;
    double mapY(double x, double y) =>
        dh2 - (x - w2) * sa + (y - h2) * ca;

    return [
      for (final b in boxes)
        _boxFromCorners([
          (b.left, b.top),
          (b.right, b.top),
          (b.right, b.bottom),
          (b.left, b.bottom),
        ].map((c) => (mapX(c.$1.toDouble(), c.$2.toDouble()),
            mapY(c.$1.toDouble(), c.$2.toDouble())))),
    ];
  }

  static PhotoBox _boxFromCorners(Iterable<(double, double)> corners) {
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final (x, y) in corners) {
      if (x < left) left = x;
      if (y < top) top = y;
      if (x > right) right = x;
      if (y > bottom) bottom = y;
    }
    return PhotoBox(
      left.floor(),
      top.floor(),
      right.ceil(),
      bottom.ceil(),
    );
  }

  static img.Image? _cropToBoxes(img.Image image, List<PhotoBox> boxes) {
    var left = boxes.first.left;
    var top = boxes.first.top;
    var right = boxes.first.right;
    var bottom = boxes.first.bottom;
    for (final b in boxes.skip(1)) {
      if (b.left < left) left = b.left;
      if (b.top < top) top = b.top;
      if (b.right > right) right = b.right;
      if (b.bottom > bottom) bottom = b.bottom;
    }
    final boxW = right - left;
    final boxH = bottom - top;
    if (boxW <= 0 || boxH <= 0) return null;
    final margin = math.max(24, (math.max(boxW, boxH) * 0.12).round());
    final x = (left - margin).clamp(0, image.width - 1);
    final y = (top - margin).clamp(0, image.height - 1);
    final x2 = (right + margin).clamp(x + 1, image.width);
    final y2 = (bottom + margin).clamp(y + 1, image.height);
    final w = x2 - x;
    final h = y2 - y;
    // Слишком маленькая вырезка — скорее всего текстовые области не покрыли
    // карточку; оставляем кадр целиком.
    if (w * h < image.width * image.height * 0.06) return null;
    return img.copyCrop(image, x: x, y: y, width: w, height: h);
  }

  /// Удаляет файл, только если он лежит в каталоге фотографий приложения.
  /// Исходные снимки из галереи/кэша не трогаем.
  Future<void> deleteIfOwned(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final dir = await _photosDir();
      if (!p.isWithin(dir.path, path)) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // Файла уже нет / нет доступа — не критично.
    }
  }

  /// Обрезка по относительным координатам и уменьшение длинной стороны.
  /// Чистая функция — покрывается тестами на хосте.
  static img.Image cropAndResize(img.Image source, CropRegion crop) {
    final width = source.width;
    final height = source.height;
    final left = (crop.left * width).round().clamp(0, width - 1);
    final top = (crop.top * height).round().clamp(0, height - 1);
    final right = (crop.right * width).round().clamp(left + 1, width);
    final bottom = (crop.bottom * height).round().clamp(top + 1, height);
    var out = img.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
    final longest = math.max(out.width, out.height);
    if (longest > maxSide) {
      final scale = maxSide / longest;
      out = img.copyResize(
        out,
        width: (out.width * scale).round(),
        height: (out.height * scale).round(),
        interpolation: img.Interpolation.average,
      );
    }
    return out;
  }

  /// Сжатие в WebP (lossy). Вынесено отдельно для тестов.
  static Uint8List encodeWebP(img.Image image) => img.encodeWebP(
        image,
        lossless: false,
        quality: quality,
        method: 4,
      );

  Future<Directory> _photosDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'card_photos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> _write(img.Image image, String prefix) async {
    final dir = await _photosDir();
    final file = File(p.join(dir.path, '${prefix}_${_uuid.v4()}.webp'));
    await file.writeAsBytes(encodeWebP(image), flush: true);
    return file.path;
  }

  static Future<Uint8List> _read(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ImageProcessingException(
        'Файл изображения не найден: $path',
        userMessage: 'Фото не найдено',
      );
    }
    return file.readAsBytes();
  }

  static img.Image _decode(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const ImageProcessingException(
        'Не удалось декодировать изображение',
        userMessage: 'Не удалось прочитать фото',
      );
    }
    var image = decoded;
    // Галерея/камера могут отдать EXIF-поворот: приводим пиксели к
    // отображаемой ориентации, иначе crop-координаты с формы кадрирования
    // считаются по другому кадру.
    try {
      image = img.bakeOrientation(image);
    } on Object {
      // Нет EXIF — оставляем как есть.
    }
    return image;
  }
}
