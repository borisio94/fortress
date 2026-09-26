import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/external_launcher.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_scaffold.dart';

// Métadonnées application. `version` est figée ici (pas de package_info_plus
// dans les deps) — à incrémenter manuellement avec `pubspec.yaml`.
const _kAppName = 'Fortress';
const _kAppVersion = '1.0.0';
const _kAppChannel = 'Bêta';
const _kSiteUrl = 'https://fortress-pos.web.app';
const _kSupportEmail = 'posfortress@gmail.com';

/// Page À propos — accessible globalement via le menu « 3 points ».
class AProposPage extends StatelessWidget {
  final String? shopId;
  const AProposPage({super.key, this.shopId});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: shopId ?? '',
      title: 'À propos',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          // ── Logo + nom + version ──────────────────────────────────────
          Center(
            child: Column(children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.primaryFill,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.shield_rounded,
                    color: Colors.white, size: 44),
              ),
              const SizedBox(height: 14),
              Text(_kAppName,
                  style: AppTextStyles.title
                      .copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Version $_kAppVersion · $_kAppChannel',
                    style: AppTextStyles.caption.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
          const SizedBox(height: 28),
          // ── Description ───────────────────────────────────────────────
          Text(
            'Fortress est une caisse intelligente pensée pour les '
            'commerces multi-boutiques. Gérez vos ventes, votre stock, '
            'vos clients et vos finances depuis un seul endroit — même '
            'hors connexion.',
            style: AppTextStyles.body
                .copyWith(color: const Color(0xFF4B5563), height: 1.55),
          ),
          const SizedBox(height: 24),
          // ── Liens / contact ───────────────────────────────────────────
          _LinkTile(
            icon: Icons.public_rounded,
            label: 'Site web',
            value: 'fortress-pos.web.app',
            onTap: () => openExternal(_kSiteUrl),
          ),
          _LinkTile(
            icon: Icons.mail_outline_rounded,
            label: 'Contact',
            value: _kSupportEmail,
            onTap: () => openExternal('mailto:$_kSupportEmail'),
          ),
          _LinkTile(
            icon: Icons.help_outline_rounded,
            label: 'Aide & FAQ',
            value: 'Centre d\'assistance',
            onTap: () => context.push('/shop/${shopId ?? ''}/aide'),
          ),
          const SizedBox(height: 28),
          // ── Mentions légales ──────────────────────────────────────────
          Center(
            child: Column(children: [
              Text('© 2026 $_kAppName',
                  style: AppTextStyles.caption
                      .copyWith(color: const Color(0xFF9CA3AF))),
              const SizedBox(height: 2),
              Text('Tous droits réservés.',
                  style: AppTextStyles.caption
                      .copyWith(color: const Color(0xFF9CA3AF))),
            ]),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  const _LinkTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: ListTile(
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 19, color: AppColors.primary),
        ),
        title: Text(label,
            style: AppTextStyles.body
                .copyWith(fontWeight: FontWeight.w700)),
        subtitle: Text(value,
            style: AppTextStyles.bodySm
                .copyWith(color: const Color(0xFF9CA3AF))),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: Color(0xFFB0B7C3)),
        onTap: onTap,
      ),
    );
  }
}
