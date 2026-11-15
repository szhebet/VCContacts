import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'person_name.dart';

/// Модель визитной карточки — единственный источник правды о данных.
/// Хранится локально в sqflite; ни одно поле не покидает устройство.
@immutable
class BusinessCard {
  const BusinessCard({
    required this.id,
    this.fullName = '',
    this.position = '',
    this.company = '',
    this.phone = '', // нормализованный формат (+7XXXXXXXXXX / E.164)
    this.phoneRaw = '', // как распознано на визитке
    this.extraPhones = const [], // дополнительные номера (как на визитке)
    this.telegram = '', // @username или ссылка t.me/...
    this.email = '',
    this.website = '',
    this.address = '',
    this.notes = '',
    this.voiceNotePath, // аудиозаметка (m4a/AAC) в данных приложения
    this.voiceNoteDurationMs = 0, // длительность голосовой заметки
    this.otherText = '',
    this.event = '',
    this.ocrText = '',
    this.photoPath, // локальный путь к исходному фото (для повторной проверки)
    this.cardImagePath, // сжатое фото визитки (webp) в данных приложения
    this.ownerImagePath, // фото владельца визитки (webp)
    this.verified = false, // проверена человеком в режиме выверки
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String fullName;
  final String position;
  final String company;

  /// Нормализованный телефон (E.164) — для набора и экспорта в контакты.
  final String phone;

  /// Исходная строка телефона с визитки — для отображения как на карточке.
  final String phoneRaw;

  /// Дополнительные телефоны (второй, третий…): хранятся как на визитке.
  final List<String> extraPhones;

  /// Telegram: `@username` (или распознанная ссылка, нормализованная).
  final String telegram;

  final String email;
  final String website;
  final String address;
  final String notes;

  /// Аудиозаметка к контакту (m4a/AAC) в каталоге данных приложения.
  final String? voiceNotePath;

  /// Длительность голосовой заметки в миллисекундах (0 — нет записи).
  final int voiceNoteDurationMs;

  /// Прочий распознанный на визитке текст, не попавший в поля выше
  /// (слоган, реквизиты, «ИНН/КПП», часы работы и т.п.).
  final String otherText;

  /// Локальный путь к исходному фото. null — если карточка создана вручную.
  final String? photoPath;

  /// Сжатое фото визитки (webp) в каталоге данных приложения.
  /// Хранится отдельно от оригинала, чтобы переживать очистку кэша.
  final String? cardImagePath;

  /// Фото владельца визитки (webp), прикрепляется из галереи.
  final String? ownerImagePath;

  /// Мероприятие, к которому относится визитка (по умолчанию пусто).
  final String event;

  /// Весь распознанный на визитке текст — источник для кнопок «*» на форме
  /// редактирования (выбор слов и подстановка в поле).
  final String ocrText;

  /// Проверена ли карточка человеком (режим выверки).
  final bool verified;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isEmpty =>
      fullName.trim().isEmpty &&
      company.trim().isEmpty &&
      phone.trim().isEmpty &&
      extraPhones.isEmpty &&
      telegram.trim().isEmpty &&
      email.trim().isEmpty;

  /// Человекочитаемое отображение: Имя или компания или телефон.
  String get displayTitle {
    if (fullName.trim().isNotEmpty) return fullName.trim();
    if (company.trim().isNotEmpty) return company.trim();
    if (phone.trim().isNotEmpty) return phone.trim();
    return 'Без имени';
  }

  /// Фамилия/имя по эвристике — только для сортировки списка.
  PersonNameParts get nameParts => splitPersonName(fullName);

  String get sortSurname => nameParts.surname;

  String get sortName => nameParts.name;

  /// Поиск по одной строке: имя, должность, компания, мероприятие,
  /// телефоны, Telegram, email, сайт, адрес. Регистр не важен — важно
  /// для кириллицы, где SQL LIKE регистр не приводит.
  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    bool has(String value) => value.toLowerCase().contains(q);
    return has(fullName) ||
        has(position) ||
        has(company) ||
        has(event) ||
        has(phone) ||
        has(phoneRaw) ||
        extraPhones.any(has) ||
        has(telegram) ||
        has(email) ||
        has(website) ||
        has(address);
  }

  String get displaySubtitle {
    final parts = <String>[
      if (position.trim().isNotEmpty) position.trim(),
      if (company.trim().isNotEmpty && fullName.trim().isNotEmpty)
        company.trim(),
      if (email.trim().isNotEmpty) email.trim(),
    ];
    return parts.join(' · ');
  }

  BusinessCard copyWith({
    String? id,
    String? fullName,
    String? position,
    String? company,
    String? phone,
    String? phoneRaw,
    List<String>? extraPhones,
    String? telegram,
    String? email,
    String? website,
    String? address,
    String? notes,
    String? voiceNotePath,
    bool clearVoiceNote = false,
    int? voiceNoteDurationMs,
    String? otherText,
    String? event,
    String? ocrText,
    String? photoPath,
    bool clearPhoto = false,
    String? cardImagePath,
    bool clearCardImage = false,
    String? ownerImagePath,
    bool clearOwnerImage = false,
    bool? verified,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return BusinessCard(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      position: position ?? this.position,
      company: company ?? this.company,
      phone: phone ?? this.phone,
      phoneRaw: phoneRaw ?? this.phoneRaw,
      extraPhones: extraPhones ?? this.extraPhones,
      telegram: telegram ?? this.telegram,
      email: email ?? this.email,
      website: website ?? this.website,
      address: address ?? this.address,
      notes: notes ?? this.notes,
      voiceNotePath:
          clearVoiceNote ? null : (voiceNotePath ?? this.voiceNotePath),
      voiceNoteDurationMs: clearVoiceNote
          ? 0
          : (voiceNoteDurationMs ?? this.voiceNoteDurationMs),
      otherText: otherText ?? this.otherText,
      event: event ?? this.event,
      ocrText: ocrText ?? this.ocrText,
      photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
      cardImagePath:
          clearCardImage ? null : (cardImagePath ?? this.cardImagePath),
      ownerImagePath:
          clearOwnerImage ? null : (ownerImagePath ?? this.ownerImagePath),
      verified: verified ?? this.verified,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Сериализация для sqflite.
  Map<String, Object?> toMap() => {
        'id': id,
        'fullName': fullName,
        'position': position,
        'company': company,
        'phone': phone,
        'phoneRaw': phoneRaw,
        'extraPhones': jsonEncode(extraPhones),
        'telegram': telegram,
        'email': email,
        'website': website,
        'address': address,
        'notes': notes,
        'voiceNotePath': voiceNotePath,
        'voiceNoteDurationMs': voiceNoteDurationMs,
        'otherText': otherText,
        'event': event,
        'ocrText': ocrText,
        'photoPath': photoPath,
        'cardImagePath': cardImagePath,
        'ownerImagePath': ownerImagePath,
        'verified': verified ? 1 : 0,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory BusinessCard.fromMap(Map<String, Object?> map) => BusinessCard(
        id: map['id'] as String,
        fullName: (map['fullName'] as String?) ?? '',
        position: (map['position'] as String?) ?? '',
        company: (map['company'] as String?) ?? '',
        phone: (map['phone'] as String?) ?? '',
        phoneRaw: (map['phoneRaw'] as String?) ?? '',
        extraPhones: _decodePhones(map['extraPhones']),
        telegram: (map['telegram'] as String?) ?? '',
        email: (map['email'] as String?) ?? '',
        website: (map['website'] as String?) ?? '',
        address: (map['address'] as String?) ?? '',
        notes: (map['notes'] as String?) ?? '',
        voiceNotePath: map['voiceNotePath'] as String?,
        voiceNoteDurationMs: (map['voiceNoteDurationMs'] as int?) ?? 0,
        otherText: (map['otherText'] as String?) ?? '',
        event: (map['event'] as String?) ?? '',
        ocrText: (map['ocrText'] as String?) ?? '',
        photoPath: map['photoPath'] as String?,
        cardImagePath: map['cardImagePath'] as String?,
        ownerImagePath: map['ownerImagePath'] as String?,
        verified: (map['verified'] as int? ?? 0) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
      );

  static List<String> _decodePhones(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return [
          for (final item in list)
            if (item.toString().trim().isNotEmpty) item.toString(),
        ];
      }
    } on Object {
      // Старое/битое значение — просто нет дополнительных номеров.
    }
    return const [];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BusinessCard && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'BusinessCard($id, $displayTitle, phone: $phone, email: $email)';
}
