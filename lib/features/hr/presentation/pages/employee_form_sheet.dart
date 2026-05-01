import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/validators/input_validators.dart';
import '../../../../shared/widgets/auth_fields.dart';
import '../../data/providers/employees_provider.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../domain/models/employee.dart';
import '../../domain/models/employee_permission.dart';
import '../../domain/models/member_role.dart';

// ═════════════════════════════════════════════════════════════════════════════
// EmployeeFormSheet — création + édition.
//
// Mode création : email + password obligatoires, full_name + status +
// permissions. Crée le compte Auth (RPC create_employee).
// Mode édition : full_name + role + status + permissions modifiables.
// L'email n'est pas modifiable depuis l'app (limitation Supabase Auth).
//
// Permissions : 5 groupes pliables (Inventaire / Caisse / Clients /
// Finances / Boutique) avec une case "tout cocher" par groupe + cases
// individuelles. Presets en haut (Caissier, Stock, Comptable, Tout).
// ═════════════════════════════════════════════════════════════════════════════

class EmployeeFormSheet extends ConsumerStatefulWidget {
  final String     shopId;
  final Employee?  existing;
  const EmployeeFormSheet({
    super.key,
    required this.shopId,
    this.existing,
  });

  @override
  ConsumerState<EmployeeFormSheet> createState() => _EmployeeFormSheetState();
}

class _EmployeeFormSheetState extends ConsumerState<EmployeeFormSheet> {
  final _nameCtrl     = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordCConfirmCtrl = TextEditingController();

  MemberRole         _role        = MemberRole.user;
  EmployeeStatus       _status      = EmployeeStatus.active;
  /// État _effectif_ des permissions cochées dans la UI. Le split en
  /// grants/denies est fait à la sauvegarde (`_buildPayload`).
  late Set<EmployeePermission> _selected;
  bool                 _busy        = false;

  bool get _isEdit => widget.existing != null;

