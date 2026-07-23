import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';

/// Carte d'un article du menu, pensée pour la prise de commande en salle.
///
/// Widget SPÉCIFIQUE au module restaurant — la grille produits de la caisse
/// (`product_grid_widget.dart`) reste dédiée à l'e-commerce : elle affiche
/// stock, marges et alertes de prix, inutiles et encombrants pour un serveur
/// qui doit taper vite entre deux tables.
class MenuItemTile extends StatelessWidget {
  final String name;
  final double price;
  final String? imageUrl;

  /// Affiche l'indice « appui long = options » quand le plat a des options.
  final bool hasModifiers;

  final VoidCallback onAdd;
  final VoidCallback onLongPress;

  const MenuItemTile({
    super.key,
    required this.name,
    required this.price,
    required this.onAdd,
    required this.onLongPress,
    this.imageUrl,
    this.hasModifiers = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;

    return Material(
      color: semantic.elevatedSurface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onAdd,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: semantic.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmBold
                      .copyWith(color: theme.colorScheme.onSurface),
                ),
              ),
              if (hasModifiers)
                Row(
                  children: [
                    Icon(Icons.tune_rounded,
                        size: 11, color: semantic.warning),
                    const SizedBox(width: 3),
                    Text('Options',
                        style: AppTextStyles.micro
                            .copyWith(color: semantic.warning)),
                  ],
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      CurrencyFormatter.format(price),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: theme.colorScheme.primary),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.add_rounded,
                        size: 16, color: theme.colorScheme.onPrimary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
