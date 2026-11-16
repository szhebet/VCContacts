import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Дисковое хранилище очереди распознавания/проверки.
///
/// Очередь сама по себе живёт в памяти (`ScanQueueCubit`), но каждый job
/// сохраняется в JSON, чтобы пережить swipe-away, force-stop и перезапуск
/// приложения. Исходные фото копируются в `scan_queue/sources/`, иначе
/// временные файлы image_picker/камеры могли бы исчезнуть.
class ScanQueueStore {
  ScanQueueStore({Future<Directory> Function()? rootProvider})
      : _rootProvider = rootProvider ?? _defaultRoot;

  final Future<Directory> Function() _rootProvider;

  static const String _jobsFile = 'jobs.json';
  static const String _sourcesDir = 'sources';

  static Future<Directory> _defaultRoot() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'scan_queue'));
  }

  Future<Directory> _root() async {
    final dir = await _rootProvider();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _jobsPath() async =>
      File(p.join((await _root()).path, _jobsFile));

  /// Читает сохранённые job-ы. Битый/отсутствующий файл — пустая очередь.
  Future<List<Map<String, Object?>>> readJobs() async {
    try {
      final file = await _jobsPath();
      if (!await file.exists()) return const [];
      final text = await file.readAsString();
      if (text.trim().isEmpty) return const [];
      final raw = jsonDecode(text);
      if (raw is! List) return const [];
      return [
        for (final item in raw)
          if (item is Map) item.cast<String, Object?>(),
      ];
    } on Object catch (e) {
      debugPrint('[QUEUE] не удалось прочитать очередь: $e');
      return const [];
    }
  }

  /// Атомарно перезаписывает файл очереди (tmp + rename).
  Future<void> writeJobs(List<Map<String, Object?>> jobs) async {
    final file = await _jobsPath();
    final tmp = File('${file.path}.tmp');
    final text = jsonEncode(jobs);
    await tmp.writeAsString(text, flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // На некоторых ФС rename может не сработать — пишем напрямую.
      await file.writeAsString(text, flush: true);
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// Копирует исходное фото в постоянный каталог очереди и возвращает путь.
  /// Если скопировать не удалось, возвращает исходный путь (best-effort).
  Future<String> copySource(String jobId, String sourcePath) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) return sourcePath;
      final root = await _root();
      final dir = Directory(p.join(root.path, _sourcesDir));
      if (!await dir.exists()) await dir.create(recursive: true);
      if (p.isWithin(dir.path, sourcePath)) return sourcePath;
      final ext = p.extension(sourcePath);
      final target = p.join(dir.path, '$jobId$ext');
      await source.copy(target);
      return target;
    } on Object catch (e) {
      debugPrint('[QUEUE] не удалось сохранить исходное фото: $e');
      return sourcePath;
    }
  }

  Future<void> deleteSource(String? path) async {
    if (path == null || path.trim().isEmpty) return;
    try {
      final root = await _root();
      final dir = p.join(root.path, _sourcesDir);
      if (!p.isWithin(dir, path)) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // Файла уже нет — не критично.
    }
  }

  /// Полностью очищает файл очереди и сохранённые исходники.
  Future<void> clear() async {
    final root = await _root();
    final file = File(p.join(root.path, _jobsFile));
    if (await file.exists()) await file.delete();
    final tmp = File('${file.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
    final dir = Directory(p.join(root.path, _sourcesDir));
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
