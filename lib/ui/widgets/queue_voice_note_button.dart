import 'package:flutter/material.dart';

import '../../business/scan/scan_queue_cubit.dart';
import '../../core/di/injector.dart';
import '../../core/errors/app_exceptions.dart';
import '../../data/services/voice_note_service.dart';
import '../../data/services/voice_note_transcriber.dart';
import 'voice_recorder_sheet.dart';

/// Кнопка «микрофон» для карточки в очереди распознавания.
///
/// Работает и пока идёт OCR: заметка сохранится в job и переедет в черновик.
class QueueVoiceNoteButton extends StatelessWidget {
  const QueueVoiceNoteButton({
    super.key,
    required this.jobId,
    this.hasVoice = false,
  });

  /// Карточка очереди, к которой прикрепляется/перезаписывается заметка.
  final String jobId;
  final bool hasVoice;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: hasVoice
          ? 'Перезаписать голосовую заметку'
          : 'Добавить голосовую заметку',
      icon: Icon(hasVoice ? Icons.mic : Icons.mic_none),
      onPressed: () => _record(context),
    );
  }

  Future<void> _record(BuildContext context) async {
    final queue = sl<ScanQueueCubit>();
    final messenger = ScaffoldMessenger.of(context);

    if (!await sl<VoiceNoteTranscriber>().isModelInstalled()) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Модель речи не установлена — текст не распознается. '
            'Скачайте её в меню «Модель распознавания речи».',
          ),
        ),
      );
    }

    final waitForOcr = queue.state.jobs
        .any((j) => j.status == ScanJobStatus.processing);
    final waiting = waitForOcr
        ? messenger.showSnackBar(
            const SnackBar(
              content: Text('Завершаем текущее распознавание…'),
              duration: Duration(seconds: 30),
            ),
          )
        : null;

    // Не запускаем запись одновременно с OCR — из-за этого приложение
    // зависало. Текущая задача дорабатывает, новые ждут.
    await queue.acquireRecording();
    waiting?.close();

    try {
      if (!context.mounted) return;
      final recording = await showModalBottomSheet<VoiceRecording>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => VoiceRecorderSheet(cardId: jobId),
      );
      if (recording == null) return;
      final attached = await queue.attachVoiceNote(jobId, recording);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            attached
                ? 'Голосовая заметка прикреплена'
                : 'Карточка уже убрана из очереди — запись удалена',
          ),
        ),
      );
    } on AppException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.userMessage ?? e.message)),
      );
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось прикрепить заметку: $e')),
      );
    } finally {
      queue.releaseRecording();
    }
  }
}
