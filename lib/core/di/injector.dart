import 'package:get_it/get_it.dart';

import '../../business/cards/cards_list_cubit.dart';
import '../../data/local/card_database.dart';
import '../../data/repositories/card_repository.dart';
import '../../data/services/card_parser.dart';
import '../../data/services/contact_export_service.dart';
import '../../data/services/export_service.dart';
import '../../data/services/image_preprocessor.dart';
import '../../data/services/ocr_service.dart';
import '../../data/services/tesseract_engine.dart';

/// Простой service locator (get_it).
/// Вся диаграмма зависимостей — в одном месте: UI не создаёт сервисы сам.
final GetIt sl = GetIt.instance;

Future<void> setupDependencies() async {
  // --- Данные ---
  sl.registerLazySingleton<CardDatabase>(CardDatabase.new);
  sl.registerLazySingleton<CardRepository>(() => CardRepository(sl()));

  // --- Сервисы (всё локальное, без сетевых клиентов) ---
  // OCR — гибрид: ML Kit (латиница) основным, Tesseract rus+eng —
  // резервом и для кириллицы (ML Kit latin её не обучен).
  sl.registerLazySingleton<OcrService>(
    () => OcrService(
      engine: MlKitTextEngine(),
      fallback: TesseractTextEngine(),
    ),
  );
  sl.registerLazySingleton<ImagePreprocessor>(ImagePreprocessor.new);
  sl.registerLazySingleton<CardParser>(CardParser.new);
  sl.registerLazySingleton<ExportService>(ExportService.new);
  sl.registerLazySingleton<ContactExportService>(ContactExportService.new);

  // --- Бизнес-логика ---
  sl.registerFactory<CardsListCubit>(() => CardsListCubit(sl()));
}

/// Тесты могут сбросить все регистрации.
Future<void> resetDependencies() => sl.reset();
