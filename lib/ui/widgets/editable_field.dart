import 'package:flutter/material.dart';

/// Подписанное поле ввода для формы проверки/редактирования визитки.
class EditableField extends StatefulWidget {
  const EditableField({
    super.key,
    required this.label,
    required this.controller,
    this.keyboardType,
    this.autofocus = false,
    this.hint,
    this.maxLines = 1,
    this.onChanged,
    this.ocrText,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool autofocus;
  final String? hint;
  final int? maxLines;
  final ValueChanged<String>? onChanged;

  /// Полный распознанный текст. Если задан, рядом с подписью появляется
  /// кнопка «*», раскрывающая область выбора слов прямо под полем.
  final String? ocrText;

  @override
  State<EditableField> createState() => _EditableFieldState();
}

class _EditableFieldState extends State<EditableField> {
  late final TextEditingController _ocrController =
      TextEditingController(text: widget.ocrText ?? '');
  bool _expanded = false;

  bool get _hasOcr => (widget.ocrText ?? '').trim().isNotEmpty;

  @override
  void dispose() {
    _ocrController.dispose();
    super.dispose();
  }

  void _applySelection() {
    final sel = _ocrController.selection;
    final source = widget.ocrText ?? '';
    if (!sel.isValid || sel.isCollapsed || source.isEmpty) return;
    final start = sel.start.clamp(0, source.length);
    final end = sel.end.clamp(0, source.length);
    final selected = source.substring(start, end).trim();
    if (selected.isEmpty) return;
    widget.controller
      ..text = selected
      ..selection =
          TextSelection.collapsed(offset: widget.controller.text.length);
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5A6472),
                ),
              ),
            ),
            if (_hasOcr)
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(16),
                child: Tooltip(
                  message: _expanded
                      ? 'Скрыть распознанный текст'
                      : 'Выбрать слова из распознанного текста',
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(
                      '*',
                      style: TextStyle(
                        fontSize: 22,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: _expanded
                            ? const Color(0xFF0D47A1)
                            : const Color(0xFF1565C0),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: widget.controller,
          keyboardType: widget.keyboardType,
          autofocus: widget.autofocus,
          maxLines: widget.maxLines,
          autocorrect: false,
          decoration: InputDecoration(hintText: widget.hint),
          onChanged: widget.onChanged,
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F8FB),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFD7DEE8)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Выделите нужные слова и нажмите «ОК»',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: TextField(
                    controller: _ocrController,
                    readOnly: true,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 14, height: 1.4),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _expanded = false),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _applySelection,
                      child: const Text('ОК'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
