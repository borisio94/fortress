import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/whatsapp_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../domain/entities/client.dart';
import 'clients_page.dart';

class ClientDetailPage extends StatefulWidget {
  final String shopId, clientId;
  const ClientDetailPage({super.key, required this.shopId,
      required this.clientId});
  @override
  State<ClientDetailPage> createState() => _ClientDetailPageState();
}

class _ClientDetailPageState extends State<ClientDetailPage> {
  Client? _client;

  @override
  void initState() {
    super.initState();
    _load();
    AppDatabase.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDbChanged);
    super.dispose();
  }

  void _onDbChanged(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    if (table == 'clients' || table == 'orders') _load();
  }

  void _load() {
    final clients = AppDatabase.getClientsForShop(widget.shopId);
    setState(() {
      _client = clients.where((c) => c.id == widget.clientId).firstOrNull;
    });
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    if (client == null) {
      return AppScaffold(shopId: widget.shopId, title: 'Client',
          isRootPage: false,
          body: const Center(child: Text('Client introuvable')));
    }

    final color    = _avatarColor(client.id);
    final initial  = client.name.isNotEmpty ? client.name[0].toUpperCase() : '?';
    final daysAgo  = client.lastVisitAt != null
        ? DateTime.now().difference(client.lastVisitAt!).inDays : null;

    return AppScaffold(
      shopId: widget.shopId,
      title: client.name,
      isRootPage: false,
      actions: [
        if ((client.phone ?? '').trim().isNotEmpty)
          IconButton(
            icon: const Icon(Icons.send_rounded, size: 20),
            // Couleur officielle WhatsApp — sémantique forte pour le bouton.
            color: const Color(0xFF25D366),
            tooltip: 'Envoyer un message WhatsApp',
            onPressed: () => _composeWhatsappMessage(context, client),
          ),
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 20),
          color: AppColors.primary,
          onPressed: () => _showEdit(context, client),
        ),
      ],
      body: ListView(padding: EdgeInsets.zero, children: [
        // ── Hero ────────────────────────────────────────────────────
        _HeroHeader(client: client, color: color, initial: initial,
            daysAgo: daysAgo),

        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            // ── KPI ─────────────────────────────────────────────────
            Row(children: [
              Expanded(child: _KpiCard(
                icon: Icons.payments_rounded, color: AppColors.primary,
                label: 'Total dépensé',
                value: CurrencyFormatter.format(client.totalSpent),
              )),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                icon: Icons.receipt_rounded, color: AppColors.secondary,
                label: 'Commandes',
                value: '${client.totalOrders}',
              )),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                icon: Icons.trending_up_rounded,
                color: const Color(0xFFF59E0B),
                label: 'Moy./cmd',
                value: client.totalOrders > 0
                    ? CurrencyFormatter.format(
                        client.totalSpent / client.totalOrders)
                    : '—',
              )),
            ]),
            const SizedBox(height: 16),

            // ── Coordonnées ──────────────────────────────────────────
            _Section(title: 'Coordonnées', icon: Icons.contact_page_outlined,
                child: _CoordinatesContent(client: client)),
            const SizedBox(height: 16),

            // ── Notes ────────────────────────────────────────────────
            if (client.notes != null && client.notes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(title: 'Notes internes', icon: Icons.notes_rounded,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(client.notes!,
                        style: const TextStyle(fontSize: 13,
                            color: Color(0xFF374151), height: 1.5)),
                  )),
            ],
            const SizedBox(height: 16),

            // ── Actions ──────────────────────────────────────────────
            _Section(title: 'Actions', icon: Icons.bolt_rounded,
                child: Column(children: [
              _ActionTile(icon: Icons.receipt_long_rounded,
                  color: AppColors.primary,
                  label: 'Nouvelle commande',
                  onTap: () => context.push(
                      '/shop/${widget.shopId}/caisse'
                      '?clientId=${Uri.encodeComponent(widget.clientId)}')),
              const _Div(),
              _ActionTile(icon: Icons.edit_outlined,
                  color: const Color(0xFF6B7280),
                  label: 'Modifier les informations',
                  onTap: () => _showEdit(context, client)),
            ])),
            const SizedBox(height: 24),
          ]),
        ),
      ]),
    );
  }

  /// Ouvre un dialog de saisie de message libre, puis envoie via
  /// `WhatsappService.sendMessage` (provider actif = WameProvider →
  /// `wa.me/<phone>?text=…`). Le numéro client est normalisé via
  /// `PhoneFormatter.toWame` pour gérer les formats `+237 6XX…` /
  /// `06XX…` / `6XX…` indifféremment.
  Future<void> _composeWhatsappMessage(
      BuildContext context, Client client) async {
    final phone = (client.phone ?? '').trim();
    if (phone.isEmpty) return;
    final message = await showDialog<String>(
      context: context,
      builder: (_) => _WhatsappComposeDialog(clientName: client.name),
    );
    if (message == null || message.trim().isEmpty) return;
    if (!context.mounted) return;
    final svc = ProviderScope.containerOf(context, listen: false)
        .read(whatsappServiceProvider);
    final ok = await svc.sendMessage(
        PhoneFormatter.toWame(phone), message.trim());
    if (!ok && context.mounted) {
      AppSnack.error(context,
          'Impossible d\'ouvrir WhatsApp.');
    }
  }

  void _showEdit(BuildContext context, Client client) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ClientFormSheet(
        shopId: widget.shopId,
        client: client,
        onSaved: () {
          Navigator.of(ctx).pop();
          _load();
          AppSnack.success(context, 'Client modifié !');
        },
        onDeleted: () {
          Navigator.of(ctx).pop();
          context.pop();
          AppSnack.success(context, 'Client supprimé');
        },
      ),
    );
  }

  Color _avatarColor(String id) {
    const colors = [
      Color(0xFF6C3FC7), Color(0xFF3B82F6), Color(0xFF10B981),
      Color(0xFFEF4444), Color(0xFFF59E0B), Color(0xFF8B5CF6),
    ];
    return colors[id.hashCode.abs() % colors.length];
  }

}

