import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../domain/entities/client.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/phone_field.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/autocomplete_text_field.dart';
import '../../../../shared/widgets/blocked_delete_dialog.dart';
import '../../../../core/services/danger_action_service.dart';
import '../../../../core/permisions/subscription_provider.dart';

class ClientsPage extends StatefulWidget {
  final String shopId;
  const ClientsPage({super.key, required this.shopId});
  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  List<Client> _clients     = [];
  bool         _loading     = true;
  String       _query       = '';
  String       _filter      = 'Tous';

  static const _filters = ['Tous', 'VIP', 'Régulier', 'Nouveau'];

  @override
  void initState() {
    super.initState();
    _load();
    // Sync en arrière-plan au montage
    _syncInBackground();
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
    setState(() {
      _clients = AppDatabase.getClientsForShop(widget.shopId);
      _loading = false;
    });
  }

  Future<void> _syncInBackground() async {
    await AppDatabase.syncClients(widget.shopId);
    if (mounted) _load();
  }

  List<Client> get _filtered {
    var list = _clients.where((c) =>
    c.name.toLowerCase().contains(_query.toLowerCase()) ||
        (c.phone ?? '').contains(_query) ||
        (c.email ?? '').toLowerCase().contains(_query.toLowerCase())).toList();
    if (_filter == 'VIP')      list = list.where((c) => c.tag == ClientTag.vip).toList();
    if (_filter == 'Régulier') list = list.where((c) => c.tag == ClientTag.regular).toList();
    if (_filter == 'Nouveau')  list = list.where((c) => c.tag == ClientTag.new_).toList();
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final l        = context.l10n;
    final filtered = _filtered;
    final total    = _clients.fold<double>(0, (s, c) => s + c.totalSpent);
    final vipCount = _clients.where((c) => c.tag == ClientTag.vip).length;

    return _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
        // ── KPI strip ─────────────────────────────────────────
        if (_clients.isNotEmpty)
          _KpiStrip(
              clientCount: _clients.length,
              vipCount: vipCount,
              totalRevenue: total),

        // ── Recherche pleine largeur ───────────────────────────────
        // Le CTA « + Ajouter » est désormais dans la topbar shell
        // (cf. ShopShell._topbarActionsFor) — la barre de recherche
        // récupère 100% de la largeur ici.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: l.crmSearch,
                  prefixIcon: const Icon(Icons.search_rounded,
                      size: 18, color: AppColors.textHint),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                    icon: const Icon(Icons.clear_rounded,
                        size: 16, color: AppColors.textHint),
                    onPressed: () => setState(() => _query = ''),
                  )
                      : null,
                  filled: true, fillColor: Colors.white, isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.divider)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.divider)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: AppColors.primary, width: 1.5)),
                ),
              ),
            ),
          ]),
        ),

        // ── Filtres ───────────────────────────────────────────
        if (_clients.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: _filters.map((f) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _FilterChip(
                  label: f,
                  selected: _filter == f,
                  count: _countForFilter(f),
                  onTap: () => setState(() => _filter = f),
                ),
              )).toList()),
            ),
          ),

        // ── Compteur ──────────────────────────────────────────
        if (_clients.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              Text('${filtered.length} client${filtered.length > 1 ? 's' : ''}',
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textHint,
                      fontWeight: FontWeight.w500)),
            ]),
          ),

        // ── Liste / Vide ──────────────────────────────────────
        Expanded(
          child: filtered.isEmpty
              ? _EmptyState(
            hasClients: _clients.isNotEmpty,
            query: _query,
            onAdd: () => _showClientForm(context),
          )
              : RefreshIndicator(
            onRefresh: _syncInBackground,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: filtered.length,
              itemBuilder: (_, i) => _ClientCard(
                client: filtered[i],
                onTap: () => context.push(
                    '/shop/${widget.shopId}/crm/client/${filtered[i].id}'),
                onEdit: () =>
                    _showClientForm(context, client: filtered[i]),
                onDelete: () =>
                    _confirmDelete(context, filtered[i]),
              ),
            ),
          ),
        ),
      ]);
  }

  int _countForFilter(String f) {
    if (f == 'Tous')      return _clients.length;
    if (f == 'VIP')       return _clients.where((c) => c.tag == ClientTag.vip).length;
    if (f == 'Régulier')  return _clients.where((c) => c.tag == ClientTag.regular).length;
    if (f == 'Nouveau')   return _clients.where((c) => c.tag == ClientTag.new_).length;
    return 0;
  }

  Future<void> _confirmDelete(BuildContext context, Client client) async {
    final perms = ProviderScope.containerOf(context, listen: false)
        .read(permissionsProvider(widget.shopId));
    await DangerActionService.execute(
      context:      context,
      perms:        perms,
      action:       DangerAction.deleteClient,
      shopId:       widget.shopId,
      targetId:     client.id,
      targetLabel:  client.name,
      title:        'Supprimer le client',
      description:  'Cette action est irréversible.',
      consequences: const [
        'Le client disparaît des listes et des sélecteurs.',
        'Les commandes passées ne pourront plus être rattachées à un client nommé.',
      ],
      confirmText:  client.name,
      onConfirmed:  () async {
        try {
          await AppDatabase.deleteClient(client.id, widget.shopId);
        } catch (e) {
          if (!mounted) return;
          // Proposer l'archivage à la place (soft-delete).
          final choice = await showBlockedDeleteDialog(
            context,
            itemLabel: client.name,
            reason: e.toString().replaceAll('Exception: ', ''),
            archiveDescription:
                'Le client sera masqué des listes et sélecteurs, mais ses '
                'commandes passées restent visibles dans l\'historique.',
          );
          if (choice == BlockedDeleteChoice.archive) {
            await AppDatabase.archiveClient(client.id);
            if (mounted) AppSnack.success(context, 'Client archivé');
          }
          return;
        }
        await ActivityLogService.log(
          action:      'client_deleted',
          targetType:  'client',
          targetId:    client.id,
          targetLabel: client.name,
          shopId:      widget.shopId,
          details: {
            if ((client.phone ?? '').isNotEmpty) 'phone': client.phone,
            if ((client.email ?? '').isNotEmpty) 'email': client.email,
            if ((client.city ?? '').isNotEmpty) 'city':  client.city,
          },
        );
        if (mounted) {
          _load();
          AppSnack.success(context, '${client.name} supprimé');
        }
      },
    );
  }

  void _showClientForm(BuildContext context, {Client? client}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ClientFormSheet(
        shopId:    widget.shopId,
        client:    client,
        onSaved:   () {
          Navigator.of(ctx).pop();
          _load();
          AppSnack.success(context,
              client == null ? 'Client ajouté !' : 'Client modifié !');
        },
        onDeleted: client == null ? null : () {
          Navigator.of(ctx).pop();
          _load();
          AppSnack.success(context, 'Client supprimé');
        },
      ),
    );
  }
}

