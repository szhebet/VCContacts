import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/business_card.dart';
import '../../data/repositories/card_repository.dart';

/// Способы упорядочивания списка визиток.
enum CardSort {
  lastName('Фамилия'),
  firstName('Имя'),
  company('Компания'),
  event('Мероприятие'),
  createdDesc('Дата создания'),
  updatedDesc('Дата редактирования');

  const CardSort(this.label);

  final String label;
}

/// Сортировка копии списка — без мутации состояния cubit.
List<BusinessCard> sortCards(List<BusinessCard> cards, CardSort sort) {
  final result = [...cards];
  result.sort((a, b) => compareCards(a, b, sort));
  return result;
}

int compareCards(BusinessCard a, BusinessCard b, CardSort sort) {
  final primary = switch (sort) {
    CardSort.lastName => _compareText(a.sortSurname, b.sortSurname) != 0
        ? _compareText(a.sortSurname, b.sortSurname)
        : _compareText(a.sortName, b.sortName),
    CardSort.firstName => _compareText(a.sortName, b.sortName) != 0
        ? _compareText(a.sortName, b.sortName)
        : _compareText(a.sortSurname, b.sortSurname),
    CardSort.company => _compareText(a.company, b.company),
    CardSort.event => _compareText(a.event, b.event),
    CardSort.createdDesc => b.createdAt.compareTo(a.createdAt),
    CardSort.updatedDesc => b.updatedAt.compareTo(a.updatedAt),
  };
  if (primary != 0) return primary;
  // Одинаковые значения — стабильный добор по названию и id.
  final byTitle = _compareText(a.displayTitle, b.displayTitle);
  if (byTitle != 0) return byTitle;
  return a.id.compareTo(b.id);
}

/// Сравнение без учёта регистра; пустые значения всегда в конце списка.
int _compareText(String a, String b) {
  final x = a.trim().toLowerCase();
  final y = b.trim().toLowerCase();
  if (x.isEmpty && y.isEmpty) return 0;
  if (x.isEmpty) return 1;
  if (y.isEmpty) return -1;
  return x.compareTo(y);
}

class CardsListState extends Equatable {
  const CardsListState({
    this.cards = const [],
    this.query = '',
    this.sort = CardSort.updatedDesc,
    this.loading = false,
    this.error,
  });

  final List<BusinessCard> cards;
  final String query;
  final CardSort sort;
  final bool loading;
  final String? error;

  bool get isEmpty => cards.isEmpty && !loading;

  CardsListState copyWith({
    List<BusinessCard>? cards,
    String? query,
    CardSort? sort,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return CardsListState(
      cards: cards ?? this.cards,
      query: query ?? this.query,
      sort: sort ?? this.sort,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [cards, query, sort, loading, error];
}

/// Список сохранённых визиток: загрузка, поиск, сортировка, удаление.
class CardsListCubit extends Cubit<CardsListState> {
  CardsListCubit(this._repository) : super(const CardsListState());

  final CardRepository _repository;

  Future<void> load({String? query}) async {
    final sort = state.sort;
    emit(state.copyWith(loading: true, clearError: true, query: query));
    try {
      final cards = await _repository.getAll(query: query ?? state.query);
      emit(state.copyWith(
        cards: sortCards(cards, sort),
        loading: false,
        query: query ?? state.query,
      ));
    } on Exception catch (e) {
      emit(state.copyWith(
        loading: false,
        error: 'Не удалось загрузить визитки: $e',
      ));
    }
  }

  Future<void> search(String query) => load(query: query);

  /// Меняет порядок уже загруженного списка без повторного запроса к БД.
  void setSort(CardSort sort) {
    if (sort == state.sort) return;
    emit(state.copyWith(sort: sort, cards: sortCards(state.cards, sort)));
  }

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
