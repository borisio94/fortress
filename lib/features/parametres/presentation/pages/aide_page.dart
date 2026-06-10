import 'package:flutter/material.dart';

import '../../../../core/services/external_launcher.dart';
import '../../../../core/services/tutorial_catalog.dart';
import '../../../../core/services/tutorial_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/tutorial_overlay.dart';

// Numéro WhatsApp support — temporairement le même que la démo landing.
// À remplacer par le numéro Business pro le jour du go-live.
const _kSupportWhatsappE164 = '+237697926045';
const _kSupportEmail = 'posfortress@gmail.com';

/// Page Aide — accessible globalement via le menu « 3 points » de la topbar.
/// FAQ repliable + carte de contact support (WhatsApp / e-mail).
class AidePage extends StatelessWidget {
  final String? shopId;
  const AidePage({super.key, this.shopId});

  void _openWhatsapp() {
    final digits = _kSupportWhatsappE164.replaceAll(RegExp(r'[^0-9]'), '');
    const msg = 'Bonjour, j\'ai besoin d\'aide avec Fortress.';
    openExternal('https://wa.me/$digits?text=${Uri.encodeComponent(msg)}');
  }

  void _openEmail() {
    openExternal('mailto:$_kSupportEmail'
        '?subject=${Uri.encodeComponent("Support Fortress")}');
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: shopId ?? '',
      title: 'Aide',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Questions fréquentes',
              style: AppTextStyles.subtitle
                  .copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'Retrouvez ici les réponses aux questions les plus courantes. '
            'Si vous ne trouvez pas votre réponse, contactez-nous.',
            style: AppTextStyles.bodySm
                .copyWith(color: const Color(0xFF6B7280)),
          ),
          const SizedBox(height: 16),
          ..._faq.map((e) => _FaqTile(question: e.$1, answer: e.$2)),
          const SizedBox(height: 24),
          const _TutorialsSection(),
          const SizedBox(height: 24),
          _SupportCard(
            onWhatsapp: _openWhatsapp,
            onEmail: _openEmail,
          ),
        ],
      ),
    );
  }

  // (question, réponse) — contenu métier POS Fortress.
  static const List<(String, String)> _faq = [
    (
      'L\'application fonctionne-t-elle sans connexion internet ?',
      'Oui. Fortress est conçue « offline-first » : vos ventes, produits '
          'et clients sont enregistrés localement puis synchronisés '
          'automatiquement dès que la connexion revient.',
    ),
    (
      'Comment ajouter un employé à ma boutique ?',
      'Allez dans Paramètres → Boutique → onglet Membres, puis touchez '
          'le bouton « + ». Saisissez l\'e-mail de l\'employé : il recevra '
          'une invitation à rejoindre la boutique avec le rôle choisi.',
    ),
    (
      'Comment partager mon catalogue à un client ?',
      'Depuis l\'Inventaire, utilisez le partage du catalogue : un lien '
          'court est généré et envoyé par WhatsApp. Le client ouvre une '
          'vitrine web toujours à jour, sans installer l\'application.',
    ),
    (
      'Que se passe-t-il si mon abonnement expire ?',
      'L\'application bascule en mode lecture seule : vous gardez l\'accès '
          'à vos données (tableau de bord, listes, exports) mais les '
          'actions d\'écriture sont bloquées jusqu\'au renouvellement.',
    ),
    (
      'Mes données sont-elles sauvegardées ?',
      'Oui. Toutes les données synchronisées sont stockées de façon '
          'sécurisée sur nos serveurs (Supabase), en plus du cache local '
          'de chaque appareil connecté à la boutique.',
    ),
    (
      'Comment changer la langue ou la devise ?',
      'Dans Paramètres, ouvrez « Langue » ou « Devise ». Le changement '
          'est immédiat et conservé pour vos prochaines sessions.',
    ),
  ];
}

class _FaqTile extends StatelessWidget {
  final String question;
  final String answer;
  const _FaqTile({required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding:
              const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedAlignment: Alignment.topLeft,
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          iconColor: AppColors.primary,
          collapsedIconColor: const Color(0xFF9CA3AF),
          title: Text(question,
              style: AppTextStyles.body
                  .copyWith(fontWeight: FontWeight.w700)),
          children: [
            Text(answer,
                style: AppTextStyles.bodySm.copyWith(
                    color: const Color(0xFF4B5563), height: 1.5)),
          ],
        ),
      ),
    );
  }
}

