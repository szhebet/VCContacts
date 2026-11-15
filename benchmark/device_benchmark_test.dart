import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vc_contacts/data/services/card_parser.dart';

import 'support/scoring.dart';

/// Замер **на реальном тексте с устройства**: берём `full_text` из
/// диагностик (`benchmark/device_corpus/*.json`), прогоняем через
/// текущий `CardParser` и сравниваем поля с эталоном карточки.
///
/// Корпус диагностик и эталоны (`device_expected.json`) — персональные
/// данные, в git не попадают. Для запуска скопируйте
/// `device_expected.example.json` в `device_expected.json` и положите
/// локальные `result.json` в `device_corpus/`.
///
/// Зачем: хост-стенд (`ocr_benchmark_test.dart`) меряет только полнокадровый
/// резерв — ML Kit на хосте нет. Основной путь на устройстве (разметка ML Kit
/// → нарезка → Tesseract/ML Kit) в нём не участвует, поэтому его
/// оптимизации не видны в `results.csv`. Здесь используется уже готовый
/// текст устройства, и видно, как парсер вытаскивает поля из того, что
/// реально вернул OCR.
///
/// Запуск:
///   flutter test benchmark/device_benchmark_test.dart
///
/// Записать строку в `benchmark/results_device.csv`:
///   BENCH_CHANGE=1 BENCH_DESC="..." BENCH_FIX="..." \
///     flutter test benchmark/device_benchmark_test.dart
void main() {
  test(
    'device diagnostics replay (parser only)',
    () async {
      final root = Platform.environment['VCC_ROOT'] ?? Directory.current.path;
      // Фиксированный корпус: копии result.json с устройства. Так метрика
      // не «плывёт» при каждом новом прогоне на телефоне.
      final diagnostics = Directory(p.join(root, 'benchmark', 'device_corpus'));
      if (!diagnostics.existsSync()) {
        // ignore: avoid_print
        print('нет benchmark/device_corpus — пропускаем');
        return;
      }

      final expectedFile =
          File(p.join(root, 'benchmark', 'device_expected.json'));
      if (!expectedFile.existsSync()) {
        // ignore: avoid_print
        print('нет benchmark/device_expected.json — пропускаем. '
            'Скопируйте device_expected.example.json и заполните локально.');
        return;
      }
      final specs = ((jsonDecode(await expectedFile.readAsString())
                  as Map<String, dynamic>)['cards'] as List<dynamic>)
          .map((e) => _ExpectedCard.fromJson(e as Map<String, dynamic>))
          .toList();

      final parser = CardParser();
      final runs = <Map<String, dynamic>>[];
      var scoreSum = 0.0;
      var correctTotal = 0;
      var fieldsTotal = 0;

      final files = diagnostics.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.json'),
          ).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final json = jsonDecode(await file.readAsString())
            as Map<String, dynamic>;
        final text = (json['full_text'] as String? ?? '').trim();
        if (text.length < 20) continue;

        final spec = _matchCard(text, specs);
        if (spec == null) continue;
        final fields = spec.fields;

        final parsed = parser.parse(
          text,
          ocrLines: (json['lines'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList(),
        );
        final actual = {
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

        final checks = <String, bool>{};
        for (final field in fields.keys) {
          checks[field] = fieldMatch(field, fields[field]!, actual[field] ?? '');
        }
        final correct = checks.values.where((v) => v).length;
        final total = checks.length;
        scoreSum += total == 0 ? 0.0 : correct / total;
        correctTotal += correct;
        fieldsTotal += total;

        runs.add({
          'diagnostics': p.basenameWithoutExtension(file.path),
          'card': spec.type,
          'pass': json['pass'],
          'orientation': json['orientation_degrees'],
          'score': double.parse((correct / total * 100).toStringAsFixed(1)),
          'correct': correct,
          'fields': total,
          'checks': checks,
          'actual': actual,
          'text': text,
        });
      }

      final score = runs.isEmpty ? 0.0 : scoreSum / runs.length * 100;
      final report = {
        'generated_at': DateTime.now().toIso8601String(),
        'note': 'parser replay on device diagnostics full_text',
        'score': double.parse(score.toStringAsFixed(1)),
        'correct_fields': correctTotal,
        'total_fields': fieldsTotal,
        'runs': runs,
      };
      await File(p.join(root, 'benchmark', 'last_run_device.json'))
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));

      final lines = StringBuffer()
        ..writeln('Device replay: ${score.toStringAsFixed(1)}/100 '
            '($correctTotal/$fieldsTotal полей, ${runs.length} прогонов)')
        ..writeln('')
        ..writeln('| Диагностика | Карточка | Балл | Проход | Поворот |')
        ..writeln('|---|---|---:|---|---:|');
      for (final r in runs) {
        lines.writeln('| ${r['diagnostics']} | ${r['card']} | ${r['score']} | '
            '${r['pass']} | ${r['orientation']}° |');
      }
      // ignore: avoid_print
      print(lines);

      await _recordChange(root, score);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

class _ExpectedCard {
  const _ExpectedCard({
    required this.type,
    required this.keywords,
    required this.fields,
    this.cyrillic,
  });

  final String type;
  final List<String> keywords;
  final Map<String, String> fields;

  /// null — не важно; true/false — требование к наличию кириллицы.
  final bool? cyrillic;

  factory _ExpectedCard.fromJson(Map<String, dynamic> json) => _ExpectedCard(
        type: json['type'] as String? ?? 'unknown',
        keywords: (json['keywords'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().toLowerCase())
            .toList(),
        fields: (json['fields'] as Map<String, dynamic>? ?? const {})
            .map((k, v) => MapEntry(k, v.toString())),
        cyrillic: json['cyrillic'] as bool?,
      );
}

_ExpectedCard? _matchCard(String text, List<_ExpectedCard> cards) {
  final lower = text.toLowerCase();
  final hasCyrillic = RegExp(r'[а-яА-ЯёЁ]').hasMatch(text);
  for (final card in cards) {
    if (card.cyrillic != null && card.cyrillic != hasCyrillic) continue;
    if (card.keywords.any(lower.contains)) return card;
  }
  return null;
}

Future<void> _recordChange(String root, double score) async {
  final change = Platform.environment['BENCH_CHANGE'];
  if (change == null || change.trim().isEmpty) return;
  final desc = Platform.environment['BENCH_DESC'] ?? '';
  final fix = Platform.environment['BENCH_FIX'] ?? '';
  final file = File(p.join(root, 'benchmark', 'results_device.csv'));
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
