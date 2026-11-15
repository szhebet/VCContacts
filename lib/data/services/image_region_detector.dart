import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'field_segmenter.dart';

/// Поиск областей с картинками (логотип, эмблема, фотография, плашка).
///
/// Задача: такие области нужно **полностью исключить из распознавания**.
/// Даже если внутри картинки есть текст (надпись на логотипе), он не
/// должен попадать в результат: он мусорный и ломает поля карточки.
///
/// ML Kit сам по себе не отдаёт боксы картинок — он размечает только
/// текст. Поэтому картинки ищем эвристикой по пикселям (чистый Dart):
///   1. насыщенные цветные компоненты (логотипы, цветные плашки);
///   2. крупные «залитые» тёмные компоненты (чёрные логотипы, QR-коды) —
///      у букв заливка низкая, а у картинки высокая.
/// Найденные боксы объединяются и выбеливаются до ML Kit/Tesseract,
/// поэтому текст внутри картинки физически не виден движкам.
class ImageRegionDetector {
  const ImageRegionDetector({
    this.workWidth = 600,
    this.saturationThreshold = 45,
    this.darkThreshold = 110,
    this.minAreaRatio = 0.0015,
    this.minFillRatio = 0.35,
    this.minMergedFillRatio = 0.5,
    this.maxSideRatio = 0.85,
    this.maxAreaRatio = 0.35,
    this.mergeGap = 6,
  });

  /// Ширина рабочей копии (анализ дешёвый, точности хватает).
  final int workWidth;

  /// Порог насыщенности для цветных картинок.
  final int saturationThreshold;

  /// Порог «тёмного» пикселя для чёрно-белых логотипов.
  final int darkThreshold;

  /// Минимальная доля площади кадра.
  final double minAreaRatio;

  /// Минимальная заливка бокса (доля «чернил»). У текста низкая.
  final double minFillRatio;

  /// Минимальная плотность «чернил» ПОСЛЕ склейки соседних компонент.
  ///
  /// Отдельная буква может пройти [minFillRatio] (особенно жирная «А»),
  /// но склеенное слово — это буквы плюс промежутки, плотность падает до
  /// 0.2–0.4. Логотип/плашка остаются плотными (0.5–0.9). Без этой
  /// проверки эвристика выбеливала буквы вместе с частью слова
  /// (НОТАРИУС → НОТ РИУ).
  final double minMergedFillRatio;

  /// Картинка не должна занимать почти весь кадр (это фон/вся визитка).
  final double maxSideRatio;

  /// Максимальная доля площади кадра для одной картинки. Склейка
  /// компонент может «сшить» фон в огромный бокс, который накрывает всю
  /// визитку — такой бокс выбелил бы весь текст. Проверяется после
  /// склейки (до неё каждая компонента проходит [maxSideRatio]).
  final double maxAreaRatio;

  /// Зазор для склейки соседних фрагментов одного логотипа.
  final int mergeGap;

  /// Находит области картинок в координатах исходного изображения.
  List<ImageBox> detect(img.Image image) {
    if (image.width < 40 || image.height < 40) return const [];
    final scale = image.width > workWidth ? workWidth / image.width : 1.0;
    final small = scale < 1.0
        ? img.copyResize(
            image,
            width: (image.width * scale).round(),
            height: (image.height * scale).round(),
            interpolation: img.Interpolation.average,
          )
        : image;

    final saturated = _components(
      small,
      (p) => _saturation(p) >= saturationThreshold,
    );
    final dark = _components(
      small,
      (p) => p.luminance.toInt() <= darkThreshold,
    );

    final raw = <ImageBox>[...saturated, ...dark]
        .where((b) => _isImageLike(b, small.width, small.height))
        .toList();
    final merged = _merge(raw)
        // Проверки размера повторяем после склейки: сшитый фон может
        // накрыть весь кадр, хотя каждая компонента была в пределах нормы.
        .where((b) => _isImageLike(b, small.width, small.height))
        .where((b) => _inkDensity(small, b) >= minMergedFillRatio)
        .toList();

    final inv = 1.0 / scale;
    return [
      for (final b in merged)
        ImageBox(
          left: (b.left * inv).round().clamp(0, image.width),
          top: (b.top * inv).round().clamp(0, image.height),
          right: (b.right * inv).round().clamp(0, image.width),
          bottom: (b.bottom * inv).round().clamp(0, image.height),
        ),
    ];
  }

