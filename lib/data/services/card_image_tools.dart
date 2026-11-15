import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'layout_analyzer.dart';

/// Язык текстовой области по составу символов.
enum RegionLanguage { english, russian, mixed, unknown }

/// Геометрия и цвет текстовых областей.
///
/// ML Kit отдаёт четырёхугольники строк. По ним мы выпрямляем наклон и
/// перспективу (каждая строка/блок становится прямоугольником), а затем
/// нормализуем цвет области перед распознаванием. Всё считается чистым
/// Dart — без нативных библиотек, поэтому тестируется на хосте.
class CardImageTools {
  const CardImageTools._();

  /// Выпрямляет четырёхугольник [corners] (TL, TR, BR, BL) в
  /// горизонтальный прямоугольник. Это одновременно убирает наклон
  /// (tilt) и перспективное искажение области.
  ///
  /// [scale] — во сколько раз увеличить вырезку: Tesseract лучше читает
  /// мелкий текст при кегле ~30–40 px. Размер ограничен, чтобы не
  /// раздувать память на больших блоках.
  static img.Image rectifyRegion(
    img.Image source,
    List<LayoutPoint> corners, {
    double scale = 2.0,
    int minWidth = 160,
    int maxWidth = 1600,
  }) {
    if (corners.length < 4) return source;
    final width = (corners.map((p) => p.x).reduce(math.max) -
            corners.map((p) => p.x).reduce(math.min))
        .abs();
    final height = (corners.map((p) => p.y).reduce(math.max) -
            corners.map((p) => p.y).reduce(math.min))
        .abs();
    final w = (width * scale).round().clamp(minWidth, maxWidth);
    final h = (height * scale).round().clamp(24, maxWidth);
    final out = img.Image(width: w, height: h, numChannels: 3);
    return img.copyRectify(
      source,
      topLeft: img.Point(corners[0].x, corners[0].y),
      topRight: img.Point(corners[1].x, corners[1].y),
      bottomLeft: img.Point(corners[3].x, corners[3].y),
      bottomRight: img.Point(corners[2].x, corners[2].y),
      // Линейная интерполяция: для OCR разницы с кубической нет, а
      // выпрямление области идёт заметно быстрее (на телефоне это сотни мс
      // на кадр).
      interpolation: img.Interpolation.linear,
      toImage: out,
    );
  }

  /// Коррекция цвета текстовой области: лёгкий контраст, нормализация
  /// уровней и обесцвечивание. Тени и цветной фон перестают «съедать»
  /// штрихи; Tesseract на таком кадре стабильнее.
  static img.Image correctColor(img.Image source) {
    var input = source;
    if (input.hasAlpha) {
      final background = img.Image(width: input.width, height: input.height);
      background.clear(img.ColorRgb8(255, 255, 255));
      input = img.compositeImage(background, input);
    }
    final w = input.width;
    final h = input.height;
    if (w <= 0 || h <= 0) return img.Image(width: 1, height: 1);

    // Один проход: яркость + гистограмма (раньше было три полных прохода
    // grayscale/adjustColor/normalize с новыми аллокациями).
    final gray = Uint8List(w * h);
    final hist = List<int>.filled(256, 0);
    var i = 0;
    var sum = 0;
    for (final p in input) {
      final v = p.luminance.toInt().clamp(0, 255);
      gray[i++] = v;
      hist[v]++;
      sum += v;
    }
    // Тёмная карточка (светлый текст на тёмном): Tesseract читает такое
    // заметно хуже, поэтому инвертируем полярность — получаем привычные
    // чёрные буквы на светлом.
    final invert = sum / (w * h) < 110;

    // Уровни: отсекаем пустые края гистограммы, растягиваем в 16..240,
    // затем контраст 1.25 и яркость 1.04 — как в прежней формуле.
    var lo = 0;
    while (lo < 255 && hist[lo] == 0) {
      lo++;
    }
    var hi = 255;
    while (hi > 0 && hist[hi] == 0) {
      hi--;
    }
    if (hi <= lo) {
      lo = 0;
      hi = 255;
    }
    final lut = Uint8List(256);
    for (var v = 0; v < 256; v++) {
      var t = (v - lo) * 255.0 / (hi - lo);
      t = (t - 128) * 1.25 + 128;
      t = t * 1.04;
      t = t * (240 - 16) / 255 + 16;
      lut[v] = t.clamp(0, 255).round();
    }

    var out = img.Image(width: w, height: h, numChannels: 3);
    var index = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var v = lut[gray[index++]];
        if (invert) v = 255 - v;
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    // Размытый текст (смаз, мелкий кегль) Tesseract читает плохо. Если
    // дисперсия лапласиана низкая — контуры «мягкие» — добавляем мягкое
    // усиление резкости. На чётких кадрах не трогаем, чтобы не плодить
    // артефакты.
    if (laplacianVariance(out) < 90) out = sharpen(out);
    return out;
  }

