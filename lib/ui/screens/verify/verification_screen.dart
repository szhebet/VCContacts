import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../business/cards/cards_list_cubit.dart';
import '../../../business/verify/verification_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../data/models/business_card.dart';
import '../../../data/repositories/card_repository.dart';
import '../../widgets/business_card_tile.dart';
import '../edit/edit_card_screen.dart';

/// Режим выверки: список визиток с фильтром «только не проверенные».
/// Тап открывает форму редактирования, где можно отметить карточку
/// проверенной и поправить поля/фото.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  late final VerificationCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = VerificationCubit(sl())..load();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  Future<void> _open(BusinessCard card) async {
    final result = await Navigator.of(context).push<BusinessCard>(
      MaterialPageRoute(builder: (_) => EditCardScreen(draft: card)),
    );
    if (!mounted) return;
    if (result != null) {
      await _cubit.load();
    }
  }

  Future<void> _delete(BusinessCard card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить визитку?'),
        content: Text('«${card.displayTitle}» будет удалена с устройства.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await sl<CardRepository>().delete(card.id);
    await _cubit.load();
    if (mounted) await context.read<CardsListCubit>().load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Режим выверки')),
      body: BlocConsumer<VerificationCubit, VerificationState>(
        bloc: _cubit,
        listenWhen: (prev, curr) => prev.error != curr.error,
        listener: (context, state) {
          if (state.error != null) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(state.error!)));
          }
        },
        builder: (context, state) {
          return Column(
            children: [
              SwitchListTile(
                value: state.onlyUnverified,
                onChanged: (v) => _cubit.setOnlyUnverified(v),
                title: const Text('Только не проверенные'),
                subtitle: const Text(
                  'Показывать визитки, которые ещё не проверил человек',
                ),
                secondary: const Icon(Icons.fact_check_outlined),
              ),
              const Divider(height: 1),
              Expanded(child: _buildList(state)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(VerificationState state) {
    if (state.loading && state.cards.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.cards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                state.onlyUnverified
                    ? Icons.check_circle_outline
                    : Icons.style_outlined,
                size: 56,
                color: Colors.black26,
              ),
              const SizedBox(height: 12),
              Text(
                state.onlyUnverified
                    ? 'Все визитки проверены'
                    : 'Визиток пока нет',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                state.onlyUnverified
                    ? 'Снимите фильтр, чтобы увидеть проверенные карточки'
                    : 'Отсканируйте визитку или выберите фото из галереи',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black45),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _cubit.load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: state.cards.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final card = state.cards[index];
          return BusinessCardTile(
            card: card,
            onTap: () => _open(card),
            onDelete: () => _delete(card),
          );
        },
      ),
    );
  }
}
