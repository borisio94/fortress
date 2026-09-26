import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/staff_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_select_menu.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../hr/data/providers/employees_provider.dart';
import '../../../hr/domain/models/employee.dart';
import '../../../hr/domain/models/job_titles.dart';
import '../../domain/entities/shift_evaluation.dart';
import '../../domain/entities/staff_absence.dart';
import '../../domain/entities/staff_member.dart';
import '../../domain/staff_account_link.dart';

part 'staff_editor_sheet.decisions.dart';
part 'staff_editor_sheet.sections.dart';

// La FICHE d'un membre du personnel : création, modification, décisions
// (mise à pied, congé, archivage, suppression).
//
// Sortie de `restaurant_staff_page.dart` (onglet Équipe, où elle était une
// classe privée) le 26/09/2026, lot « classes géantes » : comme l'onglet Paie,
// elle ne se montait pas en test. Ses trois aides (`_DayField`,
// `_ReadOnlyField`, `_AccountPicker`) ne servaient qu'à elle et l'ont suivie.
//
// Découpée le même jour : ce fichier garde la fiche, ses données et ses
// décisions (refus, écritures, messages) ; les feuilles de décision vivent
// dans `staff_editor_sheet.decisions.dart`, les sections et les aides dans
// `staff_editor_sheet.sections.dart`.

/// Création / modification d'une fiche : identité, salaire, code de pointage.
class StaffEditorSheet extends StatefulWidget {
  final String shopId;
  final StaffMember? existing;
  const StaffEditorSheet({super.key, required this.shopId, this.existing});
  @override
  State<StaffEditorSheet> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<StaffEditorSheet> {
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

  /// MISE À PIED ou CONGÉ PAYÉ : la feuille (`_AbsenceSheet`) rend les dates,
  /// le motif et le solde ; le motif est exigé ici.
  Future<void> _absence(AbsenceKind kind) async {
    final m = widget.existing!;
    final input = await showAdaptiveFormSheet<_AbsenceInput>(
      context: context,
      builder: (_) =>
          _AbsenceSheet(member: m, shopId: widget.shopId, kind: kind),
    );
    if (input == null || !mounted) return;
    if (input.reason.trim().isEmpty) {
      AppSnack.info(context,
          'Le motif est obligatoire : sans lui, la décision est '
          'indéfendable le jour où elle est contestée.');
      return;
    }
    await StaffService.recordAbsence(
      member: m,
      kind: kind,
      startDate: input.start,
      endDate: input.end,
      reason: input.reason,
      isPaid: input.isPaid,
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

  /// SUPPRESSION DÉFINITIVE — la feuille (`_DeleteSheet`) dit ce qui reste et
  /// rend le motif ; il est exigé ici.
  Future<void> _delete() async {
    final m = widget.existing!;
    final reason = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (_) => _DeleteSheet(member: m),
    );
    if (reason == null || !mounted) return;
    if (reason.trim().isEmpty) {
      AppSnack.info(context,
          'Le motif est obligatoire : une fois la fiche partie, il sera la '
          'seule trace de ce qui a disparu.');
      return;
    }
    await StaffService.deleteMemberWithReason(m, reason);
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
            // ACCÈS À L'APPLICATION — la question qui commande tout le reste
            // (`_AccessModeChoice`), posée à la création seulement.
            if (!_isEdit)
              _AccessModeChoice(
                hasAccount: _hasAccount,
                onChanged: (v) => setState(() {
                  _hasAccount = v;
                  // Le nom et la fonction viennent de deux sources
                  // différentes selon le mode : les garder d'un mode à
                  // l'autre laisserait le nom d'un compte sur une fiche
                  // « sans compte ».
                  _name.clear();
                  _role.clear();
                  _err = null;
                }),
              ),

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
            // HORAIRE PARTICULIER (`_ClosingField`).
            _ClosingField(
              closing: _closing,
              onPick: _pickClosing,
              onClear: () => setState(() => _closing = null),
            ),
            const SizedBox(height: 14),
            _PinField(
              controller: _pin,
              hasPin: m?.hasPin == true,
              onClear: () async {
                await StaffService.clearPin(m!);
                if (context.mounted) Navigator.of(context).pop(true);
              },
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: _isEdit ? 'Enregistrer' : 'Créer',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _save,
            ),
            if (_isEdit)
              _DecisionsPanel(
                member: m!,
                liveAbsence: _liveAbsence,
                onLift: _liftAbsence,
                onAbsence: _absence,
                onArchive: _archive,
                onDelete: _delete,
              ),
          ],
        ),
      ),
    );
  }
}
