import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/hive_boxes.dart';
import '../../core/storage/local_storage_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_text_styles.dart';
import '../../features/dashboard/data/dashboard_providers.dart';
import '../../features/inventaire/domain/entities/stock_location.dart';
import '../../features/restaurant/presentation/widgets/resto_surfaces.dart';

/// Barre de chips « Vue » partagée entre Dashboard, Produits, Vente, Commandes.
///
/// 3 états pilotés par `dashViewFilterProvider` (cf. `dashboard_providers.dart`) :
///   * `null`           — Globale (boutique + tous ses partenaires).
///   * `'_base'`        — Uniquement la `StockLocation type='shop'`.
///   * `<location_id>`  — Un partenaire `StockLocation type='partner'` actif.
///
/// Reset à `null` quand `shopId` change (un partenaire d'une autre boutique
/// n'a aucun sens). L'état est partagé entre les pages — l'utilisateur garde
/// son contexte en navigant.
///
/// `showGlobal` (true par défaut) : afficher le chip « Globale ». À masquer
/// sur les pages où la vue agrégée n'a pas de sens métier (ex. Vente : on
/// ne peut pas vendre depuis "toutes les sources à la fois").
///
/// `useTabs` (false par défaut) : rendu sous forme d'onglets modernes (texte +
/// icône, indicateur souligné sur l'élément actif, sans cadre encadrant) au
/// lieu de chips arrondies. Utilisé sur Produits / Vente / Commandes ; le
/// dashboard garde le rendu chip historique.
class ViewFilterChipBar extends ConsumerStatefulWidget {
  final String shopId;
  final bool showGlobal;
  final bool useTabs;
  const ViewFilterChipBar({
    super.key,
    required this.shopId,
    this.showGlobal = true,
    this.useTabs = false,
  });

  @override
  ConsumerState<ViewFilterChipBar> createState() => _ViewFilterChipBarState();
}

class _ViewFilterChipBarState extends ConsumerState<ViewFilterChipBar> {
  /// Change la vue/emplacement ET force le recalcul de TOUS les providers
  /// pilotés par le signal dashboard (dashData, scrapJournal, finances…),
  /// en plus de ceux qui watchent déjà `dashViewFilterProvider`. Sans ce
  /// bump, un écran dont le provider dépend du signal (et pas directement
  /// du filtre) gardait les chiffres de l'ancienne vue. Point de mutation
  /// UNIQUE → toute bascule de vue rafraîchit partout.
  void _setView(String? v) {
    if (ref.read(dashViewFilterProvider) == v) return;
    ref.read(dashViewFilterProvider.notifier).state = v;
    ref.read(dashSignalProvider.notifier).state++;
  }

