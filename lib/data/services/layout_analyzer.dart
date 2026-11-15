import 'dart:io';
import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../core/errors/app_exceptions.dart';

/// Точка на изображении в пикселях (без зависимости от Flutter/dart:ui —
/// геометрию можно тестировать на хосте).
class LayoutPoint {
  const LayoutPoint(this.x, this.y);

  final double x;
  final double y;

  @override
  String toString() => '(${x.toStringAsFixed(1)},${y.toStringAsFixed(1)})';
}

/// Одна строка текста, найденная ML Kit, вместе с её четырёхугольником.
///
/// `corners` идут по часовой стрелке от левого верхнего: TL, TR, BR, BL.
/// Именно этот четырёхугольник используется для коррекции наклона и
/// перспективы: строка «выпрямляется» в прямоугольник перед распознаванием.
class OcrRegion {
  const OcrRegion({
    required this.text,
    required this.corners,
    required this.lineIndex,
    required this.blockIndex,
    this.confidence = 0.0,
    this.angle = 0.0,
  });

  final String text;
  final List<LayoutPoint> corners;
  final int lineIndex;
  final int blockIndex;
  final double confidence;
  final double angle;

  bool get isEmpty => text.trim().isEmpty;

  double get left => corners.map((p) => p.x).reduce((a, b) => a < b ? a : b);
  double get top => corners.map((p) => p.y).reduce((a, b) => a < b ? a : b);
  double get right => corners.map((p) => p.x).reduce((a, b) => a > b ? a : b);
  double get bottom => corners.map((p) => p.y).reduce((a, b) => a > b ? a : b);
}

/// Блок ML Kit — несколько строк, которые распознаны как единый фрагмент.
class OcrBlock {
  const OcrBlock({
    required this.index,
    required this.corners,
    required this.lines,
  });

  final int index;
  final List<LayoutPoint> corners;
  final List<OcrRegion> lines;

  String get text => lines.map((l) => l.text).join('\n');
}

/// Разметка страницы, полученная анализатором (ML Kit).
class PageLayout {
  const PageLayout({required this.blocks, required this.regions});

  final List<OcrBlock> blocks;
  final List<OcrRegion> regions;

  bool get isEmpty => regions.isEmpty;

  /// Средний угол наклона строк (градусы). Считается по `angle` ML Kit,
  /// а если он недоступен — по геометрии corner points.
  double get medianAngleDegrees {
    final angles = <double>[
      for (final r in regions)
        if (r.angle.abs() > 0.01) r.angle else _baselineAngle(r),
    ].where((a) => a.isFinite && a.abs() < 45).toList();
    if (angles.isEmpty) return 0;
    angles.sort();
    final mid = angles.length ~/ 2;
    return angles.length.isOdd
        ? angles[mid]
        : (angles[mid - 1] + angles[mid]) / 2;
  }

  static double _baselineAngle(OcrRegion r) {
    if (r.corners.length < 4) return 0;
    final tl = r.corners[0];
    final tr = r.corners[1];
    final dx = tr.x - tl.x;
    final dy = tr.y - tl.y;
    if (dx == 0 && dy == 0) return 0;
    return _radToDeg(math.atan2(dy, dx));
  }
}

/// Анализ раскладки текста на изображении.
///
/// Продовый вариант — [MlKitLayoutAnalyzer]. Интерфейс нужен, чтобы
/// OcrService можно было тестировать без нативного ML Kit.
abstract class LayoutAnalyzer {
  Future<PageLayout> analyze(File image);
  Future<void> dispose();
}

/// ML Kit Text Recognition v2 (латиница).
///
/// ML Kit лучше всего читает английский текст и хорошо находит сами
/// области текста (блоки/строки с четырёхугольниками). Эти области мы
/// используем как основу: английские строки берём из ML Kit как есть,
/// а области с кириллицей (или нечитаемые) отправляем в Tesseract.
class MlKitLayoutAnalyzer implements LayoutAnalyzer {
  MlKitLayoutAnalyzer({TextRecognizer? recognizer})
      : _recognizer =
            recognizer ?? TextRecognizer(script: TextRecognitionScript.latin);

  final TextRecognizer _recognizer;

  @override
  Future<PageLayout> analyze(File image) async {
    try {
      final input = InputImage.fromFilePath(image.path);
      final recognized = await _recognizer.processImage(input);

      final blocks = <OcrBlock>[];
      final regions = <OcrRegion>[];
      var blockIndex = 0;
      var lineIndex = 0;

      for (final block in recognized.blocks) {
        final blockLines = <OcrRegion>[];
        for (final line in block.lines) {
          final text = line.text.trim();
          final corners = _corners(line.cornerPoints, line.boundingBox);
          if (text.isEmpty || corners.isEmpty) {
            lineIndex++;
            continue;
          }
          final region = OcrRegion(
            text: text,
            corners: corners,
            lineIndex: lineIndex,
            blockIndex: blockIndex,
            confidence: line.confidence ?? 0.0,
            angle: line.angle ?? 0.0,
          );
          regions.add(region);
          blockLines.add(region);
          lineIndex++;
        }
        if (blockLines.isNotEmpty) {
          blocks.add(OcrBlock(
            index: blockIndex,
            corners: _corners(block.cornerPoints, block.boundingBox),
            lines: blockLines,
          ));
        }
        blockIndex++;
      }

      return PageLayout(blocks: blocks, regions: regions);
    } on Exception catch (e) {
      throw OcrException(
        'ML Kit не смог разметить текст: $e',
        userMessage: 'Не удалось распознать текст на фото',
        cause: e,
        stage: 'process',
      );
    }
  }

  static List<LayoutPoint> _corners(List<dynamic> points, dynamic box) {
    if (points.length >= 4) {
      return [
        for (final p in points.take(4))
          LayoutPoint(
            (p.x as num).toDouble(),
            (p.y as num).toDouble(),
          ),
      ];
    }
    return [
      LayoutPoint((box.left as num).toDouble(), (box.top as num).toDouble()),
      LayoutPoint((box.right as num).toDouble(), (box.top as num).toDouble()),
      LayoutPoint(
          (box.right as num).toDouble(), (box.bottom as num).toDouble()),
      LayoutPoint((box.left as num).toDouble(), (box.bottom as num).toDouble()),
    ];
  }

  @override
  Future<void> dispose() => _recognizer.close();
}

double _radToDeg(double rad) => rad * 180.0 / math.pi;
