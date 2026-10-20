import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/business_card.dart';
import '../../data/repositories/card_repository.dart';

/// Поля, которые можно редактировать на экране проверки.
enum CardField { fullName, position, company, phone, email, website, address, notes }

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

  /// Есть ли хоть одно непустое поле — иначе «Сохранить» неактивен.
  bool get canSave =>
      !saving && !card.isEmpty;

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
  List<Object?> get props => [card, unmatchedLines, warnings, saving, saved, error];
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
    };
    emit(state.copyWith(card: updated, clearError: true));
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
