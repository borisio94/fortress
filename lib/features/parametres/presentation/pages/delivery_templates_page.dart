import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/draggable_fab.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../domain/entities/delivery_template.dart';
import '../providers/delivery_template_provider.dart';
import '../widgets/delivery_template_form_sheet.dart';

/// Liste des templates de livraison du shop. Permet de :
/// • créer un nouveau template (FAB)
/// • éditer un template existant (tap sur la carte)
/// • définir un template comme défaut
/// • supprimer (sauf le défaut)
class DeliveryTemplatesPage extends ConsumerWidget {
  final String shopId;
  const DeliveryTemplatesPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final perms = ref.watch(permissionsProvider(shopId));
    final canEdit = perms.canEditShopInfo;
    final asyncList = ref.watch(deliveryTemplatesProvider(shopId));

    final body = asyncList.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(e.toString(),
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.error)),
          ),
        ),
        data: (templates) {
          if (templates.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.message_outlined,
                      size: 56, color: AppColors.textHint),
                  const SizedBox(height: 12),
                  Text(l.deliveryTplListEmpty,
                      style: TextStyle(color: AppColors.textHint)),
                ],
              ),
            );
          }
          // ── Grouping par scope (hotfix_093) ───────────────────────
          // 1 section "Shop — tous partenaires" + N sections par partenaire.
          // Les partenaires sans template sont quand même listés (avec un
          // bouton « + ajouter ») pour qu'on puisse rapidement leur en
          // attacher un.
          final shopTpls = templates
              .where((t) => t.partnerId == null).toList();
          final byPartner = <String, List<DeliveryTemplate>>{};
          for (final t in templates) {
            if (t.partnerId == null) continue;
            byPartner.putIfAbsent(t.partnerId!, () => []).add(t);
          }
          final ownerId = Supabase.instance.client.auth.currentUser?.id;
          final allPartners = ownerId == null
              ? const <StockLocation>[]
              : AppDatabase.getStockLocationsForOwner(ownerId)
                  .where((l) =>
                      l.type == StockLocationType.partner && l.isActive)
                  .toList()
                ..sort((a, b) => a.name.toLowerCase()
                    .compareTo(b.name.toLowerCase()));

          return RefreshIndicator(
            onRefresh: () => ref
                .read(deliveryTemplatesProvider(shopId).notifier)
                .refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                _SectionHeader(
                  icon: Icons.store_outlined,
                  label: 'Shop — tous partenaires',
                  subtitle: 'Templates utilisés par défaut',
                  count: shopTpls.length,
                  onAdd: canEdit ? () => _openForm(context, ref,
                      existing: null, partnerId: null) : null,
                ),
                const SizedBox(height: 8),
                if (shopTpls.isEmpty)
                  _EmptyHint(text: 'Aucun template shop-wide.',
                      canCreate: canEdit,
                      onCreate: () => _openForm(context, ref,
                          existing: null, partnerId: null))
                else
                  for (final t in shopTpls) Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _TemplateCard(
                      template: t,
                      canEdit:  canEdit,
                      onTap:    () => _openForm(context, ref, existing: t),
                      onSetDefault: () => _setDefault(context, ref, t),
                      onDelete: () => _confirmDelete(context, ref, t),
                    ),
                  ),
                const SizedBox(height: 18),
                for (final p in allPartners) ...[
                  _SectionHeader(
                    // local_shipping plutôt que handshake — cf.
                    // project_icon_tree_shaking (handshake dans plan
                    // Unicode supplémentaire, à éviter).
                    icon:     Icons.local_shipping_outlined,
                    label:    p.name,
                    subtitle: 'Templates dédiés à ce partenaire',
                    count:    byPartner[p.id]?.length ?? 0,
                    onAdd:    canEdit ? () => _openForm(context, ref,
                        existing: null, partnerId: p.id) : null,
                  ),
                  const SizedBox(height: 8),
                  if ((byPartner[p.id] ?? const []).isEmpty)
                    _EmptyHint(
                      text: 'Aucun template — ${p.name} utilisera le défaut shop.',
                      canCreate: canEdit,
                      onCreate: () => _openForm(context, ref,
                          existing: null, partnerId: p.id),
                    )
                  else
                    for (final t in byPartner[p.id]!) Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _TemplateCard(
                        template: t,
                        canEdit:  canEdit,
                        onTap:    () => _openForm(context, ref, existing: t),
                        onSetDefault: () => _setDefault(context, ref, t),
                        onDelete: () => _confirmDelete(context, ref, t),
                      ),
                    ),
                  const SizedBox(height: 18),
                ],
              ],
            ),
          );
        },
      );

    return AppScaffold(
      shopId: shopId,
      title: l.deliveryTemplatesTitle,
      // FAB draggable cohérent avec les autres pages CRUD (Inventaire,
      // Clients). L'utilisateur peut le repositionner s'il masque une row.
      body: canEdit
          ? DraggableFabContainer(
              storageKey: 'delivery-templates',
              onTap: () => _openForm(context, ref),
              tooltip: l.deliveryTplCreateBtn,
              child: body,
            )
          : body,
    );
  }

  Future<void> _openForm(BuildContext context, WidgetRef ref,
      {DeliveryTemplate? existing, String? partnerId}) async {
    final saved = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => DeliveryTemplateFormSheet(
        shopId:           shopId,
        existing:         existing,
        initialPartnerId: partnerId,
      ),
    );
    if (saved == true && context.mounted) {
      AppSnack.success(context, context.l10n.deliveryTplSaved);
    }
  }

  Future<void> _setDefault(
      BuildContext context, WidgetRef ref, DeliveryTemplate t) async {
    if (t.isDefault) return;
    try {
      await ref
          .read(deliveryTemplatesProvider(shopId).notifier)
          .updateTemplate(t.copyWith(isDefault: true));
      if (context.mounted) {
        AppSnack.success(context, context.l10n.deliveryTplSaved);
      }
    } catch (e) {
      if (context.mounted) AppSnack.error(context, e.toString());
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, DeliveryTemplate t) async {
    final l = context.l10n;
    if (t.isDefault) {
      AppSnack.error(context, l.deliveryTplDeleteDefaultBlocked);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.deliveryTplDelete),
        content: Text(l.deliveryTplDeleteConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l.cancel)),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.error),
              child: Text(l.deliveryTplDelete)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(deliveryTemplatesProvider(shopId).notifier)
          .deleteTemplate(t.id);
      if (context.mounted) {
        AppSnack.success(context, l.deliveryTplDeleted);
      }
    } catch (e) {
      if (context.mounted) AppSnack.error(context, e.toString());
    }
  }
}

