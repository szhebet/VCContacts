import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors/app_exceptions.dart';
import '../../data/models/business_card.dart';
import '../../data/services/card_parser.dart';
import '../../data/services/card_photo_service.dart';
import '../../data/services/diagnostic_service.dart';
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
    this.processedImagePath,
    this.variantPaths = const [],
    this.ocrResult,
    this.autoWarped = false,
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

  /// Путь к основному обработанному изображению (то, что ушло в OCR) —
  /// используется расширенной диагностикой для вырезания областей полей.
  final String? processedImagePath;

  /// Все варианты предобработки, отправленные в OCR (для диагностики).
  final List<String> variantPaths;

  /// Полный результат OCR (со словами/bbox и hOCR) — для расширенной
  /// диагностики.
  final OcrResult? ocrResult;

  /// Была ли применена авто-детекция границ визитки (OpenCV).
  final bool autoWarped;

  bool get canRetry =>
      stage == ScanStage.failed && error is! PermissionException;

  ScanState copyWith({
    ScanStage? stage,
    BusinessCard? draft,
    List<String>? warnings,
    List<String>? unmatchedLines,
    AppException? error,
    bool clearError = false,
    bool? emptyOcr,
    OcrDiagnostic? diagnostic,
    String? processedImagePath,
    List<String>? variantPaths,
    OcrResult? ocrResult,
    bool? autoWarped,
  }) {
    return ScanState(
      stage: stage ?? this.stage,
      draft: draft ?? this.draft,
      warnings: warnings ?? this.warnings,
      unmatchedLines: unmatchedLines ?? this.unmatchedLines,
      error: clearError ? null : error,
      emptyOcr: emptyOcr ?? this.emptyOcr,
      diagnostic: diagnostic ?? this.diagnostic,
      processedImagePath: processedImagePath ?? this.processedImagePath,
      variantPaths: variantPaths ?? this.variantPaths,
      ocrResult: ocrResult ?? this.ocrResult,
      autoWarped: autoWarped ?? this.autoWarped,
    );
  }

  @override
  List<Object?> get props => [
        stage,
        draft,
        warnings,
        unmatchedLines,
        error,
        emptyOcr,
        diagnostic,
        processedImagePath,
        variantPaths,
        ocrResult,
        autoWarped,
      ];
}

/// Минимальный интерфейс пайплайна одного фото.
///
/// Нужен пакетному режиму (очередь фото) и тестам: [ScanCubit] реализует
/// его, а подменить реализацию можно без нативных движков.
abstract class CardScanner {
  Stream<ScanState> get stream;
  ScanState get state;
  Future<void> processImage(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
    double rotationDegrees = 0,
  });
  Future<void> close();
}

/// Оркестратор пайплайна:
/// фото → предобработка → OCR → парсинг → черновик для проверки.
class ScanCubit extends Cubit<ScanState> implements CardScanner {
  ScanCubit({
    required OcrService ocrService,
    required ImagePreprocessor preprocessor,
    required CardParser parser,
    DiagnosticService? diagnostic,
    CardPhotoService? photos,
  })  : _ocrService = ocrService,
        _preprocessor = preprocessor,
        _parser = parser,
        _diagnostic = diagnostic ?? const DiagnosticService(),
        _photos = photos,
        super(const ScanState());

  final OcrService _ocrService;
  final ImagePreprocessor _preprocessor;
  final CardParser _parser;
  final DiagnosticService _diagnostic;
  final CardPhotoService? _photos;

  /// После `close()` экран уже уничтожен: любые поздние `emit` от
  /// зависшего OCR не должны ронять изолят (StateError) и оставлять
  /// приложение в чёрном экране.
  @override
  void emit(ScanState state) {
    if (isClosed) return;
    super.emit(state);
  }

  String? _lastSourcePath;
  CropRegion _lastCrop = const CropRegion();
  double _lastRotation = 0;

