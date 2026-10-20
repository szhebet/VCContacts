import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/errors/app_exceptions.dart';
import '../models/business_card.dart';

/// Локальный экспорт: vCard 3.0 и CSV.
/// Файлы пишутся во временный каталог приложения и отправляются через
/// системный share-sheet — данные уходят только туда, куда явно отправит
/// пользователь (никаких серверов).
class ExportService {
  /// vCard 3.0 — универсальный формат для «Контактов»/Google/Apple.
  String toVCard(BusinessCard card) {
    final nameParts = card.fullName.trim().split(RegExp(r'\s+'));
    final last = nameParts.isNotEmpty ? nameParts.first : '';
    final first = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

    final lines = [
      'BEGIN:VCARD',
      'VERSION:3.0',
      'N:$last;$first;;;',
      'FN:${card.fullName.trim()}',
      if (card.company.trim().isNotEmpty)
        'ORG:${card.company.trim().replaceAll(',', '\\,')}',
      if (card.position.trim().isNotEmpty)
        'TITLE:${card.position.trim().replaceAll(',', '\\,')}',
      if (card.phone.trim().isNotEmpty)
        'TEL;TYPE=CELL:${card.phone.trim()}',
      if (card.email.trim().isNotEmpty) 'EMAIL;TYPE=INTERNET:${card.email.trim()}',
      if (card.website.trim().isNotEmpty) 'URL:${card.website.trim()}',
      if (card.address.trim().isNotEmpty)
        'ADR;TYPE=WORK:;;${card.address.trim().replaceAll(',', '\\,')};;;;',
      if (card.notes.trim().isNotEmpty)
        'NOTE:${card.notes.trim().replaceAll('\n', '\\n')}',
      'REV:${DateTime.now().toIso8601String()}',
      'END:VCARD',
    ];
    return lines.join('\r\n');
  }

  /// CSV с BOM (чтобы Excel корректно открыл кириллицу).
  String toCsv(List<BusinessCard> cards) {
    final buffer = StringBuffer('\uFEFF');
    buffer.writeln(
      'Имя;Должность;Компания;Телефон;Email;Сайт;Адрес;Заметки',
    );
    for (final c in cards) {
      buffer.writeln([
        _csv(c.fullName),
        _csv(c.position),
        _csv(c.company),
        _csv(c.phone),
        _csv(c.email),
        _csv(c.website),
        _csv(c.address),
        _csv(c.notes),
      ].join(';'));
    }
    return buffer.toString();
  }

  static String _csv(String v) =>
      '"${v.replaceAll('"', '""').replaceAll('\n', ' ')}"';

  /// Сохраняет vCard во временный каталог и открывает share-sheet.
  Future<XFileResult> shareVCard(BusinessCard card) async {
    if (card.isEmpty) {
      throw const ExportException(
        'Пустая карточка не экспортируется',
        userMessage: 'Сначала заполните хотя бы одно поле',
      );
    }
    final file = await _writeTemp('${_safeFileName(card.fullName)}.vcf', toVCard(card));
    await _shareFile(file, 'Визитка ${card.fullName}'.trim());
    return XFileResult(file);
  }

  /// Сохраняет CSV всех карточек и открывает share-sheet.
  Future<XFileResult> shareCsv(List<BusinessCard> cards) async {
    if (cards.isEmpty) {
      throw const ExportException(
        'Нет карточек для экспорта',
        userMessage: 'Список визиток пуст',
      );
    }
    final file = await _writeTemp('vc_contacts_${_stamp()}.csv', toCsv(cards));
    await _shareFile(file, 'Экспорт ${cards.length} визиток');
    return XFileResult(file);
  }

  Future<File> _writeTemp(String name, String content) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, name));
      await file.writeAsString(content, flush: true);
      return file;
    } on Exception catch (e) {
      throw ExportException(
        'Не удалось записать файл экспорта: $e',
        userMessage: 'Не удалось сохранить файл',
        cause: e,
      );
    }
  }

  Future<void> _shareFile(File file, String text) async {
    try {
      await Share.shareXFiles([XFile(file.path)], text: text);
    } on Exception catch (e) {
      throw ExportException(
        'Share sheet недоступен: $e',
        userMessage: 'Не удалось открыть отправку файла',
        cause: e,
      );
    }
  }

  static String _safeFileName(String name) {
    // unicode: true — чтобы \p{L}/\p{N} работали с кириллицей.
    final cleaned =
        name.trim().replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '_');
    return cleaned.isEmpty ? 'contact_${_stamp()}' : cleaned;
  }

  static String _stamp() =>
      DateTime.now().millisecondsSinceEpoch.toRadixString(36);
}

class XFileResult {
  const XFileResult(this.file);
  final File file;
}
