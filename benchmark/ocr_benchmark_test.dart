import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vc_contacts/data/services/card_parser.dart';
import 'package:vc_contacts/data/services/image_preprocessor.dart';
import 'package:vc_contacts/data/services/ocr_service.dart';

import 'support/host_engines.dart';
import 'support/scoring.dart';

/// Замерный стенд OCR на хосте (P2).
///
/// Зачем: на CI/хосте нет Android и ML Kit, но основной провал качества
/// (диагностика с устройства) происходит в полнокадровом резервном проходе
/// Tesseract. Стенд воспроизводит именно его: реальные `ImagePreprocessor`,
/// `OcrService`, `CardParser` + системный Tesseract CLI с теми же
/// `traineddata`, что вшиты в APK.
///
/// ML Kit имитируется Tesseract `eng`: на кириллице он так же отдаёт
/// латинский мусор, поэтому выбор движка и очистка строк проверяются
/// по-настоящему. Режим областей (ML Kit layout) на хосте недоступен — он
/// проверяется на устройстве.
///
/// Запуск:
///   flutter test benchmark/ocr_benchmark_test.dart
///
/// Записать строку в инкрементальную таблицу (`change_number,score,
/// description,fixes`):
///   BENCH_CHANGE=1 BENCH_DESC="P0: OSD-ориентация" \
///     BENCH_FIX="поворот кадра перед OCR" \
///     flutter test benchmark/ocr_benchmark_test.dart
void main() {
  test(
    'OCR quality benchmark on host Tesseract',
    () async {
      final root = Platform.environment['VCC_ROOT'] ?? Directory.current.path;
      final tessdata = p.join(root, 'assets', 'tessdata');
      final corpus = Directory(p.join(root, 'benchmark', 'corpus'));
      final expectedFile = File(p.join(root, 'benchmark', 'expected.json'));

      // Корпус и эталоны — персональные данные, в git не попадают.
      // На чистом клоне стенд просто пропускается.
      if (!corpus.existsSync() || !expectedFile.existsSync()) {
        // ignore: avoid_print
        print('benchmark: нет локальных данных (benchmark/corpus + '
            'benchmark/expected.json) — пропускаем. '
            'Скопируйте expected.example.json и положите фото в corpus/.');
        return;
      }

      expect(File(p.join(tessdata, 'rus.traineddata')).existsSync(), isTrue,
          reason: 'нет assets/tessdata/rus.traineddata');

      final expected = (jsonDecode(await expectedFile.readAsString())
          as Map<String, dynamic>)['cards'] as List<dynamic>;

      final workRoot = Directory(p.join(root, 'build', 'benchmark_work'));
      if (await workRoot.exists()) {
        await workRoot.delete(recursive: true);
      }
      await workRoot.create(recursive: true);

      final preprocessor = ImagePreprocessor(
        detector: null,
        detectCard: false,
        removeGraphics: true,
      );

      final ocr = OcrService(
        engine: HostMlKitLikeEngine(tessdataDir: tessdata),
        fallback: HostTesseractEngine(
          tessdataDir: tessdata,
          language: 'rus+eng',
        ),
        layoutAnalyzer: null,
        enableRegionPipeline: false,
        tesseractPageSegModes: const [3, 4],
      );

      final parser = CardParser();
      final cards = <Map<String, dynamic>>[];
      var scoreSum = 0.0;
      var correctTotal = 0;
      var fieldsTotal = 0;
      final totalWatch = Stopwatch()..start();

      for (final entry in expected.cast<Map<String, dynamic>>()) {
        final image = entry['image'] as String;
        final expectedFields =
            (entry['fields'] as Map<String, dynamic>).cast<String, String>();
        final source = File(p.join(corpus.path, image));

        final outDir = Directory(
            p.join(workRoot.path, image.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')));
        await outDir.create(recursive: true);

        Map<String, String> actual = const {};
        var text = '';
        var pass = '';
        var confidence = 0.0;
        var error = '';
        var preprocessMs = 0;
        var ocrMs = 0;
        var parseMs = 0;
        var orientation = 0;
        List<String> warnings = const [];

        final preWatch = Stopwatch()..start();
        try {
          final prepared = await preprocessor.prepare(
            source.path,
            outDir: outDir,
          );
          preprocessMs = preWatch.elapsedMilliseconds;

          final ocrWatch = Stopwatch()..start();
          final result = await ocr.recognizeFromFile(
            prepared.file.path,
            variants: prepared.variants.map((f) => f.path).toList(),
            segmentSource: prepared.colorSource?.path,
          );
          ocrMs = ocrWatch.elapsedMilliseconds;
          orientation = result.orientationDegrees;
          text = result.fullText;
          pass = result.pass;
          confidence = result.confidence;
          warnings = prepared.warnings;

          final parseWatch = Stopwatch()..start();
          final parsed = parser.parse(
            result.fullText,
            ocrLines: result.lines,
            containsCyrillic: result.containsCyrillic,
          );
          parseMs = parseWatch.elapsedMilliseconds;
          actual = {
            'name': parsed.card.fullName,
            'position': parsed.card.position,
            'company': parsed.card.company,
            'phone': parsed.card.phoneRaw.isNotEmpty
                ? parsed.card.phoneRaw
                : parsed.card.phone,
            'email': parsed.card.email,
            'website': parsed.card.website,
            'address': parsed.card.address,
          };
        } on Object catch (e) {
          error = e.toString();
        }

        final checks = <String, bool>{};
        for (final field in expectedFields.keys) {
          checks[field] = fieldMatch(
            field,
            expectedFields[field]!,
            actual[field] ?? '',
          );
        }
        final cardCorrect = checks.values.where((v) => v).length;
        final cardTotal = checks.length;
        final cardScore = cardTotal == 0 ? 0.0 : cardCorrect / cardTotal;
        scoreSum += cardScore;
        correctTotal += cardCorrect;
        fieldsTotal += cardTotal;

        cards.add({
          'image': image,
          'note': entry['note'] ?? '',
          'score': double.parse((cardScore * 100).toStringAsFixed(1)),
          'correct': cardCorrect,
          'fields': cardTotal,
          'checks': checks,
          'expected': expectedFields,
          'actual': actual,
          'text': text,
          'pass': pass,
          'confidence': double.parse(confidence.toStringAsFixed(3)),
          'orientation': orientation,
          'error': error,
          'warnings': warnings,
          'timings_ms': {
            'preprocess': preprocessMs,
            'ocr': ocrMs,
            'parse': parseMs,
          },
        });
      }

      final score = expected.isEmpty ? 0.0 : scoreSum / expected.length * 100;

      final report = {
        'generated_at': DateTime.now().toIso8601String(),
        'engine': 'host tesseract 5.x; ML Kit emulated by tesseract eng',
        'score': double.parse(score.toStringAsFixed(1)),
        'correct_fields': correctTotal,
        'total_fields': fieldsTotal,
        'total_ms': totalWatch.elapsedMilliseconds,
        'cards': cards,
      };

      final reportFile = File(p.join(root, 'benchmark', 'last_run.json'));
      await reportFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );

      final lines = StringBuffer()
        ..writeln('OCR benchmark: ${score.toStringAsFixed(1)}/100 '
            '($correctTotal/$fieldsTotal полей, '
            '${totalWatch.elapsedMilliseconds} мс)')
        ..writeln('')
        ..writeln('| Карточка | Балл | Поворот | Проход | Увер. | OCR, мс |')
        ..writeln('|---|---:|---:|---|---:|---:|');
      for (final c in cards) {
        final timings = c['timings_ms'] as Map<String, dynamic>;
        lines.writeln('| ${c['image']} | ${c['score']} | ${c['orientation']}° | '
            '${c['pass']} | ${c['confidence']} | ${timings['ocr']} |');
      }
      // ignore: avoid_print
      print(lines);

      await _recordChange(root, score);
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// Дописывает строку в `benchmark/results.csv`, если заданы
/// `BENCH_CHANGE` и `BENCH_DESC`. Колонка `fixes` (что конкретно
/// исправлено в итерации) берётся из `BENCH_FIX`. Повторный запуск того
/// же изменения обновляет его строку, а не дублирует.
Future<void> _recordChange(String root, double score) async {
  final change = Platform.environment['BENCH_CHANGE'];
  if (change == null || change.trim().isEmpty) return;
  final desc = Platform.environment['BENCH_DESC'] ?? '';
  final fix = Platform.environment['BENCH_FIX'] ?? '';
  final file = File(p.join(root, 'benchmark', 'results.csv'));
  final rows = <String>[];
  if (await file.exists()) {
    rows.addAll((await file.readAsLines())
        .where((line) => line.trim().isNotEmpty)
        .skip(1));
  }
  String quote(String value) => '"${value.replaceAll('"', '""')}"';
  rows.removeWhere((row) => row.split(',').first == change);
  rows.add('$change,${score.toStringAsFixed(1)},${quote(desc)},${quote(fix)}');
  rows.sort((a, b) {
    final ai = int.tryParse(a.split(',').first) ?? 0;
    final bi = int.tryParse(b.split(',').first) ?? 0;
    return ai.compareTo(bi);
  });
  await file.writeAsString(
    'change_number,score,description,fixes\n${rows.join('\n')}\n',
  );
}

/// Время этапов из отчёта не сохраняем в OcrResult — для стенда достаточно
/// общего времени OCR.
