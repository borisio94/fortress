import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import 'location_contents_page.dart';
import 'partner_ledger_detail_page.dart';

/// Hub partenaire unifié — point d'accès UNIQUE à tout ce qui concerne un
/// partenaire de livraison (StockLocation type=partner). Regroupe sous le
/// même nom, en onglets :
///   • « Solde » → livre de comptes ([PartnerLedgerView]) : qui doit qui,
///     versements, charges, historique des mouvements.
///   • « Stock déposé » → contenu de l'emplacement ([LocationContentsView]) :
///     unités physiquement détenues par le partenaire + transfert.
///
/// Avant : le stock vivait dans Inventaire › Emplacements et le solde dans
/// une page séparée — le même partenaire était éclaté en deux endroits.
/// Le hub réconcilie les deux facettes. `partnerLocationId` = id de la
/// StockLocation (le ledger et le stock partagent ce même id).
class PartnerHubDetailPage extends StatelessWidget {
  final String shopId;
  final String partnerLocationId;
  /// 0 = onglet Solde (défaut) · 1 = onglet Stock déposé.
  final int initialTab;
  const PartnerHubDetailPage({
    super.key,
    required this.shopId,
    required this.partnerLocationId,
    this.initialTab = 0,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab.clamp(0, 1),
      child: Scaffold(
        appBar: AppBar(
          title: Text(partnerNameOf(partnerLocationId),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          bottom: TabBar(
            indicatorColor: AppColors.primary,
            labelColor: AppColors.primary,
            labelStyle: AppTextStyles.bodyBold,
            unselectedLabelStyle: AppTextStyles.body,
            tabs: const [
              Tab(
                icon: Icon(Icons.account_balance_wallet_outlined, size: 18),
                text: 'Solde',
              ),
              Tab(
                icon: Icon(Icons.inventory_2_outlined, size: 18),
                text: 'Stock déposé',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            PartnerLedgerView(
                shopId: shopId, partnerLocationId: partnerLocationId),
            LocationContentsView(
                shopId: shopId, locationId: partnerLocationId),
          ],
        ),
      ),
    );
  }
}
