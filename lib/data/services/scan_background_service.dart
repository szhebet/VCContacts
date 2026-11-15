import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Держит приложение живым в фоне, пока идёт очередь распознавания.
///
/// Dart-очередь выполняется в основном Flutter-изоляте; нативный
/// foreground-service не даёт Android усыпить/убить процесс, а
/// PARTIAL_WAKE_LOCK — выключить CPU при погашенном экране.
class ScanBackgroundService {
  static const MethodChannel _channel = MethodChannel('vccontacts/scan_service');

  bool get _supported => Platform.isAndroid;

  Future<void> start(String text) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
    } on Object catch (e) {
      debugPrint('[SCAN] foreground service start failed: $e');
    }
  }

  Future<void> update(String text) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('update', {'text': text});
    } on Object catch (e) {
      debugPrint('[SCAN] foreground service update failed: $e');
    }
  }

  Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object catch (e) {
      debugPrint('[SCAN] foreground service stop failed: $e');
    }
  }

  /// Показывает обычное (не foreground) уведомление о завершении очереди.
  Future<void> complete(String text) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('complete', {'text': text});
    } on Object catch (e) {
      debugPrint('[SCAN] completion notification failed: $e');
    }
  }
}
