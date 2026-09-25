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

// ═══════════════════════════════════════════════════════════════════════
//  Onglet ÉQUIPE
// ═══════════════════════════════════════════════════════════════════════
class _StaffTab extends StatefulWidget {
  final String shopId;
  const _StaffTab({required this.shopId});
  @override
  State<_StaffTab> createState() => _StaffTabState2();
}

class _StaffTabState2 extends _StaffTabState<_StaffTab> {
  @override
  List<String> get tables => const ['employees', 'staff_absences'];
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final members = StaffService.forShop(widget.shopId);
    final payroll = members
        .where((m) => m.isActive)
        .fold<int>(0, (s, m) => s + m.baseSalary);
    final closing = LocalStorageService.getShopClosingTime(widget.shopId);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Masse salariale de base : '
                        '${CurrencyFormatter.format(payroll.toDouble())}',
                        style: AppTextStyles.caption),
                    // L'horaire commande le jugement de TOUS les pointages :
                    // tant qu'il n'est pas réglé, rien n'est jugé et il faut le
                    // dire ici plutôt que de laisser chercher la panne.
                    Text(
                        closing == null
                            ? 'Aucune heure de fermeture réglée'
                            : 'Fermeture à $closing',
                        style: AppTextStyles.micro.copyWith(
                            color: closing == null
                                ? sem.warning
                                : cs.onSurface.withValues(alpha: 0.55))),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Réglages (horaire, heures supplémentaires)',
                onPressed: () async {
                  await showStaffSettingsSheet(context, widget.shopId);
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.tune_rounded, size: 20),
              ),
              FilledButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Employé'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              ),
            ],
          ),
        ),
        Expanded(
          child: members.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.badge_outlined,
                  title: 'Aucun employé',
                  subtitle: 'Serveuses, cuisiniers, plongeurs… Ils n\'ont pas '
                      'besoin de compte : un code à 4 chiffres suffit pour '
                      'pointer.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: members.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final m = members[i];
                    // Absence en cours : l'information qui explique pourquoi
                    // cette personne n'a aucun pointage depuis trois jours.
                    // Sans elle, le gérant la croit en fuite.
                    final away =
                        StaffService.absenceOn(widget.shopId, m.id);
                    return _Row(
                      onTap: () => _edit(m),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(m.fullName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodyBold.copyWith(
                                      color: m.isActive
                                          ? cs.onSurface
                                          : cs.onSurface
                                              .withValues(alpha: 0.5))),
                              Text(
                                  [
                                    if (m.role.isNotEmpty) m.role,
                                    if ((m.station ?? '').isNotEmpty)
                                      m.station!,
                                    // Dit pourquoi cette personne n'apparaît
                                    // nulle part dans « Accès à l'app » : ce
                                    // n'est pas un oubli, elle ne s'y connecte
                                    // pas.
                                    if (!m.hasAppAccess) 'sans compte',
                                    if (!m.isActive) 'archivé',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.caption),
                              if (away != null)
                                Text(
                                    '${away.kind.label} jusqu\'au '
                                    '${_dayShortLabel(away.endDate)}'
                                    '${away.isPaid ? '' : ' · sans solde'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.micro
                                        .copyWith(color: sem.warning)),
                            ],
                          ),
                        ),
                        Text(CurrencyFormatter.format(m.baseSalary.toDouble()),
                            style: AppTextStyles.bodySmBold),
                        const SizedBox(width: 8),
                        Icon(
                            m.hasPin
                                ? Icons.pin_rounded
                                : Icons.pin_outlined,
                            size: 18,
                            color: m.hasPin
                                ? sem.success
                                : cs.onSurface.withValues(alpha: 0.3)),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _edit(StaffMember? m) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _StaffEditor(shopId: widget.shopId, existing: m),
    );
    if (mounted) setState(() {});
  }

  static String _dayShortLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';
}

/// Création / modification d'une fiche : identité, salaire, code de pointage.
class _StaffEditor extends StatefulWidget {
  final String shopId;
  final StaffMember? existing;
  const _StaffEditor({required this.shopId, this.existing});
  @override
  State<_StaffEditor> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<_StaffEditor> {
  late final _name =
      TextEditingController(text: widget.existing?.fullName ?? '');
  late final _role = TextEditingController(text: widget.existing?.role ?? '');
  late final _station =
      TextEditingController(text: widget.existing?.station ?? '');
  late final _salary = TextEditingController(
      text: (widget.existing?.baseSalary ?? 0) == 0
          ? ''
          : '${widget.existing!.baseSalary}');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  final _pin = TextEditingController();
  String? _err;

  /// Horaire propre à cet employé. `null` = il suit celui de la boutique, ce
  /// qui est le cas de presque tout le monde.
  late String? _closing = widget.existing?.closingTime;

  /// La personne a-t-elle un compte dans l'application ?
  ///
  /// Deux populations, deux saisies : celle qui utilise l'app est CHOISIE
  /// parmi les comptes (nom et fonction hérités, jamais retapés) ; celle qui
  /// ne s'y connectera jamais — veilleur, homme de ménage, plongeur — est
  /// SAISIE ici, parce qu'aucun compte ne la porte.
  late bool _hasAccount = widget.existing?.hasAppAccess ?? true;

  bool get _isEdit => widget.existing != null;

  /// Le personnel déjà inscrit, réduit à ce qui permet de le rapprocher d'un
  /// compte — sert à retirer de la liste ceux qui ont déjà leur fiche.
  ///
  /// Le rapprochement se faisait sur le NOM seul, faute de lien stocké, et
  /// deux homonymes se confondaient : la fiche de la première « Awa Ndiaye »
  /// rendait le compte de la seconde inéligible, sans que rien ne l'explique.
  /// `StaffMember.userId` porte le lien depuis le hotfix_182 ; le nom ne sert
  /// plus que de repli, sur les fiches qui n'en ont pas. Voir
  /// `staff_account_link.dart`.
  late final List<StaffLink> _staffLinks = [
    for (final s in StaffService.forShop(widget.shopId))
      if (s.id != widget.existing?.id)
        (userId: s.userId, fullName: s.fullName),
  ];

  /// Le compte retenu dans la liste, pour l'écrire sur la fiche.
  ///
  /// En modification, c'est celui que la fiche porte déjà — une fiche
  /// antérieure au hotfix_182 n'en a pas, et n'en gagnera un que si l'on
  /// rechoisit la personne.
  late String? _selectedUserId = widget.existing?.userId;

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    _station.dispose();
    _salary.dispose();
    _phone.dispose();
    _pin.dispose();
    super.dispose();
  }

  /// Sans cette précision, le gérant cherche le doublon dans l'équipe active —
  /// qui ne l'affiche pas — et conclut que l'app se trompe.
  String _archivedSuffix(StaffMember s) =>
      s.isActive ? '' : ' (fiche archivée)';

  Future<void> _pickClosing() async {
    final parsed = ShiftEvaluation.parseHhmm(
        _closing ?? LocalStorageService.getShopClosingTime(widget.shopId));
    final picked = await showTimePicker(
      context: context,
      initialTime: parsed == null
          ? const TimeOfDay(hour: 22, minute: 0)
          : TimeOfDay(hour: parsed.$1, minute: parsed.$2),
      helpText: 'Fin de service de cette personne',
    );
    if (picked == null) return;
    setState(() =>
        _closing = ShiftEvaluation.formatHhmm(picked.hour, picked.minute));
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      // Avec un compte, le nom vient du compte choisi : vide = personne non
      // sélectionnée. Sans compte, il se tape — le message doit dire lequel
      // des deux gestes manque.
      setState(() => _err = _isEdit || !_hasAccount
          ? 'Nom requis'
          : 'Choisissez la personne parmi les comptes de la boutique.');
      return;
    }
    // Deux fiches au même nom : les heures et la paie de l'un finiraient sur
    // l'autre. Le contrôle n'existait pas tant que le nom venait d'un compte
    // (la liste retirait déjà les comptes déjà inscrits) ; il devient
    // indispensable dès que le nom se tape.
    if (!_hasAccount &&
        _staffLinks.any(
            (s) => s.fullName.trim().toLowerCase() == name.toLowerCase())) {
      setState(() => _err = '$name figure déjà dans le personnel.');
      return;
    }
    // Deux fiches au même numéro : c'est la même personne inscrite deux fois.
    // Le nom ne permet pas de s'en apercevoir (une lettre d'écart suffit à
    // créer un second dossier) ; le contact, si. Les archivés comptent : une
    // fiche archivée se réactive d'un bouton, et le doublon ressurgirait.
    final phone = _phone.text.trim();
    final phoneOwner = StaffService.phoneOwner(widget.shopId, phone,
        exceptId: widget.existing?.id);
    if (phoneOwner != null) {
      setState(() => _err = 'Ce numéro est déjà celui de '
          '${phoneOwner.fullName}${_archivedSuffix(phoneOwner)}.');
      return;
    }

