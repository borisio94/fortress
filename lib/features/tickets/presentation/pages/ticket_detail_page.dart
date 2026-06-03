import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../data/ticket_repository.dart';
import '../../domain/entities/shop_ticket.dart';

/// Détail d'un ticket : sujet + fil de messages chronologique +
/// composer de saisie. Actions disponibles selon hiérarchie :
///   * Auteur du ticket : peut résoudre.
///   * Admin / owner    : peut résoudre + escalader au niveau supérieur.
///   * Si déjà escaladé `super_admin` : pas d'escalade possible.
class TicketDetailPage extends ConsumerStatefulWidget {
  final String shopId;
  final String ticketId;
  const TicketDetailPage({
    super.key,
    required this.shopId,
    required this.ticketId,
  });
  @override
  ConsumerState<TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends ConsumerState<TicketDetailPage> {
  final _repo     = TicketRepository();
  final _msgCtrl  = TextEditingController();
  final _scroll   = ScrollController();
  ShopTicket? _ticket;
  List<ShopTicketMessage> _messages = [];
  bool _loading = true;
  bool _posting = false;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _readFromHive();
    _syncInBackground();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scroll.dispose();
    final ch = _channel;
    if (ch != null) {
      try { Supabase.instance.client.removeChannel(ch); } catch (_) {}
    }
    super.dispose();
  }

  /// Push live des nouveaux messages de ce ticket via canal Supabase
  /// dédié. Le filtre `ticket_id=eq.<id>` côté Postgres limite le trafic
  /// au strict nécessaire.
  void _subscribeRealtime() {
    final db = Supabase.instance.client;
    _channel = db
        .channel('ticket_${widget.ticketId}')
        .onPostgresChanges(
          event:  PostgresChangeEvent.insert,
          schema: 'public',
          table:  'shop_ticket_messages',
          filter: PostgresChangeFilter(
              type:   PostgresChangeFilterType.eq,
              column: 'ticket_id',
              value:  widget.ticketId),
          callback: (_) => _syncInBackground(),
        )
        .onPostgresChanges(
          event:  PostgresChangeEvent.update,
          schema: 'public',
          table:  'shop_tickets',
          filter: PostgresChangeFilter(
              type:   PostgresChangeFilterType.eq,
              column: 'id',
              value:  widget.ticketId),
          callback: (_) => _syncInBackground(),
        )
        .subscribe();
  }

  void _readFromHive() {
    if (!mounted) return;
    final tickets = _repo.getTickets(widget.shopId);
    final t = tickets.where((x) => x.id == widget.ticketId).firstOrNull;
    setState(() {
      _ticket   = t;
      _messages = _repo.getMessages(widget.ticketId);
      _loading  = false;
    });
    // Scroll en bas après refresh
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut);
      }
    });
  }

  Future<void> _syncInBackground() async {
    await _repo.syncTickets(widget.shopId);
    await _repo.syncMessages(widget.ticketId);
    _readFromHive();
  }

  Future<void> _sendMessage() async {
    final body = _msgCtrl.text.trim();
    if (body.isEmpty) return;
    setState(() => _posting = true);
    final m = await _repo.postMessage(ticketId: widget.ticketId, body: body);
    if (!mounted) return;
    if (m == null) {
      AppSnack.error(context,
          'Envoi impossible — vérifie ta connexion.');
      setState(() => _posting = false);
      return;
    }
    _msgCtrl.clear();
    setState(() => _posting = false);
    _syncInBackground();
  }

  Future<void> _resolve() async {
    final ok = await _repo.resolveTicket(widget.ticketId);
    if (!mounted) return;
    if (ok) {
      AppSnack.success(context, 'Ticket marqué comme résolu.');
      _syncInBackground();
    } else {
      AppSnack.error(context, 'Échec — réessaie.');
    }
  }

  Future<void> _escalate() async {
    final reason = await _askReason(context);
    if (reason == null) return; // annulé
    final newLevel = await _repo.escalateTicket(
        ticketId: widget.ticketId,
        reason:   reason.isEmpty ? null : reason);
    if (!mounted) return;
    if (newLevel == null) {
      AppSnack.error(context,
          'Escalade refusée — droits insuffisants ou ticket déjà au plus haut.');
      return;
    }
    AppSnack.success(context,
        'Ticket escaladé à : ${TicketLevelX.fromKey(newLevel).labelFr}');
    _syncInBackground();
  }

  Future<String?> _askReason(BuildContext context) {
    final ctrl = TextEditingController();
    return showAdaptiveFormSheet<String?>(
      context: context,
      builder: (c) => AdaptiveFormFrame(
        title: 'Escalader au niveau supérieur',
        icon: Icons.arrow_upward_rounded,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Indique brièvement pourquoi tu transmets ce ticket '
                      '(optionnel).',
                      style: AppTextStyles.bodySm),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    maxLines: 3,
                    minLines: 2,
                    decoration: const InputDecoration(
                      hintText: 'Ex : nécessite l\'accord du propriétaire pour…',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.of(c).pop(null),
                      child: const Text('Annuler')),
                  const SizedBox(width: 8),
                  FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary),
                      onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
                      child: const Text('Escalader',
                          style: TextStyle(color: Colors.white))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final perms  = ref.watch(permissionsProvider(widget.shopId));
    final myUid  = LocalStorageService.getCurrentUser()?.id;
    final t      = _ticket;

    final isPrivileged = perms.isShopAdmin || perms.isOwner;
    final isAuthor     = t != null && t.openedBy == myUid;
    final canResolve   = (isPrivileged || isAuthor) && t?.status == TicketStatus.open;
    // Escalade : admin → owner réservé admin/owner ; owner → super_admin
    // réservé owner. Pas d'escalade si super_admin déjà ou ticket résolu.
    final canEscalate = t != null
        && t.status == TicketStatus.open
        && t.currentLevel != TicketLevel.superAdmin
        && (
          (t.currentLevel == TicketLevel.admin && (perms.isShopAdmin || perms.isOwner))
          || (t.currentLevel == TicketLevel.owner && perms.isOwner)
        );

    return AppScaffold(
      shopId:     widget.shopId,
      title:      t?.subject ?? 'Ticket',
      isRootPage: false,
      actions: [
        if (canEscalate)
          IconButton(
            icon: const Icon(Icons.upgrade_rounded, size: 20),
            tooltip: 'Escalader',
            onPressed: _escalate,
          ),
        if (canResolve)
          IconButton(
            icon: const Icon(Icons.check_circle_outline_rounded, size: 20),
            tooltip: 'Marquer résolu',
            onPressed: _resolve,
          ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : t == null
              ? const Center(child: Text('Ticket introuvable.'))
              : Column(children: [
                  _TicketHeader(ticket: t),
                  Expanded(child: _MessageList(
                      ticket:    t,
                      messages:  _messages,
                      myUid:     myUid,
                      scroll:    _scroll)),
                  if (t.status == TicketStatus.open)
                    _MessageComposer(
                        controller: _msgCtrl,
                        sending:    _posting,
                        onSend:     _sendMessage)
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      color: Theme.of(context).semantic.trackMuted,
                      child: Text(
                          'Ce ticket est ${t.status.labelFr.toLowerCase()} — '
                          'lecture seule.',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.caption.copyWith(
                              color: Theme.of(context).colorScheme
                                  .onSurface.withValues(alpha:0.6))),
                    ),
                ]),
    );
  }
}

