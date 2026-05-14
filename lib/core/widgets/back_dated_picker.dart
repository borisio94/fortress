import 'package:flutter/material.dart';

// ═════════════════════════════════════════════════════════════════════════════
// `pickBackDate` — helper unifié pour les sélecteurs de date qui doivent
// permettre l'antidatage (= saisie d'une date passée). Cas d'usage :
// un nouveau marchand qui s'inscrit veut numériser son historique des
// ventes / dépenses / transferts / arrivages / incidents / versements
// faits AVANT son inscription à Fortress.
//
// Bornes par défaut :
//   • firstDate  = DateTime(2020, 1, 1)  — couvre largement les besoins
//     d'historisation pour une boutique standard.
//   • lastDate   = aujourd'hui + 1 jour  — la date du jour reste autorisée
//     (clôture en fin de journée), mais on bloque les dates futures qui
//     n'ont aucun sens pour une vente/dépense déjà effectuée.
//
// Si le caller a besoin de permettre une date future (ex: date de livraison
// programmée), utiliser `showDatePicker` directement avec un `lastDate`
// plus loin. Ce helper cible **strictement** l'antidatage.
//
// Retourne `null` si l'utilisateur ferme le picker sans sélection.
// ═════════════════════════════════════════════════════════════════════════════

Future<DateTime?> pickBackDate({
  required BuildContext context,
  required DateTime initial,
  String? helpText,
}) async {
  final now = DateTime.now();
  final firstDate = DateTime(2020, 1, 1);
  // Clamp `initial` dans les bornes pour éviter assertion failure si l'appelant
  // passe une valeur hors plage (ex: date legacy 2018).
  final safeInitial = initial.isBefore(firstDate)
      ? firstDate
      : initial.isAfter(now.add(const Duration(days: 1)))
          ? now
          : initial;
  return showDatePicker(
    context:      context,
    initialDate:  safeInitial,
    firstDate:    firstDate,
    lastDate:     now.add(const Duration(days: 1)),
    helpText:     helpText ?? 'Sélectionner une date',
    cancelText:   'Annuler',
    confirmText:  'OK',
  );
}

/// Variante qui ouvre date + heure consécutivement (showDatePicker puis
/// showTimePicker). Utile pour `Sale.scheduledAt` et `Sale.completedAt`
/// où l'heure compte (ex: tri par moment de la journée).
Future<DateTime?> pickBackDateTime({
  required BuildContext context,
  required DateTime initial,
  String? helpText,
}) async {
  final d = await pickBackDate(
    context: context, initial: initial, helpText: helpText);
  if (d == null) return null;
  if (!context.mounted) return null;
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
    cancelText: 'Annuler',
    confirmText: 'OK',
  );
  if (t == null) return null;
  return DateTime(d.year, d.month, d.day, t.hour, t.minute);
}
