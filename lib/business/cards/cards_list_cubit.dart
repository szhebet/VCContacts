import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/business_card.dart';
import '../../data/repositories/card_repository.dart';

class CardsListState extends Equatable {
  const CardsListState({
    this.cards = const [],
    this.query = '',
    this.loading = false,
    this.error,
  });

  final List<BusinessCard> cards;
  final String query;
  final bool loading;
  final String? error;

  bool get isEmpty => cards.isEmpty && !loading;

  CardsListState copyWith({
    List<BusinessCard>? cards,
    String? query,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return CardsListState(
      cards: cards ?? this.cards,
      query: query ?? this.query,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [cards, query, loading, error];
}

/// Список сохранённых визиток: загрузка, поиск, удаление.
class CardsListCubit extends Cubit<CardsListState> {
  CardsListCubit(this._repository) : super(const CardsListState());

  final CardRepository _repository;

  Future<void> load({String? query}) async {
    emit(state.copyWith(loading: true, clearError: true, query: query));
    try {
      final cards = await _repository.getAll(query: query ?? state.query);
      emit(state.copyWith(cards: cards, loading: false, query: query ?? state.query));
    } on Exception catch (e) {
      emit(state.copyWith(
        loading: false,
        error: 'Не удалось загрузить визитки: $e',
      ));
    }
  }

  Future<void> search(String query) => load(query: query);

  Future<void> delete(String id) async {
    try {
      await _repository.delete(id);
      emit(state.copyWith(
        cards: state.cards.where((c) => c.id != id).toList(),
      ));
    } on Exception catch (e) {
      emit(state.copyWith(error: 'Не удалось удалить: $e'));
    }
  }
}
