import 'dart:io';

import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';

import '../../core/errors/app_exceptions.dart';
import 'ocr_service.dart';

/// Обёртка над Tesseract 5 (LSTM), языки rus+eng.
///
/// Зачем нужен: ML Kit Text Recognition v2 обучен для латиницы (и ещё
/// четырёх скриптов, но не для кириллицы) — на русских визитках он
/// возвращает пустой текст. Tesseract добирает то, что не увидел ML Kit,
/// и работает офлайн: модели (tessdata_best, ~30 МБ) вшиты в assets
/// и копируются плагином в песочницу приложения при первом вызове.
/// AAR плагина `flutter_tesseract_ocr` уже содержит Tesseract 5.5.1.
class TesseractTextEngine implements TextRecognitionEngine {
  TesseractTextEngine({this.language = 'rus+eng'});

  final String language;

  @override
  Future<OcrResult> recognize(
    File imageFile, {
    int pageSegMode = 3,
    String variable = '',
  }) async {
    try {
      // extractHocr (а не extractText): hOCR содержит x_wconf по каждому
      // слову — по нему мы считаем среднюю уверенность и выбираем лучший
      // проход из нескольких (вариант предобработки × режим psm).
      final hocr = await FlutterTesseractOcr.extractHocr(
        imageFile.path,
        language: language,
        args: {
          'psm': '$pageSegMode',
          'preserve_interword_spaces': '1',
        },
      );
      return parseHocr(hocr);
    } on Exception catch (e) {
      throw OcrException(
        'Tesseract не смог распознать изображение: $e',
        userMessage: 'Не удалось распознать текст на фото',
        cause: e,
        stage: 'tesseract',
      );
    }
  }

  /// Разбор hOCR: строки + средняя уверенность слов (0..1).
  /// Выделен в статический метод — тестируется без Android.
  static OcrResult parseHocr(String hocr) {
    // Слово: у тега ocrx_word в title лежит x_wconf. После title могут
    // идти другие атрибуты (например lang='eng'), поэтому закрывающую
    // кавычку title не привязываем к '>'.
    final wordRegex = RegExp(
      r"<span class='ocrx_word'[^>]*title='[^']*x_wconf\s+(\d+)[^']*'[^>]*>([^<]*)</span>",
    );
    // Строки ищем отдельно: ocr_line содержит несколько ocrx_word.
    final lineRegex = RegExp(
      r"<span class='ocr_line'[^>]*>(.*?)</span>\s*(?=</p>|<span class='ocr_line'|</div>)",
      dotAll: true,
    );
    final wordTextRegex = RegExp(r"<span class='ocrx_word'[^>]*>([^<]*)</span>");

    final lines = <String>[];
    for (final m in lineRegex.allMatches(hocr)) {
      final words = wordTextRegex
          .allMatches(m.group(1)!)
          .map((w) => w.group(1)!.trim())
          .where((w) => w.isNotEmpty)
          .toList();
      if (words.isNotEmpty) lines.add(words.join(' '));
    }

    var confSum = 0.0;
    var confCount = 0;
    for (final m in wordRegex.allMatches(hocr)) {
      final conf = int.tryParse(m.group(1)!);
      final text = m.group(2)!.trim();
      if (conf != null && text.isNotEmpty) {
        confSum += conf;
        confCount++;
      }
    }
    final confidence = confCount == 0 ? 0.0 : confSum / confCount / 100.0;

    final fullText = lines.join('\n');
    return OcrResult(
      fullText: fullText,
      lines: lines,
      containsCyrillic: OcrResult.hasCyrillic(fullText),
      confidence: confidence,
    );
  }

  @override
  Future<void> dispose() async {
    // Плагин не держит состояния между вызовами.
  }
}
