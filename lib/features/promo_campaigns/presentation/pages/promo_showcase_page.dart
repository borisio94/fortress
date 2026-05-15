import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/external_launcher.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../domain/entities/promo_campaign.dart';
import '../providers/promo_campaign_provider.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PromoShowcasePage — vitrine publique d'une campagne promo/nouveautés.
//
// Route : /promo/:shopId/:campaignId  (PUBLIC, sans auth)
//
// Affichage :
//   • Header gradient violet + nom boutique
//   • Bandeau : nom campagne + badge type + remise globale + date limite
//   • Grille 2 colonnes (mobile) / 3 colonnes (desktop) des produits avec
//     image, nom, prix barré + prix promo, badge -X%
//   • Bouton "Commander maintenant" → mène vers le catalogue public du shop
//     où le client peut passer commande
//
// Au mount, incrémente le view_count (analytics) en fire-and-forget.
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
  Future<Map<String, dynamic>?>? _futureShop;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(promoCampaignRepositoryProvider);
    _futureCampaign = repo.getById(widget.campaignId);
    // Incrément view (fire-and-forget). Si la campagne n'existe pas, le RPC
    // ne fait rien (UPDATE sur 0 row).
    Future.microtask(() => repo.incrementView(widget.campaignId));
    // Charge les infos boutique (nom, logo) en parallèle.
    _futureShop = Supabase.instance.client
        .from('shops')
        .select('id, name, logo_url, phone')
        .eq('id', widget.shopId)
        .maybeSingle();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F3FA),
      body: FutureBuilder<PromoCampaign?>(
        future: _futureCampaign,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 2));
          }
          final campaign = snap.data;
          if (campaign == null) {
            return _NotFound(shopId: widget.shopId);
          }
          if (campaign.shopId != widget.shopId) {
            // Sécurité : campagne d'un autre shop → 404.
            return _NotFound(shopId: widget.shopId);
          }
          return FutureBuilder<Map<String, dynamic>?>(
            future: _futureShop,
            builder: (_, shopSnap) {
              final shop = shopSnap.data;
              return _PromoContent(
                campaign:  campaign,
                shopName:  (shop?['name'] as String?) ?? 'Boutique',
                shopLogo:  shop?['logo_url'] as String?,
                shopPhone: shop?['phone'] as String?,
              );
            },
          );
        },
      ),
    );
  }
}

