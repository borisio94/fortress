import 'package:flutter/material.dart';

import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/menu_modifier.dart';

/// Feuille de sélection des options d'un plat (cuisson, suppléments…).
///
/// Un choix UNIQUE par groupe : « Cuisson » ne peut pas être à la fois
/// saignant et bien cuit. Un plat sans choix dans un groupe est autorisé
/// (le serveur peut ne pas demander la cuisson) — d'où le retour possible
/// d'une liste partielle.
class ModifierPickerSheet extends StatefulWidget {
  final String productName;
  final double basePrice;
  final List<MenuModifier> groups;

  const ModifierPickerSheet({
    super.key,
    required this.productName,
    required this.basePrice,
    required this.groups,
  });

  @override
  State<ModifierPickerSheet> createState() => _ModifierPickerSheetState();
}

class _ModifierPickerSheetState extends State<ModifierPickerSheet> {
  /// Option retenue par groupe : `{nom du groupe: option}`.
  final Map<String, ModifierOption> _selection = {};

  List<Map<String, dynamic>> get _asMaps => _selection.entries
      .map((e) => <String, dynamic>{
            'group': e.key,
            'option': e.value.name,
            'price_impact': e.value.priceImpact,
          })
      .toList();

  double get _preview =>
      RestaurantOrderService.priceWithModifiers(widget.basePrice, _asMaps);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;

    return SafeArea(
      child: Padding(
        // Laisse la place au clavier si un jour un champ libre est ajouté,
        // et borne la hauteur pour que la feuille reste scrollable sur un
        // menu à nombreux groupes d'options.
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Text(widget.productName, style: AppTextStyles.subtitleBold),
              Text('Options', style: AppTextStyles.captionHint),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  children: [
                    for (final group in widget.groups) ...[
                      Text(group.name, style: AppTextStyles.bodySmBold),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final opt in group.options)
                            _OptionChip(
                              option: opt,
                              selected: _selection[group.name]?.name == opt.name,
                              onTap: () => setState(() {
                                // Re-tap sur l'option active = désélection,
                                // pour pouvoir revenir à « sans précision ».
                                if (_selection[group.name]?.name == opt.name) {
                                  _selection.remove(group.name);
                                } else {
                                  _selection[group.name] = opt;
                                }
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Prix de la ligne',
                              style: AppTextStyles.captionHint),
                          Text(
                            CurrencyFormatter.format(_preview),
                            style: AppTextStyles.subtitleBold.copyWith(
                                color: _preview != widget.basePrice
                                    ? semantic.warning
                                    : theme.colorScheme.onSurface),
                          ),
                        ],
                      ),
                    ),
                    AppPrimaryButton(
                      label: 'Ajouter',
                      icon: Icons.add_rounded,
                      onTap: () => Navigator.of(context).pop(_asMaps),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Puce d'une option, avec son impact tarifaire quand il est non nul.
class _OptionChip extends StatelessWidget {
  final ModifierOption option;
  final bool selected;
  final VoidCallback onTap;

  const _OptionChip({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;
    final impact = option.priceImpact;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : semantic.trackMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : semantic.borderSubtle,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              option.name,
              style: AppTextStyles.bodySm.copyWith(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (impact != 0) ...[
              const SizedBox(width: 6),
              Text(
                // Signe explicite : « +500 » se lit mieux que « 500 » sur
                // un supplément, et « -200 » signale une remise.
                '${impact > 0 ? '+' : ''}$impact',
                style: AppTextStyles.micro.copyWith(
                    color: impact > 0 ? semantic.warning : semantic.success),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
