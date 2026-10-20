import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../../business/cards/cards_list_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../core/errors/app_exceptions.dart';
import '../../../data/models/business_card.dart';
import '../../../data/services/export_service.dart';
import '../../widgets/business_card_tile.dart';
import '../camera/camera_screen.dart';
import '../camera/crop_screen.dart';
import '../detail/card_detail_screen.dart';

/// Главный экран: список локальных визиток + поиск + экспорт CSV.
class CardsListScreen extends StatefulWidget {
  const CardsListScreen({super.key});

  @override
  State<CardsListScreen> createState() => _CardsListScreenState();
}

class _CardsListScreenState extends State<CardsListScreen> {
  final _searchController = TextEditingController();
  bool _searchMode = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Выбор из галереи: дальше тот же локальный пайплайн
  /// (обрезка -> предобработка -> OCR -> проверка -> сохранение).
  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 4000,
    );
    if (picked == null || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CropScreen(sourcePath: picked.path),
      ),
    );
  }

  Future<void> _exportCsv() async {
    final cards = context.read<CardsListCubit>().state.cards;
    try {
      await sl<ExportService>().shareCsv(cards);
    } on AppException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.userMessage ?? e.message)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searchMode
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Поиск по имени, компании, телефону…',
                  border: InputBorder.none,
                  filled: false,
                ),
                onChanged: (q) => context.read<CardsListCubit>().search(q),
              )
            : const Text('Мои визитки'),
        actions: [
          if (!_searchMode) ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Поиск',
              onPressed: () => setState(() => _searchMode = true),
            ),
            PopupMenuButton<String>(
              tooltip: 'Меню',
              onSelected: (v) async {
                if (v == 'csv') await _exportCsv();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'csv', child: Text('Экспорт всех в CSV')),
              ],
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _searchController.clear();
                setState(() => _searchMode = false);
                context.read<CardsListCubit>().search('');
              },
            ),
        ],
      ),
      body: BlocBuilder<CardsListCubit, CardsListState>(
        builder: (context, state) {
          if (state.loading && state.cards.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.error != null && state.cards.isEmpty) {
            return _ErrorView(
              message: state.error!,
              onRetry: () => context.read<CardsListCubit>().load(),
            );
          }
          if (state.isEmpty) {
            return _EmptyView(hasQuery: state.query.isNotEmpty);
          }
          return RefreshIndicator(
            onRefresh: () => context.read<CardsListCubit>().load(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: state.cards.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final card = state.cards[i];
                return BusinessCardTile(
                  card: card,
                  onTap: () => _openDetail(card),
                  onDelete: () => _confirmDelete(card),
                );
              },
            ),
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'gallery',
            tooltip: 'Из галереи',
            onPressed: _pickFromGallery,
            child: const Icon(Icons.photo_library_outlined),
          ),
          const SizedBox(width: 16),
          FloatingActionButton(
            heroTag: 'camera',
            tooltip: 'Сканировать визитку',
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const CameraScreen()),
            ),
            child: const Icon(Icons.camera_alt_outlined),
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(BusinessCard card) async {
    final result = await Navigator.of(context).push<Object>(
      MaterialPageRoute(builder: (_) => CardDetailScreen(card: card)),
    );
    if (!mounted) return;
    if (result == 'deleted' || result == 'updated') {
      await context.read<CardsListCubit>().load();
    }
  }

  Future<void> _confirmDelete(BusinessCard card) async {
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
    if (confirmed == true && mounted) {
      await context.read<CardsListCubit>().delete(card.id);
    }
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.hasQuery});
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasQuery ? Icons.search_off : Icons.badge_outlined,
              size: 72,
              color: Colors.black26,
            ),
            const SizedBox(height: 16),
            Text(
              hasQuery
                  ? 'Ничего не найдено'
                  : 'Пока ни одной визитки.\nНажмите камеру и снимите карточку — '
                      'всё останется на телефоне.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56, color: Colors.black26),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
              child: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}
