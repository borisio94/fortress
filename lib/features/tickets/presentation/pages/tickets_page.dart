import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../data/ticket_repository.dart';
import '../../domain/entities/shop_ticket.dart';

/// Liste des tickets de la boutique courante.
///
/// v1 (phase 4A) :
///   * Affichage de la liste avec badges niveau/statut/priorité.
///   * Bouton "+ Nouveau ticket" → sheet de création (texte + catégorie + priorité).
///   * Filtre hiérarchique de visibilité :
///       - vendeur (`!isShopAdmin && !isOwner`) → uniquement ses propres
///         tickets (où il est `opened_by`).
///       - admin / owner → tous les tickets de la shop.
///   * Pas de détail/messages/escalade ici — viendront en 4B.
class TicketsPage extends ConsumerStatefulWidget {
  final String shopId;
  const TicketsPage({super.key, required this.shopId});
  @override
  ConsumerState<TicketsPage> createState() => _TicketsPageState();
}

class _TicketsPageState extends ConsumerState<TicketsPage> {
  final _repo = TicketRepository();
  List<ShopTicket> _tickets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _readFromHive();
    _syncInBackground();
  }

  void _readFromHive() {
    if (!mounted) return;
    setState(() {
      _tickets = _repo.getTickets(widget.shopId);
      _loading = false;
    });
  }

  Future<void> _syncInBackground() async {
    await _repo.syncTickets(widget.shopId);
    _readFromHive();
  }

  Future<void> _openCreate() async {
    final created = await showModalBottomSheet<ShopTicket>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _CreateTicketSheet(
          shopId: widget.shopId, repo: _repo),
    );
    if (created != null && mounted) {
      AppSnack.success(context,
          'Ticket envoyé à l\'administrateur de la boutique.');
      _readFromHive();
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final myUid = LocalStorageService.getCurrentUser()?.id;
    final isPrivileged = perms.isShopAdmin || perms.isOwner;

    final visible = _tickets.where((t) {
      if (isPrivileged) return true;          // admin/owner voient tout
      return t.openedBy == myUid;             // vendeur : ses propres tickets
    }).toList();

    return AppScaffold(
      shopId:     widget.shopId,
      title:      'Messagerie',
      isRootPage: false,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreate,
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.add_rounded, color: Colors.white),
        label: const Text('Nouveau ticket',
            style: TextStyle(color: Colors.white,
                fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _syncInBackground,
              child: visible.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 80),
                        Icon(Icons.forum_outlined,
                            size: 40, color: AppColors.textHint),
                        const SizedBox(height: 12),
                        Center(child: Text(
                            'Aucun ticket pour le moment.',
                            style: AppTextStyles.bodySecondary)),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                      itemCount: visible.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _TicketTile(
                          ticket: visible[i],
                          onTap: () async {
                            await context.push(
                                '/shop/${widget.shopId}/tickets/'
                                '${visible[i].id}');
                            // Re-sync au retour pour rafraîchir les statuts.
                            _syncInBackground();
                          },
                          onResolve: isPrivileged
                              ? () => _resolveTicket(visible[i])
                              : null),
                    ),
            ),
    );
  }

  Future<void> _resolveTicket(ShopTicket t) async {
    final ok = await _repo.resolveTicket(t.id);
    if (ok && mounted) {
      AppSnack.success(context, 'Ticket marqué comme résolu.');
      _syncInBackground();
    } else if (mounted) {
      AppSnack.error(context, 'Échec — réessaie quand tu es en ligne.');
    }
  }
}

// ─── Tile ticket ────────────────────────────────────────────────────────────

class _TicketTile extends StatelessWidget {
  final ShopTicket    ticket;
  final VoidCallback? onResolve;
  final VoidCallback? onTap;
  const _TicketTile({required this.ticket, this.onResolve, this.onTap});

  Color _statusColor(BuildContext c) {
    final sem = Theme.of(c).semantic;
    return switch (ticket.status) {
      TicketStatus.open     => sem.warning,
      TicketStatus.resolved => sem.success,
      TicketStatus.closed   => sem.borderSubtle,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final isOpen = ticket.status == TicketStatus.open;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // Pastille status
          Container(width: 8, height: 8, decoration: BoxDecoration(
              color: _statusColor(context), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(ticket.subject,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyBold)),
          if (isOpen)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: sem.warning.withValues(alpha:0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(ticket.currentLevel.labelFr,
                  style: AppTextStyles.microBold
                      .copyWith(color: sem.warning)),
            ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          if (ticket.category != null && ticket.category!.isNotEmpty) ...[
            Icon(Icons.label_outline_rounded,
                size: 11, color: sem.borderSubtle),
            const SizedBox(width: 3),
            Text(TicketCategory.labelFr(ticket.category),
                style: AppTextStyles.micro.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha:0.6))),
            const SizedBox(width: 10),
          ],
          Icon(Icons.access_time_rounded,
              size: 11, color: sem.borderSubtle),
          const SizedBox(width: 3),
          Text(_fmtDate(ticket.createdAt),
              style: AppTextStyles.micro.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha:0.6))),
          const Spacer(),
          if (isOpen && onResolve != null)
            TextButton(
              onPressed: onResolve,
              style: TextButton.styleFrom(
                foregroundColor: sem.success,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('Marquer résolu',
                  style: AppTextStyles.captionBold),
            ),
        ]),
      ]),
      ),
    );
  }

  String _fmtDate(DateTime d) {
    final l = d.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/'
        '${l.month.toString().padLeft(2, '0')}/'
        '${l.year.toString().substring(2)} '
        '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }
}

