import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/staff_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_select_menu.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../hr/data/providers/employees_provider.dart';
import '../../../hr/domain/models/employee.dart';
import '../../../hr/domain/models/job_titles.dart';
import '../../../../core/services/cash_closure_service.dart';
import '../../domain/entities/payslip.dart';
import '../../domain/entities/salary_advance.dart';
import '../../domain/entities/shift_evaluation.dart';
import '../../domain/entities/staff_absence.dart';
import '../../domain/entities/staff_member.dart';
import '../../domain/staff_account_link.dart';
import '../../domain/entities/staff_penalty.dart';
import '../../domain/entities/time_record.dart';
import '../widgets/resto_empty_state.dart';
import '../widgets/resto_surfaces.dart';
import '../widgets/resto_table_listener.dart';
import '../widgets/staff_contest_tab.dart';
import '../widgets/staff_rating_tab.dart';
import '../widgets/staff_settings_sheet.dart';
import '../widgets/resto_section_header.dart';
import '../widgets/resto_underline_tabs.dart';

part 'restaurant_staff_page.team.dart';
part 'restaurant_staff_page.time.dart';
part 'restaurant_staff_page.payroll.dart';

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
                  _PayrollTab(shopId: shopId),
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

/// Carte de liste standard, alignée sur le hub Finances.
class _Row extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _Row({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: restoGlassFill(context),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sem.borderSubtle),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Sélecteur de jour au gabarit d'un champ de formulaire.
class _DayField extends StatelessWidget {
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onPick;

  const _DayField(
      {required this.label, required this.value, required this.onPick});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value,
            // Une mise à pied se régularise parfois après coup, et un congé
            // s'accorde pour le mois prochain : la fenêtre couvre les deux.
            firstDate: DateTime.now().subtract(const Duration(days: 90)),
            lastDate: DateTime.now().add(const Duration(days: 365)),
          );
          if (d != null) onPick(d);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: const Icon(Icons.calendar_today_rounded, size: 16),
          ),
          child: Text(
              '${value.day.toString().padLeft(2, '0')}/'
              '${value.month.toString().padLeft(2, '0')}/${value.year}',
              style: AppTextStyles.body),
        ),
      );
}

/// Champ en lecture seule — même gabarit qu'un `TextField`, sans la saisie.
class _ReadOnlyField extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(value, style: AppTextStyles.body),
      );
}

/// Choix de la personne parmi les comptes « Accès à l'app » de la boutique.
///
/// Les comptes DÉJÀ inscrits au personnel sont retirés de la liste : les
/// proposer laisserait créer deux fiches pour la même personne, donc deux
/// codes de badge et deux bulletins de paie.
///
/// Un `Consumer` local plutôt qu'une page entière convertie à Riverpod : seule
/// cette portion dépend du provider, et la remonter obligerait à toucher la
/// page, ses trois onglets et leurs états.
class _AccountPicker extends ConsumerWidget {
  final String shopId;
  final String selected;

  /// Le personnel déjà inscrit, réduit au lien et au nom. Voir
  /// `staff_account_link.dart` pour la règle de rapprochement.
  final List<StaffLink> staffLinks;

  /// `(identifiant, nom, fonction)`. L'IDENTIFIANT est le point de ce lot :
  /// sans lui, la fiche ne saurait pas de quel compte elle vient, et deux
  /// homonymes se confondraient à la prochaine ouverture du formulaire.
  ///
  /// La fonction vient du compte et est recopiée sur la fiche : elle n'est
  /// plus choisie deux fois.
  final void Function(String userId, String name, String jobTitle) onSelect;

  const _AccountPicker({
    required this.shopId,
    required this.selected,
    required this.staffLinks,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(employeesProvider(shopId));
    final all = async.valueOrNull ?? const <Employee>[];
    final names = [
      for (final e in all)
        if (e.fullName.trim().isNotEmpty &&
            !accountHasStaffRecord(
                userId: e.userId,
                fullName: e.fullName,
                staff: staffLinks))
          e.fullName.trim(),
    ]..sort();
    // Retrouver le COMPTE à partir du nom choisi : la liste déroulante ne sait
    // rendre qu'une chaîne. Deux homonymes tous deux éligibles restent
    // indiscernables ICI — le premier de la liste l'emporte. C'est une limite
    // de la liste déroulante, pas du rapprochement : dès que l'un des deux a
    // sa fiche, l'autre reste seul proposé.
    Employee? accountFor(String name) {
      for (final e in all) {
        if (e.fullName.trim() == name) return e;
      }
      return null;
    }

    if (async.isLoading && all.isEmpty) {
      return const _ReadOnlyField(
          label: 'Personne', value: 'Chargement des comptes…');
    }
    if (names.isEmpty) {
      // Dire QUOI faire, et où. Une liste vide sans explication ressemble à
      // une panne alors que c'est un état de départ parfaitement normal.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ReadOnlyField(
              label: 'Personne', value: 'Aucun compte disponible'),
          const SizedBox(height: 6),
          Text(
              all.isEmpty
                  ? 'Créez d\'abord le compte de cette personne dans '
                      '« Accès à l\'app ».'
                  : 'Tous les comptes de la boutique sont déjà inscrits au '
                      'personnel.',
              style: AppTextStyles.captionHint),
        ],
      );
    }
    return AppSelectWidget(
      label: 'Personne',
      required: true,
      items: names,
      value: selected.isEmpty ? null : selected,
      icon: Icons.person_outline_rounded,
      onChanged: (name) {
        final account = accountFor(name);
        if (account == null) return;
        onSelect(account.userId, name, account.jobTitle.trim());
      },
    );
  }
}