// ─── Header ticket ─────────────────────────────────────────────────────────

class _TicketHeader extends StatelessWidget {
  final ShopTicket ticket;
  const _TicketHeader({required this.ticket});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final isOpen = ticket.status == TicketStatus.open;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: sem.borderSubtle)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(ticket.subject,
              style: AppTextStyles.label
                  .copyWith(fontWeight: FontWeight.w800))),
          _Pill(
            label: ticket.status.labelFr,
            color: isOpen ? sem.warning : sem.success,
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 4, children: [
          _Pill(
            label: ticket.currentLevel.labelFr,
            color: sem.info,
          ),
          if (ticket.category != null && ticket.category!.isNotEmpty)
            _Pill(
              label: TicketCategory.labelFr(ticket.category),
              color: theme.colorScheme.onSurface.withValues(alpha:0.55),
            ),
          _Pill(
            label: 'Priorité ${ticket.priority.labelFr.toLowerCase()}',
            color: switch (ticket.priority) {
              TicketPriority.high   => sem.danger,
              TicketPriority.normal => AppColors.primary,
              TicketPriority.low    => sem.borderSubtle,
            },
          ),
        ]),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color  color;
  const _Pill({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha:0.14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(label,
        style: AppTextStyles.microBold.copyWith(color: color)),
  );
}

// ─── Liste messages ────────────────────────────────────────────────────────

class _MessageList extends StatelessWidget {
  final ShopTicket               ticket;
  final List<ShopTicketMessage>  messages;
  final String?                  myUid;
  final ScrollController         scroll;
  const _MessageList({
    required this.ticket,
    required this.messages,
    required this.myUid,
    required this.scroll,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
              'Pas encore de message. Envoie le premier pour démarrer la '
              'discussion.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm.copyWith(
                  color: Theme.of(context).colorScheme
                      .onSurface.withValues(alpha:0.6))),
        ),
      );
    }
    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: messages.length,
      itemBuilder: (_, i) {
        final m   = messages[i];
        final mine = m.authorId == myUid;
        return _MessageBubble(message: m, mine: mine);
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ShopTicketMessage message;
  final bool              mine;
  const _MessageBubble({required this.message, required this.mine});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final bg    = mine ? AppColors.primary : sem.trackMuted;
    final fg    = mine ? Colors.white     : theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.only(
                  topLeft:     const Radius.circular(12),
                  topRight:    const Radius.circular(12),
                  bottomLeft:  Radius.circular(mine ? 12 : 4),
                  bottomRight: Radius.circular(mine ? 4  : 12),
                ),
              ),
              child: Column(
                crossAxisAlignment: mine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Text(message.body,
                      style: AppTextStyles.body.copyWith(color: fg)),
                  const SizedBox(height: 2),
                  Text(_fmt(message.createdAt),
                      style: AppTextStyles.micro.copyWith(
                          color: fg.withValues(alpha:0.7))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime d) {
    final l = d.toLocal();
    return '${l.day.toString().padLeft(2,'0')}/'
        '${l.month.toString().padLeft(2,'0')} '
        '${l.hour.toString().padLeft(2,'0')}:'
        '${l.minute.toString().padLeft(2,'0')}';
  }
}

// ─── Composer ──────────────────────────────────────────────────────────────

class _MessageComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool                  sending;
  final VoidCallback          onSend;
  const _MessageComposer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: sem.borderSubtle)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: 'Écrire un message…',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: sem.borderSubtle)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: sem.borderSubtle)),
              ),
              onSubmitted: (_) => sending ? null : onSend(),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: sending ? null : onSend,
              child: Container(
                width: 40, height: 40,
                alignment: Alignment.center,
                child: sending
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded,
                        size: 18, color: Colors.white),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
