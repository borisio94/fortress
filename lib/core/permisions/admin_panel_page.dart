import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';

// ─── Provider : liste utilisateurs pour le super admin ───────────────────────
final adminUsersProvider = FutureProvider.autoDispose<List<AdminUser>>((ref) async {
  final rows = await Supabase.instance.client
      .from('profiles')
      .select('''
        id, name, email, phone, prof_status,
        is_super_admin, blocked_at, blocked_reason, created_at,
        subscriptions (
          sub_status, billing_cycle, expires_at, amount_paid, payment_ref,
          plans ( name, label, offline_enabled, max_shops )
        )
      ''')
      .order('created_at', ascending: false);

  return (rows as List).map((r) => AdminUser.fromMap(r)).toList();
});

// ─── Entité AdminUser ─────────────────────────────────────────────────────────
class AdminUser {
  final String    id, name, email;
  final String?   phone;
  final String    profStatus;
  final bool      isSuperAdmin;
  final DateTime? blockedAt;
  final String?   blockedReason;
  final DateTime  createdAt;
  // Plan
  final String?   planName, planLabel, subStatus, billingCycle;
  final DateTime? expiresAt;
  final double?   amountPaid;

  const AdminUser({
    required this.id,    required this.name,   required this.email,
    this.phone,          required this.profStatus,
    required this.isSuperAdmin, this.blockedAt, this.blockedReason,
    required this.createdAt,
    this.planName, this.planLabel, this.subStatus,
    this.billingCycle,   this.expiresAt,        this.amountPaid,
  });

  bool get isBlocked  => profStatus == 'blocked';
  bool get isActive   => profStatus == 'active';
  bool get hasPlan    => planName != null;
  bool get subActive  => subStatus == 'active';

  factory AdminUser.fromMap(Map<String, dynamic> m) {
    final subs = (m['subscriptions'] as List?)?.isNotEmpty == true
        ? (m['subscriptions'] as List).first as Map<String, dynamic>
        : null;
    final plan = subs?['plans'] as Map<String, dynamic>?;
    return AdminUser(
      id:            m['id'] as String,
      name:          m['name'] as String? ?? '—',
      email:         m['email'] as String? ?? '—',
      phone:         m['phone'] as String?,
      profStatus:    m['prof_status'] as String? ?? 'active',
      isSuperAdmin:  m['is_super_admin'] as bool? ?? false,
      blockedAt:     m['blocked_at'] != null
          ? DateTime.tryParse(m['blocked_at'] as String) : null,
      blockedReason: m['blocked_reason'] as String?,
      createdAt:     DateTime.tryParse(m['created_at'] as String) ?? DateTime.now(),
      planName:      plan?['name'] as String?,
      planLabel:     plan?['label'] as String?,
      subStatus:     subs?['sub_status'] as String?,
      billingCycle:  subs?['billing_cycle'] as String?,
      expiresAt:     subs?['expires_at'] != null
          ? DateTime.tryParse(subs!['expires_at'] as String) : null,
      amountPaid:    (subs?['amount_paid'] as num?)?.toDouble(),
    );
  }
}

// ─── Page principale ──────────────────────────────────────────────────────────
class AdminPanelPage extends ConsumerStatefulWidget {
  const AdminPanelPage({super.key});
  @override ConsumerState<AdminPanelPage> createState() => _AdminPanelPageState();
}

class _AdminPanelPageState extends ConsumerState<AdminPanelPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  String _search = '';
  String _filter = 'all'; // all | active | blocked | expired

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() { _tabs.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FC),
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Administration',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'Utilisateurs'),
            Tab(text: 'Statistiques'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _UsersTab(search: _search, filter: _filter,
              onSearchChanged: (v) => setState(() => _search = v),
              onFilterChanged: (v) => setState(() => _filter = v)),
          const _StatsTab(),
        ],
      ),
    );
  }
}

