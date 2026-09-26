/// COMMENT S'EST TERMINÉ UN SERVICE — règles pures (hotfix_165).
///
/// Un pointage de sortie ne dit pas la même chose selon l'heure : parti à
/// l'heure de fermeture, c'est une journée normale ; parti avant, il manque une
/// explication ; parti après, l'établissement doit de l'argent. Ces trois cas
/// commandent trois gestes différents, et la frontière entre eux est ici —
/// isolée de Hive, de Supabase et de Flutter, parce que c'est elle qui décide
/// de ce qu'un employé touche à la fin du mois.
library;

/// Les trois façons de finir un service.
enum ShiftEnding {
  /// Parti à l'heure prévue, à la tolérance près. Rien à trancher.
  onTime,

  /// Parti AVANT l'heure de fermeture : une excuse est attendue, et le gérant
  /// dira si elle tient.
  early,

  /// Parti APRÈS l'heure de fermeture : des heures supplémentaires sont dues.
  overtime,
}

/// Où en est une excuse de départ anticipé.
enum ExcuseStatus {
  /// Pas de départ anticipé, ou aucune excuse fournie à la badgeuse.
  none,

  /// Excuse donnée, le gérant ne l'a pas encore jugée.
  pending,

  /// Le gérant l'a acceptée : le départ anticipé est justifié.
  accepted,

  /// Le gérant l'a refusée. L'app ne retient RIEN toute seule — elle le
  /// signale, et c'est le gérant qui décide d'une retenue sur la fiche de paie.
  /// Une sanction automatique sur un motif jugé à la main serait un piège.
  refused,
}

/// Ce qu'on fait des heures supplémentaires d'un service.
enum OvertimeSettlement {
  /// À trancher : ni versées, ni portées sur la paie.
  pending,

  /// Payées tout de suite, de la main à la main.
  paidNow,

  /// Reportées sur la paie du mois — elles s'ajouteront aux primes de la
  /// fiche, avec la mention du nombre d'heures.
  onPayslip,
}

extension ExcuseStatusX on ExcuseStatus {
  String get key => switch (this) {
        ExcuseStatus.none => 'none',
        ExcuseStatus.pending => 'pending',
        ExcuseStatus.accepted => 'accepted',
        ExcuseStatus.refused => 'refused',
      };

  String get label => switch (this) {
        ExcuseStatus.none => 'Sans excuse',
        ExcuseStatus.pending => 'Excuse à juger',
        ExcuseStatus.accepted => 'Excuse acceptée',
        ExcuseStatus.refused => 'Excuse refusée',
      };

  /// Une clé inconnue (valeur écrite par une version ultérieure) retombe sur
  /// `none` plutôt que de rendre le pointage illisible.
  static ExcuseStatus fromKey(String? raw) => switch (raw?.trim()) {
        'pending' => ExcuseStatus.pending,
        'accepted' => ExcuseStatus.accepted,
        'refused' => ExcuseStatus.refused,
        _ => ExcuseStatus.none,
      };
}

extension OvertimeSettlementX on OvertimeSettlement {
  String get key => switch (this) {
        OvertimeSettlement.pending => 'pending',
        OvertimeSettlement.paidNow => 'paid_now',
        OvertimeSettlement.onPayslip => 'on_payslip',
      };

  String get label => switch (this) {
        OvertimeSettlement.pending => 'À trancher',
        OvertimeSettlement.paidNow => 'Payées de suite',
        OvertimeSettlement.onPayslip => 'Sur la paie du mois',
      };

  static OvertimeSettlement fromKey(String? raw) => switch (raw?.trim()) {
        'paid_now' => OvertimeSettlement.paidNow,
        'on_payslip' => OvertimeSettlement.onPayslip,
        _ => OvertimeSettlement.pending,
      };
}

/// Le verdict d'un service : à l'heure, trop tôt, ou en heures supplémentaires.
class ShiftEvaluation {
  final ShiftEnding ending;

