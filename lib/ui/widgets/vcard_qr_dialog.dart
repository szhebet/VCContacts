import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/models/business_card.dart';
import '../../data/services/export_service.dart';

/// QR-код визитки в формате vCard 4.0.
///
/// Показывается на главном экране для карточки с флагом MyVcard и на
/// экране просмотра текущей карточки.
class VCardQrDialog extends StatelessWidget {
  const VCardQrDialog({super.key, required this.card});

  final BusinessCard card;

  /// Максимум байт для QR с коррекцией M: длинные заметки/теги сначала
  /// отбрасываются, чтобы код оставался читаемым.
  static const int _maxBytes = 2200;

  static Future<void> show(BuildContext context, BusinessCard card) {
    return showDialog<void>(
      context: context,
      builder: (_) => VCardQrDialog(card: card),
    );
  }

  String get _data {
    final exporter = ExportService();
    var data = exporter.toVCard4(card);
    if (utf8.encode(data).length > _maxBytes) {
      data = exporter.toVCard4(card, includeNotes: false);
    }
    if (utf8.encode(data).length > _maxBytes) {
      data = exporter.toVCard4(
        card,
        includeNotes: false,
        includeTags: false,
      );
    }
    return data;
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final tooLong = utf8.encode(data).length > _maxBytes;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.qr_code_2),
          SizedBox(width: 8),
          Expanded(child: Text('QR-код визитки')),
        ],
      ),
      content: LayoutBuilder(
        builder: (context, constraints) {
          final qrSize =
              (constraints.maxWidth - 24).clamp(120.0, 260.0).toDouble();
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tooLong)
                  const Text(
                    'В карточке слишком много данных для одного QR-кода. '
                    'Сократите заметки или теги.',
                    textAlign: TextAlign.center,
                  )
                else
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFD7DEE8)),
                    ),
                    child: QrImageView(
                      data: data,
                      version: QrVersions.auto,
                      size: qrSize,
                      backgroundColor: Colors.white,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  card.displayTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                const Text(
                  'vCard 4.0 · отсканируйте камерой телефона',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
