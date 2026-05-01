import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../bloc/shop_selector_bloc.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../features/auth/domain/entities/user.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../domain/entities/shop_summary.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../subscription/presentation/widgets/subscription_guard.dart';

class ShopListPage extends ConsumerStatefulWidget {
  const ShopListPage({super.key});
  @override
  ConsumerState<ShopListPage> createState() => _ShopListPageState();
}

class _ShopListPageState extends ConsumerState<ShopListPage> {
  String? _loadingShopId; // ID de la boutique en cours de chargement

  @override
  void initState() {
    super.initState();
    context.read<ShopSelectorBloc>().add(LoadMyShops());
  }

  /// True si l'utilisateur courant peut entamer le flow de création
  /// d'une boutique.
  ///
  /// Règles :
  ///   - Owner d'au moins une boutique en local → autorisé (cas multi-shop).
  ///   - 0 membership en local pour cet uid → nouvel inscrit qui crée sa
  ///     première boutique → autorisé. Sans cette branche, le check ci-dessus
  ///     refusait à tort le tout premier compte (catch-22 : pour créer la
  ///     1ʳᵉ boutique, il fallait déjà en posséder une).
  ///   - Au moins un membership mais aucun shop possédé → employé/admin
  ///     invité dans une autre boutique → bloqué.
  ///
  /// Voir AppPermissions.canStartCreateShop pour le cas où un owner délègue
  /// la permission à un admin précis (granulaire serveur).
  bool _canCreateShop() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return false;

    final ownsAShop = HiveBoxes.shopsBox.values.any((raw) {
      try {
        final m = Map<String, dynamic>.from(raw as Map);
        return m['owner_id'] == uid;
      } catch (_) { return false; }
    });
    if (ownsAShop) return true;

