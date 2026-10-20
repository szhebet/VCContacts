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
            for (final engine in diagnostic.engines) _EngineCard(engine: engine),
          ],
        ),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
