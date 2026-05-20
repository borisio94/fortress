import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/language_switcher.dart';

/// Écran d'orientation post-slides (point 3 de l'onboarding spec).
///
/// Aucun champ visible — l'utilisateur choisit explicitement entre :
///   • « Créer mon compte » → tunnel d'inscription simplifié
///     (`/onboarding/register`).
///   • « J'ai déjà un compte » → login standard (`/login`).
///
/// Pas de logique métier ici — uniquement de la navigation. Ce séparateur
/// évite la confusion "je dois cliquer où" sur une page login surchargée.
class AuthChoicePage extends StatelessWidget {
  const AuthChoicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar : language switcher uniquement ─────────────────
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: LanguageSwitcher(),
              ),
            ),

            // ── Bloc central : logo + titre + CTA ──────────────────────
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: FortressLogo(size: 80),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Bienvenue chez Fortress',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.title
                            .copyWith(height: 1.25, fontSize: 22),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Démarrez votre essai 14 jours ou connectez-vous.',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.bodySecondary,
                      ),
                      const SizedBox(height: 36),

                      // ── CTA primaire : Créer mon compte ─────────────
                      AppPrimaryButton(
                        label: 'Créer mon compte',
                        icon:  Icons.person_add_alt_rounded,
                        onTap: () => context.go(
                            RouteNames.onboardingRegister),
                      ),
                      const SizedBox(height: 12),

                      // ── CTA secondaire : J'ai déjà un compte ────────
                      OutlinedButton.icon(
                        onPressed: () => context.go(RouteNames.login),
                        icon:  const Icon(Icons.login_rounded, size: 18),
                        label: const Text('J\'ai déjà un compte'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: BorderSide(
                              color: AppColors.primary
                                  .withValues(alpha: 0.4)),
                          minimumSize: const Size.fromHeight(43),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          textStyle: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Footer : mention "Aucune carte requise" ────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shield_outlined,
                      size: 14,
                      color: AppColors.textSecondary.withValues(alpha: 0.7)),
                  const SizedBox(width: 6),
                  Text(
                    '14 jours gratuits · aucune carte requise',
                    style: AppTextStyles.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