    final pin = _pin.text.trim();
    if (pin.isNotEmpty && !StaffService.isValidPin(pin)) {
      setState(() => _err = 'Le code de pointage fait 4 chiffres');
      return;
    }
    // Deux employés avec le même code : le badgeage attribuerait les heures au
    // premier trouvé. On refuse au moment de la saisie, seul endroit où on
    // peut encore expliquer pourquoi.
    final pinOwner = pin.isEmpty
        ? null
        : StaffService.pinOwner(widget.shopId, pin,
            exceptId: widget.existing?.id);
    if (pinOwner != null) {
      setState(() => _err = 'Ce code est déjà celui de '
          '${pinOwner.fullName}${_archivedSuffix(pinOwner)}. '
          'Choisissez-en un autre.');
      return;
    }

    var member = _isEdit
        ? widget.existing!.copyWith(
            fullName: name,
            role: _role.text.trim(),
            station: _station.text.trim(),
            baseSalary: int.tryParse(_salary.text.trim()) ?? 0,
            phone: phone,
            closingTime: _closing,
            // « Comme la boutique » doit pouvoir être RÉTABLI : sans ce
            // drapeau, `copyWith(closingTime: null)` serait un no-op et
            // l'horaire particulier resterait collé à la fiche.
            clearClosingTime: _closing == null,
            userId: _selectedUserId,
          )
        : await StaffService.createMember(
            shopId: widget.shopId,
            fullName: name,
            role: _role.text.trim(),
            station: _station.text.trim(),
            baseSalary: int.tryParse(_salary.text.trim()) ?? 0,
            phone: phone,
            hasAppAccess: _hasAccount,
            closingTime: _closing,
            // Nul pour une saisie libre : la personne n'a pas de compte.
            userId: _hasAccount ? _selectedUserId : null,
          );
    if (_isEdit) await StaffService.saveMember(member);
    if (pin.isNotEmpty) {
      member = await StaffService.setPin(member, pin) ?? member;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  /// L'absence qui court aujourd'hui, s'il y en a une.
  StaffAbsence? get _liveAbsence => widget.existing == null
      ? null
      : StaffService.absenceOn(widget.shopId, widget.existing!.id);

  static String _dayShort(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';

  /// MISE À PIED ou CONGÉ PAYÉ : deux dates, un motif, et pour la mise à pied
  /// la question du solde.
  Future<void> _absence(AbsenceKind kind) async {
    final m = widget.existing!;
    var start = DateTime.now();
    var end = DateTime.now();
    final reason = TextEditingController();
    // Sans solde par défaut pour une mise à pied ; un congé payé l'est par
    // définition et la question ne se pose pas.
    var isPaid = kind == AbsenceKind.paidLeave;

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final days = StaffAbsence(
            id: '_', shopId: widget.shopId, employeeId: m.id, kind: kind,
            startDate: start, endDate: end, reason: '',
            createdAt: DateTime.now(),
          ).days;
          final perDay = StaffAbsence.dailyRate(m.baseSalary);
          return AdaptiveFormFrame(
            title: kind.label,
            subtitle: m.fullName,
            icon: kind == AbsenceKind.suspension
                ? Icons.gavel_rounded
                : Icons.beach_access_rounded,
            body: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      kind == AbsenceKind.suspension
                          ? 'L\'employé est écarté du service. Il ne pourra '
                              'pas badger pendant cette période.'
                          : 'Le salaire est maintenu intégralement. Il ne '
                              'pourra pas badger pendant cette période.',
                      style: AppTextStyles.captionHint),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: _DayField(
                        label: 'Du',
                        value: start,
                        onPick: (d) => setSheet(() {
                          start = d;
                          if (end.isBefore(start)) end = start;
                        }),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DayField(
                        label: 'Au (inclus)',
                        value: end,
                        onPick: (d) => setSheet(() => end = d),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text('$days jour${days > 1 ? 's' : ''}',
                      style: AppTextStyles.caption),
                  const SizedBox(height: 10),
                  TextField(
                    controller: reason,
                    autofocus: true,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Motif *',
                      hintText: kind == AbsenceKind.suspension
                          ? 'Absence répétée sans prévenir, 3e fois'
                          : 'Congé annuel, mariage, deuil…',
                    ),
                  ),
                  if (kind == AbsenceKind.suspension) ...[
                    const SizedBox(height: 8),
                    SwitchListTile(
                      value: isPaid,
                      onChanged: (v) => setSheet(() => isPaid = v),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Maintenir le salaire',
                          style: AppTextStyles.bodySm),
                      // La mise à pied CONSERVATOIRE : on écarte le temps de
                      // vérifier les faits. Sanctionner avant d'avoir vérifié
                      // est exactement ce qu'elle sert à éviter.
                      subtitle: Text(
                          isPaid
                              ? 'Mise à pied conservatoire : rien n\'est '
                                  'retenu, le temps de vérifier les faits.'
                              : perDay <= 0
                                  ? 'Aucun salaire de base renseigné : rien ne '
                                      'sera retenu.'
                                  : 'Retenue de '
                                      '${CurrencyFormatter.format((perDay * days).toDouble())} '
                                      '($days × ${CurrencyFormatter.format(perDay.toDouble())} '
                                      'par jour) sur la prochaine paie.',
                          style: AppTextStyles.micro),
                    ),
                  ],
                  const SizedBox(height: 14),
                  AppPrimaryButton(
                    label: 'Enregistrer',
                    icon: Icons.check_rounded,
                    fullWidth: true,
                    onTap: () => Navigator.of(sheetCtx).pop(true),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;
    if (reason.text.trim().isEmpty) {
      AppSnack.info(context,
          'Le motif est obligatoire : sans lui, la décision est '
          'indéfendable le jour où elle est contestée.');
      return;
    }
    await StaffService.recordAbsence(
      member: m,
      kind: kind,
      startDate: start,
      endDate: end,
      reason: reason.text,
      isPaid: isPaid,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
    AppSnack.success(context, '${kind.label} enregistrée.');
  }

  Future<void> _liftAbsence() async {
    final a = _liveAbsence;
    if (a == null) return;
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.undo_rounded,
      iconColor: Theme.of(context).semantic.warning,
      title: 'Lever cette ${a.kind.label.toLowerCase()} ?',
      body: const Text(
          'L\'employé peut de nouveau badger, et plus rien ne sera retenu. '
          'La décision reste consultable dans l\'historique.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Lever',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.cancelAbsence(a);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// SUPPRESSION DÉFINITIVE. Le motif est exigé, et la boîte dit exactement ce
  /// qui reste — un gérant qui croit tout effacer serait très surpris de
  /// retrouver les bulletins, et très ennuyé de ne PAS les retrouver.
  Future<void> _delete() async {
    final m = widget.existing!;
    final reason = TextEditingController();
    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Supprimer ${m.fullName} ?',
        icon: Icons.delete_forever_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                  'Sa fiche disparaît des listes, de la paie et de la '
                  'notation. Ses pointages, avances et bulletins déjà émis '
                  'RESTENT : ils portent son nom et alimentent des totaux '
                  'déjà vérifiés.',
                  style: AppTextStyles.bodySm),
              const SizedBox(height: 8),
              Text(
                  'Pour un départ ordinaire, préférez « Archiver » : la fiche '
                  'sort de l\'équipe active et se réactive d\'un bouton.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 12),
              TextField(
                controller: reason,
                autofocus: true,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Motif de la suppression *',
                  hintText: 'Fiche créée par erreur, doublon…',
                ),
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Supprimer définitivement',
                icon: Icons.delete_forever_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(sheetCtx).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    if (reason.text.trim().isEmpty) {
      AppSnack.info(context,
          'Le motif est obligatoire : une fois la fiche partie, il sera la '
          'seule trace de ce qui a disparu.');
      return;
    }
    await StaffService.deleteMemberWithReason(m, reason.text);
    if (!mounted) return;
    Navigator.of(context).pop(true);
    AppSnack.success(context, '${m.fullName} supprimé — historique conservé.');
  }

  Future<void> _archive() async {
    final m = widget.existing!;
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.archive_outlined,
      iconColor: Theme.of(context).semantic.warning,
      title: m.isActive ? 'Archiver ${m.fullName} ?' : 'Réactiver ?',
      body: Text(m.isActive
          ? 'Sa fiche sort de l\'équipe active. Ses pointages et ses fiches '
              'de paie restent consultables.'
          : 'Il ou elle réapparaît dans l\'équipe et peut de nouveau badger.'),
      cancelLabel: 'Annuler',
      confirmLabel: m.isActive ? 'Archiver' : 'Réactiver',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.saveMember(m.copyWith(isActive: !m.isActive));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final m = widget.existing;
    return AdaptiveFormFrame(
      title: _isEdit ? m!.fullName : 'Nouvel employé',
      icon: Icons.badge_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ACCÈS À L'APPLICATION — la question qui commande tout le reste.
            //
            // Un veilleur de nuit ou un homme de ménage ne se connectera
            // jamais, mais son salaire, ses heures et ses avances se tiennent
            // ici. Tant que la fiche exigeait de choisir la personne parmi les
            // comptes, ces gens-là étaient tout simplement impossibles à
            // inscrire.
            if (!_isEdit) ...[
              Text('Cette personne utilise-t-elle l\'application ?',
                  style: AppTextStyles.caption),
              const SizedBox(height: 6),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: true,
                      label: Text('Oui, elle a un compte'),
                      icon: Icon(Icons.phone_iphone_rounded, size: 16)),
                  ButtonSegment(
                      value: false,
                      label: Text('Non, personnel seul'),
                      icon: Icon(Icons.badge_outlined, size: 16)),
                ],
                selected: {_hasAccount},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  _hasAccount = s.first;
                  // Le nom et la fonction viennent de deux sources
                  // différentes selon le mode : les garder d'un mode à
                  // l'autre laisserait le nom d'un compte sur une fiche
                  // « sans compte ».
                  _name.clear();
                  _role.clear();
                  _err = null;
                }),
              ),
              const SizedBox(height: 6),
              Text(
                  _hasAccount
                      ? 'Elle est choisie parmi les comptes « Accès à l\'app » '
                          '— son nom et sa fonction viennent de son compte.'
                      : 'Elle n\'aura ni compte ni mot de passe. Elle apparaît '
                          'dans le personnel, les pointages et la paie.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 10),
            ],

            // IDENTITÉ.
            //
            // AVEC compte : choisie, jamais retapée — la saisir une seconde
            // fois faisait diverger les deux listes (« Awa Ndiaye » ici, « Awa
            // ndiaye » là) et interdisait tout rapprochement. En modification
            // le nom reste figé : c'est le compte qui le porte.
            //
            // SANS compte : saisie ici, à la création comme en modification,
            // puisque aucun compte ne la porte.
            if (_isEdit && m!.hasAppAccess)
              _ReadOnlyField(label: 'Nom complet', value: m.fullName)
            else if (_hasAccount)
              _AccountPicker(
                shopId: widget.shopId,
                selected: _name.text,
                staffLinks: _staffLinks,
                onSelect: (userId, name, jobTitle) => setState(() {
                  _selectedUserId = userId;
                  _name.text = name;
                  _role.text = jobTitle;
                }),
              )
            else
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Nom complet *',
                    hintText: 'Ex : Awa Ndiaye'),
              ),
            const SizedBox(height: 10),
            // FONCTION.
            //
            // AVEC compte : HÉRITÉE. Elle est saisie une seule fois, à la
            // création du compte (`shop_memberships.job_title`, hotfix_159), et
            // recopiée sur la fiche au moment de la sélection. La choisir une
            // seconde fois laissait les deux valeurs diverger, sans qu'aucune
            // ne fasse autorité.
            //
            // Recopiée et non lue à la volée : `StaffMember.role` alimente la
            // feuille d'assignation d'un livreur et les états de paie, qui
            // doivent rester stables même si le compte est modifié ou supprimé
            // plus tard.
            //
            // SANS compte : choisie dans les postes de l'établissement — la
            // même liste que celle des comptes, pour que « Plongeur » désigne
            // le même métier des deux côtés.
            if (_hasAccount)
              _ReadOnlyField(
                  label: 'Fonction',
                  value: _role.text.isEmpty
                      ? 'Aucune — à définir sur le compte'
                      : _role.text)
            else
              AppSelectWidget(
                label: 'Fonction',
                items: JobTitles.merge(
                    LocalStorageService.getJobTitles(widget.shopId),
                    [for (final s in StaffService.forShop(widget.shopId))
                      s.role],
                ),
                value: _role.text.isEmpty ? null : _role.text,
                icon: Icons.work_outline_rounded,
                onChanged: (v) => setState(() => _role.text = v),
              ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _salary,
                  keyboardType: const TextInputType.numberWithOptions(),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration:
                      const InputDecoration(labelText: 'Salaire de base'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _station,
                  decoration: const InputDecoration(
                      labelText: 'Poste', hintText: 'Cuisine, Salle…'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Téléphone',
                hintText: 'Ex : 699 12 34 56',
                helperText: 'Propre à une personne : il évite le doublon '
                    'de fiche.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 10),
            // HORAIRE PARTICULIER.
            //
            // Le boulanger qui part à 11 h, le veilleur qui prend à la
            // fermeture : sans cette surcharge, ils accumuleraient chaque jour
            // des heures supplémentaires imaginaires ou devraient justifier un
            // départ anticipé quotidien.
            Row(children: [
              Expanded(
                child: InkWell(
                  onTap: _pickClosing,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Fin de service',
                      helperText: _closing == null
                          ? 'Suit l\'horaire de l\'établissement'
                          : 'Horaire particulier à cette personne',
                      suffixIcon: const Icon(Icons.schedule_rounded, size: 18),
                    ),
                    child: Text(_closing ?? 'Comme la boutique',
                        style: AppTextStyles.body),
                  ),
                ),
              ),
              if (_closing != null)
                TextButton(
                  onPressed: () => setState(() => _closing = null),
                  child: const Text('Retirer'),
                ),
            ]),
            const SizedBox(height: 14),
            Text('Code de pointage', style: AppTextStyles.caption),
            const SizedBox(height: 2),
            Text(
                m?.hasPin == true
                    ? 'Un code est déjà défini. Saisissez-en un nouveau pour '
                        'le remplacer.'
                    : '4 chiffres, saisis sur la badgeuse à l\'entrée du '
                        'personnel. Il est enregistré chiffré.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 6),
            TextField(
              controller: _pin,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              obscureText: true,
              decoration: InputDecoration(
                labelText: m?.hasPin == true ? 'Nouveau code' : 'Code',
                hintText: '••••',
                suffixIcon: m?.hasPin == true
                    ? TextButton(
                        onPressed: () async {
                          await StaffService.clearPin(m!);
                          if (context.mounted) Navigator.of(context).pop(true);
                        },
                        child: const Text('Retirer'),
                      )
                    : null,
              ),
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: _isEdit ? 'Enregistrer' : 'Créer',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _save,
            ),
            if (_isEdit) ...[
              const Divider(height: 26),
              const Text('Décisions', style: AppTextStyles.label),
              const SizedBox(height: 2),
              Text(
                  'Chacune demande un motif écrit : c\'est ce qui reste le '
                  'jour où elle est contestée.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 8),
              // ABSENCE EN COURS — affichée avant les boutons : prononcer une
              // seconde mise à pied par-dessus une première est une erreur de
              // saisie qu'on évite en la montrant, pas en la refusant.
              if (_liveAbsence != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: sem.warning.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: sem.warning.withValues(alpha: 0.35)),
                  ),
                  child: Row(children: [
                    Icon(Icons.event_busy_rounded, size: 16,
                        color: sem.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          '${_liveAbsence!.kind.label} jusqu\'au '
                          '${_dayShort(_liveAbsence!.endDate)}'
                          '${_liveAbsence!.isPaid ? ' (payée)' : ' (sans solde)'}'
                          '\n« ${_liveAbsence!.reason} »',
                          style: AppTextStyles.caption),
                    ),
                    TextButton(
                      onPressed: _liftAbsence,
                      child: const Text('Lever'),
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
              ],
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _absence(AbsenceKind.suspension),
                    icon: const Icon(Icons.gavel_rounded, size: 16),
                    label: const Text('Mise à pied'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        foregroundColor: sem.warning),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _absence(AbsenceKind.paidLeave),
                    icon: const Icon(Icons.beach_access_rounded, size: 16),
                    label: const Text('Congé payé'),
                    style:
                        OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: _archive,
                    icon: Icon(
                        m!.isActive
                            ? Icons.archive_outlined
                            : Icons.unarchive_outlined,
                        size: 18,
                        color: sem.warning),
                    label: Text(m.isActive ? 'Archiver' : 'Réactiver',
                        style:
                            AppTextStyles.label.copyWith(color: sem.warning)),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: _delete,
                    icon: Icon(Icons.delete_forever_rounded,
                        size: 18, color: sem.danger),
                    label: Text('Supprimer',
                        style:
                            AppTextStyles.label.copyWith(color: sem.danger)),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Onglet POINTAGE
// ═══════════════════════════════════════════════════════════════════════
class _TimeTab extends StatefulWidget {
  final String shopId;
  const _TimeTab({required this.shopId});
  @override
  State<_TimeTab> createState() => _TimeTabState();
}

class _TimeTabState extends _StaffTabState<_TimeTab> {
  @override
  List<String> get tables => const ['time_records', 'employees'];
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final onDuty = StaffService.onDuty(widget.shopId);
    final records = StaffService.timeRecords(widget.shopId).take(60).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.groups_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    onDuty.isEmpty
                        ? 'Personne en service'
                        : '${onDuty.length} en service : '
                            '${onDuty.map((r) => r.employeeName ?? '?').join(', ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySm),
              ),
              TextButton.icon(
                onPressed: _manualEntry,
                icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                label: const Text('Saisir'),
              ),
            ],
          ),
        ),
        Expanded(
          child: records.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.schedule_outlined,
                  title: 'Aucun pointage',
                  subtitle: 'Ouvrez la badgeuse (icône en haut) sur la '
                      'tablette de l\'entrée du personnel.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: records.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final r = records[i];
                    // Le verdict prime sur l'état du service dans l'icône : un
                    // pointage qui attend une décision doit se repérer sans
                    // lire, au milieu de soixante lignes identiques.
                    final needsCall = r.excuseToJudge || r.overtimeToSettle;
                    return _Row(
                      onTap: () => _recordActions(r),
                      child: Row(children: [
                        Icon(
                            r.isOpen
                                ? Icons.play_circle_outline_rounded
                                : needsCall
                                    ? Icons.help_outline_rounded
                                    : Icons.check_circle_outline_rounded,
                            size: 18,
                            color: r.isOpen
                                ? sem.warning
                                : needsCall
                                    ? sem.warning
                                    : sem.success),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.employeeName ?? 'Employé',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodyBold
                                      .copyWith(color: cs.onSurface)),
                              Text(
                                  '${_stamp(r.clockIn)} → '
                                  '${r.isOpen ? 'en cours' : _stamp(r.clockOut)}'
                                  '${r.method == 'manual' ? ' · saisi' : ''}',
                                  style: AppTextStyles.caption),
                              if (_verdictLabel(r) != null)
                                Text(_verdictLabel(r)!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.micro
                                        .copyWith(color: _verdictColor(r, sem))),
                            ],
                          ),
                        ),
                        Text(
                            TimeRecord.formatMinutes(
                                r.durationMinutes ?? r.worked.inMinutes),
                            style: AppTextStyles.bodySmBold),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Ce qu'un pointage raconte en une ligne : rien s'il est normal, le verdict
  /// sinon. Écrire « à l'heure » sur chaque ligne noierait les deux qui
  /// demandent quelque chose.
  static String? _verdictLabel(TimeRecord r) {
    if (r.isEarly) {
      final t = 'parti ${TimeRecord.formatMinutes(r.earlyMinutes)} plus tôt';
      return switch (r.excuseStatus) {
        ExcuseStatus.pending => '$t · excuse à juger',
        ExcuseStatus.accepted => '$t · excusé',
        ExcuseStatus.refused => '$t · excuse refusée',
        ExcuseStatus.none => '$t · sans excuse',
      };
    }
    if (r.hasOvertime) {
      final t = '+${TimeRecord.formatMinutes(r.overtimeMinutes)}';
      if (r.overtimeSettled) {
        return r.overtimeSettlement == OvertimeSettlement.paidNow
            ? '$t · payées'
            : '$t · portées sur la paie';
      }
      return r.overtimeSettlement == OvertimeSettlement.onPayslip
          ? '$t · en attente de la paie'
          : '$t · à régler';
    }
    return null;
  }

  static Color? _verdictColor(TimeRecord r, AppSemanticColors sem) {
    if (r.excuseToJudge || r.overtimeToSettle) return sem.warning;
    if (r.isUnexcused) return sem.danger;
    if (r.hasOvertime) return sem.success;
    return null;
  }

  /// Le sheet où le gérant TRANCHE : accepter ou refuser une excuse, payer des
  /// heures supplémentaires tout de suite ou les reporter sur la paie.
  ///
  /// Rien ne se décide ailleurs. C'est le seul écran qui engage de l'argent
  /// sur un pointage, et il ne le fait jamais sans un geste explicite.
  Future<void> _recordActions(TimeRecord r) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) {
        final sem = Theme.of(sheetCtx).semantic;
        return AdaptiveFormFrame(
          title: r.employeeName ?? 'Pointage',
          subtitle: '${_stamp(r.clockIn)} → '
              '${r.isOpen ? 'en cours' : _stamp(r.clockOut)}',
          icon: Icons.schedule_outlined,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Expanded(
                      child: Text('Durée travaillée',
                          style: AppTextStyles.bodySm)),
                  Text(
                      TimeRecord.formatMinutes(
                          r.durationMinutes ?? r.worked.inMinutes),
                      style: AppTextStyles.bodySmBold),
                ]),
                if (r.scheduledEnd != null)
                  Row(children: [
                    Expanded(
                        child: Text('Fin prévue',
                            style: AppTextStyles.captionHint)),
                    Text(_stamp(r.scheduledEnd), style: AppTextStyles.caption),
                  ]),

                // ── DÉPART ANTICIPÉ ──────────────────────────────────────
                if (r.isEarly) ...[
                  const Divider(height: 22),
                  Row(children: [
                    Icon(Icons.logout_rounded, size: 16, color: sem.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          'Parti ${TimeRecord.formatMinutes(r.earlyMinutes)} '
                          'avant la fermeture',
                          style: AppTextStyles.bodySmBold),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                      (r.earlyExcuse ?? '').isEmpty
                          ? 'Aucune excuse n\'a été donnée à la badgeuse.'
                          : '« ${r.earlyExcuse} »',
                      style: AppTextStyles.bodySm),
                  const SizedBox(height: 4),
                  Text(r.excuseStatus.label,
                      style: AppTextStyles.micro.copyWith(
                          color: switch (r.excuseStatus) {
                        ExcuseStatus.accepted => sem.success,
                        ExcuseStatus.refused => sem.danger,
                        _ => sem.warning,
                      })),
                  // Les deux boutons restent offerts même après décision : un
                  // gérant qui a refusé trop vite, puis à qui l'employé
                  // apporte le justificatif le lendemain, doit pouvoir se
                  // dédire sans supprimer le pointage.
                  ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(sheetCtx).pop('accept'),
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Accepter'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(sheetCtx).pop('refuse'),
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('Refuser'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40),
                              foregroundColor: sem.danger),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                        'Un refus ne retient rien automatiquement : il vous '
                        'le rappelle au moment de la paie.',
                        style: AppTextStyles.micro),
                  ],
                ],

                // ── HEURES SUPPLÉMENTAIRES ───────────────────────────────
                if (r.hasOvertime) ...[
                  const Divider(height: 22),
                  Row(children: [
                    Icon(Icons.more_time_rounded, size: 16,
                        color: sem.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          '${TimeRecord.formatMinutes(r.overtimeMinutes)} '
                          'au-delà de la fermeture',
                          style: AppTextStyles.bodySmBold),
                    ),
                    Text(
                        CurrencyFormatter.format(
                            r.overtimeAmount.toDouble()),
                        style: AppTextStyles.bodySmBold),
                  ]),
                  if (r.overtimeRate <= 0) ...[
                    const SizedBox(height: 4),
                    Text(
                        'Aucun taux horaire n\'est réglé pour cette fonction : '
                        'les heures sont comptées mais valorisées à zéro. '
                        'Réglez-le dans l\'onglet Équipe.',
                        style: AppTextStyles.micro.copyWith(
                            color: sem.warning)),
                  ] else
                    Text(
                        'Taux : '
                        '${CurrencyFormatter.format(r.overtimeRate.toDouble())} '
                        'de l\'heure, au prorata des minutes.',
                        style: AppTextStyles.micro),
                  const SizedBox(height: 10),
                  if (r.overtimeSettled)
                    Text(
                        r.overtimeSettlement == OvertimeSettlement.paidNow
                            ? 'Déjà payées de la main à la main.'
                            : 'Déjà portées sur une fiche de paie.',
                        style: AppTextStyles.caption
                            .copyWith(color: sem.success))
                  else ...[
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(sheetCtx).pop('ot_now'),
                          icon: const Icon(Icons.payments_outlined, size: 16),
                          label: const Text('Payer de suite'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(sheetCtx).pop('ot_payslip'),
                          icon: const Icon(Icons.event_note_outlined,
                              size: 16),
                          label: const Text('Sur la paie'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                        ),
                      ),
                    ]),
                    if (r.overtimeSettlement == OvertimeSettlement.onPayslip)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                            'Reportées : elles s\'ajouteront à la fiche du '
                            'mois, avec la mention des heures.',
                            style: AppTextStyles.micro
                                .copyWith(color: sem.success)),
                      ),
                  ],
                ],

                const SizedBox(height: 14),
                Center(
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(sheetCtx).pop('delete'),
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 18, color: sem.danger),
                    label: Text('Supprimer ce pointage',
                        style: AppTextStyles.label
                            .copyWith(color: sem.danger)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'accept':
      case 'refuse':
        await StaffService.judgeExcuse(r, action == 'accept');
        if (!mounted) return;
        setState(() {});
        AppSnack.success(
            context,
            action == 'accept'
                ? 'Départ excusé.'
                : 'Excuse refusée — rien n\'a été retenu.');
        return;
      case 'ot_now':
        await StaffService.settleOvertime(r, OvertimeSettlement.paidNow);
        if (!mounted) return;
        setState(() {});
        AppSnack.success(
            context,
            'Heures payées : '
            '${CurrencyFormatter.format(r.overtimeAmount.toDouble())} '
            'sortis de la caisse.');
        return;
      case 'ot_payslip':
        await StaffService.settleOvertime(r, OvertimeSettlement.onPayslip);
        if (!mounted) return;
        setState(() {});
        AppSnack.success(context, 'Reportées sur la paie du mois.');
        return;
      case 'delete':
        final ok = await AppConfirmDialog.show(
          context: context,
          icon: Icons.delete_outline_rounded,
          iconColor: Theme.of(context).semantic.danger,
          title: 'Supprimer ce pointage ?',
          body: Text('${r.employeeName ?? 'Employé'} · '
              '${_stamp(r.clockIn)} → '
              '${r.isOpen ? 'en cours' : _stamp(r.clockOut)}'),
          cancelLabel: 'Annuler',
          confirmLabel: 'Supprimer',
          onConfirm: () {},
        );
        if (ok != true || !mounted) return;
        await StaffService.deleteTimeRecord(r);
        if (mounted) setState(() {});
        return;
    }
  }

  /// Saisie manuelle d'un service — l'oubli de badge est la règle, pas
  /// l'exception : sans rattrapage, les heures du mois sont fausses.
  Future<void> _manualEntry() async {
    final members = StaffService.forShop(widget.shopId, onlyActive: true);
    if (members.isEmpty) {
      AppSnack.info(context, 'Ajoutez d\'abord un employé.');
      return;
    }
    final member = await showAdaptiveFormSheet<StaffMember>(
      context: context,
      builder: (_) => AdaptiveFormFrame(
        title: 'Qui a travaillé ?',
        icon: Icons.person_search_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final m in members)
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(m.fullName),
                subtitle: m.role.isEmpty ? null : Text(m.role),
                onTap: () => Navigator.of(context).pop(m),
              ),
          ]),
        ),
      ),
    );
    if (member == null || !mounted) return;

    final day = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
    );
    if (day == null || !mounted) return;

    final start = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
      helpText: 'Heure d\'arrivée',
    );
    if (start == null || !mounted) return;
    final end = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 18, minute: 0),
      helpText: 'Heure de départ',
    );
    if (end == null || !mounted) return;

    final from =
        DateTime(day.year, day.month, day.day, start.hour, start.minute);
    var to = DateTime(day.year, day.month, day.day, end.hour, end.minute);
    // Service de nuit : une sortie antérieure à l'entrée est le lendemain.
    // Sans ça, la durée serait nulle et les heures de nuit disparaîtraient.
    if (to.isBefore(from)) to = to.add(const Duration(days: 1));

    await StaffService.recordManual(
        member: member, start: from, end: to, note: 'Saisie gérant');
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Pointage enregistré.');
  }

  static String _stamp(DateTime? d) {
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Onglet PAIE
// ═══════════════════════════════════════════════════════════════════════
class _PayrollTab extends StatefulWidget {
  final String shopId;
  const _PayrollTab({required this.shopId});
  @override
  State<_PayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends _StaffTabState<_PayrollTab> {
  @override
  List<String> get tables => const [
        'payroll', 'salary_advances', 'employees', 'time_records',
        'staff_penalties', 'staff_absences',
      ];
  @override
  String get shopId => widget.shopId;

  late DateTime _month = DateTime.now();

  String get _monthKey => SalaryAdvance.monthKey(_month);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final members = StaffService.forShop(widget.shopId, onlyActive: true);
    final slips = StaffService.payslips(widget.shopId, month: _monthKey);
    final total = slips.fold<int>(0, (s, p) => s + p.netSalary);

    return Column(
      children: [
        // Sélecteur de mois : la paie se prépare souvent le mois suivant.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() =>
                    _month = DateTime(_month.year, _month.month - 1)),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(_monthLabel(_month),
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyBold),
              ),
              IconButton(
                onPressed: () => setState(() =>
                    _month = DateTime(_month.year, _month.month + 1)),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
        if (slips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                    child: Text('${slips.length} fiche'
                        '${slips.length > 1 ? 's' : ''} générée'
                        '${slips.length > 1 ? 's' : ''}',
                        style: AppTextStyles.caption)),
                Text(CurrencyFormatter.format(total.toDouble()),
                    style: AppTextStyles.bodyBold.copyWith(color: cs.primary)),
              ],
            ),
          ),
        Expanded(
          child: members.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.payments_outlined,
                  title: 'Aucun employé',
                  subtitle: 'Ajoutez votre équipe pour préparer la paie.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    for (final m in members)
                      _PayrollRow(
                        member: m,
                        month: _monthKey,
                        slip: StaffService.payslipFor(
                            widget.shopId, m.id, _monthKey),
                        pendingAdvances: StaffService.pendingAdvances(
                            widget.shopId, m.id, _monthKey),
                        minutes: StaffService.minutesInMonth(
                            widget.shopId, m.id, _monthKey),
                        overtime: StaffService.pendingOvertime(
                            widget.shopId, m.id, _monthKey),
                        penalty: StaffService.penaltyDueFor(
                            widget.shopId, m.id, _monthKey),
                        absence:
                            StaffService.absenceDueFor(m, _monthKey).amount,
                        onGenerate: () => _generate(m),
                        onOpen: (slip) => _openSlip(m, slip),
                        onMoney: () => _moneyActions(m),
                      ),
                    const SizedBox(height: 12),
                    const Text('Avances et quinzaines',
                        style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    ..._advancesSection(sem),
                    const SizedBox(height: 16),
                    const Text('Casse imputée', style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    ..._penaltiesSection(sem),
                    const SizedBox(height: 16),
                    const Text('Mises à pied et congés',
                        style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    ..._absencesSection(sem),
                  ],
                ),
        ),
      ],
    );
  }

  /// Les avances du mois affiché, versées à qui et retenues ou non.
  ///
  /// Une avance déjà retenue reste visible (en vert) : c'est la trace de ce
  /// qui a été déduit sur la fiche, et la première chose qu'un employé
  /// conteste.
  List<Widget> _advancesSection(AppSemanticColors sem) {
    final list = StaffService.advances(widget.shopId, month: _monthKey);
    if (list.isEmpty) {
      return [
        Text('Aucune avance versée sur ce mois.',
            style: AppTextStyles.captionHint),
      ];
    }
    return [
      for (final a in list)
        _Row(
          onTap: () => _advanceActions(a),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.employeeName ?? 'Employé',
                      style: AppTextStyles.bodySmBold),
                  Text(
                      [
                        _dayLabel(a.advanceDate),
                        if (a.isFortnight) 'quinzaine',
                        if ((a.reason ?? '').isNotEmpty) a.reason!,
                        if (a.isDeducted) 'retenue',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ],
              ),
            ),
            Text(CurrencyFormatter.format(a.amount.toDouble()),
                style: AppTextStyles.bodySmBold.copyWith(
                    color: a.isDeducted ? sem.success : sem.warning)),
          ]),
        ),
    ];
  }

  Future<void> _addAdvance(StaffMember m) async {
    final amount = TextEditingController();
    final reason = TextEditingController();
    final value = await showAdaptiveFormSheet<int>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Avance sur salaire',
        subtitle: m.fullName,
        icon: Icons.request_quote_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                'Elle sera retenue automatiquement sur la paie de '
                '${_monthLabel(_month)}. Contrairement à la quinzaine, une '
                'avance se motive.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Montant'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: reason,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Motif *',
                  hintText: 'Frais de santé, transport…'),
            ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Enregistrer l\'avance',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(sheetCtx)
                  .pop(int.tryParse(amount.text.trim()) ?? 0),
            ),
          ]),
        ),
      ),
    );
    if (value == null || value <= 0 || !mounted) return;
    // Le motif est exigé ici et NULLE PART pour la quinzaine : c'est toute la
    // différence entre une faveur et un droit. Sans lui, plus rien ne
    // distingue les deux au moment de relire le mois.
    if (reason.text.trim().isEmpty) {
      AppSnack.info(context,
          'Indiquez le motif de l\'avance. Sans motif, versez plutôt la '
          'quinzaine.');
      return;
    }
    await StaffService.recordAdvance(
      member: m,
      amount: value,
      reason: reason.text.trim(),
      month: _monthKey,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Avance enregistrée.');
  }

  /// Les trois mouvements d'argent possibles sur un employé, réunis derrière
  /// un seul bouton : la quinzaine (un droit), l'avance (une faveur motivée)
  /// et la casse (une dette). Trois icônes séparées sur chaque ligne auraient
  /// rendu la liste illisible sur un téléphone.
  Future<void> _moneyActions(StaffMember m) async {
    final taken =
        StaffService.fortnightTaken(widget.shopId, m.id, _monthKey);
    final cap = SalaryAdvance.fortnightCap(m.baseSalary);
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: m.fullName,
        subtitle: _monthLabel(_month),
        icon: Icons.account_balance_wallet_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.event_repeat_outlined),
              title: const Text('Verser la quinzaine'),
              subtitle: Text(cap <= 0
                  ? 'Aucun salaire de base renseigné'
                  : taken >= cap
                      ? 'Déjà touchée ce mois-ci '
                          '(${CurrencyFormatter.format(taken.toDouble())})'
                      : 'Jusqu\'à '
                          '${CurrencyFormatter.format((cap - taken).toDouble())}'
                          ', sans justification'),
              enabled: cap > 0 && taken < cap,
              onTap: () => Navigator.of(sheetCtx).pop('fortnight'),
            ),
            ListTile(
              leading: const Icon(Icons.request_quote_outlined),
              title: const Text('Avance sur salaire'),
              subtitle: const Text('À tout moment, avec un motif'),
              onTap: () => Navigator.of(sheetCtx).pop('advance'),
            ),
            ListTile(
              leading: const Icon(Icons.report_gmailerrorred_outlined),
              title: const Text('Imputer une casse'),
              subtitle: const Text('Un bien détruit par imprudence'),
              onTap: () => Navigator.of(sheetCtx).pop('penalty'),
            ),
          ]),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'fortnight':
        await _addFortnight(m);
        return;
      case 'advance':
        await _addAdvance(m);
        return;
      case 'penalty':
        await _addPenalty(m);
        return;
    }
  }

  /// LA QUINZAINE — la moitié du salaire, sans avoir à se justifier.
  ///
  /// Le seul contrôle est celui du FONDS : l'espèce réellement disponible dans
  /// le tiroir. Verser une quinzaine que la caisse ne contient pas, c'est
  /// découvrir le trou le soir à la clôture, quand il est trop tard pour
  /// arbitrer entre l'employé et le fournisseur.
  Future<void> _addFortnight(StaffMember m) async {
    final taken =
        StaffService.fortnightTaken(widget.shopId, m.id, _monthKey);
    final cap = SalaryAdvance.fortnightCap(m.baseSalary);
    final left = cap - taken;
    final cash = CashClosureService.systemCash(widget.shopId);
    final amount = TextEditingController(text: '$left');

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Quinzaine',
        subtitle: m.fullName,
        icon: Icons.event_repeat_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  'Aucun motif n\'est demandé : c\'est un droit. Elle sera '
                  'retenue sur la paie de ${_monthLabel(_month)}.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 10),
              _kv('Salaire de base', m.baseSalary),
              _kv('Plafond de la quinzaine', cap),
              if (taken > 0) _kv('Déjà touché ce mois', taken),
              const Divider(height: 18),
              Row(children: [
                const Expanded(
                    child: Text('Espèces en caisse',
                        style: AppTextStyles.bodySm)),
                Text(CurrencyFormatter.format(cash.toDouble()),
                    style: AppTextStyles.bodySmBold.copyWith(
                        color: cash < left
                            ? Theme.of(sheetCtx).semantic.warning
                            : Theme.of(sheetCtx).semantic.success)),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Montant versé'),
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Verser',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(sheetCtx).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final value = int.tryParse(amount.text.trim()) ?? 0;
    if (value <= 0) return;
    if (value > left) {
      AppSnack.info(
          context,
          'Au-delà de '
          '${CurrencyFormatter.format(left.toDouble())}, ce n\'est plus une '
          'quinzaine : passez par une avance sur salaire.');
      return;
    }
    if (value > cash) {
      AppSnack.info(
          context,
          'La caisse ne contient que '
          '${CurrencyFormatter.format(cash.toDouble())}. '
          'Réapprovisionnez-la, ou versez une avance plus petite.');
      return;
    }
    await StaffService.recordFortnight(
        member: m, amount: value, month: _monthKey);
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Quinzaine versée.');
  }

  /// CASSE IMPUTÉE — le montant du bien, et la façon de le récupérer.
  Future<void> _addPenalty(StaffMember m) async {
    final item = TextEditingController();
    final amount = TextEditingController();
    final reason = TextEditingController();
    var mode = PenaltyMode.oneShot;
    var percent = 25;

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final value = int.tryParse(amount.text.trim()) ?? 0;
          final preview = StaffPenalty(
            id: '_', shopId: widget.shopId, employeeId: m.id,
            itemLabel: '', amount: value, mode: mode,
            percentPerMonth: percent, startMonth: _monthKey, reason: '',
            incidentDate: DateTime.now(), createdAt: DateTime.now(),
          );
          return AdaptiveFormFrame(
            title: 'Imputer une casse',
            subtitle: m.fullName,
            icon: Icons.report_gmailerrorred_outlined,
            body: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: item,
                    autofocus: true,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                        labelText: 'Bien détruit *',
                        hintText: 'Blender, vitre du frigo…'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setSheet(() {}),
                    decoration: const InputDecoration(
                        labelText: 'Valeur du bien *'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: reason,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Circonstances *',
                      hintText: 'A fait tomber le blender en le rinçant',
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('Comment récupérer la somme ?',
                      style: AppTextStyles.label),
                  const SizedBox(height: 6),
                  for (final m2 in PenaltyMode.values)
                    RadioListTile<PenaltyMode>(
                      value: m2,
                      groupValue: mode,
                      onChanged: (v) => setSheet(() => mode = v ?? mode),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(m2.label, style: AppTextStyles.bodySm),
                    ),
                  if (mode == PenaltyMode.installments) ...[
                    Row(children: [
                      Expanded(
                        child: Text('$percent % du montant par mois',
                            style: AppTextStyles.bodySm),
                      ),
                      Text(
                          value <= 0
                              ? ''
                              : '${preview.monthsNeeded} mois × '
                                  '${CurrencyFormatter.format(preview.monthlyShare.toDouble())}',
                          style: AppTextStyles.caption),
                    ]),
                    Slider(
                      value: percent.toDouble(),
                      min: 5,
                      max: 100,
                      divisions: 19,
                      label: '$percent %',
                      onChanged: (v) => setSheet(() => percent = v.round()),
                    ),
                  ],
                  if (mode == PenaltyMode.cashRepaid)
                    Text(
                        'Le salaire ne sera JAMAIS touché. La casse reste '
                        'inscrite comme trace de l\'incident.',
                        style: AppTextStyles.captionHint),
                  const SizedBox(height: 14),
                  AppPrimaryButton(
                    label: 'Enregistrer',
                    icon: Icons.check_rounded,
                    fullWidth: true,
                    onTap: () => Navigator.of(sheetCtx).pop(true),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;

    final value = int.tryParse(amount.text.trim()) ?? 0;
    if (item.text.trim().isEmpty || value <= 0) {
      AppSnack.info(context, 'Indiquez le bien et sa valeur.');
      return;
    }
    if (reason.text.trim().isEmpty) {
      AppSnack.info(
          context,
          'Les circonstances sont obligatoires : sans elles, la retenue est '
          'indéfendable le jour où elle est contestée.');
      return;
    }
    await StaffService.recordPenalty(
      member: m,
      itemLabel: item.text,
      amount: value,
      reason: reason.text,
      mode: mode,
      percentPerMonth: percent,
      startMonth: _monthKey,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(
        context,
        mode == PenaltyMode.cashRepaid
            ? 'Casse enregistrée — salaire non impacté.'
            : 'Casse enregistrée, retenue à la prochaine paie.');
  }

  /// Les casses en cours de récupération, et celles déjà soldées du mois.
  List<Widget> _penaltiesSection(AppSemanticColors sem) {
    final list = StaffService.penalties(widget.shopId);
    if (list.isEmpty) {
      return [
        Text('Aucune casse imputée.', style: AppTextStyles.captionHint),
      ];
    }
    return [
      for (final p in list)
        _Row(
          onTap: () => _penaltyActions(p),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${p.employeeName ?? 'Employé'} · ${p.itemLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmBold),
                  Text(
                      [
                        _dayLabel(p.incidentDate),
                        p.mode.label,
                        if (p.isSettled)
                          'soldée'
                        else
                          'reste ${CurrencyFormatter.format(p.remaining.toDouble())}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ],
              ),
            ),
            Text(CurrencyFormatter.format(p.amount.toDouble()),
                style: AppTextStyles.bodySmBold.copyWith(
                    color: p.isSettled ? sem.success : sem.warning)),
          ]),
        ),
    ];
  }

  /// Les mises à pied et congés, la plus récente en tête.
  ///
  /// Les LEVÉES restent affichées, barrées d'un libellé : « la mise à pied a
  /// été levée » est une information, la faire disparaître laisserait croire
  /// qu'elle n'a jamais eu lieu.
  List<Widget> _absencesSection(AppSemanticColors sem) {
    final list = StaffService.absences(widget.shopId);
    if (list.isEmpty) {
      return [
        Text('Aucune mise à pied ni congé enregistré.',
            style: AppTextStyles.captionHint),
      ];
    }
    return [
      for (final a in list.take(20))
        _Row(
          onTap: () => _absenceActions(a),
          child: Row(children: [
            Icon(
                a.kind == AbsenceKind.suspension
                    ? Icons.gavel_rounded
                    : Icons.beach_access_rounded,
                size: 16,
                color: a.isCancelled
                    ? Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.35)
                    : (a.hitsPayroll ? sem.warning : sem.success)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${a.employeeName ?? 'Employé'} · ${a.kind.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmBold),
                  Text(
                      [
                        '${_dayLabel(a.startDate)} → ${_dayLabel(a.endDate)}',
                        '${a.days} j',
                        if (a.isCancelled)
                          'levée'
                        else if (a.isPaid)
                          'payée'
                        else
                          'sans solde',
                        a.reason,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ],
              ),
            ),
            if (a.amountDeducted > 0)
              Text('−${CurrencyFormatter.format(a.amountDeducted.toDouble())}',
                  style:
                      AppTextStyles.bodySmBold.copyWith(color: sem.warning)),
          ]),
        ),
    ];
  }

  Future<void> _absenceActions(StaffAbsence a) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: a.kind.label,
        subtitle: a.employeeName ?? 'Employé',
        icon: a.kind == AbsenceKind.suspension
            ? Icons.gavel_rounded
            : Icons.beach_access_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${_dayLabel(a.startDate)} → ${_dayLabel(a.endDate)} · '
                  '${a.days} jour${a.days > 1 ? 's' : ''}',
                  style: AppTextStyles.bodySm),
              const SizedBox(height: 6),
              Text('« ${a.reason} »', style: AppTextStyles.bodySm),
              const SizedBox(height: 6),
              Text(
                  a.isCancelled
                      ? 'Levée le ${_dayLabel(a.cancelledAt!)}'
                      : a.hitsPayroll
                          ? a.amountDeducted > 0
                              ? 'Déjà retenu : '
                                  '${CurrencyFormatter.format(a.amountDeducted.toDouble())}'
                              : 'Sans solde — la retenue sera portée sur la '
                                  'prochaine fiche de paie.'
                          : 'Salaire maintenu, rien n\'est retenu.',
                  style: AppTextStyles.caption),
              const SizedBox(height: 16),
              if (!a.isCancelled)
                AppPrimaryButton(
                  label: 'Lever cette décision',
                  icon: Icons.undo_rounded,
                  fullWidth: true,
                  onTap: () => Navigator.of(sheetCtx).pop('lift'),
                ),
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(sheetCtx).pop('delete'),
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: Theme.of(sheetCtx).semantic.danger),
                  label: Text('Supprimer la ligne',
                      style: AppTextStyles.label.copyWith(
                          color: Theme.of(sheetCtx).semantic.danger)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'lift') {
      await StaffService.cancelAbsence(a);
      if (!mounted) return;
      setState(() {});
      AppSnack.success(context, 'Décision levée.');
      return;
    }
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette ligne ?',
      body: Text(a.amountDeducted > 0
          ? 'Une retenue de '
              '${CurrencyFormatter.format(a.amountDeducted.toDouble())} a déjà '
              'été portée sur une fiche de paie. Elle ne sera PAS rendue.'
          : 'La décision disparaît de l\'historique.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.deleteAbsence(a);
    if (mounted) setState(() {});
  }

  Future<void> _penaltyActions(StaffPenalty p) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette imputation ?',
      body: Text(
          '${p.itemLabel} · ${CurrencyFormatter.format(p.amount.toDouble())}\n'
          '${p.reason}\n\n'
          '${p.amountRecovered > 0 ? 'Déjà récupéré : '
              '${CurrencyFormatter.format(p.amountRecovered.toDouble())}. '
              'Ce montant ne sera PAS rendu automatiquement.' : ''}'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.deletePenalty(p);
    if (mounted) setState(() {});
  }

  Future<void> _advanceActions(SalaryAdvance a) async {
    if (a.isDeducted) {
      AppSnack.info(
          context,
          'Cette avance a déjà été retenue sur une fiche de paie. '
          'Supprimez la fiche pour la libérer.');
      return;
    }
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette avance ?',
      body: Text('${a.employeeName ?? 'Employé'} · '
          '${CurrencyFormatter.format(a.amount.toDouble())}'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.deleteAdvance(a);
    if (mounted) setState(() {});
  }

  Future<void> _generate(StaffMember m) async {
    final bonuses = TextEditingController();
    final deductions = TextEditingController();
    final advances =
        StaffService.pendingAdvances(widget.shopId, m.id, _monthKey);
    final minutes =
        StaffService.minutesInMonth(widget.shopId, m.id, _monthKey);
    final overtime =
        StaffService.pendingOvertime(widget.shopId, m.id, _monthKey);
    final penalty =
        StaffService.penaltyDueFor(widget.shopId, m.id, _monthKey);
    final absence = StaffService.absenceDueFor(m, _monthKey);
    // Départs anticipés non justifiés du mois : SIGNALÉS, jamais retenus. Le
    // gérant en fait ce qu'il veut dans le champ « retenues » — c'est lui qui
    // connaît le contexte, pas l'application.
    final unexcused = StaffService.timeRecords(widget.shopId,
            employeeId: m.id)
        .where((r) =>
            r.isUnexcused &&
            SalaryAdvance.monthKey(
                    r.clockOut ?? r.clockIn ?? r.createdAt) ==
                _monthKey)
        .length;

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final net = Payslip.computeNet(
            baseSalary: m.baseSalary,
            bonuses: int.tryParse(bonuses.text.trim()) ?? 0,
            deductions: int.tryParse(deductions.text.trim()) ?? 0,
            advances: advances,
            overtime: overtime.amount,
            penalties: penalty,
            absences: absence.amount,
          );
          return AdaptiveFormFrame(
            title: 'Paie ${_monthLabel(_month)}',
            subtitle: m.fullName,
            icon: Icons.payments_outlined,
            body: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _kv('Salaire de base', m.baseSalary),
                  if (minutes > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        Expanded(
                            child: Text('Heures pointées',
                                style: AppTextStyles.captionHint)),
                        Text(TimeRecord.formatMinutes(minutes),
                            style: AppTextStyles.caption),
                      ]),
                    ),
                  if (overtime.amount > 0)
                    _kv(
                        'Heures supplémentaires '
                        '(${TimeRecord.formatMinutes(overtime.minutes)})',
                        overtime.amount),
                  if (penalty > 0) _kv('Casse imputée', -penalty),
                  if (absence.amount > 0)
                    _kv(
                        'Mise à pied (${absence.days} jour'
                        '${absence.days > 1 ? 's' : ''})',
                        -absence.amount),
                  if (advances > 0) _kv('Avances et quinzaines', -advances),
                  if (unexcused > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(children: [
                        Icon(Icons.info_outline_rounded,
                            size: 14,
                            color: Theme.of(ctx).semantic.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                              '$unexcused départ${unexcused > 1 ? 's' : ''} '
                              'anticipé${unexcused > 1 ? 's' : ''} non '
                              'justifié${unexcused > 1 ? 's' : ''} ce mois-ci. '
                              'À vous de décider d\'une retenue.',
                              style: AppTextStyles.micro.copyWith(
                                  color: Theme.of(ctx).semantic.warning)),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: bonuses,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setSheet(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Primes / heures supplémentaires',
                      hintText: '0',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: deductions,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setSheet(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Retenues (retards, casse…)',
                      hintText: '0',
                    ),
                  ),
                  const SizedBox(height: 10),
                  _kv('Avances déjà versées', -advances),
                  const Divider(height: 20),
                  Row(children: [
                    const Expanded(
                        child: Text('Net à payer',
                            style: AppTextStyles.bodyBold)),
                    Text(CurrencyFormatter.format(net.toDouble()),
                        style: AppTextStyles.subtitleBold),
                  ]),
                  const SizedBox(height: 18),
                  AppPrimaryButton(
                    label: 'Générer la fiche',
                    icon: Icons.check_rounded,
                    fullWidth: true,
                    onTap: () => Navigator.of(sheetCtx).pop(true),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;

    await StaffService.generatePayslip(
      member: m,
      month: _monthKey,
      bonuses: int.tryParse(bonuses.text.trim()) ?? 0,
      deductions: int.tryParse(deductions.text.trim()) ?? 0,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Fiche de paie générée.');
  }

  Future<void> _openSlip(StaffMember m, Payslip slip) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Fiche ${_monthLabel(_month)}',
        subtitle: m.fullName,
        icon: Icons.receipt_long_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _kv('Salaire de base', slip.baseSalary),
              if (slip.bonuses > 0) _kv('Primes', slip.bonuses),
              // Les heures supplémentaires portent leur MENTION : sans le
              // nombre d'heures à côté du montant, la ligne est invérifiable —
              // et c'est la première que l'employé conteste.
              if (slip.overtimeAmount > 0)
                _kv(
                    'Heures supplémentaires '
                    '(${TimeRecord.formatMinutes(slip.overtimeMinutes)})',
                    slip.overtimeAmount),
              if (slip.deductions > 0) _kv('Retenues', -slip.deductions),
              if (slip.penaltiesDeducted > 0)
                _kv('Casse imputée', -slip.penaltiesDeducted),
              if (slip.absencesDeducted > 0)
                _kv(
                    'Mise à pied (${slip.absenceDays} jour'
                    '${slip.absenceDays > 1 ? 's' : ''})',
                    -slip.absencesDeducted),
              if (slip.advancesDeducted > 0)
                _kv('Avances et quinzaines', -slip.advancesDeducted),
              if (slip.minutesWorked > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(
                        child: Text('Heures pointées',
                            style: AppTextStyles.captionHint)),
                    Text(TimeRecord.formatMinutes(slip.minutesWorked),
                        style: AppTextStyles.caption),
                  ]),
                ),
              const Divider(height: 20),
              Row(children: [
                const Expanded(
                    child:
                        Text('Net à payer', style: AppTextStyles.bodyBold)),
                Text(CurrencyFormatter.format(slip.netSalary.toDouble()),
                    style: AppTextStyles.subtitleBold),
              ]),
              const SizedBox(height: 18),
              if (!slip.isPaid)
                AppPrimaryButton(
                  label: 'Marquer comme payée',
                  icon: Icons.check_rounded,
                  fullWidth: true,
                  onTap: () => Navigator.of(sheetCtx).pop('paid'),
                )
              else
                Center(
                  child: Text('Payée le ${_dayLabel(slip.paidAt!)}',
                      style: AppTextStyles.caption),
                ),
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(sheetCtx).pop('delete'),
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: Theme.of(ctxOf(sheetCtx)).semantic.danger),
                  label: Text('Supprimer la fiche',
                      style: AppTextStyles.label.copyWith(
                          color: Theme.of(ctxOf(sheetCtx)).semantic.danger)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'paid') {
      await StaffService.markPaid(slip);
      if (!mounted) return;
      setState(() {});
      AppSnack.success(context, 'Fiche marquée payée.');
      return;
    }
    // Suppression : les avances retenues sont RENDUES, sinon elles seraient
    // perdues pour l'employé (marquées déduites sans fiche qui les porte).
    await StaffService.deletePayslip(slip);
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context,
        'Fiche supprimée : avances, heures supplémentaires et casse rendues.');
  }

  /// Petit helper pour lire le thème dans un builder imbriqué.
  BuildContext ctxOf(BuildContext c) => c;

  static Widget _kv(String label, int amount) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label, style: AppTextStyles.bodySm)),
          Text(CurrencyFormatter.format(amount.toDouble()),
              style: AppTextStyles.bodySmBold),
        ]),
      );

  static String _monthLabel(DateTime d) {
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }

  static String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Une ligne d'employé dans l'onglet Paie.
