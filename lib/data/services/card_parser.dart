import '../models/business_card.dart';

/// Результат разбора текста визитки до привязки к хранилищу.
class ParsedCard {
  const ParsedCard({
    required this.card,
    required this.warnings,
    required this.unmatchedLines,
  });

  /// Черновик карточки (без id — проставит репозиторий).
  final BusinessCard card;

  /// Предупреждения: «телефонов несколько», «кириллица в OCR» и т.п.
  final List<String> warnings;

  /// Строки, которые парсер отнёс к «прочему» — экран редактирования
  /// показывает их, чтобы пользователь ничего не потерял.
  final List<String> unmatchedLines;
}

/// Парсинг полей визитки: регулярные выражения + эвристики.
/// Никакой сетевой работы — только строки, полученные из on-device OCR.
///
/// Пайплайн внутри:
///   1) email (самый точный сигнал, «маскирует» текст);
///   2) телефон (RU/международные форматы, нормализация в E.164);
///   3) URL/site;
///   4) адрес (ключевые слова + индекс);
///   5) должность (ключевые слова ru/en);
///   6) компания (ООО/LLC/«кавычки»/ Inc...);
///   7) имя (лучший оставшийся «человеческий» кандидат).
class CardParser {
  CardParser();

  // ------------------------------------------------------------------ regex