// ─── Onglet Utilisateurs ──────────────────────────────────────────────────────
class _UsersTab extends ConsumerWidget {
  final String search, filter;
  final ValueChanged<String> onSearchChanged, onFilterChanged;
  const _UsersTab({required this.search, required this.filter,
    required this.onSearchChanged, required this.onFilterChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminUsersProvider);

    return Column(children: [
      // ── Barre recherche + filtres ───────────────────────────
      Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(children: [
          // Recherche
          SizedBox(
            height: 36,
            child: TextField(
              onChanged: onSearchChanged,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Rechercher par nom, email, téléphone…',
                hintStyle: const TextStyle(fontSize: 12,
                    color: Color(0xFF9CA3AF)),
                prefixIcon: const Icon(Icons.search, size: 16,
                    color: Color(0xFF9CA3AF)),
                filled: true, fillColor: const Color(0xFFF9FAFB),
                isDense: true, contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: Color(0xFFE5E7EB))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: Color(0xFFE5E7EB))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.primary)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Filtres
          SizedBox(
            height: 28,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _FilterChip('Tous',    'all',     filter, onFilterChanged),
                _FilterChip('Actifs',  'active',  filter, onFilterChanged),
                _FilterChip('Bloqués', 'blocked', filter, onFilterChanged),
                _FilterChip('Expirés', 'expired', filter, onFilterChanged),
                _FilterChip('Sans plan','no_plan',filter, onFilterChanged),
              ],
            ),
          ),
        ]),
      ),

      // ── Liste ────────────────────────────────────────────────
      Expanded(
        child: async.when(
          loading: () => const Center(
              child: CircularProgressIndicator()),
          error: (e, _) => Center(
              child: Text('Erreur: $e',
                  style: const TextStyle(color: Colors.red))),
          data: (users) {
            final filtered = _applyFilters(users);
            if (filtered.isEmpty) {
              return const Center(child: Text('Aucun utilisateur',
                  style: TextStyle(color: Color(0xFF9CA3AF))));
            }
            return RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(adminUsersProvider),
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: filtered.length,
                itemBuilder: (_, i) => _UserCard(
                    user: filtered[i],
                    onRefresh: () =>
                        ref.invalidate(adminUsersProvider)),
              ),
            );
          },
        ),
      ),
    ]);
  }

  List<AdminUser> _applyFilters(List<AdminUser> users) {
    var list = users;
    // Recherche
    if (search.isNotEmpty) {
      final q = search.toLowerCase();
      list = list.where((u) =>
      u.name.toLowerCase().contains(q) ||
          u.email.toLowerCase().contains(q) ||
          (u.phone ?? '').contains(q)).toList();
    }
    // Filtre statut
    switch (filter) {
      case 'active':  list = list.where((u) => u.isActive && u.subActive).toList();
      case 'blocked': list = list.where((u) => u.isBlocked).toList();
      case 'expired': list = list.where((u) =>
      u.expiresAt != null && u.expiresAt!.isBefore(DateTime.now())).toList();
      case 'no_plan': list = list.where((u) => !u.hasPlan).toList();
    }
    return list;
  }
}

