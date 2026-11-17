import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../business/cards/cards_list_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../core/errors/app_exceptions.dart';
import '../../../data/models/business_card.dart';
import '../../../data/repositories/card_repository.dart';
import '../../../data/services/card_photo_service.dart';
import '../../../data/services/contact_export_service.dart';
import '../../../data/services/export_service.dart';
import '../../../data/services/voice_note_service.dart';
import '../../widgets/vcard_qr_dialog.dart';
import '../../widgets/voice_recorder_sheet.dart';
import '../camera/crop_screen.dart';
import '../edit/edit_card_screen.dart';

/// Просмотр визитки + экспорты: контакты устройства, vCard, копирование.
/// Всё экспортируется только локально (контакты телефона / share-sheet).
class CardDetailScreen extends StatefulWidget {
  const CardDetailScreen({super.key, required this.card});

  final BusinessCard card;

  @override
  State<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends State<CardDetailScreen> {
  late BusinessCard _card;
  bool _busy = false;
  bool _playingVoice = false;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
  }

  @override
  void dispose() {
    if (sl.isRegistered<VoiceNoteService>()) {
      unawaited(sl<VoiceNoteService>().stopPlayback());
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppException catch (e) {
      _show(e.userMessage ?? e.message);
    } on Exception catch (e) {
      _show('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _exportToContacts() => _run(() async {
        final ok =
            await sl<ContactExportService>().exportToDeviceContacts(_card);
        if (ok) _show('Контакт сохранён в телефон');
      });

  Future<void> _exportVCard() =>
      _run(() => sl<ExportService>().shareVCard(_card));

  Future<void> _edit() async {
    final result = await Navigator.of(context).push<BusinessCard>(
      MaterialPageRoute(builder: (_) => EditCardScreen(draft: _card)),
    );
    if (result == null || !mounted) return;
    // Показываем обновлённую карточку и подтягиваем список под ней.
    setState(() => _card = result);
    await context.read<CardsListCubit>().load();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить визитку?'),
        content: Text('«${_card.displayTitle}» будет удалена с устройства.'),
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
    await sl<CardRepository>().delete(_card.id);
    if (mounted) Navigator.of(context).pop('deleted');
  }

  Future<void> _copy(String value, String label) async {
    if (value.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value.trim()));
    _show('$label скопировано');
  }

  /// Текстовая заметка: диалог с многострочным полем. Сохраняется сразу.
  Future<void> _editNotes() async {
    final controller = TextEditingController(text: _card.notes);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Заметка'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 4,
          maxLines: 10,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Текстовая заметка по контакту…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted) return;
    await _saveNotes(text.trim());
  }

