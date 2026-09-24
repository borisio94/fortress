import 'package:flutter/material.dart';

import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/restaurant_table.dart';

/// Pose une réservation sur une table libre : date, heure, nom, couverts.
///
/// Le statut `reservee` existait depuis l'origine — icône, couleur, libellé,
/// place dans la légende du plan de salle et contrainte SQL — mais **aucun
/// écran ne permettait de l'atteindre** : la légende annonçait un état
/// impossible. C'est cette feuille qui manquait.
///
/// GESTE DE SERVICE, ouvert à tout membre : un client appelle, le serveur qui
/// décroche note. Exiger le droit de composer la salle obligerait à déranger le
/// gérant pour un coup de fil.
///
/// ⚠ N'EFFECTUE AUCUN CONTRÔLE DE PERMISSION, comme les autres feuilles du
/// module : c'est l'appelant qui garde le geste, quand il y a lieu.
///
/// Renvoie l'issue de l'écriture, ou `null` si la feuille a été fermée sans
/// réserver.
Future<TableWriteOutcome?> showTableReservationSheet({
  required BuildContext context,
  required RestaurantTable table,
}) async {
  final nameCtrl = TextEditingController();
  // Par défaut : ce soir, à l'heure ronde suivante. Une réservation se prend
  // presque toujours pour le service en cours ou celui du soir — proposer
  // « maintenant » obligerait à la corriger à chaque fois.
  final now = DateTime.now();
  var date = DateTime(now.year, now.month, now.day);
  var time = TimeOfDay(hour: (now.hour + 1).clamp(0, 23), minute: 0);
  var covers = table.capacity;

  final saved = await showAdaptiveFormSheet<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        final theme = Theme.of(sheetCtx);
        final sem = theme.semantic;

        Future<void> pickDate() async {
          final d = await showDatePicker(
            context: sheetCtx,
            initialDate: date,
            // Pas de réservation dans le passé : elle serait périmée à la
            // seconde où elle est posée.
            firstDate: DateTime(now.year, now.month, now.day),
            lastDate: now.add(const Duration(days: 365)),
          );
          if (d != null) setSheetState(() => date = d);
        }

        Future<void> pickTime() async {
          final t =
              await showTimePicker(context: sheetCtx, initialTime: time);
          if (t != null) setSheetState(() => time = t);
        }

        return AdaptiveFormFrame(
          title: 'Réserver ${table.name}',
          subtitle: 'Capacité ${table.capacity} personnes',
          icon: Icons.access_time_rounded,
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Quand ────────────────────────────────────────────
                const AppFieldLabel('Quand'),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: _PickerTile(
                      icon: Icons.event_outlined,
                      label: _dayLabel(date, now),
                      onTap: pickDate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PickerTile(
                      icon: Icons.schedule_rounded,
                      label: _hhmm(time),
                      onTap: pickTime,
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                    'La table est tenue '
                    '${RestaurantTable.reservationGrace.inMinutes} minutes '
                    'après l\'heure, puis elle redevient libre.',
                    style: AppTextStyles.caption),
                const SizedBox(height: 16),

                // ── Au nom de qui ────────────────────────────────────
                const AppFieldLabel('Au nom de'),
                const SizedBox(height: 8),
                AppField(
                  controller: nameCtrl,
                  hint: 'Mbarga',
                  autofocus: true,
                  prefixIcon: Icons.person_outline_rounded,
                ),
                const SizedBox(height: 16),

                // ── Combien ──────────────────────────────────────────
                const AppFieldLabel('Couverts attendus'),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RoundBtn(
                      icon: Icons.remove_rounded,
                      onTap: covers > 1
                          ? () => setSheetState(() => covers--)
                          : null,
                    ),
                    SizedBox(
                      width: 88,
                      child: Text('$covers',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.display
                              .copyWith(color: theme.colorScheme.onSurface)),
                    ),
                    _RoundBtn(
                      icon: Icons.add_rounded,
                      // Borné à la capacité, comme le sélecteur de couverts du
                      // service : le module ne gère pas les tables jointes.
                      onTap: covers < table.capacity
                          ? () => setSheetState(() => covers++)
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_isPast(date, time, now))
                  Text(
                      'Cette heure est déjà passée : la réservation serait '
                      'périmée aussitôt.',
                      style:
                          AppTextStyles.caption.copyWith(color: sem.warning)),
                const SizedBox(height: 20),
                AppPrimaryButton(
                  label: 'Réserver',
                  icon: Icons.check_rounded,
                  fullWidth: true,
                  // Une heure déjà passée ne réserve rien : la table serait
                  // rendue libre par le calcul à l'instant même.
                  enabled: !_isPast(date, time, now),
                  onTap: () => Navigator.of(sheetCtx).pop(true),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  final name = nameCtrl.text.trim();
  nameCtrl.dispose();
  if (saved != true) return null;

  return RestaurantTableService.reserve(
    table: table,
    at: DateTime(date.year, date.month, date.day, time.hour, time.minute),
    name: name,
    covers: covers,
  );
}

bool _isPast(DateTime date, TimeOfDay time, DateTime now) =>
    DateTime(date.year, date.month, date.day, time.hour, time.minute)
        .isBefore(now);

String _hhmm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';

/// « Aujourd'hui », « Demain », sinon la date. Une réservation se prend pour le
/// jour même dans l'immense majorité des cas : lire « Aujourd'hui » évite de
/// déchiffrer une date pour vérifier que c'est bien celle qu'on croit.
String _dayLabel(DateTime d, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'Aujourd\'hui';
  if (diff == 1) return 'Demain';
  return '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';
}

/// Tuile de sélection date / heure — libellé et icône, tapable.
class _PickerTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PickerTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: sem.borderSubtle),
        ),
        child: Row(children: [
          Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 9),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySmBold
                    .copyWith(color: theme.colorScheme.onSurface)),
          ),
        ]),
      ),
    );
  }
}

/// Bouton rond +/− du compteur de couverts. `onTap: null` → désactivé.
class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _RoundBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final on = onTap != null;
    return Material(
      color: on ? theme.colorScheme.primary : sem.trackMuted,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon,
              size: 20,
              color: on
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurface.withValues(alpha: 0.35)),
        ),
      ),
    );
  }
}
