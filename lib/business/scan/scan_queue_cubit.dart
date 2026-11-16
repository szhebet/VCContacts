import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors/app_exceptions.dart';
import '../../data/models/business_card.dart';
import '../../data/repositories/card_repository.dart';
import '../../data/services/card_photo_service.dart';
import '../../data/services/image_preprocessor.dart';
import '../../data/services/ocr_service.dart';
import '../../data/services/scan_background_service.dart';
import '../../data/services/scan_queue_store.dart';
import '../../data/services/voice_note_service.dart';
import '../../data/services/voice_note_transcriber.dart';
import 'scan_cubit.dart';

/// Статус одного фото в фоновой очереди распознавания.
enum ScanJobStatus { queued, processing, ready, failed }

const _unset = Object();

/// Одно фото, поставленное в фоновую обработку.
///
/// Пока идёт OCR, карточки ещё нет в БД: черновик появится в [draft] после
/// стадии `ready`, а голосовую заметку можно прикрепить даже во время
/// распознавания — она переедет в черновик и сохранится вместе с карточкой.
class ScanJob extends Equatable {
  const ScanJob({
    required this.id,
    required this.sourcePath,
    required this.createdAt,
    this.crop = const CropRegion(),
    this.rotationDegrees = 0,
    this.status = ScanJobStatus.queued,
    this.stage = ScanStage.idle,
    this.draft,
    this.warnings = const [],
    this.unmatchedLines = const [],
    this.emptyOcr = false,
    this.diagnostic,
    this.processedImagePath,
    this.variantPaths = const [],
    this.ocrResult,
    this.autoWarped = false,
    this.error,
    this.voiceNotePath,
    this.voiceNoteDurationMs = 0,
    this.voiceNoteTranscribing = false,
    this.voiceNoteTranscript,
  });

  final String id;
  final String sourcePath;
  final CropRegion crop;
  final double rotationDegrees;
  final DateTime createdAt;

  final ScanJobStatus status;
  final ScanStage stage;

  /// Черновик карточки после OCR (null, пока идёт распознавание/ошибка).
  final BusinessCard? draft;
  final List<String> warnings;
  final List<String> unmatchedLines;
  final bool emptyOcr;
  final OcrDiagnostic? diagnostic;
  final String? processedImagePath;
  final List<String> variantPaths;
  final OcrResult? ocrResult;
  final bool autoWarped;
  final AppException? error;

  /// Голосовая заметка, прикреплённая до/во время/после распознавания.
  final String? voiceNotePath;
  final int voiceNoteDurationMs;

  /// Идёт офлайн-распознавание заметки (whisper.cpp).
  final bool voiceNoteTranscribing;

  /// Распознанный текст заметки (ещё не добавлен в заметку карточки,
  /// если OCR ещё не закончился).
  final String? voiceNoteTranscript;

  bool get hasDraft => status == ScanJobStatus.ready && draft != null;

  /// Карточку можно открыть на проверку только когда готов и OCR,
  /// и распознавание голосовой заметки — иначе текст заметки потеряется.
  bool get canReview => hasDraft && !voiceNoteTranscribing;

  String get displayTitle {
    final d = draft;
    if (d != null) {
      final title = d.displayTitle;
      if (title != 'Без имени') return title;
    }
    return switch (status) {
      ScanJobStatus.queued => 'Ожидает распознавания',
      ScanJobStatus.processing => 'Распознаётся…',
      ScanJobStatus.ready => 'Без имени',
      ScanJobStatus.failed => 'Ошибка распознавания',
    };
  }

  ScanState toScanState() => ScanState(
        stage: stage,
        draft: draft,
        warnings: warnings,
        unmatchedLines: unmatchedLines,
        emptyOcr: emptyOcr,
        error: error,
        diagnostic: diagnostic,
        processedImagePath: processedImagePath,
        variantPaths: variantPaths,
        ocrResult: ocrResult,
        autoWarped: autoWarped,
      );

