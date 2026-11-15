import 'package:uuid/uuid.dart';

import '../local/card_database.dart';
import '../models/business_card.dart';
import '../services/card_photo_service.dart';
import '../services/voice_note_service.dart';

/// Репозиторий визиток: единственная точка доступа к хранилищу.
/// Скрывает от бизнес-слоя детали SQL и формат БД.
class CardRepository {
  CardRepository(
    this._db, {
    Uuid? uuid,
    CardPhotoService? photos,
    VoiceNoteService? voiceNotes,
  })  : _uuid = uuid ?? const Uuid(),
        _photos = photos,
        _voiceNotes = voiceNotes;

  final CardDatabase _db;
  final Uuid _uuid;
  final CardPhotoService? _photos;
  final VoiceNoteService? _voiceNotes;

  /// Создать карточку из черновика (id/даты проставляются здесь).
  Future<BusinessCard> saveDraft(BusinessCard draft,
      {String? existingId}) async {
    final now = DateTime.now();
    final id = existingId ?? _uuid.v4();
    final existing =
        existingId == null ? null : await _db.getCardById(existingId);

    // createdAt не перезаписываем: для черновика это момент сканирования/
    // создания карточки, его показываем в форме только для чтения.
    final card = existing == null
        ? draft.copyWith(id: id, updatedAt: now)
        : draft.copyWith(id: id, updatedAt: now);

    await _db.insertCard(card);
    return card;
  }

  Future<BusinessCard?> getById(String id) => _db.getCardById(id);

  Future<List<BusinessCard>> getAll({String? query, bool? verified}) =>
      _db.getCards(query: query, verified: verified);

  /// Удаляет карточку вместе с её фотографиями в данных приложения.
  Future<void> delete(String id) async {
    final card = await _db.getCardById(id);
    await _db.deleteCard(id);
    final photos = _photos;
    if (photos != null && card != null) {
      await photos.deleteIfOwned(card.cardImagePath);
      await photos.deleteIfOwned(card.ownerImagePath);
    }
    await _voiceNotes?.deleteIfOwned(card?.voiceNotePath);
  }

  Future<int> count() => _db.count();
}
