import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/daily_expense_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_select_menu.dart';
import '../../domain/entities/daily_expense.dart' show ExpenseKind;
import '../../domain/entities/ingredient.dart';
import 'cost_method_picker.dart';

/// CRÉER UN INGRÉDIENT, sans quitter l'écran d'où on vient.
///
/// Écrite pour la fiche d'un plat — on compose une recette, il manque l'huile
/// rouge, on la crée sur place. Extraite de `dish_form_sheet.dart` le
/// 21/09/2026 pour que l'écran Stock puisse l'ouvrir aussi.
///
/// AVANT CETTE EXTRACTION, ajouter un ingrédient à sa réserve exigeait
/// d'ouvrir un plat et de composer une recette. L'état vide des ingrédients le
/// disait en toutes lettres : « Les ingrédients se créent depuis la fiche d'un
/// plat. » C'était vrai, et c'était le problème.
///
/// La feuille écrit elle-même la dépense d'achat quand un montant est saisi :
/// l'appelant relit la base plutôt que de recevoir un second résultat.

class IngredientQuickSheet extends StatefulWidget {
  final String shopId;

  /// Avertir que l'achat ne s'imputera à aucun plat.
  ///
  /// VRAI DEPUIS L'ÉCRAN STOCK, faux depuis la fiche d'un plat — et la
  /// distinction n'est pas cosmétique. Sur la fiche d'un plat on est EN TRAIN
  /// de rattacher l'ingrédient à une recette : l'avertissement y serait faux
  /// deux secondes après avoir été lu. Depuis Stock, rien n'oblige à le
  /// rattacher, et c'est ce qui produit des achats non rattachés.
  final bool warnsAboutUnlinked;

  const IngredientQuickSheet({
    super.key,
    required this.shopId,
    this.warnsAboutUnlinked = false,
  });
  @override
  State<IngredientQuickSheet> createState() => _IngredientQuickSheetState();
}

class _IngredientQuickSheetState extends State<IngredientQuickSheet> {
  final _nameCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  String _unit = 'kg';
  DateTime? _purchase;

  /// Unités PROPOSÉES par défaut à un restaurant — celles dans lesquelles on
  /// achète réellement au marché ou chez le grossiste.
  ///
  /// Ce n'est qu'une amorce : la liste effective est celle de la boutique
  /// (`LocalStorageService.getUnits`), à laquelle celles-ci s'ajoutent tant
  /// qu'elles n'y sont pas. Une boutique qui achète « au régime » ou « au
  /// panier » ajoute son unité depuis le menu, et elle est partagée avec le
  /// reste de l'application.
  static const _defaultUnits = [
    'kg', 'g', 'L', 'cL', 'pièce', 'boîte',
    'sachet', 'sac', 'tas', 'botte', 'casier', 'bouteille',
  ];

  /// Unités de la boutique, amorcées par [_defaultUnits]. Mutable : en ajouter
  /// une depuis le menu la rend disponible sans rouvrir la feuille.
  late final List<String> _units = _mergedUnits();

  List<String> _mergedUnits() {
    final saved = LocalStorageService.getUnits(widget.shopId);
    final out = <String>[...saved];
    for (final u in _defaultUnits) {
      if (!out.contains(u)) out.add(u);
    }
    return out;
  }

  /// Méthode de chiffrage de CET ingrédient. Répartition par défaut : c'est le
  /// comportement de tout le parc, et le seul qui ne demande rien de plus.
  String _costMethod = Ingredient.costRepartition;

  String? _err;
  bool _saving = false;

  bool get _isSheet => _costMethod == Ingredient.costSheet;

  /// La quantité achetée est OBLIGATOIRE en fiche technique.
  ///
  /// Le coût unitaire est déduit du total divisé par la quantité. Sans
  /// quantité, l'app retiendrait le montant du reçu ENTIER comme coût
  /// unitaire — puis le multiplierait par les grammes de la recette. Un sac de
  /// riz à 35 000 F donnerait 5,25 millions pour une portion de 150 g. La
  /// répartition, elle, ne divise jamais : la quantité peut y rester vide.
  bool get _qtyRequired => _isSheet;


  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  double get _qtyValue =>
      double.tryParse(_qtyCtrl.text.trim().replaceAll(',', '.')) ?? 0;

  int get _priceValue => int.tryParse(_priceCtrl.text.trim()) ?? 0;

  /// Le coût unitaire est DÉDUIT, jamais saisi : sur un reçu on lit un total
  /// et une quantité, pas un prix au kilo.
  int get _derivedUnitCost =>
      _qtyValue <= 0 ? _priceValue : (_priceValue / _qtyValue).round();

