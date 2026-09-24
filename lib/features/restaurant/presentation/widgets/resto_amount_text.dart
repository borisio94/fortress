import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';

/// Découpe une chaîne DÉJÀ FORMATÉE autour du symbole de devise.
///
/// Rend `(avant, symbole, après)`. Le symbole reste là où la locale l'a mis —
/// avant ou après le nombre — puisqu'on coupe la chaîne, on ne la recompose
/// pas. `null` si le symbole est absent (devise explicite, symbole vide) :
/// l'appelant affiche alors la chaîne entière.
({String before, String symbol, String after})? splitAmount(
    String formatted, String symbol) {
  if (symbol.isEmpty) return null;
  final i = formatted.indexOf(symbol);
  if (i < 0) return null;
  return (
    before: formatted.substring(0, i),
    symbol: symbol,
    after: formatted.substring(i + symbol.length),
  );
}

/// UN MONTANT, chiffre et unité séparés : « 2 500 » dans [style], « FCFA » en
/// 11 px atténué à côté.
///
/// UNE SEULE FAÇON DE COUPER UN MONTANT dans le module restaurant — Commandes
/// et Menu l'emploient tous deux. La chaîne vient TOUJOURS de
/// `CurrencyFormatter.format` : aucun montant n'est recomposé à la main.
class RestoAmountText extends StatelessWidget {
  final double value;

  /// Style du NOMBRE. L'unité, elle, est toujours `caption` en
  /// `textSecondary`.
  final TextStyle style;

  const RestoAmountText(this.value, {super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    final s = CurrencyFormatter.format(value);
    final parts = splitAmount(s, CurrencyFormatter.currentSymbol);
    if (parts == null) {
      return Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    final unit = AppTextStyles.caption.copyWith(color: AppColors.textSecondary);
    return Text.rich(
      TextSpan(children: [
        if (parts.before.isNotEmpty) TextSpan(text: parts.before, style: style),
        TextSpan(text: parts.symbol, style: unit),
        if (parts.after.isNotEmpty) TextSpan(text: parts.after, style: style),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
