/// Части ФИО, выделенные эвристикой для сортировки списка.
class PersonNameParts {
  const PersonNameParts({this.surname = '', this.name = ''});

  final String surname;
  final String name;
}

/// Разбирает строку ФИО на фамилию и имя.
///
/// На визитках порядок не фиксирован: «Петров Иван», «Иван Петров»,
/// «Petrov Ivan». Точное определение фамилии без словаря невозможно,
/// поэтому используем окончания и позицию отчества:
///
///  * три и более слов — отчество в конце означает «Фамилия Имя Отчество»,
///    иначе считаем «First Middle Last»;
///  * два слова — слово с характерным фамильным окончанием становится
///    фамилией; если оба/ни одно не похожи, по умолчанию фамилия вторая
///    («Иван Петров», «John Smith»).
PersonNameParts splitPersonName(String fullName) {
  final words = fullName
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const PersonNameParts();
  if (words.length == 1) return PersonNameParts(surname: words.first);

  if (words.length >= 3) {
    if (_isPatronymic(words[2])) {
      return PersonNameParts(surname: words[0], name: words[1]);
    }
    if (_isPatronymic(words[1])) {
      return PersonNameParts(surname: words[0], name: words[2]);
    }
    return PersonNameParts(surname: words.last, name: words.first);
  }

  final first = words[0];
  final second = words[1];
  final firstSurname = _looksLikeSurname(first);
  final secondSurname = _looksLikeSurname(second);
  if (secondSurname && !firstSurname) {
    return PersonNameParts(surname: second, name: first);
  }
  if (firstSurname && !secondSurname) {
    return PersonNameParts(surname: first, name: second);
  }
  return PersonNameParts(surname: second, name: first);
}

const _patronymicSuffixes = [
  'ович',
  'евич',
  'ьевич',
  'овна',
  'евна',
  'ьевна',
  'ична',
  'инична',
  'кызы',
  'оглы',
];

const _surnameSuffixes = [
  'ов',
  'ев',
  'ёв',
  'ин',
  'ын',
  'ский',
  'ская',
  'цкий',
  'цкая',
  'ой',
  'ая',
  'яя',
  'ко',
  'ук',
  'юк',
  'ич',
  'ова',
  'ева',
  'ёва',
  'ина',
  'ына',
];

bool _isPatronymic(String word) {
  final w = word.toLowerCase();
  return _patronymicSuffixes.any(w.endsWith);
}

bool _looksLikeSurname(String word) {
  final w = word.toLowerCase();
  return _surnameSuffixes.any(w.endsWith);
}