    final hasAnyMembership = HiveBoxes.membershipsBox.values.any((raw) {
      try {
        final m = Map<String, dynamic>.from(raw as Map);
        return m['user_id'] == uid;
      } catch (_) { return false; }
    });
    return !hasAnyMembership;
  }

  /// Helper : check la permission + le quota multi-shop avant de naviguer
  /// vers la création. Si limite atteinte → UpgradeSheet, si pas autorisé
  /// → snack erreur. Sinon push vers /shop-selector/create.
  void _handleCreateShopTap() {
    if (!_canCreateShop()) {
      AppSnack.error(context,
          'Création de boutique réservée au propriétaire.');
      return;
    }
    final plan = ref.read(currentPlanProvider);
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final shopCount = userId.isEmpty
        ? 0
        : LocalStorageService.getShopsForUser(userId).length;
    if (!plan.canAddShop(shopCount)) {
      UpgradeSheet.showQuota(context,
          label:    context.l10n.featMultiShop,
          current:  shopCount,
          max:      plan.maxShops);
      return;
    }
    context.push(RouteNames.createShop);
  }

  Widget _emptySuperAdminOrNormal(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(subscriptionProvider).valueOrNull;
    if (plan != null && plan.isSuperAdmin) {
      return _SuperAdminUsersView(
        onGoAdmin: () => context.push(RouteNames.adminPanel),
      );
    }
    return _EmptyOrLoadingState(
      onCreateTap: _handleCreateShopTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;

    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: Stack(
        children: [
          SafeArea(
            child: BlocConsumer<ShopSelectorBloc, ShopSelectorState>(
              listener: (context, state) {
                if (state is ShopSelectorLoaded && state.shops.isNotEmpty) {
                  debugPrint('[ShopListPage] Loaded ${state.shops.length} shops');

                  final userId = LocalStorageService.getCurrentUser()?.id ?? '';

                  // Sauvegarder boutiques + memberships dans Hive
                  // setFromSupabase gère les deux en une seule passe
                  ref.read(myShopsProvider.notifier)
                      .setFromSupabase(state.shops, userId: userId);

                  // Sauvegarder activeShopId si 1 seule boutique
                  if (state.shops.length == 1 && userId.isNotEmpty) {
                    LocalStorageService.saveActiveShopId(
                        userId, state.shops.first.id);
                    ref.read(currentShopProvider.notifier)
                        .setShop(state.shops.first);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!context.mounted) return;
                      context.go('/shop/${state.shops.first.id}/dashboard');
                    });
                  }
                }
                if (state is ShopCreated) {
                  context.read<ShopSelectorBloc>().add(LoadMyShops());
                }
                if (state is ShopSelectorError) {
                  AppSnack.error(context, state.message);
                }
              },
              builder: (context, state) {
                return CustomScrollView(
                  slivers: [
                    // ── Header ────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                        child: Row(
                          children: [
                            const FortressLogo.light(size: 26),
                            const Spacer(),
                            // Boutons masqués pour super admin
                            Builder(builder: (ctx) {
                              final plan = ref.watch(subscriptionProvider).valueOrNull;
                              final isSA = plan?.isSuperAdmin ?? false;
                              if (isSA) return const SizedBox.shrink();
                              final canCreate = _canCreateShop();
                              return Row(mainAxisSize: MainAxisSize.min, children: [
                                if (canCreate) ...[
                                  _SubscriptionHeaderBtn(),
                                  const SizedBox(width: 8),
                                ],
                                AppOutlineIconButton(
                                  icon: Icons.bar_chart_rounded,
                                  tooltip: l.navHub,
                                  onTap: () => context.go(RouteNames.hub),
                                ),
                                if (canCreate) ...[
                                  const SizedBox(width: 8),
                                  _NewShopBtn(
                                    onTap: _handleCreateShopTap,
                                  ),
                                ],
                              ]);
                            }),
                          ],
                        ),
                      ),
                    ),

                    // ── Titre ─────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 28, 24, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Mes boutiques',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Sélectionnez une boutique pour commencer',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── Bannière abonnement ───────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                        child: _PlanStatusCard(),
                      ),
                    ),

                    // ── Contenu ───────────────────────────────────────
                    if (state is ShopSelectorLoading)
                      const SliverFillRemaining(
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (state is ShopSelectorLoaded &&
                        state.shops.isEmpty)
                      SliverFillRemaining(
                        child: _emptySuperAdminOrNormal(context, ref),
                      )
                    else if (state is ShopSelectorLoaded) ...[
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                          sliver: SliverGrid(
                            gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 320,
                              mainAxisSpacing: 14,
                              crossAxisSpacing: 14,
                              childAspectRatio: 1.45,
                            ),
                            delegate: SliverChildBuilderDelegate(
                                  (ctx, i) => _ShopCard(
                                shop: state.shops[i],
                                isLoading: _loadingShopId == state.shops[i].id,
                                onTap: _loadingShopId != null ? null : () async {
                                  final shop = state.shops[i];
                                  final userId =
                                      LocalStorageService.getCurrentUser()?.id ?? '';

                                  // Sauvegarder dans Hive + mettre à jour providers
                                  if (userId.isNotEmpty) {
                                    LocalStorageService.saveActiveShopId(userId, shop.id);
                                  }
                                  ref.read(currentShopProvider.notifier).setShop(shop);

                                  // Offline-first : si Hive a déjà des produits de
                                  // cette boutique, naviguer instantanément et
                                  // synchroniser en arrière-plan. Sinon (1re visite
                                  // sur l'appareil), attendre la sync pour que le
                                  // dashboard ait au moins une fois les données.
                                  final hasCached = LocalStorageService
                                      .getProductsForShop(shop.id).isNotEmpty;

                                  if (hasCached) {
                                    // Sync fire-and-forget, realtime + listeners
                                    // rafraîchiront les pages quand les données
                                    // arrivent.
                                    AppDatabase.syncProducts(shop.id)
                                        .catchError((e) => debugPrint(
                                            '[ShopList] syncProducts bg: $e'));
                                    AppDatabase.syncMetadata(shop.id)
                                        .catchError((e) => debugPrint(
                                            '[ShopList] syncMetadata bg: $e'));
                                    context.go('/shop/${shop.id}/dashboard');
                                    return;
                                  }

                                  // Première visite de l'appareil sur cette
                                  // boutique → spinner le temps de remplir Hive.
                                  setState(() => _loadingShopId = shop.id);
                                  try {
                                    await AppDatabase.syncProducts(shop.id);
                                    await AppDatabase.syncMetadata(shop.id);
                                  } catch (e) {
                                    debugPrint('[ShopList] sync error: $e');
                                  }
                                  if (!mounted) return;
                                  setState(() => _loadingShopId = null);
                                  context.go('/shop/${shop.id}/dashboard');
                                },
                              ),
                              childCount: state.shops.length,
                            ),
                          ),
                        ),
                      ] else
                        const SliverFillRemaining(child: SizedBox.shrink()),
                  ],
                );
              },
            ),
          ),

          // Switcher langue
          Positioned(
            bottom: 20, right: 20,
            child: LanguageSwitcher(
              backgroundColor: Colors.white.withOpacity(0.92),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Card boutique
// ─────────────────────────────────────────────────────────────────────────────

class _ShopCard extends StatefulWidget {
  final ShopSummary shop;
  final VoidCallback? onTap;
  final bool isLoading;
  const _ShopCard({required this.shop, this.onTap, this.isLoading = false});
  @override
  State<_ShopCard> createState() => _ShopCardState();
}

class _ShopCardState extends State<_ShopCard> {
  bool _hovered = false;

  static const _sectorIcons = {
    'retail':       Icons.storefront_rounded,
    'restaurant':   Icons.restaurant_rounded,
    'supermarche':  Icons.local_grocery_store_rounded,
    'pharmacie':    Icons.local_pharmacy_rounded,
    'autre':        Icons.store_rounded,
  };

  static const _sectorColors = {
    'retail':       Color(0xFF6C3FC7),
    'restaurant':   AppColors.error,
    'supermarche':  AppColors.secondary,
    'pharmacie':    Color(0xFF3B82F6),
    'autre':        Color(0xFF8B5CF6),
  };

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final icon  = _sectorIcons[widget.shop.sector] ?? Icons.store_rounded;
    final color = _sectorColors[widget.shop.sector] ?? AppColors.primary;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _hovered ? color.withOpacity(0.4) : AppColors.divider,
            width: 1.5,
          ),
          boxShadow: _hovered
              ? [BoxShadow(color: color.withOpacity(0.12), blurRadius: 16, offset: const Offset(0, 4))]
              : [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: widget.isLoading ? null : widget.onTap,
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                // ── Contenu principal ──────────────────────────────
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Icon(icon, color: color, size: 18),
                          ),
                          const Spacer(),
                          if (widget.shop.isActive)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFECFDF5),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 5, height: 5,
                                    decoration: const BoxDecoration(
                                      color: AppColors.secondary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(l.shopActive,
                                      style: const TextStyle(
                                          fontSize: 9,
                                          color: AppColors.secondary,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.shop.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Text(_countryFlag(widget.shop.country),
                              style: const TextStyle(fontSize: 11)),
                          const SizedBox(width: 4),
                          Text(widget.shop.currency,
                              style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textHint,
                                  fontWeight: FontWeight.w500)),
                          const Spacer(),
                          if (widget.shop.todaySales != null)
                            Flexible(
                              child: Text(
                                '${widget.shop.todaySales!.toStringAsFixed(0)} ${widget.shop.currency}',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: color),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                // ── Overlay loading ────────────────────────────────
                if (widget.isLoading)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.75),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 24, height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _countryFlag(String iso) {
    const flags = {
      'CM': '🇨🇲', 'SN': '🇸🇳', 'CI': '🇨🇮', 'NG': '🇳🇬',
      'GH': '🇬🇭', 'MA': '🇲🇦', 'FR': '🇫🇷', 'BE': '🇧🇪',
      'US': '🇺🇸', 'GB': '🇬🇧', 'CD': '🇨🇩', 'GA': '🇬🇦',
    };
    return flags[iso] ?? '🏳';
  }
}


class _EmptyState extends StatelessWidget {
  final VoidCallback onCreateTap;
  const _EmptyState({required this.onCreateTap});
  @override
  Widget build(BuildContext context) => EmptyStateWidget(
    icon: Icons.storefront_rounded,
    title: context.l10n.shopNoShop,
    subtitle: context.l10n.shopNoShopHint,
    ctaLabel: 'Nouvelle boutique',
    onCta: onCreateTap,
  );
}

/// Widget qui attend 3 secondes avant d'afficher l'état "aucune boutique"
/// pour laisser le temps à la sync Supabase de terminer sur mobile
class _EmptyOrLoadingState extends StatefulWidget {
  final VoidCallback onCreateTap;
  const _EmptyOrLoadingState({required this.onCreateTap});
  @override
  State<_EmptyOrLoadingState> createState() => _EmptyOrLoadingStateState();
}

class _EmptyOrLoadingStateState extends State<_EmptyOrLoadingState> {
  bool _showEmpty = false;

  @override
  void initState() {
    super.initState();
    // Attendre 3s avant de conclure qu'il n'y a vraiment pas de boutique
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showEmpty = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_showEmpty) {
      // Pendant 3s : spinner discret
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Chargement de vos boutiques…',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ],
        ),
      );
    }
    // Après 3s : vrai état vide
    return _EmptyState(onCreateTap: widget.onCreateTap);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets atomiques
// ─────────────────────────────────────────────────────────────────────────────

class _NewShopBtn extends StatefulWidget {
  final VoidCallback onTap;
  final bool large;
  const _NewShopBtn({required this.onTap, this.large = false});
  @override
  State<_NewShopBtn> createState() => _NewShopBtnState();
}

class _NewShopBtnState extends State<_NewShopBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit:  (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: widget.large
              ? const EdgeInsets.symmetric(horizontal: 24, vertical: 12)
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: _h ? AppColors.primary : AppColors.textPrimary,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(
                'Nouvelle boutique',
                style: TextStyle(
                  fontSize: widget.large ? 14 : 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Bouton abonnement dans le header ────────────────────────────────────────
class _SubscriptionHeaderBtn extends ConsumerWidget {
  const _SubscriptionHeaderBtn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planAsync = ref.watch(subscriptionProvider);
    final plan = planAsync.valueOrNull;

    // Masqué si plan actif ou super admin
    if (plan == null || plan.isSuperAdmin || plan.isActive) {
      return const SizedBox.shrink();
    }

    final isExpired = plan.isExpired;
    final color = isExpired
        ? AppColors.error
        : AppColors.warning;

    return GestureDetector(
        onTap: () => context.push(RouteNames.subscription),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
          isExpired
          ? Icons.warning_amber_rounded
              : Icons.stars_rounded,
            size: 14, color: color,
          ),
          const SizedBox(width: 5),
          Text(
              isExpired ? 'Renouveler' : "S'abonner",
              style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color),
        ),
        ]),
    ),
    );
  }
}

