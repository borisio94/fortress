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
import '../../../caisse/data/exports/orders_export_source.dart';
import '../../../crm/data/exports/clients_export_source.dart';
import '../../../inventaire/data/exports/products_export_source.dart';
import '../../data/exports/logs_export_source.dart';

/// Page centrale des exports — accessible depuis Paramètres et depuis
/// le bouton « Télécharger » de chaque module. Une card par type
/// d'export disponible. Chaque card est désactivée si l'utilisateur
/// n'a pas la permission correspondante (avec un hint explicite).
class ExportsPage extends ConsumerWidget {
  final String shopId;
  const ExportsPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider(shopId));
    final shop  = LocalStorageService.getShop(shopId);

    return AppScaffold(
      shopId: shopId,
      title: 'Exports',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(shopName: shop?.name ?? 'Boutique'),
          const SizedBox(height: 16),
          // ── Données catalogue / vente / clients ──────────────────
          _ExportCard(
            icon:        Icons.inventory_2_outlined,
            title:       'Produits',
            subtitle:    'Catalogue · variantes · prix · stock',
            formats:     'CSV · PDF',
            scopes:      'Globale · Boutique · Partenaire',
            enabled:     perms.canExportProducts,
            disabledHint: perms.canExportProducts
                ? null
                : 'Permission « inventory.export » requise',
            onTap: () => _openProductsExport(context, shop?.name),
          ),
          _ExportCard(
            icon:        Icons.receipt_long_outlined,
            title:       'Commandes',
            subtitle:    'Ventes · statuts · paiements · livreur',
            formats:     'CSV · PDF',
            scopes:      'Globale · Boutique · Partenaire',
            enabled:     perms.canExportOrders,
            disabledHint: perms.canExportOrders
                ? null
                : 'Permission « caisse.export » requise',
            onTap: () => _openOrdersExport(context, shop?.name),
          ),
          _ExportCard(
            icon:        Icons.contacts_outlined,
            title:       'Clients',
            subtitle:    'Carnet d\'adresses · segment · valeur',
            formats:     'CSV',
            scopes:      'Globale · Boutique',
            enabled:     perms.canExportClients,
            disabledHint: perms.canExportClients
                ? null
                : 'Permission « crm.export » requise',
            onTap: () => _openClientsExport(context, shop?.name),
          ),
          const SizedBox(height: 16),
          // ── Journaux (paginés Supabase) ──────────────────────────
          _SectionLabel('Journaux'),
          const SizedBox(height: 8),
          _ExportCard(
            icon:        Icons.history_rounded,
            title:       'Activité',
            subtitle:    'Actions tracées (créations, modifs, suppressions)',
            formats:     'CSV',
            scopes:      'Globale · Boutique',
            enabled:     perms.canViewActivity,
            disabledHint: perms.canViewActivity
                ? null
                : 'Lecture activité non autorisée',
            onTap: () => _openLogsExport(
                context, shop?.name, LogsSubtype.activity),
          ),
          _ExportCard(
            icon:        Icons.swap_horiz_rounded,
            title:       'Mouvements de stock',
            subtitle:    'Entrées, sorties, ajustements, transferts',
            formats:     'CSV',
            scopes:      'Globale · Boutique',
            enabled:     perms.canManageStock,
            disabledHint: perms.canManageStock
                ? null
                : 'Gestion stock requise',
            onTap: () => _openLogsExport(
                context, shop?.name, LogsSubtype.stockMovements),
          ),
          _ExportCard(
            icon:        Icons.payments_outlined,
            title:       'Dépenses',
            subtitle:    'Charges opérationnelles (loyer, salaires, …)',
            formats:     'CSV',
            scopes:      'Globale · Boutique',
            enabled:     perms.canExportFinances,
            disabledHint: perms.canExportFinances
                ? null
                : 'Permission « finance.export » requise',
            onTap: () => _openLogsExport(
                context, shop?.name, LogsSubtype.expenses),
          ),
          _ExportCard(
            icon:        Icons.groups_outlined,
            title:       'Évènements RH',
            subtitle:    'Création, suspension, changement de rôle',
            formats:     'CSV',
            scopes:      'Globale · Boutique',
            enabled:     perms.canManageMembers,
            disabledHint: perms.canManageMembers
                ? null
                : 'Gestion employés requise',
            onTap: () => _openLogsExport(
                context, shop?.name, LogsSubtype.hr),
          ),
        ],
      ),
    );
  }

  // ── Handlers ─────────────────────────────────────────────────────

  Future<void> _openProductsExport(
      BuildContext context, String? shopName) async {
    final partners =
        ProductsExportSource.partnerLocationsForShop(shopId);
    final config = await ExportScopeSelector.show(
      context,
      type: ExportType.products,
      shopId: shopId,
      shopName: shopName,
      partnerLocations: partners,
    );
    if (config == null || !context.mounted) return;
    final rows = ProductsExportSource.collect(config.scope);
    if (rows.isEmpty) {
      AppSnack.info(context, 'Aucun produit dans ce périmètre');
      return;
    }
    await _runExport(
      context, config, ProductsExportSource.header, rows);
  }

  Future<void> _openOrdersExport(
      BuildContext context, String? shopName) async {
    final partners =
        OrdersExportSource.partnerLocationsForShop(shopId);
    final config = await ExportScopeSelector.show(
      context,
      type: ExportType.orders,
      shopId: shopId,
      shopName: shopName,
      partnerLocations: partners,
    );
    if (config == null || !context.mounted) return;
    final rows = OrdersExportSource.collect(config.scope);
    if (rows.isEmpty) {
      AppSnack.info(context, 'Aucune commande dans ce périmètre');
      return;
    }
    await _runExport(
      context, config, OrdersExportSource.header, rows);
  }

  Future<void> _openClientsExport(
      BuildContext context, String? shopName) async {
    final config = await ExportScopeSelector.show(
      context,
      type:             ExportType.clients,
      shopId:           shopId,
      shopName:         shopName,
      allowPartner:     false,
      supportedFormats: const [ExportFormat.csv],
    );
    if (config == null || !context.mounted) return;
    final rows = ClientsExportSource.collect(config.scope);
    if (rows.isEmpty) {
      AppSnack.info(context, 'Aucun client dans ce périmètre');
      return;
    }
    await _runExport(
      context, config, ClientsExportSource.header, rows);
  }

  Future<void> _openLogsExport(
      BuildContext context, String? shopName, LogsSubtype subtype) async {
    final config = await ExportScopeSelector.show(
      context,
      type:             ExportType.logs,
      shopId:           shopId,
      shopName:         shopName,
      allowPartner:     false,
      supportedFormats: const [ExportFormat.csv],
    );
    if (config == null || !context.mounted) return;
    // Fetch Supabase paginé — peut durer 2-3s sur grosse base. On
    // montre un loader bloquant pour éviter qu'un double-tap relance
    // un nouvel export en parallèle.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: SizedBox(
          width: 56, height: 56,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );
    LogsExportResult result;
    try {
      result = await LogsExportSource.collect(
          scope: config.scope, subtype: subtype);
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        AppSnack.error(context, 'Erreur fetch logs : $e');
      }
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (result.rows.isEmpty) {
      AppSnack.info(context, 'Aucune entrée dans ce périmètre');
      return;
    }
    // Le filename embarque le sous-type pour distinguer les CSV logs.
    final tunedConfig = ExportConfig(
      type:       config.type,
      scope:      config.scope,
      format:     config.format,
      scopeLabel: '${subtype.labelFr} — ${config.scopeLabel}',
      shopName:   config.shopName,
    );
    await ExportService.exportToCsv(
      context,
      config: tunedConfig,
      header: subtype.header,
      rows:   result.rows,
    );
    if (context.mounted && result.truncated) {
      AppSnack.info(context,
          'Export tronqué à 5 000 lignes — affinez le périmètre.');
    }
  }

  Future<void> _runExport(
    BuildContext context,
    ExportConfig config,
    List<String> header,
    List<List<Object?>> rows,
  ) async {
    if (config.format == ExportFormat.csv) {
      await ExportService.exportToCsv(
        context, config: config, header: header, rows: rows);
    } else {
      await ExportService.exportToPdf(
        context, config: config, header: header, rows: rows);
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

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 6),
      child: Text(label.toUpperCase(),
          style: AppTextStyles.captionBold.copyWith(
              letterSpacing: 0.6,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
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
