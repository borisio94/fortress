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
import '../../domain/models/job_titles.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
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
    // Amorçage de la liste des postes — restauration seulement, c'est le seul
    // secteur où le champ Fonction existe. Différé après le premier rendu :
    // la feuille s'ouvre immédiatement, la liste se complète juste après.
    if (isRestaurantShop(widget.shopId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await AppDatabase.ensureJobTitlesSeeded(widget.shopId, [
          ...StaffMember.suggestedRoles,
          ..._carriedTitles.values,
        ]);
        if (mounted) setState(() {});
      });
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

  /// Postes PROPOSÉS : ceux que l'établissement a déclarés, plus ceux
  /// réellement portés par des comptes. Voir [JobTitles.merge] pour le
  /// pourquoi de la seconde source.
  List<String> get _jobTitles => JobTitles.merge(
        LocalStorageService.getJobTitles(widget.shopId),
        _carriedTitles.values,
      );

  /// Fonction de chaque personne de la boutique, par nom. Sert à refuser la
  /// suppression d'un poste encore occupé, et à propager un renommage.
  Map<String, String> get _carriedTitles {
    final out = <String, String>{};
    for (final e in (ref.read(employeesProvider(widget.shopId)).valueOrNull
        ?? const <Employee>[])) {
      final t = e.jobTitle.trim();
      if (t.isNotEmpty) out[e.fullName] = t;
    }
    return out;
  }

  /// Les postes de l'établissement, dans l'ordre de la liste, avec le profil
  /// de droits de chacun (`null` = le poste ne nomme qu'une fonction).
  List<_Poste> get _postes {
    final perms = LocalStorageService.getJobTitlePerms(widget.shopId);
    return [
      for (final name in _jobTitles)
        _Poste(name, JobTitles.decodePerms(JobTitles.permsFor(perms, name))),
    ];
  }

  /// Les postes sortent du volet rétractable en restauration : c'est là que
  /// se joue le choix courant, et il n'a pas à être déplié pour être vu.
  bool get _presetsAlwaysVisible => isRestaurantShop(widget.shopId);

  Widget _buildPresetSelector() => _PresetSelector(
        selected: _selected,
        onApply:  _applyPreset,
        shopId:   widget.shopId,
        // Restauration : les POSTES de l'établissement siègent ici, à côté
        // des profils livrés avec l'app. Un poste porte un nom de métier ET
        // des droits — le choisir renseigne la fonction et coche les
        // autorisations.
        postes:   isRestaurantShop(widget.shopId) ? _postes : const [],
        jobTitle: _jobTitle,
        onApplyPoste:  _applyPoste,
        onCreatePoste: _createPosteFromCurrent,
        onEditPoste:   _posteMenu,
      );

  /// Choisir un poste = poser la fonction, et appliquer ses droits s'il en a.
  void _applyPoste(_Poste p) {
    setState(() => _jobTitle = p.name);
    if (p.perms != null) _applyPreset(p.perms!);
  }

  /// Crée un poste À PARTIR DES DROITS ACTUELLEMENT COCHÉS.
  ///
  /// C'est le geste qui manquait : on règle les autorisations d'un chawarmier
  /// une fois, on les enregistre sous ce nom, et le poste devient à la fois un
  /// préréglage de droits et une fonction proposée à la prochaine embauche.
  Future<void> _createPosteFromCurrent() async {
    final name = await _askPosteName('Nouveau poste',
        'Chawarmier, glacier, gérant adjoint… *', '');
    if (name == null || name.isEmpty) return;
    try {
      await AppDatabase.saveJobTitle(widget.shopId, name,
          permissions: _selected.map((p) => p.key).toList());
      if (mounted) setState(() => _jobTitle = name);
    } catch (e) {
      if (mounted) {
        _snack(e.toString().replaceAll('Exception: ', ''), success: false);
      }
    }
  }

  /// Menu d'un poste : enregistrer les droits affichés, renommer, supprimer.
  Future<void> _posteMenu(_Poste p) async {
    final action = await showFormSheet<String>(
      context: context,
      builder: (dc) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FormSheetHeader(title: p.name, icon: Icons.work_outline_rounded),
          Divider(height: 1, color: Theme.of(dc).semantic.borderSubtle),
          ListTile(
            leading: const Icon(Icons.shield_outlined, size: 20),
            title: const Text('Enregistrer les droits affichés'),
            subtitle: Text(
                '${_selected.length} autorisation(s) deviendront celles de '
                'ce poste',
                style: AppTextStyles.caption),
            onTap: () => Navigator.of(dc).pop('perms'),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined, size: 20),
            title: const Text('Renommer'),
            onTap: () => Navigator.of(dc).pop('rename'),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded,
                size: 20, color: Theme.of(dc).semantic.danger),
            title: const Text('Supprimer'),
            onTap: () => Navigator.of(dc).pop('delete'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'perms':
        await AppDatabase.saveJobTitle(widget.shopId, p.name,
            permissions: _selected.map((x) => x.key).toList());
        if (mounted) setState(() => _jobTitle = p.name);
      case 'rename':
        final neo = await _askPosteName('Renommer le poste', p.name, p.name);
        if (neo != null && neo.isNotEmpty) await _renameJobTitle(p.name, neo);
      case 'delete':
        await _deleteJobTitle(p.name);
    }
  }

  /// Saisie d'un nom de poste — création comme renommage.
  Future<String?> _askPosteName(
      String title, String hint, String initial) async {
    final ctrl = TextEditingController(text: initial);
    final value = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: title,
        subtitle: 'Il sera proposé comme fonction à l\'embauche',
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
                decoration: InputDecoration(
                    labelText: 'Poste', hintText: hint),
                onSubmitted: (v) => Navigator.of(sheetCtx).pop(v.trim()),
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Valider',
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
    return value?.trim();
  }

  /// Ajoute un poste à la liste de l'établissement.
  ///
  /// Écrit dans la table `job_titles` (hotfix_160) : la liste appartient à la
  /// boutique, pas à l'appareil. Un poste créé sur le téléphone du gérant est
  /// proposé sur la tablette de la caisse sans que personne ne le porte
  /// encore.
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
    // Un poste déjà présent est simplement re-sélectionné : re-saisir
    // « Serveur » ne doit pas en créer un second, ni échouer.
    final existing = _jobTitles.where((t) => JobTitles.same(t, v)).toList();
    if (existing.isNotEmpty) {
      if (mounted) setState(() {});
      return existing.first;
    }
    try {
      await AppDatabase.saveJobTitle(widget.shopId, v);
    } catch (e) {
      debugPrint('[RH] ajout poste err: $e');
    }
    if (mounted) setState(() {});
    return v;
  }

  /// Supprime un poste de la liste de l'établissement.
  ///
  /// REFUSÉ tant que quelqu'un le porte : la fonction d'une personne vit sur
  /// son compte, la retirer de la liste ne la débaptiserait pas — sa fiche
  /// afficherait une fonction qui n'existe plus nulle part, et la première
  /// modification de son compte l'effacerait sans que personne ne l'ait
  /// décidé.
  Future<void> _deleteJobTitle(String label) async {
    final holders = JobTitles.holders(label, _carriedTitles);
    if (holders.isNotEmpty) {
      if (mounted) _snack(JobTitles.inUseMessage(holders, label),
          success: false);
      return;
    }
    try {
      await AppDatabase.deleteJobTitle(widget.shopId, label);
      if (mounted) {
        setState(() {
          if (JobTitles.same(_jobTitle, label)) _jobTitle = '';
        });
      }
    } catch (e) {
      if (mounted) {
        _snack(e.toString().replaceAll('Exception: ', ''), success: false);
      }
    }
  }

  /// Renomme un poste, et le répercute sur les comptes qui le portent.
  ///
  /// La propagation n'est pas un extra : sans elle, l'ancien libellé
  /// resurgirait dans la liste par la seconde source ([JobTitles.merge]) et
  /// le renommage n'aurait rien renommé.
  Future<void> _renameJobTitle(String oldName, String newName) async {
    final neo = newName.trim();
    if (neo.isEmpty || JobTitles.same(oldName, neo)) return;
    try {
      await AppDatabase.renameJobTitle(widget.shopId, oldName, neo);
      final notifier = ref.read(employeesProvider(widget.shopId).notifier);
      for (final e in (ref.read(employeesProvider(widget.shopId)).valueOrNull
          ?? const <Employee>[])) {
        if (JobTitles.same(e.jobTitle, oldName)) {
          await notifier.setJobTitle(e.userId, neo);
        }
      }
      if (mounted) {
        setState(() {
          if (JobTitles.same(_jobTitle, oldName)) _jobTitle = neo;
        });
      }
    } catch (e) {
      if (mounted) {
        _snack(e.toString().replaceAll('Exception: ', ''), success: false);
      }
    }
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
                // Chaque poste se supprime et se renomme depuis la liste :
                // aucun établissement n'a exactement les postes d'un autre.
                onDelete: _deleteJobTitle,
                onRename: _renameJobTitle,
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

            // ── Postes / préréglages — TOUJOURS VISIBLES ────────────
            //
            // Ils étaient rangés dans le volet rétractable des
            // autorisations, replié par défaut : le geste le plus courant
            // (choisir le poste de la personne) était donc caché derrière un
            // dépliage, sous des dizaines de cases à cocher qui, elles, ne
            // servent qu'aux cas particuliers.
            //
            // Restauration seulement : l'e-commerce garde sa présentation.
            if (_presetsAlwaysVisible) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: _FieldLabel(text: l.hrPresetTitle),
              ),
              const SizedBox(height: 6),
              _buildPresetSelector(),
              const SizedBox(height: 14),
            ],

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
                    // Préréglages — ici seulement quand ils ne sont pas déjà
                    // affichés en permanence au-dessus.
                    if (!_presetsAlwaysVisible) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _FieldLabel(text: l.hrPresetTitle),
                      ),
                      const SizedBox(height: 6),
                      _buildPresetSelector(),
                      const SizedBox(height: 14),
                    ],
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
  /// Postes de l'établissement (restauration). Vide ailleurs.
  final List<_Poste>                        postes;
  /// Fonction actuellement retenue — c'est elle qui met un poste en évidence,
  /// et non l'égalité des permissions : deux postes peuvent parfaitement
  /// avoir les mêmes droits sans être le même métier.
  final String                              jobTitle;
  final ValueChanged<_Poste>                onApplyPoste;
  final VoidCallback                        onCreatePoste;
  final ValueChanged<_Poste>                onEditPoste;
  const _PresetSelector({
    required this.selected,
    required this.onApply,
    required this.shopId,
    this.postes    = const [],
    this.jobTitle  = '',
    required this.onApplyPoste,
    required this.onCreatePoste,
    required this.onEditPoste,
  });

  /// Compare deux sets de permissions (égalité stricte).
  static bool _eq(Set<EmployeePermission> a, Set<EmployeePermission> b) =>
      a.length == b.length && a.every(b.contains);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final isResto = isRestaurantShop(shopId);
    final items = <_PresetSpec>[
      // EN RESTAURATION, LES PROFILS GÉNÉRIQUES SONT RETIRÉS.
      //
      // « Admin » et « Employé » ne nomment pas un métier : dans une rangée où
      // tout le reste s'appelle Serveur, Cuisinier ou Chawarmier, ils se
      // lisaient comme deux postes de plus. Les droits d'un établissement se
      // règlent poste par poste ; le niveau admin, lui, reste accessible sur
      // la fiche d'un compte existant (champ Rôle, en modification).
      //
      // « Caissier » et « Stock » restent hors restauration : leur nom y
      // désignerait un métier alors qu'ils ne sont qu'un profil de droits.
      if (!isResto) ...[
        _PresetSpec(l.hrPresetAdmin,      Icons.admin_panel_settings_rounded,
            EmployeePermissionPresets.admin),
        _PresetSpec(l.hrPresetEmployee,   Icons.badge_outlined,
            EmployeePermissionPresets.employee),
        _PresetSpec(l.hrPresetCashier,    Icons.point_of_sale_rounded,
            EmployeePermissionPresets.cashier),
        _PresetSpec(l.hrPresetStock,      Icons.inventory_rounded,
            EmployeePermissionPresets.stockManager),
      ],
      _PresetSpec(l.hrPresetAccountant, Icons.calculate_rounded,
          EmployeePermissionPresets.accountant),
      // « Tout décocher » n'est pas un profil : c'est un geste. En laisser la
      // pastille radio allumée laissait croire qu'un employé avait le
      // « préréglage vide », alors qu'il n'a simplement aucun droit encore
      // choisi. Hors restauration, l'ancienne présentation est conservée.
      if (!isResto)
        _PresetSpec(l.hrPresetClear,      Icons.layers_clear_rounded,
            const <EmployeePermission>{}),
    ];

    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final spec in items)
              _PresetRadio(
                spec:     spec,
                // Un profil livré n'est mis en évidence que si AUCUN poste
                // n'est retenu : sinon « Chawarmier » et « Employé »
                // paraîtraient cochés tous les deux.
                selected: jobTitle.trim().isEmpty && _eq(selected, spec.perms),
                onTap:    () => onApply(spec.perms),
              ),
            for (final p in postes)
              _PresetRadio(
                spec: _PresetSpec(
                    p.name,
                    p.perms == null
                        ? Icons.work_outline_rounded
                        : Icons.verified_user_outlined,
                    p.perms ?? const <EmployeePermission>{}),
                selected: JobTitles.same(jobTitle, p.name),
                onTap:    () => onApplyPoste(p),
                onMenu:   () => onEditPoste(p),
              ),
            // Créer un poste depuis les droits affichés.
            _PresetAddChip(onTap: onCreatePoste),
          ],
        ),
        if (isResto) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onApply(const <EmployeePermission>{}),
              icon: const Icon(Icons.layers_clear_rounded, size: 15),
              label: Text(l.hrPresetClear, style: AppTextStyles.bodySm),
              style: TextButton.styleFrom(
                foregroundColor: cs.onSurface.withValues(alpha: 0.70),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
        if (postes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Un poste porte un nom de métier et ses droits. Le choisir '
            'renseigne la fonction ; ⋮ permet d\'y enregistrer les '
            'autorisations affichées, de le renommer ou de le supprimer.',
            style: AppTextStyles.caption.copyWith(
                color: cs.onSurface.withValues(alpha: 0.60)),
          ),
        ],
      ],
    );
  }
}

