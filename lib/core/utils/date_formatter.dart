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
}
