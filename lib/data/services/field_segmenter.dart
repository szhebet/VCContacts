import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'image_enhancer.dart';
import 'ocr_service.dart';

/// Прямоугольная область на изображении (пиксели, начало — левый верх).
class ImageBox {
  const ImageBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;
  int get area => width * height;

  bool overlaps(ImageBox other, {int gap = 0}) =>
      left <= other.right + gap &&
      other.left <= right + gap &&
      top <= other.bottom + gap &&
      other.top <= bottom + gap;

  ImageBox merge(ImageBox other) => ImageBox(
        left: left < other.left ? left : other.left,
        top: top < other.top ? top : other.top,
        right: right > other.right ? right : other.right,
        bottom: bottom > other.bottom ? bottom : other.bottom,
      );

  ImageBox inflate(int dx, int dy) => ImageBox(
        left: left - dx,
        top: top - dy,
        right: right + dx,
        bottom: bottom + dy,
      );

  /// Обрезка к границам изображения [w]×[h].
  ImageBox clampTo(int w, int h) => ImageBox(
        left: left.clamp(0, math.max(0, w - 1)),
        top: top.clamp(0, math.max(0, h - 1)),
        right: right.clamp(1, w),
        bottom: bottom.clamp(1, h),
      );

  @override
  String toString() => 'Box($left,$top,$right,$bottom)';

  @override
  bool operator ==(Object other) =>
      other is ImageBox &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Сегментация визитки на текстовые блоки и адресная обработка мелкого
/// текста.
///
/// Зачем: на визитке рядом соседствуют крупный заголовок и мелкий адрес
/// (индекс, дом, офис). Tesseract по полному кадру теряет мелкий текст,
/// поэтому:
///   1) слова с низкой уверенностью/малой высотой объединяем в блоки
///      ([lowQualityBlocks]) — по вертикальному разрыву между строками;
///   2) каждый блок вырезаем и увеличиваем ([cropAndUpscale]) — кегль
///      доводим до комфортного для OCR;
///   3) блок перераспознаём отдельно (в OcrService) и вклеиваем результат.
///
/// Чистая логика (объединение боксов, группировка в блоки) не трогает
/// нативные библиотеки и покрыта тестами на хосте.
class FieldSegmenter {
  const FieldSegmenter({
    this.minWordHeight = 22,
    this.lowConfidence = 0.75,
    this.lineGapFactor = 0.8,
    this.minBlockWords = 2,
    this.upscaleTarget = 40,
    this.maxScale = 4.0,
  });

  /// Слова ниже этой высоты (px) считаются мелким текстом и идут на
  /// повторное распознавание с апскейлом.
  final int minWordHeight;

  /// Слова с уверенностью ниже этой тоже попадают в выборочную обработку.
  final double lowConfidence;

  /// Вертикальный разрыв между строками больше `lineGap × высота строки`
  /// начинает новый блок.
  final double lineGapFactor;

  /// Блок из одного слова может быть шумом — берём блоки от N слов.
  final int minBlockWords;

  /// Целевая высота строчного текста (px) после апскейла — ~30–50 px
  /// оптимально для Tesseract.
  final int upscaleTarget;

  final double maxScale;

  // ------------------------------------------------------------- чистая логика

  /// Объединение нескольких слов в один охватывающий бокс.
  static ImageBox? unionBoxes(List<OcrWord> words) {
    if (words.isEmpty) return null;
    var left = words.first.left;
    var top = words.first.top;
    var right = words.first.right;
    var bottom = words.first.bottom;
    for (final w in words) {
      if (w.left < left) left = w.left;
      if (w.top < top) top = w.top;
      if (w.right > right) right = w.right;
      if (w.bottom > bottom) bottom = w.bottom;
    }
    return ImageBox(left: left, top: top, right: right, bottom: bottom);
  }

  /// «Проблемные» для OCR слова: мелкие по высоте или низкой уверенности.
  List<OcrWord> problemWords(List<OcrWord> words) => words
      .where((w) =>
          w.text.trim().isNotEmpty &&
          (w.height < minWordHeight || w.confidence < lowConfidence))
      .toList();

