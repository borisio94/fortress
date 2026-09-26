import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/partner_ledger_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';
import '../../../../shared/providers/current_shop_provider.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PartnerDebtsBanner — bandeau visible en haut du dashboard quand au moins
// un partenaire-livreur doit de l'argent à la boutique (vente encaissée par
// le partenaire mais pas encore versée à la boutique, cf. partner_ledger
// `saleCollected`).
//
// Affiche : total dû + top 3 partenaires + CTA "Voir détail" → page Comptes
// partenaires. Self-hide si aucun partenaire n'est positif au ledger.
//
// Compose proprement : ConsumerWidget qui se reconstruit naturellement à
// chaque rebuild du dashboard. Pas de listener Hive direct — le dashboard
// se rebuild via `dashSignalProvider` à chaque event d'order, et le
// partner_ledger est mis à jour de manière synchrone côté Hive avant la
// notif → état frais garanti.
// ═════════════════════════════════════════════════════════════════════════════

class PartnerDebtsBanner extends ConsumerWidget {
  final String shopId;
  const PartnerDebtsBanner({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balances = PartnerLedgerService.balancesForShop(shopId);
    // Ancienneté de la plus vieille vente non reversée, par partenaire.
    final ages = PartnerLedgerService.debtAgeByPartner(shopId);
    // Seuil réglé par le commerçant (en-tête de la page Partenaires).
    final alertDays =
        ref.watch(currentShopProvider)?.partnerDebtAlertDays ?? 30;
    // Garde uniquement les partenaires qui DOIVENT à la boutique (solde > 0).
    final owed = <_PartnerOwed>[];
    balances.forEach((partnerId, balance) {
      if (balance <= 0) return;
      final name = _locationName(partnerId);
      owed.add(_PartnerOwed(
          name: name, amount: balance, days: ages[partnerId]));
    });
    if (owed.isEmpty) return const SizedBox.shrink();
    owed.sort((a, b) => b.amount.compareTo(a.amount));
    final total = owed.fold<double>(0, (s, o) => s + o.amount);
    final top3  = owed.take(3).toList();
    // Compté sur TOUS les partenaires, pas seulement le top 3 : un retard
    // sur une petite somme resterait sinon invisible derrière trois grosses.
    final lateCount = owed.where((o) => (o.days ?? 0) > alertDays).length;

    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          colors: [
            AppColors.warning.withValues(alpha: 0.12),
            AppColors.warning.withValues(alpha: 0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.center,
            child: Icon(Icons.account_balance_wallet_rounded,
                size: 18, color: AppColors.warning),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                        'Vos partenaires vous doivent '
                        '${CurrencyFormatter.format(total)}',
                        style: AppTextStyles.bodyBold
                            .copyWith(color: theme.colorScheme.onSurface)),
                  ),
                  InkWell(
                    onTap: () => context.go(
                        '/shop/$shopId/parametres/partner-accounts'),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('Voir',
                            style: AppTextStyles.bodySmBold
                                .copyWith(color: AppColors.primary)),
                        const SizedBox(width: 2),
                        Icon(Icons.arrow_forward_rounded,
                            size: 14, color: AppColors.primary),
                      ]),
                    ),
                  ),
                ]),
                if (lateCount > 0) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.schedule_rounded,
                        size: 13, color: AppColors.error),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                          lateCount == 1
                              ? 'Un partenaire dépasse $alertDays jours'
                              : '$lateCount partenaires dépassent '
                                  '$alertDays jours',
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.error)),
                    ),
                  ]),
                ],
                const SizedBox(height: 6),
                for (final p in top3)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(children: [
                      Container(
                        width: 4, height: 4,
                        decoration: BoxDecoration(
                            color: AppColors.warning,
                            borderRadius: BorderRadius.circular(2)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.bodySm.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.75))),
                      ),
                      // Âge absent = rien qui vieillisse (tout est couvert,
                      // ou le solde ne tient qu'à une avance consentie).
                      if (p.days != null) ...[
                        Text('${p.days} j',
                            style: AppTextStyles.caption.copyWith(
                                color: p.days! > alertDays
                                    ? AppColors.error
                                    : null)),
                        const SizedBox(width: 8),
                      ],
                      Text(CurrencyFormatter.format(p.amount),
                          style: AppTextStyles.bodySmBold
                              .copyWith(color: theme.colorScheme.onSurface)),
                    ]),
                  ),
                if (owed.length > 3) ...[
                  const SizedBox(height: 4),
                  Text('+ ${owed.length - 3} autre'
                      '${owed.length - 3 > 1 ? 's' : ''} '
                      'partenaire${owed.length - 3 > 1 ? 's' : ''}',
                      style: AppTextStyles.caption.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.55))),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Résout l'ID du partenaire en nom lisible depuis Hive stockLocationsBox.
  /// Fallback "Partenaire #abcdef" si introuvable (location supprimée mais
  /// historique ledger conservé).
  String _locationName(String partnerLocationId) {
    try {
      final raw = HiveBoxes.stockLocationsBox.get(partnerLocationId);
      if (raw == null) {
        return 'Partenaire #${partnerLocationId.substring(
            partnerLocationId.length >= 6
                ? partnerLocationId.length - 6
                : 0)}';
      }
      final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
      return loc.name;
    } catch (_) {
      return 'Partenaire inconnu';
    }
  }
}

class _PartnerOwed {
  final String name;
  final double amount;
  /// Ancienneté en jours de la plus vieille vente non reversée. `null` =
  /// rien qui vieillisse (cf. `PartnerLedgerService.debtAgeByPartner`).
  final int? days;
  const _PartnerOwed({required this.name, required this.amount, this.days});
}