  /// Permissions données par défaut au rôle courant (sans grants/denies).
  /// Sert à : (a) cocher visuellement par défaut quand on crée un nouvel
  /// employé, (b) afficher un badge "(par défaut)" dans l'UI, (c) calculer
  /// le diff grants/denies à la sauvegarde.
  Set<EmployeePermission> get _roleDefaults =>
      defaultPermissionsForRole(_role);

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _nameCtrl.text  = e.fullName;
      _emailCtrl.text = e.email;
      _role           = e.role;
      _status         = e.status;
      // Effectif = (rôle de base) ∪ grants \ denies
      _selected = {
        ...defaultPermissionsForRole(e.role),
        ...e.permissions, // grants
      }.difference(e.denies);
    } else {
      // Nouvel employé : preset caissier (cohérent avec rôle user par défaut).
      _selected = {...EmployeePermissionPresets.cashier};
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordCConfirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l = context.l10n;
    if (InputValidators.name(_nameCtrl.text) != null) {
      _snack(l.hrErrFullName, success: false); return;
    }
    if (!_isEdit) {
      if (InputValidators.email(_emailCtrl.text) != null) {
        _snack(l.hrErrEmail, success: false); return;
      }
      if (InputValidators.password(_passwordCtrl.text) != null) {
        _snack(l.hrErrPassword, success: false); return;
      }
      if (_passwordCtrl.text != _passwordCConfirmCtrl.text) {
        _snack(l.hrErrPasswordMatch, success: false); return;
      }
    }

    // ── Calcul du rôle effectif ──────────────────────────────────────
    // - En édition : le rôle vient du segmented `_role` (admin/user).
    // - À la création : le rôle est dérivé du préréglage choisi. Si
    //   l'utilisateur a sélectionné le preset "Admin" (= toutes les
    //   permissions non owner-only), on enregistre role='admin' pour que
    //   la limite des 3 administrateurs s'applique. Sinon role='user'.
    bool setEq(Set<EmployeePermission> a, Set<EmployeePermission> b) =>
        a.length == b.length && a.every(b.contains);
    final MemberRole effectiveRole = _isEdit
        ? _role
        : (setEq(_selected, EmployeePermissionPresets.admin)
            ? MemberRole.admin
            : MemberRole.user);

    // ── Garde "max 3 admins (propriétaire inclus)" — création + édition.
    // Miroir client du trigger SQL trg_enforce_max_admins (hotfix_024).
    if (effectiveRole == MemberRole.admin) {
      final list = ref.read(employeesProvider(widget.shopId)).valueOrNull
          ?? const <Employee>[];
      final wasAdmin = _isEdit && widget.existing!.role == MemberRole.admin;
      if (!wasAdmin) {
        final selfId = _isEdit ? widget.existing!.userId : null;
        final adminCount = list.where((e) =>
            e.userId != selfId &&
            (e.isOwner || e.role == MemberRole.admin) &&
            e.status == EmployeeStatus.active).length;
        if (adminCount >= 3) {
          _snack('Limite atteinte : maximum 3 administrateurs par '
              'boutique (propriétaire inclus). Rétrograde un admin '
              'existant avant d\'en désigner un autre.',
              success: false);
          return;
        }
      }
    }

    // ── Garde "un seul admin avec shop.full_edit (admin principal)" ──
    // Miroir client du trigger SQL trg_unique_full_edit_admin (migration 014).
    if (_selected.contains(EmployeePermission.shopFullEdit)) {
      final list = ref.read(employeesProvider(widget.shopId)).valueOrNull
          ?? const <Employee>[];
      final selfId = _isEdit ? widget.existing!.userId : null;
      final conflict = list.any((e) {
        if (e.userId == selfId) return false;       // pas soi-même
        if (e.isOwner)          return false;       // owner toujours autorisé
        return e.permissions.contains(EmployeePermission.shopFullEdit);
      });
      if (conflict) {
        _snack(l.hrFullEditAlreadyAssigned, success: false);
        return;
      }
    }

    setState(() => _busy = true);
    final notifier = ref.read(employeesProvider(widget.shopId).notifier);
    try {
      // Conversion effectif → grants + denies par rapport au rôle de base.
      // Économise du stockage : on n'enregistre dans le JSONB QUE les
      // overrides explicites par rapport au défaut du rôle effectif.
      final defaults = defaultPermissionsForRole(effectiveRole);
      final grants   = _selected.difference(defaults); // ajouts
      final denies   = defaults.difference(_selected); // retraits

      if (_isEdit) {
        await notifier.updatePermissions(
            widget.existing!.userId, grants, denies: denies);
        await notifier.updateProfile(widget.existing!.userId,
            fullName: _nameCtrl.text.trim(), role: effectiveRole);
        if (_status != widget.existing!.status) {
          await notifier.setStatus(widget.existing!.userId, _status);
        }
      } else {
        await notifier.create(
          email:       _emailCtrl.text.trim(),
          password:    _passwordCtrl.text,
          fullName:    _nameCtrl.text.trim(),
          role:        effectiveRole,
          permissions: grants,
          denies:      denies,
          status:      _status,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(e.toString().replaceAll('Exception: ', ''), success: false);
      }
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

  void _applyPreset(Set<EmployeePermission> preset) {
    setState(() => _selected = {...preset});
  }

  void _toggleGroup(EmployeePermissionGroup group, bool checkAll,
      {required bool includeOwnerOnly}) {
    setState(() {
      // Filtre identique à celui du widget _PermissionGroup : on cache
      // les owner-only sauf si on est dans le contexte owner.
      final perms = EmployeePermission.values
          .where((p) => p.group == group
              && (includeOwnerOnly || !p.isOwnerOnly));
      if (checkAll) {
        _selected.addAll(perms);
      } else {
        _selected.removeAll(perms);
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    // Affiche les permissions sensibles (shopCreate, shopFullEdit, etc.)
    // uniquement si l'utilisateur courant est propriétaire — lui seul peut
    // les déléguer à un admin.
    final isOwnerCtx =
        ref.watch(permissionsProvider(widget.shopId)).isOwner;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + viewInsets),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 36, height: 4,
                decoration: BoxDecoration(
                    color: sem.borderSubtle,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Text(_isEdit ? l.hrEditEmployee : l.hrNewEmployee,
                style: TextStyle(fontSize: 16,
                    fontWeight: FontWeight.w800, color: cs.onSurface)),
            const SizedBox(height: 16),

            // ── Nom ─────────────────────────────────────────────
            NameField(
              controller: _nameCtrl,
              hint: l.hrFieldFullName,
              label: l.hrFieldFullName,
              required: true,
            ),
            const SizedBox(height: 12),

            // ── Email (création seulement, lecture seule en édition) ────
            EmailField(
              controller: _emailCtrl,
              hint: 'exemple@email.com',
              label: l.hrFieldEmail,
              required: !_isEdit,
              enabled: !_isEdit,
            ),
            if (!_isEdit) ...[
              const SizedBox(height: 12),

              // ── Mot de passe (avec indicateur de force) ────────
              PasswordStrengthField(
                controller: _passwordCtrl,
                hint: '••••••',
                label: l.hrFieldPassword,
                required: true,
              ),
              const SizedBox(height: 12),
              ConfirmPasswordField(
                controller: _passwordCConfirmCtrl,
                originalController: _passwordCtrl,
                hint: '••••••',
                label: l.hrFieldPasswordConfirm,
                required: true,
              ),
            ],
            const SizedBox(height: 14),

            // ── Rôle (édition seulement) ────────────────────────
            if (_isEdit) ...[
              _FieldLabel(text: l.hrFieldRole),
              const SizedBox(height: 6),
              _SegmentedRole(
                value: _role,
                onChange: (v) => setState(() => _role = v),
              ),
              const SizedBox(height: 12),
            ],

            // ── Statut ───────────────────────────────────────────
            _FieldLabel(text: l.hrFieldStatus),
            const SizedBox(height: 6),
            _StatusSelector(
              value: _status,
              onChange: (v) => setState(() => _status = v),
            ),
            const SizedBox(height: 14),

            // ── Préréglages ─────────────────────────────────────
            _FieldLabel(text: l.hrPresetTitle),
            const SizedBox(height: 6),
            _PresetSelector(
              selected: _selected,
              onApply: _applyPreset,
            ),
            const SizedBox(height: 14),

            // ── Permissions par groupe ──────────────────────────
            _FieldLabel(text: l.hrFieldPermissions),
            const SizedBox(height: 8),
            for (final g in EmployeePermissionGroup.values) ...[
              _PermissionGroup(
                group:         g,
                selected:      _selected,
                roleDefaults:  _roleDefaults,
                showOwnerOnly: isOwnerCtx,
                onToggleOne: (p, v) => setState(() {
                  if (v) {
                    _selected.add(p);
                  } else {
                    _selected.remove(p);
                  }
                }),
                onToggleGroup: (v) =>
                    _toggleGroup(g, v, includeOwnerOnly: isOwnerCtx),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 12),

            // ── CTA ──────────────────────────────────────────────
            SizedBox(
              width: double.infinity, height: 48,
              child: ElevatedButton(
                onPressed: _busy ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                  disabledBackgroundColor: cs.primary.withOpacity(0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: _busy
                    ? SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.onPrimary))
                    : Text(_isEdit ? l.hrActionSave : l.hrActionCreate,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ─── Permission group widget ────────────────────────────────────────────────

class _PermissionGroup extends StatelessWidget {
  final EmployeePermissionGroup       group;
  final Set<EmployeePermission>       selected;
  /// Permissions données par défaut au rôle courant. Affichage d'un badge
  /// "(par défaut)" pour signaler à l'admin que la permission est cochée
  /// _automatiquement_ par le rôle (le décocher = ajouter un `deny:`).
  final Set<EmployeePermission>       roleDefaults;
  /// Si `true`, affiche aussi les permissions `isOwnerOnly` (shopCreate,
  /// shopFullEdit, shopDelete, adminRemove). Réservé au propriétaire :
  /// seul lui peut déléguer ces permissions sensibles à un admin.
  final bool                           showOwnerOnly;
  final void Function(EmployeePermission, bool) onToggleOne;
  final ValueChanged<bool>             onToggleGroup;
  const _PermissionGroup({
    required this.group,
    required this.selected,
    required this.roleDefaults,
    required this.showOwnerOnly,
    required this.onToggleOne,
    required this.onToggleGroup,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    // Permissions affichées : par défaut on cache les owner-only
    // (shopDelete, adminRemove, shopCreate, shopFullEdit). Le propriétaire
    // peut explicitement les déléguer → on les montre quand
    // `showOwnerOnly == true`.
    final perms = EmployeePermission.values
        .where((p) => p.group == group
            && (showOwnerOnly || !p.isOwnerOnly))
        .toList();
    final allChecked  = perms.isNotEmpty && perms.every(selected.contains);
    final noneChecked = !perms.any(selected.contains);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header : nom du groupe + case "tout cocher"
        InkWell(
          onTap: () => onToggleGroup(!allChecked),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon(
                allChecked
                    ? Icons.check_box_rounded
                    : noneChecked
                        ? Icons.check_box_outline_blank_rounded
                        : Icons.indeterminate_check_box_rounded,
                size: 20,
                color: allChecked || !noneChecked
                    ? cs.primary
                    : cs.onSurface.withOpacity(0.5),
              ),
              const SizedBox(width: 8),
              Text(_groupLabel(l, group),
                  style: TextStyle(fontSize: 13.5,
                      fontWeight: FontWeight.w800, color: cs.onSurface)),
            ]),
          ),
        ),
        // Items
        for (final p in perms) Padding(
          padding: const EdgeInsets.only(left: 24, top: 4, bottom: 4),
          child: InkWell(
            onTap: () => onToggleOne(p, !selected.contains(p)),
            borderRadius: BorderRadius.circular(8),
            child: Row(children: [
              Icon(
                selected.contains(p)
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: selected.contains(p)
                    ? cs.primary
                    : cs.onSurface.withOpacity(0.4),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_permLabel(l, p),
                  style: TextStyle(fontSize: 12.5,
                      color: cs.onSurface.withOpacity(0.85)))),
              // Badge "par défaut" : permission accordée naturellement par
              // le rôle. Décocher = ajouter un `deny:` (override explicite).
              if (roleDefaults.contains(p))
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.onSurface.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('par défaut',
                      style: TextStyle(fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface.withOpacity(0.55))),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  static String _groupLabel(AppLocalizations l, EmployeePermissionGroup g) =>
      switch (g) {
    EmployeePermissionGroup.inventory => l.permGroupInventory,
    EmployeePermissionGroup.caisse    => l.permGroupCaisse,
    EmployeePermissionGroup.crm       => l.permGroupCrm,
    EmployeePermissionGroup.finance   => l.permGroupFinance,
    EmployeePermissionGroup.shop      => l.permGroupShop,
  };

  static String _permLabel(AppLocalizations l, EmployeePermission p) =>
      switch (p) {
    EmployeePermission.inventoryView    => l.permInventoryView,
    EmployeePermission.inventoryWrite   => l.permInventoryWrite,
    EmployeePermission.inventoryDelete  => l.permInventoryDelete,
    EmployeePermission.inventoryStock   => l.permInventoryStock,
    EmployeePermission.caisseAccess     => l.permCaisseAccess,
    EmployeePermission.caisseSell       => l.permCaisseSell,
    EmployeePermission.caisseEditOrders => l.permCaisseEditOrders,
    EmployeePermission.caisseScheduled  => l.permCaisseScheduled,
    EmployeePermission.caisseViewAllOrders => l.permCaisseViewAllOrders,
    EmployeePermission.crmView          => l.permCrmView,
    EmployeePermission.crmWrite         => l.permCrmWrite,
    EmployeePermission.crmDelete        => l.permCrmDelete,
    EmployeePermission.financeView      => l.permFinanceView,
    EmployeePermission.financeExpenses  => l.permFinanceExpenses,
    EmployeePermission.financeExport    => l.permFinanceExport,
    EmployeePermission.shopSettings     => l.permShopSettings,
    EmployeePermission.shopLocations    => l.permShopLocations,
    EmployeePermission.shopActivity     => l.permShopActivity,
    EmployeePermission.salesCancel      => l.permSalesCancel,
    EmployeePermission.salesDiscount    => l.permSalesDiscount,
    EmployeePermission.membersInvite    => l.permMembersInvite,
    EmployeePermission.shopDelete       => l.permShopDelete,
    EmployeePermission.adminRemove      => l.permAdminRemove,
    EmployeePermission.shopCreate       => l.permShopCreate,
    EmployeePermission.shopFullEdit     => l.permShopFullEdit,
  };
}

// ─── Champs et controls réutilisables ────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel({required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(alignment: Alignment.centerLeft, child: Text(text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
            color: cs.onSurface.withOpacity(0.6))));
  }
}

class _SegmentedRole extends StatelessWidget {
  final MemberRole              value;
  final ValueChanged<MemberRole> onChange;
  const _SegmentedRole({required this.value, required this.onChange});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    Widget chip(MemberRole r, String label) {
      final active = value == r;
      return Expanded(child: GestureDetector(
        onTap: () => onChange(r),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? cs.primary : sem.elevatedSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: active ? cs.primary : sem.borderSubtle),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: active
                      ? cs.onPrimary : cs.onSurface.withOpacity(0.7))),
        ),
      ));
    }
    return Row(children: [
      chip(MemberRole.user,  l.hrRoleUser),
      const SizedBox(width: 6),
      chip(MemberRole.admin, l.hrRoleAdmin),
    ]);
  }
}

// ─── Sélecteur de statut — segmented soft avec icônes ──────────────────────
class _StatusSelector extends StatelessWidget {
  final EmployeeStatus              value;
  final ValueChanged<EmployeeStatus> onChange;
  const _StatusSelector({required this.value, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;

    Widget seg(EmployeeStatus s, IconData icon, String label, Color accent) {
      final active = value == s;
      return Expanded(child: GestureDetector(
        onTap: () => onChange(s),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          decoration: BoxDecoration(
            color: active ? accent.withOpacity(0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 14,
                color: active ? accent : cs.onSurface.withOpacity(0.5)),
            const SizedBox(width: 6),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                    color: active ? accent : cs.onSurface.withOpacity(0.65)))),
          ]),
        ),
      ));
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(children: [
        seg(EmployeeStatus.active,    Icons.check_circle_rounded,
            l.hrStatusActive,    sem.success),
        seg(EmployeeStatus.suspended, Icons.pause_circle_rounded,
            l.hrStatusSuspended, sem.warning),
        seg(EmployeeStatus.archived,  Icons.inventory_2_rounded,
            l.hrStatusArchived,  cs.onSurface.withOpacity(0.55)),
      ]),
    );
  }
}