// ─── Carte utilisateur ────────────────────────────────────────────────────────
class _UserCard extends StatelessWidget {
  final AdminUser    user;
  final VoidCallback onRefresh;
  const _UserCard({required this.user, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd/MM/yyyy');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: user.isBlocked
              ? const Color(0xFFFECACA)
              : const Color(0xFFE5E7EB),
          width: user.isBlocked ? 1.5 : 1,
        ),
      ),
      child: Column(children: [
        // ── Header ──────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            // Avatar initiale
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: user.isBlocked
                    ? const Color(0xFFFEE2E2)
                    : AppColors.primarySurface,
                shape: BoxShape.circle,
              ),
              child: Center(child: Text(
                user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800,
                    color: user.isBlocked
                        ? const Color(0xFFEF4444)
                        : AppColors.primary),
              )),
            ),
            const SizedBox(width: 10),

            // Infos
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(child: Text(user.name,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A)))),
                    const SizedBox(width: 6),
                    if (user.isSuperAdmin)
                      _Badge('Super Admin', AppColors.primary),
                    if (user.isBlocked)
                      _Badge('Bloqué', const Color(0xFFEF4444)),
                  ]),
                  Text(user.email,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF6B7280))),
                  if (user.phone != null)
                    Text(user.phone!,
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xFF9CA3AF))),
                ])),

            // Menu actions
            PopupMenuButton<String>(
              onSelected: (action) =>
                  _handleAction(context, action),
              color: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              itemBuilder: (_) => [
                if (!user.isSuperAdmin) ...[
                  if (user.isBlocked)
                    _menuItem('unblock', Icons.check_circle_outline,
                        'Activer le compte',
                        const Color(0xFF10B981))
                  else
                    _menuItem('block', Icons.block_rounded,
                        'Bloquer le compte',
                        const Color(0xFFEF4444)),
                  _menuItem('subscription', Icons.card_membership_rounded,
                      'Gérer abonnement', AppColors.primary),
                ],
                _menuItem('details', Icons.info_outline_rounded,
                    'Voir détails', const Color(0xFF6B7280)),
              ],
            ),
          ]),
        ),

        // ── Plan + abonnement ────────────────────────────────
        if (user.hasPlan || user.subStatus != null)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            decoration: const BoxDecoration(
                border: Border(
                    top: BorderSide(color: Color(0xFFF0F0F0)))),
            child: Row(children: [
              // Plan badge
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: user.subActive
                      ? AppColors.primarySurface
                      : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: user.subActive
                        ? AppColors.primary.withOpacity(0.3)
                        : const Color(0xFFE5E7EB),
                  ),
                ),
                child: Text(
                  user.planLabel ?? 'Aucun plan',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: user.subActive
                          ? AppColors.primary
                          : const Color(0xFF9CA3AF)),
                ),
              ),
              const SizedBox(width: 8),

              // Statut sub
              if (user.subStatus != null)
                _SubStatusBadge(user.subStatus!),

              const Spacer(),

              // Expiration
              if (user.expiresAt != null)
                Column(crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Expire le',
                          style: const TextStyle(
                              fontSize: 9, color: Color(0xFF9CA3AF))),
                      Text(fmt.format(user.expiresAt!),
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: user.expiresAt!
                                  .isBefore(DateTime.now())
                                  ? const Color(0xFFEF4444)
                                  : const Color(0xFF374151))),
                    ]),
            ]),
          ),
      ]),
    );
  }

  PopupMenuItem<String> _menuItem(
      String value, IconData icon, String label, Color color) =>
      PopupMenuItem(
        value: value,
        child: Row(children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.w500)),
        ]),
      );

  void _handleAction(BuildContext context, String action) {
    switch (action) {
      case 'block':   _confirmBlock(context);   break;
      case 'unblock': _confirmUnblock(context); break;
      case 'subscription': _showSubscriptionDialog(context); break;
      case 'details': _showDetails(context); break;
    }
  }

  // ── Bloquer ────────────────────────────────────────────────
  void _confirmBlock(BuildContext context) {
    final reasonCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.block_rounded, size: 18,
                color: Color(0xFFEF4444)),
          ),
          const SizedBox(width: 10),
          const Text('Bloquer le compte',
              style: TextStyle(fontSize: 14,
                  fontWeight: FontWeight.w700)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Bloquer « ${user.name} » ?',
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFF374151))),
          const SizedBox(height: 10),
          TextField(
            controller: reasonCtrl,
            maxLines: 2,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Raison du blocage (optionnel)…',
              hintStyle: const TextStyle(
                  fontSize: 12, color: Color(0xFF9CA3AF)),
              filled: true,
              fillColor: const Color(0xFFF9FAFB),
              isDense: true,
              contentPadding: const EdgeInsets.all(10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                      color: Color(0xFFE5E7EB))),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                      color: Color(0xFFE5E7EB))),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dc).pop(),
              child: const Text('Annuler',
                  style: TextStyle(
                      color: Color(0xFF6B7280)))),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(dc).pop();
              await _blockUser(context,
                  reason: reasonCtrl.text.trim());
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Bloquer'),
          ),
        ],
      ),
    );
  }

  Future<void> _blockUser(BuildContext context,
      {String? reason}) async {
    try {
      await Supabase.instance.client
          .from('profiles')
          .update({
        'prof_status':     'blocked',
        'blocked_at':      DateTime.now().toIso8601String(),
        'blocked_reason':  reason?.isEmpty == true ? null : reason,
      })
          .eq('id', user.id);
      onRefresh();
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Compte bloqué'),
          backgroundColor: Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
        ));
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
    }
  }

  // ── Débloquer ──────────────────────────────────────────────
  void _confirmUnblock(BuildContext context) {
    showDialog(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('Activer le compte',
            style: TextStyle(fontSize: 14,
                fontWeight: FontWeight.w700)),
        content: Text(
            'Réactiver le compte de « ${user.name} » ?',
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dc).pop(),
              child: const Text('Annuler',
                  style: TextStyle(
                      color: Color(0xFF6B7280)))),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(dc).pop();
              await Supabase.instance.client
                  .from('profiles')
                  .update({
                'prof_status':    'active',
                'blocked_at':     null,
                'blocked_reason': null,
              })
                  .eq('id', user.id);
              onRefresh();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Activer'),
          ),
        ],
      ),
    );
  }

  // ── Gérer abonnement ───────────────────────────────────────
  void _showSubscriptionDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SubscriptionSheet(
          user: user, onSaved: onRefresh),
    );
  }

  // ── Détails ────────────────────────────────────────────────
  void _showDetails(BuildContext context) {
    final fmt = DateFormat('dd/MM/yyyy HH:mm');
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user.name, style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              _DetailLine('ID',         user.id),
              _DetailLine('Email',      user.email),
              _DetailLine('Téléphone',  user.phone ?? '—'),
              _DetailLine('Statut',     user.profStatus),
              _DetailLine('Inscrit le', fmt.format(user.createdAt)),
              if (user.blockedAt != null) ...[
                _DetailLine('Bloqué le',
                    fmt.format(user.blockedAt!)),
                _DetailLine('Raison',
                    user.blockedReason ?? '—'),
              ],
              _DetailLine('Plan',       user.planLabel ?? '—'),
              _DetailLine('Abonnement', user.subStatus ?? '—'),
              if (user.expiresAt != null)
                _DetailLine('Expire le',
                    fmt.format(user.expiresAt!)),
              if (user.amountPaid != null)
                _DetailLine('Montant payé',
                    '${user.amountPaid!.toStringAsFixed(0)} XAF'),
              const SizedBox(height: 8),
            ]),
      ),
    );
  }
}