// ─── Section coordonnées (téléphone, email, ville, quartier) ────────────────
class _CoordinatesContent extends StatelessWidget {
  final Client client;
  const _CoordinatesContent({required this.client});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];
    void addTile(IconData icon, String label, String? value) {
      if (value == null || value.isEmpty) return;
      if (tiles.isNotEmpty) tiles.add(const _Div());
      tiles.add(_InfoTile(icon: icon, label: label, value: value));
    }

    addTile(Icons.phone_outlined,         'Téléphone', client.phone);
    addTile(Icons.email_outlined,         'Email',     client.email);
    addTile(Icons.location_city_outlined, 'Ville',     client.city);
    addTile(Icons.place_outlined,         'Quartier',  client.district);

    if (tiles.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: Text('Aucune coordonnée renseignée',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))),
      );
    }
    return Column(children: tiles);
  }
}

// ─── Hero ─────────────────────────────────────────────────────────────────────
class _HeroHeader extends StatelessWidget {
  final Client client; final Color color;
  final String initial; final int? daysAgo;
  const _HeroHeader({required this.client, required this.color,
      required this.initial, required this.daysAgo});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, color: Colors.white,
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
    child: Column(children: [
      Stack(alignment: Alignment.center, children: [
        Container(width: 80, height: 80,
            decoration: BoxDecoration(color: color.withOpacity(0.12),
                shape: BoxShape.circle)),
        Container(width: 70, height: 70,
            decoration: BoxDecoration(color: color.withOpacity(0.2),
                shape: BoxShape.circle),
            child: Center(child: Text(initial,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800,
                    color: color)))),
        if (client.tag == ClientTag.vip)
          Positioned(right: 0, bottom: 0,
              child: Container(width: 24, height: 24,
                  decoration: const BoxDecoration(
                      color: Color(0xFFF59E0B), shape: BoxShape.circle),
                  child: const Icon(Icons.workspace_premium_rounded,
                      size: 14, color: Colors.white))),
      ]),
      const SizedBox(height: 12),
      Text(client.name, style: const TextStyle(fontSize: 20,
          fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
      if (client.phone != null) ...[
        const SizedBox(height: 4),
        Text(client.phone!, style: const TextStyle(
            fontSize: 13, color: Color(0xFF6B7280))),
      ],
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (client.tag != ClientTag.none) ...[
          _TagChip(client.tag),
          const SizedBox(width: 8),
        ],
        if (daysAgo != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: daysAgo! <= 7
                  ? AppColors.secondary.withOpacity(0.1)
                  : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.access_time_rounded, size: 11,
                  color: daysAgo! <= 7 ? AppColors.secondary
                      : const Color(0xFF9CA3AF)),
              const SizedBox(width: 4),
              Text(daysAgo == 0 ? "Actif aujourd'hui"
                  : daysAgo == 1 ? 'Actif hier'
                  : 'Inactif $daysAgo j',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: daysAgo! <= 7 ? AppColors.secondary
                          : const Color(0xFF9CA3AF))),
            ]),
          ),
      ]),
    ]),
  );
}

