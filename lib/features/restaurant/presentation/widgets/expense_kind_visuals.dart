import 'package:flutter/material.dart';

import '../../domain/entities/daily_expense.dart';

/// L'ICÔNE d'une catégorie de dépense du jour.
///
/// Séparée de `daily_expense.dart` pour que le domaine reste du Dart pur
/// (26/09/2026) : le domaine dit la catégorie (sa clé, son libellé, ses
/// règles), la présentation dit son icône. Rien n'est stocké : une dépense se
/// sérialise par la clé de sa catégorie.
extension ExpenseKindVisuals on ExpenseKind {
  IconData get icon => switch (this) {
        ExpenseKind.achatMarche => Icons.shopping_basket_outlined,
        ExpenseKind.electricite => Icons.bolt_outlined,
        ExpenseKind.gaz => Icons.local_fire_department_outlined,
        ExpenseKind.eau => Icons.water_drop_outlined,
        ExpenseKind.transport => Icons.local_taxi_outlined,
        ExpenseKind.entretien => Icons.cleaning_services_outlined,
        ExpenseKind.personnel => Icons.person_add_alt_outlined,
        ExpenseKind.consigneRendue => Icons.assignment_return_outlined,
        ExpenseKind.autre => Icons.more_horiz_rounded,
      };
}
