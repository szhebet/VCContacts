import 'dart:io';

import 'package:whisper_flutter_new/whisper_flutter_new.dart';

import '../../core/errors/app_exceptions.dart';
import 'whisper_model_service.dart';

/// Офлайн-распознавание голосовых заметок через whisper.cpp.
///
/// Аудио должно быть WAV 16 кГц моно (так его пишет диктофон). Модель
/// `ggml-base.bin` скачивается один раз через [WhisperModelService],
/// после чего распознавание идёт полностью на устройстве.
class VoiceNoteTranscriber {
  VoiceNoteTranscriber({WhisperModelService? models})
      : _models = models ?? WhisperModelService();

  final WhisperModelService _models;

  Future<bool> isModelInstalled() => _models.hasModel();

  Future<String?> transcribe(String audioPath) async {
    // Старые заметки в M4A пока не декодируем: диктофон теперь пишет WAV.
    if (!audioPath.toLowerCase().endsWith('.wav')) return null;
    if (!await _models.ensureInstalled()) {
      throw const VoiceNoteException(
        'Модель whisper.cpp не установлена',
        userMessage: 'Модель распознавания речи не установлена. '
            'Скачайте её в меню приложения.',
      );
    }

    final dir = await _models.modelDir();
    final whisper = Whisper(
      model: WhisperModel.base,
      modelDir: dir.path,
      // Не разрешаем пакету скачивать модель сам: сеть — только через
      // явную кнопку в меню (WhisperModelService).
      downloadHost: 'http://127.0.0.1:1',
    );
    final result = await whisper.transcribe(
      transcribeRequest: TranscribeRequest(
        audio: audioPath,
        language: 'ru',
        threads: (Platform.numberOfProcessors ~/ 2).clamp(2, 8),
        isTranslate: false,
        isNoTimestamps: true,
        isVerbose: false,
        splitOnWord: false,
        speedUp: true,
      ),
    );
    final text = result.text.trim();
    return text.isEmpty ? null : text;
  }
}
