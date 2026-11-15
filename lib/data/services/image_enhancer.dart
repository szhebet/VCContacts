import 'package:image/image.dart' as img;

/// Попиксельные операции над кадром/сегментом: уровни, контраст, бинаризация.
///
/// Выделены отдельно, потому что используются в двух местах:
///   * предобработка всей визитки (ImagePreprocessor);
///   * подготовка ОДНОГО вырезанного сегмента (FieldSegmenter) — там
///     статистика считается по пикселям самого сегмента, а не всей
///     визитки: тёмный адрес на светлой карточке и светлый адрес на
///     тёмной получают одинаково контрастный вид.
///
/// Модуль чистый (только пакет `image`) — тестируется на хосте.
class ImageEnhancer {
  const ImageEnhancer._();

  /// Порог Оцу по гистограмме яркости: максимизирует межклассовую
  /// дисперсию «фон/текст». Возвращает порог 0..255.
  static int otsuThreshold(img.Image image) {
    final gray = image.hasAlpha ? img.grayscale(image) : image;
    final hist = List<int>.filled(256, 0);
    var total = 0;
    for (final pixel in gray) {
      final v = pixel.luminance.toInt().clamp(0, 255);
      hist[v]++;
      total++;
    }
    if (total == 0) return 128;

    var sumAll = 0.0;
    for (var i = 0; i < 256; i++) {
      sumAll += i * hist[i];
    }

    var sumB = 0.0;
    var wB = 0;
    var bestVar = -1.0;
    var threshold = 128;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sumAll - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > bestVar) {
        bestVar = between;
        threshold = t;
      }
    }
    return threshold;
  }

  /// Бинаризация методом Оцу: чёрный текст на белом фоне.
  ///
  /// P1: тёмные карточки (светлый текст на тёмной плашке) после Оцу дают
  /// белый текст на чёрном. Tesseract такое иногда читает, но заметно хуже,
  /// поэтому для преимущественно тёмного кадра инвертируем результат —
  /// получаем привычные чёрные буквы на белом.
  static img.Image binarizeOtsu(img.Image image) {
    final gray = image.hasAlpha ? img.grayscale(image) : image;
    final threshold = otsuThreshold(gray);
    final invert = _meanLuminance(gray) < 110;
    final out = img.Image(width: gray.width, height: gray.height);
    for (final pixel in gray) {
      var v = pixel.luminance.toInt() > threshold ? 255 : 0;
      if (invert) v = 255 - v;
      out.setPixelRgb(pixel.x, pixel.y, v, v, v);
    }
    return out;
  }

  /// Средняя яркость по уменьшенной копии: дёшево и достаточно, чтобы
  /// отличить «белая визитка» от «тёмной карточки».
  static double _meanLuminance(img.Image image) {
    final stepX = image.width > 128 ? image.width ~/ 128 : 1;
    final stepY = image.height > 128 ? image.height ~/ 128 : 1;
    var sum = 0.0;
    var count = 0;
    for (var y = 0; y < image.height; y += stepY) {
      for (var x = 0; x < image.width; x += stepX) {
        sum += image.getPixel(x, y).luminance;
        count++;
      }
    }
    return count == 0 ? 128 : sum / count;
  }

  /// Растяжение уровней по СОБСТВЕННОЙ гистограмме [image]: тёмный
  /// сегмент (например, адрес в тёмной плашке) растягивается до полного
  /// диапазона так же, как светлый. Percentiles отсекают выбросы.
  static img.Image normalizeLevels(
    img.Image image, {
    double lowPercentile = 0.02,
    double highPercentile = 0.98,
  }) {
    final gray = image.hasAlpha ? img.grayscale(image) : image;
    final hist = List<int>.filled(256, 0);
    var total = 0;
    for (final pixel in gray) {
      hist[pixel.luminance.toInt().clamp(0, 255)]++;
      total++;
    }
    if (total == 0) return gray;

    final lowTarget = (total * lowPercentile).floor();
    final highTarget = (total * highPercentile).floor();
    var acc = 0;
    var low = 0;
    var high = 255;
    for (var i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc >= lowTarget) {
        low = i;
        break;
      }
    }
    acc = 0;
    for (var i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc >= highTarget) {
        high = i;
        break;
      }
    }
    if (high - low < 8) return gray;

    final scale = 255.0 / (high - low);
    final out = img.Image(width: gray.width, height: gray.height);
    for (final pixel in gray) {
      final v = ((pixel.luminance.toInt() - low) * scale).round().clamp(0, 255);
      out.setPixelRgb(pixel.x, pixel.y, v, v, v);
    }
    return out;
  }

  /// Подготовка ОДНОГО вырезанного сегмента к OCR:
  ///   1) ч/б;
  ///   2) растяжение уровней по своей гистограмме (контраст сегмента);
  ///   3) при [binarize] — бинаризация Оцу по своей гистограмме.
  ///
  /// Важно: статистика берётся из самого сегмента, поэтому коррекция
  /// цвета не зависит от того, как выглядит остальная визитка.
  static img.Image enhanceSegment(
    img.Image crop, {
    bool binarize = false,
    bool stretch = true,
  }) {
    if (crop.width < 2 || crop.height < 2) return crop;
    var out = img.grayscale(crop);
    if (stretch) out = normalizeLevels(out);
    if (binarize) out = binarizeOtsu(out);
    return out;
  }
}