// ─── Sheet gestion abonnement ─────────────────────────────────────────────────
class _SubscriptionSheet extends StatefulWidget {
  final AdminUser    user;
  final VoidCallback onSaved;
  const _SubscriptionSheet(
      {required this.user, required this.onSaved});
  @override
  State<_SubscriptionSheet> createState() =>
      _SubscriptionSheetState();
}

class _SubscriptionSheetState extends State<_SubscriptionSheet> {
  String  _planName     = 'normal';
  String  _cycle        = 'monthly';
  bool    _saving       = false;
  final _payRefCtrl     = TextEditingController();
  final _notesCtrl      = TextEditingController();

  @override
  void initState() {
    super.initState();
    _planName = widget.user.planName ?? 'normal';
    _cycle    = widget.user.billingCycle ?? 'monthly';
    _notesCtrl.text = '';
  }

  @override
  void dispose() {
    _payRefCtrl.dispose(); _notesCtrl.dispose();
    super.dispose();
  }

  DateTime get _expiresAt {
    final now = DateTime.now();
    return switch (_cycle) {
      'monthly'   => DateTime(now.year, now.month + 1, now.day),
      'quarterly' => DateTime(now.year, now.month + 3, now.day),
      'yearly'    => DateTime(now.year + 1, now.month, now.day),
      _           => DateTime(now.year, now.month + 1, now.day),
    };
  }

  double get _price => switch ('${_planName}_$_cycle') {
    'normal_monthly'   => 5000,  'normal_quarterly' => 13500,
    'normal_yearly'    => 50000, 'pro_monthly'      => 10000,
    'pro_quarterly'    => 27000, 'pro_yearly'       => 100000,
    _                  => 0,
  };

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Récupérer l'id du plan
      final planRow = await Supabase.instance.client
          .from('plans')
          .select('id')
          .eq('name', _planName)
          .single();
      final planId = planRow['id'] as String;

      // Désactiver l'ancien abonnement actif
      await Supabase.instance.client
          .from('subscriptions')
          .update({'sub_status': 'cancelled',
        'cancelled_at': DateTime.now().toIso8601String()})
          .eq('user_id', widget.user.id)
          .eq('sub_status', 'active');

