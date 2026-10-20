import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../business/cards/cards_list_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../core/errors/app_exceptions.dart';
import '../../../data/models/business_card.dart';
import '../../../data/repositories/card_repository.dart';
import '../../../data/services/contact_export_service.dart';
import '../../../data/services/export_service.dart';
import '../edit/edit_card_screen.dart';

/// Просмотр визитки + экспорты: контакты устройства, vCard, копирование.
/// Всё экспортируется только локально (контакты телефона / share-sheet).
class CardDetailScreen extends StatefulWidget {
  const CardDetailScreen({super.key, required this.card});

  final BusinessCard card;

  @override
  State<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends State<CardDetailScreen> {
  late BusinessCard _card;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppException catch (e) {
      _show(e.userMessage ?? e.message);
    } on Exception catch (e) {
      _show('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _exportToContacts() => _run(() async {
        final ok =
            await sl<ContactExportService>().exportToDeviceContacts(_card);
        if (ok) _show('Контакт сохранён в телефон');
      });

  Future<void> _exportVCard() =>
      _run(() => sl<ExportService>().shareVCard(_card));

  Future<void> _edit() async {
    final result = await Navigator.of(context).push<BusinessCard>(
      MaterialPageRoute(builder: (_) => EditCardScreen(draft: _card)),
    );
    if (result == null || !mounted) return;
    // Показываем обновлённую карточку и подтягиваем список под ней.
    setState(() => _card = result);
    await context.read<CardsListCubit>().load();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить визитку?'),
        content: Text('«${_card.displayTitle}» будет удалена с устройства.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await sl<CardRepository>().delete(_card.id);
    if (mounted) Navigator.of(context).pop('deleted');
  }

  Future<void> _copy(String value, String label) async {
    if (value.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value.trim()));
    _show('$label скопировано');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Визитка'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Редактировать',
            onPressed: _edit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Удалить',
            onPressed: _delete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // --- Шапка ---
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    _initials(),
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _card.displayTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_card.displaySubtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _card.displaySubtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.black54,
                    ),
                  ),
                ],
                Text(
                  'Обновлено ${DateFormat('dd.MM.yyyy HH:mm').format(_card.updatedAt)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.black38,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // --- Экспорт ---
          Row(
            children: [
              Expanded(
                child: _ActionCard(
                  icon: Icons.person_add_alt,
                  label: 'В контакты',
                  onTap: _busy ? null : _exportToContacts,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionCard(
                  icon: Icons.ios_share,
                  label: 'vCard',
                  onTap: _busy ? null : _exportVCard,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // --- Поля ---
          if (_card.phone.isNotEmpty)
            _FieldTile(
              icon: Icons.phone_outlined,
              label: 'Телефон',
              value: _card.phoneRaw.isNotEmpty ? _card.phoneRaw : _card.phone,
              onTap: () => _copy(_card.phone, 'Телефон'),
            ),
          if (_card.email.isNotEmpty)
            _FieldTile(
              icon: Icons.mail_outline,
              label: 'Email',
              value: _card.email,
              onTap: () => _copy(_card.email, 'Email'),
            ),
          if (_card.website.isNotEmpty)
            _FieldTile(
              icon: Icons.language,
              label: 'Сайт',
              value: _card.website,
              onTap: () => _copy(_card.website, 'Сайт'),
            ),
          if (_card.address.isNotEmpty)
            _FieldTile(
              icon: Icons.location_on_outlined,
              label: 'Адрес',
              value: _card.address,
              onTap: () => _copy(_card.address, 'Адрес'),
            ),
          if (_card.position.isNotEmpty)
            _FieldTile(
              icon: Icons.work_outline,
              label: 'Должность',
              value: _card.position,
              onTap: () => _copy(_card.position, 'Должность'),
            ),
          if (_card.company.isNotEmpty)
            _FieldTile(
              icon: Icons.business_outlined,
              label: 'Компания',
              value: _card.company,
              onTap: () => _copy(_card.company, 'Компания'),
            ),
          if (_card.notes.isNotEmpty)
            _FieldTile(
              icon: Icons.notes_outlined,
              label: 'Заметки',
              value: _card.notes,
              onTap: () => _copy(_card.notes, 'Заметки'),
            ),

          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  String _initials() {
    final source = _card.fullName.trim().isNotEmpty
        ? _card.fullName
        : (_card.company.isNotEmpty ? _card.company : _card.phone);
    final parts = source
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .toList();
    return parts.isEmpty ? '?' : parts.map((p) => p[0].toUpperCase()).join();
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon, color: onTap == null ? Colors.black26 : theme.colorScheme.primary),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon, color: Colors.black45),
        title: Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
        subtitle: Text(
          value,
          style: const TextStyle(fontSize: 15, color: Colors.black87),
        ),
        trailing: const Icon(Icons.copy, size: 16, color: Colors.black26),
        onTap: onTap,
      ),
    );
  }
}
