import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/services/reconciliation_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../widgets/resto_empty_state.dart' show RestoEmptyState;
import '../widgets/resto_surfaces.dart' show RestoGlassPanel;

/// Réconciliation d'inventaire (module finances — Lot 2).
///
/// L'opérateur compte la réserve en fin de service et saisit le stock RÉEL en
/// face de chaque article. À la validation : le stock est corrigé et chaque
/// manque devient une perte (catégorie `ecart_inventaire`), conformément à
/// [ReconciliationService].
///
/// **Un champ laissé vide n'est pas un zéro** : l'article n'a simplement pas
/// été compté et n'est pas touché. Sans cette règle, ouvrir la page et valider
/// viderait toute la réserve.
///
/// La liste est un INSTANTANÉ pris à l'ouverture : la page n'écoute pas
/// `AppDatabase` volontairement — un rafraîchissement live effacerait les
/// quantités en cours de saisie. Le stock théorique est de toute façon relu
/// juste avant chaque écriture.
class InventoryReconcilePage extends StatefulWidget {
  final String shopId;
  const InventoryReconcilePage({super.key, required this.shopId});

  @override
  State<InventoryReconcilePage> createState() => _InventoryReconcilePageState();
}

class _InventoryReconcilePageState extends State<InventoryReconcilePage> {
  late final List<CountableItem> _items =
      ReconciliationService.countableItems(widget.shopId);

  late final Map<String, TextEditingController> _ctrls = {
    for (final it in _items) it.key: TextEditingController(),
  };

  bool _saving = false;

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Stock réel saisi pour cet article, `null` s'il n'a pas été compté.
  double? _counted(CountableItem it) {
    final raw = _ctrls[it.key]?.text.trim().replaceAll(',', '.') ?? '';
    if (raw.isEmpty) return null;
    final v = double.tryParse(raw);
    return (v == null || v < 0) ? null : v;
  }

  /// Écarts des seuls articles comptés.
  List<StockVariance> get _variances => [
        for (final it in _items)
          if (_counted(it) != null)
            StockVariance(item: it, actual: _counted(it)!),
      ];

  Future<void> _validate() async {
    // Un écart nul ne produit rien : inutile de le faire traverser la couche
    // d'écriture, et le récapitulatif ne doit compter que du réel.
    final withGap = _variances.where((v) => v.variance != 0).toList();
    if (withGap.isEmpty) {
      AppSnack.info(context, 'Aucun écart à enregistrer.');
      return;
    }

    final lossTotal = withGap
        .where((v) => v.isShortage)
        .fold<int>(0, (s, v) => s + v.financialImpact);
    final shortages = withGap.where((v) => v.isShortage).length;
    final surplus = withGap.length - shortages;

    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.fact_check_outlined,
      iconColor: Theme.of(context).semantic.warning,
      title: 'Valider l\'inventaire ?',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${withGap.length} écart(s) constaté(s) :',
              style: AppTextStyles.body),
          const SizedBox(height: 6),
          if (shortages > 0)
            Text('• $shortages manque(s) → perte de '
                '${CurrencyFormatter.format(lossTotal.toDouble())}',
                style: AppTextStyles.bodySm),
          if (surplus > 0)
            Text('• $surplus surplus → stock corrigé, aucune perte',
                style: AppTextStyles.bodySm),
          const SizedBox(height: 8),
          Text('Le stock compté remplacera le stock théorique.',
              style: AppTextStyles.caption),
        ],
      ),
      cancelLabel: 'Annuler',
      confirmLabel: 'Valider',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final outcome = await ReconciliationService.apply(
        shopId: widget.shopId,
        variances: withGap,
        declaredBy: LocalStorageService.getCurrentUser()?.id,
      );
      if (!mounted) return;
      AppSnack.success(
          context,
          '${outcome.adjusted} stock(s) corrigé(s)'
          '${outcome.lossesCount > 0 ? ' · ${outcome.lossesCount} perte(s) : '
              '${CurrencyFormatter.format(outcome.lossTotal.toDouble())}' : ''}');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        AppSnack.error(context, 'Inventaire non enregistré : $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Inventaire',
      isRootPage: false,
      body: _items.isEmpty
          ? const RestoEmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Rien à compter',
              subtitle: 'Créez des ingrédients ou des articles de stock '
                  'depuis Finances pour pouvoir faire l\'inventaire.',
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  // Sur panneau : aucun texte du module ne se pose à nu sur la
                  // photo de salle (cf. la règle sur `restoGlassFill`).
                  child: RestoGlassPanel(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    radius: 12,
                    child: Text(
                        'Saisissez le stock réellement compté. '
                        'Un champ laissé vide n\'est pas modifié.',
                        style: AppTextStyles.captionHint),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final it = _items[i];
                      final counted = _counted(it);
                      return _CountRow(
                        item: it,
                        controller: _ctrls[it.key]!,
                        variance: counted == null
                            ? null
                            : StockVariance(item: it, actual: counted),
                        onChanged: () => setState(() {}),
                      );
                    },
                  ),
                ),
                Divider(height: 1, color: sem.borderSubtle),
                _Recap(
                  variances: _variances,
                  saving: _saving,
                  onValidate: _validate,
                ),
              ],
            ),
    );
  }
}

/// Une ligne de comptage : article · stock théorique · champ « réel » · écart.
class _CountRow extends StatelessWidget {
  final CountableItem item;
  final TextEditingController controller;

  /// Écart courant, `null` tant que l'article n'a pas été compté.
  final StockVariance? variance;
  final VoidCallback onChanged;

  const _CountRow({
    required this.item,
    required this.controller,
    required this.variance,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final v = variance;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
                Text(
                    'Théorique : ${_fmt(item.theoretical)} ${item.unit}'
                    '${item.costPerUnit > 0 ? ' · ${item.costPerUnit} F/${item.unit}' : ''}',
                    style: AppTextStyles.caption),
                if (v != null && v.variance != 0)
                  Text(
                      '${v.isShortage ? '−' : '+'}${_fmt(v.variance.abs())} '
                      '${item.unit} · ${v.label}'
                      '${v.isShortage && v.financialImpact > 0 ? ' · ${CurrencyFormatter.format(v.financialImpact.toDouble())}' : ''}',
                      style: AppTextStyles.caption.copyWith(
                          color: v.isShortage ? sem.dangerText : sem.warningText)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 92,
            child: TextField(
              controller: controller,
              onChanged: (_) => onChanged(),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Réel',
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau de bas de page : ce que la validation va réellement écrire.
class _Recap extends StatelessWidget {
  final List<StockVariance> variances;
  final bool saving;
  final VoidCallback onValidate;

  const _Recap({
    required this.variances,
    required this.saving,
    required this.onValidate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final gaps = variances.where((v) => v.variance != 0).toList();
    final lossTotal = gaps
        .where((v) => v.isShortage)
        .fold<int>(0, (s, v) => s + v.financialImpact);

    return Material(
      color: cs.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                        '${variances.length} article(s) compté(s) · '
                        '${gaps.length} écart(s)',
                        style: AppTextStyles.bodySm),
                  ),
                  if (lossTotal > 0)
                    Text(
                        'Perte : '
                        '${CurrencyFormatter.format(lossTotal.toDouble())}',
                        style: AppTextStyles.bodyBold
                            .copyWith(color: sem.dangerText)),
                ],
              ),
              const SizedBox(height: 10),
              AppPrimaryButton(
                label: 'Valider l\'inventaire',
                icon: Icons.check_rounded,
                fullWidth: true,
                isLoading: saving,
                onTap: onValidate,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quantité lisible, sans « .0 » superflu.
String _fmt(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