      // Créer le nouvel abonnement
      await Supabase.instance.client
          .from('subscriptions')
          .insert({
        'user_id':      widget.user.id,
        'plan_id':      planId,
        'billing_cycle': _cycle,
        'sub_status':   'active',
        'expires_at':   _expiresAt.toIso8601String(),
        'amount_paid':  _price,
        'payment_ref':  _payRefCtrl.text.trim().isEmpty
            ? null : _payRefCtrl.text.trim(),
        'notes':        _notesCtrl.text.trim().isEmpty
            ? null : _notesCtrl.text.trim(),
      });

      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(20))),
      padding: EdgeInsets.fromLTRB(
          20, 16, 20,
          16 + MediaQuery.of(context).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Poignée
            Center(child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(2)))),

            Row(children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.card_membership_rounded,
                    size: 18, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Gérer l\'abonnement',
                        style: TextStyle(fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    Text(widget.user.name,
                        style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF9CA3AF))),
                  ])),
              // Prix live
              Text('${_price.toStringAsFixed(0)} XAF',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800,
                      color: AppColors.primary)),
            ]),
            const SizedBox(height: 16),

            // Plan
            const Text('Plan',
                style: TextStyle(fontSize: 11,
                    color: Color(0xFF6B7280))),
            const SizedBox(height: 6),
            Row(children: [
              _PlanBtn('Normal', 'normal', _planName,
                      (v) => setState(() => _planName = v)),
              const SizedBox(width: 8),
              _PlanBtn('Pro', 'pro', _planName,
                      (v) => setState(() => _planName = v)),
            ]),
            const SizedBox(height: 12),

            // Cycle
            const Text('Cycle',
                style: TextStyle(fontSize: 11,
                    color: Color(0xFF6B7280))),
            const SizedBox(height: 6),
            Row(children: [
              _CycleBtn('Mensuel',     'monthly',   _cycle,
                      (v) => setState(() => _cycle = v)),
              const SizedBox(width: 6),
              _CycleBtn('Trimestriel', 'quarterly', _cycle,
                      (v) => setState(() => _cycle = v)),
              const SizedBox(width: 6),
              _CycleBtn('Annuel',      'yearly',    _cycle,
                      (v) => setState(() => _cycle = v)),
            ]),
            const SizedBox(height: 12),

            // Référence paiement
            TextField(
              controller: _payRefCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: _inputDeco('Référence paiement (optionnel)',
                  Icons.receipt_outlined),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notesCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: _inputDeco(
                  'Notes internes (optionnel)', Icons.notes_rounded),
            ),
            const SizedBox(height: 16),

            // Bouton
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: _saving
                    ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                    : const Text('Enregistrer l\'abonnement',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
    );
  }

  InputDecoration _inputDeco(String hint, IconData icon) =>
      InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
            fontSize: 12, color: Color(0xFF9CA3AF)),
        prefixIcon: Icon(icon, size: 16,
            color: const Color(0xFF9CA3AF)),
        filled: true,
        fillColor: const Color(0xFFF9FAFB),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:
            const BorderSide(color: Color(0xFFE5E7EB))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:
            const BorderSide(color: Color(0xFFE5E7EB))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.primary)),
      );
}

// ─── Onglet Statistiques ──────────────────────────────────────────────────────
class _StatsTab extends ConsumerWidget {
  const _StatsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminUsersProvider);
    return async.when(
      loading: () =>
      const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Erreur: $e')),
      data: (users) {
        final total    = users.length;
        final active   = users.where((u) =>
        u.isActive && u.subActive).length;
        final blocked  = users.where((u) => u.isBlocked).length;
        final noPlan   = users.where((u) => !u.hasPlan).length;
        final expired  = users.where((u) =>
        u.expiresAt?.isBefore(DateTime.now()) == true &&
            !u.isBlocked).length;
        final pro      = users.where((u) =>
        u.planName == 'pro').length;
        final normal   = users.where((u) =>
        u.planName == 'normal').length;
        final revenue  = users.fold<double>(0,
                (s, u) => s + (u.amountPaid ?? 0));

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            _StatCard('Utilisateurs total', '$total',
                Icons.people_outline_rounded, AppColors.primary),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _StatCard('Actifs',
                  '$active', Icons.check_circle_outline,
                  const Color(0xFF10B981))),
              const SizedBox(width: 8),
              Expanded(child: _StatCard('Bloqués',
                  '$blocked', Icons.block_rounded,
                  const Color(0xFFEF4444))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _StatCard('Expirés',
                  '$expired', Icons.access_time_rounded,
                  const Color(0xFFF59E0B))),
              const SizedBox(width: 8),
              Expanded(child: _StatCard('Sans plan',
                  '$noPlan', Icons.card_membership_rounded,
                  const Color(0xFF9CA3AF))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _StatCard('Plan Normal',
                  '$normal', Icons.star_outline_rounded,
                  AppColors.primary)),
              const SizedBox(width: 8),
              Expanded(child: _StatCard('Plan Pro',
                  '$pro', Icons.star_rounded,
                  const Color(0xFF7C3AED))),
            ]),
            const SizedBox(height: 8),
            _StatCard('Revenus totaux',
                '${revenue.toStringAsFixed(0)} XAF',
                Icons.payments_outlined,
                const Color(0xFF10B981)),
          ]),
        );
      },
    );
  }
}

