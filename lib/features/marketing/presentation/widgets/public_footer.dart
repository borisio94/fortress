import 'package:flutter/material.dart';

import '../../../../core/services/external_launcher.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PublicFooter — pied de page des pages publiques (landing + pricing).
// 3 colonnes desktop / 1 colonne mobile :
//   1. Marque + tagline
//   2. Liens "Légal" (CGU, Privacy — placeholders 404 OK tant que les pages
//      ne sont pas écrites, cf. Sprint 4.7 du canvas).
//   3. Contact WhatsApp Business pro (numéro hardcodé pour l'instant — à
//      remplacer par le numéro pro Fortress quand le compte sera créé).
//
// Le numéro pro est centralisé en const en haut du fichier pour faciliter
// le remplacement à un seul endroit le jour du go-live.
// ═════════════════════════════════════════════════════════════════════════════

const _kContactWhatsappE164 = '+237697926045';
const _kContactWhatsappLabel = '+237 697 92 60 45';

class PublicFooter extends StatelessWidget {
  const PublicFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.of(context).size.width >= 720;
    final cols = <Widget>[
      _BrandColumn(theme: theme),
      _LegalColumn(theme: theme),
      _ContactColumn(theme: theme),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.4),
        border: Border(
          top: BorderSide(
              color: theme.colorScheme.outline.withValues(alpha: 0.15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isWide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cols[0]),
                Expanded(child: cols[1]),
                Expanded(child: cols[2]),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                cols[0],
                const SizedBox(height: 24),
                cols[1],
                const SizedBox(height: 24),
                cols[2],
              ],
            ),
          const SizedBox(height: 28),
          Divider(
              color: theme.colorScheme.outline.withValues(alpha: 0.15),
              height: 1),
          const SizedBox(height: 14),
          Text('© ${DateTime.now().year} Fortress POS · '
              'Conçu pour les marchands camerounais',
              style: AppTextStyles.caption.copyWith(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.55))),
        ],
      ),
    );
  }
}

class _BrandColumn extends StatelessWidget {
  final ThemeData theme;
  const _BrandColumn({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Fortress',
            style: AppTextStyles.subtitleBold.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurface)),
        const SizedBox(height: 6),
        Text(
            'Le POS multi-boutiques offline-first '
            'pour les marchands camerounais.',
            style: AppTextStyles.bodySm.copyWith(
                height: 1.5,
                color: theme.colorScheme.onSurface
                    .withValues(alpha: 0.7))),
      ],
    );
  }
}

class _LegalColumn extends StatelessWidget {
  final ThemeData theme;
  const _LegalColumn({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ColTitle('LÉGAL', theme: theme),
        const SizedBox(height: 10),
        // Placeholders : routes pas encore créées (sprint 4.7 canvas).
        // Cliquables visuellement mais tombent sur la landing pour l'instant.
        // Quand /terms et /privacy seront écrits, remplacer le onTap.
        _FooterLink(label: 'Conditions générales', onTap: () {}),
        _FooterLink(label: 'Confidentialité', onTap: () {}),
        _FooterLink(label: 'Politique de remboursement', onTap: () {}),
      ],
    );
  }
}

class _ContactColumn extends StatelessWidget {
  final ThemeData theme;
  const _ContactColumn({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ColTitle('CONTACT', theme: theme),
        const SizedBox(height: 10),
        // wa.me direct — sans message pré-rempli pour rester neutre.
        InkWell(
          onTap: () {
            final digits = _kContactWhatsappE164
                .replaceAll(RegExp(r'[^0-9]'), '');
            openExternal('https://wa.me/$digits');
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.chat_outlined,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(_kContactWhatsappLabel,
                  style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                      decoration: TextDecoration.underline,
                      decorationColor:
                          AppColors.primary.withValues(alpha: 0.5))),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        Text('Réponse 24h, sept jours sur sept',
            style: AppTextStyles.caption.copyWith(
                color: theme.colorScheme.onSurface
                    .withValues(alpha: 0.55))),
      ],
    );
  }
}

class _ColTitle extends StatelessWidget {
  final String label;
  final ThemeData theme;
  const _ColTitle(this.label, {required this.theme});

  @override
  Widget build(BuildContext context) => Text(label,
      style: AppTextStyles.micro.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5)));
}

class _FooterLink extends StatelessWidget {
  final String       label;
  final VoidCallback onTap;
  const _FooterLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(label,
            style: AppTextStyles.bodySm.copyWith(
                color: theme.colorScheme.onSurface
                    .withValues(alpha: 0.75))),
      ),
    );
  }
}