// ─── Carte statut plan dans la page boutique ─────────────────────────────────
class _PlanStatusCard extends ConsumerWidget {
  const _PlanStatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planAsync = ref.watch(subscriptionProvider);
    return planAsync.when(
      loading: () => const SizedBox.shrink(),
      error:   (_, __) => const SizedBox.shrink(),
      data: (plan) {
        // Masqué si plan actif et pas sur le point d'expirer
        if (plan.isSuperAdmin) return const SizedBox.shrink();
        if (plan.isActive && !plan.expiresSoon && !plan.isExpired) {
          return const SizedBox.shrink();
        }

        final (color, icon, title, subtitle, btnLabel) = switch (true) {
          _ when plan.isExpired => (
          AppColors.error,
          Icons.warning_amber_rounded,
          'Abonnement expiré',
          'Vos boutiques sont en lecture seule. Renouvelez pour continuer.',
          'Renouveler maintenant',
          ),
          _ when plan.expiresSoon => (
          AppColors.warning,
          Icons.access_time_rounded,
          'Expire dans ${plan.daysLeft} jour(s)',
          'Renouvelez dès maintenant pour éviter toute interruption.',
          'Renouveler',
          ),
          _ => (
          AppColors.primary,
          Icons.stars_rounded,
          'Aucun abonnement actif',
          'Choisissez un plan pour accéder à toutes les fonctionnalités.',
          'Choisir un plan',
          ),
        };

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.25)),
          ),
          child: Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: color)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11,
                          color: color.withOpacity(0.8))),
                ])),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => context.push(RouteNames.subscription),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(btnLabel,
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ]),
        );
      },
    );
  }
}