  /// L'enregistrement va-t-il produire une dépense ? Il faut les DEUX : un
  /// montant (sinon il n'y a rien à dépenser) et une quantité (sinon on
  /// déclare un achat sans marchandise, l'argent sort et le stock reste nul).
  bool get _recordsPurchase => _priceValue > 0 && _qtyValue > 0;

  Future<void> _pickPurchaseDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _purchase ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => _purchase = d);
  }

  /// Saisie d'une nouvelle unité, depuis le « + Ajouter » du menu.
  ///
  /// L'unité créée est enregistrée au niveau de la BOUTIQUE
  /// (`AppDatabase.saveUnit`, synchronisé) et non de l'ingrédient : une
  /// boutique qui achète « au régime » le fait pour plusieurs ingrédients, et
  /// devoir le ressaisir à chaque fiche serait une invitation aux fautes de
  /// frappe — « régime », « Régime », « regime » deviendraient trois unités.
  Future<String?> _addUnit(BuildContext ctx) async {
    final ctrl = TextEditingController();
    final value = await showAdaptiveFormSheet<String>(
      context: ctx,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Nouvelle unité',
        subtitle: 'Elle rejoindra la liste de la boutique',
        icon: Icons.straighten_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Unité',
                    hintText: 'régime, panier, cuvette… *'),
                onSubmitted: (v) =>
                    Navigator.of(sheetCtx).pop(v.trim()),
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Ajouter',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: () =>
                    Navigator.of(sheetCtx).pop(ctrl.text.trim()),
              ),
            ],
          ),
        ),
      ),
    );
    ctrl.dispose();
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    await AppDatabase.saveUnit(widget.shopId, v);
    if (mounted) setState(() => _units.add(v));
    return v;
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    // QUANTITÉ OBLIGATOIRE EN FICHE TECHNIQUE — refus net, pas une
    // confirmation : ce n'est pas une information « qu'on complétera plus
    // tard », c'est le diviseur sans lequel le coût unitaire est absurde.
    if (_qtyRequired && _qtyValue <= 0) {
      setState(() => _err =
          'La fiche technique exige la quantité achetée : le coût unitaire '
          'se déduit du montant divisé par cette quantité.');
      return;
    }
    // MONTANT ABSENT — on demande confirmation, on ne bloque pas. Interdire
    // empêcherait de composer une carte sans avoir ses factures sous la main.
    // Mais laisser passer en silence est le défaut le plus coûteux du module :
    // un ingrédient sans dépense ne pèse RIEN, donc les plats qui le
    // contiennent affichent une marge flatteuse — et un chiffre qui fait
    // plaisir ne se remet jamais en cause.
    if (!_recordsPurchase) {
      final ok = await AppConfirmDialog.show(
        context: context,
        icon: Icons.report_problem_outlined,
        iconColor: Theme.of(context).semantic.warning,
        title: 'Créer sans montant ?',
        body: const Text(
            'Sans quantité ET montant payé, aucune dépense n\'est rattachée à '
            'cet ingrédient. Ce plat sera chiffré comme s\'il était gratuit, '
            'et sa marge paraîtra meilleure qu\'elle ne l\'est.\n\n'
            'Vous pourrez régulariser plus tard depuis Finances → Réception.'),
        cancelLabel: 'Compléter',
        confirmLabel: 'Créer quand même',
        onConfirm: () {},
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _saving = true);
    try {
      final ing = await IngredientService.create(
        shopId: widget.shopId,
        name: name,
        unit: _unit,
        costPerUnit: _derivedUnitCost,
        quantity: _qtyValue,
        purchaseDate: _purchase,
        costMethod: _costMethod,
      );
      // CRÉER un ingrédient avec un prix payé, C'EST UN ACHAT : la dépense
      // correspondante est écrite et rattachée. C'est elle, et elle seule, qui
      // donnera un coût aux plats qui contiennent cet ingrédient.
      if (_recordsPurchase) {
        await DailyExpenseService.record(
          shopId: widget.shopId,
          description: '$name — ${_fmtQty(_qtyValue)} $_unit',
          amount: _priceValue,
          kind: ExpenseKind.achatMarche,
          ingredientId: ing.id,
          date: _purchase,
        );
      }
      if (mounted) Navigator.of(context).pop(ing);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _err = 'Création impossible : $e';
        });
      }
    }
  }

  static String _fmtQty(double v) {
    final s = v.toStringAsFixed(3);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Nouvel ingrédient',
      icon: Icons.eco_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── LA MÉTHODE D'ABORD ─────────────────────────────────────────
            // Elle décide de ce qui est demandé en dessous : en fiche
            // technique la quantité devient obligatoire. La poser en tête,
            // c'est répondre à la question avant qu'elle ne se pose.
            CostMethodPicker(
              value: _costMethod,
              onChanged: (m) => setState(() {
                _costMethod = m;
                // L'erreur affichée pouvait porter sur la quantité, qui n'est
                // plus obligatoire après un retour en répartition.
                _err = null;
              }),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Nom', hintText: 'Poulet, huile rouge, riz… *'),
            ),
            const SizedBox(height: 12),
            AppSelectWidget(
              label: 'Unité d\'achat',
              items: _units,
              value: _unit,
              icon: Icons.straighten_rounded,
              addLabel: 'Ajouter une unité',
              onAdd: _addUnit,
              onChanged: (v) => setState(() => _unit = v),
            ),
            const SizedBox(height: 14),
            // ── L'ACHAT, saisi ici et pas ailleurs ─────────────────────────
            // On demande ce qui est écrit sur le reçu — une quantité et un
            // total — et non un coût unitaire que personne ne lit nulle part.
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Quantité achetée',
                    // L'astérisque n'apparaît qu'en fiche technique : la
                    // répartition ne divise jamais, la quantité peut y rester
                    // vide sans rien fausser.
                    hintText: _qtyRequired ? 'ex. 25 *' : 'ex. 25',
                    suffixText: ' $_unit',
                    suffixStyle: AppTextStyles.caption,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _priceCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Montant payé (F)',
                    hintText: 'ex. 35000',
                  ),
                ),
              ),
            ]),
            if (_priceValue > 0) ...[
              const SizedBox(height: 6),
              Text(
                  _qtyValue > 0
                      ? '→ soit $_derivedUnitCost F / $_unit'
                      : '→ retenu comme coût unitaire. Sans quantité, aucune '
                          'dépense n\'est créée.',
                  style: AppTextStyles.caption),
              // CE QUE CET ACHAT VA DEVENIR, dit avant qu'il soit écrit.
              //
              // Conditionné au MONTANT, et à lui seul : la phrase parle de
              // « cet achat », et sans montant il n'y en a aucun — l'afficher
              // serait faux. En revanche elle n'est PAS conditionnée à
              // « l'ingrédient est-il déjà sans recette » : à la création il
              // l'est toujours, une condition qui vaut toujours vrai est du
              // code mort déguisé.
              //
              // Le vocabulaire est celui du tableau de bord, mot pour mot
              // (« achats non rattachés », lot 8 des marges) : le gérant doit
              // reconnaître la même expression aux deux endroits.
              if (widget.warnsAboutUnlinked) ...[
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline_rounded,
                      size: 15, color: Theme.of(context).semantic.warningText),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                        'Cet ingrédient n\'entre encore dans aucune recette. '
                        'Tant qu\'un plat ne le contient pas, cet achat ne '
                        's\'impute à aucun plat : il apparaîtra en achats non '
                        'rattachés dans l\'écart du tableau de bord.',
                        style: AppTextStyles.caption.copyWith(
                            color: Theme.of(context).semantic.warningText)),
                  ),
                ]),
              ],
            ],
            const SizedBox(height: 10),
            InkWell(
              onTap: _pickPurchaseDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Date d\'achat',
                  prefixIcon: const Icon(Icons.calendar_today, size: 18),
                  suffixIcon: _purchase == null
                      ? null
                      : IconButton(
                          tooltip: 'Effacer la date',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () => setState(() => _purchase = null),
                        ),
                ),
                child: Text(
                    _purchase == null
                        ? 'Aujourd\'hui'
                        : _dayLabel(_purchase!),
                    style: AppTextStyles.body),
              ),
            ),
            const SizedBox(height: 10),
            // Ce que l'enregistrement va RÉELLEMENT écrire. Le dire avant est
            // la seule façon d'éviter la surprise dans les deux sens : une
            // dépense qu'on n'attendait pas, ou celle qu'on attendait en vain.
            Text(
                _recordsPurchase
                    ? 'Une dépense de $_priceValue F sera enregistrée et '
                        'rattachée à cet ingrédient : c\'est elle qui donnera '
                        'son coût aux plats qui le contiennent.'
                    : 'Sans quantité ET montant, aucun coût ne sera imputé aux '
                        'plats. Régularisable depuis Finances → Réception.',
                style: AppTextStyles.captionHint),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Créer et ajouter',
              icon: Icons.check_rounded,
              fullWidth: true,
              isLoading: _saving,
              onTap: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// BORDURE POINTILLÉE, peinte autour de [child].
///
/// Dit « à remplir » là où un trait plein dirait « vide ». Flutter n'a pas de
/// `BorderStyle.dashed` : il faut peindre le chemin soi-même.
///
/// [enabled] à `false` rend le widget transparent — pratique pour une vignette
/// qui perd son pointillé une fois la photo posée, sans changer d'arbre.
