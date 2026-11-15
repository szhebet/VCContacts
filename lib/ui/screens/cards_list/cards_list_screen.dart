import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../../business/cards/cards_list_cubit.dart';
import '../../../business/scan/scan_queue_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../core/errors/app_exceptions.dart';
import '../../../data/models/business_card.dart';
import '../../../data/services/backup_service.dart';
import '../../../data/services/export_service.dart';
import '../../../data/services/whisper_model_service.dart';
import '../../widgets/business_card_tile.dart';
import '../camera/camera_screen.dart';
import '../camera/crop_screen.dart';
import '../detail/card_detail_screen.dart';
import '../verify/verification_queue_screen.dart';
import '../verify/verification_screen.dart';

/// Главный экран: список локальных визиток + поиск + экспорт CSV.
class CardsListScreen extends StatefulWidget {
  const CardsListScreen({super.key});

  @override
  State<CardsListScreen> createState() => _CardsListScreenState();
}

class _CardsListScreenState extends State<CardsListScreen> {
  final _searchController = TextEditingController();
  bool _searchMode = false;
  bool _busy = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Выбор из галереи. Одно фото — обычный пайплайн с ручной обрезкой;
  /// несколько — пакетная очередь (`BatchScanScreen`): фото распознаются
  /// по очереди, затем карточки проверяются одна за другой.
  Future<void> _pickFromGallery() async {
    List<XFile> picked;
    try {
      picked = await ImagePicker().pickMultiImage(maxWidth: 4000);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть галерею: $e')),
        );
      }
      return;
    }
    if (picked.isEmpty || !mounted) return;
    if (picked.length == 1) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CropScreen(sourcePath: picked.first.path),
        ),
      );
      return;
    }
    // Несколько фото из галереи не блокируют экран: очередь распознаёт их
    // по одному в фоне, а пользователь сразу возвращается к списку.
    final queue = sl<ScanQueueCubit>();
    for (final file in picked) {
      queue.enqueue(file.path);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Добавлено в очередь распознавания: ${picked.length}',
          ),
        ),
      );
    }
  }

  Future<void> _exportCsv() async {
    final cards = context.read<CardsListCubit>().state.cards;
    await _runExport(() => sl<ExportService>().shareCsv(cards));
  }

  /// Полная резервная копия: все поля + фотографии визитки и владельца.
  /// ZIP уходит в share-sheet — пользователь сохраняет его в облако/на диск,
  /// чтобы восстановить данные после переустановки.
  Future<void> _exportBackup() async {
    final cards = context.read<CardsListCubit>().state.cards;
    await _runExport(() => sl<BackupService>().shareBackup(cards));
  }

  Future<void> _runExport(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.userMessage ?? e.message)),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось выполнить экспорт: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openQueue() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const VerificationQueueScreen()),
    );
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Один раз скачивает модель whisper.cpp для распознавания заметок.
  Future<void> _setupSpeechModel() async {
    final service = sl<WhisperModelService>();
    final installed = await service.isInstalled();
    final bundled = installed ? false : await service.hasBundledModel();
    if (!mounted) return;
    if (installed || bundled) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Распознавание речи'),
          content: Text(
            installed
                ? 'Модель whisper.cpp уже установлена. '
                    'Голосовые заметки распознаются офлайн.'
                : 'Модель whisper.cpp встроена в APK. '
                    'При первом распознавании она будет установлена '
                    'локально; скачивание не требуется.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Понятно'),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Модель распознавания речи'),
        content: const Text(
          'Для распознавания голосовых заметок нужна модель whisper.cpp '
          '(base, ~142 МБ). Она скачивается один раз; после этого '
          'распознавание работает полностью офлайн.\n\nСкачать сейчас?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Скачать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final progress = ValueNotifier<double?>(0);
    BuildContext? dialogContext;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        return AlertDialog(
          title: const Text('Загрузка модели речи'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, value, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('whisper.cpp · base · ~142 МБ'),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: value),
                const SizedBox(height: 8),
                Text(
                  value == null
                      ? 'Загрузка…'
                      : '${(value * 100).round()}%',
                ),
              ],
            ),
          ),
        );
      },
    ));

    void closeProgress() {
      final ctx = dialogContext;
      if (ctx != null && ctx.mounted && Navigator.of(ctx).canPop()) {
        Navigator.of(ctx).pop();
      }
    }

    try {
      await service.download(
        onProgress: (received, total) {
          progress.value = total > 0 ? received / total : null;
        },
      );
      closeProgress();
      _show('Модель распознавания речи установлена');
    } on AppException catch (e) {
      closeProgress();
      _show(
        '${e.userMessage ?? 'Не удалось скачать модель'}. '
        'Можно скопировать ggml-base.bin в '
        'Android/data/com.vccontacts.app/files/',
      );
    } on Object catch (e) {
      closeProgress();
      _show(
        'Не удалось скачать модель: $e. '
        'Можно скопировать ggml-base.bin в '
        'Android/data/com.vccontacts.app/files/',
      );
    } finally {
      // Даём диалогу завершить анимацию закрытия, чтобы не уничтожить
      // ValueNotifier, пока он ещё используется в дереве.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      progress.dispose();
    }
  }

  Future<void> _showSortSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cubit = context.read<CardsListCubit>();
        return SafeArea(
          child: BlocBuilder<CardsListCubit, CardsListState>(
            builder: (context, state) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    'Сортировка',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                for (final sort in CardSort.values)
                  RadioListTile<CardSort>(
                    value: sort,
                    groupValue: state.sort,
                    title: Text(sort.label),
                    onChanged: (value) {
                      if (value != null) cubit.setSort(value);
                      Navigator.of(ctx).pop();
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
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
                  hintText: 'Имя, компания, должность, мероприятие…',
                  border: InputBorder.none,
                  filled: false,
                ),
                onChanged: (q) => context.read<CardsListCubit>().search(q),
              )
            : const Text('Мои визитки'),
        actions: [
          if (!_searchMode)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Поиск',
              onPressed: () => setState(() => _searchMode = true),
            ),
          BlocBuilder<ScanQueueCubit, ScanQueueState>(
            builder: (context, queueState) => IconButton(
              tooltip: 'Очередь проверки',
              onPressed: _openQueue,
              icon: Badge(
                isLabelVisible: queueState.jobs.isNotEmpty,
                label: Text('${queueState.jobs.length}'),
                child: const Icon(Icons.fact_check_outlined),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: 'Сортировка',
            onPressed: _busy ? null : _showSortSheet,
          ),
          if (!_searchMode)
            PopupMenuButton<String>(
              tooltip: 'Меню',
              enabled: !_busy,
              onSelected: (v) async {
                if (v == 'backup') await _exportBackup();
                if (v == 'csv') await _exportCsv();
                if (v == 'queue') await _openQueue();
                if (v == 'speech') await _setupSpeechModel();
                if (v == 'verify') {
                  if (!context.mounted) return;
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const VerificationScreen(),
                    ),
                  );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'queue',
                  child: Text('Очередь проверки'),
                ),
                PopupMenuItem(
                  value: 'speech',
                  child: Text('Модель распознавания речи'),
                ),
                PopupMenuItem(
                  value: 'backup',
                  child: Text('Экспорт базы (ZIP с фото)'),
                ),
                PopupMenuItem(value: 'csv', child: Text('Экспорт всех в CSV')),
                PopupMenuItem(
                  value: 'verify',
                  child: Text('Режим выверки'),
                ),
              ],
            )
          else
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _searchController.clear();
                setState(() => _searchMode = false);
                context.read<CardsListCubit>().search('');
              },
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          BlocBuilder<ScanQueueCubit, ScanQueueState>(
            builder: (context, queueState) => queueState.jobs.isEmpty
                ? const SizedBox.shrink()
                : _ScanQueueBar(state: queueState, onOpen: _openQueue),
          ),
          Expanded(
            child: BlocBuilder<CardsListCubit, CardsListState>(
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
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'gallery',
            tooltip: 'Из галереи (можно несколько)',
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

/// Полоса над списком: что сейчас в фоновой очереди и быстрый микрофон.
class _ScanQueueBar extends StatelessWidget {
  const _ScanQueueBar({required this.state, required this.onOpen});

  final ScanQueueState state;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final processing = state.jobs
        .where((j) => j.status == ScanJobStatus.processing)
        .length;
    final ready = state.readyCount;
    final parts = <String>['В очереди: ${state.jobs.length}'];
    if (processing > 0) parts.add('распознаётся $processing');
    if (ready > 0) parts.add('готово $ready');

    return Material(
      color: const Color(0xFFE8F0FE),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        child: Row(
          children: [
            if (processing > 0)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.hourglass_empty,
                  size: 18, color: Color(0xFF1565C0)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                parts.join(' · '),
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
            ),
            TextButton(
              onPressed: onOpen,
              child: const Text('Очередь'),
            ),
          ],
        ),
      ),
    );
  }
}
