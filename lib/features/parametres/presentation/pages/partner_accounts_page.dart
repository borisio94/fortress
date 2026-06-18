import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/partner_ledger_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import 'partner_hub_detail_page.dart';

/// Résout le nom d'un partenaire (StockLocation) depuis Hive, fallback id.
String _partnerName(String id) {
  try {
    final raw = HiveBoxes.stockLocationsBox.get(id);
    if (raw == null) return 'Partenaire $id';
    return StockLocation.fromMap(Map<String, dynamic>.from(raw)).name;
  } catch (_) {
    return 'Partenaire $id';
  }
}

/// Liste des comptes partenaires avec leur solde courant.
/// Convention :
///   * solde > 0 → le partenaire DOIT cet argent à la boutique
///   * solde < 0 → la boutique DOIT cet argent au partenaire
///   * solde = 0 → comptes à jour (le partenaire n'apparaît pas)
class PartnerAccountsPage extends ConsumerStatefulWidget {
  final String shopId;
  const PartnerAccountsPage({super.key, required this.shopId});
  @override
  ConsumerState<PartnerAccountsPage> createState() =>
      _PartnerAccountsPageState();
}

class _PartnerAccountsPageState extends ConsumerState<PartnerAccountsPage> {
  late void Function(String, String) _listener;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (sid != widget.shopId) return;
      if (table == 'partner_ledger_entries' || table == 'stock_locations') {
        setState(() {});
      }
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final balances = PartnerLedgerService.balancesForShop(widget.shopId);
    // On liste TOUS les partenaires : ceux qui détiennent du stock
    // (StockLocation type=partner actifs) ET ceux qui ont un mouvement
    // financier (même si leur dépôt a été archivé). Ainsi on accède à la
    // fiche d'un partenaire pour son stock même sans dette en cours.
    final partnerIds = <String>{
      ...AppDatabase.getStockLocationsForOwner(userId)
          .where((l) => l.type == StockLocationType.partner && l.isActive)
          .map((l) => l.id),
      ...balances.keys,
    };
    // Tri : dettes les plus grosses en haut (signe absolu décroissant) pour
    // que l'opérateur voie d'abord ce qu'il y a à régler ; à solde égal,
    // tri alphabétique.
    final entries = partnerIds
        .map((id) => MapEntry(id, balances[id] ?? 0.0))
        .toList()
      ..sort((a, b) {
        final byBalance = b.value.abs().compareTo(a.value.abs());
        if (byBalance != 0) return byBalance;
        return _partnerName(a.key)
            .toLowerCase()
            .compareTo(_partnerName(b.key).toLowerCase());
      });

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Partenaires',
      body: entries.isEmpty
          ? _emptyState(context)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _PartnerCard(
                shopId:    widget.shopId,
                partnerId: entries[i].key,
                balance:   entries[i].value,
              ),
            ),
    );
  }

  Widget _emptyState(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_shipping_outlined, size: 56,
                  color: AppColors.textHint),
              const SizedBox(height: 12),
              Text('Aucun compte ouvert',
                  style: AppTextStyles.label),
              const SizedBox(height: 4),
              Text(
                'Les comptes apparaissent automatiquement dès qu\'une '
                'commande génère une dette croisée avec un partenaire '
                '(vente encaissée par lui ou frais de livraison à payer).',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySm.copyWith(color: AppColors.textHint),
              ),
            ],
          ),
        ),
      );
}

class _PartnerCard extends StatelessWidget {
  final String shopId;
  final String partnerId;
  final double balance;
  const _PartnerCard({
    required this.shopId, required this.partnerId, required this.balance,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final partnerName = _partnerName(partnerId);
    final partnerOwesBoutique = balance > 0;
    final boutiqueOwesPartner = balance < 0;
    final color = partnerOwesBoutique
        ? sem.success
        : (boutiqueOwesPartner ? sem.danger : sem.borderSubtle);
    final tag = partnerOwesBoutique
        ? 'Le partenaire vous doit'
        : (boutiqueOwesPartner
            ? 'Vous devez au partenaire'
            : 'À jour');

    return InkWell(
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PartnerHubDetailPage(
            shopId: shopId, partnerLocationId: partnerId),
        ));
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sem.borderSubtle),
        ),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.local_shipping_outlined, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text(partnerName,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label),
            const SizedBox(height: 2),
            Text(tag,
                style: AppTextStyles.captionHint),
          ])),
          const SizedBox(width: 10),
          Text(
            CurrencyFormatter.format(balance.abs()),
            style: AppTextStyles.label.copyWith(color: color),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded,
              size: 18, color: AppColors.textHint),
        ]),
      ),
    );
  }
}