// ─── Widgets atomiques ────────────────────────────────────────────────────────
class _FilterChip extends StatelessWidget {
  final String label, value, active;
  final ValueChanged<String> onTap;
  const _FilterChip(this.label, this.value, this.active, this.onTap);

  @override
  Widget build(BuildContext context) {
    final sel = value == active;
    return GestureDetector(
      onTap: () => onTap(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(
            horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: sel
              ? AppColors.primarySurface : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: sel
                  ? AppColors.primary : const Color(0xFFE5E7EB)),
        ),
        child: Text(label, style: TextStyle(
            fontSize: 11,
            fontWeight: sel
                ? FontWeight.w700 : FontWeight.w400,
            color: sel
                ? AppColors.primary : const Color(0xFF374151))),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color  color;
  const _Badge(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: TextStyle(
        fontSize: 8, fontWeight: FontWeight.w700, color: color)),
  );
}

class _SubStatusBadge extends StatelessWidget {
  final String status;
  const _SubStatusBadge(this.status);
  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'active'    => (const Color(0xFF10B981), 'Actif'),
      'expired'   => (const Color(0xFFEF4444), 'Expiré'),
      'cancelled' => (const Color(0xFF9CA3AF), 'Annulé'),
      'trial'     => (const Color(0xFFF59E0B), 'Essai'),
      _           => (const Color(0xFF9CA3AF), status),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(
          fontSize: 9, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String  label, value;
  final IconData icon;
  final Color   color;
  const _StatCard(this.label, this.value, this.icon, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB))),
    child: Row(children: [
      Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: color),
      ),
      const SizedBox(width: 12),
      Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w800,
                color: color)),
            Text(label, style: const TextStyle(
                fontSize: 11, color: Color(0xFF6B7280))),
          ]),
    ]),
  );
}

class _DetailLine extends StatelessWidget {
  final String label, value;
  const _DetailLine(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      SizedBox(width: 100, child: Text(label,
          style: const TextStyle(
              fontSize: 11, color: Color(0xFF6B7280)))),
      Expanded(child: Text(value,
          style: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600,
              color: Color(0xFF0F172A)))),
    ]),
  );
}

class _PlanBtn extends StatelessWidget {
  final String label, value, selected;
  final ValueChanged<String> onTap;
  const _PlanBtn(this.label, this.value, this.selected, this.onTap);
  @override
  Widget build(BuildContext context) {
    final sel = value == selected;
    return Expanded(child: GestureDetector(
      onTap: () => onTap(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: sel ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: sel ? AppColors.primary
                  : const Color(0xFFE5E7EB)),
        ),
        child: Text(label, textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: sel ? Colors.white
                    : const Color(0xFF374151))),
      ),
    ));
  }
}

class _CycleBtn extends StatelessWidget {
  final String label, value, selected;
  final ValueChanged<String> onTap;
  const _CycleBtn(this.label, this.value, this.selected, this.onTap);
  @override
  Widget build(BuildContext context) {
    final sel = value == selected;
    return Expanded(child: GestureDetector(
      onTap: () => onTap(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: sel
              ? AppColors.primarySurface : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: sel ? AppColors.primary
                  : const Color(0xFFE5E7EB)),
        ),
        child: Text(label, textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: sel ? AppColors.primary
                    : const Color(0xFF6B7280))),
      ),
    ));
  }
}