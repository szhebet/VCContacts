import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../business/cards/cards_list_cubit.dart';
import '../../../business/edit/edit_card_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../core/errors/app_exceptions.dart';
import '../../../data/models/business_card.dart';
import '../../../data/services/card_photo_service.dart';
import '../../../data/services/diagnostic_service.dart';
import '../../../data/services/ocr_service.dart';
import '../../../data/services/voice_note_service.dart';
import '../../widgets/editable_field.dart';
import '../../widgets/ocr_diagnostic_panel.dart';
import '../../widgets/voice_recorder_sheet.dart';
import '../camera/crop_screen.dart';

/// Экран проверки/редактирования результата OCR перед сохранением.
/// Явно подтверждение пользователя — данные попадают в БД осознанно.
class EditCardScreen extends StatefulWidget {
  const EditCardScreen({
    super.key,
    required this.draft,
    this.warnings = const [],
    this.unmatchedLines = const [],
    this.emptyOcr = false,
    this.diagnostic,
    this.ocrResult,
    this.processedImagePath,
    this.variantPaths = const [],
    this.autoWarped = false,
    this.batchIndex,
    this.batchTotal,
  });

  final BusinessCard draft;
  final List<String> warnings;
  final List<String> unmatchedLines;
  final bool emptyOcr;
  final OcrDiagnostic? diagnostic;

  /// Полный результат OCR (слова/bbox, сырой hOCR) — для кнопки выгрузки
  /// расширенной диагностики. null, если экран открыт вне пайплайна скана
  /// (например, редактирование из карточки).
  final OcrResult? ocrResult;

  /// Обработанное изображение, ушедшее в OCR — источник вырезок полей.
  final String? processedImagePath;

  /// Все варианты предобработки (для summary диагностики).
  final List<String> variantPaths;

  /// Была ли применена авто-детекция границ визитки (OpenCV).
  final bool autoWarped;

  /// Номер карточки в пакетном режиме (1-based) и общее число карточек.
  /// null — обычный одиночный скан.
  final int? batchIndex;
  final int? batchTotal;

  @override
  State<EditCardScreen> createState() => _EditCardScreenState();
}

class _EditCardScreenState extends State<EditCardScreen> {
  late final EditCardCubit _cubit;
  late final TextEditingController _name;
  late final TextEditingController _position;
  late final TextEditingController _company;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _website;
  late final TextEditingController _address;
  late final TextEditingController _notes;
  late final TextEditingController _otherText;
  late final TextEditingController _event;
  late final TextEditingController _telegram;
  late final TextEditingController _tags;
  final List<TextEditingController> _extraPhones = [];

