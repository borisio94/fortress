import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../../../../core/widgets/owner_pin_dialog.dart';
import '../../../../core/services/danger_action_service.dart';
import '../../data/providers/employees_provider.dart';
import '../../data/services/admin_actions_service.dart';
import '../../domain/models/employee.dart';
import '../../domain/models/employee_permission.dart';
import '../../domain/models/member_role.dart';
import 'employee_form_sheet.dart';
import '../widgets/owner_approval_banner.dart';

// ═════════════════════════════════════════════════════════════════════════════
// EmployeesPage — Ressources humaines.
//
// Garde rôle : seul un admin/owner/super_admin du shop courant peut accéder.
// La page liste les memberships (RPC list_shop_employees), avec filtres par
// statut, recherche par nom/email, et bouton "+ Nouvel employé".
//
// Toutes les couleurs via Theme.of(context).colorScheme + theme.semantic.
// ═════════════════════════════════════════════════════════════════════════════

class EmployeesPage extends ConsumerStatefulWidget {
  final String shopId;

  /// `true` (défaut) : la page se rend en plein écran avec son propre
  /// [AppScaffold] et AppBar — utilisé pour la route /shop/:id/employees.
  ///
  /// `false` : la page se rend comme un panneau autonome (Column), à
  /// embarquer dans un onglet (typiquement l'onglet "Membres" de la page
  /// Paramètres boutique). Le bouton "Ajouter un employé" est alors
  /// déplacé en haut du panneau.
  final bool embedInScaffold;

