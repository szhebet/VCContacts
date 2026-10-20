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
  static const int dbVersion = 1;

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
        email     TEXT NOT NULL DEFAULT '',
        website   TEXT NOT NULL DEFAULT '',
        address   TEXT NOT NULL DEFAULT '',
        notes     TEXT NOT NULL DEFAULT '',
        photoPath TEXT,
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

  /// Список с необязательным поиском по имени/компании/телефону/email.
  Future<List<BusinessCard>> getCards({String? query}) async {
    final db = await database;
    final q = query?.trim();
    final rows = await db.query(
      'cards',
      where: q == null || q.isEmpty
          ? null
          : 'fullName LIKE ? OR company LIKE ? OR phone LIKE ? OR email LIKE ?',
      whereArgs: q == null || q.isEmpty
          ? null
          : List.filled(4, '%$q%'),
      orderBy: 'updatedAt DESC',
    );
    return rows.map(BusinessCard.fromMap).toList();
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
