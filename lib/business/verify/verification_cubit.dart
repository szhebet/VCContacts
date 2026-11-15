import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/business_card.dart';
import '../../data/repositories/card_repository.dart';

/// Состояние экрана выверки: список карточек и фильтр «только не проверенные».
class VerificationState extends Equatable {
  const VerificationState({
    this.cards = const [],
    this.loading = true,
    this.onlyUnverified = true,
    this.error,
  });

  final List<BusinessCard> cards;
  final bool loading;
  final bool onlyUnverified;
  final String? error;

  int get unverifiedCount => cards.where((c) => !c.verified).length;

  @override
  List<Object?> get props => [cards, loading, onlyUnverified, error];
}

/// Загрузка карточек для режима выверки.
///
/// В отличие от [CardsListCubit] умеет фильтровать по флагу `verified` на
/// уровне БД, а не только по тексту.
class VerificationCubit extends Cubit<VerificationState> {
  VerificationCubit(this._repository) : super(const VerificationState());

  final CardRepository _repository;

  Future<void> load() async {
    emit(VerificationState(
      cards: state.cards,
      loading: true,
      onlyUnverified: state.onlyUnverified,
    ));
    try {
      final cards = await _repository.getAll(
        verified: state.onlyUnverified ? false : null,
      );
      if (isClosed) return;
      emit(VerificationState(
        cards: cards,
        loading: false,
        onlyUnverified: state.onlyUnverified,
      ));
    } on Exception catch (e) {
      if (isClosed) return;
      emit(VerificationState(
        cards: state.cards,
        loading: false,
        onlyUnverified: state.onlyUnverified,
        error: 'Не удалось загрузить визитки: $e',
      ));
    }
  }

  Future<void> setOnlyUnverified(bool value) async {
    if (state.onlyUnverified == value) return;
    emit(VerificationState(
      cards: const [],
      loading: true,
      onlyUnverified: value,
    ));
    await load();
  }
}