  /// Дисперсия лапласиана — стандартная оценка резкости: у размытого
  /// изображения низкая, у чёткого высокая.
  @visibleForTesting
  static double laplacianVariance(img.Image image) {
    final gray = image.hasAlpha ? img.grayscale(image) : image;
    if (gray.width < 3 || gray.height < 3) return 0;
    var sum = 0.0;
    var sumSq = 0.0;
    var n = 0;
    // Прореживаем очень широкие области: оценке хватает ~300 колонок.
    final stepX = math.max(1, gray.width ~/ 300);
    final stepY = math.max(1, gray.height ~/ 150);
    for (var y = 1; y < gray.height - 1; y += stepY) {
      for (var x = 1; x < gray.width - 1; x += stepX) {
        final c = gray.getPixel(x, y).luminance;
        final lap = 4 * c -
            gray.getPixel(x - 1, y).luminance -
            gray.getPixel(x + 1, y).luminance -
            gray.getPixel(x, y - 1).luminance -
            gray.getPixel(x, y + 1).luminance;
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }
    if (n == 0) return 0;
    final mean = sum / n;
    return sumSq / n - mean * mean;
  }

  /// Мягкое усиление резкости (3×3, сумма коэффициентов = 1).
  @visibleForTesting
  static img.Image sharpen(img.Image image) => img.convolution(
        image,
        filter: const [0, -0.5, 0, -0.5, 3, -0.5, 0, -0.5, 0],
      );

  /// Язык области по преобладающим буквам.
  static RegionLanguage classifyLanguage(String text) {
    var cyr = 0;
    var lat = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x0400 && rune <= 0x04FF) ||
          rune == 0x0451 ||
          rune == 0x0401) {
        cyr++;
      } else if ((rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A)) {
        lat++;
      }
    }
    if (cyr > 0 && lat == 0) return RegionLanguage.russian;
    if (lat > 0 && cyr == 0) return RegionLanguage.english;
    if (cyr > 0 && lat > 0) return RegionLanguage.mixed;
    return RegionLanguage.unknown;
  }

  /// Похоже ли распознанное ML Kit «английское» на мусор. Тогда область
  /// лучше отдать Tesseract: ML Kit latin на кириллице выдаёт случайные
  /// латинские обрывки, которые нельзя принять за английский текст.
  static bool looksLikeGarbage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    final tokens =
        trimmed.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return true;
    final wordLike =
        tokens.where((t) => RegExp(r'[A-Za-zА-Яа-яЁё]{2,}').hasMatch(t)).length;
    if (wordLike / tokens.length < 0.4) return true;

    final alnum = RegExp(r'[0-9A-Za-zА-Яа-яЁё]').allMatches(trimmed).length;
    if (alnum == 0) return true;
    final other = trimmed.length - alnum;
    return other > alnum * 1.5;
  }

  /// Нужен ли Tesseract для области: кириллица, смешанный текст,
  /// нечитаемый набор символов, пустая строка или мусор при латинице.
  static bool needsTesseract(String mlKitText) {
    final lang = classifyLanguage(mlKitText);
    if (lang == RegionLanguage.russian || lang == RegionLanguage.mixed) {
      return true;
    }
    if (lang == RegionLanguage.unknown) return true;
    if (lang == RegionLanguage.english) {
      // «HOtAPHYC» — кириллица в латинице, которую ML Kit прочёл неверно.
      if (RegExp(r'[oO0][Tt][A-Za-z]{4,}').hasMatch(mlKitText) ||
          RegExp(r'[Tt][eE][Pp][A-Za-z]+[HhYy]').hasMatch(mlKitText)) {
        return true;
      }
      return looksLikeGarbage(mlKitText);
    }
    return looksLikeGarbage(mlKitText);
  }

  /// Язык Tesseract для области: чистая кириллица — `rus`, всё остальное
  /// (в том числе мусор и смешанный текст) — `rus+eng`, чтобы не потерять
  /// латинские фрагменты (e-mail, домен, название на английском).
  static String tesseractLanguage(String mlKitText) =>
      classifyLanguage(mlKitText) == RegionLanguage.russian ? 'rus' : 'rus+eng';
}
