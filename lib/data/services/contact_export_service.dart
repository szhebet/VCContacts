import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/errors/app_exceptions.dart';
import '../models/business_card.dart';

/// Экспорт визитки в контакты устройства (flutter_contacts).
/// Всё локально: запись уходит в системный Contact Provider телефона,
/// никуда не отправляется по сети.
class ContactExportService {
  /// Возвращает:
  ///  true  — контакт создан;
  ///  false — пользователь отклонил запрос разрешения.
  /// Бросает [PermissionException], если доступ «запрещён навсегда».
  Future<bool> exportToDeviceContacts(BusinessCard card) async {
    if (card.isEmpty) {
      throw const ExportException(
        'Пустая карточка',
        userMessage: 'Сначала заполните хотя бы одно поле',
      );
    }

    // Запрос разрешения с корректным объяснением (rationale).
    var status = await Permission.contacts.status;
    if (!status.isGranted) {
      status = await Permission.contacts.request();
    }
    if (status.isPermanentlyDenied) {
      throw const PermissionException(
        'WRITE_CONTACTS запрещён навсегда',
        userMessage: 'Доступ к контактам заблокирован. Разрешите вручную '
            'в настройках приложения',
        permanentlyDenied: true,
      );
    }
    if (!status.isGranted) {
      throw const PermissionException(
        'WRITE_CONTACTS отклонён',
        userMessage: 'Без разрешения контакт не сохранить',
      );
    }

    final nameParts = card.fullName.trim().split(RegExp(r'\s+'));
    final contact = Contact(
      // flutter_contacts 1.1.x: имя/фамилия — через объект Name
      name: Name(
        first: nameParts.isNotEmpty ? nameParts.first : '',
        last: nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '',
      ),
      organizations: [
        if (card.company.trim().isNotEmpty || card.position.trim().isNotEmpty)
          Organization(
            company: card.company.trim(),
            title: card.position.trim(),
          ),
      ],
      phones: [
        if (card.phone.trim().isNotEmpty)
          Phone(card.phoneRaw.isNotEmpty ? card.phoneRaw : card.phone),
      ],
      emails: [if (card.email.trim().isNotEmpty) Email(card.email.trim())],
      websites: [
        if (card.website.trim().isNotEmpty) Website(card.website.trim()),
      ],
      addresses: [
        if (card.address.trim().isNotEmpty) Address(card.address.trim()),
      ],
      notes: [
        if (card.notes.trim().isNotEmpty) Note(card.notes.trim()),
      ],
    );

    try {
      await FlutterContacts.insertContact(contact);
      return true;
    } on Exception catch (e) {
      throw ExportException(
        'Не удалось вставить контакт: $e',
        userMessage: 'Системный «Контакты» отклонил запись',
        cause: e,
      );
    }
  }
}
