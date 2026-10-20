import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../business/scan/scan_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../core/errors/app_exceptions.dart';
import '../../../data/models/business_card.dart';
import '../../../data/services/image_preprocessor.dart';
import '../../../data/services/ocr_service.dart';
import '../../widgets/ocr_diagnostic_panel.dart';
import '../edit/edit_card_screen.dart';

/// Экран пайплайна: предобработка -> OCR -> парсинг.
/// По готовности черновика заменяет себя экраном проверки/редактирования.
class ScanFlowScreen extends StatefulWidget {
  const ScanFlowScreen({
    super.key,
    required this.sourcePath,
    this.crop = const CropRegion(),
  });

  final String sourcePath;
  final CropRegion crop;

  @override
  State<ScanFlowScreen> createState() => _ScanFlowScreenState();
}

class _ScanFlowScreenState extends State<ScanFlowScreen> {
  late final ScanCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = ScanCubit(
      ocrService: sl(),
      preprocessor: sl(),
      parser: sl(),
    )..processImage(widget.sourcePath, crop: widget.crop);
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ScanCubit, ScanState>(
      bloc: _cubit,
      listenWhen: (prev, curr) => prev.stage != curr.stage,
      listener: (context, state) {
        if (state.stage == ScanStage.ready && state.draft != null) {
          // Заменяем поток экраном проверки: «назад» из редактора
          // ведёт сразу к списку, минуя промежуточные шаги.
          Navigator.of(context).pushReplacement<void, void>(
            MaterialPageRoute(
              builder: (_) => EditCardScreen(
                draft: state.draft!,
                warnings: state.warnings,
                unmatchedLines: state.unmatchedLines,
                emptyOcr: state.emptyOcr,
                diagnostic: state.diagnostic,
              ),
            ),
          );
        }
      },
      builder: (context, state) {
        if (state.stage == ScanStage.failed) {
          return _FailedView(
            error: state.error,
            diagnostic: state.diagnostic,
            onRetry: () => _cubit.retry(),
            onManual: () => _openManual(state.diagnostic),
            onClose: () => Navigator.of(context).pop(),
          );
        }
        return _ProgressView(stage: state.stage);
      },
    );
  }

  void _openManual(OcrDiagnostic? diagnostic) {
    final now = DateTime.now();
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute(
        builder: (_) => EditCardScreen(
          draft: BusinessCard(id: '', createdAt: now, updatedAt: now),
          warnings: const ['Заполните карточку вручную'],
          emptyOcr: true,
          diagnostic: diagnostic,
        ),
      ),
    );
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.stage});
  final ScanStage stage;

  static const _steps = [
    (ScanStage.preprocessing, 'Предобработка фото…'),
    (ScanStage.recognizing, 'Распознавание текста (на устройстве)…'),
    (ScanStage.parsing, 'Разбор полей визитки…'),
    (ScanStage.ready, 'Готово!'),
  ];

  @override
  Widget build(BuildContext context) {
    final currentIdx = _steps.indexWhere((s) => s.$1 == stage);
    final idx = currentIdx < 0 ? 0 : currentIdx;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(strokeWidth: 5),
                ),
                const SizedBox(height: 32),
                for (var i = 0; i < _steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          i < idx
                              ? Icons.check_circle
                              : i == idx
                                  ? Icons.radio_button_checked
                                  : Icons.circle_outlined,
                          size: 22,
                          color: i <= idx
                              ? Theme.of(context).colorScheme.primary
                              : Colors.black26,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _steps[i].$2,
                          style: TextStyle(
                            fontSize: 15,
                            color: i <= idx
                                ? Colors.black87
                                : Colors.black38,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
                const Text(
                  'Фото не покидает устройство',
                  style: TextStyle(color: Colors.black45, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FailedView extends StatelessWidget {
  const _FailedView({
    required this.error,
    required this.onRetry,
    required this.onManual,
    required this.onClose,
    this.diagnostic,
  });

  final AppException? error;
  final OcrDiagnostic? diagnostic;
  final VoidCallback onRetry;
  final VoidCallback onManual;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final isOcrEmpty = e is OcrException && e.stage == 'empty';
    final diag = diagnostic;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            Icon(
              isOcrEmpty ? Icons.text_fields_outlined : Icons.error_outline,
              size: 64,
              color: Colors.black26,
            ),
            const SizedBox(height: 16),
            Text(
              e?.userMessage ?? e?.message ?? 'Не удалось обработать фото',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            if (e != null && e.userMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                '${e.runtimeType}: ${e.message}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.black45),
              ),
            ],
            const SizedBox(height: 20),
            if (diag != null) OcrDiagnosticPanel(diagnostic: diag),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: isOcrEmpty ? onManual : onRetry,
              child: Text(isOcrEmpty ? 'Заполнить вручную' : 'Повторить'),
            ),
            TextButton(
              onPressed: onClose,
              child: const Text('Закрыть'),
            ),
          ],
        ),
      ),
    );
  }
}
