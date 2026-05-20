import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import 'deleted_orders_page.dart';
import 'deleted_products_page.dart';

/// Borne haute du badge — au-delà on affiche "999+" et on ne pousse pas
/// PostgREST à rapatrier plus de lignes pour compter. Acceptable pour un
/// écran admin où l'ordre de grandeur compte plus que la précision.
const int _badgeCap = 1000;

/// Compteurs par catégorie. Lecture légère côté Supabase : on récupère
/// uniquement la colonne `id` plafonnée à `_badgeCap` lignes. La RLS
/// `*_select_deleted_sa` n'autorise ces SELECT qu'au super-admin.
///
/// (Pourquoi pas `.count(CountOption.exact)` ? L'API exacte varie entre
/// versions de supabase_flutter/postgrest. Un `select().limit()` est
/// portable et suffit pour ce besoin — un super-admin avec plus de 1000
/// éléments supprimés a un problème plus grave que la précision du badge.)
///
/// FutureProvider autoDispose : invalidé au pull-to-refresh du hub
/// pour recompter sans clé manuelle.
final _deletedCountsProvider =
    FutureProvider.autoDispose<_DeletedCounts>((ref) async {
  final db = Supabase.instance.client;
  Future<int> countOf(String table) async {
    try {
      final rows = await db.from(table)
          .select('id')
          .not('deleted_at', 'is', null)
          .limit(_badgeCap);
      return (rows as List).length;
    } catch (_) {
      // Tolérant : si la RLS bloque ou si la table n'a pas la colonne
      // deleted_at (boutiques très anciennes), on retourne 0 plutôt que
      // d'empêcher l'affichage du hub.
      return 0;
    }
  }
  final results = await Future.wait([countOf('orders'), countOf('products')]);
  return _DeletedCounts(orders: results[0], products: results[1]);
});

class _DeletedCounts {
  final int orders;
  final int products;
  const _DeletedCounts({required this.orders, required this.products});
  int get total => orders + products;
  /// `true` si l'un des compteurs a atteint la borne — l'UI peut alors
  /// afficher "999+" au lieu d'un chiffre exact.
  bool get isCapped => orders >= _badgeCap || products >= _badgeCap;
}

/// Hub super-admin (hotfix_084 + hotfix_085) — point d'entrée unique
/// pour les éléments supprimés.
///
/// Structure
/// ─────────
///   • AppBar avec titre + bouton Rafraîchir global.
///   • TabBar à 2 onglets : « Commandes » et « Produits ». Chaque onglet
///     affiche un badge avec le COUNT exact (lecture séparée, légère).
///   • Pull-to-refresh global → invalide le provider de compteurs ET
///     rafraîchit le body actif de l'onglet courant.
///   • Si total = 0, l'écran montre un empty state (l'onglet courant
///     reste accessible quand même via le tap).
///
/// Routing
/// ───────
/// Trois routes pointent ici :
///   • /super-admin/deleted          → hub avec l'onglet par défaut
///   • /super-admin/deleted/orders   → hub onglet "Commandes" forcé
///   • /super-admin/deleted/products → hub onglet "Produits" forcé
class SuperAdminDeletedHubPage extends ConsumerStatefulWidget {
  /// Onglet initial sélectionné. 0 = commandes, 1 = produits.
  final int initialTab;
  const SuperAdminDeletedHubPage({super.key, this.initialTab = 0});

  @override
  ConsumerState<SuperAdminDeletedHubPage> createState() =>
      _SuperAdminDeletedHubPageState();
}

class _SuperAdminDeletedHubPageState
    extends ConsumerState<SuperAdminDeletedHubPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  final GlobalKey<DeletedOrdersBodyState>   _ordersKey   = GlobalKey();
  final GlobalKey<DeletedProductsBodyState> _productsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(
        length: 2,
        vsync: this,
        initialIndex: widget.initialTab.clamp(0, 1));
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    // Invalide les compteurs et déclenche le refresh des 2 bodies en
    // parallèle. Les Body widgets gèrent leur propre état de loading.
    ref.invalidate(_deletedCountsProvider);
    await Future.wait([
      if (_ordersKey.currentState != null)
        _ordersKey.currentState!.refresh(),
      if (_productsKey.currentState != null)
        _productsKey.currentState!.refresh(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final isSuperAdmin = ref.watch(currentPlanProvider).isSuperAdmin;
    if (!isSuperAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Éléments supprimés')),
        body: const EmptyStateWidget(
          icon:     Icons.lock_outline_rounded,
          title:    'Réservé au super-admin',
          subtitle: 'Cet écran liste les éléments supprimés (commandes + '
              'produits) de toutes les boutiques. Seul le super-admin '
              'Fortress y a accès.',
        ),
      );
    }

    final countsAsync = ref.watch(_deletedCountsProvider);
    final counts = countsAsync.valueOrNull;
    final ordersBadge   = counts?.orders   ?? 0;
    final productsBadge = counts?.products ?? 0;
    final totalEmpty    = counts != null && counts.total == 0;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Éléments supprimés'),
        actions: [
          IconButton(
            tooltip: 'Tout rafraîchir',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refreshAll,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            color: Colors.white,
            child: TabBar(
              controller: _tabCtrl,
              labelColor:    AppColors.primary,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              indicatorWeight: 2.5,
              labelStyle:    AppTextStyles.label,
              unselectedLabelStyle:
                  AppTextStyles.label.copyWith(fontWeight: FontWeight.w500),
              tabs: [
                _TabLabel(label: 'Commandes', count: ordersBadge),
                _TabLabel(label: 'Produits',  count: productsBadge),
              ],
            ),
          ),
        ),
      ),
      body: totalEmpty
          ? RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 60),
                  EmptyStateWidget(
                    icon:     Icons.inbox_rounded,
                    title:    'Rien à restaurer',
                    subtitle: 'Aucune commande ni produit n\'a été '
                        'supprimé. Cette page reste vide tant qu\'un '
                        'manager ne supprime pas un élément éligible.',
                  ),
                ],
              ),
            )
          : TabBarView(
              controller: _tabCtrl,
              children: [
                DeletedOrdersBody(key:   _ordersKey),
                DeletedProductsBody(key: _productsKey),
              ],
            ),
    );
  }
}

/// Label d'onglet avec badge compteur intégré (sans dépendance externe).
class _TabLabel extends StatelessWidget {
  final String label;
  final int    count;
  const _TabLabel({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count >= _badgeCap ? '999+' : '$count',
                style: AppTextStyles.micro.copyWith(
                    color: AppColors.error,
                    fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Provider PUBLIC : nombre total d'éléments supprimés (commandes +
/// produits), exposé pour les widgets qui veulent afficher un badge
/// global — par exemple le quick action « Éléments supprimés » dans
/// le dashboard super-admin.
///
/// Réutilise le même Future que le hub → 1 seule paire de requêtes
/// servira les deux écrans.
final superAdminDeletedTotalProvider = Provider.autoDispose<int>((ref) {
  final async = ref.watch(_deletedCountsProvider);
  return async.valueOrNull?.total ?? 0;
});