// ─── Sheet création ─────────────────────────────────────────────────────────

class _CreateTicketSheet extends StatefulWidget {
  final String           shopId;
  final TicketRepository repo;
  const _CreateTicketSheet({required this.shopId, required this.repo});
  @override
  State<_CreateTicketSheet> createState() => _CreateTicketSheetState();
}

class _CreateTicketSheetState extends State<_CreateTicketSheet> {
  final _subjectCtrl = TextEditingController();
  String _category = TicketCategory.autre;
  TicketPriority _priority = TicketPriority.normal;
  bool _submitting = false;

  @override
  void dispose() {
    _subjectCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final subject = _subjectCtrl.text.trim();
    if (subject.isEmpty) {
      AppSnack.error(context, 'Décris le problème en quelques mots.');
      return;
    }
    setState(() => _submitting = true);
    final t = await widget.repo.createTicket(
      shopId:   widget.shopId,
      subject:  subject,
      category: _category,
      priority: _priority,
    );
    if (!mounted) return;
    if (t == null) {
      setState(() => _submitting = false);
      AppSnack.error(context,
          'Impossible d\'envoyer — vérifie ta connexion.');
      return;
    }
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 24 + viewInsets),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Poignée
        Center(child: Container(
          width: 36, height: 4,
          decoration: BoxDecoration(
              color: sem.borderSubtle,
              borderRadius: BorderRadius.circular(2)),
        )),
        const SizedBox(height: 14),
        Text('Signaler un problème',
            style: AppTextStyles.subtitleBold
                .copyWith(color: theme.colorScheme.onSurface)),
        const SizedBox(height: 4),
        Text('Ton message va à l\'administrateur de la boutique. '
            'Si nécessaire, il peut l\'escalader au propriétaire.',
            style: AppTextStyles.caption.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha:0.6))),
        const SizedBox(height: 16),

        // Sujet
        TextField(
          controller: _subjectCtrl,
          maxLines: 4,
          minLines: 3,
          decoration: const InputDecoration(
            labelText: 'Sujet / description',
            hintText: 'Ex : caisse bloquée à l\'encaissement, '
                'stock manquant sur réception, etc.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),

        // Catégorie
        Text('Catégorie',
            style: AppTextStyles.captionBold.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha:0.7))),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6,
            children: TicketCategory.values.map((c) {
          final active = c == _category;
          return GestureDetector(
            onTap: () => setState(() => _category = c),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: active ? AppColors.primary : theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: active ? AppColors.primary : sem.borderSubtle),
              ),
              child: Text(TicketCategory.labelFr(c),
                  style: AppTextStyles.captionBold.copyWith(
                      color: active ? Colors.white
                                    : theme.colorScheme.onSurface)),
            ),
          );
        }).toList()),
        const SizedBox(height: 14),

        // Priorité
        Text('Priorité',
            style: AppTextStyles.captionBold.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha:0.7))),
        const SizedBox(height: 6),
        Row(children: TicketPriority.values.map((p) {
          final active = p == _priority;
          final col = switch (p) {
            TicketPriority.low    => sem.borderSubtle,
            TicketPriority.normal => AppColors.primary,
            TicketPriority.high   => sem.danger,
          };
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => setState(() => _priority = p),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: active ? col : theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: active ? col : sem.borderSubtle),
                ),
                child: Text(p.labelFr,
                    style: AppTextStyles.captionBold.copyWith(
                        color: active ? Colors.white
                                      : theme.colorScheme.onSurface)),
              ),
            ),
          );
        }).toList()),
        const SizedBox(height: 18),

        // Actions
        Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          )),
          const SizedBox(width: 10),
          Expanded(child: FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.primaryFill,
                padding: const EdgeInsets.symmetric(vertical: 12)),
            child: Text(_submitting ? 'Envoi…' : 'Envoyer',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: Colors.white)),
          )),
        ]),
      ]),
    );
  }
}
