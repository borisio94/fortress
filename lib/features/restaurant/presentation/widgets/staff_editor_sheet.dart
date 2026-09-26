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

// La FICHE d'un membre du personnel : création, modification, décisions
// (mise à pied, congé, archivage, suppression).
//
// Sortie de `restaurant_staff_page.dart` (onglet Équipe, où elle était une
// classe privée) le 26/09/2026, lot « classes géantes » : comme l'onglet Paie,
// elle ne se montait pas en test. Ses trois aides (`_DayField`,
// `_ReadOnlyField`, `_AccountPicker`) ne servaient qu'à elle et l'ont suivie.

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
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
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
                        foregroundColor: sem.warningText),
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
                            AppTextStyles.label.copyWith(color: sem.warningText)),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: _delete,
                    icon: Icon(Icons.delete_forever_rounded,
                        size: 18, color: sem.danger),
                    label: Text('Supprimer',
                        style:
                            AppTextStyles.label.copyWith(color: sem.dangerText)),
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