  ScanJob copyWith({
    ScanJobStatus? status,
    ScanStage? stage,
    Object? draft = _unset,
    List<String>? warnings,
    List<String>? unmatchedLines,
    bool? emptyOcr,
    Object? diagnostic = _unset,
    Object? processedImagePath = _unset,
    List<String>? variantPaths,
    Object? ocrResult = _unset,
    bool? autoWarped,
    Object? error = _unset,
    Object? voiceNotePath = _unset,
    int? voiceNoteDurationMs,
    bool? voiceNoteTranscribing,
    Object? voiceNoteTranscript = _unset,
  }) {
    return ScanJob(
      id: id,
      sourcePath: sourcePath,
      crop: crop,
      rotationDegrees: rotationDegrees,
      createdAt: createdAt,
      status: status ?? this.status,
      stage: stage ?? this.stage,
      draft: identical(draft, _unset) ? this.draft : draft as BusinessCard?,
      warnings: warnings ?? this.warnings,
      unmatchedLines: unmatchedLines ?? this.unmatchedLines,
      emptyOcr: emptyOcr ?? this.emptyOcr,
      diagnostic: identical(diagnostic, _unset)
          ? this.diagnostic
          : diagnostic as OcrDiagnostic?,
      processedImagePath: identical(processedImagePath, _unset)
          ? this.processedImagePath
          : processedImagePath as String?,
      variantPaths: variantPaths ?? this.variantPaths,
      ocrResult: identical(ocrResult, _unset)
          ? this.ocrResult
          : ocrResult as OcrResult?,
      autoWarped: autoWarped ?? this.autoWarped,
      error: identical(error, _unset) ? this.error : error as AppException?,
      voiceNotePath: identical(voiceNotePath, _unset)
          ? this.voiceNotePath
          : voiceNotePath as String?,
      voiceNoteDurationMs: voiceNoteDurationMs ?? this.voiceNoteDurationMs,
      voiceNoteTranscribing:
          voiceNoteTranscribing ?? this.voiceNoteTranscribing,
      voiceNoteTranscript: identical(voiceNoteTranscript, _unset)
          ? this.voiceNoteTranscript
          : voiceNoteTranscript as String?,
    );
  }

  @override
  List<Object?> get props => [
        id,
        sourcePath,
        crop,
        rotationDegrees,
        createdAt,
        status,
        stage,
        draft,
        warnings,
        unmatchedLines,
        emptyOcr,
        diagnostic,
        processedImagePath,
        variantPaths,
        ocrResult,
        autoWarped,
        error,
        voiceNotePath,
        voiceNoteDurationMs,
        voiceNoteTranscribing,
        voiceNoteTranscript,
      ];
}

class ScanQueueState extends Equatable {
  const ScanQueueState({this.jobs = const [], this.processing = false});

  final List<ScanJob> jobs;
  final bool processing;

  bool get isEmpty => jobs.isEmpty;
  int get readyCount => jobs.where((j) => j.canReview).length;

  @override
  List<Object?> get props => [jobs, processing];
}

/// Фоновая очередь распознавания.
///
/// Работает без привязки к экрану: пользователь может вернуться в список,
/// снять следующее фото, открыть очередь проверки или прикрепить голосовую
/// заметку к обрабатываемой карточке. OCR выполняется последовательно,
/// по одному фото, чтобы не конкурировать за ML Kit/Tesseract.
class ScanQueueCubit extends Cubit<ScanQueueState> {
  ScanQueueCubit({
    required CardScanner Function() scannerFactory,
    CardPhotoService? photos,
    VoiceNoteService? voiceNotes,
    VoiceNoteTranscriber? transcriber,
    ScanBackgroundService? background,
    ScanQueueStore? store,
    CardRepository? repository,
    Uuid? uuid,
  })  : _scannerFactory = scannerFactory,
        _photos = photos,
        _voiceNotes = voiceNotes,
        _transcriber = transcriber,
        _background = background,
        _store = store,
        _repository = repository,
        _uuid = uuid ?? const Uuid(),
        super(const ScanQueueState());

  final CardScanner Function() _scannerFactory;
  final CardPhotoService? _photos;
  final VoiceNoteService? _voiceNotes;
  final VoiceNoteTranscriber? _transcriber;
  final ScanBackgroundService? _background;
  final ScanQueueStore? _store;
  final CardRepository? _repository;
  final Uuid _uuid;

  final List<ScanJob> _jobs = [];
  bool _processing = false;
  bool _backgroundActive = false;
  bool _restored = false;

  /// Поколение очереди. Увеличивается при полной очистке, чтобы старый
  /// зависший OCR-прогон не вернул данные в уже очищенную очередь.
  int _generation = 0;

