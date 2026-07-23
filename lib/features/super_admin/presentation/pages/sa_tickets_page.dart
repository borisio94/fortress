import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../tickets/data/ticket_repository.dart';
import '../../../tickets/domain/entities/shop_ticket.dart';
import '../../../tickets/presentation/pages/ticket_detail_page.dart';

/// Badge super-admin — nombre de tickets OUVERTS remontés au support
/// (`current_level = super_admin`).
///
/// ⚠️ Volontairement SANS Realtime : un canal `shop_tickets` persistant
/// survivait à la révocation du JWT au `signOut()` et déclenchait une boucle
/// de reconnexion qui FIGEAIT la page web au logout (« cette page ralentit
/// Firefox »). On se contente d'un fetch one-shot, recalculé à chaque
/// (ré)abonnement du drawer ; `autoDispose` → rien ne survit au panneau SA.
final saTicketBadgeProvider = FutureProvider.autoDispose<int>((ref) async {
  final c = await TicketRepository().saTicketCounters();
  if (c == null) return 0;
  final v = c['escalated_open'];
  return v is int ? v : (int.tryParse('$v') ?? 0);
});

/// Section super-admin « Tickets » — vision TRANSVERSALE de la messagerie
/// hiérarchique : tous les tickets de toutes les boutiques, MÊME ceux non
/// remontés au niveau super_admin (cf. hotfix_121 `sa_list_tickets`).
/// Le SA peut ouvrir un ticket pour lire le fil, répondre et le résoudre
/// (intervention pleine — `TicketDetailPage(superAdmin: true)`).
/// Rendu INLINE dans le panneau SA (pas de scaffold propre).
class SaTicketsSection extends StatefulWidget {
  const SaTicketsSection({super.key});

  @override
  State<SaTicketsSection> createState() => _SaTicketsSectionState();
}

class _SaTicketsSectionState extends State<SaTicketsSection> {
  final _repo = TicketRepository();
  final _dateFmt = DateFormat('dd/MM HH:mm');

  late Future<List<Map<String, dynamic>>> _future;
  // Filtres serveur : statut (défaut = ouverts) + niveau (null = tous).
  String? _statusFilter = 'open';
  String? _levelFilter;
  // Filtre client : boutique (null = toutes), dérivé du jeu de résultats.
  String? _shopFilter;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() =>
      _repo.saListTickets(status: _statusFilter, level: _levelFilter);

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  List<Map<String, dynamic>> _applyShopFilter(List<Map<String, dynamic>> all) {
    if (_shopFilter == null) return all;
    return all.where((t) => t['shop_id']?.toString() == _shopFilter).toList();
  }

