import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../data/onboarding_prefs.dart';
import '../providers/onboarding_seen_provider.dart';

/// Slides marketing 1ʳᵉ ouverture (point 2 de l'onboarding spec).
///
/// 3 cartes swipables qui présentent les 3 valeurs clés de l'app. Le
/// bouton « Commencer » est visible **dès la première slide** (le user
/// n'a pas à swiper jusqu'au bout). Au tap, on marque `onboarding_seen`
/// dans SharedPreferences et on bascule vers l'écran de choix
/// inscription/connexion.
///
/// Une fois vues, ces slides ne se ré-affichent pas (gated par
/// [OnboardingPrefs.hasSeenSlides] au démarrage de l'app).
class OnboardingSlidesPage extends ConsumerStatefulWidget {
  const OnboardingSlidesPage({super.key});

  @override
  ConsumerState<OnboardingSlidesPage> createState() =>
      _OnboardingSlidesPageState();
}

class _OnboardingSlidesPageState extends ConsumerState<OnboardingSlidesPage> {
  final _pageCtrl = PageController();
  int _page = 0;

  static const _slides = <_SlideSpec>[
    _SlideSpec(
      icon:  Icons.inventory_2_outlined,
      title: 'Stock temps réel, même offline',
      body:  'Vendez sans crainte de coupure réseau. Vos quantités '
             'restent à jour sur tous vos appareils dès le retour en ligne.',
    ),
    _SlideSpec(
      icon:  Icons.dashboard_customize_outlined,
      title: 'Ventes · dépenses · livraisons — un seul écran',
      body:  'Caisse, catalogue web, partenaires de livraison, livre '
             'de comptes : tout est connecté pour décider vite.',
    ),
    _SlideSpec(
      icon:  Icons.card_giftcard_outlined,
      title: '14 jours gratuits, aucune carte requise',
      body:  'Testez tout en conditions réelles. Pas de prélèvement '
             'automatique, pas de surprise — vous choisissez ensuite.',
    ),
  ];

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await OnboardingPrefs.markSlidesSeen();
    // Synchronise le cache mémoire pour que le `redirect` GoRouter ne
    // renvoie pas l'utilisateur sur cette page au prochain refresh.
    if (!mounted) return;
    ref.read(onboardingSeenCacheProvider.notifier).state = true;
    context.go(RouteNames.onboardingAuthChoice);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header : logo + bouton Passer ───────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              child: Row(
                children: [
                  const FortressLogo(size: 32),
                  const SizedBox(width: 10),
                  Text('Fortress',
                      style: AppTextStyles.subtitleBold
                          .copyWith(color: AppColors.primary)),
                  const Spacer(),
                  TextButton(
                    onPressed: _finish,
                    child: const Text('Passer',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                ],
              ),
            ),

            // ── Slides ───────────────────────────────────────────────────
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) => _Slide(spec: _slides[i]),
              ),
            ),

            // ── Indicateurs (dots) ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_slides.length, (i) {
                  final active = i == _page;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width:  active ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: active
                          ? AppColors.primary
                          : AppColors.primary.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),

            // ── CTA « Commencer » + Suivant ─────────────────────────────
            // Spec : bouton « Commencer » visible dès la 1ʳᵉ slide.
            // On garde aussi un « Suivant » (icône) pour le swipe gesture.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _finish,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        _page == _slides.length - 1
                            ? 'Démarrer maintenant'
                            : 'Commencer',
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  if (_page < _slides.length - 1) ...[
                    const SizedBox(width: 10),
                    IconButton.filled(
                      onPressed: () => _pageCtrl.nextPage(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut),
                      style: IconButton.styleFrom(
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.1),
                        foregroundColor: AppColors.primary,
                        padding: const EdgeInsets.all(14),
                      ),
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlideSpec {
  final IconData icon;
  final String   title;
  final String   body;
  const _SlideSpec({
    required this.icon,
    required this.title,
    required this.body,
  });
}

class _Slide extends StatelessWidget {
  final _SlideSpec spec;
  const _Slide({required this.spec});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Cercle d'illustration — réutilise les tokens primaires.
          Container(
            width: 140, height: 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end:   Alignment.bottomRight,
                colors: [
                  AppColors.primary.withValues(alpha: 0.15),
                  AppColors.primary.withValues(alpha: 0.05),
                ],
              ),
            ),
            child: Icon(spec.icon, size: 64, color: AppColors.primary),
          ),
          const SizedBox(height: 36),
          Text(
            spec.title,
            textAlign: TextAlign.center,
            style: AppTextStyles.title.copyWith(height: 1.25),
          ),
          const SizedBox(height: 14),
          Text(
            spec.body,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySecondary.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}
