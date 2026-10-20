import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/errors/app_exceptions.dart';
import 'crop_screen.dart';

/// Экран камеры: превью, автофокус (встроен в камеру), вспышка,
/// съёмка, переключение камеры, быстрый доступ к галерее.
/// Все кадры остаются на устройстве: ни одного сетевого вызова.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  FlashMode _flashMode = FlashMode.off;
  bool _initializing = true;
  AppException? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null) return;
    // Камеру обязательно отпускаем в фоне: иначе экран захвата
    // останется заблокирован другим приложением.
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _init();
    }
  }

  Future<void> _init() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      // 1. Разрешение камеры.
      var status = await Permission.camera.status;
      if (!status.isGranted) {
        status = await Permission.camera.request();
      }
      if (status.isPermanentlyDenied) {
        throw const PermissionException(
          'Камера запрещена навсегда',
          userMessage: 'Доступ к камере заблокирован. Разрешите '
              'в настройках приложения',
          permanentlyDenied: true,
        );
      }
      if (!status.isGranted) {
        throw const PermissionException(
          'Камера отклонена',
          userMessage: 'Без камеры сканировать не получится. '
              'Можно выбрать фото из галереи',
        );
      }

      // 2. Доступные камеры (обычно основная + фронтальная).
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        throw const CameraFailure(
          'Нет доступных камер',
          userMessage: 'На устройстве нет камер',
        );
      }

      // 3. Превью с автофокусом; снимки — JPEG.
      final controller = CameraController(
        _cameras[_cameraIndex],
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
      _controller = controller;
      if (mounted) setState(() => _initializing = false);
    } on AppException catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = e;
        });
      }
    } on CameraException catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = CameraFailure(
            'Сбой камеры: ${e.code} ${e.description}',
            userMessage: e.code == 'CameraAccessDenied'
                ? 'Нет доступа к камере'
                : 'Камера недоступна: ${e.description ?? e.code}',
            cause: e,
          );
        });
      }
    }
  }

  Future<void> _disposeController() async {
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        await c.dispose();
      } on Exception {
        // Уже отпущена — ок.
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => CropScreen(sourcePath: file.path)),
      );
    } on CameraException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Снимок не удался: ${e.description ?? e.code}')),
        );
      }
    }
  }

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 4000,
    );
    if (picked == null || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => CropScreen(sourcePath: picked.path)),
    );
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null) return;
    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.torch,
      FlashMode.torch => FlashMode.auto,
      _ => FlashMode.off,
    };
    try {
      await controller.setFlashMode(next);
      setState(() => _flashMode = next);
    } on CameraException {
      // Устройство без вспышки — молча игнорируем.
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _controller == null) return;
    await _disposeController();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    _flashMode = FlashMode.off;
    await _init();
  }

  IconData get _flashIcon => switch (_flashMode) {
        FlashMode.torch => Icons.flash_on,
        FlashMode.auto => Icons.flash_auto,
        _ => Icons.flash_off,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_initializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final error = _error;
    if (error != null) {
      return _CameraErrorView(
        error: error,
        onRetry: _init,
        onOpenSettings: () => openAppSettings(),
        onClose: () => Navigator.of(context).pop(),
      );
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(child: CameraPreview(controller)),
        // Верхняя панель: закрыть / вспышка
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Закрыть',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(_flashIcon, color: Colors.white),
                tooltip: 'Вспышка',
                onPressed: _toggleFlash,
              ),
            ],
          ),
        ),
        // Подсказка по кадрированию визитки
        const Positioned(
          top: 64,
          left: 32,
          right: 32,
          child: Text(
            'Поместите визитку в рамку. На следующем шаге можно обрезать.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        // Нижняя панель: галерея / затвор / смена камеры
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                iconSize: 34,
                icon: const Icon(Icons.photo_library, color: Colors.white),
                tooltip: 'Из галереи',
                onPressed: _pickFromGallery,
              ),
              // Затвор: увеличенная зона нажатия для удобства
              GestureDetector(
                onTap: _capture,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              IconButton(
                iconSize: 32,
                icon: const Icon(Icons.cameraswitch, color: Colors.white),
                tooltip: 'Сменить камеру',
                onPressed: _cameras.length > 1 ? _switchCamera : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CameraErrorView extends StatelessWidget {
  const _CameraErrorView({
    required this.error,
    required this.onRetry,
    required this.onOpenSettings,
    required this.onClose,
  });

  final AppException error;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // error — публичное поле виджета, не продвигается: читаем в локальную
    // переменную для проверки типа.
    final err = error;
    final permanent = err is PermissionException && err.permanentlyDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, color: Colors.white54, size: 64),
            const SizedBox(height: 16),
            Text(
              error.userMessage ?? error.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 24),
            if (permanent)
              FilledButton(
                onPressed: onOpenSettings,
                child: const Text('Открыть настройки'),
              )
            else
              FilledButton(
                onPressed: onRetry,
                child: const Text('Повторить'),
              ),
            TextButton(
              onPressed: onClose,
              child: const Text(
                'Закрыть',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