  void _openTicket(Map<String, dynamic> t) {
    final shopId = t['shop_id']?.toString();
    final id = t['id']?.toString();
    if (shopId == null || id == null) return;
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => TicketDetailPage(
              shopId: shopId, ticketId: id, superAdmin: true),
        ))
        .then((_) => _refresh());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final all = snapshot.data ?? const <Map<String, dynamic>>[];
        final filtered = _applyShopFilter(all);
        final escalated = all
            .where((t) => t['current_level'] == 'super_admin')
            .length;

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _buildStatusFilters(),
              const SizedBox(height: 8),
              _buildLevelFilters(),
              const SizedBox(height: 8),
              _buildShopFilter(all),
              const SizedBox(height: 12),
              Text.rich(TextSpan(
                style: AppTextStyles.bodyBold,
                children: [
                  TextSpan(text: '${filtered.length} ticket(s)'),
                  if (escalated > 0) ...[
                    const TextSpan(text: ' dont '),
                    TextSpan(
                      text: '$escalated remonté(s) au support',
                      style: AppTextStyles.bodyBold
                          .copyWith(color: AppColors.error),
                    ),
                  ],
                ],
              )),
              const SizedBox(height: 12),
              if (filtered.isEmpty)
                _buildEmpty(context)
              else
                ...filtered.map((t) => _TicketCard(
                      ticket: t,
                      dateFmt: _dateFmt,
                      onTap: () => _openTicket(t),
                    )),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatusFilters() {
    const items = <MapEntry<String?, String>>[
      MapEntry('open', 'Ouverts'),
      MapEntry('resolved', 'Résolus'),
      MapEntry('closed', 'Clôturés'),
      MapEntry(null, 'Tous'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final e in items)
          ChoiceChip(
            label: Text(e.value, style: AppTextStyles.caption),
            selected: _statusFilter == e.key,
            onSelected: (_) {
              setState(() {
                _statusFilter = e.key;
                _future = _load();
              });
            },
          ),
      ],
    );
  }

  Widget _buildLevelFilters() {
    const items = <MapEntry<String?, String>>[
      MapEntry(null, 'Tous niveaux'),
      MapEntry('admin', 'Admin'),
      MapEntry('owner', 'Propriétaire'),
      MapEntry('super_admin', 'Support'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final e in items)
          ChoiceChip(
            label: Text(e.value, style: AppTextStyles.caption),
            selected: _levelFilter == e.key,
            selectedColor: e.key == 'super_admin'
                ? AppColors.error.withValues(alpha: 0.15)
                : null,
            onSelected: (_) {
              setState(() {
                _levelFilter = e.key;
                _future = _load();
              });
            },
          ),
      ],
    );
  }

  Widget _buildShopFilter(List<Map<String, dynamic>> all) {
    // Construit la liste des boutiques distinctes présentes dans les résultats.
    final shops = <String, String>{}; // shop_id -> shop_name
    for (final t in all) {
      final id = t['shop_id']?.toString();
      if (id == null) continue;
      shops.putIfAbsent(
          id, () => (t['shop_name']?.toString().trim().isNotEmpty ?? false)
              ? t['shop_name'].toString()
              : id);
    }
    if (shops.isEmpty) return const SizedBox.shrink();
    // Si la boutique filtrée n'existe plus dans le jeu courant, on réinitialise.
    if (_shopFilter != null && !shops.containsKey(_shopFilter)) {
      _shopFilter = null;
    }
    return Row(
      children: [
        Icon(Icons.store_outlined,
            size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<String?>(
            isExpanded: true,
            value: _shopFilter,
            underline: const SizedBox.shrink(),
            hint: Text('Toutes les boutiques',
                style: AppTextStyles.bodySmSecondary),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Toutes les boutiques',
                    style: AppTextStyles.bodySm),
              ),
              for (final e in shops.entries)
                DropdownMenuItem<String?>(
                  value: e.key,
                  child: Text(e.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm),
                ),
            ],
            onChanged: (v) => setState(() => _shopFilter = v),
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.forum_outlined,
              size: 40, color: Theme.of(context).semantic.borderSubtle),
          const SizedBox(height: 12),
          Text('Aucun ticket', style: AppTextStyles.bodySecondary),
        ],
      ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  final Map<String, dynamic> ticket;
  final DateFormat dateFmt;
  final VoidCallback onTap;

  const _TicketCard({
    required this.ticket,
    required this.dateFmt,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final levelKey = (ticket['current_level'] as String?) ?? 'admin';
    final statusKey = (ticket['status'] as String?) ?? 'open';
    final level = TicketLevelX.fromKey(levelKey);
    final status = TicketStatusX.fromKey(statusKey);
    final isEscalated = levelKey == 'super_admin';
    final shopName = (ticket['shop_name'] as String?)?.trim();
    final opener = (ticket['opener_label'] as String?)?.trim();
    final subject = (ticket['subject'] as String?)?.trim();
    final count = ticket['message_count'] ?? 0;
    final lastAt = _parseDate(ticket['last_message_at']) ??
        _parseDate(ticket['updated_at']);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isEscalated ? AppColors.error : theme.semantic.borderSubtle,
            width: isEscalated ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Badge(text: _levelLabel(level), color: _levelColor(level)),
                const SizedBox(width: 6),
                _Badge(text: status.labelFr, color: _statusColor(status)),
                const Spacer(),
                if (count is int && count > 0)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.forum_outlined,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 3),
                    Text('$count', style: AppTextStyles.bodySmSecondary),
                  ]),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subject != null && subject.isNotEmpty ? subject : 'Sans objet',
              style: AppTextStyles.bodyBold,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                if (shopName != null && shopName.isNotEmpty)
                  _Meta(icon: Icons.store_outlined, text: shopName),
                if (opener != null && opener.isNotEmpty)
                  _Meta(icon: Icons.person_outline_rounded, text: opener),
                if (lastAt != null)
                  _Meta(
                      icon: Icons.schedule_rounded,
                      text: dateFmt.format(lastAt)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Libellé court (l'extension labelFr est verbeuse : « En attente admin »…).
  String _levelLabel(TicketLevel l) => switch (l) {
        TicketLevel.admin => 'Admin',
        TicketLevel.owner => 'Propriétaire',
        TicketLevel.superAdmin => 'Support',
      };

  Color _levelColor(TicketLevel l) => switch (l) {
        TicketLevel.superAdmin => AppColors.error,
        TicketLevel.owner => AppColors.primary,
        TicketLevel.admin => AppColors.textSecondary,
      };

  Color _statusColor(TicketStatus s) => switch (s) {
        TicketStatus.open => AppColors.warning,
        TicketStatus.resolved => const Color(0xFF16A34A), // vert succès
        TicketStatus.closed => AppColors.textSecondary,
      };

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    return DateTime.tryParse(raw.toString())?.toLocal();
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: AppTextStyles.caption
              .copyWith(color: color, fontWeight: FontWeight.w700)),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Meta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(text, style: AppTextStyles.bodySmSecondary),
      ],
    );
  }
}
