import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/errors/app_exceptions.dart';

/// Один раз скачиваемая или встроенная в APK модель whisper.cpp.
///
/// После установки распознавание полностью офлайн. Модель можно:
///  * скачать через меню приложения;
///  * положить в `assets/models/ggml-base.bin` и собрать APK — тогда она
///    уже внутри APK и переустановка не требует сети;
///  * скопировать вручную в app-specific external files.
class WhisperModelService {
  static const String modelFileName = 'ggml-base.bin';
  static const String bundledModelAsset = 'assets/models/ggml-base.bin';
  static const String modelUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';

  Future<Directory> modelDir() async {
    // App-specific external files: доступен и приложению, и пользователю
    // через USB/файловый менеджер (Android/data/<pkg>/files), поэтому
    // модель можно положить вручную, если автозагрузка недоступна.
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        await external.create(recursive: true);
        return external;
      }
    } on Object {
      // Нет внешнего каталога — используем приватный.
    }
    return getApplicationSupportDirectory();
  }

  Future<bool> isInstalled() async {
    try {
      final dir = await modelDir();
      final file = File(p.join(dir.path, modelFileName));
      return await file.exists() && await file.length() > 10 * 1024 * 1024;
    } on Object {
      return false;
    }
  }

  /// Есть ли модель в APK (assets/models/ggml-base.bin).
  Future<bool> hasBundledModel() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      return manifest.listAssets().contains(bundledModelAsset);
    } on Object {
      return false;
    }
  }

  Future<bool> hasModel() async => await isInstalled() || await hasBundledModel();

  /// Если модель встроена в APK, копирует её в рабочий каталог. Это позволяет
  /// переустанавливать APK без повторной загрузки из интернета.
  Future<bool> ensureInstalled() async {
    if (await isInstalled()) return true;
    if (!await hasBundledModel()) return false;

    final dir = await modelDir();
    final target = File(p.join(dir.path, modelFileName));
    final part = File('${target.path}.part');
    try {
      final data = await rootBundle.load(bundledModelAsset);
      if (data.lengthInBytes < 10 * 1024 * 1024) return false;
      await part.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await part.rename(target.path);
      return true;
    } on Object {
      try {
        if (await part.exists()) await part.delete();
      } on Object {
        // Частичный файл удалится при следующей попытке.
      }
      return false;
    }
  }

  /// Скачивает модель с прогрессом. При ошибке частичный файл удаляется.
  Future<void> download({
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await modelDir();
    final target = File(p.join(dir.path, modelFileName));
    final part = File('${target.path}.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(Uri.parse(modelUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'VCContacts/1.0');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw VoiceNoteException(
          'HTTP ${response.statusCode} при загрузке модели',
          userMessage: 'Сервер модели недоступен (${response.statusCode})',
        );
      }
      final total = response.contentLength;
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (total > 0 && received < total) {
        throw const VoiceNoteException(
          'Загрузка модели оборвалась',
          userMessage: 'Модель скачалась не полностью — попробуйте ещё раз',
        );
      }
      if (await part.length() < 10 * 1024 * 1024) {
        throw const VoiceNoteException(
          'Файл модели слишком мал',
          userMessage: 'Скачался повреждённый файл модели',
        );
      }
      await part.rename(target.path);
    } on VoiceNoteException {
      if (await part.exists()) await part.delete();
      rethrow;
    } on Object catch (e) {
      if (await part.exists()) await part.delete();
      throw VoiceNoteException(
        'Не удалось скачать модель распознавания: $e',
        userMessage: 'Не удалось скачать модель распознавания речи',
        cause: e,
      );
    } finally {
      client.close(force: true);
    }
  }
}
