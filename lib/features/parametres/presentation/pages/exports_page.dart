import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/export_models.dart';
import '../../../../core/services/export_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/export_scope_selector.dart';
import '../../../inventaire/data/exports/products_export_source.dart';

/// Page centrale des exports — accessible depuis Paramètres et depuis
/// le bouton « Télécharger » de chaque module. Affiche une card par
/// type d'export disponible (PR-1 : Produits ; PR-2/PR-3 ajouteront
/// Commandes, Clients, Journaux).
///
/// Chaque card indique le scope et le format supportés, puis ouvre le
/// `ExportScopeSelector` au tap. La permission requise (`canExportXxx`)
/// est vérifiée AVANT l'ouverture du sheet pour éviter d'exposer une
/// option inactive.
class ExportsPage extends ConsumerWidget {
  final String shopId;
  const ExportsPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider(shopId));
    final shop  = LocalStorageService.getShop(shopId);
    final me    = LocalStorageService.getCurrentUser();
    final myShops = me != null
        ? LocalStorageService.getShopsForUser(me.id)
        : const [];
    final isMultiShop = myShops.length > 1;

    return AppScaffold(
      shopId: shopId,
      title: 'Exports',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(shopName: shop?.name ?? 'Boutique'),
          const SizedBox(height: 16),
          _ExportCard(
            icon:        Icons.inventory_2_outlined,
            title:       'Produits',
            subtitle:    'Catalogue · prix · stock · emplacement',
            formats:     'CSV · PDF',
            scopes:      isMultiShop
                ? 'Globale · Boutique · Partenaire'
                : 'Boutique · Partenaire',
            enabled:     perms.canExportProducts,
            disabledHint: perms.canExportProducts
                ? null
                : 'Permission « inventory.export » requise',
            onTap: () => _openProductsExport(
              context,
              shopName:    shop?.name,
              isMultiShop: isMultiShop,
            ),
          ),
          // Slots PR-2/PR-3 — masqués tant que les sources ne sont pas
          // implémentées pour ne pas exposer de cards inertes.
        ],
      ),
    );
  }

  Future<void> _openProductsExport(
    BuildContext context, {
    required String? shopName,
    required bool isMultiShop,
  }) async {
    final partners =
        ProductsExportSource.partnerLocationsForShop(shopId);
    final config = await ExportScopeSelector.show(
      context,
      type: ExportType.products,
      shopId: shopId,
      shopName: shopName,
      partnerLocations: partners,
      allowGlobal: isMultiShop,
    );
    if (config == null || !context.mounted) return;
    final rows = ProductsExportSource.collect(config.scope);
    if (rows.isEmpty) {
      AppSnack.info(context,
          'Aucun produit dans ce périmètre');
      return;
    }
    if (config.format == ExportFormat.csv) {
      await ExportService.exportToCsv(
        context,
        config: config,
        header: ProductsExportSource.header,
        rows:   rows,
      );
    } else {
      await ExportService.exportToPdf(
        context,
        config: config,
        header: ProductsExportSource.header,
        rows:   rows,
      );
    }
  }
}

class _Header extends StatelessWidget {
  final String shopName;
  const _Header({required this.shopName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          theme.colorScheme.primary,
          theme.colorScheme.primary.withValues(alpha: 0.8),
        ]),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.file_download_outlined,
              color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Exports',
                    style: AppTextStyles.subtitleBold.copyWith(
                        color: Colors.white)),
                const SizedBox(height: 2),
                Text(
                  'Téléchargez le contenu de $shopName au format CSV ou PDF.',
                  style: AppTextStyles.bodySm.copyWith(
                      color: Colors.white.withValues(alpha: 0.9)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String formats;
  final String scopes;
  final bool   enabled;
  final String? disabledHint;
  final VoidCallback onTap;

  const _ExportCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.formats,
    required this.scopes,
    required this.enabled,
    required this.onTap,
    this.disabledHint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14)),
      elevation: 0,
      color: theme.colorScheme.surface,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: enabled
                      ? theme.colorScheme.primary.withValues(alpha: 0.12)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon,
                    color: enabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface
                            .withValues(alpha: 0.4)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppTextStyles.body.copyWith(
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: AppTextStyles.caption.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.65))),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _Chip(label: formats, theme: theme),
                        _Chip(label: scopes,  theme: theme),
                      ],
                    ),
                    if (!enabled && disabledHint != null) ...[
                      const SizedBox(height: 6),
                      Text(disabledHint!,
                          style: AppTextStyles.caption.copyWith(
                              color: theme.colorScheme.error)),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: enabled
                    ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final ThemeData theme;
  const _Chip({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: AppTextStyles.caption.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600)),
      );
}