  /// Выбеливает области картинок. Возвращает новое изображение —
  /// исходное не мутируется (важно для диагностики).
  img.Image mask(img.Image image, List<ImageBox> boxes) {
    if (boxes.isEmpty) return image;
    final out = img.Image.from(image);
    for (final box in boxes) {
      final left = box.left.clamp(0, out.width - 1);
      final top = box.top.clamp(0, out.height - 1);
      final right = box.right.clamp(left + 1, out.width);
      final bottom = box.bottom.clamp(top + 1, out.height);
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          out.setPixelRgb(x, y, 255, 255, 255);
        }
      }
    }
    return out;
  }

  /// Доля пикселей «чернил» (насыщенных или тёмных) внутри бокса.
  double _inkDensity(img.Image image, ImageBox box) {
    final left = box.left.clamp(0, image.width - 1);
    final top = box.top.clamp(0, image.height - 1);
    final right = box.right.clamp(left + 1, image.width);
    final bottom = box.bottom.clamp(top + 1, image.height);
    var ink = 0;
    var total = 0;
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final p = image.getPixel(x, y);
        total++;
        if (_saturation(p) >= saturationThreshold ||
            p.luminance.toInt() <= darkThreshold) {
          ink++;
        }
      }
    }
    return total == 0 ? 0.0 : ink / total;
  }

  bool _isImageLike(ImageBox box, int frameWidth, int frameHeight) {
    if (box.area == 0) return false;
    final areaRatio = box.area / (frameWidth * frameHeight);
    if (areaRatio < minAreaRatio) return false;
    if (areaRatio > maxAreaRatio) return false;
    final longSide = box.width > box.height ? box.width : box.height;
    final shortSide = box.width > box.height ? box.height : box.width;
    if (shortSide < 6) return false;
    final frameSide = frameWidth > frameHeight ? frameWidth : frameHeight;
    return longSide <= frameSide * maxSideRatio;
  }

  List<ImageBox> _components(img.Image image, bool Function(img.Pixel) test) {
    final w = image.width;
    final h = image.height;
    final total = w * h;
    final mask = Uint8List(total);
    for (final p in image) {
      if (test(p)) mask[p.y * w + p.x] = 1;
    }

    final visited = Uint8List(total);
    final stack = Int32List(total);
    final boxes = <ImageBox>[];

    for (var start = 0; start < total; start++) {
      if (mask[start] == 0 || visited[start] == 1) continue;
      var sp = 0;
      stack[sp++] = start;
      visited[start] = 1;
      var minX = w, minY = h, maxX = -1, maxY = -1;
      var count = 0;
      while (sp > 0) {
        final idx = stack[--sp];
        final x = idx % w;
        final y = idx ~/ w;
        count++;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;

        if (x > 0 && _push(mask, visited, stack, sp, idx - 1, total)) sp++;
        if (x < w - 1 && _push(mask, visited, stack, sp, idx + 1, total)) sp++;
        if (y > 0 && _push(mask, visited, stack, sp, idx - w, total)) sp++;
        if (y < h - 1 && _push(mask, visited, stack, sp, idx + w, total)) sp++;
      }
      final box = ImageBox(
        left: minX,
        top: minY,
        right: maxX + 1,
        bottom: maxY + 1,
      );
      final fill = box.area == 0 ? 0.0 : count / box.area;
      if (fill >= minFillRatio) {
        boxes.add(box);
      }
    }
    return boxes;
  }

  List<ImageBox> _merge(List<ImageBox> boxes) {
    if (boxes.length < 2) return boxes;
    final result = <ImageBox>[];
    final sorted = List<ImageBox>.from(boxes)
      ..sort((a, b) => a.top.compareTo(b.top));
    for (final box in sorted) {
      var merged = false;
      for (var i = 0; i < result.length; i++) {
        if (result[i].overlaps(box, gap: mergeGap)) {
          result[i] = result[i].merge(box);
          merged = true;
          break;
        }
      }
      if (!merged) result.add(box);
    }
    // После слияния боксы могли снова пересечься — повторяем, пока меняется.
    if (result.length != boxes.length) return _merge(result);
    return result;
  }

  static int _saturation(img.Pixel p) {
    final r = p.r.toInt();
    final g = p.g.toInt();
    final b = p.b.toInt();
    final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    return mx - mn;
  }

  static bool _push(
    Uint8List mask,
    Uint8List visited,
    Int32List stack,
    int sp,
    int idx,
    int total,
  ) {
    if (idx < 0 || idx >= total) return false;
    if (mask[idx] == 0 || visited[idx] == 1) return false;
    visited[idx] = 1;
    stack[sp] = idx;
    return true;
  }
}