// ─── Widgets atomiques ────────────────────────────────────────────────────────
class _KpiCard extends StatelessWidget {
  final IconData icon; final Color color;
  final String label, value;
  const _KpiCard({required this.icon, required this.color,
      required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.15))),
    child: Column(children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800,
          color: color), textAlign: TextAlign.center),
      const SizedBox(height: 2),
      Text(label, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 9, color: Color(0xFF9CA3AF))),
    ]),
  );
}

class _Section extends StatelessWidget {
  final String title; final IconData icon;
  final Widget child; final Widget? trailing;
  const _Section({required this.title, required this.icon,
      required this.child, this.trailing});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      Icon(icon, size: 14, color: AppColors.primary),
      const SizedBox(width: 6),
      Text(title, style: const TextStyle(fontSize: 12,
          fontWeight: FontWeight.w700, color: Color(0xFF374151))),
      if (trailing != null) ...[const Spacer(), trailing!],
    ]),
    const SizedBox(height: 8),
    Container(decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB))),
        child: child),
  ]);
}

class _InfoTile extends StatelessWidget {
  final IconData icon; final String label, value;
  const _InfoTile({required this.icon, required this.label,
      required this.value});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    child: Row(children: [
      Icon(icon, size: 15, color: const Color(0xFF9CA3AF)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Text(label, style: const TextStyle(fontSize: 10,
            color: Color(0xFF9CA3AF), fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 13,
            fontWeight: FontWeight.w600, color: Color(0xFF0F172A))),
      ])),
    ]),
  );
}

class _ActionTile extends StatelessWidget {
  final IconData icon; final Color color;
  final String label; final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.color,
      required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Container(width: 34, height: 34,
            decoration: BoxDecoration(color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 16, color: color)),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600,
            color: Color(0xFF0F172A)))),
        const Icon(Icons.chevron_right_rounded,
            size: 16, color: Color(0xFFD1D5DB)),
      ]),
    ),
  );
}

class _TagChip extends StatelessWidget {
  final ClientTag tag;
  const _TagChip(this.tag);
  @override
  Widget build(BuildContext context) {
    final color = tag == ClientTag.vip ? const Color(0xFFF59E0B)
        : tag == ClientTag.new_ ? AppColors.secondary : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (tag == ClientTag.vip)
          Padding(padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.workspace_premium_rounded,
                  size: 11, color: color)),
        Text(tag.label, style: TextStyle(fontSize: 11,
            fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }
}

class _Div extends StatelessWidget {
  const _Div();
  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, color: Color(0xFFF3F4F6), indent: 16);
}

// ─── Dialog : composer un message WhatsApp pour le client ─────────────────
class _WhatsappComposeDialog extends StatefulWidget {
  final String clientName;
  const _WhatsappComposeDialog({required this.clientName});

  @override
  State<_WhatsappComposeDialog> createState() =>
      _WhatsappComposeDialogState();
}

class _WhatsappComposeDialogState extends State<_WhatsappComposeDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _ctrl.text.trim().isNotEmpty;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Row(children: [
        const Icon(Icons.send_rounded,
            size: 18, color: Color(0xFF25D366)),
        const SizedBox(width: 8),
        Expanded(
          child: Text('Message WhatsApp à ${widget.clientName}',
              style: const TextStyle(fontSize: 14,
                  fontWeight: FontWeight.w800),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLines: 5,
        minLines: 3,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Tape ton message ici…',
          hintStyle: const TextStyle(fontSize: 12,
              color: AppColors.textHint),
          isDense: true,
          contentPadding: const EdgeInsets.all(12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.divider)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                  color: Color(0xFF25D366), width: 1.5)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        ElevatedButton.icon(
          onPressed: hasText
              ? () => Navigator.of(context).pop(_ctrl.text)
              : null,
          icon: const Icon(Icons.send_rounded, size: 14),
          label: const Text('Envoyer'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF25D366),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ],
    );
  }
}

