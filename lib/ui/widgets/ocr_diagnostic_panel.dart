import 'package:flutter/material.dart';

import '../../data/services/ocr_service.dart';

/// Постоянная панель диагностики OCR: что вернул каждый движок, кого
/// выбрали и первые строки распознанного текста.
///
/// Зачем: баннеры/ошибки на экране прогресса исчезали вместе с экраном
/// (экран заменялся), и пользователь не успевал прочитать, что пошло не
/// так. Панель живёт прямо на экране проверки — под баннерами и полями,
/// её можно раскрыть и приложить к обращению в поддержку.
class OcrDiagnosticPanel extends StatelessWidget {
  const OcrDiagnosticPanel({super.key, required this.diagnostic});

  final OcrDiagnostic diagnostic;

  /// Метка прохода (`base/psm3`, `sharp/psm6`, `ML Kit`) — в понятный вид.
  static String _humanPass(String pass) {
    if (!pass.contains('/')) return pass;
    final parts = pass.split('/');
    final variant = parts[0] == 'sharp' ? 'резкое фото' : 'основное фото';
    final psm = parts.length > 1 ? parts[1] : '';
    return 'Tesseract, $variant, $psm';
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: const Icon(Icons.bug_report_outlined, size: 20),
          title: const Text(
            'Диагностика OCR',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            diagnostic.chosen == null
                ? 'Текст не распознан'
                : 'Выбран: ${_humanPass(diagnostic.chosen!)} '
                    '(${diagnostic.chosenChars} симв.)',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          children: [
            if (diagnostic.geometry != null)
              _GeometryCard(geometry: diagnostic.geometry!),
            if (diagnostic.timings.isNotEmpty)
              _TimingsCard(timings: diagnostic.timings),
            if (diagnostic.regions.isNotEmpty)
              _RegionsCard(regions: diagnostic.regions),
            for (final engine in diagnostic.engines)
              _EngineCard(engine: engine),
          ],
        ),
      ),
    );
  }
}

/// Что сделала геометрия: наклон кадра, области и выбеленные картинки.
class _GeometryCard extends StatelessWidget {
  const _GeometryCard({required this.geometry});

  final OcrGeometryStat geometry;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: 'Геометрия',
      rows: [
        'Средний наклон строк: '
            '${geometry.medianAngleDegrees.toStringAsFixed(1)}°'
            '${geometry.rotationApplied ? ' (кадр повёрнут)' : ''}',
        'Текстовых областей: ${geometry.regionsTotal} '
            '(Tesseract: ${geometry.regionsRectified}, '
            'ML Kit: ${geometry.regionsMlKit})',
        'Областей-картинок выбелено: ${geometry.imageRegions}',
      ],
    );
  }
}

/// Сколько занял каждый этап распознавания.
class _TimingsCard extends StatelessWidget {
  const _TimingsCard({required this.timings});

  final List<OcrStageTiming> timings;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: 'Время по этапам',
      rows: [for (final t in timings) t.label],
    );
  }
}

/// Какие области в итоге дошли до движков.
class _RegionsCard extends StatelessWidget {
  const _RegionsCard({required this.regions});

  final List<OcrRegionStat> regions;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: 'Области',
      rows: [
        for (final r in regions)
          '#${r.index + 1} [${r.source}, ${r.language}] '
              '(${r.left},${r.top})-(${r.right},${r.bottom}), '
              '${r.chars} симв.: ${r.text}',
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.rows});

  final String title;
  final List<String> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: SelectableText(
                row,
                style: const TextStyle(fontSize: 12, height: 1.3),
              ),
            ),
        ],
      ),
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.engine});

  final EngineDiagnostic engine;

  @override
  Widget build(BuildContext context) {
    final color = engine.failed
        ? const Color(0xFFC62828)
        : engine.empty
            ? const Color(0xFFF9A825)
            : const Color(0xFF2E7D32);
    final status = engine.failed
        ? 'ошибка'
        : engine.empty
            ? 'пусто'
            : '${engine.charCount} симв., ${engine.lineCount} стр.';
    final conf = engine.failed || engine.empty
        ? null
        : 'увер. ${(engine.confidence * 100).round()}%';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  engine.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
            ],
          ),
          if (engine.failed) ...[
            const SizedBox(height: 6),
            Text(
              engine.error!,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ] else if (engine.preview.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (engine.hasCyrillic)
                  const Text(
                    'кириллица: да',
                    style: TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                if (conf != null) ...[
                  if (engine.hasCyrillic) const SizedBox(width: 10),
                  Text(
                    conf,
                    style: const TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.black12),
              ),
              child: SelectableText(
                engine.preview,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  height: 1.3,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