// ─── Tutoriels guidés (PR-1) ──────────────────────────────────────────────────
/// Liste les tutoriels du catalogue ([kTutorialCatalog]) avec leur statut
/// vu/non vu, un bouton Lancer/Rejouer (overlay modal) et « Tout réinitialiser ».
class _TutorialsSection extends StatefulWidget {
  const _TutorialsSection();
  @override
  State<_TutorialsSection> createState() => _TutorialsSectionState();
}

class _TutorialsSectionState extends State<_TutorialsSection> {
  Map<String, bool> _seen = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = <String, bool>{};
    for (final t in kTutorialCatalog) {
      m[t.key] = await TutorialService.isSeen(t.key);
    }
    if (mounted) setState(() { _seen = m; _loading = false; });
  }

  Future<void> _launch(TutorialDef t) async {
    await showGuidedTutorial(context, tutorialKey: t.key, steps: t.steps);
    await _load(); // rafraîchit le statut vu/non vu
  }

  Future<void> _resetAll() async {
    await TutorialService.resetAll();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    // Catégories dans l'ordre d'apparition du catalogue.
    final categories = <String>[];
    for (final t in kTutorialCatalog) {
      if (!categories.contains(t.category)) categories.add(t.category);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text('Tutoriels guidés',
                style: AppTextStyles.subtitle
                    .copyWith(fontWeight: FontWeight.w800)),
          ),
          if (!_loading)
            TextButton(
              onPressed: _resetAll,
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary),
              child: const Text('Tout réinitialiser'),
            ),
        ]),
        const SizedBox(height: 4),
        Text(
          'Apprenez chaque fonction pas à pas, directement dans l\'application.',
          style: AppTextStyles.bodySm
              .copyWith(color: const Color(0xFF6B7280)),
        ),
        const SizedBox(height: 16),
        // Sections groupées par catégorie.
        for (final cat in categories) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 2),
            child: Text(cat.toUpperCase(),
                style: AppTextStyles.microBold.copyWith(
                    color: AppColors.textSecondary, letterSpacing: 0.6)),
          ),
          ...kTutorialCatalog.where((t) => t.category == cat).map((t) =>
              _TutorialCard(
                def: t,
                seen: _seen[t.key] ?? false,
                onLaunch: () => _launch(t),
              )),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _TutorialCard extends StatelessWidget {
  final TutorialDef def;
  final bool seen;
  final VoidCallback onLaunch;
  const _TutorialCard(
      {required this.def, required this.seen, required this.onLaunch});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(def.icon, size: 20, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(def.title,
                  style: AppTextStyles.body
                      .copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('${def.stepCount} étapes · ${seen ? "Vu" : "Non vu"}',
                  style: AppTextStyles.caption.copyWith(
                      color: seen
                          ? AppColors.secondary
                          : const Color(0xFF9CA3AF))),
            ],
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: onLaunch,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
            minimumSize: const Size(0, 38),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9)),
          ),
          child: Text(seen ? 'Rejouer' : 'Lancer'),
        ),
      ]),
    );
  }
}

class _SupportCard extends StatelessWidget {
  final VoidCallback onWhatsapp;
  final VoidCallback onEmail;
  const _SupportCard({required this.onWhatsapp, required this.onEmail});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.support_agent_rounded,
                color: AppColors.primary, size: 22),
            const SizedBox(width: 8),
            Text('Besoin d\'aide ?',
                style: AppTextStyles.body
                    .copyWith(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          Text(
            'Notre équipe vous répond directement.',
            style: AppTextStyles.bodySm
                .copyWith(color: const Color(0xFF4B5563)),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: onWhatsapp,
                icon: const Icon(Icons.chat_rounded, size: 16),
                label: const Text('WhatsApp'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onEmail,
                icon: const Icon(Icons.mail_outline_rounded, size: 16),
                label: const Text('E-mail'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
