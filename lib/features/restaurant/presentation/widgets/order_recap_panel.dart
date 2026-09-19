import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/caisse/domain/entities/sale_item.dart';
import '../../../../shared/widgets/app_primary_button.dart';

/// Récapitulatif de la commande en cours, épinglé en bas de la prise de
/// commande.
///
/// Widget SPÉCIFIQUE au restaurant — `cart_widget.dart` reste dédié à
/// l'e-commerce (livraison, expédition, encaissement). Ici on ne montre que
/// ce qui sert en salle : les lignes, leurs options, le total, et l'envoi
/// en cuisine.
class OrderRecapPanel extends StatefulWidget {
  final List<SaleItem> lines;
  final double total;
  final bool saving;

  /// Vrai si un bon a déjà été envoyé pour cette commande — le bouton
  /// devient « Renvoyer en cuisine » (ajout de plats en cours de service).
  final bool alreadySent;

  final void Function(int index, int delta) onChangeQuantity;
  final VoidCallback onSave;
  final VoidCallback onSendToKitchen;

  const OrderRecapPanel({
    super.key,
    required this.lines,
    required this.total,
    required this.saving,
    required this.alreadySent,
    required this.onChangeQuantity,
    required this.onSave,
    required this.onSendToKitchen,
  });

  @override
  State<OrderRecapPanel> createState() => _OrderRecapPanelState();
}

class _OrderRecapPanelState extends State<OrderRecapPanel> {
  /// Replié par défaut : la grille du menu doit rester la zone principale.
  /// Le serveur déplie pour vérifier avant d'envoyer.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;
    final count = widget.lines.fold<int>(0, (s, l) => s + l.quantity);

    return Container(
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        border: Border(top: BorderSide(color: semantic.borderSubtle)),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: widget.lines.isEmpty
                  ? null
                  : () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Row(
                  children: [
                    Icon(Icons.receipt_long_rounded,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      count == 0
                          ? 'Aucun article'
                          : '$count article${count > 1 ? 's' : ''}',
                      style: AppTextStyles.bodySmBold,
                    ),
                    const Spacer(),
                    Text(CurrencyFormatter.format(widget.total),
                        style: AppTextStyles.subtitleBold
                            .copyWith(color: theme.colorScheme.primary)),
                    if (widget.lines.isNotEmpty)
                      Icon(
                          _expanded
                              ? Icons.expand_more_rounded
                              : Icons.expand_less_rounded,
                          color: theme.colorScheme.onSurface),
                  ],
                ),
              ),
            ),
            if (_expanded && widget.lines.isNotEmpty)
              ConstrainedBox(
                // Borne la hauteur : une table de 12 couverts peut avoir
                // beaucoup de lignes, le panneau ne doit pas manger l'écran.
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.35),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: widget.lines.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _LineRow(
                    line: widget.lines[i],
                    onMinus: () => widget.onChangeQuantity(i, -1),
                    onPlus: () => widget.onChangeQuantity(i, 1),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: widget.saving || widget.lines.isEmpty
                          ? null
                          : widget.onSave,
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('Enregistrer'),
                      // Hauteur forcée : le thème global impose un
                      // minimumSize infini qui écraserait l'Expanded et
                      // ferait s'afficher le libellé à la verticale.
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 44)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: AppPrimaryButton(
                      label: widget.alreadySent
                          ? 'Renvoyer en cuisine'
                          : 'Envoyer en cuisine',
                      icon: Icons.restaurant_rounded,
                      fullWidth: true,
                      height: 44,
                      isLoading: widget.saving,
                      enabled: widget.lines.isNotEmpty,
                      onTap: widget.onSendToKitchen,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une ligne du récapitulatif, avec ses options et son sélecteur ± .
class _LineRow extends StatelessWidget {
  final SaleItem line;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _LineRow({
    required this.line,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = line.modifiersLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.productName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySmBold),
                if (options.isNotEmpty)
                  Text(options,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.micro
                          .copyWith(color: theme.semantic.warning)),
              ],
            ),
          ),
          IconButton(
            onPressed: onMinus,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
          ),
          SizedBox(
            width: 24,
            child: Text('${line.quantity}',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyBold),
          ),
          IconButton(
            onPressed: onPlus,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
          ),
          SizedBox(
            width: 74,
            child: Text(
              CurrencyFormatter.format(line.subtotal),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySm,
            ),
          ),
        ],
      ),
    );
  }
}
