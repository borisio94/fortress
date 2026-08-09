import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/validators/input_validators.dart';
import '../../../../shared/widgets/auth_fields.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../data/providers/employees_provider.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/config/restaurant_mode.dart';
import '../../domain/models/employee.dart';
import '../../domain/models/employee_permission.dart';
import '../../domain/models/member_role.dart';
import '../../../../shared/widgets/app_select_menu.dart';
import '../../../restaurant/domain/entities/staff_member.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';

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
  /// Mode d'ajout (création uniquement) : true = invitation par lien
  /// partageable (l'employé définit son mot de passe), false = création
  /// directe avec mot de passe défini par l'admin.
  bool                 _inviteMode  = true;

  /// MÉTIER de la personne (Serveur, Cuisinier, Livreur…), distinct du rôle
  /// admin/user. Restauration seulement : c'est la fiche Personnel qui en a
  /// besoin, et l'e-commerce n'a pas de notion de poste.
  late String _jobTitle = widget.existing?.jobTitle ?? '';

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
      // Nouvel employé : préréglage de départ le plus RESTREINT du secteur.
      // En restauration c'est « Serveur » — le poste le plus courant, et celui
      // dont les droits sont les plus étroits. Partir du plus large obligerait
      // à penser à retirer, et on ne pense pas à retirer.
      _selected = isRestaurantShop(widget.shopId)
          ? {...EmployeePermissionPresets.waiter}
          : {...EmployeePermissionPresets.cashier};
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

  /// Pose la fonction métier sur un compte fraîchement créé.
  ///
  /// Sans effet si aucune fonction n'a été choisie, ou si le compte est
  /// introuvable — la création du compte, elle, a réussi, et l'échec d'un
  /// libellé ne doit pas la faire paraître ratée.
  /// Fonctions PROPOSÉES dans la liste, de trois sources cumulées :
  ///   * le socle métier livré avec l'app ([StaffMember.suggestedRoles]) ;
  ///   * celles ajoutées à la main sur cet appareil ;
  ///   * celles DÉJÀ portées par les comptes de la boutique.
  ///
  /// La troisième source est ce qui rend la liste partagée sans backend : une
  /// fonction créée sur un poste puis attribuée à quelqu'un revient d'elle-même
  /// sur les autres appareils, puisqu'elle voyage avec le compte.
  List<String> get _jobTitles {
    final out = <String>[...StaffMember.suggestedRoles];
    for (final t in _customJobTitles) {
      if (!out.contains(t)) out.add(t);
    }
    for (final e in (ref.read(employeesProvider(widget.shopId)).valueOrNull
        ?? const <Employee>[])) {
      final t = e.jobTitle.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  static String _titlesKey(String shopId) => 'job_titles_$shopId';

  List<String> get _customJobTitles {
    try {
      final raw = HiveBoxes.settingsBox.get(_titlesKey(widget.shopId));
      return raw is List ? raw.map((e) => e.toString()).toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  /// Ajoute une fonction à la liste proposée.
  ///
  /// Rangée dans les préférences de l'APPAREIL : il n'existe pas de table de
  /// métiers côté serveur, et en créer une pour une liste de suggestions
  /// coûterait plus que ça ne rapporte. La fonction, elle, est bien
  /// synchronisée — c'est le compte qui la porte.
  Future<String?> _addJobTitle(BuildContext ctx) async {
    final ctrl = TextEditingController();
    final value = await showAdaptiveFormSheet<String>(
      context: ctx,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Nouvelle fonction',
        subtitle: 'Elle rejoindra la liste proposée',
        icon: Icons.work_outline_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Fonction',
                    hintText: 'Pâtissier, veilleur, gérant adjoint… *'),
                onSubmitted: (v) => Navigator.of(sheetCtx).pop(v.trim()),
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Ajouter',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(sheetCtx).pop(ctrl.text.trim()),
              ),
            ],
          ),
        ),
      ),
    );
    ctrl.dispose();
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    if (!_jobTitles.contains(v)) {
      try {
        await HiveBoxes.settingsBox
            .put(_titlesKey(widget.shopId), [..._customJobTitles, v]);
      } catch (e) {
        debugPrint('[RH] ajout fonction err: $e');
      }
    }
    if (mounted) setState(() {});
    return v;
  }

  Future<void> _applyJobTitleByEmail(EmployeesNotifier notifier) async {
    if (_jobTitle.trim().isEmpty) return;
    final email = _emailCtrl.text.trim().toLowerCase();
    final list = ref.read(employeesProvider(widget.shopId)).valueOrNull
        ?? const <Employee>[];
    for (final e in list) {
      if (e.email.toLowerCase() == email) {
        await notifier.setJobTitle(e.userId, _jobTitle);
        return;
      }
    }
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
      if (!_inviteMode) {
        if (InputValidators.password(_passwordCtrl.text) != null) {
          _snack(l.hrErrPassword, success: false); return;
        }
        if (_passwordCtrl.text != _passwordCConfirmCtrl.text) {
          _snack(l.hrErrPasswordMatch, success: false); return;
        }
      }
    }

    // ── Garde quota plan : employés / boutique (création + invitation) ──
    if (!_isEdit) {
      final list = ref.read(employeesProvider(widget.shopId)).valueOrNull
          ?? const <Employee>[];
      final empCount = list.where((e) => !e.isOwner).length;
      final plan = ref.read(currentPlanProvider);
      if (!plan.canAddEmployee(empCount)) {
        _snack(
            'Limite d\'employés atteinte (${plan.maxEmployeesPerShop}/boutique) '
            'pour votre plan. Passez à un plan supérieur pour en ajouter.',
            success: false);
        return;
      }
    }

    // ── Rôle effectif ────────────────────────────────────────────────
    // `_role` est maintenu cohérent par `_applyPreset` (preset Admin
    // → role=admin, autres presets → role=user). À la création comme
    // en édition on prend directement `_role` — plus aucune dérivation
    // implicite par equality sur les permissions, donc plus de risque
    // qu'une légère modification individuelle d'une case rétrograde
    // silencieusement un admin.
    final MemberRole effectiveRole = _role;

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
        // Fonction métier : écrite à part, sur la table. La RPC de profil
        // garde sa signature — la changer imposerait un DROP FUNCTION, donc
        // une fenêtre où la gestion des comptes serait cassée pour tous.
        if (_jobTitle != (widget.existing!.jobTitle)) {
          await notifier.setJobTitle(widget.existing!.userId, _jobTitle);
        }
        if (_status != widget.existing!.status) {
          await notifier.setStatus(widget.existing!.userId, _status);
        }
      } else if (_inviteMode) {
        final token = await notifier.invite(
          email:       _emailCtrl.text.trim(),
          fullName:    _nameCtrl.text.trim(),
          role:        effectiveRole,
          permissions: grants,
          denies:      denies,
          status:      _status,
        );
        if (!mounted) return;
        setState(() => _busy = false);
        await _showInviteShareDialog(token);
        if (mounted) Navigator.of(context).pop(true);
        return;
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
        // La RPC ne rend pas l'id du compte créé : on le retrouve dans la
        // liste rafraîchie, par son email — seul identifiant unique connu ici.
        await _applyJobTitleByEmail(notifier);
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

  /// Construit le lien d'invitation (`/accept-invite?token=…`) et propose de
  /// le copier ou de le partager via WhatsApp. `Uri.base.origin` → marche sur
  /// n'importe quel domaine (web).
  Future<void> _showInviteShareDialog(String token) async {
    final link = '${Uri.base.origin}/#/accept-invite?token=$token';
    final waText = Uri.encodeComponent(
        'Bonjour, voici votre lien pour rejoindre la boutique sur Fortress : $link');
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Theme.of(c).colorScheme.surface,
        title: const Text('Lien d\'invitation'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Envoie ce lien à l\'employé. Il ouvrira la page, créera son mot '
            'de passe (ou se connectera) et rejoindra la boutique. '
            'Valable 7 jours.',
            style: AppTextStyles.bodySmSecondary,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: Theme.of(c).colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8)),
            child: SelectableText(link, style: AppTextStyles.caption),
          ),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (c.mounted) {
                ScaffoldMessenger.of(c).showSnackBar(const SnackBar(
                    content: Text('Lien copié'),
                    behavior: SnackBarBehavior.floating));
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copier'),
          ),
          TextButton.icon(
            onPressed: () => launchUrl(
                Uri.parse('https://wa.me/?text=$waText'),
                mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.chat_rounded, size: 18),
            label: const Text('WhatsApp'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('Terminé'),
          ),
        ],
      ),
    );
  }

  /// Applique un preset de permissions ET aligne automatiquement le rôle :
  /// le preset « Admin » force `role = admin`, tous les autres presets
  /// (Employé, Caissier, Stock, Comptable, Tout décocher) ramènent à
  /// `role = user`. Empêche la dérive historique « role = admin mais
  /// permissions = cashier » qui produisait un badge incohérent dans la
  /// liste membres (cf. _employeeRoleLabel qui détectait le preset par
  /// equality sur permissions, ignorant role).
  void _applyPreset(Set<EmployeePermission> preset) {
    setState(() {
      _selected = {...preset};
      _role = _setEq(preset, EmployeePermissionPresets.admin)
          ? MemberRole.admin
          : MemberRole.user;
    });
  }

  static bool _setEq(Set<EmployeePermission> a, Set<EmployeePermission> b) =>
      a.length == b.length && a.every(b.contains);

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
    final l     = context.l10n;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    // Affiche les permissions sensibles (shopCreate, shopFullEdit, etc.)
    // uniquement si l'utilisateur courant est propriétaire — lui seul peut
    // les déléguer à un admin.
    final isOwnerCtx =
        ref.watch(permissionsProvider(widget.shopId)).isOwner;

    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        FormSheetHeader(
          title: _isEdit ? l.hrEditEmployee : l.hrNewEmployee,
          icon: _isEdit ? Icons.edit_outlined : Icons.person_add_outlined,
        ),
        Flexible(child: Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + viewInsets),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [

            // ── Nom ─────────────────────────────────────────────
            NameField(
              controller: _nameCtrl,
              hint: l.hrFieldFullName,
              label: l.hrFieldFullName,
              required: true,
            ),
            const SizedBox(height: 12),

            // ── Méthode d'ajout (création seulement) ────────────
            if (!_isEdit) ...[
              _FieldLabel(text: 'Méthode d\'ajout'),
              const SizedBox(height: 6),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true,
                      label: Text('Lien d\'invitation'),
                      icon: Icon(Icons.link_rounded, size: 16)),
                  ButtonSegment(value: false,
                      label: Text('Mot de passe'),
                      icon: Icon(Icons.password_rounded, size: 16)),
                ],
                selected: {_inviteMode},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _inviteMode = s.first),
              ),
              const SizedBox(height: 6),
              Text(
                _inviteMode
                    ? 'Un lien sera généré : l\'employé définit son mot de '
                      'passe et rejoint la boutique.'
                    : 'Tu définis le mot de passe ; communique-le à l\'employé.',
                style: AppTextStyles.caption,
              ),
              const SizedBox(height: 12),
            ],

            // ── FONCTION MÉTIER (restauration) ───────────────────────
            // Serveur, Cuisinier, Livreur… — distinct du rôle admin/user, qui
            // est un niveau de DROITS. Saisie ICI et une seule fois : la fiche
            // Personnel en hérite au lieu de la redemander.
            if (isRestaurantShop(widget.shopId)) ...[
              const _FieldLabel(text: 'Fonction'),
              const SizedBox(height: 6),
              AppSelectWidget(
                label: '',
                items: _jobTitles,
                value: _jobTitle.isEmpty ? null : _jobTitle,
                icon: Icons.work_outline_rounded,
                addLabel: 'Ajouter une fonction',
                onAdd: _addJobTitle,
                onChanged: (v) => setState(() => _jobTitle = v),
              ),
              const SizedBox(height: 12),
            ],

            // ── Email (création seulement, lecture seule en édition) ────
            EmailField(
              controller: _emailCtrl,
              hint: 'exemple@email.com',
              label: l.hrFieldEmail,
              required: !_isEdit,
              enabled: !_isEdit,
            ),
            if (!_isEdit && !_inviteMode) ...[
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

            // ── Autorisations (menu rétractable pour alléger l'UI) ──
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: cs.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const PageStorageKey('employee_perms'),
                  initiallyExpanded: false,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  leading: const Icon(Icons.shield_outlined, size: 20),
                  title: Text(l.hrFieldPermissions, style: AppTextStyles.bodyBold),
                  subtitle: Text(
                    '${_selected.length} autorisation(s) — appuyez pour configurer',
                    style: AppTextStyles.caption,
                  ),
                  children: [
                    // Préréglages
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _FieldLabel(text: l.hrPresetTitle),
                    ),
                    const SizedBox(height: 6),
                    _PresetSelector(
                      selected: _selected,
                      onApply: _applyPreset,
                      shopId: widget.shopId,
                    ),
                    const SizedBox(height: 14),
                    // Permissions par groupe
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
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── CTA ──────────────────────────────────────────────
            SizedBox(
              width: double.infinity, height: 48,
              child: ElevatedButton(
                onPressed: _busy ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                  disabledBackgroundColor: cs.primary.withValues(alpha:0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: _busy
                    ? SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.onPrimary))
                    : Text(_isEdit
                            ? l.hrActionSave
                            : (_inviteMode ? 'Générer le lien' : l.hrActionCreate),
                        style: AppTextStyles.label.copyWith(
                            fontWeight: FontWeight.w800,
                            color: cs.onPrimary)),
              ),
            ),
          ]),
          ),
        )),
      ]),
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
                    : cs.onSurface.withValues(alpha:0.5),
              ),
              const SizedBox(width: 8),
              Text(_groupLabel(l, group),
                  style: AppTextStyles.body.copyWith(
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
                    : cs.onSurface.withValues(alpha:0.4),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_permLabel(l, p),
                  style: AppTextStyles.bodySm.copyWith(
                      color: cs.onSurface.withValues(alpha:0.85)))),
              // Badge "par défaut" : permission accordée naturellement par
              // le rôle. Décocher = ajouter un `deny:` (override explicite).
              if (roleDefaults.contains(p))
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha:0.06),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('par défaut',
                      style: AppTextStyles.micro.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface.withValues(alpha:0.55))),
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
    // PR exports — pas encore d'entrée ARB dédiée pour rester strict
    // PR-1. Fallback FR direct (le projet est francophone) ; ajouter
    // un permInventoryExport dans app_fr/en.arb dans une PR i18n.
    EmployeePermission.inventoryExport  => 'Exporter le catalogue',
    EmployeePermission.caisseAccess     => l.permCaisseAccess,
    EmployeePermission.caisseSell       => l.permCaisseSell,
    EmployeePermission.caisseEditOrders => l.permCaisseEditOrders,
    EmployeePermission.caisseScheduled  => l.permCaisseScheduled,
    EmployeePermission.caisseViewAllOrders => l.permCaisseViewAllOrders,
    EmployeePermission.caisseExport     => 'Exporter les commandes',
    EmployeePermission.crmView          => l.permCrmView,
    EmployeePermission.crmWrite         => l.permCrmWrite,
    EmployeePermission.crmDelete        => l.permCrmDelete,
    EmployeePermission.crmExport        => 'Exporter le carnet clients',
    EmployeePermission.financeView      => l.permFinanceView,
    EmployeePermission.financeExpenses  => l.permFinanceExpenses,
    EmployeePermission.financeExport    => l.permFinanceExport,
    EmployeePermission.shopSettings     => l.permShopSettings,
    EmployeePermission.shopLocations    => l.permShopLocations,
    EmployeePermission.shopActivity     => l.permShopActivity,
    EmployeePermission.salesCancel      => l.permSalesCancel,
    EmployeePermission.salesDiscount    => l.permSalesDiscount,
    EmployeePermission.deliveryWhatsApp => l.permDeliveryWhatsApp,
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
        style: AppTextStyles.captionBold
            .copyWith(color: cs.onSurface.withValues(alpha:0.6))));
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
              style: AppTextStyles.bodySm.copyWith(
                  fontWeight: FontWeight.w700,
                  color: active
                      ? cs.onPrimary : cs.onSurface.withValues(alpha:0.7))),
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
            color: active ? accent.withValues(alpha:0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 14,
                color: active ? accent : cs.onSurface.withValues(alpha:0.5)),
            const SizedBox(width: 6),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySm.copyWith(
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                    color: active ? accent : cs.onSurface.withValues(alpha:0.65)))),
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
            l.hrStatusArchived,  cs.onSurface.withValues(alpha:0.55)),
      ]),
    );
  }
}

