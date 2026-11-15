import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/errors/app_exceptions.dart';
import '../models/business_card.dart';
import 'ocr_service.dart';

/// Расширенная диагностика OCR по запросу пользователя (кнопка
/// «Выгрузить диагностику»). Ничего не пишет в обычном режиме.
///
/// Файлы кладутся в публичную папку Download, чтобы их было видно
/// файловым менеджером без доступа к каталогу приложения:
/// `/storage/emulated/0/Download/VCContacts/diagnostics/<штамп>/`
///   * `hocr.html`  — сырой hOCR выбранного прохода (слова + bbox + x_wconf);
///   * `words.csv`  — слова с координатами и уверенностью;
///   * `<поле>.jpg` — вырезка области изображения напротив каждого поля
///     карточки (имя, компания, телефон, ...);
///   * `summary.txt` — что выбрал OCR, метрики, путь к обработанному фото.
///
/// Если доступа к публичной папке нет (нет разрешения) — тихий фолбэк на
/// app-specific external каталог приложения.
class DiagnosticService {
  const DiagnosticService();

  /// Публичный Download, если он доступен для записи; иначе — каталог
  /// приложения. Пытаемся писать именно в Download (см. докстринг).
  Future<Directory> _diagRoot() async {
    final external = await _externalDownload();
    if (external != null && await _isWritable(external)) {
      return Directory(
          p.join(external.path, 'Download', 'VCContacts', 'diagnostics'));
    }
    // Фолбэк: app-specific external (виден по /Android/data/<pkg>/files).
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } on Object {
      base = null;
    }
    base ??= await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, 'diagnostics'));
  }

  /// Запросить разрешение на запись в публичное хранилище.
  /// Возвращает true, если доступ есть/получен.
  Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;
    // Android 11+: MANAGE_EXTERNAL_STORAGE («Доступ ко всем файлам»).
    if (await Permission.manageExternalStorage.isGranted) return true;
    final managed = await Permission.manageExternalStorage.request();
    if (managed.isGranted) return true;
    // Android ≤ 10: обычная запись во внешнее хранилище.
    if (await Permission.storage.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  /// Общий корень внешнего хранилища (`/storage/emulated/0`), чтобы затем
  /// дописать `Download/VCContacts`. Именно общий путь, а не scoped-каталог
  /// приложения: диагностику нужно видеть в файловом менеджере.
  Future<Directory?> _externalDownload() async {
    if (!Platform.isAndroid) return null;
    const candidates = [
      '/storage/emulated/0',
      '/sdcard',
    ];
    for (final c in candidates) {
      final dir = Directory(c);
      if (await dir.exists()) return dir;
    }
    return null;
  }

  Future<bool> _isWritable(Directory dir) async {
    try {
      await dir.create(recursive: true);
      final probe = File(p.join(dir.path, '.vcc_write_test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } on Object {
      return false;
    }
  }

  /// Сохранить диагностику одного скана. Возвращает каталог с файлами.
  Future<Directory> dump({
    required OcrResult? ocrResult,
    required String? processedImagePath,
    required List<String> variantPaths,
    required BusinessCard? card,
    required OcrDiagnostic? diagnostic,
    bool? autoWarped,
  }) async {
    try {
      // Пробуем получить доступ к публичному Download; если не выйдет —
      // _diagRoot тихо уедет в app-specific каталог.
      await ensurePermission();
      final root = await _diagRoot();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '_');
      final dir = Directory(p.join(root.path, stamp));
      await dir.create(recursive: true);

      await File(p.join(dir.path, 'summary.txt')).writeAsString(_summary(
          ocrResult, processedImagePath, variantPaths, card, diagnostic,
          autoWarped: autoWarped));

      // Машиночитаемый отчёт: тот же замерный стенд (P2) может оценить
      // поля на устройстве без ручного разбора summary.txt.
      await File(p.join(dir.path, 'result.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(
          _resultJson(
            ocrResult,
            processedImagePath,
            variantPaths,
            card,
            diagnostic,
            autoWarped: autoWarped,
          ),
        ),
      );

      final hocr = ocrResult?.hocr ?? '';
      if (hocr.isNotEmpty) {
        await File(p.join(dir.path, 'hocr.html')).writeAsString(hocr);
      }

      final words = ocrResult?.words ?? const <OcrWord>[];
      if (words.isNotEmpty) {
        await File(p.join(dir.path, 'words.csv'))
            .writeAsString(_wordsCsv(words));
      }

      if (card != null && processedImagePath != null && words.isNotEmpty) {
        // Вырезаем области из того кадра, который реально читался: после
        // поворота визитки координаты слов относятся к повёрнутой
        // картинке, а не к исходному фото.
        final source = (ocrResult?.sourcePath.isNotEmpty ?? false)
            ? ocrResult!.sourcePath
            : processedImagePath;
        await _cropFields(dir, source, words, card);
      }

      return dir;
    } on Exception catch (e) {
      throw DiagnosticException(
        'Не удалось сохранить диагностику: $e',
        userMessage: 'Не удалось выгрузить диагностику',
        cause: e,
      );
    }
  }

  // ------------------------------------------------------------------ summary

  /// Машиночитаемая версия диагностики (`result.json`).
  ///
  /// Формат стабилен по `schema_version`: поля карточки и полный текст можно
  /// сравнивать с эталоном на хосте тем же scorer'ом, что и `benchmark/`.
  Map<String, Object?> _resultJson(
    OcrResult? ocr,
    String? processedImagePath,
    List<String> variantPaths,
    BusinessCard? card,
    OcrDiagnostic? diagnostic, {
    bool? autoWarped,
  }) {
    return {
      'schema_version': 1,
      'generated_at': DateTime.now().toIso8601String(),
      'pass': ocr?.pass,
      'orientation_degrees': ocr?.orientationDegrees ?? 0,
      'tilt_degrees': ocr?.tiltDegrees ?? 0,
      'deskew_applied': ocr?.deskewApplied ?? false,
      'confidence': ocr?.confidence,
      'contains_cyrillic': ocr?.containsCyrillic,
      'full_text': ocr?.fullText ?? '',
      'lines': ocr?.lines ?? const <String>[],
      'words': [
        for (final w in ocr?.words ?? const <OcrWord>[])
          {
            'text': w.text,
            'left': w.left,
            'top': w.top,
            'right': w.right,
            'bottom': w.bottom,
            'confidence': w.confidence,
            'line_index': w.lineIndex,
          },
      ],
      'auto_warped': autoWarped,
      'card': card == null
          ? null
          : {
              'card_image_path': card.cardImagePath,
              'full_name': card.fullName,
              'position': card.position,
              'company': card.company,
              'phone': card.phone,
              'phone_raw': card.phoneRaw,
              'email': card.email,
              'website': card.website,
              'address': card.address,
              'other_text': card.otherText,
            },
      'processed_image': processedImagePath,
      'variants': variantPaths,
      'diagnostic': diagnostic == null
          ? null
          : {
              'chosen': diagnostic.chosen,
              'chosen_chars': diagnostic.chosenChars,
              'engines': [
                for (final e in diagnostic.engines)
                  {
                    'name': e.name,
                    'error': e.error,
                    'line_count': e.lineCount,
                    'char_count': e.charCount,
                    'has_cyrillic': e.hasCyrillic,
                    'preview': e.preview,
                    'confidence': e.confidence,
                  },
              ],
              'timings': [
                for (final t in diagnostic.timings)
                  {'stage': t.stage, 'milliseconds': t.milliseconds},
              ],
              'regions': [
                for (final r in diagnostic.regions)
                  {
                    'index': r.index,
                    'source': r.source,
                    'language': r.language,
                    'text': r.text,
                    'left': r.left,
                    'top': r.top,
                    'right': r.right,
                    'bottom': r.bottom,
                    'confidence': r.confidence,
                  },
              ],
              'geometry': diagnostic.geometry == null
                  ? null
                  : {
                      'median_angle_degrees':
                          diagnostic.geometry!.medianAngleDegrees,
                      'regions_total': diagnostic.geometry!.regionsTotal,
                      'regions_mlkit': diagnostic.geometry!.regionsMlKit,
                      'regions_rectified':
                          diagnostic.geometry!.regionsRectified,
                      'image_regions': diagnostic.geometry!.imageRegions,
                      'rotation_applied':
                          diagnostic.geometry!.rotationApplied,
                      'orientation_degrees':
                          diagnostic.geometry!.orientationDegrees,
                    },
              'image_boxes': [
                for (final b in diagnostic.imageBoxes)
                  {
                    'left': b.left,
                    'top': b.top,
                    'right': b.right,
                    'bottom': b.bottom,
                  },
              ],
              'english_regions': diagnostic.englishRegions,
            },
    };
  }

  String _summary(
    OcrResult? ocr,
    String? processedImagePath,
    List<String> variantPaths,
    BusinessCard? card,
    OcrDiagnostic? diagnostic, {
    bool? autoWarped,
  }) {
    final b = StringBuffer()
      ..writeln('=== OCR-диагностика VCContacts ===')
      ..writeln('Время: ${DateTime.now().toIso8601String()}')
      ..writeln('Проход: ${ocr?.pass ?? '-'}')
      ..writeln('Уверенность: '
          '${((ocr?.confidence ?? 0) * 100).toStringAsFixed(1)}%')
      ..writeln('Слов: ${ocr?.words.length ?? 0}')
      ..writeln('Обработанное фото: ${processedImagePath ?? '-'}')
      ..writeln('Варианты:');
    for (final v in variantPaths) {
      b.writeln('  - $v');
    }
    if (autoWarped != null) {
      b.writeln('Визитка выпрямлена: ${autoWarped ? 'да' : 'нет'}');
    }

    if (diagnostic != null) {
      b
        ..writeln()
        ..writeln('--- Движки ---');
      for (final d in diagnostic.engines) {
        b.writeln('${d.name}: '
            '${d.failed ? 'ошибка: ${d.error}' : '${d.charCount} симв., '
                'увер. ${(d.confidence * 100).toStringAsFixed(0)}%'}');
      }
      b.writeln('Выбран: ${diagnostic.chosen ?? '-'} '
          '(${diagnostic.chosenChars} симв.)');

      final geometry = diagnostic.geometry;
      if (geometry != null) {
        b
          ..writeln()
          ..writeln('--- Геометрия ---')
          ..writeln('Средний наклон строк: '
              '${geometry.medianAngleDegrees.toStringAsFixed(1)}°'
              '${geometry.rotationApplied ? ' (кадр повёрнут)' : ''}')
          ..writeln('Ориентация кадра: ${geometry.orientationDegrees}°')
          ..writeln('Текстовых областей: ${geometry.regionsTotal} '
              '(Tesseract: ${geometry.regionsRectified}, '
              'ML Kit: ${geometry.regionsMlKit})')
          ..writeln('Областей-картинок выбелено: ${geometry.imageRegions}');
      }

      if (diagnostic.regions.isNotEmpty) {
        b
          ..writeln()
          ..writeln('--- Области ---');
        for (final r in diagnostic.regions) {
          b.writeln('#${r.index + 1} [${r.source}, ${r.language}] '
              '(${r.left},${r.top})-(${r.right},${r.bottom}), '
              '${r.chars} симв.: ${r.text}');
        }
      }

      if (diagnostic.timings.isNotEmpty) {
        b
          ..writeln()
          ..writeln('--- Временные затраты ---');
        var total = 0;
        for (final t in diagnostic.timings) {
          total += t.milliseconds;
          b.writeln('${t.stage}: ${t.milliseconds} мс');
        }
        b.writeln('Итого OCR: $total мс');
        final slowest = [...diagnostic.timings]
          ..sort((a, b) => b.milliseconds.compareTo(a.milliseconds));
        b.writeln('Самые долгие: '
            '${slowest.take(3).map((t) => '${t.stage} ${t.milliseconds} мс').join(' · ')}');
      }
    }

    if (card != null) {
      b
        ..writeln()
        ..writeln('--- Распознанные поля ---');
      void f(String label, String v) {
        if (v.trim().isNotEmpty) b.writeln('$label: $v');
      }

      f('Имя', card.fullName);
      f('Должность', card.position);
      f('Компания', card.company);
      f('Телефон', card.phone);
      f('Email', card.email);
      f('Сайт', card.website);
      f('Адрес', card.address);
      f('Заметки', card.notes);
      f('Прочий текст', card.otherText);
    }

    if (ocr != null && ocr.fullText.isNotEmpty) {
      b
        ..writeln()
        ..writeln('--- Полный текст ---')
        ..writeln(ocr.fullText);
    }
    return b.toString();
  }

  // --------------------------------------------------------------- words.csv

  String _wordsCsv(List<OcrWord> words) {
    final b = StringBuffer('text,left,top,right,bottom,confidence,line\n');
    for (final w in words) {
      final text = '"${w.text.replaceAll('"', '""')}"';
      b.writeln('$text,${w.left},${w.top},${w.right},${w.bottom},'
          '${w.confidence.toStringAsFixed(3)},${w.lineIndex}');
    }
    return b.toString();
  }

  // ---------------------------------------------------------------- вырезки

  /// Для каждого непустого поля карточки находим слова OCR, чей текст входит
  /// в значение поля (по вхождению без регистра) и вырезаем объединённый
  /// bbox из обработанного изображения. Имя файла — латиницей.
  Future<void> _cropFields(
    Directory dir,
    String imagePath,
    List<OcrWord> words,
    BusinessCard card,
  ) async {
    final src = File(imagePath);
    if (!await src.exists()) return;
    final decoded = img.decodeImage(await src.readAsBytes());
    if (decoded == null) return;

    final fields = <String, String>{
      'name': card.fullName,
      'position': card.position,
      'company': card.company,
      'phone': card.phone,
      'email': card.email,
      'website': card.website,
      'address': card.address,
    };

    for (final entry in fields.entries) {
      final value = entry.value.trim();
      if (value.isEmpty) continue;
      final box = _boundingBox(words, value);
      if (box == null) continue;

      const pad = 6;
      final x = (box.$1 - pad).clamp(0, decoded.width - 1);
      final y = (box.$2 - pad).clamp(0, decoded.height - 1);
      final w = (box.$3 - box.$1 + pad * 2).clamp(1, decoded.width - x);
      final h = (box.$4 - box.$2 + pad * 2).clamp(1, decoded.height - y);

      final crop = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
      final out = File(p.join(dir.path, '${entry.key}.jpg'));
      await out.writeAsBytes(img.encodeJpg(crop, quality: 92));
    }
  }

  /// Объединяющий bbox слов, входящих в [value]. Возвращает
  /// `(left, top, right, bottom)` или null, если совпадений нет.
  (int, int, int, int)? _boundingBox(List<OcrWord> words, String value) {
    final norm = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final tokens = norm
        .split(RegExp(r'[^0-9a-zа-яё]+'))
        .where((t) => t.length >= 2)
        .toSet();
    if (tokens.isEmpty) return null;

    int? left, top, right, bottom;
    for (final w in words) {
      final wt = w.text.toLowerCase();
      final hit = tokens.any((t) => wt.contains(t) || t.contains(wt));
      if (!hit) continue;
      left = left == null ? w.left : (w.left < left ? w.left : left);
      top = top == null ? w.top : (w.top < top ? w.top : top);
      right = right == null ? w.right : (w.right > right ? w.right : right);
      bottom =
          bottom == null ? w.bottom : (w.bottom > bottom ? w.bottom : bottom);
    }
    if (left == null) return null;
    return (left, top!, right!, bottom!);
  }
}
