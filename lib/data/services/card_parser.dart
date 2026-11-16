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

  /// Предупреждения: «телефонов несколько» и т.п.
  final List<String> warnings;

  /// Строки, которые парсер отнёс к «прочему» — экран редактирования
  /// показывает их, чтобы пользователь ничего не потерял. Они же попадают
  /// в поле [BusinessCard.otherText].
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

  /// E-mail без обязательной точки в домене — для починки OCR-ошибок
  /// («INFO@EXAMPLEJNFO», «user@yandex,ru»).
  static final _looseEmailRegex = RegExp(
    r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.,\-]+',
  );

  /// Телефон: кандидат — цифры с разделителями (пробел, -, (), точка),
  /// опциональный код страны «+…» и/или открывающая скобка кода города.
  /// Открывающую скобку включаем в совпадение (`\(?`), иначе на визитке
  /// с «(495) 123-45-67» в `phoneRaw` терялась ведущая «(».
  /// Далее кандидат фильтруется по числу цифр.
  static final _phoneCandidateRegex = RegExp(
    r'\+?\(?\d[\d\s\-.()]{5,20}\d|\b\d{6,12}\b',
  );

  /// URL: явный протокол/www ИЛИ домен с известным TLD.
  /// Lookahead (?![a-zA-Z0-9-]) не даёт «съесть» начало слова:
  /// «ACME Corp.» не станет сайтом acme.co / acme.com.
  /// Telegram: ссылка `t.me/username` / `telegram.me/username`.
  static final _telegramLinkRegex = RegExp(
    r'(?:https?://)?t(?:elegram)?\.me/([A-Za-z0-9_]{4,32})',
    caseSensitive: false,
  );

  /// Telegram: `@username` (не часть e-mail: перед @ не должно быть
  /// буквы/цифры/точки).
  static final _telegramAtRegex = RegExp(r'(?<![\w.@])@([A-Za-z0-9_]{5,32})\b');

  static final _urlRegex = RegExp(
    r'(?:https?://|www\.)[^\s,;|]+'
    r'|(?:[a-zA-Z0-9\-]+\.)+(?:com|ru|net|org|io|me|su|info|biz|tech|'
    r'dev|app|co|uk|de|fr|eu|рф)(?![a-zA-Z0-9\-])(?:/[^\s,;|]*)?',
    caseSensitive: false,
  );

  /// Расширения файлов, которые легко спутать с доменом (vizitka.pdf).
  static const _fileExtensions = {
    'pdf',
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'zip',
    'rar',
    'svg',
    'mp3',
    'mp4',
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
    'амбассадор',
    'программист', 'юрист', 'бухгалтер', 'маркетолог', 'администратор',
    'сотрудник', 'заместитель', 'дирекция', 'отдел', 'продаж', 'поддержк',
    'эксперт', 'директор', 'партнер', 'сооснователь', 'девелопер',
    'нотариус', 'управление',
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
    'ооо',
    'зао',
    'пао',
    'ао ',
    'ип ',
    'нко',
    'llc',
    'ltd',
    'inc',
    'corp',
    'gmbh',
    'ag ',
    'sa ',
    'llp',
    'plc',
    'company',
    'consortium',
    'консорциум',
    'group',
    'studio',
    'agency',
    'solutions',
    'systems',
    'компания',
    'фирма',
    'группа',
    'производств',
    'центр',
    'нотариаль',
    'нотариат',
    'палата',
    'ассоциац',
    'министерств',
    'департамент',
    'комитет',
    'академи',
    'институт',
    'фонд',
    'управлен',
    'контора',
    'бюро',
  ];

  /// Адрес: ru + en ключевые слова (сопоставляются по токенам строк)
  /// и почтовый индекс РФ.
  static const _addressKeywords = {
    'ул',
    'улица',
    'пр',
    'проспект',
    'пер',
    'переулок',
    'наб',
    'набережная',
    'б-р',
    'бульвар',
    'шоссе',
    'ш',
    'д',
    'дом',
    'стр',
    'строение',
    'корпус',
    'каб',
    'офис',
    'этаж',
    'кв',
    'г',
    'город',
    'москва',
    'санкт',
    'индекс',
    'мкр',
    'мкрн',
    'мкр-н',
    'б',
    'пос',
    'ст',
    'тер',
    'проезд',
    'street',
    'st',
    'st.',
    'avenue',
    'ave',
    'ave.',
    'road',
    'rd',
    'rd.',
    'blvd',
    'lane',
    'drive',
    'suite',
    'floor',
    'apt',
    'building',
    'office',
    'city',
  };

  /// Режим работы в конце строки: «9.00 - 17.00 - кроме сб, вс».
  /// Это не адрес — отрезаем и возвращаем в «прочий текст».
  ///
  /// Перед временем обязателен разделитель (пробел/запятая): иначе
  /// «д.6 9.00» отрезался бы вместе с номером дома.
  static final _scheduleRegex = RegExp(
    r'(?:^|[\s,;])[-–—]?\s*\d{1,2}\s*[.:]\s*\d{2}\s*[-–—]+\s*'
    r'\d{1,2}\s*[.:]\s*\d{2}.*$',
  );

  /// Диапазон времени «9.00 - 17.00» — не телефон (хотя цифр достаточно,
  /// чтобы телефонный кандидат засчитал его номером).
  static final _timeRangeRegex = RegExp(
    r'\d{1,2}\s*[.:]\s*\d{2}\s*[-–—]+\s*\d{1,2}\s*[.:]\s*\d{2}',
  );

  /// Режим работы без двоеточий: «900-1100». Отличаем от телефона только
  /// по словам «кроме/часы/приём/обед/выходные» в той же строке.
  static final _compactTimeRangeRegex = RegExp(r'^\d{3,4}\s*[-–—]\s*\d{4}$');

  static final _scheduleWordsRegex = RegExp(
    r'кроме|часы|при[её]м|обед|выходн',
    caseSensitive: false,
  );

  // ------------------------------------------------------------------- публичное

  /// Разбирает текст OCR в черновик карточки.
  /// [ocrLines] — построчный результат OCR (если есть, используется
  /// вместо разбиения [rawText], т.к. сохраняет порядок чтения).
  ParsedCard parse(String rawText,
      {List<String>? ocrLines, bool containsCyrillic = false}) {
    final warnings = <String>[];

    final lines = _mergeSplitCaps((ocrLines != null && ocrLines.isNotEmpty)
        ? ocrLines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList()
        : rawText
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList());

    if (lines.isEmpty) {
      return ParsedCard(
        card: _emptyDraft(),
        warnings: const ['OCR не вернул текст — заполните карточку вручную'],
        unmatchedLines: const [],
      );
    }

    // Кириллица поддерживается штатно (Tesseract rus+eng), поэтому
    // отдельное предупреждение о ней пользователю не показываем.

    // «рабочая копия» строк: изъятые поля заменяются на пустоту,
    // чтобы они не участвовали дальше как кандидаты на имя/компанию.
    final rest = List<String>.from(lines);

    // 1. Email -----------------------------------------------------------------
    String email = '';
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // OCR часто ставит пробел перед доменом («user@yandex. ry»).
      // Ищем e-mail и в «сжатом» варианте строки, где пробелы вокруг
      // точек убраны — иначе адрес молча теряется.
      final m = _emailRegex.firstMatch(line) ??
          _emailRegex.firstMatch(_compactDots(line));
      if (m != null) {
        email = _fixDomain(_cleanTrailing(m.group(0)!));
        _mask(rest, email);
        // Полного совпадения в строке может не быть (вариант с пробелом):
        // маскируем хотя бы локальную часть, чтобы она не стала «именем».
        _mask(rest, '${m.group(0)!.split('@').first}@');
        break;
      }
      final loose = _looseEmailRegex.firstMatch(line) ??
          _looseEmailRegex.firstMatch(_compactDots(line));
      if (loose != null) {
        final repaired = _repairEmail(loose.group(0)!);
        if (repaired != null) {
          email = repaired;
          _mask(rest, '${loose.group(0)!.split('@').first}@');
          break;
        }
      }
    }

    // 2. Телефон ----------------------------------------------------------------
    String phone = '';
    String phoneRaw = '';
    final phoneCandidates = <_PhoneCandidate>[];
    for (final line in lines) {
      phoneCandidates.addAll(_extractPhones(line));
    }
    final extraPhones = <String>[];
    if (phoneCandidates.isNotEmpty) {
      final best = _chooseBestPhone(phoneCandidates);
      phone = best.normalized;
      phoneRaw = best.raw;
      // Дополнительные номера: все остальные кандидаты (без дублей).
      for (final c in phoneCandidates) {
        if (identical(c, best)) continue;
        final raw = c.raw.trim();
        if (raw.isEmpty) continue;
        final digits = c.raw.replaceAll(RegExp(r'\D'), '');
        if (digits.length < 7) continue;
        if (extraPhones.any((e) => e.replaceAll(RegExp(r'\D'), '') == digits)) {
          continue;
        }
        extraPhones.add(raw);
      }
      // OCR/ML Kit иногда теряют «+» перед кодом страны: «7 (999) …».
      // Нормализованный номер при этом уже +7…, поэтому возвращаем «+»
      // и в отображаемой строке (только когда она начинается с 7).
      if (!phoneRaw.contains('+') &&
          phone.startsWith('+7') &&
          RegExp(r'^7\b').hasMatch(phoneRaw.trim())) {
        phoneRaw = phoneRaw.trim().replaceFirst(RegExp(r'^7'), '+7');
      } else if (phoneRaw.trim().startsWith('+') &&
          !phoneRaw.trim().startsWith('+7') &&
          phone.startsWith('+7')) {
        // «+(999) 123-45-67»: «+» есть, а код страны OCR потерял —
        // нормализация уже восстановила +7, показываем его и в raw.
        final digits = phoneRaw.replaceAll(RegExp(r'\D'), '');
        if (digits.length == 10 && digits.startsWith('9')) {
          phoneRaw = '+7 ${phoneRaw.trim().substring(1).trim()}';
        }
      }
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

    // 3. Telegram ---------------------------------------------------------------
    String telegram = '';
    for (final line in lines) {
      final link = _telegramLinkRegex.firstMatch(line);
      final at = _telegramAtRegex.firstMatch(line);
      final handle = link?.group(1) ?? at?.group(1);
      if (handle == null || handle.isEmpty) continue;
      telegram = '@$handle';
      _mask(rest, link?.group(0) ?? at!.group(0)!);
      break;
    }

    // 4. URL --------------------------------------------------------------------
    // Идём по rest, а не по исходным строкам: e-mail/телефон/Telegram уже
    // замаскированы, иначе ссылка t.me попадала бы в «Сайт».
    String website = '';
    for (final line in rest) {
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
      final parts = <String>[_cleanAddress(rest[addressIdx])];
      rest[addressIdx] = '';
      // Адрес на визитках часто перенесён на две строки: «МО г. Примерск» и
      // «мкр-н Примерный». Связываем соседние строки, чтобы адрес не
      // распался на два разных поля.
      for (var i = addressIdx + 1; i < rest.length && parts.length < 3; i++) {
        final raw = rest[i];
        if (raw.trim().isEmpty) continue;
        // «Телефон:» без номера (номер уже вырезан) — не конец адреса,
        // просто пропускаем подпись.
        if (_isContactLabel(raw)) continue;
        if (!_looksLikeAddressContinuation(raw)) break;
        final (head, tail) = _splitSchedule(raw);
        final cleaned = _cleanAddress(head);
        if (cleaned.isEmpty) break;
        parts.add(cleaned);
        // Остаток строки (режим работы) остаётся в «прочем тексте».
        rest[i] = tail;
      }
      address = parts.where((p) => p.isNotEmpty).join(', ');
    }

    // 5. Должность ---------------------------------------------------------------
    // Берём не первую подходящую строку, а самую «должностную»: на визитке
    // с многострочным названием компании слово «ПАРТНЕРСТВА» из него
    // перехватывало поле раньше настоящей должности.
    String position = '';
    final positionIdx = _bestPositionIndex(rest);
    if (positionIdx >= 0) {
      // Строка могла быть «Имя — Должность»: тогда имя оставляем
      // кандидатом в этой же строке, а должность берём после разделителя.
      final parts = _splitNamePosition(rest[positionIdx]);
      position = parts.positionText.isNotEmpty
          ? _cleanPosition(parts.positionText)
          : _cleanPosition(rest[positionIdx]);
      rest[positionIdx] =
          parts.nameCandidate.isNotEmpty ? parts.nameCandidate : '';
      // Должность часто перенесена на следующую строку: «Управление по
      // работе с государственными» + «и индивидуальными проектами».
      // Между частями может стоять название компании, поэтому смотрим
      // несколько следующих строк, но останавливаемся на контактах/адресе.
      var scanned = 0;
      for (var i = positionIdx + 1; i < rest.length && scanned < 3; i++) {
        final next = rest[i].trim();
        if (next.isEmpty) continue;
        scanned++;
        if (_isPositionContinuation(next)) {
          position = '$position $next'.trim();
          rest[i] = '';
          continue;
        }
        if (_isContactLabel(next) ||
            _looksLikeAddress(next) ||
            _phoneCandidateRegex.hasMatch(next) ||
            _emailRegex.hasMatch(next) ||
            _extractUrl(next, '') != null) {
          break;
        }
        // Строка компании/логотипа — пропускаем и смотрим дальше.
      }
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
    final nameCandidate = _pickBestNameCandidate(
      rest,
      positionIndex: positionIdx >= 0 ? positionIdx : null,
    );
    if (nameCandidate != null) {
      fullName = _stripEdgeJunk(nameCandidate.text);
      rest[nameCandidate.index] = '';
    }

    // 8. Фолбэк для компании: первая осмысленная строка после имени/должности.
    // Строки с цифрами («встретиться после 15:00») компанией не считаем.
    if (company.isEmpty) {
      // Из «человеческих» строк предпочитаем многословную: обрывки логотипа
      // («oNSOR», «BRl», «ORLD») — одно слово, а название компании — обычно
      // два и больше.
      var bestIdx = -1;
      var bestScore = 0;
      for (var i = 0; i < rest.length; i++) {
        final line = rest[i].trim();
        if (line.isEmpty || line == fullName) continue;
        if (!_isHumanLine(line) || RegExp(r'\d').hasMatch(line)) continue;
        final words =
            line.split(RegExp(r'\s+')).where((w) => w.length >= 2).length;
        if (words < 2) continue;
        final score = words * 10 + line.length;
        if (score > bestScore) {
          bestScore = score;
          bestIdx = i;
        }
      }
      if (bestIdx >= 0) {
        company = _cleanCompany(rest[bestIdx]);
        rest[bestIdx] = '';
      } else {
        final fallbackIdx = rest.indexWhere(
          (l) => _isHumanLine(l) && l != fullName && !RegExp(r'\d').hasMatch(l),
        );
        if (fallbackIdx >= 0) {
          company = _cleanCompany(rest[fallbackIdx]);
          rest[fallbackIdx] = '';
        }
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
        extraPhones: extraPhones,
        telegram: telegram,
        email: email,
        website: website,
        address: address,
        otherText: unmatched.join('\n'),
      ),
      warnings: warnings,
      unmatchedLines: unmatched,
    );
  }

  // ----------------------------------------------------------------- телефон

  static List<_PhoneCandidate> _extractPhones(String line) {
    final result = <_PhoneCandidate>[];
    // OCR часто вставляет мусор между «+» и цифрами: «+] (999)»,
    // «+/ 903». Без чистки номер теряет код страны и «+7» пропадает.
    final cleaned = line.replaceAll(RegExp(r'\+\s*[\]\)\|}/\\]+\s*'), '+');
    for (final m in _phoneCandidateRegex.allMatches(cleaned)) {
      final raw = m.group(0)!.trim();
      final digits = raw.replaceAll(RegExp(r'\D'), '');

      if (digits.length < 7 || digits.length > 15) continue;
      // Отбрасываем годы/диапазоны: 2019-2024 и т.п.
      if (RegExp(r'^\d{4}\s*[-–]\s*\d{4}$').hasMatch(raw)) continue;
      // «9.00 - 17.00» — режим работы, не телефон.
      if (_timeRangeRegex.hasMatch(raw)) continue;
      // «900-1100 кроме 9, 6» — часы работы без двоеточий.
      if (_compactTimeRangeRegex.hasMatch(raw) &&
          _scheduleWordsRegex.hasMatch(line)) {
        continue;
      }

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
      // «+» мог появиться из восстановленного «+7», а сам код страны OCR
      // потерял: для 10 цифр, начинающихся с 9, это российский мобильный.
      if (digits.length == 10 && digits.startsWith('9')) return '+7$digits';
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

  /// Исправление очевидной OCR-ошибки в домене: Tesseract регулярно читает
  /// «ru» как «ry» (example-site.ru → example-site.ry). TLD `.ry` не существует,
  /// поэтому замена однозначна; кириллическую «и» в TLD обрабатываем так же.
  static String _fixDomain(String value) => value
      // Пробелы вокруг точек — типичная OCR-ошибка в адресах и доменах.
      .replaceAll(RegExp(r'\s*\.\s*'), '.')
      .replaceFirst(
        RegExp(r'\.(?:ry|rи)(?=$|[/:?#])', caseSensitive: false),
        '.ru',
      );

  /// Убирает пробелы вокруг точек: «yandex. ry» -> «yandex.ry».
  static String _compactDots(String value) =>
      value.replaceAll(RegExp(r'\s*\.\s*'), '.');

  static String? _extractUrl(String line, String alreadyEmail) {
    for (final m in _urlRegex.allMatches(line)) {
      var candidate = _cleanTrailing(m.group(0)!).toLowerCase();
      candidate = _fixDomain(candidate);
      if (candidate.isEmpty) continue;

      // Пропускаем расширения файлов (vizitka.pdf).
      final ext = candidate.split('.').last.split('/').first;
      if (_fileExtensions.contains(ext)) continue;

      // «голый» домен из строки с email (ivan@example.com -> example.com)
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
    // Домен без точки: «EXAMPLEINFO» → https://example.info.
    for (final token in line.split(RegExp(r'\s+'))) {
      final cleaned = _cleanTrailing(token);
      if (cleaned.length < 5) continue;
      if (!RegExp(r'^[A-Za-z0-9\-]+$').hasMatch(cleaned)) continue;
      final repaired = _repairDomain(cleaned);
      if (repaired != null) return 'https://${repaired.toLowerCase()}';
    }
    return null;
  }

  /// Чинит домен без точки: «EXAMPLEINFO» → «EXAMPLE.INFO»,
  /// «EXAMPLEJNFO» (точка + I прочитаны как J) → «EXAMPLE.INFO».
  static String? _repairDomain(String domain) {
    if (domain.contains('.')) return null;
    final upper = domain.toUpperCase();
    if (upper.endsWith('NFO') && domain.length > 4) {
      return '${domain.substring(0, domain.length - 4)}.INFO';
    }
    const tlds = [
      'INFO',
      'COM',
      'ORG',
      'NET',
      'RU',
      'PRO',
      'SITE',
      'ONLINE',
      'TECH',
      'BIZ',
    ];
    for (final tld in tlds) {
      if (upper.length > tld.length + 1 && upper.endsWith(tld)) {
        return '${domain.substring(0, domain.length - tld.length)}.'
            '${domain.substring(domain.length - tld.length)}';
      }
    }
    return null;
  }

  static String? _repairEmail(String raw) {
    final at = raw.indexOf('@');
    if (at <= 0) return null;
    final local = raw.substring(0, at);
    var domain = raw.substring(at + 1).replaceAll(',', '.');
    if (!domain.contains('.')) {
      final repaired = _repairDomain(domain);
      if (repaired == null) return null;
      domain = repaired;
    }
    return '$local@$domain';
  }

  // ------------------------------------------------------------------ адрес/должность/компания

  static bool _looksLikeAddress(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    // 6-значный почтовый индекс РФ — сильный сигнал.
    if (RegExp(r'\b\d{6}\b').hasMatch(t)) return true;
    return _hasAddressMarker(t);
  }

  /// Есть ли в строке адресный маркер («ул.», «д.», «мкр-н», «г. …»).
  static bool _hasAddressMarker(String t) {
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

  /// Продолжение адреса: строка содержит адресный маркер и не похожа на
  /// другую строку визитки (имя, должность, компанию, контакты).
  ///
  /// Нужна, чтобы перенос строки внутри адреса («г. Примерск» / «мкр-н
  /// Примерный») не превращался в два отдельных поля.
  /// Строка-подпись без данных: «Телефон:», «E-mail:», «Сайт:».
  static bool _isContactLabel(String line) {
    final t = line.toLowerCase().replaceAll(RegExp(r'[^a-zа-яё]'), '');
    return t == 'телефон' ||
        t == 'тел' ||
        t == 'факс' ||
        t == 'email' ||
        t == 'mail' ||
        t == 'сайт' ||
        t == 'site' ||
        t == 'адрес' ||
        t == 'www';
  }

  static bool _looksLikeAddressContinuation(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (_emailRegex.hasMatch(t)) return false;
    if (_phoneCandidateRegex.hasMatch(t) && RegExp(r'\d{7,}').hasMatch(t)) {
      return false;
    }
    if (_extractUrl(t, '') != null) return false;
    if (_looksLikePosition(t)) return false;
    if (_looksLikeCompany(t)) return false;
    if (_hasAddressMarker(t)) return true;
    // «УЛИЦА, 10.» — улица с номером дома без маркеров «ул./д.»:
    // на визитках такое написание встречается чаще, чем с сокращениями.
    return RegExp(
      r'^[A-ZА-ЯЁ][A-Za-zА-Яа-яЁё\- ]{2,},\s*\d+[A-Za-zА-Яа-я]?[.,]?$',
    ).hasMatch(t);
  }

  /// Отделяет «режим работы» от адреса: «мкр-н Примерный, д.б 9.00 - 17.00»
  /// -> («мкр-н Примерный, д.б», «9.00 - 17.00»).
  static (String, String) _splitSchedule(String line) {
    final m = _scheduleRegex.firstMatch(line);
    if (m == null) return (line, '');
    return (
      line.substring(0, m.start).trim(),
      line.substring(m.start).trim(),
    );
  }

  /// Адрес после маски контактов: «МО г. Примерск,     Телефон:» —
  /// отрезаем повисшие хвостовые метки («Телефон:», «Тел.», «E-mail»…),
  /// а также ведущие осколки рамки/логотипа перед индексом или улицей
  /// («|9 | 123456, …», «a 123456, …»).
  static String _cleanAddress(String line) {
    var s = line.replaceAll(
      RegExp(
        r'[\s,;:.-]*(?:тел\.?|телефон|факс|e-?mail|сайт|site)[\s:.,;()\-]*$',
        caseSensitive: false,
      ),
      '',
    );
    // Артефакты из логотипа: "0] 123456", "[2 ..." и т.п.
    s = s.replaceAll(RegExp(r'^\s*\d+\s*[\]\)\}]+\s*'), '');
    s = s.replaceAll(RegExp(r'^\s*[\[\]\(\)\{\}]+\s*'), '');
    s = _stripEdgeJunk(s);
    s = _cleanTrailing(s);
    return s.trim();
  }

  /// Срезает ведущие и хвостовые «осколки» рамок/логотипов: токены без
  /// букв и цифр (`|`, `||`, `[]`, `_`), «символ + знак» (`|9`) и одиночные
  /// латинские буквы в начале (`a 123456, …`). Длинные вкрапления внутри
  /// строки не трогаем.
  static String _stripEdgeJunk(String line) {
    var tokens =
        line.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    bool isJunk(String t) {
      // «+7»/«+1» — код страны, а не осколок рамки: раньше это правило
      // срезало плюс, и телефон терял «+7» ещё до парсера.
      if (RegExp(r'^\+\d{1,4}$').hasMatch(t)) return false;
      final hasAlnum = RegExp(r'[0-9A-Za-zА-Яа-яЁё]').hasMatch(t);
      // Токен без единой буквы/цифры («||», «[]», «_», «|») — осколок.
      if (!hasAlnum) return true;
      // «|9», «||9» — символ-лидер + 1 знак: осколок рамки.
      final stripped = t.replaceFirst(RegExp(r'^[^0-9A-Za-zА-Яа-яЁё]+'), '');
      if (stripped.length <= 1 && t.length != stripped.length) return true;
      return false;
    }

    // Ведущий одиночный латинский символ («a», «J», «B») — тоже осколок.
    // Tesseract часто подтягивает букву из логотипа в начало адресной строки.
    bool isLeadJunk(String t) =>
        isJunk(t) ||
        RegExp(r'^[A-Za-z]$').hasMatch(t) ||
        RegExp(r'^[A-Za-z]\]?\]?$').hasMatch(t);

    while (tokens.isNotEmpty && isLeadJunk(tokens.first)) {
      tokens = tokens.sublist(1);
    }
    while (tokens.isNotEmpty && isJunk(tokens.last)) {
      tokens = tokens.sublist(0, tokens.length - 1);
    }
    return tokens.join(' ');
  }

  static bool _looksLikePosition(String line) {
    final lower = line.toLowerCase();
    if (lower.trim().isEmpty) return false;
    for (final k in _positionKeywords) {
      if (lower.contains(k)) return true;
    }
    return false;
  }

  /// Продолжение должности на следующей строке: начинается со строчной
  /// буквы или союза и не содержит контактов/цифр.
  static bool _isPositionContinuation(String line) {
    final t = line.trim();
    if (t.isEmpty || t.length > 80) return false;
    if (RegExp(r'\d').hasMatch(t)) return false;
    if (_emailRegex.hasMatch(t)) return false;
    // Строка с «@» — e-mail/telegram/мусорная OCR-строка, а не должность.
    if (t.contains('@')) return false;
    if (_looksLikeAddress(t)) return false;
    // Обрывок домена/сайта («example-site», «example-site.ru») — не продолжение
    // должности.
    if (RegExp(r'[a-zа-яё0-9\-]+\.[a-zа-яё]{2,}$', caseSensitive: false)
        .hasMatch(t)) {
      return false;
    }
    if (RegExp(r'^[A-Za-z0-9\-]+$').hasMatch(t) && t.contains('-')) {
      return false;
    }
    final first = t[0];
    final lower = first == first.toLowerCase() && first != first.toUpperCase();
    if (lower) return true;
    final low = t.toLowerCase();
    return low.startsWith('и ') ||
        low.startsWith('по ') ||
        low.startsWith('с ') ||
        low.startsWith('для ') ||
        low.startsWith('в ');
  }

  /// Индекс самой вероятной строки с должностью.
  ///
  /// Считаем: ключевое слово найдено (+2), строка из 2+ слов (+2),
  /// одиночное слово КАПСОМ (−1) — так «ПАРТНЕРСТВА» из названия компании
  /// проигрывает «эксперт по коммуникации».
  static int _bestPositionIndex(List<String> lines) {
    var best = -1;
    var bestScore = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || !_looksLikePosition(line)) continue;
      final words =
          line.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      final allCaps = line == line.toUpperCase();
      var score = 2;
      if (words >= 2) score += 2;
      if (allCaps && words == 1) score -= 1;
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
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
    // Строка с e-mail — это контакты, а не название: домен
    // «company.consortium» иначе совпадает с ключевым словом «consortium».
    if (_emailRegex.hasMatch(line)) return false;
    final l = ' ${line.toLowerCase()} ';
    // «кавычки» — типичное написание компании в РФ: ООО «Ромашка»
    if (line.contains('«') || line.contains('»')) return true;
    for (final k in _companyKeywords) {
      if (l.contains(k)) return true;
    }
    return false;
  }

  static String _cleanCompany(String line) {
    var s = _stripEdgeJunk(line.trim());
    s = _cleanTrailing(s);
    return s;
  }

  // ---------------------------------------------------------------------- имя

  static _NameCandidate? _pickBestNameCandidate(
    List<String> rest, {
    int? positionIndex,
  }) {
    _NameCandidate? best;
    var bestScore = 0;
    var bestWords = 0;
    var bestAdjacent = false;

    for (var i = 0; i < rest.length; i++) {
      final line = rest[i].trim();
      if (line.isEmpty) continue;
      // Осколки рамки/логотипа в начале («| Иванов …») не должны снижать
      // оценку: иначе строка ФИО проигрывает адресному обрывку.
      final cleaned = _stripEdgeJunk(line);
      if (cleaned.isEmpty) continue;
      final score = _scoreName(cleaned);
      final words =
          cleaned.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      // Ранжирование: score → число слов → близость к должности → порядок.
      // Число слов важно для «АННА ИВАНОВА» против мусорного
      // односложного «RyookaE» рядом с должностью.
      final adjacent = positionIndex != null && (i - positionIndex).abs() == 1;
      final better = score > bestScore ||
          (score == bestScore &&
              score > 0 &&
              (words > bestWords ||
                  (words == bestWords && adjacent && !bestAdjacent)));
      if (better) {
        bestScore = score;
        bestWords = words;
        bestAdjacent = adjacent;
        best = _NameCandidate(index: i, text: cleaned);
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
  /// Склеивает соседние строки из одного слова КАПСОМ: на визитках ФИО и
  /// название компании часто разнесены по строкам («ИВАН» / «ПЕТРОВ»,
  /// «ЭНЕРГИЯ» / «ВРЕМЕНИ»). По отдельности каждая строка выглядит как
  /// логотип и в поля не попадает.
  static List<String> _mergeSplitCaps(List<String> lines) {
    final out = <String>[];
    for (final raw in lines) {
      // Осколок рамки/логотипа в начале («| ЭНЕРГИЯ») ломал выравнивание
      // пар: первая пара не склеивалась, и получалось «ВРЕМЕНИ ИВАН».
      final line = _stripEdgeJunk(raw.trim());
      if (line.isEmpty) continue;
      if (out.isNotEmpty &&
          _isSingleCapsWord(out.last) &&
          _isSingleCapsWord(line) &&
          !_looksLikePosition(out.last) &&
          !_looksLikePosition(line) &&
          !_looksLikeCompany(out.last) &&
          !_looksLikeCompany(line)) {
        out[out.length - 1] = '${out.last} $line';
      } else {
        out.add(line);
      }
    }
    return out;
  }

  static bool _isSingleCapsWord(String line) {
    final t = line.trim();
    if (t.length < 3 || t.length > 24) return false;
    if (!RegExp(r'^[A-ZА-ЯЁ][A-ZА-ЯЁ\-]*$').hasMatch(t)) return false;
    return t == t.toUpperCase();
  }

  static int _scoreName(String line) {
    if (_looksLikeAddress(line)) return 0;
    if (_emailRegex.hasMatch(line)) return 0;
    // «MO. Примерск,» / «Г. Город,» — адресный обрывок, а не имя: первое
    // слово — 2–3-буквенное сокращение с точкой или строка кончается
    // запятой. Инициалы человека — одна буква («И. Иванов»), их не трогаем.
    if (RegExp(r'^[A-ZА-ЯЁ]{2,3}\.').hasMatch(line.trim())) return 0;
    if (line.trim().endsWith(',')) return 1;
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

    final words =
        line.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
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
    // Одно слово КАПСОМ — это вывеска/логотип («ПРИМЕР», «РОМАШКА»),
    // а не имя человека. Имена на визитках пишут с заглавной, а не целиком
    // заглавными; иначе компания уезжает в поле «Имя».
    if (words.length == 1 && words.first == words.first.toUpperCase()) {
      return 0;
    }
    if (words.every((w) => w == w.toUpperCase())) {
      // Несколько слов КАПСОМ — ФИО/название, но не выше смешанного
      // написания: «ONSOR BRL» (обрывки логотипа) не должен обгонять
      // «Ivan Petrov».
      return 2;
    }

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
    // Строка с «@» — e-mail/telegram/мусорная OCR-строка, а не должность.
    if (t.contains('@')) return false;
    if (_looksLikeAddress(t)) return false;
    if (_looksLikePosition(t)) return false;
    if (_phoneCandidateRegex.hasMatch(t) && RegExp(r'\d{7,}').hasMatch(t)) {
      return false;
    }
    return _scoreName(t) >= 1 || t.split(' ').length <= 6;
  }

  /// Убирает висящие в конце пунктуацию и скобки: «ivan@example.com.»
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
