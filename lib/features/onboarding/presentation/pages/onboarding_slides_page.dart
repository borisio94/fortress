import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../providers/onboarding_seen_provider.dart';

/// Slides d'intro affichées UNE SEULE FOIS par compte, à la première
/// connexion (cf. hotfix_099 + onboardingSlidesSeenProvider).
///
/// 3 cartes swipables qui présentent les 3 valeurs clés de l'app. Le
/// bouton « Commencer » est visible **dès la première slide** (le user
/// n'a pas à swiper jusqu'au bout). Au tap, on marque le flag serveur
/// `profiles.onboarding_slides_seen = true` (donc plus jamais réaffiché,
/// même sur un autre appareil) puis on entre dans l'app.
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
    // Marque le flag local IMMÉDIATEMENT pour que le `redirect` GoRouter ne
    // renvoie pas l'utilisateur sur cette page (optimiste : suffit pour la
    // session courante même si l'écriture serveur échoue).
    ref.read(onboardingSlidesSeenProvider.notifier).state = true;

    // Persiste le flag côté serveur (cross-device) — best-effort.
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid != null) {
      try {
        await client
            .from('profiles')
            .update({'onboarding_slides_seen': true}).eq('id', uid);
      } catch (_) {/* réseau KO : le flag local couvre cette session */}
    }

    if (!mounted) return;
    // Les slides étant désormais post-login, on entre directement dans l'app.
    // shop-selector se charge de router vers le dashboard si une seule boutique.
    context.go(RouteNames.shopSelector);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        // Desktop : borne la largeur et centre — sinon header, slides, dots
        // et CTA s'étiraient sur tout l'écran (rendu « grossier »).
        child: Center(
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
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
                    child: Text('Passer',
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
    // Centrage vertical quand ça tient, scroll quand l'écran est trop court
    // (sinon, avec `mainAxisAlignment.center`, le débordement rognait le
    // HAUT du contenu → le cercle/icône disparaissait sur petit mobile).
    // `maxWidth` borne la largeur sur desktop (sinon titre/texte s'étiraient
    // sur toute la largeur — rendu « grossier »).
    return LayoutBuilder(
      builder: (_, c) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