  /// Файлы, созданные на этом экране (фото WebP, голосовые WAV), и исходные
  /// файлы карточки. При сохранении удаляем заменённые, при отказе — все
  /// созданные.
  final Set<String> _createdPhotos = {};
  final Set<String> _originalPhotos = {};
  final Set<String> _createdVoiceNotes = {};
  final Set<String> _originalVoiceNotes = {};
  bool _playingVoice = false;
  bool _voiceBusy = false;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    _cubit = EditCardCubit(
      sl(),
      draft: d,
      unmatchedLines: widget.unmatchedLines,
      warnings: widget.warnings,
    );
    _name = TextEditingController(text: d.fullName);
    _position = TextEditingController(text: d.position);
    _company = TextEditingController(text: d.company);
    _phone = TextEditingController(
        text: d.phoneRaw.isNotEmpty ? d.phoneRaw : d.phone);
    _email = TextEditingController(text: d.email);
    _website = TextEditingController(text: d.website);
    _address = TextEditingController(text: d.address);
    _notes = TextEditingController(text: d.notes);
    _otherText = TextEditingController(text: d.otherText);
    _event = TextEditingController(text: d.event);
    _telegram = TextEditingController(text: d.telegram);
    _tags = TextEditingController(text: d.tags.join(', '));
    for (final phone in d.extraPhones) {
      _extraPhones.add(TextEditingController(text: phone));
    }
    if (d.cardImagePath != null) _originalPhotos.add(d.cardImagePath!);
    if (d.ownerImagePath != null) _originalPhotos.add(d.ownerImagePath!);
    if (d.voiceNotePath != null) _originalVoiceNotes.add(d.voiceNotePath!);
  }

  @override
  void dispose() {
    if (sl.isRegistered<VoiceNoteService>()) {
      unawaited(sl<VoiceNoteService>().stopPlayback());
    }
    _cubit.close();
    for (final c in [
      _name,
      _position,
      _company,
      _phone,
      _email,
      _website,
      _address,
      _notes,
      _otherText,
      _event,
      _telegram,
      _tags,
      ..._extraPhones,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    // Переливаем значения из контроллеров в кубит, затем сохраняем.
    _cubit
      ..setExtraPhones([
        for (final c in _extraPhones)
          if (c.text.trim().isNotEmpty) c.text.trim(),
      ])
      ..updateField(CardField.fullName, _name.text)
      ..updateField(CardField.position, _position.text)
      ..updateField(CardField.company, _company.text)
      ..updateField(CardField.phone, _phone.text)
      ..updateField(CardField.email, _email.text)
      ..updateField(CardField.website, _website.text)
      ..updateField(CardField.address, _address.text)
      ..updateField(CardField.notes, _notes.text)
      ..updateField(CardField.otherText, _otherText.text)
      ..updateField(CardField.event, _event.text)
      ..updateField(CardField.telegram, _telegram.text)
      ..setTags(_parseTags(_tags.text));

    // Фото визитки при сохранении сжимается в WebP и кладётся в данные
    // приложения (если пользователь ещё не обрезал его на форме).
    final card = _cubit.state.card;
    final source = card.cardImagePath ?? card.photoPath;
    if (card.cardImagePath == null && source != null) {
      await _compressCardPhoto(source);
    }

    final ok = await _cubit.save();
    if (ok) await _cleanupReplacedFiles();
    if (!ok || !mounted) return;

    // Обновляем корневой список (провайдер выше MaterialApp).
    await context.read<CardsListCubit>().load();
    if (!mounted) return;
    Navigator.of(context).pop(_cubit.state.card);
  }

  /// Полный распознанный текст: у новых карточек — ocrText, у старых —
  /// «прочий текст» (полного не сохраняли).
  String get _ocrText {
    final card = _cubit.state.card;
    return card.ocrText.trim().isNotEmpty ? card.ocrText : card.otherText;
  }

  String? get _cardPhotoSource {
    final card = _cubit.state.card;
    return card.cardImagePath ?? card.photoPath;
  }

  Future<void> _compressCardPhoto(String source) async {
    try {
      final path = await sl<CardPhotoService>().saveCardPhoto(source);
      _cubit.setCardImagePath(path);
      _createdPhotos.add(path);
    } on AppException catch (e) {
      _showError(e.userMessage ?? 'Не удалось сохранить фото');
    }
  }

  Future<void> _pickCardPhoto() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 4000,
      );
    } on Object catch (e) {
      _showError('Не удалось открыть галерею: $e');
      return;
    }
    if (picked == null) return;
    await _compressCardPhoto(picked.path);
  }

  Future<void> _cropCardPhoto() async {
    final source = _cardPhotoSource;
    if (source == null) {
      await _pickCardPhoto();
      return;
    }
    final selection = await Navigator.of(context).push<CropSelection>(
      MaterialPageRoute(
        builder: (_) => CropScreen(sourcePath: source, cropOnly: true),
      ),
    );
    if (selection == null) return;
    try {
      final path = await sl<CardPhotoService>().saveCardPhoto(
        source,
        crop: selection.crop,
        rotationDegrees: selection.rotationDegrees,
      );
      _cubit.setCardImagePath(path);
      _createdPhotos.add(path);
    } on AppException catch (e) {
      _showError(e.userMessage ?? 'Не удалось обрезать фото');
    }
  }

  Future<void> _pickOwnerPhoto() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 4000,
      );
    } on Object catch (e) {
      _showError('Не удалось открыть галерею: $e');
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

  Future<void> _cropOwnerPhoto() async {
    final source = _cubit.state.card.ownerImagePath;
    if (source == null) return;
    final selection = await Navigator.of(context).push<CropSelection>(
      MaterialPageRoute(
        builder: (_) => CropScreen(
          sourcePath: source,
          cropOnly: true,
          circle: true,
        ),
      ),
    );
    if (selection == null || !mounted) return;
    await _saveOwnerPhoto(source, selection);
  }

  Future<void> _saveOwnerPhoto(
    String source,
    CropSelection selection,
  ) async {
    try {
      final path = await sl<CardPhotoService>().saveOwnerPhoto(
        source,
        crop: selection.crop,
        rotationDegrees: selection.rotationDegrees,
      );
      _cubit.setOwnerImagePath(path);
      _createdPhotos.add(path);
    } on AppException catch (e) {
      _showError(e.userMessage ?? 'Не удалось сохранить фото владельца');
    }
  }

  Future<void> _removeOwnerPhoto() async {
    // Сам файл удаляем после успешного сохранения (см. cleanup): если
    // пользователь передумает, карточка в БД всё ещё ссылается на него.
    _cubit.setOwnerImagePath(null);
  }

  /// Записывает голосовую заметку и прикрепляет её к текущей карточке.
  /// Файл переносится из кэша в данные приложения сразу, а старый удаляется
  /// только после успешного сохранения (или отмены — см. _discard).
  Future<void> _recordVoiceNote() async {
    if (_voiceBusy) return;
    final service = sl<VoiceNoteService>();
    if (!service.isSupported) {
      _showError('Голосовые заметки пока доступны только на Android');
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
      builder: (_) => VoiceRecorderSheet(
        cardId: _cubit.state.card.id.isEmpty ? 'draft' : _cubit.state.card.id,
      ),
    );
    if (recording == null || !mounted) return;

    setState(() => _voiceBusy = true);
    String? persisted;
    try {
      persisted = await service.persist(recording.path);
      if (!mounted) {
        await service.deleteIfOwned(persisted);
        return;
      }
      _cubit.setVoiceNote(persisted, durationMs: recording.durationMs);
      _createdVoiceNotes.add(persisted);
    } on AppException catch (e) {
      await service.deleteTemp(recording.path);
      _showError(e.userMessage ?? 'Не удалось сохранить запись');
    } on Object catch (e) {
      await service.deleteTemp(recording.path);
      _showError('Не удалось сохранить запись: $e');
    } finally {
      if (mounted) setState(() => _voiceBusy = false);
    }
  }

  Future<void> _toggleVoicePlayback() async {
    final service = sl<VoiceNoteService>();
    if (!service.isSupported) {
      _showError('Воспроизведение пока доступно только на Android');
      return;
    }
    if (_playingVoice) {
      await service.stopPlayback();
      if (mounted) setState(() => _playingVoice = false);
      return;
    }
    final path = _cubit.state.card.voiceNotePath;
    if (path == null) return;
    setState(() => _playingVoice = true);
    try {
      await service.play(path);
    } on AppException catch (e) {
      _showError(e.userMessage ?? e.message);
    } finally {
      if (mounted) setState(() => _playingVoice = false);
    }
  }

  void _removeVoiceNote() {
    if (_playingVoice) {
      unawaited(sl<VoiceNoteService>().stopPlayback());
      setState(() => _playingVoice = false);
    }
    _cubit.setVoiceNote(null);
  }

  static String _formatDuration(int ms) {
    if (ms <= 0) return '';
    final total = (ms / 1000).round();
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// После сохранения удаляет файлы, на которые карточка больше не
  /// ссылается: заменённые исходные фото/записи и промежуточные варианты.
  Future<void> _cleanupReplacedFiles() async {
    final card = _cubit.state.card;
    final keepPhotos = {card.cardImagePath, card.ownerImagePath};
    final photos = sl<CardPhotoService>();
    for (final path in {..._createdPhotos, ..._originalPhotos}) {
      if (!keepPhotos.contains(path)) await photos.deleteIfOwned(path);
    }
    final keepVoice = card.voiceNotePath;
    final voice = sl<VoiceNoteService>();
    for (final path in {..._createdVoiceNotes, ..._originalVoiceNotes}) {
      if (path != keepVoice) await voice.deleteIfOwned(path);
    }
    _createdPhotos.clear();
    _originalPhotos.clear();
    _createdVoiceNotes.clear();
    _originalVoiceNotes.clear();
  }

  void _openPhotoViewer(String path) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('Фото визитки'),
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

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _deleteCreatedFiles() async {
    for (final path in _createdPhotos) {
      await sl<CardPhotoService>().deleteIfOwned(path);
    }
    for (final path in _createdVoiceNotes) {
      await sl<VoiceNoteService>().deleteIfOwned(path);
    }
    _createdPhotos.clear();
    _createdVoiceNotes.clear();
  }

  Future<void> _discard() async {
    if (!_isDirty()) {
      // Даже без изменений могли остаться промежуточные файлы: например,
      // записали заметку и сразу удалили её.
      await _deleteCreatedFiles();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Не сохранять?'),
        content: const Text('Распознанные данные будут потеряны.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Продолжить правку'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Не сохранять'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      await _deleteCreatedFiles();
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// Выгрузить расширенную диагностику последнего распознавания
  /// (hOCR + вырезки полей) в app-specific external каталог.
  Future<void> _dumpDiagnostic() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final current = widget.draft.copyWith(
        fullName: _name.text,
        position: _position.text,
        company: _company.text,
        phone: _phone.text,
        email: _email.text,
        website: _website.text,
        address: _address.text,
        notes: _notes.text,
        otherText: _otherText.text,
        event: _event.text,
        tags: _parseTags(_tags.text),
      );
      final dir = await sl<DiagnosticService>().dump(
        ocrResult: widget.ocrResult,
        processedImagePath: widget.processedImagePath,
        variantPaths: widget.variantPaths,
        card: current,
        diagnostic: widget.diagnostic,
        autoWarped: widget.autoWarped,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Диагностика сохранена: ${dir.path}')),
      );
    } on AppException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.userMessage ?? 'Не удалось выгрузить')),
      );
    }
  }

  bool _isDirty() {
    final d = widget.draft;
    return _name.text != d.fullName ||
        _position.text != d.position ||
        _company.text != d.company ||
        _phone.text != (d.phoneRaw.isNotEmpty ? d.phoneRaw : d.phone) ||
        _email.text != d.email ||
        _website.text != d.website ||
        _address.text != d.address ||
        _notes.text != d.notes ||
        _otherText.text != d.otherText ||
        _event.text != d.event ||
        _telegram.text != d.telegram ||
        !listEquals(_parseTags(_tags.text), d.tags) ||
        !_samePhones(
          [for (final c in _extraPhones) c.text.trim()],
          d.extraPhones,
        ) ||
        _cubit.state.card.cardImagePath != d.cardImagePath ||
        _cubit.state.card.ownerImagePath != d.ownerImagePath ||
        _cubit.state.card.voiceNotePath != d.voiceNotePath ||
        _cubit.state.card.voiceNoteDurationMs != d.voiceNoteDurationMs ||
        _cubit.state.card.verified != d.verified;
  }

  Widget _label(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF5A6472),
        ),
      );

  Widget _photoPlaceholder(String text, {double height = 120}) => Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF1F3F6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: const TextStyle(color: Colors.black45)),
      );

  Widget _cardPhotoSection(
    BusinessCard card, {
    double photoHeight = 180,
  }) {
    final source = card.cardImagePath ?? card.photoPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (source != null)
          GestureDetector(
            onTap: () => _openPhotoViewer(source),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(source),
                height: photoHeight,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _photoPlaceholder('Фото не найдено'),
              ),
            ),
          )
        else
          _photoPlaceholder('Фото отсутствует', height: photoHeight),
        Wrap(
          spacing: 4,
          children: [
            if (source != null)
              TextButton.icon(
                onPressed: _cropCardPhoto,
                icon: const Icon(Icons.crop, size: 18),
                label: const Text('Обрезать'),
              ),
            TextButton.icon(
              onPressed: _pickCardPhoto,
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: Text(source == null ? 'Добавить фото' : 'Заменить'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _ownerPhotoSection(BusinessCard card) {
    final owner = card.ownerImagePath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('Фото владельца'),
        const SizedBox(height: 6),
        Row(
          children: [
            if (owner != null)
              GestureDetector(
                onTap: () => _openPhotoViewer(owner),
                child: ClipOval(
                  child: Image.file(
                    File(owner),
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 72,
                      height: 72,
                      color: const Color(0xFFF1F3F6),
                      child: const Icon(Icons.person_outline,
                          color: Colors.black26),
                    ),
                  ),
                ),
              )
            else
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F3F6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.person_outline,
                    size: 34, color: Colors.black26),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                owner == null
                    ? 'Фото владельца не прикреплено'
                    : 'Нажмите на фото, чтобы увеличить',
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
            ),
            TextButton(
              onPressed: _pickOwnerPhoto,
              child: Text(owner == null ? 'Прикрепить' : 'Заменить'),
            ),
            if (owner != null)
              IconButton(
                tooltip: 'Удалить фото',
                onPressed: _removeOwnerPhoto,
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
        if (owner != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _cropOwnerPhoto,
              icon: const Icon(Icons.crop, size: 18),
              label: const Text('Кадрировать по кругу'),
            ),
          ),
      ],
    );
  }

  Widget _voiceNoteControls(BusinessCard card) {
    final hasVoice = card.voiceNotePath != null;
    final duration = _formatDuration(card.voiceNoteDurationMs);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8FB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFD7DEE8)),
      ),
      child: Row(
        children: [
          Icon(
            hasVoice ? Icons.graphic_eq : Icons.mic_none,
            size: 18,
            color: hasVoice
                ? Theme.of(context).colorScheme.primary
                : Colors.black45,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasVoice
                  ? 'Голосовая заметка${duration.isEmpty ? '' : ' · $duration'}'
                  : 'Голосовая заметка не записана',
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ),
          if (hasVoice)
            IconButton(
              tooltip: _playingVoice
                  ? 'Остановить воспроизведение'
                  : 'Прослушать голосовую заметку',
              onPressed: _voiceBusy ? null : _toggleVoicePlayback,
              icon: Icon(
                _playingVoice
                    ? Icons.stop_circle_outlined
                    : Icons.volume_up_outlined,
                size: 22,
              ),
            ),
          if (hasVoice)
            IconButton(
              tooltip: 'Удалить голосовую заметку',
              onPressed: _voiceBusy ? null : _removeVoiceNote,
              icon: const Icon(Icons.delete_outline, size: 22),
            ),
          IconButton(
            tooltip: hasVoice
                ? 'Перезаписать голосовую заметку'
                : 'Записать голосовую заметку',
            onPressed: _voiceBusy ? null : _recordVoiceNote,
            icon: _voiceBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.mic, size: 22),
          ),
        ],
      ),
    );
  }

  Widget _metaSection(BusinessCard card) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F8FB),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.event_available_outlined,
                  size: 18, color: Colors.black45),
              const SizedBox(width: 8),
              const Text('Создана', style: TextStyle(color: Colors.black54)),
              const Spacer(),
              Text(
                DateFormat('dd.MM.yyyy HH:mm').format(card.createdAt),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Проверена', style: TextStyle(fontSize: 15)),
          subtitle: const Text(
            'Отметить, что карточка проверена человеком',
            style: TextStyle(fontSize: 12),
          ),
          value: card.verified,
          onChanged: _cubit.setVerified,
        ),
      ],
    );
  }

  static bool _samePhones(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Теги вводятся через запятую или точку с запятой.
  static List<String> _parseTags(String raw) =>
      BusinessCard.normalizeTags(raw.split(RegExp(r'[,;]')));

  void _addExtraPhone() {
    setState(() => _extraPhones.add(TextEditingController()));
    _syncExtraPhones();
  }

  void _syncExtraPhones() {
    _cubit.setExtraPhones([
      for (final c in _extraPhones)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ]);
  }

  void _removeExtraPhone(int index) {
    setState(() {
      _extraPhones.removeAt(index).dispose();
    });
    _syncExtraPhones();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<EditCardCubit, EditCardState>(
      bloc: _cubit,
      listenWhen: (prev, curr) =>
          prev.saving != curr.saving ||
          prev.saved != curr.saved ||
          prev.error != curr.error,
      listener: (context, state) {
        if (state.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.error!)),
          );
        }
      },
      builder: (context, state) {
        return PopScope(
          // Подтверждение потери данных при «назад» — всегда через диалог,
          // т.к. canPop не пересчитывается при вводе текста.
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _discard();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.batchIndex != null
                  ? 'Визитка ${widget.batchIndex} из ${widget.batchTotal ?? widget.batchIndex}'
                  : widget.draft.id.isEmpty
                      ? 'Проверьте визитку'
                      : 'Редактирование'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Закрыть',
                onPressed: _discard,
              ),
              actions: [
                if (widget.diagnostic != null)
                  IconButton(
                    icon: const Icon(Icons.bug_report_outlined),
                    tooltip: 'Выгрузить диагностику OCR',
                    onPressed: _dumpDiagnostic,
                  ),
              ],
            ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                // На маленькой высоте (открыта клавиатура) фото временно
                // скрываем, чтобы форма не упиралась в край экрана.
                final showPhoto = constraints.maxHeight >= 240;
                final photoHeight =
                    (constraints.maxHeight * 0.28).clamp(100.0, 180.0);
                return Column(
                  children: [
                    // Фото визитки — отдельный закреплённый слой: поля под
                    // ним прокручиваются, а сам снимок остаётся на месте.
                    if (showPhoto) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: _cardPhotoSection(
                          state.card,
                          photoHeight: photoHeight,
                        ),
                      ),
                      const Divider(height: 1),
                    ],
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                        children: [
                          if (widget.emptyOcr)
                            const _Banner(
                              icon: Icons.edit_note,
                              text:
                                  'Текст не распознан — заполните карточку вручную',
                              color: Color(0xFF1565C0),
                            ),
                          for (final w in state.warnings
                              .where((w) => w.trim().isNotEmpty))
                            _Banner(icon: Icons.warning_amber_rounded, text: w),
                          const SizedBox(height: 8),
                          _metaSection(state.card),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Имя и фамилия',
                            controller: _name,
                            autofocus: widget.emptyOcr,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.fullName, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Должность',
                            controller: _position,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.position, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Компания',
                            controller: _company,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.company, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Телефон',
                            controller: _phone,
                            keyboardType: TextInputType.phone,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.phone, v),
                          ),
                          for (var i = 0; i < _extraPhones.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Expanded(
                                    child: EditableField(
                                      label: 'Телефон ${i + 2}',
                                      controller: _extraPhones[i],
                                      keyboardType: TextInputType.phone,
                                      ocrText: _ocrText,
                                      onChanged: (_) => _syncExtraPhones(),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Удалить номер',
                                    onPressed: () => _removeExtraPhone(i),
                                    icon: const Icon(
                                        Icons.remove_circle_outline,
                                        color: Colors.black45),
                                  ),
                                ],
                              ),
                            ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _addExtraPhone,
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Добавить телефон'),
                            ),
                          ),
                          const SizedBox(height: 6),
                          EditableField(
                            label: 'Email',
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.email, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Telegram',
                            controller: _telegram,
                            hint: '@username или t.me/username',
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.telegram, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Сайт',
                            controller: _website,
                            keyboardType: TextInputType.url,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.website, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Адрес',
                            controller: _address,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.address, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Заметки',
                            controller: _notes,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.notes, v),
                          ),
                          const SizedBox(height: 6),
                          _voiceNoteControls(state.card),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Прочий текст с визитки',
                            controller: _otherText,
                            maxLines: null,
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.otherText, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Мероприятие',
                            controller: _event,
                            hint: 'Например: конференция, выставка…',
                            ocrText: _ocrText,
                            onChanged: (v) =>
                                _cubit.updateField(CardField.event, v),
                          ),
                          const SizedBox(height: 14),
                          EditableField(
                            label: 'Теги',
                            controller: _tags,
                            hint: 'Через запятую: клиент, партнёр, выставка',
                            ocrText: _ocrText,
                            onChanged: (v) => _cubit.setTags(_parseTags(v)),
                          ),
                          const SizedBox(height: 24),
                          const Divider(height: 1),
                          const SizedBox(height: 18),
                          _ownerPhotoSection(state.card),
                          if (widget.diagnostic != null) ...[
                            const SizedBox(height: 20),
                            OcrDiagnosticPanel(diagnostic: widget.diagnostic!),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            bottomNavigationBar: SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: state.canSave && !state.saving ? _save : null,
                icon: state.saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(state.saving
                    ? 'Сохранение…'
                    : widget.batchIndex != null &&
                            widget.batchTotal != null &&
                            widget.batchIndex! < widget.batchTotal!
                        ? 'Сохранить и далее'
                        : 'Сохранить'),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFFF9A825);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
