import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../../business/cards/cards_list_cubit.dart';
import '../../../business/scan/scan_queue_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../core/errors/app_exceptions.dart';
import '../../../data/models/business_card.dart';
import '../../../data/repositories/card_repository.dart';
import '../../../data/services/backup_service.dart';
import '../../../data/services/export_service.dart';
import '../../../data/services/qr_card_service.dart';
import '../../../data/services/whisper_model_service.dart';
import '../../widgets/business_card_tile.dart';
import '../../widgets/vcard_qr_dialog.dart';
import '../camera/camera_screen.dart';
import '../camera/crop_screen.dart';
import '../detail/card_detail_screen.dart';
import '../edit/edit_card_screen.dart';
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

  /// Какие группы пользователь свернул/развернул вручную.
  /// Ключ — режим группировки + название группы.
  final Set<String> _toggledGroups = {};

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
      if (await _importQr(picked.first.path)) {
        if (!mounted) return;
        await context.read<CardsListCubit>().load();
        _show('Визитка добавлена из QR-кода');
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CropScreen(sourcePath: picked.first.path),
        ),
      );
      return;
    }

    final remaining = <String>[];
    var qrCount = 0;
    for (final file in picked) {
      if (await _importQr(file.path)) {
        qrCount++;
      } else {
        remaining.add(file.path);
      }
    }
    if (!mounted) return;
    if (qrCount > 0) {
      await context.read<CardsListCubit>().load();
    }
    // Несколько фото из галереи не блокируют экран: очередь распознаёт их
    // по одному в фоне, а пользователь сразу возвращается к списку.
    final queue = sl<ScanQueueCubit>();
    for (final path in remaining) {
      await queue.enqueue(path);
    }
    if (!mounted) return;
    final parts = <String>[
      if (qrCount > 0) 'из QR: $qrCount',
      if (remaining.isNotEmpty) 'в очередь: ${remaining.length}',
    ];
    if (parts.isNotEmpty) {
      _show('Добавлено ${parts.join(', ')}');
    }
  }

  /// Пытается распознать vCard в QR-коде и сразу сохранить карточку.
  Future<bool> _importQr(String path) async {
    try {
      return await sl<QrCardService>().importFile(path) != null;
    } on Object catch (e) {
      debugPrint('[QR] импорт не удался: $e');
      return false;
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

  Future<void> _createCard() async {
    final now = DateTime.now();
    final saved = await Navigator.of(context).push<BusinessCard>(
      MaterialPageRoute(
        builder: (_) => EditCardScreen(
          draft: BusinessCard(
            id: '',
            createdAt: now,
            updatedAt: now,
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (saved != null) {
      await context.read<CardsListCubit>().load();
    }
  }

  Future<void> _clearQueues() async {
    final queue = context.read<ScanQueueCubit>();
    if (queue.state.jobs.isEmpty) {
      _show('Очереди уже пусты');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить очереди?'),
        content: const Text(
          'Будут удалены все несохранённые задания распознавания и '
          'проверки, их черновики, временные фото и голосовые заметки. '
          'Сохранённые визитки не пострадают.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await queue.clearAll();
    if (mounted) _show('Очереди очищены');
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showMyVcardQr() async {
    BusinessCard? my;
    try {
      // Берём из БД, а не из отфильтрованного поиском списка.
      final cards = await sl<CardRepository>().getAll();
      for (final card in cards) {
        if (card.myVcard) {
          my = card;
          break;
        }
      }
    } on Object catch (e) {
      _show('Не удалось найти карточку MyVcard: $e');
      return;
    }
    if (my == null) {
      _show(
        'Сначала отметьте визитку как «Моя визитка (MyVcard)» '
        'на форме редактирования.',
      );
      return;
    }
    if (!mounted) return;
    await VCardQrDialog.show(context, my);
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
                  value == null ? 'Загрузка…' : '${(value * 100).round()}%',
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

  Future<void> _showGroupingSheet() async {
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
                    'Группировка',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                for (final grouping in CardGrouping.values)
                  RadioListTile<CardGrouping>(
                    value: grouping,
                    groupValue: state.grouping,
                    title: Text(grouping.label),
                    onChanged: (value) {
                      if (value != null) {
                        if (value != cubit.state.grouping) {
                          // При смене режима возвращаем настройки по
                          // умолчанию: группы по компаниям — свёрнуты.
                          setState(() => _toggledGroups.clear());
                        }
                        cubit.setGrouping(value);
                      }
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

  Widget _buildCardsList(CardsListState state) {
    if (state.grouping == CardGrouping.none) {
      return ListView.separated(
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
      );
    }

    final groups = groupCards(state.cards, state.grouping);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        for (final group in groups) _groupSection(state.grouping, group),
      ],
    );
  }

  Widget _groupSection(CardGrouping grouping, CardGroup group) {
    final expanded = _isGroupExpanded(grouping, group.title);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupHeader(
          title: group.title,
          count: group.cards.length,
          expanded: expanded,
          onTap: () => _toggleGroup(grouping, group.title),
        ),
        if (expanded)
          for (final card in group.cards)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: BusinessCardTile(
                card: card,
                onTap: () => _openDetail(card),
                onDelete: () => _confirmDelete(card),
              ),
            ),
      ],
    );
  }

  String _groupKey(CardGrouping grouping, String title) =>
      '${grouping.name}:${title.trim().toLowerCase()}';

  /// Все группы по умолчанию свёрнуты; ручное переключение запоминается
  /// до смены режима группировки.
  bool _isGroupExpanded(CardGrouping grouping, String title) =>
      _toggledGroups.contains(_groupKey(grouping, title));

  void _toggleGroup(CardGrouping grouping, String title) {
    final key = _groupKey(grouping, title);
    setState(() {
      if (!_toggledGroups.remove(key)) _toggledGroups.add(key);
    });
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
                  hintText: 'Имя, компания, тег…',
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
            builder: (context, queueState) => queueState.jobs.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Очередь проверки',
                    onPressed: _openQueue,
                    icon: Badge(
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
                if (v == 'create') await _createCard();
                if (v == 'backup') await _exportBackup();
                if (v == 'csv') await _exportCsv();
                if (v == 'queue') await _openQueue();
                if (v == 'group') await _showGroupingSheet();
                if (v == 'clear') await _clearQueues();
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
              itemBuilder: (menuContext) {
                final hasQueue =
                    menuContext.read<ScanQueueCubit>().state.jobs.isNotEmpty;
                return [
                  const PopupMenuItem(
                    value: 'create',
                    child: Row(
                      children: [
                        Icon(Icons.add),
                        SizedBox(width: 8),
                        Text('Создать'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'group',
                    child: Text('Группировка'),
                  ),
                  if (hasQueue)
                    const PopupMenuItem(
                      value: 'queue',
                      child: Text('Очередь проверки'),
                    ),
                  const PopupMenuItem(
                    value: 'speech',
                    child: Text('Модель распознавания речи'),
                  ),
                  const PopupMenuItem(
                    value: 'backup',
                    child: Text('Экспорт базы (ZIP с фото)'),
                  ),
                  const PopupMenuItem(
                    value: 'csv',
                    child: Text('Экспорт всех в CSV'),
                  ),
                  const PopupMenuItem(
                    value: 'verify',
                    child: Text('Режим выверки'),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'clear',
                    child: Text(
                      'Очистить очереди',
                      style: TextStyle(color: Color(0xFFC62828)),
                    ),
                  ),
                ];
              },
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
                  child: _buildCardsList(state),
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
          FloatingActionButton.small(
            heroTag: 'myvcard_qr',
            tooltip: 'QR-код моей визитки (MyVcard)',
            onPressed: _showMyVcardQr,
            child: const Icon(Icons.qr_code_2),
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

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: const Color(0xFFF3F6FB),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 22,
                  color: Colors.black54,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8EDF5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    final processing =
        state.jobs.where((j) => j.status == ScanJobStatus.processing).length;
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
