import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../business/cards/cards_list_cubit.dart';
import '../../../business/edit/edit_card_cubit.dart';
import '../../../core/di/injector.dart';
import '../../../data/models/business_card.dart';
import '../../../data/services/ocr_service.dart';
import '../../widgets/editable_field.dart';
import '../../widgets/ocr_diagnostic_panel.dart';

/// Экран проверки/редактирования результата OCR перед сохранением.
/// Явно подтверждение пользователя — данные попадают в БД осознанно.
class EditCardScreen extends StatefulWidget {
  const EditCardScreen({
    super.key,
    required this.draft,
    this.warnings = const [],
    this.unmatchedLines = const [],
    this.emptyOcr = false,
    this.diagnostic,
  });

  final BusinessCard draft;
  final List<String> warnings;
  final List<String> unmatchedLines;
  final bool emptyOcr;
  final OcrDiagnostic? diagnostic;

  @override
  State<EditCardScreen> createState() => _EditCardScreenState();
}

class _EditCardScreenState extends State<EditCardScreen> {
  late final EditCardCubit _cubit;
  late final TextEditingController _name;
  late final TextEditingController _position;
  late final TextEditingController _company;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _website;
  late final TextEditingController _address;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    _cubit = EditCardCubit(
      sl(),
      draft: d,
      unmatchedLines: widget.unmatchedLines,
      warnings: widget.warnings,
    );
    _name = TextEditingController(text: d.fullName);
    _position = TextEditingController(text: d.position);
    _company = TextEditingController(text: d.company);
    _phone = TextEditingController(text: d.phoneRaw.isNotEmpty ? d.phoneRaw : d.phone);
    _email = TextEditingController(text: d.email);
    _website = TextEditingController(text: d.website);
    _address = TextEditingController(text: d.address);
    _notes = TextEditingController(text: d.notes);
  }

  @override
  void dispose() {
    _cubit.close();
    for (final c in [
      _name, _position, _company, _phone,
      _email, _website, _address, _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    // Переливаем значения из контроллеров в кубит, затем сохраняем.
    _cubit
      ..updateField(CardField.fullName, _name.text)
      ..updateField(CardField.position, _position.text)
      ..updateField(CardField.company, _company.text)
      ..updateField(CardField.phone, _phone.text)
      ..updateField(CardField.email, _email.text)
      ..updateField(CardField.website, _website.text)
      ..updateField(CardField.address, _address.text)
      ..updateField(CardField.notes, _notes.text);

    final ok = await _cubit.save();
    if (!ok || !mounted) return;

    // Обновляем корневой список (провайдер выше MaterialApp).
    await context.read<CardsListCubit>().load();
    if (!mounted) return;
    Navigator.of(context).pop(_cubit.state.card);
  }

  Future<void> _discard() async {
    if (!_isDirty()) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Не сохранять?'),
        content: const Text('Распознанные данные будут потеряны.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Продолжить правку'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Не сохранять'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  bool _isDirty() {
    final d = widget.draft;
    return _name.text != d.fullName ||
        _position.text != d.position ||
        _company.text != d.company ||
        _phone.text != (d.phoneRaw.isNotEmpty ? d.phoneRaw : d.phone) ||
        _email.text != d.email ||
        _website.text != d.website ||
        _address.text != d.address ||
        _notes.text != d.notes;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocConsumer<EditCardCubit, EditCardState>(
      bloc: _cubit,
      listenWhen: (prev, curr) => prev.saving != curr.saving ||
          prev.saved != curr.saved ||
          prev.error != curr.error,
      listener: (context, state) {
        if (state.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.error!)),
          );
        }
      },
      builder: (context, state) {
        return PopScope(
          // Подтверждение потери данных при «назад» — всегда через диалог,
          // т.к. canPop не пересчитывается при вводе текста.
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _discard();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.draft.id.isEmpty
                  ? 'Проверьте визитку'
                  : 'Редактирование'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Закрыть',
                onPressed: _discard,
              ),
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                if (widget.emptyOcr)
                  const _Banner(
                    icon: Icons.edit_note,
                    text: 'Текст не распознан — заполните карточку вручную',
                    color: Color(0xFF1565C0),
                  ),
                for (final w in state.warnings.where((w) => w.trim().isNotEmpty))
                  _Banner(icon: Icons.warning_amber_rounded, text: w),

                const SizedBox(height: 8),
                EditableField(
                  label: 'Имя и фамилия',
                  controller: _name,
                  autofocus: widget.emptyOcr,
                  hint: 'Иванов Иван',
                ),
                const SizedBox(height: 14),
                EditableField(
                  label: 'Должность',
                  controller: _position,
                  hint: 'Генеральный директор',
                ),
                const SizedBox(height: 14),
                EditableField(
                  label: 'Компания',
                  controller: _company,
                  hint: 'ООО «Ромашка»',
                ),
                const SizedBox(height: 14),
                EditableField(
                  label: 'Телефон',
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  hint: '+7 (999) 123-45-67',
                ),
                const SizedBox(height: 14),
                EditableField(
                  label: 'Email',
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  hint: 'name@company.ru',
                ),
                const SizedBox(height: 14),
                EditableField(
                  label: 'Сайт',
                  controller: _website,
                  keyboardType: TextInputType.url,
                  hint: 'https://company.ru',
                ),
                const SizedBox(height: 14),
                EditableField(
                  label: 'Адрес',
                  controller: _address,
                  hint: 'г. Москва, ул. Ленина, д. 1',
                ),
                const SizedBox(height: 14),
                EditableField(
                  label: 'Заметки',
                  controller: _notes,
                  hint: 'Встреча, условия, напоминание…',
                ),

                if (state.unmatchedLines.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        'Прочие строки с визитки '
                        '(${state.unmatchedLines.length})',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      children: [
                        for (final line in state.unmatchedLines)
                          InkWell(
                            onTap: () => _appendNote(line),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 6,
                                ),
                                child: Text(
                                  line,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        const Text(
                          'Нажатие добавит строку в заметки — ничего не '
                          'потеряется',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                if (widget.diagnostic != null) ...[
                  const SizedBox(height: 20),
                  OcrDiagnosticPanel(diagnostic: widget.diagnostic!),
                ],
              ],
            ),
            bottomNavigationBar: SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: state.canSave && !state.saving ? _save : null,
                icon: state.saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(state.saving ? 'Сохранение…' : 'Сохранить'),
              ),
            ),
          ),
        );
      },
    );
  }

  void _appendNote(String line) {
    final current = _notes.text;
    _notes.text = current.isEmpty ? line : '$current\n$line';
    _cubit.updateField(CardField.notes, _notes.text);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Строка добавлена в заметки')),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFFF9A825);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