class _PromoContent extends StatelessWidget {
  final PromoCampaign campaign;
  final String        shopName;
  final String?       shopLogo;
  final String?       shopPhone;
  const _PromoContent({
    required this.campaign,
    required this.shopName,
    this.shopLogo,
    this.shopPhone,
  });

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 720;
    final crossAxisCount = isWide ? 3 : 2;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Header(
          shopName: shopName,
          shopLogo: shopLogo,
          campaign: campaign,
        )),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount:    crossAxisCount,
              mainAxisSpacing:   10,
              crossAxisSpacing:  10,
              childAspectRatio:  0.62,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) => _ProductCard(
                product:        campaign.products[i],
                globalDiscount: campaign.discountPercent,
                shopName:       shopName,
                shopPhone:      shopPhone,
                canOrder:       campaign.isActiveNow,
              ),
              childCount: campaign.products.length,
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String        shopName;
  final String?       shopLogo;
  final PromoCampaign campaign;
  const _Header({
    required this.shopName,
    this.shopLogo,
    required this.campaign,
  });

  @override
  Widget build(BuildContext context) {
    final isPromo = campaign.type == PromoCampaignType.promo;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
          colors: [Color(0xFF6C3FC7), Color(0xFF4E2A9A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (shopLogo != null && shopLogo!.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(shopLogo!,
                    width: 44, height: 44, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _LogoFallback(name: shopName)),
              )
            else
              _LogoFallback(name: shopName),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(shopName,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  Text(isPromo ? 'Promotion exclusive' : 'Nouveautés',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 11, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 18),
          Text(campaign.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22, fontWeight: FontWeight.w900,
                  height: 1.2)),
          if (campaign.description != null
              && campaign.description!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(campaign.description!,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13, height: 1.4)),
          ],
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (campaign.discountPercent != null
                && campaign.discountPercent! > 0)
              _Badge(
                icon: Icons.local_offer_rounded,
                text: 'Jusqu\'à -${campaign.discountPercent}%',
                background: Colors.white,
                foreground: const Color(0xFF6C3FC7),
              ),
            if (campaign.validUntil != null)
              _Badge(
                icon: Icons.schedule_rounded,
                text: 'Valable jusqu\'au '
                    '${DateFormat('dd/MM/yyyy').format(campaign.validUntil!.toLocal())}',
                background: Colors.white.withValues(alpha: 0.18),
                foreground: Colors.white,
              ),
          ]),
          const SizedBox(height: 18),
          if (campaign.isPending) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.schedule_rounded,
                    size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'Campagne à venir — démarre le '
                      '${DateFormat('dd/MM à HH:mm').format(campaign.startsAt!.toLocal())}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                // Catalogue filtré : ne montre QUE les produits de la
                // campagne grâce au paramètre ?ids=p1,p2,p3.
                onPressed: () {
                  final ids = campaign.products
                      .map((p) => p.productId)
                      .where((id) => id.isNotEmpty)
                      .join(',');
                  context.go(
                      '/catalogue/${campaign.shopId}?ids=$ids');
                },
                icon: const Icon(Icons.shopping_bag_rounded, size: 18),
                label: const Text('Commander maintenant',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF6C3FC7),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LogoFallback extends StatelessWidget {
  final String name;
  const _LogoFallback({required this.name});
  @override
  Widget build(BuildContext context) {
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+'))
            .take(2).map((p) => p[0].toUpperCase()).join();
    return Container(
      width: 44, height: 44,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(initials,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 16, fontWeight: FontWeight.w800)),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String   text;
  final Color    background;
  final Color    foreground;
  const _Badge({
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: foreground),
        const SizedBox(width: 5),
        Text(text,
            style: TextStyle(
                color: foreground,
                fontSize: 11, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

class _ProductCard extends StatelessWidget {
  final PromoProductSnapshot product;
  final int?                  globalDiscount;
  final String                shopName;
  final String?               shopPhone;
  final bool                  canOrder;
  const _ProductCard({
    required this.product,
    this.globalDiscount,
    required this.shopName,
    this.shopPhone,
    this.canOrder = true,
  });

  void _orderViaWhatsApp() {
    final phone = (shopPhone ?? '').trim();
    if (phone.isEmpty) return;
    final p = PhoneFormatter.toWame(phone).replaceAll(RegExp(r'[^\d]'), '');
    if (p.isEmpty) return;
    final eff = product.effectivePrice(globalDiscount);
    final priceStr = CurrencyFormatter.format(eff);
    final msg = 'Bonjour $shopName 👋\n\n'
        'Je voudrais commander :\n'
        '• ${product.name}\n'
        '  Prix promo : $priceStr\n\n'
        'Merci de me confirmer la disponibilité.';
    openExternal('https://wa.me/$p?text=${Uri.encodeComponent(msg)}');
  }

  @override
  Widget build(BuildContext context) {
    final effPrice = product.effectivePrice(globalDiscount);
    final hasDiscount = effPrice < product.originalPrice;
    final discountPercent = product.discountPercent
        ?? globalDiscount
        ?? (hasDiscount
            ? ((1 - effPrice / product.originalPrice) * 100).round()
            : null);
    final hasPhone = (shopPhone ?? '').trim().isNotEmpty;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 0,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12)),
                  child: (product.imageUrl != null
                          && product.imageUrl!.isNotEmpty)
                      ? Image.network(product.imageUrl!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (_, __, ___) =>
                              _ImageFallback(name: product.name))
                      : _ImageFallback(name: product.name),
                ),
                if (discountPercent != null && discountPercent > 0)
                  Positioned(
                    top: 6, left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.error,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('-$discountPercent%',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800)),
                    ),
                  ),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w700,
                            height: 1.3)),
                    const SizedBox(height: 4),
                    if (hasDiscount) ...[
                      Text(CurrencyFormatter.format(product.originalPrice),
                          style: TextStyle(
                              fontSize: 9,
                              decoration: TextDecoration.lineThrough,
                              color: AppColors.textHint)),
                    ],
                    Text(CurrencyFormatter.format(effPrice),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: hasDiscount
                                ? AppColors.error
                                : AppColors.primary)),
                    const Spacer(),
                    // Bouton Commander : wa.me direct vers la boutique avec
                    // message pré-rempli mentionnant le produit/variante.
                    if (canOrder && hasPhone)
                      SizedBox(
                        width: double.infinity,
                        height: 30,
                        child: ElevatedButton.icon(
                          onPressed: _orderViaWhatsApp,
                          icon: const Icon(Icons.shopping_cart_rounded,
                              size: 13),
                          label: const Text('Commander',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF25D366),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageFallback extends StatelessWidget {
  final String name;
  const _ImageFallback({required this.name});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primarySurface.withValues(alpha: 0.4),
      alignment: Alignment.center,
      child: Icon(Icons.image_rounded,
          size: 32, color: AppColors.primary.withValues(alpha: 0.3)),
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
                style:
                    TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
