import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../business/scan/scan_queue_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../core/errors/app_exceptions.dart';
import '../../../data/services/image_preprocessor.dart';
import '../../../data/services/voice_note_service.dart';
import '../../../data/services/voice_note_transcriber.dart';
import '../../widgets/voice_recorder_sheet.dart';

/// Результат экрана кадрирования: рамка в координатах повёрнутого кадра
/// и угол ручного поворота (по часовой стрелке).
class CropSelection {
  const CropSelection({
    required this.crop,
    this.rotationDegrees = 0,
  });

  final CropRegion crop;
  final double rotationDegrees;
}

/// Интерактивная обрезка по границам визитки.
/// Пользователь тянет углы рамки; результат — [CropSelection]
/// в относительных координатах (переживает любое разрешение).
class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.sourcePath,
    this.cropOnly = false,
    this.circle = false,
  });

  final String sourcePath;

  /// true — экран только обрезает фото и возвращает [CropSelection]
  /// (используется на форме редактирования карточки).
  final bool cropOnly;

  /// Круглый шаблон для фото владельца: рамка остаётся квадратной,
  /// а видимая область ограничивается вписанной окружностью.
  final bool circle;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  /// Прямоугольник кропа в нормализованных координатах [0..1]
  /// относительно повёрнутого кадра.
  double _left = 0.04;
  double _top = 0.04;
  double _right = 0.96;
  double _bottom = 0.96;

  /// Ручной поворот перед кадрированием, градусы по часовой стрелке.
  double _rotation = 0;

  /// Голосовая заметка, записанная до постановки фото в очередь.
  /// Прикрепится к этой же карточке при нажатии «Сканировать».
  VoiceRecording? _pendingVoice;

  bool _submitting = false;

  Size? _imageSize;
  bool _loadError = false;

  static const double _handleTouch = 44; // зона захвата угла (px)
  static const double _minSize = 0.15; // минимальный размер рамки

  @override
  void initState() {
    super.initState();
    _resolveImageSize();
  }

  @override
  void dispose() {
    final pending = _pendingVoice;
    if (pending != null) {
      unawaited(sl<VoiceNoteService>().deleteTemp(pending.path));
    }
    super.dispose();
  }

  Future<void> _resolveImageSize() async {
    final stream = Image.file(File(widget.sourcePath))
        .image
        .resolve(const ImageConfiguration());
    final listener = ImageStreamListener((info, _) {
      if (mounted) {
        setState(() {
          _imageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
          _setDefaultCrop();
        });
      }
    }, onError: (e, _) {
      if (mounted) setState(() => _loadError = true);
    });
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.cropOnly ? 'Обрезка фото' : 'Обрезка визитки'),
      ),
      body: _loadError
          ? const _LoadError()
          : _imageSize == null
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                )
              : Column(
                  children: [
                    Expanded(child: _buildCropArea()),
                    _buildControls(),
                  ],
                ),
    );
  }

  /// Габариты кадра после поворота на [_rotation] (как у copyRotate).
  Size _rotatedSize(Size source) {
    final rad = _rotation * math.pi / 180;
    final ca = math.cos(rad).abs();
    final sa = math.sin(rad).abs();
    return Size(
      source.width * ca + source.height * sa,
      source.width * sa + source.height * ca,
    );
  }

  /// Доля исходного кадра, которая при повороте на [degrees] гарантированно
  /// остаётся внутри холста (вписанный прямоугольник с исходными
  /// пропорциями). Нужна, чтобы рамка по умолчанию не захватывала белые
  /// углы, появившиеся после поворота.
  double _inscribedScale(Size source, double degrees) {
    final a = degrees.abs() % 90;
    if (a < 0.01) return 1.0;
    final rad = a * math.pi / 180;
    final ca = math.cos(rad).abs();
    final sa = math.sin(rad).abs();
    final k1 = source.width / (source.width * ca + source.height * sa);
    final k2 = source.height / (source.width * sa + source.height * ca);
    return math.min(k1, k2);
  }

  void _changeRotation(double value) {
    setState(() {
      _rotation = value;
      _setDefaultCrop();
    });
  }

  /// Рамка по умолчанию: для круга — квадрат с запасом, для обычной
  /// обрезки — вписанный прямоугольник без белых углов после поворота.
  void _setDefaultCrop() {
    final size = _imageSize;
    if (size == null) return;
    final rotated = _rotatedSize(size);
    if (widget.circle) {
      final side = math.min(rotated.width, rotated.height) * 0.82;
      final nw = side / rotated.width;
      final nh = side / rotated.height;
      _left = 0.5 - nw / 2;
      _right = 0.5 + nw / 2;
      _top = 0.5 - nh / 2;
      _bottom = 0.5 + nh / 2;
      return;
    }
    if (_rotation == 0) {
      _left = 0.04;
      _top = 0.04;
      _right = 0.96;
      _bottom = 0.96;
      return;
    }
    final k = (_inscribedScale(size, _rotation) * 0.98).clamp(0.0, 1.0);
    final nw = k * size.width / rotated.width;
    final nh = k * size.height / rotated.height;
    _left = (0.5 - nw / 2).clamp(0.0, 1.0);
    _right = (0.5 + nw / 2).clamp(0.0, 1.0);
    _top = (0.5 - nh / 2).clamp(0.0, 1.0);
    _bottom = (0.5 + nh / 2).clamp(0.0, 1.0);
  }

  /// Область изображения с рамкой: вычисляем fit-прямоугольник картинки.
  Widget _buildCropArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final imgSize = _imageSize!;
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final rotated = _rotatedSize(imgSize);
        // contain: вся повёрнутая картинка видна
        final scale = math.min(
          box.width / rotated.width,
          box.height / rotated.height,
        );
        final display = Size(rotated.width * scale, rotated.height * scale);
        final imageDisplay = Size(
          imgSize.width * scale,
          imgSize.height * scale,
        );
        final origin = Offset(
          (box.width - display.width) / 2,
          (box.height - display.height) / 2,
        );

        final rect = Rect.fromLTWH(
          origin.dx + _left * display.width,
          origin.dy + _top * display.height,
          (_right - _left) * display.width,
          (_bottom - _top) * display.height,
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) =>
              _onPanStart(d.localPosition, rect, display, origin),
          onPanUpdate: (d) =>
              _onPanUpdate(d.localPosition, rect, display, origin),
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: Rect.fromLTWH(
                  origin.dx,
                  origin.dy,
                  display.width,
                  display.height,
                ),
                child: ClipRect(
                  child: Container(
                    color: Colors.white,
                    child: Center(
                      child: Transform.rotate(
                        angle: _rotation * math.pi / 180,
                        child: SizedBox(
                          width: imageDisplay.width,
                          height: imageDisplay.height,
                          child: Image.file(
                            File(widget.sourcePath),
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Затемнение вне рамки / круга
              if (widget.circle)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _CircleMaskPainter(circle: _circleRect(rect)),
                    ),
                  ),
                )
              else ...[
                ..._buildDimming(rect, box),
                // Рамка
                Positioned.fromRect(
                  rect: rect,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
              // Угловые маркеры
              ..._buildHandles(rect),
            ],
          ),
        );
      },
    );
  }

  Rect _circleRect(Rect r) {
    final side = math.min(r.width, r.height);
    return Rect.fromCenter(center: r.center, width: side, height: side);
  }

  List<Widget> _buildDimming(Rect crop, Size box) {
    Widget dim(Rect r) => Positioned.fromRect(
          rect: r,
          child: Container(color: Colors.black.withOpacity(0.55)),
        );
    return [
      dim(Rect.fromLTWH(0, 0, box.width, crop.top)),
      dim(Rect.fromLTWH(0, crop.bottom, box.width, box.height - crop.bottom)),
      dim(Rect.fromLTWH(0, crop.top, crop.left, crop.height)),
      dim(Rect.fromLTWH(
          crop.right, crop.top, box.width - crop.right, crop.height)),
    ];
  }

  List<Widget> _buildHandles(Rect r) {
    Widget handle(Alignment align) => Align(
          alignment: align,
          child: Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 4)],
            ),
          ),
        );
    return [
      Positioned.fromRect(
          rect: r,
          child: Stack(children: [
            handle(Alignment.topLeft),
            handle(Alignment.topRight),
            handle(Alignment.bottomLeft),
            handle(Alignment.bottomRight),
          ])),
    ];
  }

  // ------------------------------------------------------------- жесты

  _Handle? _activeHandle;
  bool _moving = false;
  Offset? _dragStart;

  void _onPanStart(Offset pos, Rect crop, Size display, Offset origin) {
    _dragStart = pos;
    // Какой угол ближе всего к касанию?
    final handles = <_Handle, Offset>{
      _Handle.tl: crop.topLeft,
      _Handle.tr: crop.topRight,
      _Handle.bl: crop.bottomLeft,
      _Handle.br: crop.bottomRight,
    };
    _Handle? nearest;
    var best = _handleTouch;
    handles.forEach((handle, point) {
      final d = (point - pos).distance;
      if (d < best) {
        best = d;
        nearest = handle;
      }
    });
    _activeHandle = nearest;
    _moving = nearest == null && crop.inflate(8).contains(pos);
  }

  void _onPanUpdate(Offset pos, Rect crop, Size display, Offset origin) {
    final start = _dragStart;
    if (start == null) return;

    // Пересчёт в нормализованные координаты (позиция внутри display).
    final local = pos - origin;
    final nx = (local.dx / display.width).clamp(0.0, 1.0);
    final ny = (local.dy / display.height).clamp(0.0, 1.0);

    final handle = _activeHandle;
    if (handle != null) {
      if (widget.circle) {
        _resizeCircle(pos, display, origin, handle);
        return;
      }
      setState(() {
        switch (handle) {
          case _Handle.tl:
            _left = math.min(nx, _right - _minSize);
            _top = math.min(ny, _bottom - _minSize);
          case _Handle.tr:
            _right = math.max(nx, _left + _minSize);
            _top = math.min(ny, _bottom - _minSize);
          case _Handle.bl:
            _left = math.min(nx, _right - _minSize);
            _bottom = math.max(ny, _top + _minSize);
          case _Handle.br:
            _right = math.max(nx, _left + _minSize);
            _bottom = math.max(ny, _top + _minSize);
        }
        _left = _left.clamp(0.0, 1.0);
        _top = _top.clamp(0.0, 1.0);
        _right = _right.clamp(0.0, 1.0);
        _bottom = _bottom.clamp(0.0, 1.0);
      });
      return;
    }

    if (_moving) {
      // Сдвиг всей рамки: delta в нормализованных единицах.
      final prevLocal = start - origin;
      final dx = (local.dx - prevLocal.dx) / display.width;
      final dy = (local.dy - prevLocal.dy) / display.height;
      setState(() {
        final w = _right - _left;
        final h = _bottom - _top;
        var nl = (_left + dx).clamp(0.0, 1.0 - w);
        var nt = (_top + dy).clamp(0.0, 1.0 - h);
        _left = nl;
        _right = nl + w;
        _top = nt;
        _bottom = nt + h;
      });
      _dragStart = pos;
    }
  }

  void _resizeCircle(
    Offset pos,
    Size display,
    Offset origin,
    _Handle handle,
  ) {
    final local = pos - origin;
    // Неподвижный противоположный угол в координатах display.
    final anchorX = (handle == _Handle.tl || handle == _Handle.bl)
        ? _right * display.width
        : _left * display.width;
    final anchorY = (handle == _Handle.tl || handle == _Handle.tr)
        ? _bottom * display.height
        : _top * display.height;

    final maxSideX = (handle == _Handle.tl || handle == _Handle.bl)
        ? anchorX
        : display.width - anchorX;
    final maxSideY = (handle == _Handle.tl || handle == _Handle.tr)
        ? anchorY
        : display.height - anchorY;
    final maxSide = math.max(0.0, math.min(maxSideX, maxSideY));
    final minSide = math.min(display.width, display.height) * _minSize;
    if (maxSide < minSide) return;

    final side = math
        .max((local.dx - anchorX).abs(), (local.dy - anchorY).abs())
        .clamp(minSide, maxSide);

    double left = 0;
    double top = 0;
    switch (handle) {
      case _Handle.tl:
        left = anchorX - side;
        top = anchorY - side;
      case _Handle.tr:
        left = anchorX;
        top = anchorY - side;
      case _Handle.bl:
        left = anchorX - side;
        top = anchorY;
      case _Handle.br:
        left = anchorX;
        top = anchorY;
    }

    setState(() {
      _left = (left / display.width).clamp(0.0, 1.0);
      _right = ((left + side) / display.width).clamp(0.0, 1.0);
      _top = (top / display.height).clamp(0.0, 1.0);
      _bottom = ((top + side) / display.height).clamp(0.0, 1.0);
    });
  }

  Future<void> _recordPendingNote() async {
    final queue = sl<ScanQueueCubit>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await sl<VoiceNoteTranscriber>().isModelInstalled()) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Модель речи не установлена — текст не распознается. '
            'Скачайте её в меню «Модель распознавания речи».',
          ),
        ),
      );
    }
    final waitForOcr = queue.state.jobs
        .any((j) => j.status == ScanJobStatus.processing);
    final waiting = waitForOcr
        ? messenger.showSnackBar(
            const SnackBar(
              content: Text('Завершаем текущее распознавание…'),
              duration: Duration(seconds: 30),
            ),
          )
        : null;

    await queue.acquireRecording();
    waiting?.close();
    try {
      if (!mounted) return;
      final recording = await showModalBottomSheet<VoiceRecording>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const VoiceRecorderSheet(cardId: 'scan'),
      );
      if (recording == null) return;
      final old = _pendingVoice;
      setState(() => _pendingVoice = recording);
      if (old != null) {
        await sl<VoiceNoteService>().deleteTemp(old.path);
      }
    } on AppException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.userMessage ?? e.message)),
      );
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось записать заметку: $e')),
      );
    } finally {
      queue.releaseRecording();
    }
  }

  Widget _buildControls() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.rotate_right,
                    size: 20, color: Colors.white70),
                Expanded(
                  child: Slider(
                    value: _rotation,
                    min: -180,
                    max: 180,
                    divisions: 720,
                    label: '${_rotation.round()}°',
                    activeColor: Colors.white,
                    inactiveColor: Colors.white24,
                    onChanged: _changeRotation,
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Text(
                    '${_rotation.round()}°',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Colors.white70,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Сбросить поворот',
                  onPressed: _rotation == 0
                      ? null
                      : () => _changeRotation(0),
                  icon: const Icon(Icons.restart_alt),
                  color: Colors.white70,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                      side: const BorderSide(color: Colors.white38),
                    ),
                    onPressed: () => _apply(const CropRegion()),
                    child: const Text('Без обрезки'),
                  ),
                ),
                if (!widget.cropOnly) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _pendingVoice == null
                            ? Colors.white
                            : Colors.lightGreenAccent,
                        minimumSize: const Size.fromHeight(52),
                        side: BorderSide(
                          color: _pendingVoice == null
                              ? Colors.white38
                              : Colors.lightGreenAccent,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      onPressed: _recordPendingNote,
                      child: Text(
                        _pendingVoice == null
                            ? 'Добавить\nзаметку'
                            : 'Заметка\nдобавлена',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: FilledButton(
                    onPressed: () => _apply(CropRegion(
                      left: _left,
                      top: _top,
                      right: _right,
                      bottom: _bottom,
                    )),
                    child: Text(widget.cropOnly ? 'Готово' : 'Сканировать'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// В режиме обрезки возвращаем рамку и поворот назад, иначе ставим фото
  /// в фоновую очередь распознавания и сразу возвращаемся к съёмке.
  Future<void> _apply(CropRegion crop) async {
    if (widget.cropOnly) {
      Navigator.of(context).pop(CropSelection(
        crop: crop,
        rotationDegrees: _rotation,
      ));
      return;
    }
    if (_submitting) return;
    _submitting = true;

    final messenger = ScaffoldMessenger.of(context);
    final queue = sl<ScanQueueCubit>();
    final pending = _pendingVoice;
    // Забираем заметку из состояния сразу: dispose не должен удалить файл,
    // пока идёт привязка к только что созданному job.
    _pendingVoice = null;
    final jobId = queue.enqueue(
      widget.sourcePath,
      crop: crop,
      rotationDegrees: _rotation,
    );

    String? noteError;
    if (pending != null) {
      if (jobId != null) {
        try {
          await queue.attachVoiceNote(jobId, pending);
        } on AppException catch (e) {
          noteError = e.userMessage ?? 'Не удалось прикрепить заметку';
        } on Object catch (e) {
          noteError = 'Не удалось прикрепить заметку: $e';
        }
      } else {
        await sl<VoiceNoteService>().deleteTemp(pending.path);
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          noteError ?? 'Фото добавлено в очередь распознавания',
        ),
      ),
    );
  }
}

enum _Handle { tl, tr, bl, br }

/// Затемняет всё вне круга и рисует его границу — шаблон для фото владельца.
class _CircleMaskPainter extends CustomPainter {
  const _CircleMaskPainter({required this.circle});

  final Rect circle;

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Path()..addRect(Offset.zero & size);
    final hole = Path()..addOval(circle);
    final outside = Path.combine(PathOperation.difference, screen, hole);
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withOpacity(0.55),
    );
    canvas.drawOval(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _CircleMaskPainter oldDelegate) =>
      oldDelegate.circle != circle;
}

class _LoadError extends StatelessWidget {
  const _LoadError();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Не удалось открыть фото',
        style: TextStyle(color: Colors.white70, fontSize: 16),
      ),
    );
  }
}
