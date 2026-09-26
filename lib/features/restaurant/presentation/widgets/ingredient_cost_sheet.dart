import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/services/daily_expense_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/daily_expense.dart';
import '../../domain/entities/ingredient.dart';

/// Saisie GROUPÉE des achats d'ingrédients.
///
/// Tant qu'aucune dépense n'est rattachée à un ingrédient, les plats qui le
/// contiennent affichent 0 F de coût matières : la répartition n'a rien à
/// répartir, et la marge annoncée est flatteuse et fausse. Cet écran ferme ce
/// trou en une passe, au lieu d'exiger une réception ingrédient par
/// ingrédient dans un autre menu.
///
/// Chaque ligne écrit DEUX choses : la quantité entre en stock, et le montant
/// devient une dépense rattachée. Les séparer était précisément l'erreur qui
/// laissait des ingrédients « valorisés » sans un franc au compte de résultat.
///
/// Retourne le nombre d'achats enregistrés.
Future<int?> showIngredientCostSheet({
  required BuildContext context,
  required String shopId,
  required List<Ingredient> ingredients,
}) =>
    showAdaptiveFormSheet<int>(
      context: context,
      builder: (_) =>
          _IngredientCostSheet(shopId: shopId, ingredients: ingredients),
    );

class _IngredientCostSheet extends StatefulWidget {
  final String shopId;
  final List<Ingredient> ingredients;

  const _IngredientCostSheet({
    required this.shopId,
    required this.ingredients,
  });

  @override
  State<_IngredientCostSheet> createState() => _IngredientCostSheetState();
}

class _IngredientCostSheetState extends State<_IngredientCostSheet> {
  /// Un couple de contrôleurs par ingrédient, indexé par son id.
  late final Map<String, ({TextEditingController qty, TextEditingController amount})>
      _ctrls = {
    for (final i in widget.ingredients)
      i.id: (
        // Pré-remplies avec ce que l'ingrédient déclare déjà : dans la plupart
        // des cas, la quantité et le coût unitaire ont été saisis à la
        // création. Re-taper ce qu'on vient d'écrire serait absurde.
        qty: TextEditingController(
            text: i.quantity > 0 ? _fmt(i.quantity) : ''),
        amount: TextEditingController(
            text: (i.quantity > 0 && i.costPerUnit > 0)
                ? '${(i.quantity * i.costPerUnit).round()}'
                : ''),
      ),
  };

  bool _saving = false;
  String? _err;

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.qty.dispose();
      c.amount.dispose();
    }
    super.dispose();
  }

  double _qtyOf(String id) =>
      double.tryParse(
          (_ctrls[id]?.qty.text ?? '').trim().replaceAll(',', '.')) ??
      0;

  int _amountOf(String id) =>
      int.tryParse((_ctrls[id]?.amount.text ?? '').trim()) ?? 0;

  /// Lignes réellement exploitables : il faut les DEUX. Un montant sans
  /// quantité déclarerait un achat sans marchandise ; une quantité sans
  /// montant n'imputerait toujours rien aux plats.
  List<Ingredient> get _ready => widget.ingredients
      .where((i) => _qtyOf(i.id) > 0 && _amountOf(i.id) > 0)
      .toList();

  int get _total =>
      _ready.fold<int>(0, (s, i) => s + _amountOf(i.id));

  Future<void> _save() async {
    final ready = _ready;
    if (ready.isEmpty) {
      setState(() => _err =
          'Renseignez la quantité ET le montant d\'au moins un ingrédient.');
      return;
    }
    setState(() {
      _saving = true;
      _err = null;
    });

    var done = 0;
    for (final i in ready) {
      final qty = _qtyOf(i.id);
      final amount = _amountOf(i.id);
      try {
        // La quantité déjà déclarée à la création n'est PAS ré-ajoutée : on
        // remplace le stock par celui saisi ici, sinon un ingrédient créé avec
        // 5 kg puis confirmé à 5 kg se retrouverait à 10.
        await IngredientService.update(i.copyWith(
          quantity: qty,
          costPerUnit: (amount / qty).round(),
        ));
        await DailyExpenseService.record(
          shopId: widget.shopId,
          description: '${i.name} — ${_fmt(qty)} ${i.unit}',
          amount: amount,
          kind: ExpenseKind.achatMarche,
          ingredientId: i.id,
        );
        done++;
      } catch (e) {
        // Un ingrédient qui échoue n'empêche pas les autres d'être
        // enregistrés — l'écran rouvrira sur ceux qui restent.
        debugPrint('[IngredientCost] ${i.name}: $e');
      }
    }
    if (mounted) Navigator.of(context).pop(done);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final ready = _ready.length;

    return AdaptiveFormFrame(
      title: 'Vos achats',
      subtitle: '${widget.ingredients.length} ingrédient(s) à renseigner',
      icon: Icons.receipt_long_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                'Combien avez-vous acheté, et combien l\'avez-vous payé ? '
                'C\'est ce montant qui donnera un coût à vos plats — sans lui '
                'ils resteront à 0 F et votre marge sera fausse.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 14),
            for (final i in widget.ingredients) ...[
              Text('${i.name}  ·  ${i.unit}',
                  style:
                      AppTextStyles.bodySmBold.copyWith(color: cs.onSurface)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _ctrls[i.id]!.qty,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    onChanged: (_) => setState(() => _err = null),
                    decoration: InputDecoration(
                        labelText: 'Quantité', suffixText: i.unit, isDense: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _ctrls[i.id]!.amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() => _err = null),
                    decoration: const InputDecoration(
                        labelText: 'Montant payé (F)', isDense: true),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
            ],
            if (_err != null) ...[
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
              const SizedBox(height: 8),
            ],
            Text(
                ready == 0
                    ? 'Aucune ligne complète pour l\'instant.'
                    : '$ready achat(s) seront enregistrés · '
                        '${CurrencyFormatter.format(_total.toDouble())}',
                style: AppTextStyles.caption),
            const SizedBox(height: 14),
            AppPrimaryButton(
              label: 'Enregistrer mes achats',
              icon: Icons.check_rounded,
              fullWidth: true,
              isLoading: _saving,
              enabled: ready > 0,
              onTap: _save,
            ),
          ],
        ),
      ),
    );
  }
}

/// Quantité lisible, sans « .0 » superflu.
String _fmt(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
