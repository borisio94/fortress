/// BRIQUES COMMUNES AUX ÉCRANS EN ONGLETS DU MODULE RESTAURANT.
///
/// Extraites du hub Finances le 21/09/2026, quand Stock en est sorti pour
/// prendre sa propre entrée de menu. Les deux écrans affichent les mêmes
/// listes de lignes, les mêmes pastilles d'état et le même bandeau de
/// rattrapage : les dupliquer aurait garanti qu'ils divergent au premier
/// ajustement.
///
/// Rien n'a changé de comportement au passage — seuls les noms sont devenus
/// publics, puisqu'ils franchissent désormais une frontière de fichier.
library;

import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import 'resto_surfaces.dart';

abstract class RestoTabState<T extends StatefulWidget> extends State<T> {
  late final OnDataChanged _listener;

  /// Table Supabase à écouter pour rafraîchir la liste.
  String get table;
  String get shopId;

  @override
  void initState() {
    super.initState();
    _listener = (t, sid) {
      if (!mounted) return;
      if (t != table) return;
      if (sid != shopId && sid != '_all') return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  /// Bouton d'ajout en tête de liste.
  ///
  /// ALIGNÉ À GAUCHE, comme le titre, le sous-titre et les pastilles. Il était
  /// à droite : sur un écran dont tout le reste commence au même bord, un seul
  /// élément à l'opposé fait chercher l'œil sans rien apprendre.
  Widget headerButton(String label, VoidCallback onTap) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: FilledButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(label),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          ),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  Onglet INGRÉDIENTS
// ═══════════════════════════════════════════════════════════════════════

class RestoCard extends StatelessWidget {
  final Widget child;

  /// `null` = carte INERTE, sans effet au toucher.
  ///
  /// Une carte qui ouvre un formulaire au moindre contact déclenche des
  /// modifications non voulues quand on vise un bouton et qu'on le manque.
  /// Les listes dont chaque action a son propre bouton n'en passent donc pas.
  final VoidCallback? onTap;

  /// Bordure d'accentuation — sert à signaler une ligne qui demande
  /// l'attention. `null` = bordure discrète habituelle.
  final Color? borderColor;

  /// Teinte de fond superposée au verre. Volontairement séparée de
  /// [borderColor] : une bordure seule passe inaperçue dans une longue liste,
  /// un fond seul ne dit pas où s'arrête la ligne.
  final Color? background;

  const RestoCard({
    super.key,
    required this.child,
    this.onTap,
    this.borderColor,
    this.background,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Material(
      color: background ?? restoGlassFill(context),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: borderColor ?? sem.borderSubtle,
                width: borderColor == null ? 1 : 1.5),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Pastille colorée (statut : partagé / stock bas / mode).

class RestoPill extends StatelessWidget {
  final String label;
  final Color color;
  const RestoPill(this.label, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: AppTextStyles.micro
                .copyWith(color: color, fontWeight: FontWeight.w700)),
      );
}

/// Mention d'EXCEPTION posée à côté d'un nom, en TEXTE — sans fond ni bordure.
///
/// Remplace [RestoPill] là où l'écran a été épuré (le Stock, 24/09/2026) : une
/// pastille teintée répétée sur une liste devient un mur de couleur, et la
/// couleur ne distingue plus rien.
///
/// ─── RÈGLE : SEULES LES ALERTES GARDENT LEUR COULEUR ───────────────────────
///
/// C'est la généralisation de « le token suit son fond » (cf. le Menu,
/// `warningText` sur surface claire, `warning` sur voile sombre). Sans pastille
/// pour la porter, une couleur doit tenir SEULE en texte de 10 px — et la
/// plupart n'y tiennent pas :
///
///   • ALERTE (quelque chose appelle une action) → la variante TEXTE du token
///     sémantique : `dangerText` (stock bas), `warningText` (coût manquant).
///     `danger` ne fait que 3,76:1 sur blanc et `warning` 2,15:1.
///   • INFORMATION (une propriété, pas un problème) → `textSecondary`. La
///     primaire n'est PAS une couleur de texte fiable : en clair elle passe
///     sous 4,5:1 sur cinq palettes sur huit (Ocean 2,77, Emerald 2,54, Sunset
///     2,80, Amber 3,19, Rose 3,53), et Midnight en sombre ne fait que 1,93:1.
///     Il n'existe pas de token « primaire lisible en texte » : `brandText`
///     vaut la primaire en clair.
///
/// Les deux constructeurs rendent la règle impossible à contourner à l'appel :
/// une information ne peut pas recevoir de couleur.
class RestoInlineTag extends StatelessWidget {
  final String label;

  /// Couleur d'ALERTE — toujours une variante `*Text`. `null` : information.
  final Color? alertColor;

  /// Une propriété, pas un problème (« Quantité connue », « partagé »).
  const RestoInlineTag.info(this.label, {super.key}) : alertColor = null;

  /// Quelque chose appelle une action. Passer la variante TEXTE du token :
  /// `sem.dangerText`, `sem.warningText`.
  const RestoInlineTag.alert(this.label, Color textColor, {super.key})
      : alertColor = textColor;

  @override
  Widget build(BuildContext context) => Text(label,
      maxLines: 1,
      style: AppTextStyles.microBold
          .copyWith(color: alertColor ?? AppColors.textSecondary));
}

/// Ce qu'une réception d'ingrédient produit.

class RestoMiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const RestoMiniStat(
      {super.key,
      required this.label,
      required this.value,
      required this.color});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: restoGlassFill(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.captionHint),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyBold.copyWith(color: color)),
        ],
      ),
    );
  }
}
// L'onglet « Consignes » a été SUPPRIMÉ (2026-08-05) : l'établissement ne
// prête aucun contenant. Le service `BottleDepositService` et la table
// `bottle_deposits` subsistent, inertes — rien n'écrit plus de consigne, et
// rétablir l'onglet ne demanderait que de recréer cet écran.
/// Onglet PERTES — UN SEUL TOTAL, celui du bilan (audit des marges, A1).
///
/// Il ne somme plus les montants saisis : il affiche les lignes que
/// `RestaurantReportingService` valorise pour la période du tableau de bord,
/// via le MÊME provider que le tableau de bord. Une perte de matière y vaut ce
/// que la répartition de la période lui impute ; son montant de déclaration
/// reste visible comme estimation, jamais sommé.
///
/// Conséquence assumée : changer de période change la valeur d'une perte de
/// matière — le coût d'une assiette dépend des achats et des ventes de la
/// période. Les pertes hors période ne sont pas listées.