/// Un poste de l'établissement : un nom de métier et, éventuellement, le
/// profil de droits qui va avec.
class _Poste {
  final String name;
  final Set<EmployeePermission>? perms;
  const _Poste(this.name, this.perms);
}

/// Puce « + Poste » — enregistre les droits actuellement cochés sous un nom.
class _PresetAddChip extends StatelessWidget {
  final VoidCallback onTap;
  const _PresetAddChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: cs.primary.withValues(alpha: 0.55),
              width: 1,
              style: BorderStyle.solid),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add_rounded, size: 15, color: cs.primary),
          const SizedBox(width: 6),
          Text('Nouveau poste',
              style: AppTextStyles.bodySm.copyWith(
                  fontWeight: FontWeight.w700, color: cs.primary)),
        ]),
      ),
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
  /// Non null pour les postes de l'établissement : affiche le ⋮ qui ouvre
  /// leur menu (droits / renommer / supprimer). Les profils livrés avec
  /// l'app n'en ont pas — ils ne se modifient pas.
  final VoidCallback? onMenu;
  const _PresetRadio({
    required this.spec,
    required this.selected,
    required this.onTap,
    this.onMenu,
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
          if (onMenu != null) ...[
            const SizedBox(width: 2),
            // Zone de frappe à part : toucher le ⋮ ouvre le menu du poste,
            // toucher la puce le sélectionne. Sans ce GestureDetector imbriqué,
            // le tap remonterait au parent et sélectionnerait au lieu d'ouvrir.
            GestureDetector(
              onTap: onMenu,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Icon(Icons.more_vert_rounded, size: 15,
                    color: cs.onSurface.withValues(alpha: 0.55)),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