  /// Записи на диск выполняются строго по очереди, чтобы более старый
  /// снимок состояния не перезаписал более новый.
  Future<void> _persistChain = Future<void>.value();

  /// Пока открыт диктофон, новые фото не запускаем: MediaRecorder и OCR
  /// не должны одновременно занимать платформенный поток/движки.
  bool _recordingSession = false;

  bool get isRecordingSession => _recordingSession;

  @override
  void emit(ScanQueueState state) {
    if (isClosed) return;
    super.emit(state);
  }

  @override
  Future<void> close() async {
    if (_backgroundActive) {
      _backgroundActive = false;
      await _background?.stop();
    }
    await _persistChain;
    await super.close();
  }

  void _emitState() {
    emit(ScanQueueState(
      jobs: List<ScanJob>.unmodifiable(_jobs),
      processing: _processing,
    ));
    _persist();
    _syncBackground();
  }

  void _persist() {
    final store = _store;
    if (store == null || isClosed) return;
    final snapshot = [for (final job in _jobs) _jobToMap(job)];
    _persistChain = _persistChain.then((_) async {
      try {
        await store.writeJobs(snapshot);
      } on Object catch (e) {
        debugPrint('[QUEUE] не удалось сохранить очередь: $e');
      }
    });
  }

  /// Держим foreground-service, пока есть что распознавать (или пока
  /// распознаётся голосовая заметка). Это позволяет свернуть приложение
  /// или выключить экран — очередь продолжится.
  void _syncBackground() {
    final service = _background;
    if (service == null) return;
    final active = _jobs.any((j) =>
        j.status == ScanJobStatus.queued ||
        j.status == ScanJobStatus.processing ||
        j.voiceNoteTranscribing);
    final text = _backgroundText;
    if (active) {
      if (!_backgroundActive) {
        _backgroundActive = true;
        debugPrint('[QUEUE] foreground service start: $text');
        unawaited(service.start(text));
      } else {
        unawaited(service.update(text));
      }
    } else if (_backgroundActive) {
      _backgroundActive = false;
      final completion = _completionText;
      debugPrint('[QUEUE] completion notification: $completion');
      unawaited(service.complete(completion));
    }
  }

  String get _completionText {
    final ready = _jobs.where((j) => j.canReview).length;
    final failed = _jobs.where((j) => j.status == ScanJobStatus.failed).length;
    final parts = <String>['Распознавание завершено'];
    if (ready > 0) parts.add('готово к проверке: $ready');
    if (failed > 0) parts.add('с ошибками: $failed');
    return parts.join(' · ');
  }

  String get _backgroundText {
    final remaining = _jobs
        .where((j) =>
            j.status == ScanJobStatus.queued ||
            j.status == ScanJobStatus.processing)
        .length;
    if (remaining == 0 && _jobs.any((j) => j.voiceNoteTranscribing)) {
      return 'Распознавание голосовой заметки…';
    }
    final done = _jobs.length - remaining;
    return done <= 0
        ? 'Распознавание визиток: осталось $remaining'
        : 'Распознавание визиток: $done из ${_jobs.length}';
  }