// ─── KPI strip ────────────────────────────────────────────────────────────────
class _KpiStrip extends StatelessWidget {
  final int clientCount, vipCount;
  final double totalRevenue;
  const _KpiStrip({required this.clientCount, required this.vipCount,
    required this.totalRevenue});

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Row(children: [
      _Kpi(icon: Icons.people_rounded, color: AppColors.primary,
          label: 'Clients', value: '$clientCount'),
      _divider(),
      _Kpi(icon: Icons.workspace_premium_rounded,
          color: AppColors.warning, label: 'VIP', value: '$vipCount'),
      _divider(),
      _Kpi(icon: Icons.payments_rounded, color: AppColors.secondary,
          label: 'CA total', value: _fmt(totalRevenue)),
    ]),
  );

  Widget _divider() => Container(width: 1, height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.divider);

  String _fmt(double n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M XAF';
    if (n >= 1000)    return '${(n / 1000).toStringAsFixed(0)}k XAF';
    return '${n.toStringAsFixed(0)} XAF';
  }
}

class _Kpi extends StatelessWidget {
  final IconData icon; final Color color;
  final String label, value;
  const _Kpi({required this.icon, required this.color,
    required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Expanded(
    child: Row(children: [
      Container(width: 30, height: 30,
          decoration: BoxDecoration(color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 14, color: color)),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(fontSize: 13,
                fontWeight: FontWeight.w800, color: color),
                overflow: TextOverflow.ellipsis, maxLines: 1),
            Text(label, style: const TextStyle(fontSize: 10,
                color: AppColors.textHint)),
          ])),
    ]),
  );
}

