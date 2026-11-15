import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Простая точка в пикселях — без привязки к OpenCV, чтобы геометрию
/// (упорядочивание углов, выбор четырёхугольника) можно было тестировать
/// на хосте, не поднимая нативную библиотеку.
class PixelPoint {
  const PixelPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  String toString() => '($x,$y)';

  @override
  bool operator ==(Object other) =>
      other is PixelPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// Четыре угла визитки в пикселях исходного изображения.
///
/// Порядок: [topLeft, topRight, bottomRight, bottomLeft] — в этом же
/// порядке их ждёт `getPerspectiveTransform` для выпрямления.
class CardCorners {
  const CardCorners(this.points);

  final List<PixelPoint> points;

  PixelPoint get topLeft => points[0];
  PixelPoint get topRight => points[1];
  PixelPoint get bottomRight => points[2];
  PixelPoint get bottomLeft => points[3];

  /// Ширина/высота прямоугольника после выпрямления (по длинной стороне).
  double get width => math.max(
        _dist(topLeft, topRight),
        _dist(bottomLeft, bottomRight),
      );

  double get height => math.max(
        _dist(topLeft, bottomLeft),
        _dist(topRight, bottomRight),
      );

  static double _dist(PixelPoint a, PixelPoint b) {
    final dx = (a.x - b.x).toDouble();
    final dy = (a.y - b.y).toDouble();
    return math.sqrt(dx * dx + dy * dy);
  }

  static CardCorners fromFlat(List<int> xy) {
    final pts = <PixelPoint>[];
    for (var i = 0; i + 1 < xy.length; i += 2) {
      pts.add(PixelPoint(xy[i], xy[i + 1]));
    }
    return CardCorners(pts);
  }
}

/// Упорядочивает 4 точки выпуклого четырёхугольника так, чтобы получился
/// контур TL → TR → BR → BL (по часовой стрелке от левого верхнего).
///
/// TL — минимум x+y, BR — максимум x+y, TR — максимум x−y, BL — минимум
/// x−y. Метод устойчивее сортировки по углу для карточек с перспективой.
List<PixelPoint> orderCorners(List<PixelPoint> pts) {
  if (pts.length != 4) return List<PixelPoint>.from(pts);
  PixelPoint bySumMin = pts[0], bySumMax = pts[0];
  PixelPoint byDiffMin = pts[0], byDiffMax = pts[0];
  for (final p in pts) {
    if (p.x + p.y < bySumMin.x + bySumMin.y) bySumMin = p;
    if (p.x + p.y > bySumMax.x + bySumMax.y) bySumMax = p;
    if (p.x - p.y > byDiffMax.x - byDiffMax.y) byDiffMax = p;
    if (p.x - p.y < byDiffMin.x - byDiffMin.y) byDiffMin = p;
  }
  return [bySumMin, byDiffMax, bySumMax, byDiffMin];
}

/// Автодетекция границ визитки на фото и коррекция перспективы средствами
/// OpenCV (`dartcv4`): уменьшение → grayscale → размытие → Canny → контуры
/// → поиск крупнейшего четырёхугольника → `warpPerspective`.
///
/// Зачем: если пользователь снял визитку на стол/фон, OCR получает лишний
/// шум и перспективное искажение. Выпрямленная карточка читается заметно
/// лучше. Детекция — best-effort: если четырёхугольник не найден, исходное
/// изображение не меняется.
class CardDetector {
  CardDetector({
    this.workSize = 800,
    this.minAreaRatio = 0.15,
    this.maxAreaRatio = 0.99,
  });

  /// К меньшей стороне этого размера приводим перед анализом —
  /// быстрее и устойчивее к шуму.
  final int workSize;

  /// Найденный контур должен занимать не менее этой доли кадра (иначе это
  /// мелкий объект, а не карточка) и не более [maxAreaRatio] (почти весь
  /// кадр значит, что фон слился с карточкой — выпрямлять нечего).
  final double minAreaRatio;
  final double maxAreaRatio;

  /// Ищет контур визитки. Возвращает углы в координатах **исходного**
  /// изображения или null, если надёжный четырёхугольник не найден.
  Future<CardCorners?> detect(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    return detectFromBytes(bytes);
  }

  CardCorners? detectFromBytes(Uint8List bytes) {
    final src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (src.isEmpty) return null;
    try {
      return _detect(src);
    } finally {
      src.dispose();
    }
  }

