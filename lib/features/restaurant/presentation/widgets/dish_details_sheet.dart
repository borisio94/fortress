import 'package:flutter/material.dart';

import '../../../../core/services/daily_menu_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/product_image_card.dart';

/// Fiche d'un plat en LECTURE SEULE — ce que voit qui n'a pas le droit de
/// modifier la carte.
///
/// Elle existe parce que « pas le droit de modifier » ne veut pas dire « pas
/// le droit de savoir » : la page Menu est l'écran de prise de commande, et un
/// serveur a besoin de lire la composition d'un plat pour répondre au client
/// qui demande ce qu'il y a dedans. Sans elle, le tap sur une carte n'aurait
/// rien fait — un geste mort sur l'écran le plus utilisé du service.
///
/// Volontairement PAUVRE : nom, photo, prix de vente, description, catégorie,
/// disponibilité du jour. Ni prix d'achat, ni marge, ni recette — ce sont des
/// données de gestion, elles restent derrière le formulaire complet.
Future<void> showDishDetails({
  required BuildContext context,
  required String shopId,
  required Product product,
}) =>
    showAdaptiveFormSheet<void>(
      context: context,
      builder: (_) => _DishDetailsSheet(shopId: shopId, product: product),
    );

class _DishDetailsSheet extends StatelessWidget {
  final String shopId;
  final Product product;

  const _DishDetailsSheet({required this.shopId, required this.product});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final avail = DailyMenuService.read(shopId, product.id ?? '');
    final desc = product.description?.trim() ?? '';
    final category = product.categoryId?.trim() ?? '';

    return AdaptiveFormFrame(
      title: product.name,
      subtitle: category.isEmpty ? 'Fiche du plat' : category,
      icon: Icons.restaurant_menu_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ProductImageCard(
                imageUrl: product.mainImageUrl,
                aspectRatio: 16 / 9,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    CurrencyFormatter.format(product.priceSellPos),
                    style: AppTextStyles.title
                        .copyWith(color: theme.colorScheme.primary),
                  ),
                ),
                _AvailabilityChip(
                  available: avail.isAvailable,
                  soldOut: avail.isSoldOut,
                  count: avail.count,
                ),
              ],
            ),
            if (product.rating > 0) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 1; i <= 5; i++)
                    Icon(
                      i <= product.rating
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                ],
              ),
            ],
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Composition', style: AppTextStyles.captionBold),
              const SizedBox(height: 4),
              Text(desc, style: AppTextStyles.body),
            ],
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: sem.trackMuted,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Icon(Icons.lock_outline_rounded,
                    size: 15, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Modifier la carte est réservé à la gérance.',
                    style: AppTextStyles.caption,
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

/// Disponibilité du jour, en un coup d'œil.
class _AvailabilityChip extends StatelessWidget {
  final bool available;
  final bool soldOut;
  final int? count;

  const _AvailabilityChip({
    required this.available,
    required this.soldOut,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final (label, color) = available
        ? (count == null ? 'Disponible' : 'Disponible · $count', sem.success)
        : (soldOut ? 'Épuisé' : 'Indisponible', sem.danger);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: AppTextStyles.captionBold.copyWith(color: color)),
    );
  }
}