// ─── Filtre chip ──────────────────────────────────────────────────────────────
class _FilterChip extends StatelessWidget {
  final String label; final bool selected;
  final int count; final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected,
    required this.count, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? AppColors.primary : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: TextStyle(fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textSecondary)),
        const SizedBox(width: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withOpacity(0.25)
                : AppColors.inputFill,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('$count', style: TextStyle(fontSize: 9,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : AppColors.textSecondary)),
        ),
      ]),
    ),
  );
}

// ─── Card client ──────────────────────────────────────────────────────────────
class _ClientCard extends StatelessWidget {
  final Client client;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _ClientCard({required this.client, required this.onTap,
    required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final color    = _avatarColor(client.id);
    final initial  = client.name.isNotEmpty ? client.name[0].toUpperCase() : '?';
    final daysAgo  = client.lastVisitAt != null
        ? DateTime.now().difference(client.lastVisitAt!).inDays
        : null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(children: [
          // Avatar 32px primarySurface (spec round 9, prompt 2). Le badge
          // VIP overlay coin bas-droit reste pour la lisibilité du segment.
          Stack(children: [
            Container(width: 32, height: 32,
                decoration: BoxDecoration(
                    color: AppColors.primarySurface, shape: BoxShape.circle),
                child: Center(child: Text(initial,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800,
                        color: color)))),
            if (client.tag == ClientTag.vip)
              Positioned(right: -2, bottom: -2,
                  child: Container(width: 12, height: 12,
                      decoration: BoxDecoration(
                          color: AppColors.warning,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: AppColors.surface, width: 1.5)),
                      child: const Icon(Icons.workspace_premium_rounded,
                          size: 8, color: Colors.white))),
          ]),
          const SizedBox(width: 12),

          // Infos
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(client.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary))),
                  if (client.tag != ClientTag.none)
                    _TagBadge(client.tag),
                ]),
                if (client.phone != null) ...[
                  const SizedBox(height: 2),
                  Text(client.phone!,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 9, color: AppColors.textSecondary)),
                ],
                const SizedBox(height: 5),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _Stat(Icons.receipt_rounded,
                        '${client.totalOrders} commande${client.totalOrders > 1 ? 's' : ''}'),
                    if (daysAgo != null)
                      _Stat(Icons.access_time_rounded,
                          daysAgo == 0 ? "Auj." : daysAgo == 1 ? 'Hier' : 'Il y a ${daysAgo}j'),
                  ],
                ),
              ])),

          // Montant + actions
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_fmtAmount(client.totalSpent),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800,
                    color: color)),
            const Text('XAF', style: TextStyle(fontSize: 9,
                color: AppColors.textHint)),
            const SizedBox(height: 6),
            Row(mainAxisSize: MainAxisSize.min, children: [
              GestureDetector(
                onTap: onDelete,
                child: Container(width: 28, height: 28,
                    decoration: BoxDecoration(
                        color: AppColors.error.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(7)),
                    child: const Icon(Icons.delete_outline_rounded,
                        size: 13, color: AppColors.error)),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onEdit,
                child: Container(width: 28, height: 28,
                    decoration: BoxDecoration(
                        color: AppColors.primarySurface,
                        borderRadius: BorderRadius.circular(7)),
                    child: Icon(Icons.edit_rounded, size: 13,
                        color: AppColors.primary)),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: AppColors.textHint.withOpacity(0.5)),
            ]),
          ]),
        ]),
      ),
    );
  }

  String _fmtAmount(double n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000)    return '${(n / 1000).toStringAsFixed(0)}k';
    return n.toStringAsFixed(0);
  }

  /// Couleur stable d'avatar client basée sur le hash de l'id. Palette
  /// de 6 couleurs Material (constantes valides hors `Color(0xFF…)` —
  /// voir règle « zéro Color hardcodé ») pour donner à chaque client une
  /// identité visuelle stable indépendante de la palette de thème.
  Color _avatarColor(String id) {
    final colors = [
      Colors.deepPurple.shade600,
      Colors.blue.shade600,
      Colors.teal.shade600,
      AppColors.error,
      AppColors.warning,
      Colors.purple.shade400,
    ];
    return colors[id.hashCode.abs() % colors.length];
  }
}