  /// Полный прогон пайплайна для одного снимка/файла из галереи.
  @override
  Future<void> processImage(
    String sourcePath, {
    CropRegion crop = const CropRegion(),
    double rotationDegrees = 0,
  }) async {
    _lastSourcePath = sourcePath;
    _lastCrop = crop;
    _lastRotation = rotationDegrees;

    emit(const ScanState(stage: ScanStage.preprocessing));
    try {
      // 1. Предобработка в фоновом isolate: декодирование, OpenCV-детекция,
      //    фильтры и сохранение вариантов. UI-поток при этом не блокируется.
      final prepared = await _preprocessor.prepareInBackground(
        sourcePath,
        crop: crop,
        rotationDegrees: rotationDegrees,
      );
      if (isClosed) return;

      // Фото визитки для карточки: кадр после обрезки по контуру/поворота,
      // но до маскировки графики и нарезки строк. Сжимаем в WebP сразу,
      // чтобы карточка не зависела от кэша image_picker.
      String? cardImagePath;
      final cardPhotoSource = prepared.cardPhotoSource;
      final photos = _photos;
      if (cardPhotoSource != null && photos != null) {
        try {
          cardImagePath = await photos.saveCardPhoto(cardPhotoSource.path);
        } on Object catch (e) {
          debugPrint('[SCAN] не удалось сохранить фото визитки: $e');
        }
      }
      if (isClosed) return;

      // 2. OCR на устройстве (ML Kit + многопроходный Tesseract).
      emit(const ScanState(stage: ScanStage.recognizing));
      OcrResult ocr;
      try {
        ocr = await _ocrService
            .recognizeFromFile(
              prepared.file.path,
              variants: prepared.variants.map((f) => f.path).toList(),
              segmentSource: prepared.colorSource?.path,
            )
            .timeout(
              const Duration(minutes: 2),
              onTimeout: () => throw const OcrException(
                'OCR не завершился за 2 минуты',
                userMessage: 'Распознавание заняло слишком много времени. '
                    'Попробуйте ещё раз',
                stage: 'process',
              ),
            );
      } on OcrException catch (e) {
        if (e.stage == 'empty') {
          // Пустой результат — не авария: UI открывает ручной ввод.
          emit(ScanState(
            stage: ScanStage.ready,
            draft: _emptyDraft().copyWith(
              photoPath: sourcePath,
              cardImagePath: cardImagePath,
            ),
            warnings: [...prepared.warnings, e.userMessage ?? ''],
            unmatchedLines: const [],
            emptyOcr: true,
            diagnostic: e.diagnostic as OcrDiagnostic?,
            processedImagePath: prepared.file.path,
            variantPaths: prepared.variants.map((f) => f.path).toList(),
            autoWarped: prepared.autoWarped,
          ));
          return;
        }
        rethrow;
      }
      if (isClosed) return;

      // 2b. Позиционирование фото визитки: если контур не найден или
      // остался наклон строк, выравниваем/обрезаем снимок по геометрии
      // OCR. Работает для каждой карточки очереди, а не только для первой.
      String? positionedCardPhoto = cardImagePath;
      final photosService = _photos;
      if (cardImagePath != null && photosService != null) {
        final tilt = ocr.deskewApplied
            ? ocr.tiltDegrees
            : (ocr.diagnostic?.geometry?.medianAngleDegrees ?? 0);
        final regions = ocr.diagnostic?.regions ?? const <OcrRegionStat>[];
        final boxes = [
          for (final r in regions)
            PhotoBox(r.left, r.top, r.right, r.bottom),
        ];
        final needsRotation = ocr.orientationDegrees % 360 != 0;
        final needsDeskew = tilt.abs() >= 1.0 && tilt.abs() < 45;
        final needsCrop = !prepared.autoWarped && boxes.isNotEmpty;
        if (needsRotation || needsDeskew || needsCrop) {
          try {
            final path = await photosService.repositionCardPhoto(
              cardImagePath,
              orientationDegrees: ocr.orientationDegrees,
              tiltDegrees: tilt,
              textBoxes: boxes,
              cropToText: needsCrop,
              // OCR уже выпрямил кадр целиком, поэтому его bbox заданы в
              // выпрямленных координатах и повторно поворачивать их нельзя.
              boxesAlreadyDeskewed: ocr.deskewApplied,
            );
            await photosService.deleteIfOwned(cardImagePath);
            positionedCardPhoto = path;
          } on Object catch (e) {
            debugPrint('[SCAN] не удалось выровнять фото визитки: $e');
          }
        }
      }
      if (isClosed) return;

      // 3. Парсинг полей.
      emit(const ScanState(stage: ScanStage.parsing));
      final parsed = _parser.parse(
        ocr.fullText,
        ocrLines: ocr.lines,
        containsCyrillic: ocr.containsCyrillic,
      );

      final warnings = [...prepared.warnings, ...parsed.warnings];
      if (ocr.confidence < 0.6) {
        warnings.add(
          'Низкое качество текста: проверьте поля внимательнее '
          '(возможен смаз или мелкий шрифт)',
        );
        if (!prepared.autoWarped) {
          warnings.add(
            'Визитка не выделена автоматически — обрежьте фото вручную '
            'или переснимите её крупнее',
          );
        }
      }
      emit(ScanState(
        stage: ScanStage.ready,
        draft: parsed.card.copyWith(
          photoPath: sourcePath,
          ocrText: ocr.fullText,
          cardImagePath: positionedCardPhoto,
        ),
        warnings: warnings,
        unmatchedLines: parsed.unmatchedLines,
        emptyOcr: false,
        diagnostic: ocr.diagnostic,
        processedImagePath: prepared.file.path,
        variantPaths: prepared.variants.map((f) => f.path).toList(),
        ocrResult: ocr,
        autoWarped: prepared.autoWarped,
      ));
    } on AppException catch (e) {
      emit(ScanState(
        stage: ScanStage.failed,
        error: e,
        diagnostic: e is OcrException ? e.diagnostic as OcrDiagnostic? : null,
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
    await processImage(path, crop: _lastCrop, rotationDegrees: _lastRotation);
  }

  /// Выгрузить расширенную диагностику последнего скана в публичную папку
  /// Download (app-specific каталог — только как фолбэк). Возвращает путь
  /// к каталогу с файлами.
  Future<String> dumpDiagnostic() async {
    final s = state;
    final dir = await _diagnostic.dump(
      ocrResult: s.ocrResult,
      processedImagePath: s.processedImagePath,
      variantPaths: s.variantPaths,
      card: s.draft,
      diagnostic: s.diagnostic,
      autoWarped: s.autoWarped,
    );
    return dir.path;
  }

  void reset() => emit(const ScanState());

  BusinessCard _emptyDraft() => BusinessCard(
        id: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  @override
  Future<void> close() async {
    // OcrService/препроцессор живут в DI как singleton: закрывать их вместе
    // с экраном нельзя, иначе следующий скан (и пакетная очередь) останутся
    // без движков. Жизненным циклом сервисов управляет DI.
    await super.close();
  }
}
