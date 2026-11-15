import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/di/injector.dart';
import 'business/cards/cards_list_cubit.dart';
import 'business/scan/scan_queue_cubit.dart';
import 'ui/screens/cards_list/cards_list_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ошибки не должны оставлять пользователя с чёрным экраном: пишем их
  // в logcat (их можно снять через adb) и показываем внятный экран, если
  // не удалось инициализировать зависимости.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[APP] FlutterError: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[APP] Uncaught: $error\n$stack');
    return true;
  };

  try {
    // Локальная диаграмма зависимостей: БД, OCR, парсер, экспорт.
    // Сетевые инициализации отсутствуют — приложение стартует офлайн.
    await setupDependencies();
  } on Object catch (e, stack) {
    debugPrint('[APP] startup failed: $e\n$stack');
    runApp(_StartupErrorApp(error: e));
    return;
  }

  runApp(const VcContactsApp());
}

class VcContactsApp extends StatelessWidget {
  const VcContactsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      // Cubit списка живёт дольше навигации: экран деталей/редактора
      // возвращается в актуальный список без повторной загрузки.
      providers: [
        BlocProvider<CardsListCubit>(
          create: (_) => sl<CardsListCubit>()..load(),
        ),
        BlocProvider<ScanQueueCubit>(
          create: (_) => sl<ScanQueueCubit>(),
        ),
      ],
      child: MaterialApp(
        title: 'VCContacts',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: const CardsListScreen(),
      ),
    );
  }
}

/// Видимый экран вместо чёрного, если инициализация зависимостей упала.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      size: 64, color: Colors.black26),
                  const SizedBox(height: 16),
                  const Text(
                    'Не удалось запустить приложение',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Перезапустите приложение. Если ошибка повторяется — '
                    'сохраните логи через adb logcat.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    error.toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black38),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
