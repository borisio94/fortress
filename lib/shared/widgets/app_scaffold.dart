import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/database/app_database.dart';
import '../../core/permisions/permission_guard.dart';
import '../../core/theme/app_colors.dart';
import '../../core/i18n/app_localizations.dart';
import '../../features/caisse/presentation/bloc/caisse_bloc.dart';
import 'adaptive_scaffold.dart';
import 'app_drawer.dart';
import 'offline_banner_widget.dart';
import 'pin_lock_banner.dart';
import 'app_primary_button.dart';

class AppScaffold extends ConsumerStatefulWidget {
  final String shopId;
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool isRootPage;

  const AppScaffold({
    super.key,
    required this.shopId,
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.isRootPage = true,
  });

  @override
  ConsumerState<AppScaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends ConsumerState<AppScaffold> {
  bool _railExpanded = true;
  static const double _kDesktop = 900;

  @override
  void initState() {
    super.initState();
    // Abonne le shop au realtime Supabase dès que n'importe quelle page
    // d'une boutique est ouverte. `subscribeToShop` est idempotent — si
    // le channel est déjà actif, c'est un no-op.
    // NOTE : on NE fait PAS de unsubscribe au dispose car les pages se
    // succèdent en continu — unsubscribe casserait le realtime entre 2
    // navigations. Le channel reste vivant jusqu'à changement de shop
    // ou déconnexion (géré dans didUpdateWidget et dans la logique auth).
    AppDatabase.subscribeToShop(widget.shopId);
  }

  @override
  void didUpdateWidget(covariant AppScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId) {
      AppDatabase.unsubscribeFromShop(oldWidget.shopId);
      AppDatabase.subscribeToShop(widget.shopId);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pass-through : si une AdaptiveScaffold est déjà au-dessus dans
    // l'arbre, c'est elle qui fournit la sidebar/bottom-nav/AppBar/back
    // button. Cet AppScaffold devient transparent — sinon on aurait un
    // double layout (rail interne + sidebar externe). Conserve l'effet
    // d'OfflineBlockGuard et des bannières (PinLock, Offline) en
    // s'appuyant sur celles déjà fournies par AdaptiveScaffold.
    //
    // ⚠ Side effect : les `actions` custom et le `bottomNavigationBar`
    // passés à AppScaffold par les sub-pages sont ignorés dans ce mode.
    // À porter en P2 via un InheritedWidget si besoin.
    final inAdaptive =
        context.findAncestorWidgetOfExactType<AdaptiveScaffold>() != null;
    if (inAdaptive) {
      return widget.body;
    }

    final isDesktop = MediaQuery.of(context).size.width >= _kDesktop;
    if (isDesktop) return _buildDesktop(context);
    return _buildMobile(context);
  }

  Widget _buildDesktop(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(children: [
        ClipRect(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            width: _railExpanded ? 220 : 64,
            child: AppDrawerRail(
              shopId: widget.shopId,
              expanded: _railExpanded,
              onToggle: () => setState(() => _railExpanded = !_railExpanded),
            ),
          ),
        ),
        Container(width: 1, color: const Color(0xFFF0F0F0)),
        Expanded(
          child: Scaffold(
            backgroundColor: AppColors.background,
            appBar: _buildAppBar(context, isDesktop: true) as PreferredSizeWidget,
            body: OfflineBlockGuard(
              child: Column(
                children: [
                  const PinLockBanner(),
                  const OfflineBanner(),
                  const SubscriptionBanner(),
                  Expanded(child: widget.body),
                ],
              ),
            ),
            floatingActionButton: widget.floatingActionButton,
          ),
        ),
      ]),
    );
  }

  Widget _buildMobile(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: widget.isRootPage ? AppDrawer(shopId: widget.shopId) : null,
      appBar: _buildAppBar(context, isDesktop: false) as PreferredSizeWidget,
      body: OfflineBlockGuard(
        child: Column(
          children: [
            const PinLockBanner(),
            const OfflineBanner(),
            const SubscriptionBanner(),
            Expanded(child: widget.body),
          ],
        ),
      ),
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: widget.bottomNavigationBar,
    );
  }

  Widget _buildAppBar(BuildContext context, {required bool isDesktop}) {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: _buildLeading(context, isDesktop: isDesktop),
      title: Text(
        widget.title,
        style: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      centerTitle: isDesktop ? false : true,
      actions: [
        ...?widget.actions,
        // Badge panier
        _CartBadgeBtn(shopId: widget.shopId),
        // Notifications
        _NotifBtn(),
        const SizedBox(width: 4),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: const Color(0xFFF0F0F0)),
      ),
    );
  }

  Widget _buildLeading(BuildContext context, {required bool isDesktop}) {
    if (!widget.isRootPage) {
      return IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        color: AppColors.textPrimary,
        onPressed: () {
          if (context.canPop()) context.pop();
          else context.go('/shop/${widget.shopId}/dashboard');
        },
      );
    }
    if (isDesktop) {
      return IconButton(
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Icon(
            _railExpanded ? Icons.menu_open_rounded : Icons.menu_rounded,
            key: ValueKey(_railExpanded), size: 22,
          ),
        ),
        color: AppColors.textPrimary,
        onPressed: () => setState(() => _railExpanded = !_railExpanded),
      );
    }
    return Builder(
      builder: (ctx) => IconButton(
        icon: const Icon(Icons.menu_rounded, size: 22),
        color: AppColors.textPrimary,
        onPressed: () => Scaffold.of(ctx).openDrawer(),
      ),
    );
  }
}

// ─── Badge panier ─────────────────────────────────────────────────────────────

class _CartBadgeBtn extends StatelessWidget {
  final String shopId;
  const _CartBadgeBtn({required this.shopId});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CaisseBloc, CaisseState>(
      builder: (context, state) {
        final count = state.itemCount;
        return AppIconBadge(
          icon: Icons.shopping_cart_outlined,
          count: count,
          onTap: () => context.push('/shop/$shopId/caisse/payment'),
          tooltip: context.l10n.cartTitle,
        );
      },
    );
  }
}

// ─── Notifications ────────────────────────────────────────────────────────────
// État actuel : pas de centre de notifications branché. La cloche reste
// présente pour la cohérence du topbar et n'affiche jamais de badge. Le
// sheet montre un état vide explicite — préférable à des notifs mockées
// qui mentent à l'utilisateur. Quand on branchera de vraies notifs sur
// les events métier (vente complétée, stock bas, queue offline flushée,
// employé suspendu), elles passeront par un NotificationService dédié
// + Hive box, et alimenteront `count` et la liste affichée ici.

class _NotifBtn extends StatelessWidget {
  const _NotifBtn();

  @override
  Widget build(BuildContext context) {
    return AppIconBadge(
      icon: Icons.notifications_outlined,
      count: 0,
      onTap: () => _showNotifications(context),
      tooltip: context.l10n.notificationsTitle,
    );
  }

  void _showNotifications(BuildContext context) {
    final l = context.l10n;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Text(l.notificationsTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 32),
          const Icon(Icons.notifications_off_outlined,
              size: 40, color: Color(0xFFD1D5DB)),
          const SizedBox(height: 12),
          const Text('Aucune notification',
              style: TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B7280))),
          const SizedBox(height: 4),
          const Text(
            'Les alertes liées à vos ventes et à votre stock\n'
            'apparaîtront ici.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

// ─── Widget badge générique ───────────────────────────────────────────────────