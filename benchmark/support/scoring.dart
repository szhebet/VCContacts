/// Общий скоринг полей для замерных стендов (полный кадр и режим областей).
///
/// Сравнение терпимо к регистру, ё/е, форматированию телефона и словоизменению:
/// «консорциум» и «консорциума», «коммуникациям» и «коммуникации» — одно поле.
library;

bool fieldMatch(String field, String expected, String actual) {
  if (actual.trim().isEmpty) return false;
  switch (field) {
    case 'phone':
      return phoneMatch(expected, actual);
    case 'email':
      return emailMatch(expected, actual);
    case 'website':
      return websiteMatch(expected, actual);
    case 'address':
      return tokenCoverage(expected, actual, minCoverage: 0.7);
    case 'name':
    case 'position':
    case 'company':
      return textMatch(expected, actual);
    default:
      return norm(expected) == norm(actual);
  }
}

bool textMatch(String expected, String actual) {
  final e = norm(expected);
  final a = norm(actual);
  if (e.isEmpty || a.isEmpty) return false;
  if (e == a || a.contains(e) || e.contains(a)) return true;

  final et = tokens(expected);
  final at = tokens(actual);
  if (et.isEmpty || at.isEmpty) return false;
  var matched = 0;
  for (final token in et) {
    if (at.any((candidate) => sameStem(token, candidate))) matched++;
  }
  return matched / et.length >= 0.999;
}

/// Сравнение слов с учётом словоизменения: общий префикс не короче
/// 5 символов, чтобы не склеивать разные короткие слова.
bool sameStem(String a, String b) {
  if (a == b) return true;
  final shortest = a.length < b.length ? a.length : b.length;
  if (shortest < 5) return false;
  final stem = shortest >= 6 ? 6 : 5;
  return a.substring(0, stem) == b.substring(0, stem);
}

bool tokenCoverage(String expected, String actual, {double minCoverage = 0.7}) {
  final et = tokens(expected, minLength: 2);
  final at = tokens(actual, minLength: 2);
  if (et.isEmpty || at.isEmpty) return false;
  final overlap = et.intersection(at).length;
  return overlap / et.length >= minCoverage;
}

bool phoneMatch(String expected, String actual) {
  final e = digits(expected);
  final a = digits(actual);
  if (e.length < 7 || a.length < 7) return false;
  // Сравниваем последние 10 цифр: код страны (7/8) и форматирование не
  // должны влиять на оценку распознавания.
  if (e.length < 10 || a.length < 10) return e == a;
  return e.substring(e.length - 10) == a.substring(a.length - 10);
}

bool emailMatch(String expected, String actual) {
  final e = normAddress(expected);
  final a = normAddress(actual);
  return e == a || a.contains(e) || e.contains(a);
}

bool websiteMatch(String expected, String actual) {
  final e = normSite(expected);
  final a = normSite(actual);
  if (e.isEmpty || a.isEmpty) return false;
  return e == a || a.contains(e) || e.contains(a);
}

String norm(String s) => s
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[^a-zа-я0-9]+'), ' ')
    .trim();

Set<String> tokens(String s, {int minLength = 3}) => norm(s)
    .split(RegExp(r'\s+'))
    .where((t) => t.length >= minLength)
    .toSet();

String digits(String s) => s.replaceAll(RegExp(r'\D'), '');

String normAddress(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'^mailto:'), '')
    .replaceAll(RegExp(r'[\s.,;]+$'), '');

String normSite(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'^https?://'), '')
    .replaceAll(RegExp(r'^www\.'), '')
    .replaceAll(RegExp(r'[/.,;]+$'), '');
