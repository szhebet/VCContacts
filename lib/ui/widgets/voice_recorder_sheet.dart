import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/di/injector.dart';
import '../../core/errors/app_exceptions.dart';
import '../../data/services/voice_note_service.dart';

/// Виджет диктофона для голосовой заметки.
///
/// Возвращает [VoiceRecording] с временным файлом; вызывающий экран
/// переносит его в постоянное хранилище и сохраняет путь в БД. При отмене
/// или закрытии шторки временный файл удаляется.
class VoiceRecorderSheet extends StatefulWidget {
  const VoiceRecorderSheet({super.key, required this.cardId});

  final String cardId;

  @override
  State<VoiceRecorderSheet> createState() => _VoiceRecorderSheetState();
}

enum _RecState { idle, recording, recorded }

class _VoiceRecorderSheetState extends State<VoiceRecorderSheet> {
  final _service = sl<VoiceNoteService>();
  final _watch = Stopwatch();

  _RecState _state = _RecState.idle;
  Timer? _timer;
  String? _path;
  int _durationMs = 0;
  String? _error;
  bool _busy = false;
  bool _previewing = false;
  bool _permanentlyDenied = false;

  /// true — файл передан наружу, удалять его при dispose нельзя.
  bool _saved = false;

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_cleanup());
    super.dispose();
  }

  Future<void> _cleanup() async {
    try {
      if (_state == _RecState.recording) {
        await _service.stopRecording();
      }
      await _service.stopPlayback();
      if (!_saved) await _service.deleteTemp(_path);
    } on Object {
      // Уборка временного файла не должна влиять на закрытие экрана.
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    if (!_service.isSupported) {
      setState(() => _error = 'Голосовые заметки пока доступны только на Android');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? path;
    try {
      final status = await Permission.microphone.request();
      _permanentlyDenied = status.isPermanentlyDenied;
      if (!status.isGranted) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = _permanentlyDenied
              ? 'Микрофон запрещён. Разрешите доступ в настройках приложения'
              : 'Нет доступа к микрофону';
        });
        return;
      }

      path = await _service.createTempRecordingPath();
      await _service.startRecording(path);
      if (!mounted) {
        await _service.stopRecording();
        await _service.deleteTemp(path);
        return;
      }
      _path = path;
      _durationMs = 0;
      _watch
        ..reset()
        ..start();
      _timer?.cancel();
      _timer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) {
          if (mounted) setState(() {});
        },
      );
      setState(() {
        _state = _RecState.recording;
        _busy = false;
      });
    } on AppException catch (e) {
      await _service.deleteTemp(path);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.userMessage ?? e.message;
      });
    } on Exception catch (e) {
      await _service.deleteTemp(path);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось начать запись: $e';
      });
    }
  }

  Future<void> _stop() async {
    if (_busy) return;
    setState(() => _busy = true);
    _timer?.cancel();
    _watch.stop();
    try {
      final rec = await _service.stopRecording();
      if (!mounted) {
        await _service.deleteTemp(rec?.path ?? _path);
        return;
      }
      if (rec == null || rec.durationMs < 300) {
        await _service.deleteTemp(rec?.path ?? _path);
        setState(() {
          _busy = false;
          _state = _RecState.idle;
          _path = null;
          _durationMs = 0;
          _error = 'Слишком короткая запись — попробуйте ещё раз';
        });
        return;
      }
      setState(() {
        _busy = false;
        _state = _RecState.recorded;
        _path = rec.path;
        _durationMs = rec.durationMs;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _state = _RecState.idle;
        _error = e.userMessage ?? e.message;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _state = _RecState.idle;
        _error = 'Не удалось остановить запись: $e';
      });
    }
  }

  Future<void> _reset() async {
    _timer?.cancel();
    _watch.stop();
    if (_previewing) {
      await _service.stopPlayback();
      _previewing = false;
    }
    await _service.deleteTemp(_path);
    if (!mounted) return;
    setState(() {
      _state = _RecState.idle;
      _path = null;
      _durationMs = 0;
      _error = null;
    });
  }

  Future<void> _preview() async {
    final path = _path;
    if (path == null) return;
    if (_previewing) {
      await _service.stopPlayback();
      if (mounted) setState(() => _previewing = false);
      return;
    }
    setState(() => _previewing = true);
    try {
      await _service.play(path);
    } on AppException catch (e) {
      if (mounted) {
        setState(() => _error = e.userMessage ?? e.message);
      }
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  void _save() {
    final path = _path;
    if (path == null) return;
    _saved = true;
    Navigator.of(context).pop(
      VoiceRecording(path: path, durationMs: _durationMs),
    );
  }

  String get _timerText {
    final ms = _state == _RecState.recording
        ? _watch.elapsedMilliseconds
        : _durationMs;
    final totalSeconds = ms ~/ 1000;
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = _state == _RecState.recording;
    final recorded = _state == _RecState.recorded;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.mic_none, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Голосовая заметка',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _timerText,
              style: const TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.w300,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              recording
                  ? 'Идёт запись…'
                  : recorded
                      ? 'Запись готова'
                      : 'Нажмите микрофон, чтобы начать',
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            if (recording)
              _RoundButton(
                color: Colors.red,
                icon: Icons.stop,
                busy: _busy,
                onTap: _stop,
              )
            else if (recorded)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filledTonal(
                    tooltip: _previewing ? 'Остановить' : 'Прослушать',
                    onPressed: _preview,
                    icon: Icon(
                      _previewing ? Icons.stop : Icons.play_arrow,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Прослушать перед сохранением',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.black.withOpacity(0.55),
                    ),
                  ),
                ],
              )
            else
              _RoundButton(
                color: theme.colorScheme.primary,
                icon: Icons.mic,
                busy: _busy,
                onTap: _start,
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.red),
              ),
              if (_permanentlyDenied)
                const TextButton(
                  onPressed: openAppSettings,
                  child: Text('Открыть настройки'),
                ),
            ],
            const SizedBox(height: 16),
            if (recorded)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _reset,
                      child: const Text('Перезаписать'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _save,
                      child: const Text('Сохранить'),
                    ),
                  ),
                ],
              )
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : (recording ? _stop : _start),
                  icon: Icon(recording ? Icons.stop : Icons.mic),
                  label: Text(recording ? 'Остановить' : 'Начать запись'),
                ),
              ),
            const SizedBox(height: 4),
            if (recorded)
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Отмена'),
              ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.color,
    required this.icon,
    required this.busy,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy ? null : onTap,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 40),
          ),
        ),
      ),
    );
  }
}
