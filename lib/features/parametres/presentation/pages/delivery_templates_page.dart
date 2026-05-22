import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/draggable_fab.dart';
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
          return RefreshIndicator(
            onRefresh: () => ref
                .read(deliveryTemplatesProvider(shopId).notifier)
                .refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: templates.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _TemplateCard(
                template: templates[i],
                canEdit:  canEdit,
                onTap:    () => _openForm(context, ref, templates[i]),
                onSetDefault: () =>
                    _setDefault(context, ref, templates[i]),
                onDelete: () =>
                    _confirmDelete(context, ref, templates[i]),
              ),
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
              onTap: () => _openForm(context, ref, null),
              tooltip: l.deliveryTplCreateBtn,
              child: body,
            )
          : body,
    );
  }

  Future<void> _openForm(
      BuildContext context, WidgetRef ref, DeliveryTemplate? existing) async {
    final saved = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => DeliveryTemplateFormSheet(
        shopId:   shopId,
        existing: existing,
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
