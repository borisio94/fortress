import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../data/onboarding_prefs.dart';

/// Bannière douce « Confirmez votre email » (point 4 de l'onboarding spec).
///
/// Affichée en haut du dashboard immédiatement après inscription tant que :
///   • Une session est active.
///   • L'utilisateur n'a PAS encore confirmé son email côté Supabase
///     (`auth.users.email_confirmed_at == null`).
///   • L'utilisateur n'a PAS fermé la bannière manuellement (flag
///     SharedPreferences user-scoped `onboarding_email_confirm_banner_*`).
///
/// L'inscription est **non bloquante** : on laisse l'accès complet à
/// l'app, la bannière sert juste de rappel doux. Elle disparaît
/// automatiquement quand le user click le lien dans son email
/// (`email_confirmed_at` cesse d'être null).
///
/// Le widget se replie sur `SizedBox.shrink()` quand il ne doit pas
/// s'afficher → safe à inclure partout sans condition externe.
class EmailConfirmBanner extends StatefulWidget {
  /// Padding autour de la bannière (laissé au parent par défaut).
  final EdgeInsets margin;
  const EmailConfirmBanner({
    super.key,
    this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 0),
  });

  @override
  State<EmailConfirmBanner> createState() => _EmailConfirmBannerState();
}

class _EmailConfirmBannerState extends State<EmailConfirmBanner> {
  bool _dismissed = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _checkInitialState();
  }

  Future<void> _checkInitialState() async {
    final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    final dismissed = await OnboardingPrefs.isEmailConfirmBannerDismissed(uid);
    if (!mounted) return;
    setState(() {
      _dismissed = dismissed;
      _initialized = true;
    });
  }

  Future<void> _dismiss() async {
    final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    await OnboardingPrefs.dismissEmailConfirmBanner(uid);
    if (!mounted) return;
    setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized || _dismissed) return const SizedBox.shrink();
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return const SizedBox.shrink();
    // emailConfirmedAt est non-null dès que Supabase a validé le lien.
    // En l'absence de cette valeur → on affiche le rappel.
    if (user.emailConfirmedAt != null) return const SizedBox.shrink();
    final email = user.email ?? '';

    return Padding(
      padding: widget.margin,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: AppColors.warning.withValues(alpha: 0.30)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.mark_email_unread_outlined,
                color: AppColors.warning, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Confirmez votre email',
                    style: AppTextStyles.bodyBold.copyWith(
                        color: AppColors.textPrimary),
                  ),
                  if (email.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Vérifiez votre boîte $email — le lien sécurise '
                        'votre compte.',
                        style: AppTextStyles.bodySm.copyWith(
                            color: AppColors.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Plus tard',
              icon: const Icon(Icons.close_rounded,
                  color: AppColors.textSecondary, size: 18),
              onPressed: _dismiss,
            ),
          ],
        ),
      ),
    );
  }
}
