import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../domain/entities/promo_campaign.dart';
import '../providers/promo_campaign_provider.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PromoShowcasePage — point d'entrée du lien public d'une campagne promo.
//
// Route : /promo/:shopId/:campaignId  (PUBLIC, sans auth)
//
// Comportement : redirige SYSTÉMATIQUEMENT vers le catalogue FILTRÉ sur les
// produits de la campagne (/catalogue/:shopId?ids=...). Le catalogue offre
// déjà le flow de commande complet (sélection multi → bandeau "Commander"
// → formulaire infos/livraison → validation) et applique le prix promo
// temporellement (cf. CataloguePage._effectivePrice : prix normal avant
// promo_start, prix réduit pendant [promo_start, promo_end[).
//
// On ne maintient plus de vitrine séparée : elle dupliquait l'UI catalogue
// sans le flow de commande, ce qui empêchait de commander depuis le lien.
//
// Incrémente view_count (analytics) en fire-and-forget avant de rediriger.
// ═════════════════════════════════════════════════════════════════════════════

class PromoShowcasePage extends ConsumerStatefulWidget {
  final String shopId;
  final String campaignId;
  const PromoShowcasePage({
    super.key,
    required this.shopId,
    required this.campaignId,
  });

  @override
  ConsumerState<PromoShowcasePage> createState() =>
      _PromoShowcasePageState();
}

class _PromoShowcasePageState extends ConsumerState<PromoShowcasePage> {
  Future<PromoCampaign?>? _futureCampaign;
  bool _redirected = false;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(promoCampaignRepositoryProvider);
    _futureCampaign = repo.getById(widget.campaignId);
    Future.microtask(() => repo.incrementView(widget.campaignId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: FutureBuilder<PromoCampaign?>(
        future: _futureCampaign,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 2));
          }
          final campaign = snap.data;
          if (campaign == null || campaign.shopId != widget.shopId) {
            return _NotFound(shopId: widget.shopId);
          }
          if (!_redirected) {
            _redirected = true;
            final ids = campaign.products
                .map((p) => p.productId)
                .where((id) => id.isNotEmpty)
                .toSet()
                .join(',');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                context.go('/catalogue/${widget.shopId}?ids=$ids');
              }
            });
          }
          return const Center(
              child: CircularProgressIndicator(strokeWidth: 2));
        },
      ),
    );
  }
}

class _NotFound extends StatelessWidget {
  final String shopId;
  const _NotFound({required this.shopId});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded,
                size: 64, color: AppColors.textHint),
            const SizedBox(height: 12),
            const Text('Campagne introuvable ou expirée.',
                textAlign: TextAlign.center,
                style: AppTextStyles.label),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => context.go('/catalogue/$shopId'),
              icon: const Icon(Icons.storefront_outlined, size: 16),
              label: const Text('Voir le catalogue'),
            ),
          ],
        ),
      ),
    );
  }
}
