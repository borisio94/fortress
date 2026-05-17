import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/services/external_launcher.dart';
import '../../../../core/theme/app_colors.dart';
import '../widgets/landing_faq_section.dart';
import '../widgets/landing_waitlist_section.dart';
import '../widgets/public_footer.dart';
import '../widgets/public_top_bar.dart';

// ═════════════════════════════════════════════════════════════════════════════
// LandingPage — page publique d'accueil `/`. Marketing first :
//   ① Hero       : promesse + 2 CTAs (essai 14j / démo WhatsApp)
//   ② Features   : 3 cards (offline-first / catalogue WhatsApp / multi-boutiques)
//   ③ Waitlist   : capture email pour Automatisation WhatsApp Pro (Q3 2026)
//                  → cf. LandingWaitlistSection (Stateful, insert anon Supabase)
//   ④ FAQ        : 5 questions → cf. LandingFaqSection
//   ⑤ Footer     : légal + contact pro
//
// Audience cible : marchands camerounais (FR exclusif → textes hardcodés FR,
// pas de l10n pour la landing). À i18n-iser uniquement si on élargit le
// marché. Le numéro WhatsApp pour démo est temporairement le perso de
// l'owner — à remplacer par le numéro Business pro le jour du go-live.
// ═════════════════════════════════════════════════════════════════════════════

const _kDemoWhatsappE164 = '+237697926045';
const _kDemoMessage =
    'Bonjour, je découvre Fortress et j\'aimerais voir une démo de 10 minutes.';

class LandingPage extends StatelessWidget {
  const LandingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(children: [
        const PublicTopBar(currentRoute: RouteNames.landing),
        Expanded(
          child: SingleChildScrollView(
            child: Column(children: const [
              _HeroSection(),
              _FeaturesSection(),
              LandingWaitlistSection(),
              LandingFaqSection(),
              PublicFooter(),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─── ① Hero ──────────────────────────────────────────────────────────────

class _HeroSection extends StatelessWidget {
  const _HeroSection();

  void _openDemo() {
    final digits = _kDemoWhatsappE164.replaceAll(RegExp(r'[^0-9]'), '');
    final encoded = Uri.encodeComponent(_kDemoMessage);
    openExternal('https://wa.me/$digits?text=$encoded');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.of(context).size.width >= 720;
    return Container(
      width: double.infinity,
      padding:
          EdgeInsets.fromLTRB(24, isWide ? 80 : 48, 24, isWide ? 80 : 48),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: 0.06),
            theme.colorScheme.surface,
          ],
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(children: [
            Text('Gérez votre boutique sans carnets papier',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: isWide ? 38 : 28,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                    letterSpacing: -0.5,
                    color: theme.colorScheme.onSurface)),
            const SizedBox(height: 16),
            Text(
                'Caisse multi-boutiques, catalogue WhatsApp, alertes '
                'commandes. Conçu pour les marchands camerounais.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: isWide ? 17 : 15,
                    height: 1.5,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.7))),
            const SizedBox(height: 28),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton(
                  onPressed: () => context.go(RouteNames.register),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Essayer 14 jours gratuit',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800)),
                ),
                OutlinedButton.icon(
                  onPressed: _openDemo,
                  icon: const Icon(Icons.play_circle_outline_rounded,
                      size: 18),
                  label: const Text('Voir une démo (10 min)',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            // Raccourci connexion mis en évidence : les utilisateurs qui
            // ont déjà un compte atterrissent par défaut sur la landing.
            // Le bouton "Connexion" en haut à droite passe inaperçu — un
            // bouton tonal franc au cœur du hero les évite de recréer un
            // compte par erreur via le CTA principal.
            FilledButton.tonalIcon(
              onPressed: () => context.go(RouteNames.login),
              icon: const Icon(Icons.login_rounded, size: 19),
              label: const Text('J\'ai déjà un compte — Se connecter',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800)),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(
                    horizontal: 26, vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              runSpacing: 6,
              children: const [
                _HeroBullet(text: 'Sans carte bancaire'),
                _HeroBullet(text: 'Toutes les fonctionnalités'),
                _HeroBullet(text: 'Annulez à tout moment'),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _HeroBullet extends StatelessWidget {
  final String text;
  const _HeroBullet({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.check_circle_rounded, size: 14, color: AppColors.secondary),
      const SizedBox(width: 5),
      Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
    ]);
  }
}

// ─── ② Features ───────────────────────────────────────────────────────────

class _FeaturesSection extends StatelessWidget {
  const _FeaturesSection();

  static const _features = <_FeatureData>[
    _FeatureData(
      icon: Icons.point_of_sale_rounded,
      title: 'Caisse offline-first',
      body: 'Vendez même sans internet. Synchronisation automatique '
          'dès la reconnexion.',
    ),
    _FeatureData(
      icon: Icons.share_rounded,
      title: 'Catalogue WhatsApp partageable',
      body: 'Partagez votre catalogue en un clic. Vos clients commandent '
          'depuis WhatsApp.',
    ),
    _FeatureData(
      icon: Icons.storefront_rounded,
      title: 'Multi-boutiques et livreurs partenaires',
      body: 'Gérez plusieurs points de vente et vos livreurs depuis '
          'une seule interface.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.of(context).size.width >= 900;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
          horizontal: 24, vertical: isWide ? 56 : 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(children: [
            Text('Tout ce qu\'il vous faut pour digitaliser votre commerce',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: isWide ? 24 : 20,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSurface)),
            SizedBox(height: isWide ? 40 : 28),
            if (isWide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _features.length; i++) ...[
                    Expanded(child: _FeatureCard(data: _features[i])),
                    if (i < _features.length - 1) const SizedBox(width: 20),
                  ],
                ],
              )
            else
              Column(
                children: [
                  for (final f in _features) ...[
                    _FeatureCard(data: f),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
          ]),
        ),
      ),
    );
  }
}

class _FeatureData {
  final IconData icon;
  final String   title;
  final String   body;
  const _FeatureData(
      {required this.icon, required this.title, required this.body});
}

class _FeatureCard extends StatelessWidget {
  final _FeatureData data;
  const _FeatureCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            child: Icon(data.icon, size: 22, color: AppColors.primary),
          ),
          const SizedBox(height: 14),
          Text(data.title,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface)),
          const SizedBox(height: 6),
          Text(data.body,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.7))),
        ],
      ),
    );
  }
}
