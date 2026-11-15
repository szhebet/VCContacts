import 'ocr_service.dart';

/// Выбор лучшего результата распознавания одного и того же текстового блока
/// среди нескольких вариантов предобработки (базовый, резкий, бинаризованный).
///
/// Идея — «кворум заключений»: один движок на разных препроцессингах ошибается
/// по-разному. Вариант, который (а) уверен в себе и (б) согласуется с
/// большинством остальных, надёжнее любого одиночного прохода.
///
/// Вся логика — чистые строки и числа, без нативных библиотек: тестируется
/// на хосте.
class BlockConsensus {
  const BlockConsensus({
    this.confidenceWeight = 0.6,
    this.agreementWeight = 0.4,
    this.minAgreement = 0.5,
  });

  /// Вес средней уверенности варианта в итоговой оценке (0..1).
  final double confidenceWeight;

  /// Вес согласия варианта с кворумом в итоговой оценке (0..1).
  final double agreementWeight;

  /// Минимальная доля согласия, ниже которой вариант считается «одиночкой»
  /// и не может победить, даже если очень уверен.
  final double minAgreement;

  /// Оценка варианта: `confidenceWeight × уверенность +
  /// agreementWeight × согласие с кворумом`. [agreement] — доля голосов
  /// (0..1), посчитанная по токенам.
  double score(OcrResult r, double agreement) =>
      confidenceWeight * r.confidence.clamp(0.0, 1.0) +
      agreementWeight * agreement.clamp(0.0, 1.0);

  /// Выбирает лучший вариант по уверенности и согласию с большинством.
  ///
  /// Возвращает null, если список пуст или все варианты пусты. При равенстве
  /// оценок предпочитается более полный текст (больше осмысленных символов).
  OcrResult? pickBest(List<OcrResult> candidates) {
    final nonEmpty = candidates.where((r) => !r.isEmpty).toList();
    if (nonEmpty.isEmpty) return null;
    if (nonEmpty.length == 1) return nonEmpty.first;

    OcrResult? best;
    double bestScore = -1;
    for (final r in nonEmpty) {
      final agreement = _agreementWithOthers(r, nonEmpty);
      // Одиночку (нет согласия хотя бы с одним другим) считаем
      // подозрительной: штрафуем ниже порога.
      final effective = agreement < minAgreement ? 0.0 : agreement;
      final s = score(r, effective);
      if (best == null ||
          s > bestScore ||
          (s == bestScore && _meaningfulLength(r) > _meaningfulLength(best))) {
        best = r;
        bestScore = s;
      }
    }
    return best;
  }

  /// Средняя доля согласия [r] с каждым другим непустым вариантом.
  double _agreementWithOthers(OcrResult r, List<OcrResult> all) {
    var sum = 0.0;
    var n = 0;
    for (final other in all) {
      if (identical(other, r)) continue;
      sum += agreement(r, other);
      n++;
    }
    return n == 0 ? 1.0 : sum / n;
  }

  /// Доля токенов [a], которые встречаются в [b] (без регистра). 0..1.
  static double agreement(OcrResult a, OcrResult b) {
    final ta = _tokens(a.fullText);
    final tb = _tokens(b.fullText).toSet();
    if (ta.isEmpty) return 0.0;
    final hit = ta.where(tb.contains).length;
    return hit / ta.length;
  }

  /// Токены: слова и числа длиной ≥ 2 значимых символа (одиночные знаки
  /// и осколки рамок в кворуме не участвуют).
  static List<String> _tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^0-9a-zа-яё]+'))
      .where((t) => t.length >= 2)
      .toList(growable: false);

  static int _meaningfulLength(OcrResult r) =>
      _tokens(r.fullText).join().length;
}
