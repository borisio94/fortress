import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/manager_gate.dart';
import '../../../../core/services/staff_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/staff_absence.dart';
import '../../domain/entities/staff_member.dart';
import '../../domain/entities/time_record.dart';

/// Badgeuse — pointage du personnel par code à 4 chiffres (Lot D).
///
/// Conçue pour une tablette posée à l'entrée du personnel, en libre-service :
/// gros pavé numérique, aucune navigation, aucune donnée sensible à l'écran.
/// L'employé tape son code ; l'écran l'accueille ou lui souhaite bonne fin de
/// service, puis se réarme tout seul au bout de quelques secondes.
///
/// Le code n'ouvre AUCUN droit dans l'application : il identifie, il
/// n'autorise pas. C'est ce qui permet de le confier à toute l'équipe sans
/// exposer la caisse — les gestes sensibles restent derrière le PIN gérant
/// (cf. `ManagerGate`).
///
/// La spec prévoyait aussi un badge par QR code. Il n'est pas implémenté : la
/// lecture de QR demande une dépendance caméra (et les permissions qui vont
/// avec) que le projet n'embarque pas. Le PIN couvre le même besoin sur le même
/// appareil ; la saisie manuelle par le gérant rattrape les oublis.
class TimeclockPage extends StatefulWidget {
  final String shopId;

  const TimeclockPage({super.key, required this.shopId});

  @override
  State<TimeclockPage> createState() => _TimeclockPageState();
}

class _TimeclockPageState extends State<TimeclockPage> {
  final List<int> _digits = [];
  Timer? _resetTimer;
  Timer? _clock;

  /// Message affiché après un badge. Effacé automatiquement pour que la
  /// tablette soit toujours prête pour le suivant.
  String? _message;
  String? _detail;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    // Rafraîchit l'horloge affichée : sur une badgeuse, l'heure est
    // l'information de référence du personnel.
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  void _tap(int d) {
    if (_digits.length >= 4) return;
    setState(() {
      _digits.add(d);
      _message = null;
    });
    if (_digits.length == 4) _submit();
  }

  void _backspace() {
    if (_digits.isEmpty) return;
    setState(() => _digits.removeLast());
  }

  Future<void> _submit() async {
    final pin = _digits.join();
    final member = StaffService.findByPin(widget.shopId, pin);
    if (member == null) {
      _show('Code inconnu', 'Vérifiez votre code avec le gérant.',
          isError: true);
      return;
    }
    // MISE À PIED OU CONGÉ EN COURS — on refuse le badge, en disant pourquoi.
    //
    // Laisser pointer créerait des heures à quelqu'un qui n'est pas censé
    // travailler : un employé suspendu se ferait payer sa sanction, et
    // l'incohérence ne se découvrirait qu'à la paie, sans personne pour se
    // souvenir de ce qui s'était passé ce soir-là.
    final absence = StaffService.absenceOn(widget.shopId, member.id);
    if (absence != null) {
      _show('${absence.kind.label} en cours',
          '${_firstName(member)}, vous êtes absent jusqu\'au '
          '${_dayLabel(absence.endDate)}. Voyez le gérant.',
          isError: true);
      return;
    }

    final result = await StaffService.punch(member);
    if (!mounted) return;
    if (result.isEntry) {
      final end = result.record.scheduledEnd;
      _show('Bonjour ${_firstName(member)}',
          'Service commencé à ${_hhmm(result.record.clockIn)}'
          '${end == null ? '' : ' · fin prévue ${_hhmm(end)}'}');
      return;
    }

    final minutes = result.record.durationMinutes ?? 0;
    final verdict = result.verdict;

    // DÉPART ANTICIPÉ — l'excuse se demande ICI, à la personne concernée, au
    // moment où elle part. Reconstituée trois jours plus tard par le gérant,
    // elle ne vaudrait rien : personne ne se souvient de la raison exacte, et
    // c'est le souvenir du gérant qui ferait foi contre celui de l'employé.
    if (verdict.isEarly) {
      _show('À bientôt, ${_firstName(member)}',
          'Vous partez ${TimeRecord.formatMinutes(verdict.earlyMinutes)} '
          'avant la fermeture.');
      await _askExcuse(member, result.record, verdict.earlyMinutes);
      return;
    }

    if (verdict.isOvertime) {
      _show('Merci ${_firstName(member)}',
          '${TimeRecord.formatMinutes(minutes)} travaillées · '
          '${TimeRecord.formatMinutes(verdict.overtimeMinutes)} '
          'supplémentaires enregistrées');
      return;
    }

    _show('Bonne fin de service, ${_firstName(member)}',
        '${TimeRecord.formatMinutes(minutes)} travaillées aujourd\'hui');
  }

