import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/draggable_fab.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
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
                  ? _openDeliveryForm(context, existing: null)
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
              onCopy:   () => _copyWhatsapp(context, filtered[i]),
              onSetDefault: () => _setDefault(context, ref, filtered[i]),
              onDelete: () => _confirmDelete(context, ref, filtered[i]),
            ),
          ),
        );
      },
    );
  }

  // ── Liste modèles de LIVRAISON groupée par portée (hotfix_093) ────────
  // Section "Shop — tous partenaires" puis 1 section par partenaire actif,
  // chacune avec son propre bouton « + ajouter » qui pré-sélectionne le
  // scope. Les partenaires sans template affichent un hint cliquable.
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
        // Bucket par portée.
        final shopTpls = templates
            .where((t) => t.partnerId == null).toList();
        final byPartner = <String, List<DeliveryTemplate>>{};
        for (final t in templates) {
          if (t.partnerId == null) continue;
          byPartner.putIfAbsent(t.partnerId!, () => []).add(t);
        }
        // Partenaires actifs du propriétaire (toutes boutiques confondues
        // — cf. project_multishop_roadmap : owner-scoped).
        final ownerId = Supabase.instance.client.auth.currentUser?.id;
        final allPartners = ownerId == null
            ? const <StockLocation>[]
            : AppDatabase.getStockLocationsForOwner(ownerId)
                .where((l) =>
                    l.type == StockLocationType.partner && l.isActive)
                .toList()
              ..sort((a, b) => a.name.toLowerCase()
                  .compareTo(b.name.toLowerCase()));

        // État vide global : aucun template ET aucun partenaire → CTA simple.
        if (templates.isEmpty && allPartners.isEmpty) {
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
                    onPressed: () =>
                        _openDeliveryForm(context, existing: null),
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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: [
              _DeliverySectionHeader(
                icon:     Icons.store_outlined,
                label:    'Shop — tous partenaires',
                subtitle: 'Modèle utilisé par défaut',
                count:    shopTpls.length,
                onAdd:    canEdit
                    ? () => _openDeliveryForm(context,
                        existing: null, partnerId: null)
                    : null,
              ),
              const SizedBox(height: 8),
              if (shopTpls.isEmpty)
                _DeliveryEmptyHint(
                  text: 'Aucun modèle shop-wide.',
                  canCreate: canEdit,
                  onCreate: () => _openDeliveryForm(context,
                      existing: null, partnerId: null),
                )
              else
                for (final t in shopTpls) Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _DeliveryCard(
                    template: t,
                    partner:  null, // shop-wide → pas de partner context
                    canEdit:  canEdit,
                    onTap:    () =>
                        _openDeliveryForm(context, existing: t),
                    onCopy:   () => _copyDelivery(context, t, null),
                    onSetDefault: () =>
                        _setDeliveryDefault(context, t),
                    onDelete: () =>
                        _confirmDeleteDelivery(context, t),
                  ),
                ),
              const SizedBox(height: 18),
              for (final p in allPartners) ...[
                _DeliverySectionHeader(
                  icon:     Icons.local_shipping_outlined,
                  label:    p.name,
                  subtitle: 'Modèles dédiés à ce partenaire',
                  count:    byPartner[p.id]?.length ?? 0,
                  onAdd:    canEdit
                      ? () => _openDeliveryForm(context,
                          existing: null, partnerId: p.id)
                      : null,
                ),
                const SizedBox(height: 8),
                if ((byPartner[p.id] ?? const []).isEmpty)
                  _DeliveryEmptyHint(
                    text: 'Aucun modèle — ${p.name} utilisera le défaut shop.',
                    canCreate: canEdit,
                    onCreate: () => _openDeliveryForm(context,
                        existing: null, partnerId: p.id),
                  )
                else
                  for (final t in byPartner[p.id]!) Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _DeliveryCard(
                      template: t,
                      partner:  p, // résout {{partner_*}} pour le copier-coller
                      canEdit:  canEdit,
                      onTap:    () =>
                          _openDeliveryForm(context, existing: t),
                      onCopy:   () => _copyDelivery(context, t, p),
                      onSetDefault: () =>
                          _setDeliveryDefault(context, t),
                      onDelete: () =>
                          _confirmDeleteDelivery(context, t),
                    ),
                  ),
                const SizedBox(height: 18),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _openDeliveryForm(BuildContext context,
      {DeliveryTemplate? existing, String? partnerId}) async {
    final saved = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => DeliveryTemplateFormSheet(
        shopId:           widget.shopId,
        existing:         existing,
        initialPartnerId: partnerId,
      ),
    );
    if (saved == true && context.mounted) {
      AppSnack.success(context, 'Modèle de livraison enregistré');
    }
  }

  /// Copie le corps du template dans le presse-papier. Si [partner] est
  /// fourni (template partner-scoped), les variables `{{partner_*}}` sont
  /// résolues depuis ce partenaire — les autres variables ({{client_name}},
  /// {{produits}}, …) restent en placeholder car on n'a pas d'order context
  /// dans cette page (l'utilisateur les remplacera dans WhatsApp).
  Future<void> _copyDelivery(
      BuildContext context, DeliveryTemplate t, StockLocation? partner) async {
    var body = t.body;
    if (partner != null) {
      String partnerCity() {
        final d = (partner.district ?? '').trim();
        final c = (partner.city     ?? '').trim();
        if (d.isNotEmpty && c.isNotEmpty) return '$d, $c';
        if (d.isNotEmpty) return d;
        if (c.isNotEmpty) return c;
        return (partner.address ?? '').trim();
      }
      body = body
          .replaceAll('{{partner_name}}',  partner.name.trim())
          .replaceAll('{{partner_phone}}', (partner.phone ?? '').trim())
          .replaceAll('{{partner_city}}',  partnerCity())
          .replaceAll('{{partner_notes}}', (partner.notes ?? '').trim());
    }
    await Clipboard.setData(ClipboardData(text: body));
    if (context.mounted) {
      AppSnack.success(context,
          partner != null
              ? 'Modèle copié (variables ${partner.name} résolues)'
              : 'Modèle copié dans le presse-papier');
    }
  }

  /// Copie le corps brut d'un template WhatsApp client.
  Future<void> _copyWhatsapp(
      BuildContext context, WhatsappTemplate t) async {
    await Clipboard.setData(ClipboardData(text: t.body));
    if (context.mounted) {
      AppSnack.success(context, 'Template copié dans le presse-papier');
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
        color: Theme.of(context).colorScheme.surface,
        border: Border(bottom: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
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
  /// Partenaire de cette section (null si shop-wide) — sert au libellé
  /// du tooltip Copier (« Copier (résout les variables de <partenaire>) »).
  final StockLocation?   partner;
  final bool             canEdit;
  final VoidCallback     onTap;
  final VoidCallback     onCopy;
  final VoidCallback     onSetDefault;
  final VoidCallback     onDelete;
  const _DeliveryCard({
    required this.template,
    required this.partner,
    required this.canEdit,
    required this.onTap,
    required this.onCopy,
    required this.onSetDefault,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
                // Bouton Copier : visible pour tous (canEdit pas requis —
                // copier ne modifie rien). Tooltip explicite quand un
                // partenaire est résolu.
                IconButton(
                  onPressed: onCopy,
                  icon: const Icon(Icons.content_copy_rounded, size: 16),
                  tooltip: partner != null
                      ? 'Copier (variables ${partner!.name} résolues)'
                      : 'Copier le message',
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(
                      minWidth: 32, minHeight: 32),
                  color: AppColors.primary,
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
  final VoidCallback     onCopy;
  final VoidCallback     onSetDefault;
  final VoidCallback     onDelete;
  const _TemplateCard({
    required this.template,
    required this.canEdit,
    required this.onTap,
    required this.onCopy,
    required this.onSetDefault,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
                // Bouton Copier visible pour tous (ne modifie pas la data).
                IconButton(
                  onPressed: onCopy,
                  icon: const Icon(Icons.content_copy_rounded, size: 16),
                  tooltip: 'Copier le message',
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(
                      minWidth: 32, minHeight: 32),
                  color: AppColors.primary,
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

/// En-tête de section pour la vue Livraison groupée par portée (hotfix_093).
class _DeliverySectionHeader extends StatelessWidget {
  final IconData      icon;
  final String        label;
  final String        subtitle;
  final int           count;
  final VoidCallback? onAdd;
  const _DeliverySectionHeader({
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
          tooltip: 'Ajouter un modèle à cette portée',
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

/// Carte placeholder pour une portée sans modèle (hotfix_093).
class _DeliveryEmptyHint extends StatelessWidget {
  final String        text;
  final bool          canCreate;
  final VoidCallback  onCreate;
  const _DeliveryEmptyHint({
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
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Row(children: [
        Expanded(child: Text(text,
            style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary))),
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
