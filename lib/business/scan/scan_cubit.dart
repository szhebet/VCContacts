import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors/app_exceptions.dart';
import '../../data/models/business_card.dart';
import '../../data/services/card_parser.dart';
import '../../data/services/image_preprocessor.dart';
import '../../data/services/ocr_service.dart';
/// Статусы пайплайна «фото → черновик карточки».
enum ScanStage {
  idle,
  preprocessing,
  recognizing,
  parsing,
  ready, // черновик собран, ждём проверки на экране редактирования
  failed,
}

class ScanState extends Equatable {
  const ScanState({
    this.stage = ScanStage.idle,
    this.draft,
    this.warnings = const [],
    this.unmatchedLines = const [],
    this.error,
    this.emptyOcr = false,
    this.diagnostic,
  });

  final ScanStage stage;
  final BusinessCard? draft;
  final List<String> warnings;
  final List<String> unmatchedLines;

  /// Ошибка текущего этапа (null, если stage != failed).
  final AppException? error;

  /// true — OCR не нашёл текст: показываем ручной ввод без ошибки.
  final bool emptyOcr;

  /// Пошаговая диагностика OCR (движки, выбор, распознанный текст) —
  /// показывается на экране проверки и при сбое.
  final OcrDiagnostic? diagnostic;

  bool get canRetry =>
      stage == ScanStage.failed &&
      error is! PermissionException;

  ScanState copyWith({
    ScanStage? stage,
    BusinessCard? draft,
    List<String>? warnings,
    List<String>? unmatchedLines,
    AppException? error,
    bool clearError = false,
    bool? emptyOcr,
    OcrDiagnostic? diagnostic,
  }) {
    return ScanState(
      stage: stage ?? this.stage,
      draft: draft ?? this.draft,
      warnings: warnings ?? this.warnings,
      unmatchedLines: unmatchedLines ?? this.unmatchedLines,
      error: clearError ? null : error,
      emptyOcr: emptyOcr ?? this.emptyOcr,
      diagnostic: diagnostic ?? this.diagnostic,
    );
  }

  @override
  List<Object?> get props =>
      [stage, draft, warnings, unmatchedLines, error, emptyOcr, diagnostic];
}

/// Оркестратор пайплайна:
/// фото → предобработка → OCR → парсинг → черновик для проверки.
class ScanCubit extends Cubit<ScanState> {
  ScanCubit({
    required OcrService ocrService,
    required ImagePreprocessor preprocessor,
    required CardParser parser,
  })  : _ocrService = ocrService,
        _preprocessor = preprocessor,
        _parser = parser,
        super(const ScanState());

  final OcrService _ocrService;
  final ImagePreprocessor _preprocessor;
  final CardParser _parser;

  String? _lastSourcePath;
  CropRegion _lastCrop = const CropRegion();

  /// Полный прогон пайплайна для одного снимка/файла из галереи.
  Future<void> processImage(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
  }) async {
    _lastSourcePath = sourcePath;
    _lastCrop = crop;

    emit(const ScanState(stage: ScanStage.preprocessing));
    try {
      // 1. Предобработка: EXIF, обрезка, контраст, уменьшение.
      final prepared = await _preprocessor.prepare(sourcePath, crop: crop);

      // 2. OCR на устройстве (ML Kit + многопроходный Tesseract).
      emit(const ScanState(stage: ScanStage.recognizing));
      OcrResult ocr;
      try {
        ocr = await _ocrService.recognizeFromFile(
          prepared.file.path,
          variants: prepared.variants.map((f) => f.path).toList(),
        );
      } on OcrException catch (e) {
        if (e.stage == 'empty') {
          // Пустой результат — не авария: UI открывает ручной ввод.
          emit(ScanState(
            stage: ScanStage.ready,
            draft: _emptyDraft(),
            warnings: [...prepared.warnings, e.userMessage ?? ''],
            unmatchedLines: const [],
            emptyOcr: true,
            diagnostic: e.diagnostic as OcrDiagnostic?,
          ));
          return;
        }
        rethrow;
      }

      // 3. Парсинг полей.
      emit(const ScanState(stage: ScanStage.parsing));
      final parsed = _parser.parse(
        ocr.fullText,
        ocrLines: ocr.lines,
        containsCyrillic: ocr.containsCyrillic,
      );

      emit(ScanState(
        stage: ScanStage.ready,
        draft: parsed.card,
        warnings: [...prepared.warnings, ...parsed.warnings],
        unmatchedLines: parsed.unmatchedLines,
        emptyOcr: false,
        diagnostic: ocr.diagnostic,
      ));
    } on AppException catch (e) {
      emit(ScanState(
        stage: ScanStage.failed,
        error: e,
        diagnostic:
            e is OcrException ? e.diagnostic as OcrDiagnostic? : null,
      ));
    } on Exception catch (e) {
      emit(ScanState(
        stage: ScanStage.failed,
        error: ImageProcessingException(
          'Непредвиденная ошибка обработки: $e',
          userMessage: 'Сбой обработки фото',
          cause: e,
        ),
      ));
    }
  }

  /// Повтор после ошибки (тот же снимок).
  Future<void> retry() async {
    final path = _lastSourcePath;
    if (path == null) return;
    await processImage(path, crop: _lastCrop);
  }

  void reset() => emit(const ScanState());

  BusinessCard _emptyDraft() => BusinessCard(
        id: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  @override
  Future<void> close() async {
    await _ocrService.dispose();
    await super.close();
  }
}