// ─── Vue utilisateurs abonnés pour super admin ───────────────────────────────
class _SuperAdminUsersView extends StatefulWidget {
  final VoidCallback onGoAdmin;
  const _SuperAdminUsersView({required this.onGoAdmin});
  @override
  State<_SuperAdminUsersView> createState() => _SuperAdminUsersViewState();
}

class _SuperAdminUsersViewState extends State<_SuperAdminUsersView> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select('id, name, email, prof_status, is_super_admin, created_at, subscriptions(sub_status, expires_at, plans(label))')
          .order('created_at', ascending: false)
          .limit(20);
      final list = List<Map<String, dynamic>>.from(rows as List);

      // Si aucun utilisateur → aller directement au panneau admin
      if (list.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onGoAdmin();
        });
        return;
      }
      setState(() { _users = list; _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(children: [
      // ── Stats rapides ────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        child: Row(children: [
          _StatPill(
            label: 'Total',
            value: '${_users.length}',
            color: const Color(0xFF534AB7),
          ),
          const SizedBox(width: 8),
          _StatPill(
            label: 'Actifs',
            value: '${_users.where((u) {
              final subs = u['subscriptions'] as List?;
              return subs?.isNotEmpty == true &&
                  subs!.first['sub_status'] == 'active';
            }).length}',
            color: AppColors.secondary,
          ),
          const SizedBox(width: 8),
          _StatPill(
            label: 'Bloqués',
            value: '${_users.where((u) => u['prof_status'] == 'blocked').length}',
            color: AppColors.error,
          ),
          const Spacer(),
          // Bouton accès admin
          GestureDetector(
            onTap: widget.onGoAdmin,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF534AB7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.admin_panel_settings_rounded,
                    size: 14, color: Colors.white),
                SizedBox(width: 5),
                Text('Admin',
                    style: TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ]),
            ),
          ),
        ]),
      ),

      // ── Liste utilisateurs ───────────────────────────────────
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            itemCount: _users.length,
            itemBuilder: (_, i) => _UserTile(user: _users[i]),
          ),
        ),
      ),
    ]);
  }
}