  /// Загружает очередь с диска. Вызывается один раз при старте приложения.
  ///
  /// Незавершённые задания (`processing`) возвращаются в `queued` и
  /// запускаются заново. Готовые черновики восстанавливаются сразу и
  /// снова доступны в «Очереди проверки».
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final store = _store;
    if (store == null) return;
    try {
      final saved = await store.readJobs();
      if (saved.isEmpty) return;
      for (final map in saved) {
        var job = _jobFromMap(map);
        if (job == null) continue;
        if (job.status == ScanJobStatus.processing) {
          job = job.copyWith(
            status: ScanJobStatus.queued,
            stage: ScanStage.idle,
            draft: null,
            error: null,
            voiceNoteTranscribing: false,
          );
        } else if (job.voiceNoteTranscribing) {
          // Распознавание речи не переживает убийство процесса; запись
          // останется, пользователь сможет запустить его кнопкой.
          job = job.copyWith(voiceNoteTranscribing: false);
        }
        if (job.status == ScanJobStatus.queued &&
            !await File(job.sourcePath).exists()) {
          job = job.copyWith(
            status: ScanJobStatus.failed,
            stage: ScanStage.failed,
            error: const ImageProcessingException(
              'Исходное фото очереди не найдено',
              userMessage: 'Фото не найдено — переснимите визитку',
            ),
          );
        }
        // Запись могла уже сохраниться в БД, а удаление job с диска —
        // не успеть (kill между save и remove). Такой job не дублируем.
        if (await _isAlreadySaved(job)) {
          await store.deleteSource(job.sourcePath);
          continue;
        }
        _jobs.add(job);
      }
      debugPrint('[QUEUE] restored ${_jobs.length} job(s)');
      _emitState();
      if (_jobs.any((j) => j.status == ScanJobStatus.queued)) {
        unawaited(_pump());
      }
    } on Object catch (e) {
      debugPrint('[QUEUE] не удалось восстановить очередь: $e');
    }
  }

  /// Полностью очищает очередь распознавания и проверки, включая
  /// несохранённые черновики, временные фото и голосовые заметки.
  Future<void> clearAll() async {
    _generation++;
    final jobs = List<ScanJob>.of(_jobs);
    _jobs.clear();
    _recordingSession = false;
    _backgroundActive = false;
    unawaited(_background?.stop());
    for (final job in jobs) {
      // Не удаляем фото/аудио, если карточка уже сохранена в БД: job мог
      // остаться на диске из-за kill между сохранением и remove.
      if (!await _isAlreadySaved(job)) {
        await _photos?.deleteIfOwned(job.draft?.cardImagePath);
        await _voiceNotes?.deleteIfOwned(job.voiceNotePath);
      }
      await _store?.deleteSource(job.sourcePath);
    }
    // Дожидаемся старых записей, затем стираем файл очереди целиком.
    await _persistChain;
    await _store?.clear();
    _emitState();
    debugPrint('[QUEUE] cleared ${jobs.length} job(s)');
  }

  Future<bool> _isAlreadySaved(ScanJob job) async {
    final id = job.draft?.id;
    final repository = _repository;
    if (id == null || id.isEmpty || repository == null) return false;
    try {
      return await repository.getById(id) != null;
    } on Object {
      // Не рискуем удалять файлы, если БД недоступна.
      return true;
    }
  }

  Map<String, Object?> _jobToMap(ScanJob job) => {
        'id': job.id,
        'sourcePath': job.sourcePath,
        'crop': {
          'left': job.crop.left,
          'top': job.crop.top,
          'right': job.crop.right,
          'bottom': job.crop.bottom,
        },
        'rotationDegrees': job.rotationDegrees,
        'createdAt': job.createdAt.millisecondsSinceEpoch,
        'status': job.status.name,
        'stage': job.stage.name,
        'draft': job.draft?.toMap(),
        'warnings': job.warnings,
        'unmatchedLines': job.unmatchedLines,
        'emptyOcr': job.emptyOcr,
        'processedImagePath': job.processedImagePath,
        'variantPaths': job.variantPaths,
        'autoWarped': job.autoWarped,
        'error': job.error == null
            ? null
            : {
                'message': job.error!.message,
                'userMessage': job.error!.userMessage,
              },
        'voiceNotePath': job.voiceNotePath,
        'voiceNoteDurationMs': job.voiceNoteDurationMs,
        'voiceNoteTranscript': job.voiceNoteTranscript,
      };

  ScanJob? _jobFromMap(Map<String, Object?> map) {
    try {
      final id = map['id'] as String?;
      final sourcePath = map['sourcePath'] as String?;
      if (id == null || id.isEmpty || sourcePath == null) return null;
      final cropMap = map['crop'];
      final crop = cropMap is Map
          ? CropRegion(
              left: (cropMap['left'] as num?)?.toDouble() ?? 0,
              top: (cropMap['top'] as num?)?.toDouble() ?? 0,
              right: (cropMap['right'] as num?)?.toDouble() ?? 1,
              bottom: (cropMap['bottom'] as num?)?.toDouble() ?? 1,
            )
          : const CropRegion();
      final draftMap = map['draft'];
      final draft = draftMap is Map
          ? BusinessCard.fromMap(draftMap.cast<String, Object?>())
          : null;
      final errorMap = map['error'];
      final error = errorMap is Map
          ? ImageProcessingException(
              errorMap['message']?.toString() ?? 'Ошибка распознавания',
              userMessage: errorMap['userMessage']?.toString(),
            )
          : null;
      final rawStatus = map['status']?.toString();
      final rawStage = map['stage']?.toString();
      return ScanJob(
        id: id,
        sourcePath: sourcePath,
        crop: crop,
        rotationDegrees: (map['rotationDegrees'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (map['createdAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
        status: ScanJobStatus.values.firstWhere(
          (v) => v.name == rawStatus,
          orElse: () => ScanJobStatus.queued,
        ),
        stage: ScanStage.values.firstWhere(
          (v) => v.name == rawStage,
          orElse: () => ScanStage.idle,
        ),
        draft: draft,
        warnings: _stringList(map['warnings']),
        unmatchedLines: _stringList(map['unmatchedLines']),
        emptyOcr: map['emptyOcr'] == true,
        processedImagePath: map['processedImagePath'] as String?,
        variantPaths: _stringList(map['variantPaths']),
        autoWarped: map['autoWarped'] == true,
        error: error,
        voiceNotePath: map['voiceNotePath'] as String?,
        voiceNoteDurationMs: (map['voiceNoteDurationMs'] as num?)?.toInt() ?? 0,
        voiceNoteTranscribing: false,
        voiceNoteTranscript: map['voiceNoteTranscript'] as String?,
      );
    } on Object catch (e) {
      debugPrint('[QUEUE] не удалось восстановить job: $e');
      return null;
    }
  }

  static List<String> _stringList(Object? raw) =>
      raw is List ? [for (final item in raw) item.toString()] : const [];

  /// Ставит фото в очередь. Обработка стартует сразу в фоне.
  /// Возвращает id созданной карточки (для привязки голосовой заметки,
  /// записанной на форме кадрирования).
  Future<String?> enqueue(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
    double rotationDegrees = 0,
  }) async {
    if (isClosed) return null;
    final id = _uuid.v4();
    var storedPath = sourcePath;
    final store = _store;
    if (store != null) {
      storedPath = await store.copySource(id, sourcePath);
    }
    if (isClosed) {
      await store?.deleteSource(storedPath);
      return null;
    }
    _jobs.add(ScanJob(
      id: id,
      sourcePath: storedPath,
      crop: crop,
      rotationDegrees: rotationDegrees,
      createdAt: DateTime.now(),
    ));
    debugPrint('[QUEUE] enqueued $id, jobs=${_jobs.length}');
    _emitState();
    unawaited(_pump());
    return id;
  }

  /// Приостанавливает запуск новых OCR-задач и ждёт завершения текущей.
  ///
  /// Вызывается перед открытием диктофона: так запись не конфликтует с
  /// распознаванием, из-за которого приложение зависало.
  Future<void> acquireRecording() async {
    _recordingSession = true;
    while (_processing && !isClosed) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Возобновляет очередь после закрытия диктофона.
  void releaseRecording() {
    _recordingSession = false;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_processing || isClosed || _recordingSession) return;
    _processing = true;
    final generation = _generation;
    _emitState();
    try {
      while (!isClosed && !_recordingSession && generation == _generation) {
        final index = _jobs.indexWhere((j) => j.status == ScanJobStatus.queued);
        if (index < 0) break;

        var job = _jobs[index];
        job = job.copyWith(
          status: ScanJobStatus.processing,
          stage: ScanStage.preprocessing,
          error: null,
        );
        _jobs[index] = job;
        debugPrint('[QUEUE] start ${job.id} (${index + 1}/${_jobs.length})');
        _emitState();

        final scanner = _scannerFactory();
        final sub = scanner.stream.listen((s) {
          if (isClosed || generation != _generation) return;
          final i = _jobs.indexWhere((j) => j.id == job.id);
          if (i < 0) return;
          if (_jobs[i].status != ScanJobStatus.processing) return;
          _jobs[i] = _jobs[i].copyWith(stage: s.stage);
          _emitState();
        });

        try {
          await scanner.processImage(
            job.sourcePath,
            crop: job.crop,
            rotationDegrees: job.rotationDegrees,
          );
          final result = scanner.state;
          if (generation != _generation) {
            // Очередь очистили, пока шёл OCR: не возвращаем job обратно,
            // но подчищаем созданное фото.
            await _photos?.deleteIfOwned(result.draft?.cardImagePath);
            break;
          }
          final i = _jobs.indexWhere((j) => j.id == job.id);
          if (i < 0) {
            // Карточку убрали, пока шёл OCR — не оставляем файл-сироту.
            await _photos?.deleteIfOwned(result.draft?.cardImagePath);
          } else if (result.stage == ScanStage.ready && result.draft != null) {
            final current = _jobs[i];
            final transcript = current.voiceNoteTranscript;
            final notes = transcript == null || transcript.trim().isEmpty
                ? result.draft!.notes
                : _appendNote(result.draft!.notes, transcript);
            final draft = result.draft!.copyWith(
              id: current.id,
              createdAt: current.createdAt,
              notes: notes,
              voiceNotePath: current.voiceNotePath,
              voiceNoteDurationMs: current.voiceNoteDurationMs,
            );
            _jobs[i] = current.copyWith(
              status: ScanJobStatus.ready,
              stage: result.stage,
              draft: draft,
              warnings: result.warnings,
              unmatchedLines: result.unmatchedLines,
              emptyOcr: result.emptyOcr,
              diagnostic: result.diagnostic,
              processedImagePath: result.processedImagePath,
              variantPaths: result.variantPaths,
              ocrResult: result.ocrResult,
              autoWarped: result.autoWarped,
              error: null,
            );
            debugPrint('[QUEUE] ready ${current.id}');
          } else {
            _jobs[i] = _jobs[i].copyWith(
              status: ScanJobStatus.failed,
              stage: ScanStage.failed,
              error: result.error ??
                  const ImageProcessingException(
                    'Фоновое распознавание не вернуло карточку',
                    userMessage: 'Не удалось распознать фото',
                  ),
            );
            debugPrint('[QUEUE] failed ${_jobs[i].id}: ${_jobs[i].error}');
          }
        } on Object catch (e) {
          if (generation != _generation) break;
          final i = _jobs.indexWhere((j) => j.id == job.id);
          debugPrint('[QUEUE] exception ${job.id}: $e');
          if (i >= 0) {
            _jobs[i] = _jobs[i].copyWith(
              status: ScanJobStatus.failed,
              stage: ScanStage.failed,
              error: e is AppException
                  ? e
                  : ImageProcessingException(
                      'Ошибка фоновой обработки: $e',
                      userMessage: 'Не удалось обработать фото',
                      cause: e,
                    ),
            );
          }
        } finally {
          await sub.cancel();
          try {
            await scanner.close();
          } on Object {
            // Закрытие одного сканера не должно останавливать очередь.
          }
        }
        _emitState();
      }
    } finally {
      _processing = false;
      debugPrint('[QUEUE] idle, jobs=${_jobs.length}');
      if (!isClosed) {
        _emitState();
        // После аварийной очистки/сбоя могли остаться новые queued-задачи.
        if (generation == _generation &&
            !_recordingSession &&
            _jobs.any((j) => j.status == ScanJobStatus.queued)) {
          unawaited(_pump());
        }
      }
    }
  }

  /// Прикрепляет голосовую заметку к карточке в очереди.
  ///
  /// Работает и во время распознавания: путь сохраняется в job и затем
  /// переносится в черновик, когда OCR закончится.
  Future<bool> attachVoiceNote(
    String jobId,
    VoiceRecording recording,
  ) async {
    final service = _voiceNotes;
    final index = _jobs.indexWhere((j) => j.id == jobId);
    if (service == null || index < 0 || isClosed) {
      await service?.deleteTemp(recording.path);
      if (service == null) {
        throw const VoiceNoteException(
          'Хранилище голосовых заметок недоступно',
          userMessage: 'Не удалось сохранить голосовую заметку',
        );
      }
      return false;
    }

    final oldPath = _jobs[index].voiceNotePath;
    String? persisted;
    try {
      persisted = await service.persist(recording.path);
      final currentIndex = _jobs.indexWhere((j) => j.id == jobId);
      if (currentIndex < 0 || isClosed) {
        await service.deleteIfOwned(persisted);
        return false;
      }
      final current = _jobs[currentIndex];
      final transcriber = _transcriber;
      final draft = current.draft?.copyWith(
        voiceNotePath: persisted,
        voiceNoteDurationMs: recording.durationMs,
      );
      _jobs[currentIndex] = current.copyWith(
        voiceNotePath: persisted,
        voiceNoteDurationMs: recording.durationMs,
        draft: draft,
        voiceNoteTranscribing: transcriber != null,
        voiceNoteTranscript: null,
      );
      _emitState();
      await service.deleteIfOwned(oldPath);
      if (transcriber != null) {
        unawaited(_recognizeVoiceNote(jobId, persisted, transcriber));
      }
      return true;
    } on Object {
      if (persisted != null) {
        await service.deleteIfOwned(persisted);
      } else {
        await service.deleteTemp(recording.path);
      }
      rethrow;
    }
  }

  Future<void> _recognizeVoiceNote(
    String jobId,
    String path,
    VoiceNoteTranscriber transcriber,
  ) async {
    String? text;
    String? error;
    try {
      text = await transcriber.transcribe(path);
    } on AppException catch (e) {
      error = e.userMessage ?? e.message;
    } on Object catch (e) {
      error = 'не удалось распознать ($e)';
    }
    if (isClosed) return;
    final index = _jobs.indexWhere((j) => j.id == jobId);
    if (index < 0) return;
    final current = _jobs[index];
    // Заметку успели заменить — старый результат не нужен.
    if (current.voiceNotePath != path) return;

    final draft = current.draft;
    final transcript = text?.trim();
    final updatedDraft =
        draft == null || transcript == null || transcript.isEmpty
            ? draft
            : draft.copyWith(notes: _appendNote(draft.notes, transcript));
    final warnings = error == null
        ? current.warnings
        : [...current.warnings, 'Голосовая заметка: $error'];
    _jobs[index] = current.copyWith(
      voiceNoteTranscribing: false,
      voiceNoteTranscript:
          transcript == null || transcript.isEmpty ? null : transcript,
      draft: updatedDraft,
      warnings: warnings,
    );
    _emitState();
  }

  static String _appendNote(String existing, String transcript) {
    final t = transcript.trim();
    if (t.isEmpty) return existing;
    final e = existing.trim();
    if (e.isEmpty) return t;
    return '$e\n$t';
  }

  /// Повторно запускает распознавание уже прикреплённой заметки
  /// (например, после скачивания модели).
  void retryVoiceNoteTranscription(String jobId) {
    final index = _jobs.indexWhere((j) => j.id == jobId);
    if (index < 0 || _jobs[index].voiceNoteTranscribing) return;
    final current = _jobs[index];
    final path = current.voiceNotePath;
    final transcriber = _transcriber;
    if (path == null || transcriber == null) return;
    _jobs[index] = current.copyWith(
      voiceNoteTranscribing: true,
      voiceNoteTranscript: null,
    );
    _emitState();
    unawaited(_recognizeVoiceNote(jobId, path, transcriber));
  }

  /// Повторная попытка после ошибки.
  void retry(String jobId) {
    final index = _jobs.indexWhere((j) => j.id == jobId);
    if (index < 0 || _jobs[index].status == ScanJobStatus.processing) return;
    final old = _jobs[index];
    final oldPhoto = old.draft?.cardImagePath;
    if (oldPhoto != null) {
      unawaited(_photos?.deleteIfOwned(oldPhoto));
    }
    _jobs[index] = old.copyWith(
      status: ScanJobStatus.queued,
      stage: ScanStage.idle,
      draft: null,
      warnings: const [],
      unmatchedLines: const [],
      emptyOcr: false,
      diagnostic: null,
      processedImagePath: null,
      variantPaths: const [],
      ocrResult: null,
      autoWarped: false,
      error: null,
    );
    _emitState();
    unawaited(_pump());
  }

  /// Убирает job. [keepFiles] = true — карточка сохранена в БД и файлы
  /// принадлежат ей; false — удаляем фото и голосовую заметку.
  Future<void> remove(String jobId, {bool keepFiles = true}) async {
    final index = _jobs.indexWhere((j) => j.id == jobId);
    if (index < 0 || _jobs[index].status == ScanJobStatus.processing) return;
    final job = _jobs.removeAt(index);
    _emitState();
    await _store?.deleteSource(job.sourcePath);
    if (!keepFiles) {
      await _photos?.deleteIfOwned(job.draft?.cardImagePath);
      await _voiceNotes?.deleteIfOwned(job.voiceNotePath);
    }
  }

  /// Для тестов и сценариев «дождаться фоновой обработки».
  Future<void> waitUntilIdle() async {
    while (_processing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Дожидается завершения текущей записи очереди на диск (тесты/очистка).
  Future<void> flushPersistence() => _persistChain;
}
