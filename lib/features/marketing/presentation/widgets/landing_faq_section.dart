import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

// ═════════════════════════════════════════════════════════════════════════════
// LandingFaqSection — 5 questions courantes pour lever les freins à
// l'inscription. ExpansionTile natifs, dépliables un par un, rendu
// classique formulaire. Au-delà de 5 questions, envisager un /help dédié.
// ═════════════════════════════════════════════════════════════════════════════

class LandingFaqSection extends StatelessWidget {
  const LandingFaqSection({super.key});

  static const _faq = <_FaqEntry>[
    _FaqEntry(q: 'Qui peut utiliser Fortress ?',
        a: 'Tout marchand camerounais qui veut digitaliser sa caisse, son '
           'stock et son catalogue. Boutiques mode, beauté, alimentation, '
           'multi-services — Fortress s\'adapte à votre activité.'),
    _FaqEntry(q: 'Comment fonctionne l\'essai gratuit ?',
        a: 'À l\'inscription, votre compte est automatiquement en essai '
           '14 jours avec toutes les fonctionnalités débloquées. Aucune '
           'carte bancaire demandée. À la fin, choisissez votre plan ou '
           'annulez.'),
    _FaqEntry(q: 'Comment payer mon abonnement ?',
        a: 'Bientôt par Mobile Money (Orange Money, MTN MoMo) directement '
           'depuis l\'app. Pendant la phase pilote, activation manuelle '
           'par notre équipe après paiement (WhatsApp).'),
    _FaqEntry(q: 'Que se passe-t-il si je dépasse mes limites ?',
        a: 'L\'app vous prévient avant la limite. Vous pouvez upgrader '
           'immédiatement vers un plan supérieur ou archiver des éléments. '
           'Aucune perte de données, jamais.'),
    _FaqEntry(q: 'Puis-je annuler à tout moment ?',
        a: 'Oui. L\'annulation prend effet à la fin de la période payée. '
           'Vos données restent accessibles en lecture seule pendant 30 '
           'jours pour export, puis sont définitivement supprimées.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      color: theme.colorScheme.surfaceContainerHighest
          .withValues(alpha: 0.3),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Questions fréquentes',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface)),
              const SizedBox(height: 20),
              for (final f in _faq) _FaqItem(entry: f),
            ],
          ),
        ),
      ),
    );
  }
}

class _FaqEntry {
  final String q;
  final String a;
  const _FaqEntry({required this.q, required this.a});
}

class _FaqItem extends StatelessWidget {
  final _FaqEntry entry;
  const _FaqItem({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.12)),
      ),
      child: ExpansionTile(
        title: Text(entry.q,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface)),
        iconColor: AppColors.primary,
        collapsedIconColor:
            theme.colorScheme.onSurface.withValues(alpha: 0.5),
        childrenPadding:
            const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(entry.a,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.75))),
          ),
        ],
      ),
    );
  }
}