  /// Группирует слова в вертикальные блоки: слова одной строки
  /// (совпадающий [OcrWord.lineIndex]) объединяются, а соседние строки
  /// сливаются, пока вертикальный разрыв между ними меньше
  /// `lineGapFactor × высота строки`.
  ///
  /// Порядок слов сохраняется (по строке, затем по x). Возвращает список
  /// блоков; каждый блок — список слов. Блоки из меньше чем [minBlockWords]
  /// слов отбрасываются.
  List<List<OcrWord>> groupIntoBlocks(List<OcrWord> words) {
    if (words.isEmpty) return const [];

    // 1. Группируем по строкам и сортируем строки сверху вниз.
    final byLine = <int, List<OcrWord>>{};
    for (final w in words) {
      byLine.putIfAbsent(w.lineIndex, () => []).add(w);
    }
    for (final line in byLine.values) {
      line.sort((a, b) => a.left.compareTo(b.left));
    }
    final lineIds = byLine.keys.toList()
      ..sort((a, b) {
        final ya = unionBoxes(byLine[a]!)!.top;
        final yb = unionBoxes(byLine[b]!)!.top;
        return ya.compareTo(yb);
      });

    // 2. Сливаем строки в блоки по вертикальному разрыву.
    final blocks = <List<OcrWord>>[];
    List<OcrWord>? current;
    int? currentBottom;
    double? currentLineHeight;

    for (final id in lineIds) {
      final line = byLine[id]!;
      final box = unionBoxes(line)!;
      if (current == null) {
        current = [...line];
        currentBottom = box.bottom;
        currentLineHeight = box.height.toDouble();
        continue;
      }
      final gap = box.top - currentBottom!;
      final gapLimit = (currentLineHeight! * lineGapFactor);
      if (gap <= gapLimit) {
        current.addAll(line);
        currentBottom = math.max(currentBottom, box.bottom);
        currentLineHeight = math.max(currentLineHeight, box.height.toDouble());
      } else {
        blocks.add(current);
        current = [...line];
        currentBottom = box.bottom;
        currentLineHeight = box.height.toDouble();
      }
    }
    if (current != null) blocks.add(current);

    return blocks.where((b) => b.length >= minBlockWords).toList();
  }

  /// Расширяет блоки до полных строк.
  ///
  /// Зачем: «проблемные» слова — это лишь мелкие/неуверенные слова
  /// строки. Если блок собрать только из них, вырезка обрежет строку
  /// пополам: адрес «г. Примерск» / «мкр-н Примерный» (перенос строки)
  /// распался бы на два не связанных куска. Поэтому блок расширяется до
  /// всех слов строк, которых он коснулся, — соседние строки остаются
  /// связанными.
  List<List<OcrWord>> expandToFullLines(
    List<List<OcrWord>> blocks,
    List<OcrWord> allWords,
  ) {
    if (blocks.isEmpty || allWords.isEmpty) return blocks;
    final byLine = <int, List<OcrWord>>{};
    for (final w in allWords) {
      byLine.putIfAbsent(w.lineIndex, () => []).add(w);
    }
    return blocks.map((block) {
      final lines = <int, List<OcrWord>>{};
      for (final w in block) {
        final full = byLine[w.lineIndex];
        if (full != null) lines[w.lineIndex] = full;
      }
      if (lines.isEmpty) return block;
      final result = <OcrWord>[];
      final ids = lines.keys.toList()..sort();
      for (final id in ids) {
        result.addAll(lines[id]!);
      }
      return result;
    }).toList();
  }

  // ----------------------------------------------------------- вырезка/апскейл

  /// Вырезает область [box] из изображения по пути [imagePath], увеличивает
  /// так, чтобы высота строки достигла [upscaleTarget], и сохраняет JPEG в
  /// [outDir]. Возвращает путь к файлу или null, если обрезка невозможна.
  ///
  /// Коррекция цвета выполняется **для самого сегмента**: контраст и
  /// уровни считаются по его собственным пикселям ([ImageEnhancer]), а не
  /// по всей визитке. Тёмный адрес в тёмной плашке и светлый адрес на
  /// белом фоне получают одинаково читаемый вид.
  Future<String?> cropAndUpscale({
    required String imagePath,
    required ImageBox box,
    required String outDir,
    required String name,
    bool enhanceColors = true,
    bool binarize = false,
  }) async {
    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final safe = box.inflate(4, 4).clampTo(decoded.width, decoded.height);
    if (safe.width < 8 || safe.height < 8) return null;

    var crop = img.copyCrop(
      decoded,
      x: safe.left,
      y: safe.top,
      width: safe.width,
      height: safe.height,
    );

    // Собственная коррекция сегмента: ч/б + растяжение уровней по его
    // гистограмме (+ бинаризация Оцу по запросу).
    if (enhanceColors) {
      crop = ImageEnhancer.enhanceSegment(crop, binarize: binarize);
    }

    // Апскейл: короткие блоки не трогаем слишком агрессивно (maxScale).
    final scale = (upscaleTarget / safe.height).clamp(1.0, maxScale);
    final resized = scale <= 1.0
        ? crop
        : img.copyResize(
            crop,
            width: (crop.width * scale).round(),
            height: (crop.height * scale).round(),
            interpolation: img.Interpolation.cubic,
          );

    final dir = Directory(outDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(p.join(outDir, name));
    await file.writeAsBytes(img.encodeJpg(resized, quality: 92));
    return file.path;
  }
}
