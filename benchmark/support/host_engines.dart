import 'dart:io';

import 'package:vc_contacts/core/errors/app_exceptions.dart';
import 'package:vc_contacts/data/services/ocr_service.dart';
import 'package:vc_contacts/data/services/tesseract_engine.dart';

/// Хостовый адаптер Tesseract CLI для замерного стенда.
///
/// На Android работает плагин `flutter_tesseract_ocr` (AAR 5.5.1). На хосте
/// запускаем системный `tesseract` с теми же `traineddata`, поэтому проходы
/// и hOCR-разбор совпадают с устройством. Модель ML Kit на хосте недоступна:
/// её роль играет Tesseract с языком `eng` — он так же возвращает латинский
/// мусор на кириллице (см. [HostMlKitLikeEngine]).
class HostTesseractEngine implements TextRecognitionEngine {
  HostTesseractEngine({
    required this.tessdataDir,
    required this.language,
    this.label = 'tesseract',
  });

  /// Каталог с `rus.traineddata` и `eng.traineddata`.
  final String tessdataDir;

  /// Язык по умолчанию: `rus+eng` — резервный движок, `eng` — имитация ML Kit.
  final String language;

  /// Метка для диагностики/логов.
  final String label;

  @override
  Future<OcrResult> recognize(
    File imageFile, {
    int pageSegMode = 3,
    String variable = '',
    String? language,
  }) async {
    final process = await Process.run('tesseract', [
      imageFile.path,
      'stdout',
      '--tessdata-dir',
      tessdataDir,
      '-l',
      language ?? this.language,
      '--psm',
      '$pageSegMode',
      '-c',
      'tessedit_create_hocr=1',
      '-c',
      'preserve_interword_spaces=1',
    ]);

    if (process.exitCode != 0) {
      throw OcrException(
        '$label: tesseract завершился с кодом ${process.exitCode}: '
        '${process.stderr}',
        userMessage: 'Не удалось распознать текст на фото',
        stage: 'tesseract',
      );
    }

    final parsed = TesseractTextEngine.parseHocr(process.stdout as String);
    return OcrResult(
      fullText: parsed.fullText,
      lines: parsed.lines,
      containsCyrillic: parsed.containsCyrillic,
      confidence: parsed.confidence,
      pass: label,
      words: parsed.words,
      hocr: parsed.hocr,
      sourcePath: imageFile.path,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// Имитация ML Kit на хосте: Tesseract только с латиницей.
///
/// На кириллических визитках ML Kit (latin) отдаёт латинский мусор — ровно то,
/// что делает Tesseract `eng`. Это позволяет замерять выбор движка
/// ([OcrService]), не имея Android-устройства.
class HostMlKitLikeEngine extends HostTesseractEngine {
  HostMlKitLikeEngine({required super.tessdataDir})
      : super(language: 'eng', label: 'ML Kit (host)');
}