  /// Email: локальная часть + домен + TLD (2+ символа).
  static final _emailRegex = RegExp(
    r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}',
  );

  /// Телефон: кандидат — цифры с разделителями (пробел, -, (), точка),
  /// опциональный код страны «+…». Далее фильтруется по числу цифр.
  static final _phoneCandidateRegex = RegExp(
    r'\+?\d[\d\s\-.()]{5,20}\d|\b\d{6,12}\b',
  );

  /// URL: явный протокол/www ИЛИ домен с известным TLD.
  /// Lookahead (?![a-zA-Z0-9-]) не даёт «съесть» начало слова:
  /// «ACME Corp.» не станет сайтом acme.co / acme.com.
  static final _urlRegex = RegExp(
    r'(?:https?://|www\.)[^\s,;|]+'
    r'|(?:[a-zA-Z0-9\-]+\.)+(?:com|ru|net|org|io|me|su|info|biz|tech|'
    r'dev|app|co|uk|de|fr|eu|рф)(?![a-zA-Z0-9\-])(?:/[^\s,;|]*)?',
    caseSensitive: false,
  );

  /// Расширения файлов, которые легко спутать с доменом (vizitka.pdf).
  static const _fileExtensions = {
    'pdf', 'jpg', 'jpeg', 'png', 'gif', 'webp', 'doc', 'docx', 'xls',
    'xlsx', 'ppt', 'pptx', 'txt', 'zip', 'rar', 'svg', 'mp3', 'mp4',
  };

  /// Разделители «Имя — Должность» на одной строке.
  static final _nameSplitRegex = RegExp(r'\s+[—–|\-]\s+|\s*,\s*');

  // ------------------------------------------------------------- ключевые слова

  /// Должность: ru + en. Проверяется по вхождению подстроки.
  static const _positionKeywords = [
    // ru
    'менеджер', 'директор', 'генеральный', 'коммерческий', 'финансовый',
    'технический', 'руководитель', 'основатель', 'владелец', 'консультант',
    'специалист', 'аналитик', 'разработчик', 'дизайнер', 'инженер',
    'программист', 'юрист', 'бухгалтер', 'маркетолог', 'администратор',
    'сотрудник', 'заместитель', 'дирекция', 'отдел', 'продаж', 'поддержк',
    'эксперт', 'директор', 'партнер', 'сооснователь', 'девелопер',
    'нотариус',
    // en
    'ceo', 'cto', 'cfo', 'cmo', 'coo', 'founder', 'owner', 'director',
    'manager', 'engineer', 'developer', 'designer', 'analyst',
    'consultant', 'sales', 'marketing', 'account', 'recruiter',
    'architect', 'officer', 'executive', 'president', 'chief',
    'specialist', 'supervisor', 'head of', 'head,', 'lead',
    'business development', 'customer', 'representative', 'assistant',
    'junior', 'middle', 'senior', 'principal', 'intern', 'coordinator',
  ];

  /// Компания: организационные формы, маркеры и типичные орг-существительные.
  /// Последние не дают строке вроде «Нотариальная Палата» украсть поле
  /// «Имя»: без них она набирает 2 балла как «два слова с заглавными».
  static const _companyKeywords = [
    'ооо', 'зао', 'пао', 'ао ', 'ип ', 'нко',
    'llc', 'ltd', 'inc', 'corp', 'gmbh', 'ag ', 'sa ', 'llp', 'plc',
    'company', 'group', 'studio', 'agency', 'solutions', 'systems',
    'компания', 'фирма', 'группа', 'производств', 'центр',
    'нотариаль', 'нотариат', 'палата', 'ассоциац', 'министерств',
    'департамент', 'комитет', 'академи', 'институт', 'фонд', 'управлен',
    'контора', 'бюро',
  ];

  /// Адрес: ru + en ключевые слова (сопоставляются по токенам строк)
  /// и почтовый индекс РФ.
  static const _addressKeywords = {
    'ул', 'улица', 'пр', 'проспект', 'пер', 'переулок', 'наб', 'набережная',
    'б-р', 'бульвар', 'шоссе', 'ш', 'д', 'дом', 'стр', 'строение',
    'корпус', 'каб', 'офис', 'этаж', 'кв', 'г', 'город', 'москва',
    'санкт', 'индекс',
    'street', 'st', 'st.', 'avenue', 'ave', 'ave.', 'road', 'rd', 'rd.',
    'blvd', 'lane', 'drive', 'suite', 'floor', 'apt', 'building',
    'office', 'city',
  };

  // ------------------------------------------------------------------- публичное

  /// Разбирает текст OCR в черновик карточки.
  /// [ocrLines] — построчный результат OCR (если есть, используется
  /// вместо разбиения [rawText], т.к. сохраняет порядок чтения).
  ParsedCard parse(String rawText, {List<String>? ocrLines, bool containsCyrillic = false}) {
    final warnings = <String>[];

    final lines = (ocrLines != null && ocrLines.isNotEmpty)
        ? ocrLines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList()
        : rawText
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();

    if (lines.isEmpty) {
      return ParsedCard(
        card: _emptyDraft(),
        warnings: const ['OCR не вернул текст — заполните карточку вручную'],
        unmatchedLines: const [],
      );
    }

    if (containsCyrillic) {
      warnings.add(
        'Кириллица: проверьте распознанные поля внимательнее',
      );
    }

    // «рабочая копия» строк: изъятые поля заменяются на пустоту,
    // чтобы они не участвовали дальше как кандидаты на имя/компанию.
    final rest = List<String>.from(lines);

    // 1. Email -----------------------------------------------------------------
    String email = '';
    for (final line in lines) {
      final m = _emailRegex.firstMatch(line);
      if (m != null) {
        email = _cleanTrailing(m.group(0)!);
        _mask(rest, email);
        break;
      }
    }

    // 2. Телефон ----------------------------------------------------------------
    String phone = '';
    String phoneRaw = '';
    final phoneCandidates = <_PhoneCandidate>[];
    for (final line in lines) {
      phoneCandidates.addAll(_extractPhones(line));
    }
    if (phoneCandidates.isNotEmpty) {
      final best = _chooseBestPhone(phoneCandidates);
      phone = best.normalized;
      phoneRaw = best.raw;
      // Маскируем все кандидаты-телефоны, чтобы не спутать с именем.
      for (final c in phoneCandidates) {
        _mask(rest, c.raw);
      }
      if (phoneCandidates.length > 1) {
        warnings.add(
          'Найдено телефонов: ${phoneCandidates.length} — '
          'сохранён первый по приоритету, остальные проверьте вручную',
        );
      }
    }

    // 3. URL --------------------------------------------------------------------
    String website = '';
    for (final line in lines) {
      final candidate = _extractUrl(line, email);
      if (candidate != null) {
        website = candidate;
        _mask(rest, candidate);
        break;
      }
    }

    // 4. Адрес ------------------------------------------------------------------
    String address = '';
    final addressIdx = rest.indexWhere(_looksLikeAddress);
    if (addressIdx >= 0) {
      address = _cleanAddress(rest[addressIdx]);
      rest[addressIdx] = '';
    }

    // 5. Должность ---------------------------------------------------------------
    String position = '';
    final positionIdx = rest.indexWhere(_looksLikePosition);
    if (positionIdx >= 0) {
      // Строка могла быть «Имя — Должность»: тогда имя оставляем
      // кандидатом в этой же строке, а должность берём после разделителя.
      final parts = _splitNamePosition(rest[positionIdx]);
      position = parts.positionText.isNotEmpty
          ? _cleanPosition(parts.positionText)
          : _cleanPosition(rest[positionIdx]);
      rest[positionIdx] =
          parts.nameCandidate.isNotEmpty ? parts.nameCandidate : '';
    }

    // 6. Компания ----------------------------------------------------------------
    String company = '';
    final companyIdx = rest.indexWhere(_looksLikeCompany);
    if (companyIdx >= 0) {
      company = _cleanCompany(rest[companyIdx]);
      rest[companyIdx] = '';
    }

    // 7. Имя ---------------------------------------------------------------------
    String fullName = '';
    final nameCandidate = _pickBestNameCandidate(rest);
    if (nameCandidate != null) {
      fullName = nameCandidate.text;
      rest[nameCandidate.index] = '';
    }

    // 8. Фолбэк для компании: первая осмысленная строка после имени/должности.
    // Строки с цифрами («встретиться после 15:00») компанией не считаем.
    if (company.isEmpty) {
      final fallbackIdx = rest.indexWhere(
        (l) => _isHumanLine(l) && l != fullName && !RegExp(r'\d').hasMatch(l),
      );
      if (fallbackIdx >= 0 && fullName.isNotEmpty) {
        company = _cleanCompany(rest[fallbackIdx]);
        rest[fallbackIdx] = '';
      }
    }

    final unmatched =
        rest.where((l) => l.trim().isNotEmpty).map((l) => l.trim()).toList();

    if (fullName.isEmpty && company.isEmpty && phone.isEmpty && email.isEmpty) {
      warnings.add('Не удалось выделить поля — проверьте текст вручную');
    }

    return ParsedCard(
      card: _emptyDraft().copyWith(
        fullName: fullName,
        position: position,
        company: company,
        phone: phone,
        phoneRaw: phoneRaw,
        email: email,
        website: website,
        address: address,
      ),
      warnings: warnings,
      unmatchedLines: unmatched,
    );
  }

  // ----------------------------------------------------------------- телефон

  static List<_PhoneCandidate> _extractPhones(String line) {
    final result = <_PhoneCandidate>[];
    for (final m in _phoneCandidateRegex.allMatches(line)) {
      final raw = m.group(0)!.trim();
      final digits = raw.replaceAll(RegExp(r'\D'), '');

      if (digits.length < 7 || digits.length > 15) continue;
      // Отбрасываем годы/диапазоны: 2019-2024 и т.п.
      if (RegExp(r'^\d{4}\s*[-–]\s*\d{4}$').hasMatch(raw)) continue;

      final normalized = _normalizePhone(digits, raw);
      if (normalized.isEmpty) continue;

      // Признак «похоже на телефон»: плюс, скобки/дефисы, или 10-15 цифр.
      final looksInternational = raw.contains('+');
      final hasSeparators = RegExp(r'[\-()]').hasMatch(raw);
      if (!looksInternational && !hasSeparators && digits.length < 10) {
        continue;
      }
      result.add(_PhoneCandidate(raw: raw, normalized: normalized));
    }
    return result;
  }

  /// Нормализация в E.164 с приоритетом российских форматов:
  ///   +7 (999) 123-45-67  -> +79991234567
  ///   8 999 123-45-67     -> +79991234567
  ///   999-12-34           -> +79991234567   (мобильный без кода)
  ///   (495) 123-45-67     -> +74951234567   (городской без кода)
  ///   +1 555 123 4567     -> +15551234567   (международный — как есть)
  static String _normalizePhone(String digits, String raw) {
    if (digits.length < 7 || digits.length > 15) return '';

    if (raw.trim().startsWith('+')) {
      return '+$digits';
    }
    if (digits.length == 11 && digits.startsWith('8')) {
      return '+7${digits.substring(1)}';
    }
    if (digits.length == 11 && digits.startsWith('7')) {
      return '+$digits';
    }
    if (digits.length == 10) {
      // РФ без междугороднего кода: 9XXXXXXXXX (моб.) или 4XXXXXXXXX/3XXXXXXXXX (город).
      if (digits.startsWith('9')) return '+7$digits';
      if (RegExp(r'^[34][0-9]{9}$').hasMatch(digits)) return '+7$digits';
      // Североамериканский NANP: 1XXXXXXXXXX без плюса не отличить от РФ
      // 10 цифр — оставляем как есть (без +): UI позволит исправить.
      return digits;
    }
    if (digits.length == 9 && digits.startsWith('9')) {
      // Локальный мобильный «999 123 45 67».
      return '+7$digits';
    }
    // Прочие международные: доверяем «+», если был, иначе просто цифры.
    return raw.contains('+') ? '+$digits' : digits;
  }

  static _PhoneCandidate _chooseBestPhone(List<_PhoneCandidate> list) {
    // Приоритет: начинается с +7/8 или 11 цифр РФ, затем прочие с «+».
    for (final c in list) {
      if (c.normalized.startsWith('+7') && c.normalized.length == 12) return c;
    }
    for (final c in list) {
      if (c.normalized.startsWith('+') && c.normalized.length >= 11) return c;
    }
    return list.first;
  }

  // --------------------------------------------------------------------- url

  static String? _extractUrl(String line, String alreadyEmail) {
    for (final m in _urlRegex.allMatches(line)) {
      var candidate = _cleanTrailing(m.group(0)!).toLowerCase();
      if (candidate.isEmpty) continue;

      // Пропускаем расширения файлов (vizitka.pdf).
      final ext = candidate.split('.').last.split('/').first;
      if (_fileExtensions.contains(ext)) continue;

      // «голый» домен из строки с email (ivan@mail.ru -> mail.ru)
      // не считаем сайтом; явный www./http — считаем.
      final isExplicit =
          candidate.startsWith('http') || candidate.startsWith('www.');
      if (!isExplicit &&
          alreadyEmail.isNotEmpty &&
          candidate.contains(alreadyEmail.split('@').last.toLowerCase())) {
        continue;
      }
      // Всегда нормализуем к полному URL: www.site.ru -> https://www.site.ru
      if (!candidate.startsWith('http')) candidate = 'https://$candidate';
      return candidate;
    }
    return null;
  }

  // ------------------------------------------------------------------ адрес/должность/компания

  static bool _looksLikeAddress(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    // 6-значный почтовый индекс РФ — сильный сигнал.
    if (RegExp(r'\b\d{6}\b').hasMatch(t)) return true;
    // Токенизация: «г. Москва, ул. Ленина» -> [г., москва, ул., ленина]
    final tokens = t
        .toLowerCase()
        .split(RegExp(r'[^0-9a-zа-яё./-]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    for (final token in tokens) {
      if (_addressKeywords.contains(token)) return true;
      // «ул.» == «ул», «д.» == «д»
      final bare = token.endsWith('.') || token.endsWith(',')
          ? token.substring(0, token.length - 1)
          : token;
      if (_addressKeywords.contains(bare)) return true;
    }
    return false;
  }

  /// Адрес после маски контактов: «МО г. Видное,     Телефон:» —
  /// отрезаем повисшие хвостовые метки («Телефон:», «Тел.», «E-mail»…).
  static String _cleanAddress(String line) {
    var s = line.replaceAll(
      RegExp(
        r'[\s,;:.-]*(?:тел\.?|телефон|факс|e-?mail|сайт|site)[\s:.,;()\-]*$',
        caseSensitive: false,
      ),
      '',
    );
    s = _cleanTrailing(s);
    return s.trim();
  }

  static bool _looksLikePosition(String line) {
    final lower = line.toLowerCase();
    if (lower.trim().isEmpty) return false;
    for (final k in _positionKeywords) {
      if (lower.contains(k)) return true;
    }
    return false;
  }

  static String _cleanPosition(String line) {
    // «Генеральный директор ООО …» → берём только должность до организационной формы.
    var s = line.trim();
    for (final k in ['ооо', 'зао', 'пао', 'llc', 'ltd', 'inc']) {
      final i = s.toLowerCase().indexOf(' $k');
      if (i > 0) s = s.substring(0, i).trim();
    }
    // Мусор от логотипа/рамки в конце строки: «НОТАРИУС |.».
    // Скобки не трогаем — «Директор (CEO)» должна сохраниться.
    while (s.isNotEmpty && '|.,;:'.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1);
    }
    return s.trim();
  }

  static bool _looksLikeCompany(String line) {
    final l = ' ${line.toLowerCase()} ';
    // «кавычки» — типичное написание компании в РФ: ООО «Ромашка»
    if (line.contains('«') || line.contains('»')) return true;
    for (final k in _companyKeywords) {
      if (l.contains(k)) return true;
    }
    return false;
  }

  static String _cleanCompany(String line) {
    var s = line.trim();
    // Вырезаем «орг. форму + кавычки» → только название не нужно,
    // наоборот: оставляем строку целиком, но убираем вложенную должность.
    return s;
  }

  // ---------------------------------------------------------------------- имя

  static _NameCandidate? _pickBestNameCandidate(List<String> rest) {
    _NameCandidate? best;
    var bestScore = 0;

    for (var i = 0; i < rest.length; i++) {
      final line = rest[i].trim();
      if (line.isEmpty) continue;
      final score = _scoreName(line);
      if (score > bestScore) {
        bestScore = score;
        best = _NameCandidate(index: i, text: line);
      }
    }
    // Порог: 2+ балла — уверенный кандидат, сомнительные строки не берём.
    if (bestScore < 2) return null;
    return best;
  }

  /// Оценка строки как «это имя человека».
  /// 3 — «Иванов Иван» / «Ivan Petrov» (2 слова, каждое с заглавной);
  /// 2 — 1 слово с заглавной или 3 слова с заглавными;
  /// 1 — сомнительный кандидат;
  /// 0 — точно не имя (контакты, цифры, ключевые слова).
  static int _scoreName(String line) {
    if (_looksLikeAddress(line)) return 0;
    if (_emailRegex.hasMatch(line)) return 0;
    if (_phoneCandidateRegex.hasMatch(line) &&
        RegExp(r'\d{7,}').hasMatch(line)) {
      return 0;
    }
    final lower = line.toLowerCase();
    for (final k in _positionKeywords) {
      if (lower.contains(k)) return 1; // «Имя — Должность» обработается выше
    }
    for (final k in _companyKeywords) {
      if (lower.contains(k)) return 0;
    }

    if (line.length > 60) return 0;

    final words = line.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty || words.length > 4) return 0;

    var capitalized = 0;
    var withDigit = 0;
    for (final w in words) {
      if (RegExp(r'\d').hasMatch(w)) withDigit++;
      final first = w[0];
      if (first == first.toUpperCase() && first != first.toLowerCase()) {
        capitalized++;
      }
    }
    // Имя не содержит цифр (кроме редких случаев) и не ALL CAPS целиком.
    if (withDigit > 0) return withDigit >= 2 ? 0 : 1;
    final isAllUpper =
        words.every((w) => w == w.toUpperCase()) && line.length > 12;
    if (isAllUpper) return 1;

    if (words.length == 2 && capitalized == 2) return 3;
    if (words.length == 3 && capitalized >= 2) return 2;
    if (words.length == 1 && capitalized == 1 && words.first.length > 1) {
      return 2;
    }
    if (words.length <= 3 && capitalized >= 1) return 1;
    return 0;
  }

  static ({String nameCandidate, String positionText}) _splitNamePosition(
    String line,
  ) {
    const none = (nameCandidate: '', positionText: '');
    final m = _nameSplitRegex.firstMatch(line);
    if (m == null) return none;
    final left = line.substring(0, m.start).trim();
    final right = line.substring(m.end).trim();
    // «Имя — Должность»: слева имя, справа должность.
    // «Должность — Имя» — редкий случай, определяем по ключевым словам.
    if (_looksLikePosition(right) && !_looksLikePosition(left)) {
      return (nameCandidate: left, positionText: right);
    }
    return none;
  }

  // --------------------------------------------------------------------- утилиты

  static bool _isHumanLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (_emailRegex.hasMatch(t)) return false;
    if (_looksLikeAddress(t)) return false;
    if (_looksLikePosition(t)) return false;
    if (_phoneCandidateRegex.hasMatch(t) && RegExp(r'\d{7,}').hasMatch(t)) {
      return false;
    }
    return _scoreName(t) >= 1 || t.split(' ').length <= 6;
  }

  /// Убирает висящие в конце пунктуацию и скобки: «petrov@romasha.ru.»
  static String _cleanTrailing(String s) {
    var out = s.trim();
    while (out.isNotEmpty && '.,;:)]}'.contains(out[out.length - 1])) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// Заменяет найденное значение на пробелы, сохраняя число строк
  /// (чтобы индексы остальных эвристик не поехали).
  static void _mask(List<String> lines, String value) {
    if (value.isEmpty) return;
    for (var i = 0; i < lines.length; i++) {
      lines[i] = lines[i].replaceAll(value, ' ');
    }
  }

  static BusinessCard _emptyDraft() => BusinessCard(
        id: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
}

class _PhoneCandidate {
  const _PhoneCandidate({
    required this.raw,
    required this.normalized,
  });

  final String raw;
  final String normalized;
}

class _NameCandidate {
  const _NameCandidate({required this.index, required this.text});

  final int index;
  final String text;
}
