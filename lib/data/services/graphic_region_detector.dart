import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'field_segmenter.dart';

/// Эвристика выявления графических элементов визитки (логотип, эмблема,
/// фотография, цветной прямоугольник-плашка).
///
/// Зачем: рядом с названием компании часто стоит картинка. OCR такую
/// область читает как «осколки» (`NrxspueA®wnniosuos`), и название
/// компании перестаёт определяться. Если такую область распознать заранее
/// и убрать из кадра, текст рядом читается нормально.
///
/// Как работает (чистый Dart, без OpenCV — тестируется на хосте):
///   1. кадр уменьшается (скорость) и переводится в карту насыщенности
///      `max(R,G,B) - min(R,G,B)`;
///   2. пиксели с насыщенностью выше порога образуют бинарную маску;
///   3. по маске ищутся связные компоненты (BFS, 4-связность);
///   4. компонента считается графикой, если она заметная по площади, не
///      размазана по всему кадру (не фон/полоса) и **залита** (доля
///      насыщенных пикселей в её боксе высока). У текста заливка низкая:
///      буквы — тонкие штрихи.
///
/// Обнаруженную графику можно «выбелить» ([whitenSaturated]) — при этом
/// белым делаются только насыщенные пиксели, поэтому чёрный текст, случайно
/// попавший в тот же бокс, сохраняется.
class GraphicRegionDetector {
  const GraphicRegionDetector({
    this.workWidth = 600,
    this.saturationThreshold = 45,
    this.minAreaRatio = 0.002,
    this.minFillRatio = 0.42,
    this.minSideRatio = 0.02,
    this.maxSideRatio = 0.6,
  });

  /// Ширина рабочей копии кадра (для анализа достаточно мелкой).
  final int workWidth;

  /// Порог насыщенности, выше которого пиксель считается «цветным».
  final int saturationThreshold;

  /// Минимальная доля площади кадра, которую должна занимать графика.
  final double minAreaRatio;

  /// Минимальная заливка бокса (доля насыщенных пикселей). У логотипа
  /// 0.5–0.9, у текста 0.1–0.3.
  final double minFillRatio;

  /// Минимальный размер стороны области относительно короткой стороны кадра.
  final double minSideRatio;

  /// Максимальный размер стороны: полоса во всю ширину — это фон, а не
  /// логотип, такие не трогаем.
  final double maxSideRatio;

  /// Находит графические области в [color] (цветном кадре).
  /// Возвращает боксы в координатах исходного изображения.
  List<ImageBox> detect(img.Image color) {
    if (color.width < 40 || color.height < 40) return const [];

    final scale = color.width > workWidth ? workWidth / color.width : 1.0;
    final small = scale < 1.0
        ? img.copyResize(
            color,
            width: (color.width * scale).round(),
            height: (color.height * scale).round(),
            interpolation: img.Interpolation.average,
          )
        : color;

    final w = small.width;
    final h = small.height;
    final total = w * h;
    if (total <= 0) return const [];

    // 1. Маска насыщенных пикселей.
    final mask = Uint8List(total);
    var saturated = 0;
    for (final p in small) {
      final r = p.r.toInt();
      final g = p.g.toInt();
      final b = p.b.toInt();
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (mx - mn >= saturationThreshold) {
        mask[p.y * w + p.x] = 1;
        saturated++;
      }
    }
    if (saturated == 0) return const [];

    // 2. Связные компоненты.
    final visited = Uint8List(total);
    final stack = Int32List(total);
    final regions = <ImageBox>[];

    for (var start = 0; start < total; start++) {
      if (mask[start] == 0 || visited[start] == 1) continue;
      var sp = 0;
      stack[sp++] = start;
      visited[start] = 1;

      var minX = w, minY = h, maxX = -1, maxY = -1, area = 0;
      while (sp > 0) {
        final idx = stack[--sp];
        final x = idx % w;
        final y = idx ~/ w;
        area++;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;

        if (x > 0 && _push(mask, visited, stack, sp, idx - 1, total)) sp++;
        if (x < w - 1 && _push(mask, visited, stack, sp, idx + 1, total)) sp++;
        if (y > 0 && _push(mask, visited, stack, sp, idx - w, total)) sp++;
        if (y < h - 1 && _push(mask, visited, stack, sp, idx + w, total)) sp++;
      }

      final boxW = maxX - minX + 1;
      final boxH = maxY - minY + 1;
      final shortSide = w < h ? w : h;

      if (area < total * minAreaRatio) continue;
      if (boxW < shortSide * minSideRatio || boxH < shortSide * minSideRatio) {
        continue;
      }
      if (boxW > w * maxSideRatio || boxH > h * maxSideRatio) continue;

      final fill = area / (boxW * boxH);
      if (fill < minFillRatio) continue;

      final inv = 1.0 / scale;
      regions.add(ImageBox(
        left: (minX * inv).floor(),
        top: (minY * inv).floor(),
        right: (maxX * inv).ceil() + 1,
        bottom: (maxY * inv).ceil() + 1,
      ));
    }

    return regions;
  }

  /// Возвращает копию [color], где насыщенные пиксели внутри [boxes]
  /// заменены белым. Чёрный/серый текст при этом не страдает — он не
  /// насыщен и остаётся как был.
  static img.Image whitenSaturated(
    img.Image color,
    List<ImageBox> boxes, {
    int saturationThreshold = 45,
  }) {
    if (boxes.isEmpty) return color;
    final out = img.Image.from(color);
    for (final box in boxes) {
      final left = box.left.clamp(0, out.width - 1);
      final top = box.top.clamp(0, out.height - 1);
      final right = box.right.clamp(left + 1, out.width);
      final bottom = box.bottom.clamp(top + 1, out.height);
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          final p = out.getPixel(x, y);
          final r = p.r.toInt();
          final g = p.g.toInt();
          final b = p.b.toInt();
          final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
          final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
          if (mx - mn >= saturationThreshold) {
            out.setPixelRgb(x, y, 255, 255, 255);
          }
        }
      }
    }
    return out;
  }

  /// Кладёт соседние [boxes] в один (логотип из нескольких цветов).
  static List<ImageBox> mergeBoxes(List<ImageBox> boxes, {int gap = 6}) {
    if (boxes.length < 2) return List<ImageBox>.from(boxes);
    final result = <ImageBox>[];
    final sorted = List<ImageBox>.from(boxes)
      ..sort((a, b) => a.top.compareTo(b.top));
    for (final box in sorted) {
      var merged = false;
      for (var i = 0; i < result.length; i++) {
        final other = result[i];
        final overlapX =
            box.left <= other.right + gap && other.left <= box.right + gap;
        final overlapY =
            box.top <= other.bottom + gap && other.top <= box.bottom + gap;
        if (overlapX && overlapY) {
          result[i] = ImageBox(
            left: box.left < other.left ? box.left : other.left,
            top: box.top < other.top ? box.top : other.top,
            right: box.right > other.right ? box.right : other.right,
            bottom: box.bottom > other.bottom ? box.bottom : other.bottom,
          );
          merged = true;
          break;
        }
      }
      if (!merged) result.add(box);
    }
    return result;
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
