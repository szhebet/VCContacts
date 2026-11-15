import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../scan/scan_cubit.dart';

/// Результат обработки одного фото в пакете: либо готовый черновик,
/// либо ошибка (этап `failed`).
class BatchScanResult extends Equatable {
  const BatchScanResult({required this.path, required this.state});

  final String path;
  final ScanState state;

  bool get hasDraft =>
      state.stage == ScanStage.ready && state.draft != null;

  @override
  List<Object?> get props => [path, state];
}

/// Состояние пакетной очереди: какие фото в очереди, какое обрабатывается
/// сейчас и что уже готово.
class BatchScanState extends Equatable {
  const BatchScanState({
    this.paths = const [],
    this.index = 0,
    this.stage = ScanStage.idle,
    this.results = const [],
    this.done = false,
    this.cancelled = false,
  });

  /// Все выбранные фото (в порядке выбора).
  final List<String> paths;

  /// Индекс текущего фото (0-based); после завершения равен числу
  /// обработанных.
  final int index;

  /// Этап текущего фото.
  final ScanStage stage;

  /// Уже обработанные фото (успех или ошибка).
  final List<BatchScanResult> results;

  /// Очередь закончена (все обработаны или отменена).
  final bool done;

  /// Пользователь нажал «Отмена».
  final bool cancelled;

  int get total => paths.length;
  int get completed => results.length;
  int get currentNumber => (index + 1).clamp(1, total == 0 ? 1 : total);

  double get progress => total == 0 ? 0 : completed / total;

  BatchScanState copyWith({
    List<String>? paths,
    int? index,
    ScanStage? stage,
    List<BatchScanResult>? results,
    bool? done,
    bool? cancelled,
  }) {
    return BatchScanState(
      paths: paths ?? this.paths,
      index: index ?? this.index,
      stage: stage ?? this.stage,
      results: results ?? this.results,
      done: done ?? this.done,
      cancelled: cancelled ?? this.cancelled,
    );
  }

  @override
  List<Object?> get props => [
        paths,
        index,
        stage,
        results,
        done,
        cancelled,
      ];
}

/// Пакетная очередь: обрабатывает выбранные фото **по одному**, чтобы не
/// держать в памяти несколько OCR-прогонов и не конкурировать за движки.
///
/// Сервисы ([OcrService], препроцессор) — singleton в DI, поэтому очередь
/// создаёт отдельный [CardScanner] на фото, но переиспользует движки.
class BatchScanCubit extends Cubit<BatchScanState> {
  BatchScanCubit({
    required this.scannerFactory,
    required List<String> paths,
  }) : super(BatchScanState(paths: List.unmodifiable(paths)));

  /// Фабрика пайплайна одного фото (в приложении — `createScanCubit`).
  final CardScanner Function() scannerFactory;

  bool _cancelled = false;

  /// Запускает очередь. Повторный вызов игнорируется, если уже идёт.
  Future<void> start() async {
    if (state.done || state.index > 0) return;
    final paths = state.paths;
    final results = <BatchScanResult>[];

    for (var i = 0; i < paths.length; i++) {
      if (_cancelled || isClosed) break;
      emit(BatchScanState(
        paths: paths,
        index: i,
        stage: ScanStage.idle,
        results: List<BatchScanResult>.of(results),
        cancelled: _cancelled,
      ));

      final scanner = scannerFactory();
      final sub = scanner.stream.listen((s) {
        if (isClosed) return;
        emit(BatchScanState(
          paths: paths,
          index: i,
          stage: s.stage,
          results: List<BatchScanResult>.of(results),
          cancelled: _cancelled,
        ));
      });

      try {
        await scanner.processImage(paths[i]);
      } finally {
        await sub.cancel();
      }
      results.add(BatchScanResult(path: paths[i], state: scanner.state));
      try {
        await scanner.close();
      } on Object {
        // Закрытие одного сканера не должно ронять очередь.
      }
    }

    if (isClosed) return;
    emit(BatchScanState(
      paths: paths,
      index: results.length,
      results: List<BatchScanResult>.of(results),
      done: true,
      cancelled: _cancelled,
    ));
  }

  /// Отмена: текущее фото дорабатывается, остальные пропускаются.
  void cancel() {
    if (state.done) return;
    _cancelled = true;
    if (!isClosed) emit(state.copyWith(cancelled: true));
  }
}
