import 'package:get_it/get_it.dart';

import '../../business/cards/cards_list_cubit.dart';
import '../../business/scan/scan_cubit.dart';
import '../../business/scan/scan_queue_cubit.dart';
import '../../data/local/card_database.dart';
import '../../data/repositories/card_repository.dart';
import '../../data/services/block_consensus.dart';
import '../../data/services/backup_service.dart';
import '../../data/services/card_detector.dart';
import '../../data/services/card_parser.dart';
import '../../data/services/card_photo_service.dart';
import '../../data/services/contact_export_service.dart';
import '../../data/services/diagnostic_service.dart';
import '../../data/services/export_service.dart';
import '../../data/services/field_segmenter.dart';
import '../../data/services/image_preprocessor.dart';
import '../../data/services/layout_analyzer.dart';
import '../../data/services/ocr_service.dart';
import '../../data/services/qr_card_service.dart';
import '../../data/services/scan_background_service.dart';
import '../../data/services/scan_queue_store.dart';
import '../../data/services/tesseract_engine.dart';
import '../../data/services/vcard_parser.dart';
import '../../data/services/voice_note_service.dart';
import '../../data/services/voice_note_transcriber.dart';
import '../../data/services/whisper_model_service.dart';

/// Простой service locator (get_it).
/// Вся диаграмма зависимостей — в одном месте: UI не создаёт сервисы сам.
final GetIt sl = GetIt.instance;

Future<void> setupDependencies() async {
  // --- Данные ---
  sl.registerLazySingleton<CardDatabase>(CardDatabase.new);
  sl.registerLazySingleton<CardRepository>(
    () => CardRepository(sl(), photos: sl(), voiceNotes: sl()),
  );
  sl.registerLazySingleton<VCardParser>(VCardParser.new);
  sl.registerLazySingleton<QrCardService>(
    () => QrCardService(repository: sl(), parser: sl()),
  );

  // --- Сервисы (всё локальное, без сетевых клиентов) ---
  // OCR — гибрид: ML Kit (латиница) основным, Tesseract rus+eng —
  // резервом и для кириллицы (ML Kit latin её не обучен).
  sl.registerLazySingleton<FieldSegmenter>(FieldSegmenter.new);
  sl.registerLazySingleton<BlockConsensus>(BlockConsensus.new);
  sl.registerLazySingleton<OcrService>(
    () => OcrService(
      engine: MlKitTextEngine(),
      fallback: TesseractTextEngine(),
      // ML Kit размечает области и корректирует наклон; Tesseract rus+eng
      // читает русские/смешанные области, английские — перераспознаёт ML Kit.
      layoutAnalyzer: MlKitLayoutAnalyzer(),
      segmenter: sl(),
      consensus: sl(),
    ),
  );
  sl.registerLazySingleton<CardDetector>(CardDetector.new);
  sl.registerLazySingleton<ImagePreprocessor>(
    () => ImagePreprocessor(
      detector: sl(),
      detectCard: true,
    ),
  );
  sl.registerLazySingleton<CardParser>(CardParser.new);
  sl.registerLazySingleton<CardPhotoService>(CardPhotoService.new);
  sl.registerLazySingleton<ExportService>(ExportService.new);
  sl.registerLazySingleton<BackupService>(BackupService.new);
  sl.registerLazySingleton<VoiceNoteService>(VoiceNoteService.new);
  sl.registerLazySingleton<WhisperModelService>(WhisperModelService.new);
  sl.registerLazySingleton<VoiceNoteTranscriber>(
    () => VoiceNoteTranscriber(models: sl()),
  );
  sl.registerLazySingleton<ScanBackgroundService>(ScanBackgroundService.new);
  sl.registerLazySingleton<ScanQueueStore>(ScanQueueStore.new);
  sl.registerLazySingleton<ContactExportService>(ContactExportService.new);
  sl.registerLazySingleton<DiagnosticService>(DiagnosticService.new);

  // --- Бизнес-логика ---
  sl.registerFactory<CardsListCubit>(() => CardsListCubit(sl()));
  sl.registerLazySingleton<ScanQueueCubit>(
    () => ScanQueueCubit(
      scannerFactory: createScanCubit,
      photos: sl(),
      voiceNotes: sl(),
      transcriber: sl(),
      background: sl(),
      store: sl(),
      repository: sl(),
    ),
  );

  // Поднимаем сохранённую очередь до первого кадра UI: незавершённые
  // задания продолжат распознавание, готовые снова появятся на проверку.
  await sl<ScanQueueCubit>().restore();
}

/// Новый прогон пайплайна для одного фото.
///
/// Используется одиночным и пакетным режимами: сервисы — singleton, поэтому
/// очередь из нескольких фото переиспользует уже прогретые OCR-движки.
ScanCubit createScanCubit() => ScanCubit(
      ocrService: sl(),
      preprocessor: sl(),
      parser: sl(),
      diagnostic: sl(),
      photos: sl(),
    );

/// Тесты могут сбросить все регистрации.
Future<void> resetDependencies() => sl.reset();