  CardCorners? _detect(cv.Mat src) {
    final scale =
        src.cols >= src.rows ? workSize / src.cols : workSize / src.rows;
    final small = cv.resize(
      src,
      ((src.cols * scale).round(), (src.rows * scale).round()),
      interpolation: cv.INTER_AREA,
    );
    try {
      final gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      final blurred = cv.gaussianBlur(gray, (5, 5), 0);
      final edges = cv.canny(blurred, 50, 150);
      final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
      final closed = cv.dilate(edges, kernel, iterations: 1);
      gray.dispose();
      blurred.dispose();
      edges.dispose();
      kernel.dispose();

      final (contours, hierarchy) =
          cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
      closed.dispose();
      hierarchy.dispose();

      try {
        final quad = _largestQuad(contours, small.cols * small.rows);
        if (quad == null) return null;

        final inv = 1.0 / scale;
        try {
          return CardCorners([
            for (final p in quad)
              PixelPoint((p.x * inv).round(), (p.y * inv).round()),
          ]);
        } finally {
          // cv.Point выделяет нативную память — освобождаем.
          for (final p in quad) {
            p.dispose();
          }
        }
      } finally {
        // Контейнер контуров владеет нативными векторами: без dispose
        // утечка накапливалась с каждым сканом (в пакетном режиме —
        // детекция переставала работать после первых карточек).
        contours.dispose();
      }
    } finally {
      small.dispose();
    }
  }

  /// Перебирает контуры, аппроксимирует каждый полигоном и берёт
  /// наибольший выпуклый четырёхугольник площадью в допустимом диапазоне.
  List<cv.Point>? _largestQuad(cv.Contours contours, int frameArea) {
    List<cv.Point>? best;
    var bestArea = 0.0;
    for (final contour in contours) {
      final area = cv.contourArea(contour);
      final ratio = frameArea == 0 ? 0.0 : area / frameArea;
      if (ratio < minAreaRatio || ratio > maxAreaRatio) continue;

      final peri = cv.arcLength(contour, true);
      final approx = cv.approxPolyDP(contour, 0.02 * peri, true);
      if (approx.length == 4 && cv.isContourConvex(approx)) {
        if (area > bestArea) {
          bestArea = area;
          final ordered = orderCorners([
            for (final p in approx) PixelPoint(p.x, p.y),
          ]);
          best = [for (final p in ordered) cv.Point(p.x, p.y)];
        }
      }
      approx.dispose();
    }
    return best;
  }

  /// Угол поворота карточки по её контуру после исправления перспективы.
  ///
  /// Визитка — прямоугольник, у которого длинная сторона горизонтальна.
  /// Если после `warpPerspective` кадр получился «портретным» (высота больше
  /// ширины), значит карточку сняли боком — поворачиваем на 90°, чтобы
  /// вернуть естественную ориентацию. Направление текста здесь не
  /// участвует: ориентация задаётся только геометрией прямоугольника,
  /// поэтому логотип и отдельные надписи её не сбивают.
  ///
  /// Возвращает 0 или 90 (по часовой стрелке); 180/270 по контуру
  /// неопределимы — низ/верх карточки контур не различает.
  static int detectRotationAngle(CardCorners corners) {
    final w = corners.width;
    final h = corners.height;
    if (w == 0 || h == 0) return 0;
    return h > w ? 90 : 0;
  }

  /// Выпрямляет карточку по найденным углам. Возвращает JPEG-байты или
  /// null при ошибке. [corners] — в координатах исходного изображения.
  Uint8List? warpToBytes(String imagePath, CardCorners corners) {
    final bytes = File(imagePath).readAsBytesSync();
    return warpBytes(bytes, corners);
  }

  Uint8List? warpBytes(Uint8List bytes, CardCorners corners) {
    final src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (src.isEmpty) return null;
    try {
      final w = corners.width.round().clamp(1, 100000);
      final h = corners.height.round().clamp(1, 100000);
      final srcPoints = [
        for (final p in corners.points) cv.Point(p.x, p.y),
      ];
      final dstPoints = [
        cv.Point(0, 0),
        cv.Point(w - 1, 0),
        cv.Point(w - 1, h - 1),
        cv.Point(0, h - 1),
      ];
      final srcPts = cv.VecPoint.fromList(srcPoints);
      final dstPts = cv.VecPoint.fromList(dstPoints);
      try {
        final m = cv.getPerspectiveTransform(srcPts, dstPts);
        final warped = cv.warpPerspective(src, m, (w, h));
        try {
          final (ok, out) = cv.imencode('.jpg', warped);
          return ok ? out : null;
        } finally {
          m.dispose();
          warped.dispose();
        }
      } finally {
        srcPts.dispose();
        dstPts.dispose();
        for (final p in srcPoints) {
          p.dispose();
        }
        for (final p in dstPoints) {
          p.dispose();
        }
      }
    } finally {
      src.dispose();
    }
  }
}