// ── Carte utilisateur ─────────────────────────────────────────────────────────
class _UserTile extends StatelessWidget {
  final Map<String, dynamic> user;
  const _UserTile({required this.user});

  @override
  Widget build(BuildContext context) {
    final name     = user['name'] as String? ?? '—';
    final email    = user['email'] as String? ?? '—';
    final status   = user['prof_status'] as String? ?? 'active';
    final isAdmin  = user['is_super_admin'] as bool? ?? false;
    final subs     = (user['subscriptions'] as List?);
    final sub      = subs?.isNotEmpty == true
        ? subs!.first as Map<String, dynamic> : null;
    final plan     = sub?['plans'] as Map<String, dynamic>?;
    final planLabel = plan?['label'] as String?;
    final subStatus = sub?['sub_status'] as String?;
    final initials = name.isNotEmpty
        ? name.trim().split(' ').map((w) => w.isNotEmpty ? w[0] : '')
        .take(2).join().toUpperCase()
        : '?';

    final isBlocked = status == 'blocked';
    final isActive  = subStatus == 'active';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isBlocked
              ? const Color(0xFFFECACA)
              : AppColors.divider,
        ),
      ),
      child: Row(children: [
        // Avatar
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: isBlocked
                ? const Color(0xFFFEE2E2)
                : const Color(0xFFEEEDFE),
            shape: BoxShape.circle,
          ),
          child: Center(child: Text(initials,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700,
                  color: isBlocked
                      ? AppColors.error
                      : const Color(0xFF534AB7)))),
        ),
        const SizedBox(width: 10),

        // Infos
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Flexible(child: Text(name,
                  style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary))),
              if (isAdmin) ...[
                const SizedBox(width: 5),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                      color: const Color(0xFFEEEDFE),
                      borderRadius: BorderRadius.circular(4)),
                  child: const Text('SA',
                      style: TextStyle(fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF534AB7))),
                ),
              ],
            ]),
            Text(email,
                style: const TextStyle(fontSize: 11,
                    color: AppColors.textHint)),
          ],
        )),

        // Plan + statut
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (planLabel != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: isActive
                    ? const Color(0xFFEEEDFE)
                    : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(planLabel,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w600,
                      color: isActive
                          ? const Color(0xFF534AB7)
                          : AppColors.textHint)),
            )
          else
            const Text('Sans plan',
                style: TextStyle(fontSize: 10, color: AppColors.textHint)),
          if (isBlocked)
            const Text('Bloqué',
                style: TextStyle(fontSize: 10,
                    color: AppColors.error,
                    fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }
}

// ── Pill statistique ──────────────────────────────────────────────────────────
class _StatPill extends StatelessWidget {
  final String label, value;
  final Color color;
  const _StatPill({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.2))),
    child: RichText(text: TextSpan(children: [
      TextSpan(text: value,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
              color: color)),
      TextSpan(text: '  $label',
          style: const TextStyle(fontSize: 10,
              color: AppColors.textSecondary)),
    ])),
  );
}