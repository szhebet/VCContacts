import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/business_card.dart';
import '../../data/repositories/card_repository.dart';

/// Поля, которые можно редактировать на экране проверки.
enum CardField {
  fullName,
  position,
  company,
  phone,
  email,
  website,
  address,
  notes,
  otherText,
  event,
  telegram,
}

class EditCardState extends Equatable {
  const EditCardState({
    required this.card,
    this.unmatchedLines = const [],
    this.warnings = const [],
    this.saving = false,
    this.saved = false,
    this.error,
  });

  final BusinessCard card;
  final List<String> unmatchedLines;
  final List<String> warnings;
  final bool saving;
  final bool saved;
  final String? error;

  /// Есть ли хоть одно непустое поле/фото/мероприятие — иначе «Сохранить»
  /// неактивен. Фото и мероприятие тоже считаем содержимым: карточку можно
  /// сохранить в режиме выверки, даже если текст не распознан.
  bool get canSave =>
      !saving &&
      (!card.isEmpty ||
          card.cardImagePath != null ||
          card.ownerImagePath != null ||
          card.voiceNotePath != null ||
          card.event.trim().isNotEmpty);

  EditCardState copyWith({
    BusinessCard? card,
    bool saving = false,
    bool saved = false,
    String? error,
    bool clearError = false,
  }) {
    return EditCardState(
      card: card ?? this.card,
      unmatchedLines: unmatchedLines,
      warnings: warnings,
      saving: saving,
      saved: saved,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props =>
      [card, unmatchedLines, warnings, saving, saved, error];
}

/// Редактирование черновика перед сохранением в локальную БД.
class EditCardCubit extends Cubit<EditCardState> {
  EditCardCubit(
    this._repository, {
    required BusinessCard draft,
    List<String> unmatchedLines = const [],
    List<String> warnings = const [],
  }) : super(EditCardState(
          card: draft,
          unmatchedLines: unmatchedLines,
          warnings: warnings,
        ));

  final CardRepository _repository;

  /// Существующая запись (null — новая карточка из сканера).
  String? get existingId => draftId.isEmpty ? null : draftId;

  String get draftId => state.card.id;

  void updateField(CardField field, String value) {
    final card = state.card;
    final updated = switch (field) {
      CardField.fullName => card.copyWith(fullName: value),
      CardField.position => card.copyWith(position: value),
      CardField.company => card.copyWith(company: value),
      CardField.phone => card.copyWith(phone: value, phoneRaw: value),
      CardField.email => card.copyWith(email: value),
      CardField.website => card.copyWith(website: value),
      CardField.address => card.copyWith(address: value),
      CardField.notes => card.copyWith(notes: value),
      CardField.otherText => card.copyWith(otherText: value),
      CardField.event => card.copyWith(event: value),
      CardField.telegram => card.copyWith(telegram: value),
    };
    emit(state.copyWith(card: updated, clearError: true));
  }

  /// Дополнительные телефоны (второй, третий…).
  void setExtraPhones(List<String> phones) {
    emit(state.copyWith(
      card: state.card.copyWith(extraPhones: List.unmodifiable(phones)),
    ));
  }

  /// Теги для поиска и группировки.
  void setTags(List<String> tags) {
    emit(state.copyWith(card: state.card.copyWith(tags: tags)));
  }

  /// Отметка «проверена человеком» (режим выверки).
  void setVerified(bool value) {
    emit(state.copyWith(card: state.card.copyWith(verified: value)));
  }

  /// Отметка «моя визитка» (уникальная, для QR-кода MyVcard).
  void setMyVcard(bool value) {
    emit(state.copyWith(card: state.card.copyWith(myVcard: value)));
  }

  /// Путь к сжатому фото визитки (webp) в данных приложения.
  void setCardImagePath(String? path) {
    emit(state.copyWith(
      card: path == null
          ? state.card.copyWith(clearCardImage: true)
          : state.card.copyWith(cardImagePath: path),
    ));
  }

  /// Путь к фото владельца визитки.
  void setOwnerImagePath(String? path) {
    emit(state.copyWith(
      card: path == null
          ? state.card.copyWith(clearOwnerImage: true)
          : state.card.copyWith(ownerImagePath: path),
    ));
  }

  /// Путь к голосовой заметке (WAV в данных приложения) и её длительность.
  void setVoiceNote(String? path, {int durationMs = 0}) {
    emit(state.copyWith(
      card: path == null
          ? state.card.copyWith(clearVoiceNote: true)
          : state.card.copyWith(
              voiceNotePath: path,
              voiceNoteDurationMs: durationMs,
            ),
    ));
  }

  /// Сохранение в локальную БД. Возвращает true при успехе.
  Future<bool> save() async {
    if (!state.canSave) return false;
    emit(state.copyWith(saving: true, clearError: true));
    try {
      final saved = await _repository.saveDraft(
        state.card,
        existingId: existingId,
      );
      emit(state.copyWith(card: saved, saving: false, saved: true));
      return true;
    } on Exception catch (e) {
      emit(state.copyWith(
        saving: false,
        error: 'Не удалось сохранить: $e',
      ));
      return false;
    }
  }
}
