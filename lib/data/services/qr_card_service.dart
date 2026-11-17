import 'package:flutter/foundation.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

import '../models/business_card.dart';
import '../repositories/card_repository.dart';
import 'vcard_parser.dart';

/// Поиск QR-кода с vCard на фотографии и импорт карточки.
///
/// Если QR найден и содержит vCard, карточка сразу сохраняется в БД —
/// без предобработки, обрезки и OCR фотографии.
class QrCardService {
  QrCardService({
    CardRepository? repository,
    VCardParser? parser,
  })  : _repository = repository,
        _parser = parser ?? const VCardParser();

  final CardRepository? _repository;
  final VCardParser _parser;

  /// Ищет QR-код на фото и возвращает черновик карточки без сохранения.
  Future<BusinessCard?> detect(String path) async {
    final scanner = BarcodeScanner(formats: const [BarcodeFormat.qrCode]);
    try {
      final barcodes = await scanner.processImage(
        InputImage.fromFilePath(path),
      );
      for (final barcode in barcodes) {
        final raw = barcode.rawValue;
        if (raw == null || raw.trim().isEmpty) continue;
        final card = _parser.parse(raw);
        if (card != null) return card;
      }
    } on Object catch (e) {
      debugPrint('[QR] не удалось просканировать фото: $e');
    } finally {
      try {
        await scanner.close();
      } on Object {
        // Сканер мог уже закрыться — не критично.
      }
    }
    return null;
  }

  /// Находит vCard в QR и сразу сохраняет карточку в БД.
  /// Возвращает null, если QR/vCard не найден.
  Future<BusinessCard?> importFile(String path) async {
    final draft = await detect(path);
    if (draft == null) return null;
    final repository = _repository;
    if (repository == null) return null;
    return repository.saveDraft(draft);
  }
}
