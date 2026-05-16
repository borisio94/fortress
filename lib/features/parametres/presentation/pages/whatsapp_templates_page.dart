import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/draggable_fab.dart';
import '../../domain/entities/whatsapp_template.dart';
import '../providers/whatsapp_template_provider.dart';
import '../widgets/whatsapp_template_form_sheet.dart';
import '../../domain/entities/delivery_template.dart';
import '../providers/delivery_template_provider.dart';
import '../widgets/delivery_template_form_sheet.dart';

// ═════════════════════════════════════════════════════════════════════════════
// WhatsappTemplatesPage — CRUD des templates de message WhatsApp envoyés aux
// clients (factures, relances, catalogue, nouveautés, promotion).
//
// Calquée sur DeliveryTemplatesPage (hotfix_049). Ajoute un filtre par type
// en chips horizontaux. Le FAB crée un nouveau template avec le type filtré
// pré-sélectionné.
// ═════════════════════════════════════════════════════════════════════════════

class WhatsappTemplatesPage extends ConsumerStatefulWidget {
  final String shopId;
  const WhatsappTemplatesPage({super.key, required this.shopId});

  @override
  ConsumerState<WhatsappTemplatesPage> createState() =>
      _WhatsappTemplatesPageState();
}

class _WhatsappTemplatesPageState
    extends ConsumerState<WhatsappTemplatesPage> {
  /// null = tous types, sinon filtre. Si [_delivery] est vrai, on affiche
  /// les modèles de LIVRAISON (système distinct delivery_templates) à la
  /// place — même UI (chip + card + form), pipeline d'envoi inchangé.
  WhatsappTemplateType? _filter;
  bool _delivery = false;

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final canEdit = perms.canEditShopInfo;

    final filterBar = _TypeFilterBar(
      current:  _filter,
      delivery: _delivery,
      onChanged: (t) => setState(() { _filter = t; _delivery = false; }),
      onDelivery: () => setState(() => _delivery = true),
    );

    final Widget listArea = _delivery
        ? _buildDeliveryList(context, canEdit)
        : _buildWhatsappList(context, canEdit);

    final body = Column(children: [filterBar, Expanded(child: listArea)]);

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Modèles WhatsApp',
      isRootPage: false,
      body: canEdit
          ? DraggableFabContainer(
              storageKey: 'whatsapp-templates',
              onTap: () => _delivery
                  ? _openDeliveryForm(context, null)
                  : _openForm(context, ref, null),
              tooltip: _delivery
                  ? 'Nouveau modèle de livraison'
                  : 'Nouveau template',
              child: body,
            )
          : body,
    );
  }

  // ── Liste templates WhatsApp (facture, relance, catalogue, …) ──────────
  Widget _buildWhatsappList(BuildContext context, bool canEdit) {
    final asyncList = ref.watch(whatsappTemplatesProvider(widget.shopId));
    return asyncList.when(
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
        final filtered = _filter == null
            ? templates
            : templates.where((t) => t.type == _filter).toList();
        if (filtered.isEmpty) {
          return _EmptyState(
              filter: _filter,
              canEdit: canEdit,
              onCreate: () => _openForm(context, ref, null));
        }
        return RefreshIndicator(
          onRefresh: () => ref
              .read(whatsappTemplatesProvider(widget.shopId).notifier)
              .refresh(),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _TemplateCard(
              template: filtered[i],
              canEdit:  canEdit,
              onTap:    () => _openForm(context, ref, filtered[i]),
              onSetDefault: () => _setDefault(context, ref, filtered[i]),
              onDelete: () => _confirmDelete(context, ref, filtered[i]),
            ),
          ),
        );
      },
    );
  }

  // ── Liste modèles de LIVRAISON (système delivery_templates, intact) ────
  Widget _buildDeliveryList(BuildContext context, bool canEdit) {
    final asyncList = ref.watch(deliveryTemplatesProvider(widget.shopId));
    return asyncList.when(
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
                Icon(Icons.local_shipping_outlined,
                    size: 56, color: AppColors.textHint),
                const SizedBox(height: 12),
                Text('Aucun modèle de livraison.',
                    style: TextStyle(color: AppColors.textHint)),
                if (canEdit) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () => _openDeliveryForm(context, null),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Créer un modèle de livraison'),
                  ),
                ],
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref
              .read(deliveryTemplatesProvider(widget.shopId).notifier)
              .refresh(),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: templates.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _DeliveryCard(
              template: templates[i],
              canEdit:  canEdit,
              onTap:    () => _openDeliveryForm(context, templates[i]),
              onSetDefault: () =>
                  _setDeliveryDefault(context, templates[i]),
              onDelete: () =>
                  _confirmDeleteDelivery(context, templates[i]),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openDeliveryForm(
      BuildContext context, DeliveryTemplate? existing) async {
    final saved = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => DeliveryTemplateFormSheet(
        shopId:   widget.shopId,
        existing: existing,
      ),
    );
    if (saved == true && context.mounted) {
      AppSnack.success(context, 'Modèle de livraison enregistré');
    }
  }

  Future<void> _setDeliveryDefault(
      BuildContext context, DeliveryTemplate t) async {
    if (t.isDefault) return;
    try {
      await ref
          .read(deliveryTemplatesProvider(widget.shopId).notifier)
          .updateTemplate(t.copyWith(isDefault: true));
      if (context.mounted) AppSnack.success(context, 'Défaut mis à jour');
    } catch (e) {
      if (context.mounted) AppSnack.error(context, e.toString());
    }
  }

  Future<void> _confirmDeleteDelivery(
      BuildContext context, DeliveryTemplate t) async {
    if (t.isDefault) {
      AppSnack.error(context,
          'Impossible de supprimer le modèle par défaut. '
          'Désigne un autre modèle comme défaut d\'abord.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce modèle de livraison ?'),
        content: const Text('Cette action est irréversible.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error),
              child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(deliveryTemplatesProvider(widget.shopId).notifier)
          .deleteTemplate(t.id);
      if (context.mounted) AppSnack.success(context, 'Modèle supprimé');
    } catch (e) {
      if (context.mounted) AppSnack.error(context, e.toString());
    }
  }

  Future<void> _openForm(
      BuildContext context, WidgetRef ref, WhatsappTemplate? existing) async {
    final saved = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => WhatsappTemplateFormSheet(
        shopId:      widget.shopId,
        existing:    existing,
        initialType: _filter,
      ),
    );
    if (saved == true && context.mounted) {
      AppSnack.success(context, 'Template enregistré');
    }
  }

  Future<void> _setDefault(
      BuildContext context, WidgetRef ref, WhatsappTemplate t) async {
    if (t.isDefault) return;
    try {
      await ref
          .read(whatsappTemplatesProvider(widget.shopId).notifier)
          .updateTemplate(t.copyWith(isDefault: true));
      if (context.mounted) AppSnack.success(context, 'Défaut mis à jour');
    } catch (e) {
      if (context.mounted) AppSnack.error(context, e.toString());
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, WhatsappTemplate t) async {
    if (t.isDefault) {
      AppSnack.error(context,
          'Impossible de supprimer un template défini par défaut. '
          'Désigne un autre template comme défaut d\'abord.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer ce template ?'),
        content: const Text(
            'Cette action est irréversible. Les envois en cours ne sont pas '
            'affectés.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.error),
              child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(whatsappTemplatesProvider(widget.shopId).notifier)
          .deleteTemplate(t.id);
      if (context.mounted) AppSnack.success(context, 'Template supprimé');
    } catch (e) {
      if (context.mounted) AppSnack.error(context, e.toString());
    }
  }
}

// ─── Barre de filtre par type (chips horizontaux) ────────────────────────
class _TypeFilterBar extends StatelessWidget {
  final WhatsappTemplateType? current;
  final bool                  delivery;
  final ValueChanged<WhatsappTemplateType?> onChanged;
  final VoidCallback          onDelivery;
  const _TypeFilterBar({
    required this.current,
    required this.delivery,
    required this.onChanged,
    required this.onDelivery,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _Chip(label: 'Tous',
              selected: current == null && !delivery,
              onTap: () => onChanged(null)),
          const SizedBox(width: 6),
          for (final t in WhatsappTemplateType.values) ...[
            _Chip(label: t.label,
                selected: current == t && !delivery,
                onTap: () => onChanged(t)),
            const SizedBox(width: 6),
          ],
          // Modèles de livraison (système distinct, même UI).
          _Chip(label: 'Livraison', selected: delivery,
              onTap: onDelivery),
          const SizedBox(width: 6),
        ]),
      ),
    );
  }
}

