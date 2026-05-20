import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/draggable_fab.dart';
import '../../domain/entities/promo_campaign.dart';
import '../providers/promo_campaign_provider.dart';
import '../widgets/campaign_form_sheet.dart';

// ═════════════════════════════════════════════════════════════════════════════
// CampaignsPage — liste des campagnes marketing du shop (promotions +
// annonces nouveautés). FAB pour créer, popup menu sur chaque card pour
// envoyer / éditer / supprimer.
// ═════════════════════════════════════════════════════════════════════════════

class CampaignsPage extends ConsumerStatefulWidget {
  final String shopId;
  const CampaignsPage({super.key, required this.shopId});

  @override
  ConsumerState<CampaignsPage> createState() => _CampaignsPageState();
}

class _CampaignsPageState extends ConsumerState<CampaignsPage> {
  PromoCampaignType? _filter;

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final canEdit = perms.canEditShopInfo;
    final asyncList = ref.watch(promoCampaignsProvider(widget.shopId));

    final body = Column(children: [
      _TypeFilterBar(
        current: _filter,
        onChanged: (t) => setState(() => _filter = t),
      ),
      Expanded(
        child: asyncList.when(
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
          data: (campaigns) {
            final filtered = _filter == null
                ? campaigns
                : campaigns.where((c) => c.type == _filter).toList();
            if (filtered.isEmpty) {
              return _EmptyState(
                  canEdit: canEdit,
                  onCreate: () => _openForm(context, null));
            }
            return RefreshIndicator(
              onRefresh: () => ref
                  .read(promoCampaignsProvider(widget.shopId).notifier)
                  .refresh(),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _CampaignCard(
                  campaign: filtered[i],
                  canEdit:  canEdit,
                  onSend:   () => _openSendPage(context, filtered[i]),
                  onEdit:   () => _openForm(context, filtered[i]),
                  onDelete: () => _confirmDelete(context, filtered[i]),
                  onPreview: () => _openPreview(context, filtered[i]),
                ),
              ),
            );
          },
        ),
      ),
    ]);

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Campagnes marketing',
      isRootPage: false,
      body: canEdit
          ? DraggableFabContainer(
              storageKey: 'campaigns',
              onTap: () => _openForm(context, null),
              tooltip: 'Nouvelle campagne',
              child: body,
            )
          : body,
    );
  }

  Future<void> _openForm(BuildContext context, PromoCampaign? existing) async {
    final saved = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => CampaignFormSheet(
        shopId:   widget.shopId,
        existing: existing,
        initialType: _filter,
      ),
    );
    if (saved == true && context.mounted) {
      AppSnack.success(context, 'Campagne enregistrée');
    }
  }

  void _openSendPage(BuildContext context, PromoCampaign c) {
    context.push('/shop/${widget.shopId}/campaigns/${c.id}/send');
  }

  void _openPreview(BuildContext context, PromoCampaign c) {
    final origin = Uri.base.origin.startsWith('http')
        ? Uri.base.origin
        : 'https://fortress-pos.web.app';
    final url = '$origin/#/promo/${c.shopId}/${c.id}';
    showDialog<void>(
      context: context,
      // ctx du builder pour fermer correctement le dialog. Utiliser le
      // context du parent (showDialog) pouvait pointer vers un Navigator
      // qui n'inclut pas la route du dialog dans certains layouts shell.
      builder: (ctx) => AlertDialog(
        title: const Text('Lien public'),
        content: SelectableText(url,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Fermer')),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, PromoCampaign c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer la campagne ?'),
        content: const Text(
            'Le lien public ne sera plus accessible après suppression.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.error),
              child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(promoCampaignsProvider(widget.shopId).notifier)
          .deleteCampaign(c.id);
      if (context.mounted) AppSnack.success(context, 'Campagne supprimée');
    } catch (e) {
      if (context.mounted) AppSnack.error(context, e.toString());
    }
  }
}

class _TypeFilterBar extends StatelessWidget {
  final PromoCampaignType? current;
  final ValueChanged<PromoCampaignType?> onChanged;
  const _TypeFilterBar({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(children: [
        _Chip(label: 'Toutes', selected: current == null,
            onTap: () => onChanged(null)),
        const SizedBox(width: 6),
        _Chip(label: 'Promotions',
            selected: current == PromoCampaignType.promo,
            onTap: () => onChanged(PromoCampaignType.promo)),
        const SizedBox(width: 6),
        _Chip(label: 'Nouveautés',
            selected: current == PromoCampaignType.news,
            onTap: () => onChanged(PromoCampaignType.news)),
      ]),
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
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 6),
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
                style: AppTextStyles.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppColors.primary)),
          ),
        ),
      );
}

class _CampaignCard extends StatelessWidget {
  final PromoCampaign campaign;
  final bool          canEdit;
  final VoidCallback  onSend;
  final VoidCallback  onEdit;
  final VoidCallback  onDelete;
  final VoidCallback  onPreview;
  const _CampaignCard({
    required this.campaign,
    required this.canEdit,
    required this.onSend,
    required this.onEdit,
    required this.onDelete,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: canEdit ? onEdit : null,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
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
                  child: Text(campaign.type.label,
                      style: AppTextStyles.micro.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary)),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(campaign.name,
                    style: AppTextStyles.label
                        .copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (canEdit)
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert_rounded,
                        size: 18, color: AppColors.textHint),
                    onSelected: (v) {
                      switch (v) {
                        case 'send':    onSend();    break;
                        case 'preview': onPreview(); break;
                        case 'delete':  onDelete();  break;
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'send',
                          child: Text('Envoyer aux clients')),
                      const PopupMenuItem(
                          value: 'preview',
                          child: Text('Voir le lien public')),
                      PopupMenuItem(
                          value: 'delete',
                          child: Text('Supprimer',
                              style: TextStyle(color: AppColors.error))),
                    ],
                  ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.inventory_2_outlined,
                    size: 12, color: AppColors.textHint),
                const SizedBox(width: 4),
                Text('${campaign.products.length} produits',
                    style: AppTextStyles.caption),
                const SizedBox(width: 12),
                if (campaign.discountPercent != null
                    && campaign.discountPercent! > 0) ...[
                  Icon(Icons.local_offer_rounded,
                      size: 12, color: AppColors.error),
                  const SizedBox(width: 4),
                  Text('-${campaign.discountPercent}%',
                      style: AppTextStyles.caption.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppColors.error)),
                  const SizedBox(width: 12),
                ],
                Icon(Icons.send_outlined,
                    size: 12, color: AppColors.textHint),
                const SizedBox(width: 4),
                Text('${campaign.sentCount} envois',
                    style: AppTextStyles.caption),
              ]),
              if (campaign.validUntil != null) ...[
                const SizedBox(height: 6),
                Text('Valable jusqu\'au '
                    '${DateFormat('dd/MM/yyyy').format(campaign.validUntil!.toLocal())}',
                    style: AppTextStyles.micro
                        .copyWith(fontStyle: FontStyle.italic)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool         canEdit;
  final VoidCallback onCreate;
  const _EmptyState({required this.canEdit, required this.onCreate});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.campaign_outlined, size: 56, color: AppColors.textHint),
          const SizedBox(height: 12),
          Text('Aucune campagne encore créée.',
              style: TextStyle(color: AppColors.textHint)),
          if (canEdit) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Créer une campagne'),
            ),
          ],
        ],
      ),
    );
  }
}
