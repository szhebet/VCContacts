import 'package:flutter/foundation.dart';

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
    this.email = '',
    this.website = '',
    this.address = '',
    this.notes = '',
    this.photoPath, // локальный путь к исходному фото (для повторной проверки)
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

  final String email;
  final String website;
  final String address;
  final String notes;

  /// Локальный путь к фото. null — если карточка создана вручную.
  final String? photoPath;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isEmpty =>
      fullName.trim().isEmpty &&
      company.trim().isEmpty &&
      phone.trim().isEmpty &&
      email.trim().isEmpty;

  /// Человекочитаемое отображение: Имя или компания или телефон.
  String get displayTitle {
    if (fullName.trim().isNotEmpty) return fullName.trim();
    if (company.trim().isNotEmpty) return company.trim();
    if (phone.trim().isNotEmpty) return phone.trim();
    return 'Без имени';
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
    String? email,
    String? website,
    String? address,
    String? notes,
    String? photoPath,
    bool clearPhoto = false,
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
      email: email ?? this.email,
      website: website ?? this.website,
      address: address ?? this.address,
      notes: notes ?? this.notes,
      photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
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
        'email': email,
        'website': website,
        'address': address,
        'notes': notes,
        'photoPath': photoPath,
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
        email: (map['email'] as String?) ?? '',
        website: (map['website'] as String?) ?? '',
        address: (map['address'] as String?) ?? '',
        notes: (map['notes'] as String?) ?? '',
        photoPath: map['photoPath'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BusinessCard && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'BusinessCard($id, $displayTitle, phone: $phone, email: $email)';
}