// ─── Card d'un modèle de livraison (style identique à _TemplateCard) ─────
class _DeliveryCard extends StatelessWidget {
  final DeliveryTemplate template;
  final bool             canEdit;
  final VoidCallback     onTap;
  final VoidCallback     onSetDefault;
  final VoidCallback     onDelete;
  const _DeliveryCard({
    required this.template,
    required this.canEdit,
    required this.onTap,
    required this.onSetDefault,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
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
                    : AppColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text('Livraison',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary)),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(template.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (template.isDefault)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text('Défaut',
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
                      if (v == 'default') onSetDefault();
                      if (v == 'delete')  onDelete();
                    },
                    itemBuilder: (_) => [
                      if (!template.isDefault)
                        const PopupMenuItem(
                            value: 'default',
                            child: Text('Définir comme défaut')),
                      PopupMenuItem(
                          value: 'delete',
                          child: Text('Supprimer',
                              style: TextStyle(color: AppColors.error))),
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

class _Chip extends StatelessWidget {
  final String label;
  final bool   selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.primary
                  : AppColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: selected
                      ? AppColors.primary
                      : AppColors.primary.withValues(alpha: 0.2)),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppColors.primary)),
          ),
        ),
      );
}

// ─── Card d'un template ──────────────────────────────────────────────────
class _TemplateCard extends StatelessWidget {
  final WhatsappTemplate template;
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
    return Material(
      color: Colors.white,
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
                    : AppColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(template.type.label,
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary)),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(template.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (template.isDefault)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text('Défaut',
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
                        const PopupMenuItem(
                            value: 'default',
                            child: Text('Définir comme défaut')),
                      PopupMenuItem(
                          value: 'delete',
                          child: Text('Supprimer',
                              style: TextStyle(color: AppColors.error))),
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

class _EmptyState extends StatelessWidget {
  final WhatsappTemplateType? filter;
  final bool                  canEdit;
  final VoidCallback          onCreate;
  const _EmptyState({
    required this.filter,
    required this.canEdit,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final msg = filter == null
        ? 'Aucun template encore créé.'
        : 'Aucun template pour ${filter!.label.toLowerCase()}.';
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_outlined, size: 56, color: AppColors.textHint),
          const SizedBox(height: 12),
          Text(msg, style: TextStyle(color: AppColors.textHint)),
          if (canEdit) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Créer un template'),
            ),
          ],
        ],
      ),
    );
  }
}
