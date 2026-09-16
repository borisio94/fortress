import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
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
import '../../../hr/data/providers/employees_provider.dart';
import '../../../hr/domain/models/employee.dart';
import '../../domain/entities/payslip.dart';
import '../../domain/entities/salary_advance.dart';
import '../../domain/entities/staff_member.dart';
import '../../domain/entities/time_record.dart';
import '../widgets/resto_empty_state.dart';
import '../widgets/resto_surfaces.dart';

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
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
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
        length: 3,
        child: Column(
          children: [
            Material(
              color: restoGlassFill(context),
              child: TabBar(
                labelColor: cs.primary,
                unselectedLabelColor: cs.onSurface.withValues(alpha: 0.6),
                indicatorColor: cs.primary,
                labelStyle: AppTextStyles.label,
                tabs: const [
                  Tab(text: 'Équipe'),
                  Tab(text: 'Pointage'),
                  Tab(text: 'Paie'),
                ],
              ),
            ),
            Divider(height: 1, color: sem.borderSubtle),
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Base commune : rafraîchit l'onglet quand la table écoutée change.
abstract class _StaffTabState<T extends StatefulWidget> extends State<T> {
  late final OnDataChanged _listener;

  /// Tables Supabase à écouter.
  List<String> get tables;
  String get shopId;

  @override
  void initState() {
    super.initState();
    _listener = (t, sid) {
      if (!mounted) return;
      if (!tables.contains(t)) return;
      if (sid != shopId && sid != '_all') return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }
}

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
  List<String> get tables => const ['employees'];
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                    'Masse salariale de base : '
                    '${CurrencyFormatter.format(payroll.toDouble())}',
                    style: AppTextStyles.caption),
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
                                    if (!m.isActive) 'archivé',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.caption),
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

  bool get _isEdit => widget.existing != null;

  /// Noms déjà inscrits au personnel, en minuscules — sert à retirer de la
  /// liste les comptes qui ont déjà leur fiche. Le rapprochement se fait sur
  /// le NOM faute de lien stocké entre les deux notions : c'est imparfait
  /// (deux homonymes seraient confondus) mais c'est exactement ce que la
  /// sélection vient supprimer comme risque, puisque le nom ne se tape plus.
  late final Set<String> _alreadyStaffNames = {
    for (final s in StaffService.forShop(widget.shopId))
      if (s.id != widget.existing?.id) s.fullName.trim().toLowerCase(),
  };

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

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      // Le nom ne se tape plus : il vient du compte choisi. Un nom vide veut
      // donc dire « aucune personne sélectionnée ».
      setState(() => _err = _isEdit
          ? 'Nom requis'
          : 'Choisissez la personne parmi les comptes de la boutique.');
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
    if (pin.isNotEmpty &&
        StaffService.isPinTaken(widget.shopId, pin,
            exceptId: widget.existing?.id)) {
      setState(() => _err = 'Ce code est déjà utilisé par un autre employé');
      return;
    }

    var member = _isEdit
        ? widget.existing!.copyWith(
            fullName: name,
            role: _role.text.trim(),
            station: _station.text.trim(),
            baseSalary: int.tryParse(_salary.text.trim()) ?? 0,
            phone: _phone.text.trim(),
          )
        : await StaffService.createMember(
            shopId: widget.shopId,
            fullName: name,
            role: _role.text.trim(),
            station: _station.text.trim(),
            baseSalary: int.tryParse(_salary.text.trim()) ?? 0,
            phone: _phone.text.trim(),
          );
    if (_isEdit) await StaffService.saveMember(member);
    if (pin.isNotEmpty) {
      member = await StaffService.setPin(member, pin) ?? member;
    }
    if (mounted) Navigator.of(context).pop(true);
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
            // IDENTITÉ — choisie, plus saisie.
            //
            // À la création, la personne est prise parmi les comptes « Accès à
            // l'app » de la boutique : la saisir une seconde fois au clavier
            // faisait diverger les deux listes (« Awa Ndiaye » ici, « Awa
            // ndiaye » là) et interdisait tout rapprochement.
            //
            // En modification, le nom est figé : c'est le compte qui le porte.
            if (_isEdit)
              _ReadOnlyField(label: 'Nom complet', value: m!.fullName)
            else
              _AccountPicker(
                shopId: widget.shopId,
                selected: _name.text,
                taken: _alreadyStaffNames,
                onSelect: (name, jobTitle) => setState(() {
                  _name.text = name;
                  _role.text = jobTitle;
                }),
              ),
            const SizedBox(height: 10),
            // FONCTION — HÉRITÉE du compte, plus choisie ici.
            //
            // Elle est saisie une seule fois, à la création du compte
            // (`shop_memberships.job_title`, hotfix_159), et recopiée sur la
            // fiche au moment de la sélection. La choisir une seconde fois
            // laissait les deux valeurs diverger, sans qu'aucune ne fasse
            // autorité.
            //
            // Recopiée et non lue à la volée : `StaffMember.role` alimente la
            // feuille d'assignation d'un livreur et les états de paie, qui
            // doivent rester stables même si le compte est modifié ou supprimé
            // plus tard.
            _ReadOnlyField(
                label: 'Fonction',
                value: _role.text.isEmpty
                    ? 'Aucune — à définir sur le compte'
                    : _role.text),
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
              decoration: const InputDecoration(labelText: 'Téléphone'),
            ),
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
              const SizedBox(height: 6),
              Center(
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
                    return _Row(
                      onTap: () => _recordActions(r),
                      child: Row(children: [
                        Icon(
                            r.isOpen
                                ? Icons.play_circle_outline_rounded
                                : Icons.check_circle_outline_rounded,
                            size: 18,
                            color: r.isOpen ? sem.warning : sem.success),
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

  Future<void> _recordActions(TimeRecord r) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer ce pointage ?',
      body: Text('${r.employeeName ?? 'Employé'} · '
          '${_stamp(r.clockIn)} → ${r.isOpen ? 'en cours' : _stamp(r.clockOut)}'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.deleteTimeRecord(r);
    if (mounted) setState(() {});
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
  List<String> get tables =>
      const ['payroll', 'salary_advances', 'employees', 'time_records'];
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
                        onGenerate: () => _generate(m),
                        onOpen: (slip) => _openSlip(m, slip),
                        onAdvance: () => _addAdvance(m),
                      ),
                    const SizedBox(height: 12),
                    const Text('Avances du mois', style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    ..._advancesSection(sem),
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
                      '${_dayLabel(a.advanceDate)}'
                      '${(a.reason ?? '').isEmpty ? '' : ' · ${a.reason}'}'
                      '${a.isDeducted ? ' · retenue' : ''}',
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
                '${_monthLabel(_month)}.',
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
                  labelText: 'Motif (optionnel)',
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
    await StaffService.recordAdvance(
      member: m,
      amount: value,
      reason: reason.text.trim().isEmpty ? null : reason.text.trim(),
      month: _monthKey,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Avance enregistrée.');
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

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final net = Payslip.computeNet(
            baseSalary: m.baseSalary,
            bonuses: int.tryParse(bonuses.text.trim()) ?? 0,
            deductions: int.tryParse(deductions.text.trim()) ?? 0,
            advances: advances,
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
              if (slip.deductions > 0) _kv('Retenues', -slip.deductions),
              if (slip.advancesDeducted > 0)
                _kv('Avances', -slip.advancesDeducted),
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
    AppSnack.success(context, 'Fiche supprimée, avances libérées.');
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
  final VoidCallback onGenerate;
  final ValueChanged<Payslip> onOpen;
  final VoidCallback onAdvance;

  const _PayrollRow({
    required this.member,
    required this.month,
    required this.slip,
    required this.pendingAdvances,
    required this.minutes,
    required this.onGenerate,
    required this.onOpen,
    required this.onAdvance,
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
            ],
          ),
        ),
        IconButton(
          onPressed: onAdvance,
          icon: const Icon(Icons.request_quote_outlined, size: 20),
          tooltip: 'Avance sur salaire',
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
  final Set<String> taken;
  /// `(nom, fonction)` — la fonction vient du compte et est recopiée sur
  /// la fiche : elle n'est plus choisie deux fois.
  final void Function(String name, String jobTitle) onSelect;

  const _AccountPicker({
    required this.shopId,
    required this.selected,
    required this.taken,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(employeesProvider(shopId));
    final all = async.valueOrNull ?? const <Employee>[];
    final names = [
      for (final e in all)
        if (e.fullName.trim().isNotEmpty &&
            !taken.contains(e.fullName.trim().toLowerCase()))
          e.fullName.trim(),
    ]..sort();
    // Retrouver la fonction du compte à partir du nom choisi : la liste
    // déroulante ne sait rendre qu'une chaîne.
    String titleFor(String name) {
      for (final e in all) {
        if (e.fullName.trim() == name) return e.jobTitle.trim();
      }
      return '';
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
      onChanged: (name) => onSelect(name, titleFor(name)),
    );
  }
}
