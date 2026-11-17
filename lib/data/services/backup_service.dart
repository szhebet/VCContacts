import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/errors/app_exceptions.dart';
import '../models/business_card.dart';

/// Резервная копия всей базы: ZIP c `manifest.json` и фотографиями.
///
/// `manifest.json` — машиночитаемый слепок всех полей карточки (включая
/// кастомные: мероприятие, заметки, прочий текст, несколько телефонов,
/// Telegram, флаг выверки). Фотографии визитки и владельца лежат рядом
/// в каталоге `photos/`, голосовая заметка — в `voice/`; в манифесте для
/// каждой карточки сохранён относительный путь, чтобы копию можно было
/// восстановить и после переустановки.
///
/// Абсолютные пути устройства в манифест не попадают — только имена файлов
/// внутри архива.
class BackupService {
  static const int schemaVersion = 1;

  /// Собирает ZIP в память. [readFile] подменяется в тестах: в приложении
  /// читает файл с диска, в тестах — отдаёт заранее подготовленные байты.
  Future<Uint8List> buildArchive(
    List<BusinessCard> cards, {
    Future<List<int>?> Function(String path)? readFile,
  }) async {
    final read = readFile ?? _readFile;
    final archive = Archive();
    final manifestCards = <Map<String, Object?>>[];

    for (final card in cards) {
      final photos = <String, String>{};
      final id = _safeId(card.id);

      await _addPhoto(archive, read,
          photos: photos,
          role: 'card',
          folder: 'photos',
          id: id,
          path: card.cardImagePath);
      await _addPhoto(archive, read,
          photos: photos,
          role: 'owner',
          folder: 'photos',
          id: id,
          path: card.ownerImagePath);

      final voiceNote = await _addVoice(
        archive,
        read,
        id: id,
        path: card.voiceNotePath,
      );

      manifestCards.add(_cardJson(card, photos, voiceNote));
    }

    final manifest = <String, Object?>{
      'schema_version': schemaVersion,
      'app': 'VCContacts',
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'card_count': cards.length,
      'cards': manifestCards,
    };
    archive.addFile(ArchiveFile.string(
      'manifest.json',
      const JsonEncoder.withIndent('  ').convert(manifest),
    ));

    return ZipEncoder().encodeBytes(archive);
  }

  /// Записывает ZIP во временный каталог и открывает системный share-sheet,
  /// чтобы пользователь сохранил копию туда, где она переживёт переустановку.
  Future<File> shareBackup(List<BusinessCard> cards) async {
    if (cards.isEmpty) {
      throw const ExportException(
        'Нет карточек для резервной копии',
        userMessage: 'Список визиток пуст',
      );
    }
    try {
      final bytes = await buildArchive(cards);
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'vc_contacts_backup_${_stamp()}.zip'));
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Резервная копия VCContacts: ${cards.length} визиток',
      );
      return file;
    } on ExportException {
      rethrow;
    } on Exception catch (e) {
      throw ExportException(
        'Не удалось создать резервную копию: $e',
        userMessage: 'Не удалось создать файл резервной копии',
        cause: e,
      );
    }
  }

  Map<String, Object?> _cardJson(
    BusinessCard card,
    Map<String, String> photos,
    String? voiceNote,
  ) =>
      {
        'id': card.id,
        'full_name': card.fullName,
        'position': card.position,
        'company': card.company,
        'phone': card.phone,
        'phone_raw': card.phoneRaw,
        'extra_phones': card.extraPhones,
        'telegram': card.telegram,
        'email': card.email,
        'website': card.website,
        'address': card.address,
        'notes': card.notes,
        'tags': card.tags,
        'other_text': card.otherText,
        'event': card.event,
        'ocr_text': card.ocrText,
        'verified': card.verified,
        'my_vcard': card.myVcard,
        'created_at': card.createdAt.toUtc().toIso8601String(),
        'updated_at': card.updatedAt.toUtc().toIso8601String(),
        'photos': photos,
        'voice_note': voiceNote,
        'voice_note_duration_ms': card.voiceNoteDurationMs,
      };

  Future<void> _addPhoto(
    Archive archive,
    Future<List<int>?> Function(String path) read, {
    required Map<String, String> photos,
    required String role,
    required String folder,
    required String id,
    required String? path,
  }) async {
    if (path == null || path.trim().isEmpty) return;
    final bytes = await read(path);
    if (bytes == null || bytes.isEmpty) return;
    final ext = p.extension(path).toLowerCase();
    final name = '$folder/${id}_$role${ext.isEmpty ? '.img' : ext}';
    archive.addFile(ArchiveFile.bytes(name, bytes));
    photos[role] = name;
  }

  Future<String?> _addVoice(
    Archive archive,
    Future<List<int>?> Function(String path) read, {
    required String id,
    required String? path,
  }) async {
    if (path == null || path.trim().isEmpty) return null;
    final bytes = await read(path);
    if (bytes == null || bytes.isEmpty) return null;
    final ext = p.extension(path).toLowerCase();
    final name = 'voice/${id}_note${ext.isEmpty ? '.m4a' : ext}';
    archive.addFile(ArchiveFile.bytes(name, bytes));
    return name;
  }

  static Future<List<int>?> _readFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  static String _safeId(String id) {
    final cleaned =
        id.replaceAll(RegExp(r'[^\w.-]+', unicode: true), '_').trim();
    return cleaned.isEmpty ? 'card' : cleaned;
  }

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}';
  }
}
