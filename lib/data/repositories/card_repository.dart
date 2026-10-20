import 'package:uuid/uuid.dart';

import '../local/card_database.dart';
import '../models/business_card.dart';

/// Репозиторий визиток: единственная точка доступа к хранилищу.
/// Скрывает от бизнес-слоя детали SQL и формат БД.
class CardRepository {
  CardRepository(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final CardDatabase _db;
  final Uuid _uuid;

  /// Создать карточку из черновика (id/даты проставляются здесь).
  Future<BusinessCard> saveDraft(BusinessCard draft, {String? existingId}) async {
    final now = DateTime.now();
    final id = existingId ?? _uuid.v4();
    final existing = existingId == null ? null : await _db.getCardById(existingId);

    final card = existing == null
        ? draft.copyWith(id: id, createdAt: now, updatedAt: now)
        : draft.copyWith(id: id, updatedAt: now);

    await _db.insertCard(card);
    return card;
  }

  Future<BusinessCard?> getById(String id) => _db.getCardById(id);

  Future<List<BusinessCard>> getAll({String? query}) => _db.getCards(query: query);

  Future<void> delete(String id) => _db.deleteCard(id);

  Future<int> count() => _db.count();
}
