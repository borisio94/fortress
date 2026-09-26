part of 'restaurant_staff_page.dart';

// L'onglet Équipe. La fiche d'un membre du personnel vit dans
// `widgets/staff_editor_sheet.dart`.

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
                                ? sem.warningText
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
                    return RestoListCard(
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
                                        .copyWith(color: sem.warningText)),
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
      builder: (_) => StaffEditorSheet(shopId: widget.shopId, existing: m),
    );
    if (mounted) setState(() {});
  }

  static String _dayShortLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';
}
