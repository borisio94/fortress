import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/services/staff_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
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
    final result = await StaffService.punch(member);
    if (!mounted) return;
    if (result.isEntry) {
      _show('Bonjour ${_firstName(member)}',
          'Service commencé à ${_hhmm(result.record.clockIn)}');
    } else {
      final minutes = result.record.durationMinutes ?? 0;
      _show('Bonne fin de service, ${_firstName(member)}',
          '${TimeRecord.formatMinutes(minutes)} travaillées aujourd\'hui');
    }
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

  static String _hhmm(DateTime? d) {
    final t = d ?? DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
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
                        onPressed: () => Navigator.of(context).maybePop(),
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
