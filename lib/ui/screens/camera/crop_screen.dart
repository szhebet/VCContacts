import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/services/image_preprocessor.dart';
import 'scan_flow_screen.dart';

/// Интерактивная обрезка по границам визитки.
/// Пользователь тянет углы рамки; результат — [CropRegion]
/// в относительных координатах (переживает любое разрешение).
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.sourcePath});

  final String sourcePath;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  /// Прямоугольник кропа в нормализованных координатах [0..1].
  double _left = 0.04;
  double _top = 0.04;
  double _right = 0.96;
  double _bottom = 0.96;

  Size? _imageSize;
  bool _loadError = false;

  static const double _handleTouch = 44; // зона захвата угла (px)
  static const double _minSize = 0.15; // минимальный размер рамки

  @override
  void initState() {
    super.initState();
    _resolveImageSize();
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
        title: const Text('Обрезка визитки'),
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

  /// Область изображения с рамкой: вычисляем fit-прямоугольник картинки.
  Widget _buildCropArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final imgSize = _imageSize!;
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        // contain: вся картинка видна
        final scale = math.min(
          box.width / imgSize.width,
          box.height / imgSize.height,
        );
        final display = Size(imgSize.width * scale, imgSize.height * scale);
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
          onPanStart: (d) => _onPanStart(d.localPosition, rect, display, origin),
          onPanUpdate: (d) => _onPanUpdate(d.localPosition, rect, display, origin),
          child: Stack(
            children: [
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: display.width,
                height: display.height,
                child: Image.file(
                  File(widget.sourcePath),
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              // Затемнение вне рамки (4 прямоугольника — просто и дёшево)
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
              // Угловые маркеры
              ..._buildHandles(rect),
            ],
          ),
        );
      },
    );
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
      dim(Rect.fromLTWH(crop.right, crop.top, box.width - crop.right, crop.height)),
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
      Positioned.fromRect(rect: r, child: Stack(children: [
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

  Widget _buildControls() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  side: const BorderSide(color: Colors.white38),
                ),
                onPressed: () => _startScan(
                  const CropRegion(), // без обрезки
                ),
                child: const Text('Без обрезки'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: () => _startScan(
                  CropRegion(
                    left: _left,
                    top: _top,
                    right: _right,
                    bottom: _bottom,
                  ),
                ),
                child: const Text('Сканировать'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _startScan(CropRegion crop) {
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute(
        builder: (_) => ScanFlowScreen(
          sourcePath: widget.sourcePath,
          crop: crop,
        ),
      ),
    );
  }
}

enum _Handle { tl, tr, bl, br }

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