class _PayrollRow extends StatelessWidget {
  final StaffMember member;
  final String month;
  final Payslip? slip;
  final int pendingAdvances;
  final int minutes;

  /// Heures supplémentaires reportées sur la paie de ce mois, pas encore
  /// portées sur une fiche.
  final ({int minutes, int amount}) overtime;

  /// Retenue pour casse due ce mois.
  final int penalty;

  /// Retenue pour mise à pied sans solde due ce mois.
  final int absence;

  final VoidCallback onGenerate;
  final ValueChanged<Payslip> onOpen;
  final VoidCallback onMoney;

  const _PayrollRow({
    required this.member,
    required this.month,
    required this.slip,
    required this.pendingAdvances,
    required this.minutes,
    required this.overtime,
    required this.penalty,
    required this.absence,
    required this.onGenerate,
    required this.onOpen,
    required this.onMoney,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final s = slip;
    return _Row(
      onTap: () => s == null ? onGenerate() : onOpen(s),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(member.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
              Text(
                  [
                    CurrencyFormatter.format(member.baseSalary.toDouble()),
                    if (minutes > 0) TimeRecord.formatMinutes(minutes),
                    if (pendingAdvances > 0)
                      'avances ${CurrencyFormatter.format(pendingAdvances.toDouble())}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption),
              // Ce qui s'ajoutera ou se retirera automatiquement à la
              // génération : le gérant doit le voir AVANT de générer, pas le
              // découvrir sur la fiche.
              if (overtime.amount > 0 || penalty > 0 || absence > 0)
                Text(
                    [
                      if (overtime.amount > 0)
                        '+${CurrencyFormatter.format(overtime.amount.toDouble())} '
                            'heures sup',
                      if (penalty > 0)
                        '−${CurrencyFormatter.format(penalty.toDouble())} casse',
                      if (absence > 0)
                        '−${CurrencyFormatter.format(absence.toDouble())} '
                            'mise à pied',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.micro.copyWith(
                        color: (penalty > 0 || absence > 0)
                            ? sem.warning
                            : sem.success)),
            ],
          ),
        ),
        IconButton(
          onPressed: onMoney,
          icon: const Icon(Icons.account_balance_wallet_outlined, size: 20),
          tooltip: 'Quinzaine, avance, casse',
        ),
        if (s == null)
          Text('à générer',
              style: AppTextStyles.caption.copyWith(color: sem.warning))
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(CurrencyFormatter.format(s.netSalary.toDouble()),
                  style: AppTextStyles.bodySmBold),
              Text(s.isPaid ? 'payée' : 'à payer',
                  style: AppTextStyles.micro.copyWith(
                      color: s.isPaid ? sem.success : sem.warning)),
            ],
          ),
      ]),
    );
  }
}

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