  /// Minutes manquantes avant l'heure de fermeture (0 si parti à l'heure ou
  /// après).
  final int earlyMinutes;

  /// Minutes travaillées au-delà de l'heure de fermeture (0 sinon).
  final int overtimeMinutes;

  const ShiftEvaluation({
    required this.ending,
    this.earlyMinutes = 0,
    this.overtimeMinutes = 0,
  });

  static const ShiftEvaluation onTime =
      ShiftEvaluation(ending: ShiftEnding.onTime);

  bool get isEarly => ending == ShiftEnding.early;
  bool get isOvertime => ending == ShiftEnding.overtime;

  /// TOLÉRANCE, en minutes, de part et d'autre de l'heure de fermeture.
  ///
  /// Sans elle, partir trois minutes avant réclamerait une excuse et rester
  /// six minutes de plus créerait une dette de 100 F : le gérant aurait
  /// vingt décisions à prendre chaque soir et cesserait de s'en servir au bout
  /// d'une semaine. Le quart d'heure est ce que tout le monde considère
  /// spontanément comme « à l'heure ».
  static const int graceMinutes = 15;

  /// Verdict d'un service — la règle, telle quelle.
  ///
  /// [scheduledEnd] nul signifie « aucune heure de fermeture réglée » : on ne
  /// peut alors juger de rien, et tout service est à l'heure. C'est
  /// volontaire — un établissement qui n'a pas renseigné son horaire ne doit
  /// pas voir apparaître des heures supplémentaires qu'il n'a jamais promises.
  static ShiftEvaluation of({
    required DateTime clockOut,
    DateTime? scheduledEnd,
    int grace = graceMinutes,
  }) {
    if (scheduledEnd == null) return onTime;
    final diff = clockOut.difference(scheduledEnd).inMinutes;
    if (diff.abs() <= grace) return onTime;
    if (diff < 0) {
      return ShiftEvaluation(
          ending: ShiftEnding.early, earlyMinutes: -diff);
    }
    return ShiftEvaluation(
        ending: ShiftEnding.overtime, overtimeMinutes: diff);
  }

  /// Heure de fermeture d'un service commencé à [clockIn].
  ///
  /// Retourne `null` si aucun horaire n'est réglé. Un horaire ANTÉRIEUR à
  /// l'entrée est reporté au lendemain : un service qui démarre à 18 h dans un
  /// restaurant qui ferme à 2 h du matin finit bien le lendemain, et sans ce
  /// report il serait compté comme seize heures de retard.
  static DateTime? scheduledEndFor(DateTime clockIn, String? closingTime) {
    final hhmm = parseHhmm(closingTime);
    if (hhmm == null) return null;
    var end = DateTime(clockIn.year, clockIn.month, clockIn.day,
        hhmm.$1, hhmm.$2);
    if (!end.isAfter(clockIn)) end = end.add(const Duration(days: 1));
    return end;
  }

  /// « 22:00 » → (22, 0). `null` si le texte n'est pas une heure valable —
  /// réglage jamais saisi, ou saisi de travers.
  static (int, int)? parseHhmm(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2})[:hH](\d{1,2})$').firstMatch(s);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!) ?? -1;
    final min = int.tryParse(m.group(2)!) ?? -1;
    if (h < 0 || h > 23 || min < 0 || min > 59) return null;
    return (h, min);
  }

  static String formatHhmm(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}';

  /// MONTANT DES HEURES SUPPLÉMENTAIRES — au prorata des minutes.
  ///
  /// Payer à l'heure entamée serait plus généreux mais imprévisible : quatre
  /// soirs à dix minutes de dépassement coûteraient quatre heures. Le prorata
  /// donne un montant que le gérant comme l'employé peuvent refaire de tête.
  static int overtimePay({required int minutes, required int hourlyRate}) {
    if (minutes <= 0 || hourlyRate <= 0) return 0;
    return ((minutes * hourlyRate) / 60).round();
  }
}