  /// Demande l'excuse du départ anticipé, sur la badgeuse elle-même.
  ///
  /// Facultative : on peut partir sans se justifier, et le pointage le dira.
  /// L'imposer ferait taper n'importe quoi pour se débarrasser de l'écran, ce
  /// qui vaut moins que rien du tout.
  Future<void> _askExcuse(
      StaffMember member, TimeRecord record, int earlyMinutes) async {
    final excuse = TextEditingController();
    final text = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Pourquoi partez-vous plus tôt ?',
        subtitle: '${member.fullName} · '
            '${TimeRecord.formatMinutes(earlyMinutes)} avant la fermeture',
        icon: Icons.logout_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  'Le gérant lira votre explication et dira s\'il l\'accepte. '
                  'Vous pouvez aussi passer sans rien écrire.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 12),
              TextField(
                controller: excuse,
                autofocus: true,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Votre explication',
                  hintText: 'Rendez-vous à l\'hôpital, enfant malade…',
                ),
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Envoyer',
                icon: Icons.send_rounded,
                fullWidth: true,
                onTap: () =>
                    Navigator.of(sheetCtx).pop(excuse.text.trim()),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(sheetCtx).pop(''),
                  child: const Text('Passer'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    await StaffService.attachExcuse(record, text);
    if (!mounted) return;
    _show('Explication transmise', 'Le gérant en sera informé.');
  }

  void _show(String message, String? detail, {bool isError = false}) {
    setState(() {
      _message = message;
      _detail = detail;
      _isError = isError;
      _digits.clear();
    });
    _resetTimer?.cancel();
    // Réarmement automatique : personne ne pense à effacer l'écran derrière
    // soi, et le suivant doit trouver la badgeuse prête.
    _resetTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _message = null);
    });
  }

  static String _firstName(StaffMember m) =>
      m.fullName.trim().split(' ').first;

  static String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';

  static String _hhmm(DateTime? d) {
    final t = d ?? DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  /// QUITTER LA BADGEUSE — sous PIN gérant (25/09/2026).
  ///
  /// La badgeuse tourne en libre-service sur le compte connecté : la quitter
  /// rend toute l'application à qui se trouve devant. C'était un simple
  /// `maybePop`, ouvert à n'importe qui. Désormais `ManagerGate` : le PIN s'il
  /// existe ; sinon le passage libre, journalisé — un gérant sans code ne doit
  /// jamais rester enfermé ici.
  ///
  /// Ouverte directement par son adresse, la page n'a rien sous elle : on
  /// ramène alors au Personnel, d'où elle s'ouvre (sinon la croix ne faisait
  /// rien et l'on restait bloqué).
  Future<void> _exit() async {
    final perms = ProviderScope.containerOf(context, listen: false)
        .read(permissionsProvider(widget.shopId));
    final ok = await ManagerGate.require(
      context: context,
      perms: perms,
      action: ManagerAction.exitTimeclock,
      shopId: widget.shopId,
      targetId: widget.shopId,
      targetLabel: 'Badgeuse',
    );
    if (!ok || !mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      context.go('/shop/${widget.shopId}/restaurant/personnel');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final onDuty = StaffService.onDuty(widget.shopId);

    return Scaffold(
      // Pas d'AppScaffold : la badgeuse ne doit donner accès à RIEN. Un seul
      // bouton de sortie, discret, pour le gérant.
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: _exit,
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Quitter la badgeuse',
                      ),
                      Expanded(
                        child: Text(_hhmm(DateTime.now()),
                            textAlign: TextAlign.center,
                            style: AppTextStyles.title),
                      ),
                      // Contrepoids visuel du bouton de fermeture.
                      const SizedBox(width: 48),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                      onDuty.isEmpty
                          ? 'Personne en service'
                          : '${onDuty.length} en service',
                      style: AppTextStyles.captionHint),
                  const SizedBox(height: 24),

                  if (_message != null) ...[
                    Icon(
                        _isError
                            ? Icons.error_outline_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 44,
                        color: _isError ? sem.danger : sem.success),
                    const SizedBox(height: 10),
                    Text(_message!,
                        textAlign: TextAlign.center,
                        style: AppTextStyles.subtitleBold.copyWith(
                            color: _isError ? sem.danger : sem.success)),
                    if (_detail != null) ...[
                      const SizedBox(height: 4),
                      Text(_detail!,
                          textAlign: TextAlign.center,
                          style: AppTextStyles.caption),
                    ],
                    const SizedBox(height: 24),
                  ] else ...[
                    const Text('Tapez votre code', style: AppTextStyles.body),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(4, (i) {
                        final filled = i < _digits.length;
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: filled ? cs.primary : Colors.transparent,
                            border: Border.all(
                                color: filled
                                    ? cs.primary
                                    : cs.onSurface.withValues(alpha: 0.35),
                                width: 2),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Pavé numérique — grosses cibles : on badge debout, souvent
                  // les mains occupées.
                  for (final row in const [
                    [1, 2, 3],
                    [4, 5, 6],
                    [7, 8, 9],
                  ])
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final d in row) _key(context, label: '$d', onTap: () => _tap(d)),
                      ],
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _key(context, label: '', onTap: null),
                      _key(context, label: '0', onTap: () => _tap(0)),
                      _key(context,
                          icon: Icons.backspace_outlined,
                          onTap: _digits.isEmpty ? null : _backspace),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _key(BuildContext context,
      {String? label, IconData? icon, VoidCallback? onTap}) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: enabled
            ? cs.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 72,
            height: 72,
            child: Center(
              child: icon != null
                  ? Icon(icon, size: 24, color: cs.onSurface)
                  : Text(label ?? '',
                      style: AppTextStyles.title.copyWith(
                          color: enabled
                              ? cs.onSurface
                              : cs.onSurface.withValues(alpha: 0.3))),
            ),
          ),
        ),
      ),
    );
  }
}
