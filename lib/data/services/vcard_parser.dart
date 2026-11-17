import '../models/business_card.dart';

/// Разбор vCard 3.0/4.0 из QR-кода в черновик визитки.
///
/// Переносятся только те поля, которые реально есть в QR: имя, компания,
/// должность, телефоны, email, сайт, адрес, заметки и теги. Никакого OCR
/// и догадок по фото здесь нет.
class VCardParser {
  const VCardParser();

  BusinessCard? parse(String raw) {
    final text = _unfold(raw).trim();
    if (text.isEmpty || !text.toUpperCase().contains('BEGIN:VCARD')) {
      return null;
    }

    final props = <String, List<String>>{};
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      final colon = _unescapedIndex(line, ':');
      if (colon <= 0) continue;
      final left = line.substring(0, colon);
      final name = left.split(';').first.trim().toUpperCase();
      if (name.isEmpty) continue;
      props.putIfAbsent(name, () => []).add(line.substring(colon + 1));
    }

    final fn = _firstValue(props, 'FN')?.trim() ?? '';
    final fullName = fn.isNotEmpty ? fn : _formatName(_first(props, 'N'));
    final orgParts = _components(_first(props, 'ORG'), ';');
    final company = orgParts.firstWhere(
      (p) => p.trim().isNotEmpty,
      orElse: () => '',
    );
    final position = _firstValue(props, 'TITLE')?.trim() ?? '';

    final phoneValues = <String>[];
    for (final rawPhone in props['TEL'] ?? const <String>[]) {
      final phone = _cleanTelephone(rawPhone);
      if (phone != null) phoneValues.add(phone);
    }
    final phoneRaw = phoneValues.isNotEmpty ? phoneValues.first : '';

    final emails = [
      for (final e in props['EMAIL'] ?? const <String>[])
        if (_cleanEmail(e).isNotEmpty) _cleanEmail(e),
    ];
    final urls = [
      for (final u in props['URL'] ?? const <String>[]) _unescape(u).trim(),
    ].where((u) => u.isNotEmpty).toList();
    // URL в vCard может быть Telegram-ссылкой.
    final telegram = _firstValue(props, 'X-TELEGRAM')?.trim() ??
        urls.firstWhere(
          (u) => u.toLowerCase().contains('t.me/'),
          orElse: () => '',
        );
    final websites =
        urls.where((u) => !u.toLowerCase().contains('t.me/')).toList();

    final note = [
      for (final n in props['NOTE'] ?? const <String>[]) _unescape(n).trim(),
    ].where((n) => n.isNotEmpty).join('\n');
    final tags = <String>[];
    for (final rawCategories in props['CATEGORIES'] ?? const <String>[]) {
      for (final tag in _components(rawCategories, ',')) {
        if (tag.trim().isNotEmpty) tags.add(tag.trim());
      }
    }

    final card = BusinessCard(
      id: '',
      fullName: fullName,
      company: company.trim(),
      position: position,
      phone: _normalizePhone(phoneRaw),
      phoneRaw: phoneRaw,
      extraPhones: phoneValues.skip(1).toList(),
      telegram: telegram,
      email: emails.isNotEmpty ? emails.first : '',
      website: websites.isNotEmpty ? websites.first : '',
      address: _formatAddress(_first(props, 'ADR')),
      notes: note,
      tags: BusinessCard.normalizeTags(tags),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    return _hasUsefulData(card) ? card : null;
  }

  static bool _hasUsefulData(BusinessCard card) =>
      card.fullName.trim().isNotEmpty ||
      card.company.trim().isNotEmpty ||
      card.position.trim().isNotEmpty ||
      card.phone.trim().isNotEmpty ||
      card.phoneRaw.trim().isNotEmpty ||
      card.extraPhones.isNotEmpty ||
      card.email.trim().isNotEmpty ||
      card.website.trim().isNotEmpty ||
      card.address.trim().isNotEmpty ||
      card.notes.trim().isNotEmpty ||
      card.tags.isNotEmpty ||
      card.telegram.trim().isNotEmpty;

  static String? _first(Map<String, List<String>> props, String name) {
    final values = props[name.toUpperCase()];
    return values == null || values.isEmpty ? null : values.first;
  }

  static String? _firstValue(Map<String, List<String>> props, String name) {
    final raw = _first(props, name);
    return raw == null ? null : _unescape(raw);
  }

  /// vCard может переносить длинные строки: CRLF + пробел/таб.
  static String _unfold(String raw) {
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return text.replaceAll(RegExp(r'\n[ \t]'), '');
  }

  static String _unescape(String value) {
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (ch == '\\' && i + 1 < value.length) {
        final next = value[++i];
        if (next == 'n' || next == 'N') {
          out.write('\n');
        } else {
          out.write(next);
        }
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }

  static int _unescapedIndex(String value, String target) {
    var escaped = false;
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        escaped = true;
        continue;
      }
      if (ch == target) return i;
    }
    return -1;
  }

  static List<String> _components(String? raw, String separator) {
    if (raw == null || raw.isEmpty) return const [];
    final result = <String>[];
    var start = 0;
    var escaped = false;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        escaped = true;
        continue;
      }
      if (ch == separator) {
        result.add(_unescape(raw.substring(start, i)));
        start = i + 1;
      }
    }
    result.add(_unescape(raw.substring(start)));
    return result;
  }

  static String _formatName(String? raw) {
    final parts = List<String>.of(_components(raw, ';'));
    while (parts.length < 5) {
      parts.add('');
    }
    // N: family;given;additional;prefix;suffix.
    final ordered = [parts[3], parts[1], parts[2], parts[0], parts[4]];
    return ordered.map((p) => p.trim()).where((p) => p.isNotEmpty).join(' ');
  }

  static String _formatAddress(String? raw) {
    final parts = List<String>.of(_components(raw, ';'));
    while (parts.length < 7) {
      parts.add('');
    }
    // ADR: PO box;extended;street;locality;region;postal;country.
    final ordered = [parts[2], parts[3], parts[4], parts[5], parts[6]];
    return ordered.map((p) => p.trim()).where((p) => p.isNotEmpty).join(', ');
  }

  static String? _cleanTelephone(String raw) {
    var value = _unescape(raw).trim();
    if (value.toLowerCase().startsWith('tel:')) {
      value = value.substring(4).trim();
    }
    if (value.replaceAll(RegExp(r'\D'), '').length < 5) return null;
    return value;
  }

  static String _normalizePhone(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('8') && cleaned.length == 11) {
      return '+7${cleaned.substring(1)}';
    }
    if (cleaned.startsWith('7') && cleaned.length == 11) {
      return '+$cleaned';
    }
    return cleaned;
  }

  static String _cleanEmail(String raw) {
    var value = _unescape(raw).trim();
    if (value.toLowerCase().startsWith('mailto:')) {
      value = value.substring(7).trim();
    }
    return value;
  }
}