class _TemplateCard extends StatelessWidget {
  final DeliveryTemplate template;
  final bool             canEdit;
  final VoidCallback     onTap;
  final VoidCallback     onSetDefault;
  final VoidCallback     onDelete;
  const _TemplateCard({
    required this.template,
    required this.canEdit,
    required this.onTap,
    required this.onSetDefault,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: canEdit ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: template.isDefault
                    ? AppColors.primary.withValues(alpha: 0.4)
                    : Theme.of(context).semantic.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(template.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (template.isDefault)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color:
                            AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(l.deliveryTplDefaultBadge,
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary)),
                  ),
                if (canEdit)
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert_rounded,
                        size: 18, color: AppColors.textHint),
                    onSelected: (v) {
                      switch (v) {
                        case 'default': onSetDefault(); break;
                        case 'delete':  onDelete();     break;
                      }
                    },
                    itemBuilder: (_) => [
                      if (!template.isDefault)
                        PopupMenuItem(
                            value: 'default',
                            child: Text(l.deliveryTplSetDefault)),
                      PopupMenuItem(
                          value: 'delete',
                          child: Text(l.deliveryTplDelete,
                              style:
                                  TextStyle(color: AppColors.error))),
                    ],
                  ),
              ]),
              const SizedBox(height: 8),
              Text(template.body,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: AppColors.textSecondary,
                      fontFamily: 'monospace')),
            ],
          ),
        ),
      ),
    );
  }
}

/// En-tête de section dans la page Templates : icône + label + compteur
/// + bouton « + ajouter » contextuel à la section (hotfix_093).
class _SectionHeader extends StatelessWidget {
  final IconData      icon;
  final String        label;
  final String        subtitle;
  final int           count;
  final VoidCallback? onAdd;
  const _SectionHeader({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.count,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Container(width: 28, height: 28,
          decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(7)),
          child: Icon(icon, size: 15, color: AppColors.primary)),
      const SizedBox(width: 10),
      Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Flexible(child: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface))),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8)),
            child: Text('$count', style: AppTextStyles.microBold
                .copyWith(color: AppColors.primary)),
          ),
        ]),
        Text(subtitle, style: AppTextStyles.microSecondary),
      ])),
      if (onAdd != null)
        IconButton(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded, size: 18),
          tooltip: 'Ajouter un template à cette portée',
          style: IconButton.styleFrom(
            backgroundColor: AppColors.primary.withValues(alpha: 0.08),
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.all(6),
            minimumSize: const Size(32, 32),
          ),
        ),
    ]);
  }
}

/// Carte placeholder quand une section n'a pas encore de template.
class _EmptyHint extends StatelessWidget {
  final String        text;
  final bool          canCreate;
  final VoidCallback  onCreate;
  const _EmptyHint({
    required this.text,
    required this.canCreate,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: Theme.of(context).semantic.borderSubtle,
            style: BorderStyle.solid),
      ),
      child: Row(children: [
        Expanded(child: Text(text,
            style: AppTextStyles.captionHint
                .copyWith(color: AppColors.textSecondary))),
        if (canCreate)
          TextButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add_rounded, size: 14),
            label: const Text('Ajouter'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 32),
            ),
          ),
      ]),
    );
  }
}