class RestoBackfillBanner extends StatelessWidget {
  final int count;
  final int total;
  final bool busy;
  final VoidCallback onRun;
  final String label;

  const RestoBackfillBanner({
    super.key,
    required this.count,
    required this.total,
    required this.busy,
    required this.onRun,
    this.label = 'ingrédient',
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sem.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.info_outline_rounded, size: 18, color: sem.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$count $label(s) sans achat enregistré',
                  style: AppTextStyles.bodySmBold
                      .copyWith(color: cs.onSurface)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
              'Ils ont du stock, mais aucune dépense ne leur est rattachée : '
              'les plats qui les contiennent affichent donc 0 F de coût '
              'matières. Enregistrer leurs achats '
              '(${CurrencyFormatter.format(total.toDouble())}) corrige vos '
              'marges.',
              style: AppTextStyles.caption),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onRun,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.receipt_long_outlined, size: 18),
              label: Text(busy
                  ? 'Enregistrement…'
                  : 'Enregistrer les achats manquants'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            ),
          ),
        ],
      ),
    );
  }
}


/// Date courte `jj/mm/aaaa`.
String restoDayLabel(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Formate une quantité double sans « .0 » superflu.
String restoQty(double v) => v == v.truncateToDouble()
    ? v.toInt().toString()
    : v.toStringAsFixed(1);


/// Champ numérique compact (entier par défaut, décimal si demandé).
Widget restoNumField(TextEditingController c, String label, {bool decimal = false}) =>
    TextField(
      controller: c,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      inputFormatters: decimal
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]
          : [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label),
    );


/// Petite feuille « saisir une quantité » (réception).
Future<double?> restoAskAmount(BuildContext context, String title,
    {String? suffix}) async {
  final ctrl = TextEditingController();
  return showAdaptiveFormSheet<double>(
    context: context,
    builder: (sheetCtx) => AdaptiveFormFrame(
      title: title,
      icon: Icons.add_box_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            decoration:
                InputDecoration(labelText: 'Quantité reçue', suffixText: suffix),
          ),
          const SizedBox(height: 18),
          AppPrimaryButton(
            label: 'Ajouter au stock',
            icon: Icons.check_rounded,
            fullWidth: true,
            onTap: () {
              final v = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
              if (v == null || v <= 0) {
                AppSnack.error(sheetCtx, 'Quantité invalide');
                return;
              }
              Navigator.of(sheetCtx).pop(v);
            },
          ),
        ]),
      ),
    ),
  );
}

/// Carte de liste standard (surface + bordure douce).
