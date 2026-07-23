import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../features/inventaire/domain/entities/product.dart';

/// Salutation « Bienvenue, <prénom> » de la barre supérieure restaurant.
class RestoGreeting extends StatelessWidget {
  const RestoGreeting({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final full = LocalStorageService.getCurrentUser()?.name.trim() ?? '';
    // Prénom seul : un nom complet déborderait sur la recherche en 1200 px.
    final first = full.isEmpty ? '' : full.split(RegExp(r'\s+')).first;

    return Text(
      first.isEmpty ? 'Bienvenue 👋' : 'Bienvenue, $first 👋',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.subtitleBold.copyWith(color: cs.onSurface),
    );
  }
}

/// Recherche de la barre supérieure restaurant.
///
/// Cherche dans la carte (produits de la boutique) et ouvre la fiche du plat
/// sélectionné. Volontairement limitée aux plats : c'est la recherche utile
/// en service, et un champ décoratif qui ne ferait rien serait pire que pas
/// de champ du tout.
class RestoSearchField extends StatefulWidget {
  final String shopId;

  const RestoSearchField({super.key, required this.shopId});

  @override
  State<RestoSearchField> createState() => _RestoSearchFieldState();
}

class _RestoSearchFieldState extends State<RestoSearchField> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _link = LayerLink();
  OverlayEntry? _overlay;
  List<Product> _results = const [];

  @override
  void dispose() {
    _hide();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    final query = q.trim().toLowerCase();
    if (query.length < 2) {
      setState(() => _results = const []);
      _hide();
      return;
    }
    final all = LocalStorageService.getProductsForShop(widget.shopId);
    setState(() {
      _results = all
          .where((p) => p.name.toLowerCase().contains(query))
          .take(6)
          .toList();
    });
    if (_results.isEmpty) {
      _hide();
    } else {
      _show();
    }
  }

  void _show() {
    _overlay?.markNeedsBuild();
    if (_overlay != null) return;
    final overlay = OverlayEntry(builder: (ctx) {
      final theme = Theme.of(ctx);
      final sem = theme.semantic;
      return Positioned(
        width: 420,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          offset: const Offset(0, 44),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            color: sem.elevatedSurface,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sem.borderSubtle),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final p in _results)
                    InkWell(
                      onTap: () => _open(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Row(
                          children: [
                            Icon(Icons.restaurant_rounded,
                                size: 16, color: theme.colorScheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodySm.copyWith(
                                      color: theme.colorScheme.onSurface)),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    });
    _overlay = overlay;
    Overlay.of(context).insert(overlay);
  }

  void _hide() {
    _overlay?.remove();
    _overlay = null;
  }

  void _open(Product p) {
    _hide();
    _ctrl.clear();
    _focus.unfocus();
    setState(() => _results = const []);
    context.push('/shop/${widget.shopId}/inventaire/product', extra: p);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;

    return CompositedTransformTarget(
      link: _link,
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: sem.trackMuted,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: sem.borderSubtle),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(Icons.search_rounded,
                size: 18,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                onChanged: _onChanged,
                style: AppTextStyles.bodySm
                    .copyWith(color: theme.colorScheme.onSurface),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Rechercher un plat…',
                  hintStyle: AppTextStyles.bodySm.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.45)),
                ),
              ),
            ),
            if (_ctrl.text.isNotEmpty)
              InkWell(
                onTap: () {
                  _ctrl.clear();
                  _onChanged('');
                },
                child: Icon(Icons.close_rounded,
                    size: 16,
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.5)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bloc identité à droite de la barre : avatar, nom, rôle.
class RestoUserChip extends StatelessWidget {
  final bool isAdmin;

  const RestoUserChip({super.key, required this.isAdmin});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final user = LocalStorageService.getCurrentUser();
    final name = (user?.name ?? '').trim();
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: cs.primary.withValues(alpha: 0.14),
          child: Text(initial,
              style: AppTextStyles.bodySmBold.copyWith(color: cs.primary)),
        ),
        const SizedBox(width: 9),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name.isEmpty ? 'Utilisateur' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmBold.copyWith(color: cs.onSurface),
            ),
            Text(isAdmin ? 'Admin' : 'Équipe',
                style: AppTextStyles.micro),
          ],
        ),
      ],
    );
  }
}