class _TagBadge extends StatelessWidget {
  final ClientTag tag;
  const _TagBadge(this.tag);

  Color _color() => switch (tag) {
    ClientTag.vip     => AppColors.warning,
    ClientTag.regular => AppColors.primary,
    ClientTag.new_    => AppColors.secondary,
    ClientTag.none    => AppColors.textHint,
  };

  IconData _icon() => switch (tag) {
    ClientTag.vip     => Icons.workspace_premium_rounded,
    ClientTag.regular => Icons.repeat_rounded,
    ClientTag.new_    => Icons.fiber_new_rounded,
    ClientTag.none    => Icons.remove_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final color = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_icon(), size: 10, color: color),
        const SizedBox(width: 3),
        Text(tag.label, style: TextStyle(fontSize: 9,
            fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon; final String label;
  const _Stat(this.icon, this.label);
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: AppColors.textHint),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textHint)),
      ]);
}

// ─── État vide local — spec round 9 prompt 2 ─────────────────────────────────
// Override du widget partagé EmptyStateWidget pour matcher pile la spec :
// icône 44px dans un cercle primarySurface, titre 12px, description 10px,
// bouton Ajouter centré. Le widget shared reste inchangé pour les autres
// pages qui en dépendent.
class _EmptyState extends StatelessWidget {
  final bool hasClients; final String query; final VoidCallback onAdd;
  const _EmptyState({required this.hasClients, required this.query,
    required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final isSearching = query.isNotEmpty;
    final showCta = !hasClients && !isSearching;
    final icon = isSearching
        ? Icons.search_off_rounded
        : Icons.people_outline_rounded;
    final title = isSearching
        ? 'Aucun résultat'
        : hasClients
            ? 'Aucun client dans ce filtre'
            : "Aucun client pour l'instant";
    final desc = isSearching
        ? 'Essayez un autre terme de recherche'
        : hasClients
            ? "Changez de filtre pour voir d'autres clients"
            : 'Ajoutez votre premier client pour démarrer votre CRM';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 22, color: AppColors.primary),
          ),
          const SizedBox(height: 12),
          Text(title,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text(desc,
              textAlign: TextAlign.center,
              maxLines: 3, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10,
                  color: AppColors.textSecondary)),
          if (showCta) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.person_add_rounded, size: 16),
              label: const Text('Ajouter un client',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

// ─── Formulaire client (sheet) ────────────────────────────────────────────────
class ClientFormSheet extends StatefulWidget {
  final String   shopId;
  final Client?  client;
  final VoidCallback         onSaved;
  final VoidCallback?        onDeleted;
  const ClientFormSheet({super.key, required this.shopId, this.client,
    required this.onSaved, this.onDeleted});
  @override
  State<ClientFormSheet> createState() => ClientFormSheetState();
}

class ClientFormSheetState extends State<ClientFormSheet> {
  final _nameCtrl     = TextEditingController();
  final _phoneCtrl    = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _cityCtrl     = TextEditingController();
  final _districtCtrl = TextEditingController();
  final _notesCtrl    = TextEditingController();
  bool _saving        = false;
  String _phoneFull   = '';
  bool _phoneValid    = false;

  // Champs facultatifs masqués par défaut.
  bool _showEmail = false;
  bool _showNotes = false;

  // ── Erreurs de validation ──────────────────────────────────────────────────
  String? _nameError;
  String? _emailError;
  String? _cityError;
  String? _districtError;

  // Suggestions d'autocomplétion (villes/quartiers déjà saisis).
  late final List<String> _citySuggestions;
  late final List<String> _districtSuggestions;

  // ── Validateurs ───────────────────────────────────────────────────────────
  static String? _validateName(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'Le nom est requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    if (s.length > 80) return 'Maximum 80 caractères';
    if (!RegExp(r"^[a-zA-ZÀ-ÿ\s\-\']+$").hasMatch(s)) {
      return 'Lettres et espaces uniquement';
    }
    return null;
  }

  static String? _validateEmail(String v) {
    final s = v.trim();
    if (s.isEmpty) return null; // optionnel
    if (!RegExp(r'^[\w.+\-]+@[\w\-]+\.[a-zA-Z]{2,}$').hasMatch(s)) {
      return 'Email invalide';
    }
    return null;
  }

  static String? _validateCity(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'La ville est requise';
    if (s.length < 2) return 'Minimum 2 caractères';
    return null;
  }

  static String? _validateDistrict(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'Le quartier est requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    return null;
  }

  bool get _isEdit => widget.client != null;

  @override
  void initState() {
    super.initState();
    _citySuggestions     = AppDatabase.getDistinctClientCities(widget.shopId);
    _districtSuggestions = AppDatabase.getDistinctClientDistricts(widget.shopId);

    if (_isEdit) {
      final cl = widget.client!;
      _nameCtrl.text     = cl.name;
      _phoneCtrl.text    = cl.phone    ?? '';
      _emailCtrl.text    = cl.email    ?? '';
      _cityCtrl.text     = cl.city     ?? '';
      _districtCtrl.text = cl.district ?? '';
      _notesCtrl.text    = cl.notes    ?? '';
      // Déplier les champs facultatifs s'ils sont déjà renseignés.
      _showEmail = (cl.email ?? '').isNotEmpty;
      _showNotes = (cl.notes ?? '').isNotEmpty;
      _phoneFull  = cl.phone ?? '';
      _phoneValid = cl.phone != null && cl.phone!.isNotEmpty;
    }
    _nameCtrl.addListener(() => setState(() =>
        _nameError = _validateName(_nameCtrl.text)));
    _emailCtrl.addListener(() => setState(() =>
        _emailError = _validateEmail(_emailCtrl.text)));
    _cityCtrl.addListener(() => setState(() =>
        _cityError = _validateCity(_cityCtrl.text)));
    _districtCtrl.addListener(() => setState(() =>
        _districtError = _validateDistrict(_districtCtrl.text)));
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _phoneCtrl.dispose(); _emailCtrl.dispose();
    _cityCtrl.dispose(); _districtCtrl.dispose(); _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name     = _nameCtrl.text.trim();
    final email    = _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim();
    final city     = _cityCtrl.text.trim();
    final district = _districtCtrl.text.trim();
    final phone    = _phoneFull.isEmpty ? null : _phoneFull;

    // ── Validation ──────────────────────────────────────────────────────────
    setState(() {
      _nameError     = _validateName(name);
      _emailError    = _showEmail ? _validateEmail(_emailCtrl.text) : null;
      _cityError     = _validateCity(city);
      _districtError = _validateDistrict(district);
    });
    if (_nameError != null || _emailError != null ||
        _cityError != null || _districtError != null) {
      AppSnack.error(context, 'Corrigez les erreurs avant de continuer');
      return;
    }
    if (phone == null || !_phoneValid) {
      AppSnack.error(context, 'Le téléphone est requis');
      return;
    }

    setState(() => _saving = true);
    try {
      // ── Vérification unicité (email + téléphone) ─────────────────────────
      final existing = AppDatabase.getClientsForShop(widget.shopId);
      final editId   = _isEdit ? widget.client!.id : null;

      if (email != null) {
        final dupe = existing.where((cl) =>
        cl.id != editId &&
            cl.email?.toLowerCase() == email.toLowerCase()).firstOrNull;
        if (dupe != null) {
          setState(() {
            _emailError = 'Cet email est déjà utilisé (${dupe.name})';
            _saving = false;
          });
          AppSnack.error(context, 'Email déjà enregistré');
          return;
        }
      }

      final dupePhone = existing.where((cl) =>
          cl.id != editId && cl.phone == phone).firstOrNull;
      if (dupePhone != null) {
        setState(() => _saving = false);
        AppSnack.error(context,
            'Ce numéro est déjà utilisé par ${dupePhone.name}');
        return;
      }

      // ── Construction de l'entité ─────────────────────────────────────────
      final now    = DateTime.now();
      final client = Client(
        id:          _isEdit
            ? widget.client!.id
            : 'cli_${now.millisecondsSinceEpoch}',
        storeId:     widget.shopId,
        name:        name,
        phone:       phone,
        email:       email,
        city:        city,
        district:    district,
        address:     '$district, $city', // legacy, composé automatiquement
        notes:       _notesCtrl.text.trim().isEmpty
            ? null : _notesCtrl.text.trim(),
        createdAt:   _isEdit ? widget.client!.createdAt : now,
        lastVisitAt: _isEdit ? widget.client!.lastVisitAt : null,
        totalOrders: _isEdit ? widget.client!.totalOrders : 0,
        totalSpent:  _isEdit ? widget.client!.totalSpent  : 0,
      );

      await AppDatabase.saveClient(client);
      await ActivityLogService.log(
        action:      _isEdit ? 'client_updated' : 'client_created',
        targetType:  'client',
        targetId:    client.id,
        targetLabel: client.name,
        shopId:      widget.shopId,
        details: {
          if ((client.phone ?? '').isNotEmpty) 'phone': client.phone,
          if ((client.email ?? '').isNotEmpty) 'email': client.email,
          if ((client.city ?? '').isNotEmpty) 'city':  client.city,
        },
      );
      widget.onSaved();
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }


  Future<void> _delete() async {
    final c = widget.client!;
    try {
      await AppDatabase.deleteClient(c.id, widget.shopId);
    } catch (e) {
      if (!mounted) return;
      final choice = await showBlockedDeleteDialog(
        context,
        itemLabel: c.name,
        reason: e.toString().replaceAll('Exception: ', ''),
        archiveDescription:
            'Le client sera masqué des listes et sélecteurs, mais ses '
            'commandes passées restent visibles dans l\'historique.',
      );
      if (choice == BlockedDeleteChoice.archive) {
        await AppDatabase.archiveClient(c.id);
        if (mounted) {
          AppSnack.success(context, 'Client archivé');
          widget.onDeleted?.call();
        }
      }
      return;
    }
    await ActivityLogService.log(
      action:      'client_deleted',
      targetType:  'client',
      targetId:    c.id,
      targetLabel: c.name,
      shopId:      widget.shopId,
      details: {
        if ((c.phone ?? '').isNotEmpty) 'phone': c.phone,
        if ((c.email ?? '').isNotEmpty) 'email': c.email,
        if ((c.city ?? '').isNotEmpty) 'city':  c.city,
      },
    );
    widget.onDeleted?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Poignée
          Center(child: Container(width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),

          // Titre
          Row(children: [
            Container(width: 36, height: 36,
                decoration: BoxDecoration(color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(
                    _isEdit ? Icons.edit_outlined : Icons.person_add_outlined,
                    size: 18, color: AppColors.primary)),
            const SizedBox(width: 10),
            Text(_isEdit ? 'Modifier le client' : 'Nouveau client',
                style: const TextStyle(fontSize: 16,
                    fontWeight: FontWeight.w700)),
            if (_isEdit) ...[
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded,
                    size: 20, color: AppColors.error),
                onPressed: () async {
                  final ok = await _confirmDelete(context);
                  if (ok) _delete();
                },
              ),
            ],
          ]),
          const SizedBox(height: 20),

          // Nom (requis)
          AppLabeledField(
            label: 'Nom complet', required: true,
            child: AppField(
              controller: _nameCtrl,
              hint: 'Ex: Alice Mballa',
              prefixIcon: Icons.person_outline_rounded,
              validator: (_) => _nameError,
              onChanged: (_) {},
            ),
          ),
          if (_nameError != null)
            _FieldError(_nameError!),
          const SizedBox(height: 12),

          // Téléphone (requis)
          PhoneField(
            controller: _phoneCtrl,
            label: 'Téléphone',
            required: true,
            onChanged: (full, valid) {
              _phoneFull  = full;
              _phoneValid = valid;
            },
          ),
          const SizedBox(height: 12),

          // Ville (requis, autocomplete)
          AutocompleteTextField(
            controller:     _cityCtrl,
            label:          'Ville',
            hint:           'Ex: Yaoundé',
            prefixIcon:     Icons.location_city_outlined,
            required:       true,
            suggestions:    _citySuggestions,
            validator:      (_) => _cityError,
          ),
          if (_cityError != null)
            _FieldError(_cityError!),
          const SizedBox(height: 12),

          // Quartier (requis, autocomplete)
          AutocompleteTextField(
            controller:     _districtCtrl,
            label:          'Quartier',
            hint:           'Ex: Bastos',
            prefixIcon:     Icons.place_outlined,
            required:       true,
            suggestions:    _districtSuggestions,
            validator:      (_) => _districtError,
          ),
          if (_districtError != null)
            _FieldError(_districtError!),
          const SizedBox(height: 16),

          // ── Facultatifs (masqués par défaut) ──────────────────────────────
          if (!_showEmail)
            _OptionalFieldToggle(
              icon:  Icons.email_outlined,
              label: 'Ajouter un email',
              onTap: () => setState(() => _showEmail = true),
            )
          else ...[
            AppLabeledField(
              label: 'Email',
              child: AppField(
                controller: _emailCtrl,
                hint: 'exemple@email.com',
                prefixIcon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
                validator: (_) => _emailError,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.close_rounded,
                      size: 16, color: AppColors.textHint),
                  onPressed: () => setState(() {
                    _emailCtrl.clear();
                    _showEmail = false;
                    _emailError = null;
                  }),
                ),
                onChanged: (_) {},
              ),
            ),
            if (_emailError != null)
              _FieldError(_emailError!),
          ],
          const SizedBox(height: 10),

          if (!_showNotes)
            _OptionalFieldToggle(
              icon:  Icons.notes_rounded,
              label: 'Ajouter une note interne',
              onTap: () => setState(() => _showNotes = true),
            )
          else
            AppLabeledField(
              label: 'Note interne',
              child: AppField(
                controller: _notesCtrl,
                hint: 'Préférences, informations utiles…',
                prefixIcon: Icons.notes_rounded,
                maxLines: 2,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.close_rounded,
                      size: 16, color: AppColors.textHint),
                  onPressed: () => setState(() {
                    _notesCtrl.clear();
                    _showNotes = false;
                  }),
                ),
              ),
            ),
          const SizedBox(height: 24),

          // Bouton sauvegarder
          AppPrimaryButton(
            label: _isEdit ? 'Enregistrer' : 'Ajouter le client',
            icon: _isEdit ? Icons.check_rounded : Icons.person_add_rounded,
            isLoading: _saving,
            enabled: !_saving &&
                _nameError == null &&
                _cityError == null &&
                _districtError == null &&
                (!_showEmail || _emailError == null) &&
                _phoneValid,
            onTap: _save,
            color: AppColors.primary,
            height: 48,
          ),
        ]),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Supprimer ce client ?',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: const Text('Cette action est irréversible.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dc).pop(false),
              child: const Text('Annuler',
                  style: TextStyle(color: AppColors.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.of(dc).pop(true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    ) ?? false;
  }
}

// ─── Message d'erreur sous un champ ───────────────────────────────────────────
class _FieldError extends StatelessWidget {
  final String message;
  const _FieldError(this.message);
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(top: 3, left: 2),
      child: Text(message,
          style: const TextStyle(
              fontSize: 10, color: AppColors.error)),
    ),
  );
}

// ─── Toggle pour révéler un champ facultatif ──────────────────────────────────
class _OptionalFieldToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OptionalFieldToggle({
    required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(children: [
        Icon(icon, size: 16, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(label,
            style: TextStyle(fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary)),
        const Spacer(),
        Icon(Icons.add_rounded, size: 16, color: AppColors.primary),
      ]),
    ),
  );
}