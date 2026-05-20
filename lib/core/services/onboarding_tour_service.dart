import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/onboarding_keys_provider.dart';
import '../theme/app_colors.dart';

// ═════════════════════════════════════════════════════════════════════════════
// OnboardingTourService — tour guidé 5 étapes au premier login après
// inscription self-service (cf. canvas Phase 2 Sprint 2.3).
//
// Architecture : `showDialog` plein écran avec PageView 5 pages. Chaque page
// = illustration + titre + body. Last page = CTA "Aller dans Inventaire"
// qui ferme le modal et navigue. Skip OU finish → marque le flag.
//
// Pivot par rapport à la 1ʳᵉ version (coach marks ancrés) : sur mobile la
// nav est dans un drawer fermé par défaut — pointer dessus est fragile.
// Un modal plein écran avec illustrations marche partout identiquement.
// ═════════════════════════════════════════════════════════════════════════════

class OnboardingTourService {
  static bool _showing = false;

  /// Affiche le tour si le flag local n'est pas encore set. Idempotent.
  /// `shopId` est utilisé pour la navigation du CTA final (vers Inventaire
  /// de la boutique courante).
  static Future<void> showIfFirstLogin(
      BuildContext context, String uid, String shopId) async {
    if (_showing) return;
    if (isOnboardingDone(uid)) return;
    if (uid.isEmpty || shopId.isEmpty) return;
    _showing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.75),
        builder: (_) => _OnboardingDialog(uid: uid, shopId: shopId),
      );
    } finally {
      _showing = false;
    }
  }
}

// ─── Modal walkthrough ────────────────────────────────────────────────────

class _OnboardingDialog extends StatefulWidget {
  final String uid;
  final String shopId;
  const _OnboardingDialog({required this.uid, required this.shopId});

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  final _pageCtrl = PageController();
  int _step = 0;

  static const _steps = <_StepData>[
    _StepData(
      icon:  Icons.celebration_rounded,
      title: 'Bienvenue dans Fortress 👋',
      body:  'Faisons le tour en 60 secondes. Vous découvrirez où ajouter '
             'vos produits, gérer vos clients et faire vos premières ventes.',
    ),
    _StepData(
      icon:  Icons.inventory_2_rounded,
      title: 'Ajoutez vos produits',
      body:  'Direction l\'Inventaire (icône boîte dans le menu) : ajoutez '
             'vos produits, leurs variantes, prix, stock et photos. C\'est '
             'la base de tout votre catalogue.',
    ),
    _StepData(
      icon:  Icons.person_rounded,
      title: 'Constituez votre fichier clients',
      body:  'L\'onglet Clients regroupe votre carnet d\'adresses, '
             'l\'historique des commandes et le solde de chaque client. '
             'Aussi accessible depuis la caisse pendant une vente.',
    ),
    _StepData(
      icon:  Icons.shopping_cart_rounded,
      title: 'Faites votre première vente',
      body:  'La Caisse fonctionne MÊME sans internet : encaissez d\'abord, '
             'la synchronisation se fait dès la reconnexion. Aucune vente '
             'perdue, jamais.',
    ),
    _StepData(
      icon:  Icons.share_rounded,
      title: 'Partagez votre catalogue WhatsApp',
      body:  'Depuis Inventaire, utilisez le bouton « Partager » pour '
             'envoyer votre catalogue à vos clients en un clic. Ils '
             'commandent ensuite directement via WhatsApp.',
      ctaLabel: 'C\'est parti — aller à Inventaire',
    ),
  ];

  void _next() {
    if (_step >= _steps.length - 1) {
      _finish(goToInventaire: true);
      return;
    }
    setState(() => _step++);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut);
  }

  void _back() {
    if (_step == 0) return;
    setState(() => _step--);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut);
  }

  Future<void> _finish({bool goToInventaire = false}) async {
    await markOnboardingDone(widget.uid);
    debugPrint('[OnboardingTour] Flag terminé — goToInventaire=$goToInventaire');
    if (!mounted) return;
    Navigator.of(context).pop();
    if (goToInventaire) {
      context.go('/shop/${widget.shopId}/inventaire');
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.of(context).size.width >= 600;
    final isLast = _step == _steps.length - 1;
    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      insetPadding:
          EdgeInsets.symmetric(horizontal: isWide ? 80 : 20, vertical: 40),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: isWide ? 460 : double.infinity,
            maxHeight:
                MediaQuery.of(context).size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header avec bouton Passer
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(children: [
                Text('Étape ${_step + 1}/${_steps.length}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.55))),
                const Spacer(),
                if (!isLast)
                  TextButton(
                    onPressed: () => _finish(),
                    child: Text('Passer',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6))),
                  ),
              ]),
            ),
            // PageView
            Flexible(
              child: PageView(
                controller: _pageCtrl,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final s in _steps) _StepCard(data: s),
                ],
              ),
            ),
            // Indicateur de progression (dots)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_steps.length, (i) {
                    final active = i == _step;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: active ? 22 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                          color: active
                              ? AppColors.primary
                              : AppColors.primary.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(3)),
                    );
                  })),
            ),
            // Bottom : Précédent + Suivant / Terminer
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
              child: Row(children: [
                TextButton(
                  onPressed: _step == 0 ? null : _back,
                  child: Text('Précédent',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _step == 0
                              ? theme.colorScheme.onSurface
                                  .withValues(alpha: 0.3)
                              : theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7))),
                ),
                const Spacer(),
                ElevatedButton(
                  onPressed: _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    // Sans ça, le minimumSize Size(double.infinity, 52)
                    // du thème global rend le bouton infiniment large
                    // dans le Row → il déborde hors du dialogue et
                    // « Suivant » devient invisible.
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                      isLast
                          ? _steps[_step].ctaLabel ?? 'Terminer'
                          : 'Suivant',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepData {
  final IconData icon;
  final String   title;
  final String   body;
  final String?  ctaLabel;
  const _StepData({
    required this.icon,
    required this.title,
    required this.body,
    this.ctaLabel,
  });
}

class _StepCard extends StatelessWidget {
  final _StepData data;
  const _StepCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Illustration circulaire avec icône
          Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.only(top: 12, bottom: 20),
            child: Container(
              width: 96, height: 96,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.18),
                    AppColors.primary.withValues(alpha: 0.06),
                  ],
                  begin: Alignment.topLeft,
                  end:   Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(data.icon,
                  size: 44, color: AppColors.primary),
            ),
          ),
          Text(data.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                  color: theme.colorScheme.onSurface)),
          const SizedBox(height: 10),
          Text(data.body,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.75))),
        ],
      ),
    );
  }
}

