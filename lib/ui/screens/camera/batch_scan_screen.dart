import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../business/batch/batch_scan_cubit.dart';
import '../../../business/scan/scan_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../data/models/business_card.dart';
import '../edit/edit_card_screen.dart';

/// Пакетный режим: выбранные из галереи фото распознаются по очереди.
/// После завершения открывается последовательная проверка карточек.
class BatchScanScreen extends StatefulWidget {
  const BatchScanScreen({super.key, required this.paths});

  final List<String> paths;

  @override
  State<BatchScanScreen> createState() => _BatchScanScreenState();
}

class _BatchScanScreenState extends State<BatchScanScreen> {
  late final BatchScanCubit _cubit;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _cubit = BatchScanCubit(
      scannerFactory: createScanCubit,
      paths: widget.paths,
    )..start();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<BatchScanCubit, BatchScanState>(
      bloc: _cubit,
      listenWhen: (prev, curr) => !prev.done && curr.done,
      listener: (context, state) {
        if (_navigated) return;
        _navigated = true;
        Navigator.of(context).pushReplacement<void, void>(
          MaterialPageRoute(
            builder: (_) => BatchReviewScreen(
              results: state.results,
              cancelled: state.cancelled,
            ),
          ),
        );
      },
      builder: (context, state) => _BatchProgressView(
        state: state,
        onCancel: _cubit.cancel,
      ),
    );
  }
}

class _BatchProgressView extends StatelessWidget {
  const _BatchProgressView({required this.state, required this.onCancel});

  final BatchScanState state;
  final VoidCallback onCancel;

  String get _stageText => switch (state.stage) {
        ScanStage.preprocessing => 'Предобработка фото…',
        ScanStage.recognizing => 'Распознавание текста (на устройстве)…',
        ScanStage.parsing => 'Разбор полей визитки…',
        ScanStage.ready => 'Готово',
        _ => 'Подготовка…',
      };

  @override
  Widget build(BuildContext context) {
    final total = state.total;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        onCancel();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: const Text('Распознавание визиток'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Отменить',
            onPressed: onCancel,
          ),
        ),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Фото ${state.currentNumber} из $total',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : state.progress,
                      minHeight: 8,
                      backgroundColor: Colors.black12,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(strokeWidth: 4),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    _stageText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, color: Colors.black87),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'Фото не покидает устройство',
                    style: TextStyle(color: Colors.black45, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: onCancel,
                    child: const Text('Отменить очередь'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Последовательная проверка: открывает по одной карточке редактор.
/// Сохранённые попадают в список, пропущенные и неудачные учитываются
/// в итоговом сообщении.
class BatchReviewScreen extends StatefulWidget {
  const BatchReviewScreen({
    super.key,
    required this.results,
    this.cancelled = false,
    this.onProcessed,
  });

  final List<BatchScanResult> results;
  final bool cancelled;

  /// Вызывается после каждой карточки. [saved] — пользователь сохранил её.
  final Future<void> Function(BatchScanResult result, bool saved)? onProcessed;

  @override
  State<BatchReviewScreen> createState() => _BatchReviewScreenState();
}

class _BatchReviewScreenState extends State<BatchReviewScreen> {
  int _index = 0;
  int _saved = 0;
  int _skipped = 0;
  int _failed = 0;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _next());
  }

  Future<void> _next() async {
    if (!mounted || _finishing) return;
    if (_index >= widget.results.length) {
      _finish();
      return;
    }

    final result = widget.results[_index];
    final state = result.state;
    if (result.hasDraft) {
      final saved = await Navigator.of(context).push<BusinessCard>(
        MaterialPageRoute(
          builder: (_) => EditCardScreen(
            draft: state.draft!,
            warnings: state.warnings,
            unmatchedLines: state.unmatchedLines,
            emptyOcr: state.emptyOcr,
            diagnostic: state.diagnostic,
            ocrResult: state.ocrResult,
            processedImagePath: state.processedImagePath,
            variantPaths: state.variantPaths,
            autoWarped: state.autoWarped,
            batchIndex: _index + 1,
            batchTotal: widget.results.length,
          ),
        ),
      );
      if (saved != null) {
        _saved++;
      } else {
        _skipped++;
      }
      await widget.onProcessed?.call(result, saved != null);
    } else {
      _failed++;
      await widget.onProcessed?.call(result, false);
    }

    _index++;
    if (mounted) {
      setState(() {});
      await _next();
    }
  }

  void _finish() {
    if (_finishing || !mounted) return;
    _finishing = true;
    final messenger = ScaffoldMessenger.of(context);
    final total = widget.results.length;
    final parts = <String>[];
    if (total == 0) {
      parts.add('Обработка отменена');
    } else {
      parts.add('Сохранено $_saved из $total');
      if (_skipped > 0) parts.add('пропущено $_skipped');
      if (_failed > 0) parts.add('не распознано $_failed');
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(parts.join(', '))));
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.results.length;
    final current = (_index + 1).clamp(1, total == 0 ? 1 : total);
    return Scaffold(
      appBar: AppBar(title: const Text('Проверка визиток')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(strokeWidth: 4),
              ),
              const SizedBox(height: 20),
              Text(
                'Визитка $current из $total',
                style: const TextStyle(fontSize: 17),
              ),
              const SizedBox(height: 8),
              const Text(
                'Проверьте поля и сохраните карточку',
                style: TextStyle(color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
