/// Единая иерархия ошибок приложения.
/// UI никогда не видит stack trace — только сообщения из [userMessage].
sealed class AppException implements Exception {
  const AppException(this.message, {this.userMessage, this.cause});

  /// Техническое описание (для локального лога).
  final String message;

  /// Сообщение для пользователя (на русском).
  final String? userMessage;

  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// Ошибка камеры: недоступна, занят другим приложением, нет разрешения.
/// (Название не совпадает с CameraException из пакета camera — избегаем
/// путаницы при импортах.)
final class CameraFailure extends AppException {
  const CameraFailure(super.message, {super.userMessage, super.cause});
}

/// Ошибка OCR: сбой инициализации ML Kit, пустой результат.
final class OcrException extends AppException {
  const OcrException(super.message,
      {super.userMessage, super.cause, this.stage = 'process', this.diagnostic});

  /// Этап сбоя: 'init' | 'process' | 'empty' | 'tesseract'.
  final String stage;

  /// Пошаговая диагностика движков (что вернул ML Kit / Tesseract).
  /// Тип — Object, чтобы слой ошибок не зависел от сервисов;
  /// фактически хранится OcrDiagnostic (см. ocr_service.dart).
  final Object? diagnostic;
}

/// Ошибка предобработки: файл не декодируется, фото повреждено.
final class ImageProcessingException extends AppException {
  const ImageProcessingException(super.message,
      {super.userMessage, super.cause});
}

/// Ошибка локальной БД.
final class DatabaseException extends AppException {
  const DatabaseException(super.message, {super.userMessage, super.cause});
}

/// Ошибка разрешений: пользователь отклонил или «навсегда запретил».
final class PermissionException extends AppException {
  const PermissionException(super.message,
      {super.userMessage, super.cause, this.permanentlyDenied = false});

  final bool permanentlyDenied;
}

/// Ошибка экспорта: не удалось записать файл/контакт.
final class ExportException extends AppException {
  const ExportException(super.message, {super.userMessage, super.cause});
}
