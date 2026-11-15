import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../business/batch/batch_scan_cubit.dart';
import '../../../business/scan/scan_cubit.dart';
import '../../../business/scan/scan_queue_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../data/models/business_card.dart';
import '../../widgets/queue_voice_note_button.dart';
import '../camera/batch_scan_screen.dart';
import '../edit/edit_card_screen.dart';

/// Очередь карточек, которые распознали в фоне, но ещё не сохранили.
///
/// Разбор — обычный последовательный редактор, как после пакетного скана:
/// сохранили — job уходит из очереди, пропустили — остаётся на потом.
class VerificationQueueScreen extends StatefulWidget {
  const VerificationQueueScreen({super.key});

  @override
  State<VerificationQueueScreen> createState() =>
      _VerificationQueueScreenState();
}

class _VerificationQueueScreenState extends State<VerificationQueueScreen> {
  final _queue = sl<ScanQueueCubit>();

  Future<void> _openJob(ScanJob job) async {
    if (!job.canReview) return;
    final draft = job.draft;
    if (draft == null) return;
    final state = job.toScanState();
    final saved = await Navigator.of(context).push<BusinessCard>(
      MaterialPageRoute(
        builder: (_) => EditCardScreen(
          draft: draft,
          warnings: state.warnings,
          unmatchedLines: state.unmatchedLines,
          emptyOcr: state.emptyOcr,
          diagnostic: state.diagnostic,
          ocrResult: state.ocrResult,
          processedImagePath: state.processedImagePath,
          variantPaths: state.variantPaths,
          autoWarped: state.autoWarped,
        ),
      ),
    );
    if (saved != null) {
      await _queue.remove(job.id);
    }
  }

  Future<void> _reviewAll(List<ScanJob> ready) async {
    if (ready.isEmpty) return;
    final results = [
      for (final job in ready)
        BatchScanResult(path: job.id, state: job.toScanState()),
    ];
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BatchReviewScreen(
          results: results,
          onProcessed: (result, saved) async {
            if (saved) await _queue.remove(result.path);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScanQueueCubit, ScanQueueState>(
      bloc: _queue,
      builder: (context, state) {
        final ready = state.jobs.where((j) => j.canReview).toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Очередь проверки'),
            actions: [
              if (ready.isNotEmpty)
                IconButton(
                  tooltip: 'Проверить все',
                  onPressed: () => _reviewAll(ready),
                  icon: const Icon(Icons.playlist_add_check),
                ),
            ],
          ),
          body: state.jobs.isEmpty
              ? const _EmptyQueue()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  itemCount: state.jobs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final job = state.jobs[i];
                    return _QueueJobTile(
                      job: job,
                      onOpen: job.canReview ? () => _openJob(job) : null,
                      onRetry: job.status == ScanJobStatus.failed
                          ? () => _queue.retry(job.id)
                          : null,
                      onTranscribe: () =>
                          _queue.retryVoiceNoteTranscription(job.id),
                    );
                  },
                ),
          bottomNavigationBar: ready.isEmpty
              ? null
              : SafeArea(
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: () => _reviewAll(ready),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: Text('Проверить все (${ready.length})'),
                  ),
                ),
        );
      },
    );
  }
}

class _QueueJobTile extends StatelessWidget {
  const _QueueJobTile({
    required this.job,
    required this.onOpen,
    required this.onRetry,
    required this.onTranscribe,
  });

  final ScanJob job;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;
  final VoidCallback onTranscribe;

  String get _statusText {
    if (job.voiceNoteTranscribing) return 'Распознаётся голосовая заметка…';
    switch (job.status) {
      case ScanJobStatus.queued:
        return 'Ожидает обработки';
      case ScanJobStatus.processing:
        return 'Распознаётся: ${_stageText(job.stage)}';
      case ScanJobStatus.ready:
        final warnings = job.warnings.where((w) => w.trim().isNotEmpty).length;
        return warnings == 0
            ? 'Готова к проверке'
            : 'Готова к проверке · предупреждений: $warnings';
      case ScanJobStatus.failed:
        return job.error?.userMessage ??
            job.error?.message ??
            'Не удалось распознать фото';
    }
  }

  static String _stageText(ScanStage stage) => switch (stage) {
        ScanStage.preprocessing => 'подготовка',
        ScanStage.recognizing => 'распознавание текста',
        ScanStage.parsing => 'разбор полей',
        _ => 'обработка',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = job.draft?.cardImagePath ?? job.sourcePath;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onOpen ?? onRetry,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 56,
              height: 56,
              color: const Color(0xFFF1F3F6),
              child: Icon(
                job.status == ScanJobStatus.failed
                    ? Icons.error_outline
                    : Icons.image_outlined,
                color: Colors.black26,
              ),
            ),
          ),
        ),
        title: Text(
          job.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              _statusText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: job.status == ScanJobStatus.failed
                    ? theme.colorScheme.error
                    : Colors.black54,
              ),
            ),
            if (job.voiceNotePath != null)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(
                  'Голосовая заметка прикреплена',
                  style: TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            QueueVoiceNoteButton(
              jobId: job.id,
              hasVoice: job.voiceNotePath != null,
            ),
            if (job.voiceNotePath != null &&
                job.voiceNoteTranscript == null &&
                !job.voiceNoteTranscribing)
              IconButton(
                tooltip: 'Распознать голосовую заметку',
                onPressed: onTranscribe,
                icon: const Icon(Icons.text_fields),
              ),
            if (job.status == ScanJobStatus.processing ||
                job.voiceNoteTranscribing)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (job.status == ScanJobStatus.failed)
              IconButton(
                tooltip: 'Повторить',
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
              )
            else if (job.canReview)
              const Icon(Icons.chevron_right, color: Colors.black26),
          ],
        ),
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fact_check_outlined,
                size: 72, color: Colors.black26),
            const SizedBox(height: 16),
            const Text(
              'Очередь пуста',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Отсканируйте визитку — распознавание пойдёт в фоне, '
              'а карточка появится здесь перед сохранением.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black.withOpacity(0.5)),
            ),
          ],
        ),
      ),
    );
  }
}
