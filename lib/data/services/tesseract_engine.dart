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

  /// Язык по умолчанию для всего изображения. Для отдельных сегментов
  /// можно переопределить через [recognize] параметр — см. [_detectLanguage].
  final String language;

  @override
  Future<OcrResult> recognize(
    File imageFile, {
    int pageSegMode = 3,
    String variable = '',
    String? language,
  }) async {
    final lang = language ?? this.language;
    try {
      // extractHocr (а не extractText): hOCR содержит x_wconf по каждому
      // слову — по нему мы считаем среднюю уверенность и выбираем лучший
      // проход из нескольких (вариант предобработки × режим psm).
      final hocr = await FlutterTesseractOcr.extractHocr(
        imageFile.path,
        language: lang,
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

  /// Разбор hOCR: строки, слова с bbox и средняя уверенность (0..1).
  /// Выделен в статический метод — тестируется без Android.
  static OcrResult parseHocr(String hocr) {
    // Разбираем строки ocr_line и вложенные в них слова ocrx_word.
    // Tesseract помечает часть строк как `ocr_caption`/`ocr_header`
    // (например, вертикальный адрес на повёрнутой визитке) — их тоже
    // берём, иначе такие строки молча теряются.
    // У слова в title лежит bbox и x_wconf; после title могут идти другие
    // атрибуты (lang='eng'), поэтому закрывающую кавычку title не
    // привязываем к '>'.
    final lineRegex = RegExp(
      r"<span class='ocr_(?:line|caption|header)'[^>]*>(.*?)</span>\s*(?=</p>|<span class='ocr_|</div>)",
      dotAll: true,
    );
    final wordRegex = RegExp(
      r"<span class='ocrx_word'[^>]*title='[^']*bbox\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)[^']*x_wconf\s+(\d+)[^']*'[^>]*>([^<]*)</span>",
    );

    final lines = <String>[];
    final words = <OcrWord>[];
    var confSum = 0.0;
    var confCount = 0;

    var lineIndex = 0;
    for (final m in lineRegex.allMatches(hocr)) {
      final lineWords = <String>[];
      for (final w in wordRegex.allMatches(m.group(1)!)) {
        final text = _unescapeHtml(w.group(6)!.trim());
        if (text.isEmpty) continue;
        final conf = int.tryParse(w.group(5)!) ?? 0;
        lineWords.add(text);
        confSum += conf;
        confCount++;
        words.add(OcrWord(
          text: text,
          left: int.parse(w.group(1)!),
          top: int.parse(w.group(2)!),
          right: int.parse(w.group(3)!),
          bottom: int.parse(w.group(4)!),
          confidence: conf / 100.0,
          lineIndex: lineIndex,
        ));
      }
      if (lineWords.isNotEmpty) {
        lines.add(lineWords.join(' '));
        lineIndex++;
      }
    }

    final confidence = confCount == 0 ? 0.0 : confSum / confCount / 100.0;
    final fullText = lines.join('\n');
    return OcrResult(
      fullText: fullText,
      lines: lines,
      containsCyrillic: OcrResult.hasCyrillic(fullText),
      confidence: confidence,
      words: words,
      hocr: hocr,
    );
  }

  @override
  Future<void> dispose() async {
    // Плагин не держит состояния между вызовами.
  }

  /// hOCR экранирует HTML-сущности (`&amp;`, `&lt;`, `&#39;`). Без
  /// обратного преобразования они попадают в поля карточки как мусор
  /// («123456, Г. ГОРОД &lt;»).
  static String _unescapeHtml(String text) {
    if (!text.contains('&')) return text;
    final named = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'");
    return named.replaceAllMapped(
      RegExp(r'&#(x?)([0-9a-fA-F]+);'),
      (m) {
        final value = m.group(1) == 'x'
            ? int.tryParse(m.group(2)!, radix: 16)
            : int.tryParse(m.group(2)!);
        return value == null ? m.group(0)! : String.fromCharCode(value);
      },
    );
  }
}
