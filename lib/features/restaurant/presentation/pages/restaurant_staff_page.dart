import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/staff_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../domain/entities/shift_evaluation.dart';
import '../../domain/entities/staff_absence.dart';
import '../../domain/entities/staff_member.dart';
import '../../domain/entities/time_record.dart';
import '../widgets/resto_empty_state.dart';
import '../widgets/staff_editor_sheet.dart';
import '../widgets/staff_payroll_tab.dart';
import '../widgets/resto_surfaces.dart';
import '../widgets/resto_table_listener.dart';
import '../widgets/staff_contest_tab.dart';
import '../widgets/staff_rating_tab.dart';
import '../widgets/staff_settings_sheet.dart';
import '../widgets/resto_section_header.dart';
import '../widgets/resto_underline_tabs.dart';

part 'restaurant_staff_page.team.dart';
part 'restaurant_staff_page.time.dart';

/// Personnel du restaurant (Lot D) : fiches, heures pointées et paie.
///
/// Concerne les serveuses, cuisiniers et plongeurs — PAS les utilisateurs de
/// l'application, qui vivent dans le module RH (`features/hr/`). Ils n'ont pas
/// de compte : c'est le gérant qui tient leurs fiches, et eux badgent avec un
/// code à 4 chiffres.
class RestaurantStaffPage extends StatelessWidget {
  final String shopId;
  const RestaurantStaffPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: shopId,
      title: 'Personnel',
      isRootPage: false,
      actions: [
        IconButton(
          tooltip: 'Badgeuse',
          icon: const Icon(Icons.pin_outlined),
          onPressed: () => context.push('/shop/$shopId/restaurant/pointage'),
        ),
      ],
      body: DefaultTabController(
        length: 5,
        child: Column(
          children: [
            // LE TITRE DE LA PAGE, DANS LE CORPS (lot Shell, 25/09/2026) : une page
            // racine du restaurant porte son nom ici, la barre du haut se tait. Il
            // manquait : sur ordinateur, l'écran n'affichait aucun nom.
            _StaffHeader(shopId: shopId),
            // ONGLETS SOULIGNÉS, comme Stock, Menu et Commandes (25/09/2026).
            // Ils DÉFILENT : cinq onglets ne tiennent pas sur un téléphone.
            const RestoUnderlineTabBar(labels: [
              'Équipe',
              'Pointage',
              'Paie',
              'Notation',
              'Primes',
            ]),
            // Lever l'ambiguïté avec « Accès à l'app », juste au-dessus dans
            // le menu : ici ce sont les gens qui travaillent en salle et en
            // cuisine, pas les comptes qui se connectent.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              // Sur panneau : aucun texte du module ne se pose à nu sur la
              // photo de salle (cf. la règle sur `restoGlassFill`).
              child: RestoGlassPanel(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                radius: 12,
                child: Text(
                    'Serveuses, cuisiniers, plongeurs — ils badgent avec un '
                    'code à 4 chiffres et n\'ont pas de compte Fortress. Les '
                    'comptes de connexion sont dans « Accès à l\'app ».',
                    style: AppTextStyles.captionHint),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _StaffTab(shopId: shopId),
                  _TimeTab(shopId: shopId),
                  StaffPayrollTab(shopId: shopId),
                  StaffRatingTab(shopId: shopId),
                  StaffContestTab(shopId: shopId),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// En-tête de la page : « 4 employés · masse salariale 450 000 F ».
///
/// Le chiffre n'est PAS recalculé autrement : c'est EXACTEMENT celui de
/// l'onglet Équipe (employés actifs, somme des salaires de base), lu à la même
/// source et rafraîchi sur la même table.
class _StaffHeader extends StatefulWidget {
  final String shopId;
  const _StaffHeader({required this.shopId});
  @override
  State<_StaffHeader> createState() => _StaffHeaderState();
}

class _StaffHeaderState extends RestoTableListenerState<_StaffHeader> {
  @override
  List<String> get tables => const ['employees'];
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final active =
        StaffService.forShop(widget.shopId).where((m) => m.isActive).toList();
    final payroll = active.fold<int>(0, (s, m) => s + m.baseSalary);
    final n = active.length;
    final count = n == 0 ? 'aucun employé' : '$n employé${n > 1 ? 's' : ''}';
    return RestoSectionHeader(
      title: 'Personnel',
      subtitle: payroll > 0
          ? '$count · masse salariale '
              '${CurrencyFormatter.format(payroll.toDouble())}'
          : count,
    );
  }
}

/// Base commune : rafraîchit l'onglet quand la table écoutée change.
///
/// Le corps vit désormais dans `RestoTableListenerState` (hotfix_165) : les
/// onglets Notation et Primes, dans leurs propres fichiers, ont exactement le
/// même besoin et ne pouvaient pas hériter d'une classe privée.
abstract class _StaffTabState<T extends StatefulWidget>
    extends RestoTableListenerState<T> {}
