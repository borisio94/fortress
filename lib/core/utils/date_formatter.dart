import 'package:intl/intl.dart';

class DateFormatter {
  static String toDisplay(DateTime date, {String locale = 'fr'}) =>
      DateFormat('dd/MM/yyyy', locale).format(date);

  static String toDisplayWithTime(DateTime date, {String locale = 'fr'}) =>
      DateFormat('dd/MM/yyyy HH:mm', locale).format(date);

  static String toApi(DateTime date) =>
      DateFormat('yyyy-MM-ddTHH:mm:ss').format(date.toUtc());

  static String toShortMonth(DateTime date, {String locale = 'fr'}) =>
      DateFormat('MMM yyyy', locale).format(date);

  /// Date numérique `jj/MM/aaaa` par padding manuel — sans dépendance
  /// `intl`/locale (sûr même si les données de locale ne sont pas
  /// initialisées). Sortie strictement identique aux anciennes
  /// implémentations privées `_fmtDate`/`_fmt` éparpillées.
  static String dayMonthYear(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';
}