// ─── Sélecteur de préréglage — radios soft dans un Wrap ────────────────────
class _PresetSelector extends StatelessWidget {
  final Set<EmployeePermission>             selected;
  final ValueChanged<Set<EmployeePermission>> onApply;
  final String                              shopId;
  const _PresetSelector({
    required this.selected,
    required this.onApply,
    required this.shopId,
  });

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
      // AUCUN préréglage portant un nom de MÉTIER en restauration.
      //
      // « Serveur », « Caissier », « Cuisinier » étaient des profils de
      // PERMISSIONS, mais leur nom les faisait passer pour la fonction de la
      // personne — laquelle a désormais son propre champ, juste au-dessus et
      // toujours visible. Deux endroits qui semblent désigner le métier, dont
      // un seul est enregistré comme tel, ne pouvaient que se contredire.
      if (isRestaurantShop(shopId)) ...[
      ] else ...[
        _PresetSpec(l.hrPresetCashier,    Icons.point_of_sale_rounded,
            EmployeePermissionPresets.cashier),
        _PresetSpec(l.hrPresetStock,      Icons.inventory_rounded,
            EmployeePermissionPresets.stockManager),
      ],
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
              ? cs.primary.withValues(alpha:0.10)
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
                color: selected ? cs.primary : cs.onSurface.withValues(alpha:0.35),
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
              color: selected ? cs.primary : cs.onSurface.withValues(alpha:0.55)),
          const SizedBox(width: 6),
          Text(spec.label,
              style: AppTextStyles.bodySm.copyWith(
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? cs.primary
                      : cs.onSurface.withValues(alpha:0.85))),
        ]),
      ),
    );
  }
}

