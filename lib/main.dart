import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/di/injector.dart';
import 'business/cards/cards_list_cubit.dart';
import 'ui/screens/cards_list/cards_list_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Локальная диаграмма зависимостей: БД, OCR, парсер, экспорт.
  // Сетевые инициализации отсутствуют — приложение стартует офлайн.
  await setupDependencies();

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
