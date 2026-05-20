import 'package:flutter/material.dart';

import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../data/onboarding_prefs.dart';

/// Bannière didactique « 1ʳᵉ vente » (point 8 de l'onboarding spec).
///
/// Affichée en haut de la page Caisse tant que :
///   • le device n'a jamais vu le tooltip
///     (`OnboardingPrefs.hasSeenFirstSaleTooltip == false`)
///   • ET aucune commande complétée n'existe encore pour cette boutique
///     (auto-dismiss à la 1ʳᵉ vente)
///
/// 3 étapes successives, l'utilisateur clique « Suivant » pour avancer
/// ou « Passer » pour fermer définitivement. À la dernière étape, le
/// bouton devient « C'est compris ».
///
/// Implémentation **non-bloquante** : pas d'overlay modal, pas de
/// Stack au-dessus du contenu. Le widget se rend en haut du body comme
/// une bannière classique pour ne pas interférer avec le bloc Caisse.
/// (Spec : « Ne pas toucher à CaisseBloc ».)
class FirstSaleTooltipBanner extends StatefulWidget {
  /// Id de la boutique active — sert à détecter l'auto-dismiss
  /// (1ʳᵉ vente effective).
  final String shopId;
  const FirstSaleTooltipBanner({super.key, required this.shopId});

  @override
  State<FirstSaleTooltipBanner> createState() =>
      _FirstSaleTooltipBannerState();
}

class _FirstSaleTooltipBannerState extends State<FirstSaleTooltipBanner> {
  static const _steps = <_Step>[
    _Step(
      icon:  Icons.search_rounded,
      title: '1. Cherchez un produit',
      body:  'Tapez son nom ou scannez le code-barres en haut de la page.',
    ),
    _Step(
      icon:  Icons.shopping_cart_outlined,
      title: '2. Ajoutez au panier',
      body:  'Cliquez sur le produit pour l\'ajouter, ajustez la quantité.',
    ),
    _Step(
      icon:  Icons.check_circle_outline,
      title: '3. Validez la vente',
      body:  'Choisissez le moyen de paiement et appuyez sur « Encaisser ».',
    ),
  ];

  bool? _seen;
  int   _stepIndex = 0;

  @override
  void initState() {
    super.initState();
    _checkSeen();
  }

  Future<void> _checkSeen() async {
    final seen = await OnboardingPrefs.hasSeenFirstSaleTooltip();
    if (!mounted) return;
    setState(() => _seen = seen);
  }

  Future<void> _dismiss() async {
    await OnboardingPrefs.markFirstSaleTooltipSeen();
    if (!mounted) return;
    setState(() => _seen = true);
  }

  void _next() {
    if (_stepIndex < _steps.length - 1) {
      setState(() => _stepIndex++);
    } else {
      _dismiss();
    }
  }

  bool get _hasCompletedSale {
    // Auto-dismiss à la 1ʳᵉ vente : on parcourt les orders Hive de la
    // boutique active à la recherche d'au moins une commande completed.
    // Lecture courte (premier match) — pas de surcoût notable.
    try {
      for (final raw in HiveBoxes.ordersBox.values) {
        final m = Map<String, dynamic>.from(raw);
        if (m['shop_id'] != widget.shopId) continue;
        if (m['deleted_at'] != null)       continue;
        if ((m['status'] as String?) == 'completed') return true;
      }
    } catch (_) {/* hive pas prêt, retomber sur seen */}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_seen == null)         return const SizedBox.shrink();
    if (_seen!)                return const SizedBox.shrink();
    if (_hasCompletedSale)     return const SizedBox.shrink();

    final step = _steps[_stepIndex];
    final isLast = _stepIndex == _steps.length - 1;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(step.icon,
                color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(step.title, style: AppTextStyles.bodyBold),
                const SizedBox(height: 2),
                Text(step.body,
                    style: AppTextStyles.bodySmSecondary),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Passer',
                icon: const Icon(Icons.close_rounded,
                    color: AppColors.textSecondary, size: 18),
                onPressed: _dismiss,
                visualDensity: VisualDensity.compact,
              ),
              ElevatedButton(
                onPressed: _next,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(isLast ? 'C\'est compris' : 'Suivant',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Step {
  final IconData icon;
  final String   title;
  final String   body;
  const _Step({
    required this.icon,
    required this.title,
    required this.body,
  });
}
