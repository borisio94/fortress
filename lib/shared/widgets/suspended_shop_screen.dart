import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_names.dart';
import '../../core/theme/app_text_styles.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_event.dart';

/// Écran de blocage affiché quand la boutique courante a été SUSPENDUE
/// par le super-admin (cf. SA-1, `shops.status='suspended'`). Remplace
/// tout le contenu du shell tant que la suspension n'est pas levée.
/// Les super-admins ne voient JAMAIS cet écran (le guard les laisse
/// passer pour pouvoir gérer la suspension).
class SuspendedShopScreen extends StatelessWidget {
  final String? reason;
  const SuspendedShopScreen({super.key, this.reason});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84, height: 84,
                decoration: BoxDecoration(
                  color: cs.error.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.block_rounded, size: 44, color: cs.error),
              ),
              const SizedBox(height: 20),
              Text('Compte suspendu',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.title.copyWith(color: cs.onSurface)),
              const SizedBox(height: 10),
              Text(
                'L\'accès à cette boutique a été suspendu. '
                'Veuillez contacter le support pour régulariser la situation.',
                textAlign: TextAlign.center,
                style: AppTextStyles.body.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.7)),
              ),
              if ((reason ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.error.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.error.withValues(alpha: 0.25)),
                  ),
                  child: Text('Motif : ${reason!.trim()}',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodySm.copyWith(color: cs.error)),
                ),
              ],
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    // Retour au sélecteur de boutiques (l'utilisateur peut
                    // avoir d'autres boutiques non suspendues).
                    context.go(RouteNames.shopSelector);
                  },
                  icon: const Icon(Icons.storefront_outlined, size: 18),
                  label: const Text('Mes boutiques'),
                ),
              ),
              const SizedBox(height: 10),
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
    );
  }
}