// ─── Sélecteur de préréglage — radios soft dans un Wrap ────────────────────
class _PresetSelector extends StatelessWidget {
  final Set<EmployeePermission>             selected;
  final ValueChanged<Set<EmployeePermission>> onApply;
  const _PresetSelector({required this.selected, required this.onApply});

  /// Compare deux sets de permissions (égalité stricte).
  static bool _eq(Set<EmployeePermission> a, Set<EmployeePermission> b) =>
      a.length == b.length && a.every(b.contains);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final items = <_PresetSpec>[
      // Admin en premier — c'est le rôle "co-propriétaire" et la limite
      // des 3 administrateurs s'applique. Les autres préréglages ne
      // changent que les permissions (rôle reste 'user').
      _PresetSpec(l.hrPresetAdmin,      Icons.admin_panel_settings_rounded,
          EmployeePermissionPresets.admin),
      _PresetSpec(l.hrPresetEmployee,   Icons.badge_outlined,
          EmployeePermissionPresets.employee),
      _PresetSpec(l.hrPresetCashier,    Icons.point_of_sale_rounded,
          EmployeePermissionPresets.cashier),
      _PresetSpec(l.hrPresetStock,      Icons.inventory_rounded,
          EmployeePermissionPresets.stockManager),
      _PresetSpec(l.hrPresetAccountant, Icons.calculate_rounded,
          EmployeePermissionPresets.accountant),
      _PresetSpec(l.hrPresetClear,      Icons.layers_clear_rounded,
          const <EmployeePermission>{}),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final spec in items)
          _PresetRadio(
            spec:     spec,
            selected: _eq(selected, spec.perms),
            onTap:    () => onApply(spec.perms),
          ),
      ],
    );
  }
}

class _PresetSpec {
  final String                  label;
  final IconData                icon;
  final Set<EmployeePermission> perms;
  const _PresetSpec(this.label, this.icon, this.perms);
}

class _PresetRadio extends StatelessWidget {
  final _PresetSpec  spec;
  final bool         selected;
  final VoidCallback onTap;
  const _PresetRadio({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withOpacity(0.10)
              : sem.elevatedSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? cs.primary : sem.borderSubtle,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          // ── Pastille radio ─────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 16, height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? cs.primary : Colors.transparent,
              border: Border.all(
                color: selected ? cs.primary : cs.onSurface.withOpacity(0.35),
                width: 1.5,
              ),
            ),
            child: selected
                ? Center(child: Container(
                    width: 6, height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cs.onPrimary,
                    ),
                  ))
                : null,
          ),
          const SizedBox(width: 8),
          Icon(spec.icon, size: 14,
              color: selected ? cs.primary : cs.onSurface.withOpacity(0.55)),
          const SizedBox(width: 6),
          Text(spec.label,
              style: TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? cs.primary
                      : cs.onSurface.withOpacity(0.85))),
        ]),
      ),
    );
  }
}