  @override
  void didUpdateWidget(covariant ViewFilterChipBar old) {
    super.didUpdateWidget(old);
    if (old.shopId != widget.shopId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _setView(null);
      });
    }
  }

  /// Partenaires actifs rattachés à la boutique (même `owner_id`).
  List<StockLocation> _partners() {
    final shop = LocalStorageService.getShop(widget.shopId);
    final ownerId = shop?.ownerId;
    if (ownerId == null) return const [];
    final out = <StockLocation>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (loc.ownerId == ownerId
            && loc.type == StockLocationType.partner
            && loc.isActive) {
          out.add(loc);
        }
      } catch (_) {/* ignore une ligne corrompue */}
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final cs       = theme.colorScheme;
    final sem      = theme.semantic;
    final selected = ref.watch(dashViewFilterProvider);
    final partners = _partners();
    // « Globale » (boutique + partenaires agrégés) n'a de sens QUE s'il y a
    // plus d'un emplacement à agréger : la boutique + au moins un partenaire.
    // Avec la seule boutique (aucun partenaire), « Globale » est identique à
    // l'onglet boutique → on le masque (demande utilisateur).
    final effectiveShowGlobal = widget.showGlobal && partners.isNotEmpty;
    // Sécurité : sur les pages/cas où « Globale » est masqué, un état null
    // laisserait aucun chip actif. On force '_base'.
    if (!effectiveShowGlobal && selected == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(dashViewFilterProvider) == null) {
          _setView('_base');
        }
      });
    }
    final shopName = LocalStorageService.getShop(widget.shopId)?.name
        ?? 'Boutique';

    // Onglet style « moderne » : icône + label, indicateur souligné en
    // dessous quand actif. Pas de fond rempli, pas de border arrondi —
    // se fond dans la page comme une TabBar classique.
    Widget tab({
      required String label,
      required IconData icon,
      required bool active,
      required VoidCallback onTap,
    }) {
      final fg = active ? cs.primary : cs.onSurface.withValues(alpha:0.55);
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? cs.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(label,
                style: AppTextStyles.bodySm.copyWith(
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    color: fg)),
          ]),
        ),
      );
    }

    Widget chip({
      required String label,
      required IconData icon,
      required bool active,
      required VoidCallback onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? cs.primary
                  : (restoDecorActive ? restoGlassFill(context) : cs.surface),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: active ? cs.primary : sem.borderSubtle),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 13,
                  color: active ? cs.onPrimary : cs.onSurface),
              const SizedBox(width: 6),
              Text(label,
                  style: AppTextStyles.bodySm.copyWith(
                      fontWeight: FontWeight.w700,
                      color: active ? cs.onPrimary : cs.onSurface)),
            ]),
          ),
        ),
      );
    }

    // Construit la liste des items dans un ordre stable :
    // [Globale (optionnel)] · Boutique · Partenaires…
    final builders = <Widget Function(bool useTabs)>[
      if (effectiveShowGlobal)
        (useTabs) {
          final args = (
            label:  'Globale',
            icon:   Icons.public_rounded,
            active: selected == null,
            onTap:  () => _setView(null),
          );
          return useTabs
              ? tab(label: args.label, icon: args.icon,
                    active: args.active, onTap: args.onTap)
              : chip(label: args.label, icon: args.icon,
                    active: args.active, onTap: args.onTap);
        },
      (useTabs) {
        final args = (
          label:  shopName,
          icon:   Icons.storefront_rounded,
          active: selected == '_base',
          onTap:  () => _setView('_base'),
        );
        return useTabs
            ? tab(label: args.label, icon: args.icon,
                  active: args.active, onTap: args.onTap)
            : chip(label: args.label, icon: args.icon,
                  active: args.active, onTap: args.onTap);
      },
      for (final p in partners)
        (useTabs) {
          final args = (
            label:  p.name,
            icon:   Icons.local_shipping_rounded,
            active: selected == p.id,
            onTap:  () => _setView(p.id),
          );
          return useTabs
              ? tab(label: args.label, icon: args.icon,
                    active: args.active, onTap: args.onTap)
              : chip(label: args.label, icon: args.icon,
                    active: args.active, onTap: args.onTap);
        },
    ];

    if (widget.useTabs) {
      // Rendu onglets : groupe compact aligné à gauche, scrollable
      // horizontalement si trop large. Pas de border pleine largeur —
      // l'indicateur souligné par onglet suffit comme repère visuel.
      // En restauration, la bande reçoit la teinte des cartes sur TOUTE sa
      // largeur : sans fond, c'était le décor brut qui passait entre les
      // onglets, seule zone de la page à ne rien avoir derrière le texte.
      return Container(
        width: double.infinity,
        color: restoDecorActive ? restoGlassFill(context) : null,
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [for (final b in builders) b(true)]),
        ),
      );
    }

    // Rendu chip historique (dashboard) : cadre, label « Vue », chips arrondies.
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: restoDecorActive ? restoGlassFill(context) : cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Vue',
            style: AppTextStyles.micro.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: cs.onSurface.withValues(alpha:0.55))),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [for (final b in builders) b(false)]),
        ),
      ]),
    );
  }
}
