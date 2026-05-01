import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/theme/app_colors.dart';

/// Chips de navigation Stock. Chips horizontaux scrollables qui pushent
/// vers les sous-pages d'Inventaire :
///   Produits · Emplacements · Incidents
///
/// Transferts + Mouvements retirés round 13 (alignement avec le menu —
/// transferts via action inline produit, historique mouvements via la
/// page Emplacements).
///
/// **Rendu au niveau du shell** (`AdaptiveScaffold._MobileShell`) plutôt
/// que dans chaque page individuellement — sinon naviguer d'un onglet à
/// un autre fait disparaître les chips (chaque sub-page n'avait pas le
/// widget). Style « tabs » : texte simple + underline 2px primary sur
/// l'actif, pas de bg ni de border.
///
/// Affiché uniquement quand on est sur l'une des 5 routes (cf.
/// [matchesStockNavRoute]).
class StockNavChips extends StatelessWidget {
  final String shopId;
  const StockNavChips({super.key, required this.shopId});

  @override
  Widget build(BuildContext context) {
    final l       = context.l10n;
    final theme   = Theme.of(context);
    final loc     = GoRouterState.of(context).matchedLocation;
    // (id, label, route)
    final chips = <(String, String, String)>[
      ('produits',     l.navInvProduits,     '/shop/$shopId/inventaire'),
      ('emplacements', l.navInvEmplacements, '/shop/$shopId/parametres/locations'),
      ('incidents',    l.navInvIncidents,    '/shop/$shopId/inventaire/incidents'),
    ];
    // Détermine la route active par **longest-prefix-wins** : sur
    // `/inventaire/stock-movements`, sans ce filtre, Produits
    // (`/inventaire`) ET Mouvements (`/inventaire/stock-movements`)
    // matcheraient tous les deux → 2 tabs actifs en même temps. On
    // garde uniquement le préfixe le plus long.
    String? activeChipId;
    var activeLen = 0;
    for (final c in chips) {
      final matches = loc == c.$3 || loc.startsWith('${c.$3}/');
      if (matches && c.$3.length > activeLen) {
        activeChipId = c.$1;
        activeLen    = c.$3.length;
      }
    }
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
            bottom: BorderSide(color: AppColors.divider, width: 0.5)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) {
          final c = chips[i];
          final active = activeChipId == c.$1;
          return GestureDetector(
            onTap: active ? null : () => context.go(c.$3),
            behavior: HitTestBehavior.opaque,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                    bottom: BorderSide(
                        color: active
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                        width: 2)),
              ),
              alignment: Alignment.center,
              child: Text(c.$2,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active
                          ? theme.colorScheme.primary
                          : AppColors.textSecondary)),
            ),
          );
        },
      ),
    );
  }
}

/// Vrai si la route donnée est l'une des sous-pages Stock racines (match
/// EXACT — pas `startsWith`). Utilisé par `_MobileShell` / `_DesktopShell`
/// pour traiter ces routes comme « root » (pas de back button — elles sont
/// dans le drawer). Une sub-route comme `/parametres/locations/{id}` ne
/// matche PAS → le shell affiche un back button (UX attendue : retour
/// vers la liste des emplacements).
bool matchesStockNavRoute(String location, String shopId) {
  final routes = [
    '/shop/$shopId/inventaire',
    '/shop/$shopId/parametres/locations',
    '/shop/$shopId/parametres/transfers',
    '/shop/$shopId/inventaire/stock-movements',
    '/shop/$shopId/inventaire/incidents',
  ];
  return routes.contains(location);
}
