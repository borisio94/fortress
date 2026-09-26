import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/daily_expense_service.dart';
import '../../../../core/services/fixed_charge_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/services/loss_service.dart';
import '../../../../core/services/reconciliation_service.dart';
import '../../../../core/services/restaurant_reporting_service.dart'
    show LossLine;
import '../../../../core/services/round_routing.dart';
import '../../../../core/services/service_incident_service.dart';
import '../../../../core/services/stock_item_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../data/restaurant_dashboard_providers.dart'
    show restaurantFinanceProvider;
import '../widgets/resto_empty_state.dart' show RestoEmptyState;
import '../../../caisse/domain/entities/sale_item.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../domain/entities/daily_expense.dart';
import '../../domain/entities/fixed_charge.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/loss.dart';
import '../../domain/entities/restaurant_activity.dart';
import '../widgets/resto_period_sheet.dart';
import '../widgets/resto_tab_kit.dart';
import '../widgets/resto_section_header.dart';
import '../widgets/expense_kind_visuals.dart';
import '../widgets/resto_underline_tabs.dart';

part 'finances_hub_page.activities.dart';
part 'finances_hub_page.charges.dart';
part 'finances_hub_page.expenses.dart';
part 'finances_hub_page.losses.dart';

/// HUB FINANCES DU RESTAURANT — ce que l'établissement dépense et perd.
///
/// Quatre onglets : Activités · Dépenses · Charges · Pertes.
///
/// IL EN PORTAIT SIX, et trois n'étaient pas financiers. Ingrédients et
/// Fournitures sont partis le 21/09/2026 vers l'écran Stock, qui a sa propre
/// entrée de menu : compter sa réserve et lire ses marges ne demandent ni les
/// mêmes gestes ni les mêmes droits.
///
/// ACTIVITÉS RESTE ICI. C'est de la configuration — les secteurs qui ventilent
/// le chiffre d'affaires, cuisine et bar — mais son seul usage est cette
/// ventilation, et il n'existe aucun écran de paramètres restaurant où la
/// loger. En créer un pour une page consultée deux fois dans la vie d'un
/// établissement coûterait plus que l'approximation.
///
/// L'ONGLET PAR DÉFAUT EST DÉPENSES. C'était Ingrédients : un écran de réserve
/// accueillait quiconque cliquait sur « Finances ».
///
/// Restaurant-only (route `sectorIn` restaurant + admin).
class FinancesHubPage extends StatelessWidget {
  final String shopId;
  const FinancesHubPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: shopId,
      title: 'Finances',
      isRootPage: false,
      actions: [
        IconButton(
          tooltip: 'Personnel',
          icon: const Icon(Icons.badge_outlined),
          onPressed: () => context.push('/shop/$shopId/restaurant/personnel'),
        ),
        IconButton(
          tooltip: 'Clôture de caisse',
          icon: const Icon(Icons.point_of_sale_outlined),
          onPressed: () =>
              context.push('/shop/$shopId/restaurant/caisse/cloture'),
        ),
        // L'inventaire compare le stock théorique au stock compté : il a
        // suivi le stock, dont il est le prolongement.
        IconButton(
          tooltip: 'Stock',
          icon: const Icon(Icons.inventory_2_outlined),
          onPressed: () => context.push('/shop/$shopId/restaurant/stock'),
        ),
      ],
      body: DefaultTabController(
        // La longueur DOIT valoir le nombre d'onglets rendus. Elle annonçait
        // sept pour six depuis `45e517a` (28/07/2026) : en debug, Flutter lève
        // une assertion sur ce désaccord ; en release, elle est retirée et le
        // désaccord passe inaperçu. Les builds web de production étant des
        // release, personne ne l'avait vu.
        length: 4,
        child: Column(
          children: [
            // LE TITRE DE LA PAGE, DANS LE CORPS (lot Shell, 25/09/2026) : une page
            // racine du restaurant porte son nom ici, la barre du haut se tait. Il
            // manquait : sur ordinateur, l'écran n'affichait aucun nom.
            // Titre SEUL : la période ne cadre pas toute la page, elle vit dans
            // l'onglet Pertes.
            const RestoSectionHeader(title: 'Finances'),
            // ONGLETS SOULIGNÉS, comme Stock, Menu et Commandes (25/09/2026) :
            // plus de bande teintée ni de `TabBar` dont libellé et trait
            // étaient en primaire. Le balayage entre onglets reste.
            const RestoUnderlineTabBar(
                labels: ['Dépenses', 'Charges', 'Pertes', 'Activités']),
            Expanded(
              child: TabBarView(
                children: [
                  _DailyExpensesTab(shopId: shopId),
                  _ChargesTab(shopId: shopId),
                  _LossesTab(shopId: shopId),
                  _ActivitiesTab(shopId: shopId),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Helpers partagés
// ═══════════════════════════════════════════════════════════════════════

/// Libellés des fréquences de charge (clé = valeur stockée / CHECK SQL).
const Map<String, String> _kFrequencyLabels = {
  'monthly': 'Mensuel',
  'quarterly': 'Trimestriel',
  'yearly': 'Annuel',
  'once': 'Unique',
};

/// Libellés des catégories de charge fixe (clé = valeur stockée / CHECK SQL).
const Map<String, String> _kChargeCategoryLabels = {
  'loyer': 'Loyer',
  'electricite': 'Électricité',
  'internet': 'Internet',
  'impots': 'Impôts',
  'salaires': 'Salaires',
  'autre': 'Autre',
};

/// Libellés des catégories de perte (clé = valeur stockée / CHECK SQL).
///
/// `ecart_inventaire` est produit UNIQUEMENT par la réconciliation
/// (hotfix_141) : il figure ici pour l'affichage, mais l'éditeur de perte ne
/// le propose pas à la saisie manuelle — un écart d'inventaire se constate en
/// comptant, il ne se déclare pas à la main.
const Map<String, String> _kLossCategoryLabels = {
  'casse': 'Casse',
  'reste_invendu': 'Invendu',
  'plat_mal_fait': 'Plat raté',
  'non_paye': 'Non payé',
  'materiel_endommage': 'Matériel',
  'ecart_inventaire': 'Écart d\'inventaire',
  'autre': 'Autre',
};

