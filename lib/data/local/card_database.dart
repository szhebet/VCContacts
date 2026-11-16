import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/errors/app_exceptions.dart' as app;
import '../models/business_card.dart';

/// Локальная БД визиток (sqflite).
/// Все данные остаются в песочнице приложения: /data/data/<pkg>/databases.
class CardDatabase {
  CardDatabase({DatabaseFactory? factory})
      : _factory = factory ?? databaseFactory;

  final DatabaseFactory _factory;

  static const String dbName = 'vc_contacts.db';
  static const int dbVersion = 6;

  Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    try {
      final path = p.join(await getDatabasesPath(), dbName);
      final db = await _factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: dbVersion,
          onCreate: _onCreate,
          onUpgrade: (db, oldVersion, newVersion) async {
            // Миграции добавляются последовательно: v1 -> v2 -> ...
            if (oldVersion < 2) {
              await db.execute(
                'ALTER TABLE cards ADD COLUMN otherText TEXT NOT NULL '
                "DEFAULT ''",
              );
            }
            if (oldVersion < 4) {
              await db.execute(
                'ALTER TABLE cards ADD COLUMN extraPhones TEXT NOT NULL '
                "DEFAULT '[]'",
              );
              await db.execute(
                'ALTER TABLE cards ADD COLUMN telegram TEXT NOT NULL '
                "DEFAULT ''",
              );
            }
            if (oldVersion < 3) {
              await db.execute(
                'ALTER TABLE cards ADD COLUMN event TEXT NOT NULL '
                "DEFAULT ''",
              );
              await db.execute(
                'ALTER TABLE cards ADD COLUMN ocrText TEXT NOT NULL '
                "DEFAULT ''",
              );
              await db
                  .execute('ALTER TABLE cards ADD COLUMN cardImagePath TEXT');
              await db
                  .execute('ALTER TABLE cards ADD COLUMN ownerImagePath TEXT');
              await db.execute(
                'ALTER TABLE cards ADD COLUMN verified INTEGER NOT NULL '
                'DEFAULT 0',
              );
            }
            if (oldVersion < 5) {
              await db
                  .execute('ALTER TABLE cards ADD COLUMN voiceNotePath TEXT');
              await db.execute(
                'ALTER TABLE cards ADD COLUMN voiceNoteDurationMs INTEGER '
                'NOT NULL DEFAULT 0',
              );
            }
            if (oldVersion < 6) {
              await db.execute(
                'ALTER TABLE cards ADD COLUMN tags TEXT NOT NULL '
                "DEFAULT '[]'",
              );
            }
          },
        ),
      );
      _db = db;
      return db;
    } on Exception catch (e) {
      // StateError — Error, кубиты ловят только Exception: бросаем
      // наше AppException-исключение, иначе сбой БД уронит приложение.
      throw app.DatabaseException(
        'Не удалось открыть локальную БД: $e',
        userMessage: 'Ошибка локального хранилища',
        cause: e,
      );
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE cards (
        id        TEXT PRIMARY KEY,
        fullName  TEXT NOT NULL DEFAULT '',
        position  TEXT NOT NULL DEFAULT '',
        company   TEXT NOT NULL DEFAULT '',
        phone     TEXT NOT NULL DEFAULT '',
        phoneRaw  TEXT NOT NULL DEFAULT '',
        extraPhones TEXT NOT NULL DEFAULT '[]',
        telegram  TEXT NOT NULL DEFAULT '',
        email     TEXT NOT NULL DEFAULT '',
        website   TEXT NOT NULL DEFAULT '',
        address   TEXT NOT NULL DEFAULT '',
        notes     TEXT NOT NULL DEFAULT '',
        voiceNotePath TEXT,
        voiceNoteDurationMs INTEGER NOT NULL DEFAULT 0,
        tags TEXT NOT NULL DEFAULT '[]',
        otherText TEXT NOT NULL DEFAULT '',
        event     TEXT NOT NULL DEFAULT '',
        ocrText   TEXT NOT NULL DEFAULT '',
        photoPath TEXT,
        cardImagePath TEXT,
        ownerImagePath TEXT,
        verified  INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    // Индексы под штатные сценарии: быстрый поиск и сортировка
    await db.execute('CREATE INDEX idx_cards_name ON cards(fullName)');
    await db.execute('CREATE INDEX idx_cards_updated ON cards(updatedAt)');
  }

  Future<int> insertCard(BusinessCard card) async {
    final db = await database;
    return db.insert(
      'cards',
      card.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> updateCard(BusinessCard card) async {
    final db = await database;
    return db.update(
      'cards',
      card.toMap(),
      where: 'id = ?',
      whereArgs: [card.id],
    );
  }

  Future<int> deleteCard(String id) async {
    final db = await database;
    return db.delete('cards', where: 'id = ?', whereArgs: [id]);
  }

  Future<BusinessCard?> getCardById(String id) async {
    final db = await database;
    final rows = await db.query('cards', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return BusinessCard.fromMap(rows.first);
  }

  /// Список с необязательным поиском по имени, компании, должности,
  /// мероприятию, телефонам, Telegram, email, сайту и адресу.
  Future<List<BusinessCard>> getCards({String? query, bool? verified}) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (verified != null) {
      where.add('verified = ?');
      args.add(verified ? 1 : 0);
    }
    final rows = await db.query(
      'cards',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'updatedAt DESC',
    );
    final cards = rows.map(BusinessCard.fromMap).toList();
    final q = query?.trim() ?? '';
    if (q.isEmpty) return cards;
    // Фильтруем в Dart: SQLite LIKE без ICU не приводит регистр кириллицы,
    // а поиск должен одинаково находить «Конференция» и «конференция».
    return cards.where((c) => c.matchesQuery(q)).toList();
  }

  Future<int> count() async {
    final db = await database;
    final res = await db.rawQuery('SELECT COUNT(*) AS c FROM cards');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
