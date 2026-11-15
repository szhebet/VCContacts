import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/errors/app_exceptions.dart';

/// Готовая голосовая запись: временный файл и его длительность.
class VoiceRecording {
  const VoiceRecording({required this.path, required this.durationMs});

  final String path;
  final int durationMs;
}

/// Запись и воспроизведение голосовых заметок.
///
/// Звук пишется нативно (Android `MediaRecorder`, AAC в MP4) в каталог
/// данных приложения, поэтому заметка не теряется при очистке кэша и не
/// покидает устройство. Временная запись создаётся в кэше и переносится
/// в постоянное хранилище только по кнопке «Сохранить».
class VoiceNoteService {
  static const MethodChannel _channel = MethodChannel('vccontacts/voice_notes');

  /// На iOS нативная часть пока не реализована — UI показывает пояснение.
  bool get isSupported => Platform.isAndroid;

  Future<String> createTempRecordingPath() async {
    final dir = await _dir(temp: true);
    return p.join(
      dir.path,
      'note_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
  }

  Future<void> startRecording(String path) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('startRecording', {'path': path});
    } on PlatformException catch (e) {
      throw VoiceNoteException(
        'Не удалось начать запись: ${e.message}',
        userMessage: 'Не удалось начать запись',
        cause: e,
      );
    } on MissingPluginException catch (e) {
      throw VoiceNoteException(
        'Нативный модуль записи недоступен',
        userMessage: 'Запись голоса недоступна на этом устройстве',
        cause: e,
      );
    }
  }

  Future<VoiceRecording?> stopRecording() async {
    _ensureSupported();
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(
        'stopRecording',
      );
      if (map == null) return null;
      final path = map['path']?.toString();
      if (path == null || path.isEmpty) return null;
      final duration = (map['durationMs'] as num?)?.toInt() ?? 0;
      return VoiceRecording(path: path, durationMs: duration);
    } on PlatformException catch (e) {
      throw VoiceNoteException(
        'Не удалось завершить запись: ${e.message}',
        userMessage: 'Не удалось сохранить запись',
        cause: e,
      );
    } on MissingPluginException catch (e) {
      throw VoiceNoteException(
        'Нативный модуль записи недоступен',
        userMessage: 'Запись голоса недоступна на этом устройстве',
        cause: e,
      );
    }
  }

  /// Проигрывает файл и завершается по окончании записи или по [stopPlayback].
  Future<void> play(String path) async {
    _ensureSupported();
    if (path.trim().isEmpty) return;
    try {
      await _channel.invokeMethod<void>('play', {'path': path});
    } on PlatformException catch (e) {
      throw VoiceNoteException(
        'Не удалось воспроизвести заметку: ${e.message}',
        userMessage: 'Не удалось воспроизвести запись',
        cause: e,
      );
    } on MissingPluginException catch (e) {
      throw VoiceNoteException(
        'Нативный модуль воспроизведения недоступен',
        userMessage: 'Воспроизведение недоступно на этом устройстве',
        cause: e,
      );
    }
  }

  Future<void> stopPlayback() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopPlayback');
    } on PlatformException {
      // Остановка — best-effort: плеер мог уже завершиться.
    }
  }

  /// Переносит временную запись в Documents/voice_notes и возвращает путь.
  Future<String> persist(String tempPath) async {
    final source = File(tempPath);
    if (!await source.exists()) {
      throw const VoiceNoteException(
        'Временный файл записи не найден',
        userMessage: 'Запись не найдена — попробуйте ещё раз',
      );
    }
    final dir = await _dir(temp: false);
    final target = p.join(
      dir.path,
      'note_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    try {
      await source.rename(target);
    } on FileSystemException {
      // Разные тома (редко): копируем и удаляем исходник.
      await source.copy(target);
      await source.delete();
    }
    return target;
  }

  Future<void> deleteTemp(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final dir = await _dir(temp: true);
      if (!p.isWithin(dir.path, path)) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // Временного файла уже нет — не критично.
    }
  }

  /// Удаляет файл, только если он лежит в каталоге голосовых заметок
  /// приложения. Чужие/временные файлы не трогаем.
  Future<void> deleteIfOwned(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final dir = await _dir(temp: false);
      if (!p.isWithin(dir.path, path)) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // Файла нет / нет доступа — не критично.
    }
  }

  void _ensureSupported() {
    if (!isSupported) {
      throw const VoiceNoteException(
        'Голосовые заметки пока доступны только на Android',
        userMessage: 'Голосовые заметки пока доступны только на Android',
      );
    }
  }

  Future<Directory> _dir({required bool temp}) async {
    final base = temp
        ? await getTemporaryDirectory()
        : await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'voice_notes'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
