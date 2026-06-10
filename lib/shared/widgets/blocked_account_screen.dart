import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_names.dart';
import '../../core/theme/app_text_styles.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_event.dart';

/// Écran affiché quand le COMPTE de l'utilisateur a été bloqué par le
/// super-admin (`profiles.prof_status='blocked'` → get_user_plan.is_blocked).
/// Verrouille toute l'application : seule la déconnexion est possible.
/// Les super-admins ne voient jamais cet écran (garde routeur).
class BlockedAccountScreen extends StatelessWidget {
  const BlockedAccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 84, height: 84,
                  decoration: BoxDecoration(
                    color: cs.error.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.lock_person_rounded, size: 44, color: cs.error),
                ),
                const SizedBox(height: 20),
                Text('Compte bloqué',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.title.copyWith(color: cs.onSurface)),
                const SizedBox(height: 10),
                Text(
                  'Votre compte a été bloqué par l\'administrateur de la '
                  'plateforme. L\'accès à l\'application est suspendu. '
                  'Veuillez contacter le support pour régulariser la situation.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.body.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () {
                      context.read<AuthBloc>().add(AuthLogoutRequested());
                      context.go(RouteNames.login);
                    },
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('Se déconnecter'),
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