  Future<void> _saveNotes(String note) async {
    final previous = _card;
    final updated = previous.copyWith(notes: note);
    final listCubit = context.read<CardsListCubit>();
    setState(() => _card = updated);
    try {
      final saved = await sl<CardRepository>().saveDraft(
        updated,
        existingId: updated.id,
      );
      if (!mounted) return;
      setState(() => _card = saved);
      await listCubit.load();
      _show(note.isEmpty ? 'Заметка удалена' : 'Заметка сохранена');
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _card = previous);
      _show(e.userMessage ?? 'Не удалось сохранить заметку');
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _card = previous);
      _show('Не удалось сохранить заметку: $e');
    }
  }

  /// Голосовая заметка: открывает диктофон, затем сохраняет запись в БД.
  Future<void> _recordVoiceNote() async {
    if (_busy) return;
    final service = sl<VoiceNoteService>();
    if (!service.isSupported) {
      _show('Голосовые заметки пока доступны только на Android');
      return;
    }
    if (_playingVoice) {
      await service.stopPlayback();
      if (mounted) setState(() => _playingVoice = false);
    }
    if (!mounted) return;
    final recording = await showModalBottomSheet<VoiceRecording>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => VoiceRecorderSheet(cardId: _card.id),
    );
    if (recording == null || !mounted) return;
    await _saveVoiceNote(recording);
  }

  Future<void> _saveVoiceNote(VoiceRecording recording) async {
    final previous = _card;
    final service = sl<VoiceNoteService>();
    final listCubit = context.read<CardsListCubit>();
    setState(() => _busy = true);
    String? persistedPath;
    var dbSaved = false;
    try {
      persistedPath = await service.persist(recording.path);
      final saved = await sl<CardRepository>().saveDraft(
        previous.copyWith(
          voiceNotePath: persistedPath,
          voiceNoteDurationMs: recording.durationMs,
        ),
        existingId: previous.id,
      );
      dbSaved = true;
      if (!mounted) return;
      setState(() => _card = saved);
      // Старую запись удаляем только после успешной записи в БД.
      await service.deleteIfOwned(previous.voiceNotePath);
      await listCubit.load();
      _show('Голосовая заметка сохранена');
    } on AppException catch (e) {
      if (!dbSaved) {
        if (persistedPath != null) {
          await service.deleteIfOwned(persistedPath);
        } else {
          await service.deleteTemp(recording.path);
        }
      }
      if (mounted) _show(e.userMessage ?? 'Не удалось сохранить запись');
    } on Exception catch (e) {
      if (!dbSaved) {
        if (persistedPath != null) {
          await service.deleteIfOwned(persistedPath);
        } else {
          await service.deleteTemp(recording.path);
        }
      }
      if (mounted) _show('Не удалось сохранить запись: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleVoicePlayback() async {
    final service = sl<VoiceNoteService>();
    if (!service.isSupported) {
      _show('Воспроизведение пока доступно только на Android');
      return;
    }
    if (_playingVoice) {
      await service.stopPlayback();
      if (mounted) setState(() => _playingVoice = false);
      return;
    }
    final path = _card.voiceNotePath;
    if (path == null) return;
    setState(() => _playingVoice = true);
    try {
      await service.play(path);
    } on AppException catch (e) {
      if (mounted) _show(e.userMessage ?? e.message);
    } finally {
      if (mounted) setState(() => _playingVoice = false);
    }
  }

  static String _formatDuration(int ms) {
    if (ms <= 0) return '';
    final total = (ms / 1000).round();
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _notesSection(ThemeData theme) {
    final note = _card.notes.trim();
    final hasVoice = _card.voiceNotePath != null;
    final duration = _formatDuration(_card.voiceNoteDurationMs);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sticky_note_2_outlined,
                    size: 18, color: Colors.black45),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Заметки',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                IconButton(
                  tooltip: 'Текстовая заметка',
                  onPressed: _editNotes,
                  icon: const Icon(Icons.more_horiz),
                ),
                IconButton(
                  tooltip: hasVoice
                      ? 'Перезаписать голосовую заметку'
                      : 'Записать голосовую заметку',
                  onPressed: _recordVoiceNote,
                  icon: const Icon(Icons.mic_none),
                ),
                IconButton(
                  tooltip: _playingVoice
                      ? 'Остановить воспроизведение'
                      : 'Прослушать голосовую заметку',
                  onPressed: hasVoice ? _toggleVoicePlayback : null,
                  icon: Icon(
                    _playingVoice
                        ? Icons.stop_circle_outlined
                        : Icons.volume_up_outlined,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            InkWell(
              onTap: _editNotes,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Text(
                  note.isEmpty
                      ? 'Нет текстовой заметки — нажмите «…», чтобы добавить'
                      : note,
                  style: TextStyle(
                    fontSize: 15,
                    color: note.isEmpty ? Colors.black38 : Colors.black87,
                  ),
                ),
              ),
            ),
            if (hasVoice) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.graphic_eq,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Голосовая заметка${duration.isEmpty ? '' : ' · $duration'}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.black54,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Мини-редактор фото владельца: кадрирование текущего снимка или
  /// выбор нового из галереи (с последующим кадрированием).
  Future<void> _showOwnerPhotoEditor() async {
    final owner = _card.ownerImagePath;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Фото владельца',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Center(
                child: ClipOval(
                  child: owner == null
                      ? Container(
                          width: 180,
                          height: 180,
                          color: const Color(0xFFF1F3F6),
                          alignment: Alignment.center,
                          child: const Text(
                            'Нет фото',
                            style: TextStyle(color: Colors.black45),
                          ),
                        )
                      : Image.file(
                          File(owner),
                          width: 180,
                          height: 180,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 180,
                            height: 180,
                            color: const Color(0xFFF1F3F6),
                            alignment: Alignment.center,
                            child: const Text(
                              'Фото не найдено',
                              style: TextStyle(color: Colors.black45),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              if (owner != null)
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(ctx, 'crop'),
                  icon: const Icon(Icons.crop),
                  label: const Text('Кадрировать'),
                ),
              if (owner != null) const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, 'pick'),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(owner == null ? 'Выбрать фото' : 'Выбрать другое'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'crop':
        await _cropOwnerPhoto();
      case 'pick':
        await _pickOwnerPhoto();
    }
  }

  Future<void> _cropOwnerPhoto() async {
    final path = _card.ownerImagePath;
    if (path == null) return;
    final selection = await Navigator.of(context).push<CropSelection>(
      MaterialPageRoute(
        builder: (_) => CropScreen(
          sourcePath: path,
          cropOnly: true,
          circle: true,
        ),
      ),
    );
    if (selection == null || !mounted) return;
    await _saveOwnerPhoto(path, selection);
  }

  Future<void> _pickOwnerPhoto() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 4000,
      );
    } on Object catch (e) {
      _show('Не удалось открыть галерею: $e');
      return;
    }
    if (picked == null || !mounted) return;
    final selection = await Navigator.of(context).push<CropSelection>(
      MaterialPageRoute(
        builder: (_) => CropScreen(
          sourcePath: picked!.path,
          cropOnly: true,
          circle: true,
        ),
      ),
    );
    if (selection == null || !mounted) return;
    await _saveOwnerPhoto(picked.path, selection);
  }

  Future<void> _saveOwnerPhoto(
    String source,
    CropSelection selection,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    final previous = _card;
    final photos = sl<CardPhotoService>();
    final listCubit = context.read<CardsListCubit>();
    String? newPath;
    var persisted = false;
    try {
      newPath = await photos.saveOwnerPhoto(
        source,
        crop: selection.crop,
        rotationDegrees: selection.rotationDegrees,
      );
      final saved = await sl<CardRepository>().saveDraft(
        previous.copyWith(ownerImagePath: newPath),
        existingId: previous.id,
      );
      persisted = true;
      if (!mounted) return;
      setState(() => _card = saved);
      // Старое фото удаляем только после успешной записи в БД.
      await photos.deleteIfOwned(previous.ownerImagePath);
      await listCubit.load();
      _show('Фото владельца обновлено');
    } on AppException catch (e) {
      if (!persisted) await photos.deleteIfOwned(newPath);
      if (mounted) _show(e.userMessage ?? 'Не удалось сохранить фото');
    } on Exception catch (e) {
      if (!persisted) await photos.deleteIfOwned(newPath);
      if (mounted) _show('Не удалось сохранить фото: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Двойной тап по «Проверена»: ставит флаг и сразу пишет в БД.
  /// Повторный двойной тап ничего не сбрасывает.
  Future<void> _markVerified() async {
    if (_card.verified || _busy) return;
    final previous = _card;
    // Оптимистично показываем «Да» — запись в БД короткая, но если она
    // сорвётся, вернём прежнее значение.
    setState(() => _card = _card.copyWith(verified: true));
    try {
      final saved = await sl<CardRepository>().saveDraft(
        _card,
        existingId: _card.id,
      );
      if (!mounted) return;
      setState(() => _card = saved);
      // Список под экраном показывает галочку «проверена» — обновляем его.
      await context.read<CardsListCubit>().load();
      _show('Визитка отмечена как проверенная');
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _card = previous);
      _show(e.userMessage ?? 'Не удалось сохранить отметку');
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _card = previous);
      _show('Не удалось сохранить отметку: $e');
    }
  }

  /// Переключает флаг MyVcard. Репозиторий снимает его с остальных
  /// карточек в одной транзакции.
  Future<void> _toggleMyVcard() async {
    if (_busy) return;
    final previous = _card;
    final next = !_card.myVcard;
    setState(() => _card = _card.copyWith(myVcard: next));
    try {
      final saved = await sl<CardRepository>().saveDraft(
        _card,
        existingId: _card.id,
      );
      if (!mounted) return;
      setState(() => _card = saved);
      await context.read<CardsListCubit>().load();
      _show(next
          ? 'Карточка отмечена как «Моя визитка»'
          : 'Флаг «Моя визитка» снят');
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _card = previous);
      _show(e.userMessage ?? 'Не удалось сохранить отметку');
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _card = previous);
      _show('Не удалось сохранить отметку: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _card.phone.trim().isNotEmpty
              ? (_card.phoneRaw.trim().isNotEmpty
                  ? _card.phoneRaw.trim()
                  : _card.phone.trim())
              : 'Визитка',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Редактировать',
            onPressed: _edit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Удалить',
            onPressed: _delete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // --- Шапка ---
          Center(
            child: Column(
              children: [
                GestureDetector(
                  // Одинарный тап — посмотреть фото, двойной — открыть
                  // редактор фото (кадрирование/замена). Если фото ещё нет,
                  // одинарный тап сразу открывает редактор.
                  onTap: _card.ownerImagePath == null
                      ? _showOwnerPhotoEditor
                      : () => _showPhoto(_card.ownerImagePath!),
                  onDoubleTap: _showOwnerPhotoEditor,
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    backgroundImage: _card.ownerImagePath == null
                        ? null
                        : FileImage(File(_card.ownerImagePath!)),
                    child: _card.ownerImagePath == null
                        ? Text(
                            _initials(),
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _card.displayTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_card.displaySubtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _card.displaySubtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.black54,
                    ),
                  ),
                ],
                Text(
                  'Обновлено ${DateFormat('dd.MM.yyyy HH:mm').format(_card.updatedAt)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.black38,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // --- Фото визитки ---
          if ((_card.cardImagePath ?? _card.photoPath) != null) ...[
            Stack(
              children: [
                GestureDetector(
                  onTap: () =>
                      _showPhoto((_card.cardImagePath ?? _card.photoPath)!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.file(
                      File((_card.cardImagePath ?? _card.photoPath)!),
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 120,
                        color: const Color(0xFFF1F3F6),
                        alignment: Alignment.center,
                        child: const Text('Фото не найдено'),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'QR-код визитки (vCard 4.0)',
                      onPressed: () => VCardQrDialog.show(context, _card),
                      icon: const Icon(Icons.qr_code_2, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // --- Основные поля: сразу после фото ---
          ..._phoneTiles(),
          if (_card.email.isNotEmpty)
            _FieldTile(
              icon: Icons.mail_outline,
              label: 'Email',
              value: _card.email,
              onTap: () => _copy(_card.email, 'Email'),
            ),
          if (_card.company.isNotEmpty)
            _FieldTile(
              icon: Icons.business_outlined,
              label: 'Компания',
              value: _card.company,
              onTap: () => _copy(_card.company, 'Компания'),
            ),
          if (_card.position.isNotEmpty)
            _FieldTile(
              icon: Icons.work_outline,
              label: 'Должность',
              value: _card.position,
              onTap: () => _copy(_card.position, 'Должность'),
            ),

          // --- Остальные поля ---
          if (_card.telegram.isNotEmpty)
            _FieldTile(
              icon: Icons.send_outlined,
              label: 'Telegram',
              value: _card.telegram,
              onTap: () => _copy(_card.telegram, 'Telegram'),
            ),
          if (_card.website.isNotEmpty)
            _FieldTile(
              icon: Icons.language,
              label: 'Сайт',
              value: _card.website,
              onTap: () => _copy(_card.website, 'Сайт'),
            ),
          if (_card.address.isNotEmpty)
            _FieldTile(
              icon: Icons.location_on_outlined,
              label: 'Адрес',
              value: _card.address,
              onTap: () => _copy(_card.address, 'Адрес'),
            ),
          if (_card.otherText.isNotEmpty)
            _FieldTile(
              icon: Icons.text_snippet_outlined,
              label: 'Прочий текст',
              value: _card.otherText,
              onTap: () => _copy(_card.otherText, 'Прочий текст'),
            ),

          // --- Метаданные ---
          _FieldTile(
            icon: Icons.event_available_outlined,
            label: 'Создана',
            value: DateFormat('dd.MM.yyyy HH:mm').format(_card.createdAt),
          ),
          _FieldTile(
            icon: Icons.verified_outlined,
            label: 'Проверена',
            value: _card.verified ? 'Да' : 'Нет',
            onDoubleTap: _markVerified,
          ),
          _FieldTile(
            icon: Icons.qr_code_2,
            label: 'Моя визитка (MyVcard)',
            value: _card.myVcard ? 'Да' : 'Нет',
            onTap: _toggleMyVcard,
          ),
          if (_card.event.isNotEmpty)
            _FieldTile(
              icon: Icons.local_activity_outlined,
              label: 'Мероприятие',
              value: _card.event,
              onTap: () => _copy(_card.event, 'Мероприятие'),
            ),
          if (_card.tags.isNotEmpty)
            _FieldTile(
              icon: Icons.sell_outlined,
              label: 'Теги',
              value: _card.tags.join(', '),
              onTap: () => _copy(_card.tags.join(', '), 'Теги'),
            ),

          const SizedBox(height: 20),

          // --- Заметки: текст + голос ---
          _notesSection(theme),
          const SizedBox(height: 20),

          // --- Экспорт ---
          Row(
            children: [
              Expanded(
                child: _ActionCard(
                  icon: Icons.person_add_alt,
                  label: 'В контакты',
                  onTap: _busy ? null : _exportToContacts,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionCard(
                  icon: Icons.ios_share,
                  label: 'vCard',
                  onTap: _busy ? null : _exportVCard,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // --- Фото владельца в самом конце карточки ---
          if (_card.ownerImagePath != null) ...[
            const Text(
              'Фото владельца',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF5A6472),
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => _showPhoto(_card.ownerImagePath!),
              child: Center(
                child: ClipOval(
                  child: Image.file(
                    File(_card.ownerImagePath!),
                    width: 220,
                    height: 220,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 220,
                      height: 220,
                      color: const Color(0xFFF1F3F6),
                      alignment: Alignment.center,
                      child: const Text('Фото владельца не найдено'),
                    ),
                  ),
                ),
              ),
            ),
          ],

          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  List<Widget> _phoneTiles() {
    final phones = <String>[
      if (_card.phone.trim().isNotEmpty)
        _card.phoneRaw.isNotEmpty ? _card.phoneRaw : _card.phone,
      ..._card.extraPhones.where((p) => p.trim().isNotEmpty),
    ];
    return [
      for (var i = 0; i < phones.length; i++)
        _FieldTile(
          icon: Icons.phone_outlined,
          label: i == 0 ? 'Телефон' : 'Телефон ${i + 1}',
          value: phones[i],
          onTap: () => _copy(phones[i], 'Телефон'),
        ),
    ];
  }

  void _showPhoto(String path) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('Фото'),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 6,
              child: Image.file(File(path)),
            ),
          ),
        ),
      ),
    );
  }

  String _initials() {
    final source = _card.fullName.trim().isNotEmpty
        ? _card.fullName
        : (_card.company.isNotEmpty ? _card.company : _card.phone);
    final parts = source
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .toList();
    return parts.isEmpty ? '?' : parts.map((p) => p[0].toUpperCase()).join();
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon,
                  color: onTap == null
                      ? Colors.black26
                      : theme.colorScheme.primary),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.onDoubleTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: ListTile(
          leading: Icon(icon, color: Colors.black45),
          title: Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          subtitle: Text(
            value,
            style: const TextStyle(fontSize: 15, color: Colors.black87),
          ),
          trailing: onTap == null
              ? null
              : const Icon(Icons.copy, size: 16, color: Colors.black26),
        ),
      ),
    );
  }
}
