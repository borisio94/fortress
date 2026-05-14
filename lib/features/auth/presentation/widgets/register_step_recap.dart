part of '../pages/register_page.dart';

// ─── Step 3 — Récap + CTA ──────────────────────────────────────────────────
//
// Inclus comme `part of register_page.dart`. Affiche le résumé de ce que
// l'utilisateur a saisi (compte + boutique) + 3 bullets rassurants + alerte
// offline si la connectivité est tombée. Le CTA « Démarrer mon essai » est
// géré par `_BottomBar` côté page racine.

class _StepRecap extends StatelessWidget {
  final _RegisterPageState state;
  const _StepRecap({required this.state});

  @override
  Widget build(BuildContext context) {
    final sectorLabel = _kSectors
        .firstWhere((s) => s.value == state._sector,
            orElse: () => _kSectors.first)
        .label;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(Icons.rocket_launch_rounded,
                  size: 32, color: AppColors.primary),
            ),
          ),
          Text('Vous y êtes presque !',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text('Voici ce que nous allons créer pour vous :',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 20),
          _RecapRow(
              icon: Icons.person_outline_rounded,
              label: 'Compte',
              value: state._namCtrl.text.trim()),
          _RecapRow(
              icon: Icons.mail_outline_rounded,
              label: 'Email',
              value: state._mailCtrl.text.trim()),
          _RecapRow(
              icon: Icons.storefront_rounded,
              label: 'Boutique',
              value:
                  '${state._shopNameCtrl.text.trim()} ($sectorLabel)'),
          if (state._shopAddressCtrl.text.trim().isNotEmpty)
            _RecapRow(
                icon: Icons.location_on_outlined,
                label: 'Adresse',
                value: state._shopAddressCtrl.text.trim()),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.2))),
            child: Column(children: const [
              _RecapBullet(text: '14 jours d\'essai gratuit'),
              _RecapBullet(text: 'Aucune carte bancaire demandée'),
              _RecapBullet(text: 'Annulez à tout moment'),
            ]),
          ),
          if (!state._isOnline) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFBBF24)),
              ),
              child: Row(children: [
                const Icon(Icons.wifi_off_rounded,
                    size: 14, color: Color(0xFFF59E0B)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(context.l10n.onlineRequiredForRegister,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF92400E)))),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecapRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  const _RecapRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      );
}

class _RecapBullet extends StatelessWidget {
  final String text;
  const _RecapBullet({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(Icons.check_circle_rounded,
              size: 14, color: AppColors.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
        ]),
      );
}

class _ErrText extends StatelessWidget {
  final String message;
  const _ErrText(this.message);
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 4, left: 2),
          child: Text(message,
              style: const TextStyle(
                  fontSize: 10, color: Color(0xFFEF4444))),
        ),
      );
}