  const EmployeesPage({
    super.key,
    required this.shopId,
    this.embedInScaffold = true,
  });
  @override
  ConsumerState<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends ConsumerState<EmployeesPage> {
  String _filter = 'all'; // all | active | suspended | archived
  String _query  = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final perms = ref.watch(permissionsProvider(widget.shopId));

    // Garde : la route doit être réservée aux admins/owners/super_admins.
    if (!perms.canManageMembers && !perms.isSuperAdmin) {
      final deniedBody = Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Column(mainAxisSize: MainAxisSize.min,
            children: [
          Icon(Icons.lock_rounded, size: 48, color: sem.danger),
          const SizedBox(height: 12),
          Text(l.hrAccessDenied,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14,
                  fontWeight: FontWeight.w700, color: cs.onSurface)),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: () => context.canPop()
                ? context.pop() : context.go(RouteNames.shopSelector),
            style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary, elevation: 0),
            child: Text(l.commonCancel),
          ),
        ])),
      );
      return deniedBody;
    }

    final asyncList = ref.watch(employeesProvider(widget.shopId));

    final myRole          = perms.effectiveRole;
    final currentUserId   = _currentUserId();

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ─── Topbar : titre + bouton "Nouveau membre" ──────────────────
        _MembersTopbar(
          title:        l.hrMembersTitle,
          buttonLabel:  l.hrNewMember,
          onCreate:     _openCreateSheet,
        ),

        // ─── Banner d'approbation owner (gardé) ────────────────────────
        OwnerApprovalBanner(
            shopId: widget.shopId, isOwner: perms.isOwner),

        // ─── Liste filtrée + sections ──────────────────────────────────
        Expanded(child: asyncList.when(
          loading: () => Center(child: CircularProgressIndicator(
              color: cs.primary)),
          error:   (e, _) => _ErrorView(message: e.toString()),
          data: (list) {
            final filtered = _applyFilters(list);
            return RefreshIndicator(
              color: cs.primary,
              onRefresh: () => ref
                  .read(employeesProvider(widget.shopId).notifier)
                  .refresh(),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Stats cards (calculées sur la liste TOTALE, pas filtrée).
                    _MembersStats(all: list),
                    const SizedBox(height: 14),
                    // Mobile : barre recherche + bouton filtre popup à
                    // droite (gain de hauteur). Desktop : pills filtre
                    // au-dessus + barre recherche en dessous (inchangé).
                    if (MediaQuery.of(context).size.width < 600) ...[
                      Row(children: [
                        Expanded(child: _MembersSearchBar(
                          hint: l.hrSearchPlaceholder,
                          onChange: (v) => setState(() => _query = v),
                        )),
                        const SizedBox(width: 8),
                        _MembersFilterPopupBtn(
                          current: _filter,
                          onChange: (v) => setState(() => _filter = v),
                        ),
                      ]),
                    ] else ...[
                      _MembersFilterTabs(
                        current: _filter,
                        onChange: (v) => setState(() => _filter = v),
                      ),
                      const SizedBox(height: 12),
                      _MembersSearchBar(
                        hint: l.hrSearchPlaceholder,
                        onChange: (v) => setState(() => _query = v),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (filtered.isEmpty)
                      _EmptyView(
                        hasNoEmployees: list.isEmpty,
                        onCreate: _openCreateSheet,
                      )
                    else
                      _MembersSections(
                        all:           list,
                        filtered:      filtered,
                        myRole:        myRole,
                        currentUserId: currentUserId,
                        onEdit:        _openEditSheet,
                        onAction:      _handleAction,
                      ),
                  ],
                ),
              ),
            );
          },
        )),
      ],
    );

    return body;
  }

  List<Employee> _applyFilters(List<Employee> list) {
    Iterable<Employee> rows = list;
    switch (_filter) {
      case 'active':    rows = rows.where((e) => e.isActive);
      case 'suspended': rows = rows.where((e) => e.isSuspended);
      case 'archived':  rows = rows.where((e) => e.isArchived);
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      rows = rows.where((e) =>
          e.fullName.toLowerCase().contains(q) ||
          e.email.toLowerCase().contains(q));
    }
    return rows.toList();
  }

  Future<void> _openCreateSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => EmployeeFormSheet(shopId: widget.shopId),
    );
    if (created == true && mounted) {
      _snack(context.l10n.hrCreated, success: true);
    }
  }

  Future<void> _openEditSheet(Employee e) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => EmployeeFormSheet(
        shopId: widget.shopId, existing: e,
      ),
    );
    if (saved == true && mounted) {
      _snack(context.l10n.hrUpdated, success: true);
    }
  }

  Future<void> _handleAction(Employee e, _RowAction a) async {
    final notifier = ref.read(employeesProvider(widget.shopId).notifier);
    final l = context.l10n;
    final perms = ref.read(permissionsProvider(widget.shopId));
    try {
      switch (a) {
        case _RowAction.suspend:
          if (perms.isOwner) {
            await OwnerPinDialog.guard(
              context: context,
              title: 'Suspendre ${e.fullName}',
              onConfirmed: () async =>
                  notifier.setStatus(e.userId, EmployeeStatus.suspended),
            );
          } else {
            await notifier.setStatus(e.userId, EmployeeStatus.suspended);
          }
        case _RowAction.reactivate:
          await notifier.setStatus(e.userId, EmployeeStatus.active);
        case _RowAction.archive:
          if (perms.isOwner) {
            await OwnerPinDialog.guard(
              context: context,
              title: 'Archiver ${e.fullName}',
              onConfirmed: () async =>
                  notifier.setStatus(e.userId, EmployeeStatus.archived),
            );
          } else {
            await notifier.setStatus(e.userId, EmployeeStatus.archived);
          }
        case _RowAction.delete:
          if (e.role == MemberRole.admin) {
            // Suppression d'admin → workflow strict.
            if (perms.isOwner) {
              await DangerActionService.execute(
                context:      context,
                perms:        perms,
                action:       DangerAction.deleteAdmin,
                shopId:       widget.shopId,
                targetId:     e.userId,
                targetLabel:  e.fullName,
                title:        l.hrConfirmDelete,
                description:  l.hrConfirmDeleteHint,
                consequences: const [
                  'L\'employé perd l\'accès à toutes les boutiques de cette organisation.',
                  'L\'historique de ses actions reste lisible dans les logs.',
                  'Le quota d\'administrateurs est libéré.',
                ],
                confirmText:  e.fullName,
                onConfirmed:  () async {
                  await notifier.delete(e.userId);
                  if (mounted) _snack(l.hrDeleted, success: true);
                },
              );
            } else {
              // Admin non-owner → demander approbation au owner.
              final ok = await DangerConfirmDialog.show(
                context: context,
                title: l.hrConfirmDelete,
                description: l.hrConfirmDeleteHint,
                consequences: const [
                  'Une demande d\'approbation sera envoyée au propriétaire.',
                  'L\'admin reste actif tant que le propriétaire n\'a pas validé.',
                ],
                confirmText: e.fullName,
                onConfirmed: () {},
              ) ?? false;
              if (!ok) return;
              await _requestAdminAction(
                  type: AdminActionType.removeAdmin,
                  targetUserId: e.userId);
            }
          } else {
            // Suppression d'un user (non-admin) — pas de PIN, juste saisie.
            final ok = await DangerConfirmDialog.show(
              context: context,
              title: l.hrConfirmDelete,
              description: l.hrConfirmDeleteHint,
              consequences: const [
                'L\'employé perd l\'accès à toutes les boutiques de cette organisation.',
                'L\'historique de ses actions reste lisible dans les logs.',
              ],
              confirmText: e.fullName,
              onConfirmed: () {},
            ) ?? false;
            if (!ok) return;
            await notifier.delete(e.userId);
            if (mounted) _snack(l.hrDeleted, success: true);
          }
          return;
      }
      if (mounted) _snack(l.hrUpdated, success: true);
    } catch (err) {
      if (mounted) _snack(err.toString().replaceAll('Exception: ', ''),
          success: false);
    }
  }

  /// Id Supabase auth de l'utilisateur courant. Utilisé pour empêcher de
  /// modifier sa propre fiche depuis la page RH.
  String? _currentUserId() =>
      Supabase.instance.client.auth.currentUser?.id;

  /// Initie une demande d'action sensible (remove/demote/delete) qui sera
  /// approuvée par le owner. Affiche un dialog de confirmation puis envoie
  /// la requête via [AdminActionsService].
  Future<void> _requestAdminAction({
    required AdminActionType type,
    String?                  targetUserId,
  }) async {
    final theme = Theme.of(context);
    try {
      final id = await AdminActionsService.request(
        shopId:       widget.shopId,
        type:         type,
        targetUserId: targetUserId,
      );
      if (id.isEmpty || !mounted) return;
      // Dialog "Demande envoyée"
      await showDialog<void>(
        context: context,
        builder: (dc) => AlertDialog(
          title: Row(children: [
            Icon(Icons.send_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            const Text('Demande envoyée'),
          ]),
          content: Text(
            'La demande "${type.labelFr}" a été envoyée au propriétaire. '
            'Vous serez notifié dès qu\'elle est approuvée ou refusée.\n\n'
            'Cette demande expire dans 5 minutes.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dc),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } on AdminActionException catch (e) {
      if (mounted) _snack(e.messageFr, success: false);
    } catch (e) {
      if (mounted) _snack(e.toString(), success: false);
    }
  }

  void _snack(String msg, {required bool success}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? theme.semantic.success : theme.semantic.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }
}

enum _RowAction { suspend, reactivate, archive, delete }


// ═════════════════════════════════════════════════════════════════════════════
// Empty / Error
// ═════════════════════════════════════════════════════════════════════════════
// Délègue au widget partagé EmptyStateWidget (design de référence de l'app).
class _EmptyView extends StatelessWidget {
  final bool         hasNoEmployees;
  final VoidCallback onCreate;
  const _EmptyView({required this.hasNoEmployees, required this.onCreate});
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return EmptyStateWidget(
      icon: Icons.people_outline_rounded,
      title: l.hrEmptyTitle,
      subtitle: l.hrEmptyHint,
      ctaLabel: hasNoEmployees ? l.hrNewEmployee : null,
      ctaIcon: Icons.person_add_alt_1_rounded,
      onCta: hasNoEmployees ? onCreate : null,
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message,
            style: TextStyle(color: sem.danger, fontSize: 13),
            textAlign: TextAlign.center),
      ),
    );
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Calcule le libellé de rôle à afficher dans la carte employé : détecte
/// quel preset de permissions correspond à ses permissions effectives, et
/// retombe sur "Personnalisé" si aucun preset n'est exact. Le owner est
/// traité à part (toujours "Propriétaire").
String _employeeRoleLabel(AppLocalizations l, Employee e) {
  if (e.isOwner) return l.hrBadgeOwner;

  // Permissions effectives = (défauts du rôle) ∪ grants \ denies.
  // Même calcul que dans le form (employee_form_sheet.dart::initState).
  final effective = <EmployeePermission>{
    ...defaultPermissionsForRole(e.role),
    ...e.permissions,
  }..removeAll(e.denies);

  bool eq(Set<EmployeePermission> p) =>
      p.length == effective.length && p.every(effective.contains);

  // Ordre du plus spécifique au plus générique.
  if (eq(EmployeePermissionPresets.admin))        return l.hrPresetAdmin;
  if (eq(EmployeePermissionPresets.accountant))   return l.hrPresetAccountant;
  if (eq(EmployeePermissionPresets.stockManager)) return l.hrPresetStock;
  if (eq(EmployeePermissionPresets.cashier))      return l.hrPresetCashier;
  if (eq(EmployeePermissionPresets.employee))     return l.hrPresetEmployee;

  // Pas de preset exact → "Personnalisé" (l'employé a un set custom).
  return l.hrRoleCustom;
}

/// Limite max d'admins par boutique (propriétaire inclus).
/// Aligné sur le trigger SQL `trg_enforce_max_admins` (hotfix_024/037)
/// et la garde client dans `employee_form_sheet.dart:122`.
const int _kMaxAdmins = 3;

String _initialsOf(String s) {
  final parts = s.split(RegExp(r'[\s.@_-]+'))
      .where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    return parts.first
        .substring(0, parts.first.length.clamp(1, 2))
        .toUpperCase();
  }
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

// ═════════════════════════════════════════════════════════════════════════════
// Topbar : titre + bouton "Nouveau membre"
// ═════════════════════════════════════════════════════════════════════════════
class _MembersTopbar extends StatelessWidget {
  final String       title;
  final String       buttonLabel;
  final VoidCallback onCreate;
  const _MembersTopbar({
    required this.title,
    required this.buttonLabel,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    // Sur mobile, le bouton « + » est rendu par la topbar shell
    // (cf. ShopShell._topbarActionsFor pour /parametres/users) — on
    // évite le doublon en masquant le bouton inline. Sur desktop, le
    // bouton inline reste visible (la topbar shell desktop ne montre
    // pas de + dédié pour cette page).
    final isMobile = MediaQuery.of(context).size.width < 600;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(children: [
        Expanded(
          child: Text(title,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isMobile ? 15 : 18,
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              )),
        ),
        if (!isMobile)
          ElevatedButton.icon(
            onPressed: onCreate,
            icon: Icon(Icons.add_rounded, size: 16, color: cs.onPrimary),
            label: Text(buttonLabel,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.onPrimary)),
            style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 15),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Stats cards : Total · Actifs · Admins X/3
// ═════════════════════════════════════════════════════════════════════════════
class _MembersStats extends StatelessWidget {
  final List<Employee> all;
  const _MembersStats({required this.all});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;

    final total   = all.length;
    final active  = all.where((e) => e.isActive).length;
    final admins  = all.where(
        (e) => e.role == MemberRole.admin || e.isOwner).length;

    return Row(children: [
      Expanded(child: _StatCard(
        label: l.hrStatTotal,
        value: '$total',
        color: cs.primary,
      )),
      const SizedBox(width: 10),
      Expanded(child: _StatCard(
        label: l.hrStatActive,
        value: '$active',
        color: sem.success,
      )),
      const SizedBox(width: 10),
      Expanded(child: _StatCard(
        label: l.hrStatAdmins,
        value: l.hrAdminQuota(admins, _kMaxAdmins),
        color: cs.primary,
      )),
    ]);
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color  color;
  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontWeight: FontWeight.w600),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Filter tabs : Tous · Actifs · Suspendus · Archivés
// Onglet actif = fond inverseSurface (≈ noir en mode light) · texte blanc
// ═════════════════════════════════════════════════════════════════════════════
class _MembersFilterTabs extends StatelessWidget {
  final String              current;
  final ValueChanged<String> onChange;
  const _MembersFilterTabs({
    required this.current,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final l     = context.l10n;
    final items = <(String, String)>[
      ('all',       l.hrFilterAll),
      ('active',    l.hrFilterActive),
      ('suspended', l.hrFilterSuspended),
      ('archived',  l.hrFilterArchived),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: sem.trackMuted,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        for (final it in items)
          Expanded(child: _TabPill(
            label:  it.$2,
            active: current == it.$1,
            onTap:  () => onChange(it.$1),
          )),
      ]),
    );
  }
}

class _TabPill extends StatelessWidget {
  final String       label;
  final bool         active;
  final VoidCallback onTap;
  const _TabPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    return Material(
      color: active ? cs.inverseSurface : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: Text(label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: active
                      ? cs.onInverseSurface
                      : cs.onSurface.withValues(alpha: 0.65),
                ),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Filter popup button (mobile uniquement) — bouton compact 40×40 à droite
// de la barre de recherche, ouvre un PopupMenu avec les 4 filtres.
// Indicateur visuel : pastille primary si filtre actif ≠ 'all'.
// ═════════════════════════════════════════════════════════════════════════════
class _MembersFilterPopupBtn extends StatelessWidget {
  final String              current;
  final ValueChanged<String> onChange;
  const _MembersFilterPopupBtn({
    required this.current,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final items = <(String, String)>[
      ('all',       l.hrFilterAll),
      ('active',    l.hrFilterActive),
      ('suspended', l.hrFilterSuspended),
      ('archived',  l.hrFilterArchived),
    ];
    final isActive = current != 'all';
    return SizedBox(
      width: 32, height: 32,
      child: PopupMenuButton<String>(
        tooltip: l.hrFilterAll,
        position: PopupMenuPosition.under,
        offset: const Offset(0, 4),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
        color: cs.surface,
        elevation: 6,
        padding: EdgeInsets.zero,
        onSelected: onChange,
        itemBuilder: (_) => items.map((it) => PopupMenuItem<String>(
          value: it.$1,
          height: 38,
          child: Row(children: [
            Icon(
              current == it.$1
                  ? Icons.check_rounded
                  : Icons.circle_outlined,
              size: 14,
              color: current == it.$1
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(it.$2,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: current == it.$1
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: current == it.$1
                        ? cs.primary
                        : cs.onSurface))),
          ]),
        )).toList(),
        child: Container(
          decoration: BoxDecoration(
            color: isActive ? cs.primary.withValues(alpha: 0.10) : sem.elevatedSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: isActive
                    ? cs.primary.withValues(alpha: 0.4)
                    : sem.borderSubtle),
          ),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.tune_rounded, size: 15,
                  color: isActive ? cs.primary
                                  : cs.onSurface.withValues(alpha: 0.7)),
              if (isActive)
                Positioned(
                  right: 4, top: 4,
                  child: Container(
                    width: 6, height: 6,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.surface, width: 1),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Search bar
// ═════════════════════════════════════════════════════════════════════════════
class _MembersSearchBar extends StatelessWidget {
  final String              hint;
  final ValueChanged<String> onChange;
  const _MembersSearchBar({required this.hint, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return TextField(
      onChanged: onChange,
      style: TextStyle(fontSize: 13, color: cs.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontSize: 13, color: cs.onSurface.withValues(alpha: 0.45)),
        prefixIcon: Icon(Icons.search_rounded,
            size: 18, color: cs.onSurface.withValues(alpha: 0.5)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 12),
        filled: true,
        fillColor: sem.elevatedSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: sem.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: sem.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: cs.primary, width: 1.4),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Sections : Propriétaire · Admins · Personnel
// ═════════════════════════════════════════════════════════════════════════════
class _MembersSections extends StatelessWidget {
  final List<Employee>            all;       // pour compteurs / quota
  final List<Employee>            filtered;  // déjà filtrée (filtre + recherche)
  final MemberRole?               myRole;
  final String?                   currentUserId;
  final void Function(Employee)   onEdit;
  final Future<void> Function(Employee, _RowAction) onAction;

  const _MembersSections({
    required this.all,
    required this.filtered,
    required this.myRole,
    required this.currentUserId,
    required this.onEdit,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final owners = filtered.where((e) => e.isOwner).toList();
    final admins = filtered.where(
        (e) => !e.isOwner && e.role == MemberRole.admin).toList();
    final staff  = filtered.where((e) => e.role == MemberRole.user).toList();

    final adminTotal = all.where(
        (e) => e.role == MemberRole.admin || e.isOwner).length;
    final slotsLeft  = (_kMaxAdmins - adminTotal).clamp(0, _kMaxAdmins);
    final staffTotal = all.where((e) => e.role == MemberRole.user).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (owners.isNotEmpty) ...[
          _SectionCard(
            title: l.hrSectionOwner,
            trailing: null,
            accentEdge: true,
            children: owners.map((e) => _MemberRow(
              employee:      e,
              canEdit:       false,
              canDelete:     false,
              onEdit:        () {},
              onAction:      (a) async {},
            )).toList(),
          ),
          const SizedBox(height: 14),
        ],
        if (admins.isNotEmpty || all.any((e) => e.role == MemberRole.admin)) ...[
          _SectionCard(
            title: l.hrSectionAdmins,
            trailing: '${l.hrAdminCount(admins.length)} · '
                '${l.hrSlotsRemaining(slotsLeft)}',
            children: admins.map((e) {
              final canEdit   = _canEdit(e);
              final canDelete = _canDelete(e);
              return _MemberRow(
                employee:  e,
                canEdit:   canEdit,
                canDelete: canDelete,
                onEdit:    () => onEdit(e),
                onAction:  (a) => onAction(e, a),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
        ],
        if (staff.isNotEmpty || staffTotal > 0)
          _SectionCard(
            title: l.hrSectionStaff,
            trailing: l.hrStaffCount(staff.length),
            children: staff.map((e) {
              final canEdit   = _canEdit(e);
              final canDelete = _canDelete(e);
              return _MemberRow(
                employee:  e,
                canEdit:   canEdit,
                canDelete: canDelete,
                onEdit:    () => onEdit(e),
                onAction:  (a) => onAction(e, a),
              );
            }).toList(),
          ),
      ],
    );
  }

  bool _canEdit(Employee target) {
    if (target.userId == currentUserId) return false;
    if (myRole == null) return false;
    return myRole!.canManage(target.role);
  }

  bool _canDelete(Employee target) {
    if (target.isOwner) return false;
    if (target.role == MemberRole.user) {
      return myRole == MemberRole.owner || myRole == MemberRole.admin;
    }
    return myRole == MemberRole.owner;
  }
}

class _SectionCard extends StatelessWidget {
  final String       title;
  final String?      trailing;
  final List<Widget> children;
  /// Liseré gauche couleur primaire (pour la section Propriétaire).
  final bool         accentEdge;
  const _SectionCard({
    required this.title,
    required this.trailing,
    required this.children,
    this.accentEdge = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return Container(
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sem.borderSubtle),
        boxShadow: accentEdge
            ? [BoxShadow(
                color: cs.primary.withValues(alpha: 0.18),
                blurRadius: 0,
                offset: const Offset(-3, 0),
                spreadRadius: -1,
              )]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header grisé
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: sem.trackMuted,
              borderRadius: const BorderRadius.only(
                topLeft:  Radius.circular(13),
                topRight: Radius.circular(13),
              ),
              border: accentEdge
                  ? Border(
                      left: BorderSide(color: cs.primary, width: 3))
                  : null,
            ),
            child: Row(children: [
              Expanded(child: Text(title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface.withValues(alpha: 0.75),
                    letterSpacing: 0.4,
                  ))),
              if ((trailing ?? '').isNotEmpty)
                Text(trailing!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    )),
            ]),
          ),
          // Lignes
          for (var i = 0; i < children.length; i++) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                accentEdge ? 17 : 14,
                i == 0 ? 12 : 8,
                14,
                i == children.length - 1 ? 12 : 8,
              ),
              child: children[i],
            ),
            if (i < children.length - 1)
              Divider(height: 1,
                  thickness: 1,
                  indent:    accentEdge ? 17 : 14,
                  endIndent: 14,
                  color: sem.borderSubtle),
          ],
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// MemberRow : avatar · nom · email · badges · barre permissions · activité ·  ⋮
// ═════════════════════════════════════════════════════════════════════════════
class _MemberRow extends StatelessWidget {
  final Employee                  employee;
  final bool                      canEdit;
  final bool                      canDelete;
  final VoidCallback              onEdit;
  final Future<void> Function(_RowAction) onAction;
  const _MemberRow({
    required this.employee,
    required this.canEdit,
    required this.canDelete,
    required this.onEdit,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;

    final Color  statusColor;
    final String statusLabel;
    switch (employee.status) {
      case EmployeeStatus.active:
        statusColor = sem.success;
        statusLabel = l.hrStatusActive;
      case EmployeeStatus.suspended:
        statusColor = sem.warning;
        statusLabel = l.hrStatusSuspended;
      case EmployeeStatus.archived:
        statusColor = cs.onSurface.withValues(alpha: 0.5);
        statusLabel = l.hrStatusArchived;
    }

    // Couleur d'accent par rôle (avatar + barre permissions).
    final Color accent = employee.isOwner
        ? cs.primary
        : (employee.role == MemberRole.admin
            ? sem.info
            : (employee.isSuspended ? sem.warning : sem.success));

    // Permissions effectives.
    final effectivePerms = <EmployeePermission>{
      ...defaultPermissionsForRole(employee.role),
      ...employee.permissions,
    }..removeAll(employee.denies);
    final permCount = effectivePerms.length;
    final permTotal = EmployeePermission.values.length;
    final permRatio = permTotal == 0 ? 0.0 : permCount / permTotal;

    final activityLabel = employee.createdAt != null
        ? l.hrSinceDate(_fmtDate(employee.createdAt!))
        : l.hrNeverActive;

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Avatar coloré
      Container(
        width: 42, height: 42,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(11),
        ),
        alignment: Alignment.center,
        child: Text(_initialsOf(employee.fullName.isEmpty
                ? employee.email : employee.fullName),
            style: TextStyle(fontSize: 14,
                fontWeight: FontWeight.w800, color: accent)),
      ),
      const SizedBox(width: 12),

      // Bloc principal
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nom + badge rôle
          Row(children: [
            Expanded(child: Text(
                employee.fullName.isEmpty
                    ? employee.email : employee.fullName,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface))),
            const SizedBox(width: 8),
            _RoleBadge(employee: employee, accent: accent),
          ]),
          const SizedBox(height: 2),

          // Email
          Text(employee.email,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.55))),
          const SizedBox(height: 6),

          // Statut + barre permissions + activité
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(statusLabel,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: statusColor)),
            const SizedBox(width: 10),
            Expanded(child: _PermBar(
              ratio:  permRatio,
              count:  permCount,
              total:  permTotal,
              color:  accent,
            )),
          ]),

          const SizedBox(height: 4),
          Text(activityLabel,
              style: TextStyle(fontSize: 10,
                  color: cs.onSurface.withValues(alpha: 0.5))),
        ],
      )),

      // Menu actions (jamais pour owner — règle UI)
      if (!employee.isOwner) const SizedBox(width: 6),
      if (!employee.isOwner) Builder(builder: (_) {
        final hasAny = canEdit || canDelete;
        return PopupMenuButton<_RowAction>(
          enabled: hasAny,
          icon: Icon(Icons.more_vert_rounded,
              size: 18, color: hasAny
                  ? cs.onSurface.withValues(alpha: 0.65)
                  : cs.onSurface.withValues(alpha: 0.25)),
          onSelected: onAction,
          itemBuilder: (_) => [
            if (canEdit)
              PopupMenuItem(
                onTap: onEdit,
                child: Row(children: [
                  Icon(Icons.edit_outlined, size: 16,
                      color: cs.onSurface.withValues(alpha: 0.7)),
                  const SizedBox(width: 8),
                  Text(l.hrActionEdit),
                ]),
              ),
            if (canEdit && employee.isActive)
              PopupMenuItem(
                value: _RowAction.suspend,
                child: Row(children: [
                  Icon(Icons.pause_circle_outline_rounded,
                      size: 16, color: sem.warning),
                  const SizedBox(width: 8),
                  Text(l.hrActionSuspend),
                ]),
              ),
            if (canEdit && employee.isSuspended)
              PopupMenuItem(
                value: _RowAction.reactivate,
                child: Row(children: [
                  Icon(Icons.play_circle_outline_rounded,
                      size: 16, color: sem.success),
                  const SizedBox(width: 8),
                  Text(l.hrActionReactivate),
                ]),
              ),
            if (canEdit && !employee.isArchived)
              PopupMenuItem(
                value: _RowAction.archive,
                child: Row(children: [
                  Icon(Icons.archive_outlined, size: 16,
                      color: cs.onSurface.withValues(alpha: 0.7)),
                  const SizedBox(width: 8),
                  Text(l.hrActionArchive),
                ]),
              ),
            if (canDelete)
              PopupMenuItem(
                value: _RowAction.delete,
                child: Row(children: [
                  Icon(Icons.delete_outline_rounded,
                      size: 16, color: sem.danger),
                  const SizedBox(width: 8),
                  Text(l.hrActionDelete,
                      style: TextStyle(color: sem.danger)),
                ]),
              ),
          ],
        );
      }),
    ]);
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _RoleBadge extends StatelessWidget {
  final Employee employee;
  final Color    accent;
  const _RoleBadge({required this.employee, required this.accent});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final label = _employeeRoleLabel(l, employee);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            color: accent,
          )),
    );
  }
}

class _PermBar extends StatelessWidget {
  final double ratio;
  final int    count;
  final int    total;
  final Color  color;
  const _PermBar({
    required this.ratio,
    required this.count,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final cs    = theme.colorScheme;
    return Row(children: [
      Expanded(child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(children: [
          Container(height: 5, color: sem.trackMuted),
          FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: Container(height: 5, color: color),
          ),
        ]),
      )),
      const SizedBox(width: 6),
      Text('$count/$total',
          style: TextStyle(
              fontSize: 10,
              color: cs.onSurface.withValues(alpha: 0.55),
              fontWeight: FontWeight.w600)),
    ]);
  }
}
