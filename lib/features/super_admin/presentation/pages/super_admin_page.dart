import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/secure_storage.dart';
import '../../../../core/database/app_database.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../../../features/auth/presentation/bloc/auth_event.dart';

// ─── Providers ────────────────────────────────────────────────────────────────

final _saStatsProvider = FutureProvider.autoDispose<_SAStats>((ref) async {
  final db = Supabase.instance.client;
  // Filtre is_super_admin=false côté Supabase pour exclure les super admins
  // du compte des utilisateurs et des bloqués
  final profiles = await db.from('profiles')
      .select('id,prof_status,is_super_admin,created_at')
      .eq('is_super_admin', false);
  final subs     = await db.from('subscriptions').select('id,sub_status,amount_paid,billing_cycle,expires_at,user_id,plans(name,label)');
  final shops    = await db.from('shops').select('id,name,owner_id,is_active,created_at');
  final orders   = await db.from('orders').select('id,created_at');

  final now = DateTime.now();
  final pL  = List<Map<String,dynamic>>.from(profiles as List);
  final sL  = List<Map<String,dynamic>>.from(subs     as List);
  final shL = List<Map<String,dynamic>>.from(shops    as List);
  final oL  = List<Map<String,dynamic>>.from(orders   as List);

  // Le filtre is_super_admin=false ne s'applique qu'aux profiles.
  // Pour exclure les abonnements/revenus du super admin, on ne garde
  // que les subscriptions dont user_id correspond à un profil non-super-admin.
  final validUserIds = pL.map((p) => p['id'] as String).toSet();
  final filteredSubs = sL.where((s) =>
      validUserIds.contains(s['user_id'] as String?)).toList();

  final totalUsers   = pL.length;
  final blocked      = pL.where((u) => u['prof_status'] == 'blocked').length;
  final activeSubs   = filteredSubs.where((s) {
    final exp = s['expires_at'] != null ? DateTime.tryParse(s['expires_at']) : null;
    return s['sub_status'] == 'active' && (exp == null || exp.isAfter(now));
  }).length;
  final totalRevenue = filteredSubs.fold<double>(0, (a, e) => a + ((e['amount_paid'] as num?)?.toDouble() ?? 0));
  final proSubs  = filteredSubs.where((s) => (s['plans'] as Map?)?['name'] == 'pro'    && s['sub_status'] == 'active').length;
  final normSubs = filteredSubs.where((s) => (s['plans'] as Map?)?['name'] == 'normal' && s['sub_status'] == 'active').length;
  final expSoon  = filteredSubs.where((s) {
    final exp = s['expires_at'] != null ? DateTime.tryParse(s['expires_at']) : null;
    return exp != null && s['sub_status'] == 'active' && exp.isAfter(now) && exp.difference(now).inDays <= 7;
  }).length;
  final todayCmds = oL.where((o) {
    final d = o['created_at'] != null ? DateTime.tryParse(o['created_at']) : null;
    return d != null && d.year == now.year && d.month == now.month && d.day == now.day;
  }).length;

  return _SAStats(
    totalUsers: totalUsers, blocked: blocked,
    activeSubs: activeSubs, totalRevenue: totalRevenue,
    proSubs: proSubs, normalSubs: normSubs,
    totalShops: shL.length, activeShops: shL.where((s) => s['is_active'] == true).length,
    expireSoon: expSoon, todayOrders: todayCmds,
    recentPayments: filteredSubs.take(5).toList(),
    recentShops: shL.take(5).toList(),
  );
});

final _saUsersProvider = FutureProvider.autoDispose<List<Map<String,dynamic>>>((ref) async {
  final rows = await Supabase.instance.client
      .from('profiles')
      .select('id,name,email,phone,prof_status,is_super_admin,created_at,subscriptions(sub_status,expires_at,billing_cycle,amount_paid,plans(name,label))')
      .eq('is_super_admin', false)           // ← exclure les super admins
      .order('created_at', ascending: false).limit(100);
  return List<Map<String,dynamic>>.from(rows as List);
});

final _saShopsProvider = FutureProvider.autoDispose<List<Map<String,dynamic>>>((ref) async {
  final db = Supabase.instance.client;
  final rows = List<Map<String,dynamic>>.from(
      await db.from('shops')
          .select('id,name,owner_id,sector,currency,country,is_active,created_at')
          .order('created_at', ascending: false) as List);
  // Récupérer les profils des propriétaires en une seule requête
  final ownerIds = rows.map((s) => s['owner_id'] as String?)
      .whereType<String>().toSet().toList();
  if (ownerIds.isNotEmpty) {
    final profiles = List<Map<String,dynamic>>.from(
        await db.from('profiles').select('id,name,email')
            .inFilter('id', ownerIds) as List);
    final profileMap = { for (final p in profiles) p['id'] as String : p };
    for (final shop in rows) {
      final ownerId = shop['owner_id'] as String?;
      if (ownerId != null) shop['owner_profile'] = profileMap[ownerId];
    }
  }
  return rows;
});

final _saPaymentsProvider = FutureProvider.autoDispose<List<Map<String,dynamic>>>((ref) async {
  final db = Supabase.instance.client;
  final rows = List<Map<String,dynamic>>.from(
      await db.from('subscriptions')
          .select('id,sub_status,billing_cycle,amount_paid,payment_ref,notes,started_at,expires_at,cancelled_at,user_id,plans(label,name)')
          .order('started_at', ascending: false).limit(200) as List);
  final userIds = rows.map((s) => s['user_id'] as String?)
      .whereType<String>().toSet().toList();
  if (userIds.isNotEmpty) {
    final profiles = List<Map<String,dynamic>>.from(
        await db.from('profiles').select('id,name,email')
            .inFilter('id', userIds) as List);
    final pm = { for (final p in profiles) p['id'] as String : p };
    for (final sub in rows) {
      final uid = sub['user_id'] as String?;
      if (uid != null) sub['profiles'] = pm[uid];
    }
  }
  return rows;
});

final _saPlansProvider = FutureProvider.autoDispose<List<Map<String,dynamic>>>((ref) async =>
List<Map<String,dynamic>>.from(await Supabase.instance.client
    .from('plans').select('*').order('price_monthly') as List));

// ─── Modèle stats ─────────────────────────────────────────────────────────────
class _SAStats {
  final int totalUsers, blocked, activeSubs, proSubs, normalSubs;
  final int totalShops, activeShops, expireSoon, todayOrders;
  final double totalRevenue;
  final List<Map<String,dynamic>> recentPayments, recentShops;
  const _SAStats({
    required this.totalUsers, required this.blocked, required this.activeSubs,
    required this.totalRevenue, required this.proSubs, required this.normalSubs,
    required this.totalShops, required this.activeShops,
    required this.expireSoon, required this.todayOrders,
    required this.recentPayments, required this.recentShops,
  });
}

// ─── Sections drawer ──────────────────────────────────────────────────────────
enum _SASection {
  dashboard, users, shops, payments, plans, logs, messages,
  maintenance, monitoring, settings,
}

extension _SASectionX on _SASection {
  String get label => switch (this) {
    _SASection.dashboard    => 'Tableau de bord',
    _SASection.users        => 'Utilisateurs',
    _SASection.shops        => 'Boutiques',
    _SASection.payments     => 'Paiements',
    _SASection.plans        => 'Plans tarifaires',
    _SASection.logs         => 'Logs',
    _SASection.messages     => 'Messages',
    _SASection.maintenance  => 'Maintenance',
    _SASection.monitoring   => 'Monitoring',
    _SASection.settings     => 'Configuration',
  };
  IconData get icon => switch (this) {
    _SASection.dashboard    => Icons.dashboard_rounded,
    _SASection.users        => Icons.people_rounded,
    _SASection.shops        => Icons.store_rounded,
    _SASection.payments     => Icons.payments_rounded,
    _SASection.plans        => Icons.card_membership_rounded,
    _SASection.logs         => Icons.terminal_rounded,
    _SASection.messages     => Icons.chat_bubble_outline_rounded,
    _SASection.maintenance  => Icons.build_circle_rounded,
    _SASection.monitoring   => Icons.monitor_heart_rounded,
    _SASection.settings     => Icons.settings_outlined,
  };
}


// ─── Page principale ──────────────────────────────────────────────────────────
class SuperAdminPage extends ConsumerStatefulWidget {
  const SuperAdminPage({super.key});
  @override
  ConsumerState<SuperAdminPage> createState() => _SuperAdminPageState();
}

class _SuperAdminPageState extends ConsumerState<SuperAdminPage> {
  _SASection _section = _SASection.dashboard;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  void _navigate(_SASection s) {
    setState(() => _section = s);
    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      Navigator.of(context).pop();
    }
  }

  void _refresh() {
    ref.invalidate(_saStatsProvider);
    ref.invalidate(_saUsersProvider);
    ref.invalidate(_saShopsProvider);
    ref.invalidate(_saPaymentsProvider);
    ref.invalidate(_saPlansProvider);
  }

  bool get _isDesktop => MediaQuery.of(context).size.width >= 900;

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(_saStatsProvider).valueOrNull;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      drawer: _isDesktop ? null : _SADrawer(
        current: _section, onNavigate: _navigate,
        stats: stats, onRefresh: _refresh,
      ),
      body: _isDesktop
          ? Row(children: [
        _SADrawerContent(current: _section, onNavigate: _navigate,
            stats: stats, onRefresh: _refresh),
        Expanded(child: _bodyColumn()),
      ])
          : _bodyColumn(),
    );
  }

  Widget _bodyColumn() => Column(children: [
    _SAAppBar(section: _section, onMenuTap: () => _scaffoldKey.currentState?.openDrawer(),
        onRefresh: _refresh, stats: ref.watch(_saStatsProvider).valueOrNull,
        isDesktop: _isDesktop),
    Expanded(child: _buildSection()),
  ]);

  Widget _buildSection() => switch (_section) {
    _SASection.dashboard    => _DashboardSection(onNavigate: _navigate),
    _SASection.users        => const _UsersSection(),
    _SASection.shops        => const _ShopsSection(),
    _SASection.payments     => const _PaymentsSection(),
    _SASection.plans        => const _PlansSection(),
    _SASection.logs         => const _LogsSection(),
    _SASection.messages     => const _MessagesSection(),
    _SASection.maintenance  => const _MaintenanceSection(),
    _SASection.monitoring   => const _MonitoringSection(),
    _SASection.settings     => const _SettingsSection(),
  };
}

// ─── AppBar ────────────────────────────────────────────────────────────────────
class _SAAppBar extends StatelessWidget {
  final _SASection section;
  final VoidCallback onMenuTap, onRefresh;
  final _SAStats? stats;
  final bool isDesktop;
  const _SAAppBar({required this.section, required this.onMenuTap,
    required this.onRefresh, required this.stats, required this.isDesktop});

  @override
  Widget build(BuildContext context) {
    final alertCount = (stats?.expireSoon ?? 0) + (stats?.blocked ?? 0);
    return Container(
      decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0)))),
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.of(context).padding.top + 10, 12, 10),
      child: Row(children: [
        if (!isDesktop) ...[
          IconButton(onPressed: onMenuTap,
              icon: const Icon(Icons.menu_rounded, size: 22, color: Color(0xFF374151)),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
          const SizedBox(width: 8),
        ],
        Text(section.label, style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w700,
            color: AppColors.textPrimary)),
        const Spacer(),
        IconButton(onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 20,
                color: AppColors.textSecondary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
        const SizedBox(width: 4),
        Stack(children: [
          IconButton(onPressed: () {},
              icon: const Icon(Icons.notifications_outlined, size: 20,
                  color: AppColors.textSecondary),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
          if (alertCount > 0)
            Positioned(top: 4, right: 4,
                child: Container(width: 14, height: 14,
                    decoration: const BoxDecoration(
                        color: AppColors.error, shape: BoxShape.circle),
                    child: Center(child: Text('$alertCount',
                        style: const TextStyle(fontSize: 8,
                            fontWeight: FontWeight.w800, color: Colors.white))))),
        ]),
        const SizedBox(width: 4),
        _SAAvatar(),
      ]),
    );
  }
}

class _SAAvatar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';
    final init  = email.isNotEmpty ? email[0].toUpperCase() : 'A';
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context, backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 28, backgroundColor: AppColors.primarySurface,
                child: Text(init, style: TextStyle(fontSize: 20,
                    fontWeight: FontWeight.w800, color: AppColors.primary))),
            const SizedBox(height: 8),
            Text(email, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(20)),
                child: Text('Super Admin', style: TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w700, color: AppColors.primary))),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppColors.error, size: 20),
              title: const Text('Déconnexion', style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.error)),
              onTap: () {
                Navigator.of(context).pop();
                Future.microtask(() => _showLogoutConfirm(context));
              },
            ),
          ]),
        ),
      ),
      child: Container(width: 32, height: 32,
          decoration: BoxDecoration(
              color: AppColors.primarySurface, shape: BoxShape.circle,
              border: Border.all(color: AppColors.primary.withOpacity(0.3))),
          child: Center(child: Text(init, style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w800,
              color: AppColors.primary)))),
    );
  }
}

// ─── Drawer ────────────────────────────────────────────────────────────────────
class _SADrawer extends StatelessWidget {
  final _SASection current;
  final ValueChanged<_SASection> onNavigate;
  final _SAStats? stats;
  final VoidCallback onRefresh;
  const _SADrawer({required this.current, required this.onNavigate,
    required this.stats, required this.onRefresh});

  @override
  Widget build(BuildContext context) => Drawer(
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(),
    child: _SADrawerContent(current: current, onNavigate: onNavigate,
        stats: stats, onRefresh: onRefresh),
  );
}

class _SADrawerContent extends ConsumerWidget {
  final _SASection current;
  final ValueChanged<_SASection> onNavigate;
  final _SAStats? stats;
  final VoidCallback onRefresh;
  const _SADrawerContent({required this.current, required this.onNavigate,
    required this.stats, required this.onRefresh});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 240,
      child: Column(children: [
        // ── Header ─────────────────────────────────────────────────────────
        Container(
          padding: EdgeInsets.fromLTRB(
              16, MediaQuery.of(context).padding.top + 16, 16, 16),
          decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0)))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const FortressLogo.light(size: 22),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primary.withOpacity(0.2))),
              child: Row(children: [
                Container(width: 28, height: 28,
                    decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(7)),
                    child: const Icon(Icons.admin_panel_settings_rounded,
                        size: 14, color: Colors.white)),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Super Admin', style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w700, color: AppColors.primary)),
                  const Text('Panneau principal', style: TextStyle(
                      fontSize: 9, color: AppColors.textSecondary)),
                ]),
              ]),
            ),
            if (stats != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                _MiniStat('${stats!.totalUsers}', 'users', AppColors.primary),
                const SizedBox(width: 6),
                _MiniStat('${stats!.activeSubs}', 'actifs', AppColors.secondary),
                if (stats!.blocked > 0) ...[
                  const SizedBox(width: 6),
                  _MiniStat('${stats!.blocked}', 'bloqués', AppColors.error),
                ],
              ]),
            ],
          ]),
        ),

        // ── Nav items ──────────────────────────────────────────────────────
        Expanded(child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          children: [
            _DrawerLabel('Principal'),
            ...[ _SASection.dashboard, _SASection.users,
              _SASection.shops, _SASection.payments, _SASection.plans,
            ].map((s) => _DrawerTile(
              section: s, current: current, onTap: () => onNavigate(s),
              badge: s == _SASection.users && (stats?.blocked ?? 0) > 0
                  ? stats?.blocked
                  : s == _SASection.payments && (stats?.expireSoon ?? 0) > 0
                  ? stats?.expireSoon : null,
            )),
            const _Divider(),
            _DrawerLabel('Outils'),
            ...[ _SASection.logs, _SASection.messages,
              _SASection.maintenance, _SASection.monitoring,
            ].map((s) => _DrawerTile(
              section: s, current: current, onTap: () => onNavigate(s),
            )),
          ],
        )),

        // ── Footer ─────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(children: [
            const _Divider(),
            _DrawerTile(section: _SASection.settings, current: current,
                onTap: () => onNavigate(_SASection.settings)),
            const SizedBox(height: 4),
            InkWell(
              onTap: () => _confirmLogout(context),
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Icon(Icons.logout_rounded, size: 20, color: AppColors.error),
                  SizedBox(width: 10),
                  Expanded(child: Text('Déconnexion', style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500,
                      color: AppColors.error))),
                ]),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: Container(width: 48, height: 48,
            decoration: BoxDecoration(
                color: AppColors.error.withOpacity(0.1),
                shape: BoxShape.circle),
            child: const Icon(Icons.logout_rounded,
                color: AppColors.error, size: 22)),
        title: const Text('Déconnexion',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: const Text(
            'Vous allez quitter le panneau administrateur.\n\nÊtes-vous sûr de vouloir vous déconnecter ?',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.inputBorder),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 10)),
            child: const Text('Annuler',
                style: TextStyle(color: AppColors.textSecondary,
                    fontSize: 13)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.read<AuthBloc>().add(AuthLogoutRequested());
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 10)),
            child: const Text('Déconnecter',
                style: TextStyle(fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String value, label;
  final Color color;
  const _MiniStat(this.value, this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6)),
    child: RichText(text: TextSpan(children: [
      TextSpan(text: value, style: TextStyle(fontSize: 11,
          fontWeight: FontWeight.w700, color: color)),
      TextSpan(text: ' $label', style: const TextStyle(
          fontSize: 9, color: AppColors.textSecondary)),
    ])),
  );
}

class _DrawerLabel extends StatelessWidget {
  final String text;
  const _DrawerLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
    child: Text(text, style: const TextStyle(fontSize: 10,
        fontWeight: FontWeight.w700, color: AppColors.textSecondary,
        letterSpacing: 0.5)),
  );
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.symmetric(vertical: 6),
          child: Divider(color: Color(0xFFF0F0F0), thickness: 1));
}

class _DrawerTile extends StatelessWidget {
  final _SASection section, current;
  final VoidCallback onTap;
  final int? badge;
  const _DrawerTile({required this.section, required this.current,
    required this.onTap, this.badge});

  @override
  Widget build(BuildContext context) {
    final active = section == current;
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
          color: active ? AppColors.primary.withOpacity(0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Icon(section.icon, size: 20,
                color: active ? AppColors.primary : AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text(section.label, style: TextStyle(fontSize: 13,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active ? AppColors.primary : const Color(0xFF374151)))),
            if (badge != null && badge! > 0)
              Container(width: 18, height: 18,
                  decoration: const BoxDecoration(
                      color: AppColors.error, shape: BoxShape.circle),
                  child: Center(child: Text('$badge', style: const TextStyle(
                      fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)))),
            if (active && (badge == null || badge == 0)) ...[
              const SizedBox(width: 4),
              Container(width: 3, height: 16,
                  decoration: BoxDecoration(color: AppColors.primary,
                      borderRadius: BorderRadius.circular(2))),
            ],
          ]),
        ),
      ),
    );
  }
}


// ════════════════════════════════════════════════════════════════════════════
// SECTIONS
// ════════════════════════════════════════════════════════════════════════════

// ─── Dashboard ────────────────────────────────────────────────────────────────
class _DashboardSection extends ConsumerWidget {
  final ValueChanged<_SASection> onNavigate;
  const _DashboardSection({required this.onNavigate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(_saStatsProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(_saStatsProvider),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: statsAsync.when(
          loading: () => const Center(child: Padding(
              padding: EdgeInsets.all(48),
              child: CircularProgressIndicator())),
          error: (e, _) => _ErrorState(e.toString()),
          data: (s) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Alertes
            if (s.expireSoon > 0) _Alert(color: AppColors.warning,
                icon: Icons.access_time_rounded,
                message: '${s.expireSoon} abonnement(s) expirent dans 7 jours',
                onTap: () => onNavigate(_SASection.payments)),
            if (s.blocked > 0) ...[
              const SizedBox(height: 6),
              _Alert(color: AppColors.error, icon: Icons.block_rounded,
                  message: '${s.blocked} compte(s) bloqué(s)',
                  onTap: () => onNavigate(_SASection.users)),
            ],
            const SizedBox(height: 14),
            // KPI
            SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.start,
                children: [
                  _KpiCard('Utilisateurs', '${s.totalUsers}', Icons.people_rounded, AppColors.primary),
                  _KpiCard('Abonnés actifs', '${s.activeSubs}', Icons.verified_rounded, AppColors.secondary),
                  _KpiCard('Boutiques', '${s.totalShops}', Icons.store_rounded, AppColors.primary),
                  _KpiCard('Revenus XAF', _fmt(s.totalRevenue), Icons.payments_rounded, AppColors.secondary),
                  _KpiCard('Plan Pro', '${s.proSubs}', Icons.star_rounded, const Color(0xFF7C3AED)),
                  _KpiCard('Plan Normal', '${s.normalSubs}', Icons.star_outline_rounded, AppColors.primary),
                  _KpiCard('Bloqués', '${s.blocked}', Icons.block_rounded, AppColors.error),
                  _KpiCard('Cmds aujourd\'hui', '${s.todayOrders}', Icons.receipt_rounded, AppColors.warning),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // Accès rapides
            _SectionTitle('Accès rapides'),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _QuickAction('Utilisateurs', Icons.people_rounded, AppColors.primary,
                          () => onNavigate(_SASection.users)),
                  _QuickAction('Boutiques', Icons.store_rounded, AppColors.primary,
                          () => onNavigate(_SASection.shops)),
                  _QuickAction('Paiements', Icons.payments_rounded, AppColors.secondary,
                          () => onNavigate(_SASection.payments)),
                  _QuickAction('Plans', Icons.card_membership_rounded, const Color(0xFF7C3AED),
                          () => onNavigate(_SASection.plans)),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _SectionTitle('Paiements récents'),
            const SizedBox(height: 8),
            ...s.recentPayments.map((p) => _PaymentRow(payment: p)),
            const SizedBox(height: 18),
            _SectionTitle('Boutiques récentes'),
            const SizedBox(height: 8),
            ...s.recentShops.map((sh) => _ShopRow(shop: sh, onToggle: null, onDelete: null)),
          ]),
        ),
      ),
    );
  }
}

// ─── Utilisateurs ─────────────────────────────────────────────────────────────
class _UsersSection extends ConsumerStatefulWidget {
  const _UsersSection();
  @override ConsumerState<_UsersSection> createState() => _UsersSectionState();
}

class _UsersSectionState extends ConsumerState<_UsersSection> {
  String _search = '', _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_saUsersProvider);
    return Column(children: [
      _FilterBar(hint: 'Rechercher un utilisateur…', onSearch: (v) => setState(() => _search = v),
          filters: const ['Tous', 'Actifs', 'Bloqués', 'Sans plan', 'Expiré'],
          filterValues: const ['all', 'active', 'blocked', 'no_plan', 'expired'],
          selected: _filter, onFilter: (v) => setState(() => _filter = v)),
      Expanded(child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(e.toString()),
        data: (users) {
          final now = DateTime.now();
          var list = users;
          if (_search.isNotEmpty) {
            final q = _search.toLowerCase();
            list = list.where((u) =>
            (u['name'] as String? ?? '').toLowerCase().contains(q) ||
                (u['email'] as String? ?? '').toLowerCase().contains(q)).toList();
          }
          list = switch (_filter) {
            'active' => list.where((u) {
              final sub = (u['subscriptions'] as List?)?.firstOrNull as Map?;
              final exp = sub?['expires_at'] != null ? DateTime.tryParse(sub!['expires_at']) : null;
              return u['prof_status'] == 'active' && sub?['sub_status'] == 'active' && (exp == null || exp.isAfter(now));
            }).toList(),
            'blocked' => list.where((u) => u['prof_status'] == 'blocked').toList(),
            'no_plan' => list.where((u) => (u['subscriptions'] as List?)?.isEmpty != false).toList(),
            'expired' => list.where((u) {
              final sub = (u['subscriptions'] as List?)?.firstOrNull as Map?;
              final exp = sub?['expires_at'] != null ? DateTime.tryParse(sub!['expires_at']) : null;
              return exp != null && exp.isBefore(now);
            }).toList(),
            _ => list,
          };
          if (list.isEmpty) return const _EmptyState('Aucun utilisateur trouvé');
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_saUsersProvider),
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              itemBuilder: (_, i) => _UserCard(user: list[i], onRefresh: () {
                ref.invalidate(_saUsersProvider);
                ref.invalidate(_saStatsProvider);
              }),
            ),
          );
        },
      )),
    ]);
  }
}

// ─── Boutiques ────────────────────────────────────────────────────────────────
class _ShopsSection extends ConsumerStatefulWidget {
  const _ShopsSection();
  @override ConsumerState<_ShopsSection> createState() => _ShopsSectionState();
}

class _ShopsSectionState extends ConsumerState<_ShopsSection> {
  String _search = '', _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_saShopsProvider);
    return Column(children: [
      _FilterBar(hint: 'Rechercher une boutique…', onSearch: (v) => setState(() => _search = v),
          filters: const ['Toutes', 'Actives', 'Inactives'],
          filterValues: const ['all', 'active', 'inactive'],
          selected: _filter, onFilter: (v) => setState(() => _filter = v)),
      Expanded(child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(e.toString()),
        data: (shops) {
          var list = shops;
          if (_search.isNotEmpty) {
            final q = _search.toLowerCase();
            list = list.where((s) => (s['name'] as String? ?? '').toLowerCase().contains(q)).toList();
          }
          list = switch (_filter) {
            'active'   => list.where((s) => s['is_active'] == true).toList(),
            'inactive' => list.where((s) => s['is_active'] != true).toList(),
            _           => list,
          };
          if (list.isEmpty) return const _EmptyState('Aucune boutique trouvée');
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_saShopsProvider),
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              itemBuilder: (_, i) => _ShopRow(
                shop: list[i],
                onToggle: () async {
                  final val = !(list[i]['is_active'] as bool? ?? true);
                  await Supabase.instance.client.from('shops')
                      .update({'is_active': val}).eq('id', list[i]['id']);
                  ref.invalidate(_saShopsProvider);
                  ref.invalidate(_saStatsProvider);
                },
                onDelete: () => showDialog(context: context, builder: (_) => _ConfirmDialog(
                  title: 'Supprimer la boutique',
                  body: 'Supprimer « ${list[i]['name']} » ? Irréversible.',
                  confirmLabel: 'Supprimer', confirmColor: AppColors.error,
                  onConfirm: () async {
                    await Supabase.instance.client.from('shops').delete().eq('id', list[i]['id']);
                    ref.invalidate(_saShopsProvider);
                    ref.invalidate(_saStatsProvider);
                  },
                )),
              ),
            ),
          );
        },
      )),
    ]);
  }
}

// ─── Paiements ────────────────────────────────────────────────────────────────
class _PaymentsSection extends ConsumerStatefulWidget {
  const _PaymentsSection();
  @override ConsumerState<_PaymentsSection> createState() => _PaymentsSectionState();
}

class _PaymentsSectionState extends ConsumerState<_PaymentsSection> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_saPaymentsProvider);
    return Column(children: [
      _FilterBar(hint: 'Filtrer…', onSearch: (_) {},
          filters: const ['Tous', 'Actifs', 'Expirés', 'Annulés'],
          filterValues: const ['all', 'active', 'expired', 'cancelled'],
          selected: _filter, onFilter: (v) => setState(() => _filter = v), showSearch: false),
      async.when(
        loading: () => const SizedBox.shrink(),
        error: (_, __) => const SizedBox.shrink(),
        data: (payments) {
          final list = _filterPays(payments);
          final total = list.fold<double>(0, (s, p) => s + ((p['amount_paid'] as num?)?.toDouble() ?? 0));
          return Container(color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              Text('${list.length} paiement(s)', style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
              const Spacer(),
              Text('Total : ${_fmt(total)} XAF', style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.secondary)),
            ]),
          );
        },
      ),
      Expanded(child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(e.toString()),
        data: (payments) {
          final list = _filterPays(payments);
          if (list.isEmpty) return const _EmptyState('Aucun paiement enregistré');
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_saPaymentsProvider),
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              itemBuilder: (_, i) => _PaymentCard(payment: list[i], onRefresh: () {
                ref.invalidate(_saPaymentsProvider);
                ref.invalidate(_saStatsProvider);
              }),
            ),
          );
        },
      )),
    ]);
  }

  List<Map<String,dynamic>> _filterPays(List<Map<String,dynamic>> p) => switch (_filter) {
    'active'    => p.where((x) => x['sub_status'] == 'active').toList(),
    'expired'   => p.where((x) => x['sub_status'] == 'expired').toList(),
    'cancelled' => p.where((x) => x['sub_status'] == 'cancelled').toList(),
    _ => p,
  };
}

// ─── Plans ────────────────────────────────────────────────────────────────────
class _PlansSection extends ConsumerWidget {
  const _PlansSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_saPlansProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorState(e.toString()),
      data: (plans) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(_saPlansProvider),
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: plans.length,
          itemBuilder: (_, i) => _PlanCard(plan: plans[i],
              onEdit: () => showModalBottomSheet(
                context: context, isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => _EditPlanSheet(
                    plan: plans[i], onSaved: () => ref.invalidate(_saPlansProvider)),
              )),
        ),
      ),
    );
  }
}

// ─── Logs ─────────────────────────────────────────────────────────────────────
class _LogsSection extends ConsumerStatefulWidget {
  const _LogsSection();
  @override ConsumerState<_LogsSection> createState() => _LogsSectionState();
}

class _LogsSectionState extends ConsumerState<_LogsSection> {
  List<_LogEntry> _logs = [];
  bool _loading = true;
  String _filter = 'all';

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final db = Supabase.instance.client;
      final rows = List<Map<String, dynamic>>.from(
          await db.from('activity_logs')
              .select('id,action,actor_id,actor_email,target_type,target_id,'
                      'target_label,shop_id,details,created_at')
              .order('created_at', ascending: false)
              .limit(200) as List);

      // actor_email peut être null (anciennes lignes / log via RPC SECURITY DEFINER)
      // → enrichir depuis profiles pour afficher le nom
      final actorIds = rows
          .map((r) => r['actor_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final profileMap = <String, Map<String, dynamic>>{};
      if (actorIds.isNotEmpty) {
        final profs = List<Map<String, dynamic>>.from(
            await db.from('profiles')
                .select('id,name,email')
                .inFilter('id', actorIds) as List);
        for (final p in profs) {
          profileMap[p['id'] as String] = p;
        }
      }

      final logs = rows.map((r) {
        final prof = profileMap[r['actor_id'] as String?];
        final actor = prof?['name'] as String? ??
            r['actor_email'] as String? ??
            prof?['email'] as String? ??
            '—';
        return _LogEntry.fromRow(r, actorName: actor);
      }).toList();

      setState(() { _logs = logs; _loading = false; });
    } catch (e) { setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) {
    final list = _filter == 'all'
        ? _logs
        : _logs.where((l) => l.category == _filter).toList();
    return Column(children: [
      _FilterBar(hint: 'Filtrer…', onSearch: (_) {},
          filters: const ['Tous', 'Connexions', 'Boutiques', 'Ventes', 'Comptes', 'Alertes'],
          filterValues: const ['all', 'auth', 'shop', 'sale', 'account', 'alert'],
          selected: _filter, onFilter: (v) => setState(() => _filter = v),
          showSearch: false),
      Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty ? const _EmptyState('Aucun log disponible')
          : RefreshIndicator(onRefresh: _load,
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            itemBuilder: (_, i) => _LogTile(entry: list[i]),
          ))),
    ]);
  }
}

// ─── Messages ─────────────────────────────────────────────────────────────────
class _MessagesSection extends StatelessWidget {
  const _MessagesSection();
  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(padding: EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chat_bubble_outline_rounded, size: 48, color: Color(0xFFD1D5DB)),
          SizedBox(height: 12),
          Text('Messagerie — Prochaine version', style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          SizedBox(height: 6),
          Text('Les messages des utilisateurs apparaîtront ici.',
              style: TextStyle(fontSize: 12, color: AppColors.textHint),
              textAlign: TextAlign.center),
        ])),
  );
}

// ─── Configuration ────────────────────────────────────────────────────────────
class _SettingsSection extends ConsumerWidget {
  const _SettingsSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SectionTitle('Compte administrateur'),
      const SizedBox(height: 8),
      _SettingsCard(items: [
        _SettingsTile(icon: Icons.person_outline_rounded,
            label: 'Profil super admin',
            subtitle: Supabase.instance.client.auth.currentUser?.email ?? '—',
            onTap: () {}),
        _SettingsTile(icon: Icons.lock_outline_rounded,
            label: 'Changer le mot de passe',
            subtitle: 'Modifier le mot de passe du compte', onTap: () {}),
      ]),
      const SizedBox(height: 16),
      _SectionTitle('Plateforme'),
      const SizedBox(height: 8),
      _SettingsCard(items: [
        _SettingsTile(icon: Icons.language_rounded,
            label: 'Langues disponibles', subtitle: 'Français, Anglais', onTap: () {}),
        _SettingsTile(icon: Icons.attach_money_rounded,
            label: 'Devises configurées', subtitle: 'XAF, EUR, USD…', onTap: () {}),
        _SettingsTile(icon: Icons.category_rounded,
            label: "Secteurs d'activité",
            subtitle: 'Restaurant, Pharmacie…', onTap: () {}),
      ]),
      const SizedBox(height: 16),
      _SectionTitle('Actions système'),
      const SizedBox(height: 8),
      _SettingsCard(items: [
        _SettingsTile(icon: Icons.timer_outlined, color: AppColors.warning,
            label: 'Expirer les abonnements périmés',
            subtitle: 'Lance expire_subscriptions()',
            onTap: () => _runExpire(context)),
      ]),
      const SizedBox(height: 16),
      _SectionTitle('Zone dangereuse'),
      const SizedBox(height: 8),
      _SettingsCard(items: [
        _SettingsTile(icon: Icons.cleaning_services_rounded,
            color: AppColors.warning,
            label: 'Purger tous les logs d\'activité',
            subtitle: 'Efface activity_logs côté Supabase + cache local',
            onTap: () => _confirmPurgeAllLogs(context)),
        _SettingsTile(icon: Icons.restart_alt_rounded, color: AppColors.error,
            label: 'Réinitialiser toutes les données de la plateforme',
            subtitle: 'Supprime tous les utilisateurs, boutiques et données',
            onTap: () => _confirmResetAll(context, ref)),
      ]),
    ]),
  );

  void _confirmPurgeAllLogs(BuildContext ctx) {
    showDialog(context: ctx, builder: (_) => _SaDangerReauthDialog(
      icon: Icons.cleaning_services_rounded,
      title: 'Purger tous les logs',
      warningTitle: 'Action irréversible',
      warningMessage:
          'Tous les logs d\'activité de toutes les boutiques seront '
          'supprimés définitivement. L\'historique de la plateforme ne '
          'pourra plus être reconstitué. Les données métier (ventes, '
          'produits, utilisateurs) ne sont pas affectées.',
      confirmLabel: 'Tout purger',
      onConfirmed: () async {
        final n = await AppDatabase.purgeAllActivityLogs();
        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text('$n log(s) purgé(s) sur la plateforme'),
          backgroundColor: AppColors.secondary,
          behavior: SnackBarBehavior.floating,
        ));
      },
    ));
  }

  Future<void> _runExpire(BuildContext ctx) async {
    try {
      final result = await Supabase.instance.client.rpc('expire_subscriptions');
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('$result abonnement(s) expiré(s)'),
        backgroundColor: AppColors.secondary, behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Erreur: $e'),
        backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _confirmResetAll(BuildContext ctx, WidgetRef ref) {
    showDialog(context: ctx, builder: (_) => _SaDangerReauthDialog(
      icon: Icons.restart_alt_rounded,
      title: 'Réinitialiser la plateforme',
      warningTitle: 'Action irréversible',
      warningMessage:
          'Toutes les données utilisateurs seront supprimées : comptes, '
          'boutiques, produits, ventes, clients et abonnements. Seuls les '
          'super admins seront conservés. Cette action est irréversible.',
      confirmLabel: 'Tout réinitialiser',
      onConfirmed: () async {
        // 1. RPC SQL — supprime tables métier + profiles + tente auth.users
        final result = await Supabase.instance.client.rpc('reset_all_data');

        String? authError;
        int deletedAuth = 0;
        int deletedProfiles = 0;
        if (result is Map) {
          authError = result['auth_error'] as String?;
          deletedAuth = (result['deleted_auth_users'] as num?)?.toInt() ?? 0;
          deletedProfiles =
              (result['deleted_profiles'] as num?)?.toInt() ?? 0;
        }

        // 2. Fallback Edge Function si le RPC n'a pas pu toucher auth.users
        if (authError != null) {
          try {
            final fn = await Supabase.instance.client.functions.invoke(
                'reset-platform',
                body: {'mode': 'auth-cleanup'});
            if (fn.data is Map) {
              final extraDeleted =
                  (fn.data['deleted_auth_users'] as num?)?.toInt() ?? 0;
              deletedAuth += extraDeleted;
              if (extraDeleted > 0) authError = null;
            }
          } catch (_) {
            // L'Edge Function n'est peut-être pas déployée — on ignore.
          }
        }

        // 3. Fermer les channels Realtime avant de vider Hive
        AppDatabase.dispose();

        // 4. Vider TOUT le cache Hive local + secure storage.
        //    CRITIQUE : usersBox contient `_pwd` en clair par utilisateur et
        //    SecureStorage conserve `_pwd_<email>` → sans ce nettoyage, le
        //    fallback _offlineLogin() authentifierait encore un ancien compte
        //    supprimé côté Supabase.
        try {
          await HiveBoxes.shopsBox.clear();
          await HiveBoxes.productsBox.clear();
          await HiveBoxes.clientsBox.clear();
          await HiveBoxes.ordersBox.clear();
          await HiveBoxes.salesBox.clear();
          await HiveBoxes.membershipsBox.clear();
          await HiveBoxes.offlineQueueBox.clear();
          await HiveBoxes.cartBox.clear();
          await HiveBoxes.usersBox.clear();
          // Boxes cycle de vie produit
          await HiveBoxes.suppliersBox.clear();
          await HiveBoxes.receptionsBox.clear();
          await HiveBoxes.incidentsBox.clear();
          await HiveBoxes.stockMovementsBox.clear();
          await HiveBoxes.purchaseOrdersBox.clear();
          await HiveBoxes.stockArrivalsBox.clear();
          await SecureStorageService.clearAll();      // ← tokens + tous les _pwd_*
          // Purger les clés settings non essentielles (on garde la locale)
          final keepKeys = {'app_locale'};
          final toDelete = HiveBoxes.settingsBox.keys
              .where((k) => !keepKeys.contains(k))
              .toList();
          await HiveBoxes.settingsBox.deleteAll(toDelete);
        } catch (_) {}

        // 4. Rafraîchir TOUS les providers (super admin + dashboard boutique)
        ref.invalidate(_saStatsProvider);
        ref.invalidate(_saUsersProvider);
        ref.invalidate(_saShopsProvider);
        ref.invalidate(_saPaymentsProvider);
        ref.invalidate(_saPlansProvider);
        AppDatabase.notifyAllChanged();

        if (ctx.mounted) {
          if (authError != null) {
            AppSnack.warning(ctx,
                'Données effacées ($deletedProfiles profils) mais $deletedAuth '
                'compte(s) Auth supprimé(s). Erreur : $authError. '
                'Déployez la fonction reset-platform ou appliquez la migration 002.');
          } else {
            AppSnack.success(ctx,
                'Plateforme réinitialisée. $deletedProfiles profils et '
                '$deletedAuth compte(s) Auth supprimés, cache local vidé.');
          }

          // 5. Forcer la déconnexion du super admin : son propre mot de passe
          //    et son token viennent d'être effacés du cache local. Se
          //    reconnecter garantit un état propre, et empêche tout ancien
          //    JWT/session de continuer à rouler sur cet appareil.
          await Future.delayed(const Duration(milliseconds: 800));
          if (ctx.mounted) {
            ctx.read<AuthBloc>().add(AuthLogoutRequested());
          }
        }
      },
    ));
  }
}


// ════════════════════════════════════════════════════════════════════════════
// WIDGETS RÉUTILISABLES
// ════════════════════════════════════════════════════════════════════════════

class _KpiCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _KpiCard(this.label, this.value, this.icon, this.color);
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 160,
    height: 110,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 30, height: 30,
              decoration: BoxDecoration(color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 20, color: color)),
          const Spacer(),
        ]),
        const Spacer(),
        Text(value, style: TextStyle(fontSize: 24,
            fontWeight: FontWeight.w800, color: color)),
        Text(label, style: const TextStyle(fontSize: 11,
            color: AppColors.textSecondary)),
      ]),
    ),
  );
}

class _QuickAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction(this.label, this.icon, this.color, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 130,
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Alert extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String message;
  final VoidCallback? onTap;
  const _Alert({required this.color, required this.icon,
    required this.message, this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3))),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: color))),
        if (onTap != null)
          Icon(Icons.chevron_right_rounded, size: 16, color: color.withOpacity(0.7)),
      ]),
    ),
  );
}

class _FilterBar extends StatelessWidget {
  final String hint, selected;
  final ValueChanged<String> onSearch, onFilter;
  final List<String> filters, filterValues;
  final bool showSearch;
  const _FilterBar({required this.hint, required this.onSearch,
    required this.filters, required this.filterValues,
    required this.selected, required this.onFilter, this.showSearch = true});

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: Column(children: [
      if (showSearch) ...[
        SizedBox(height: 36, child: TextField(onChanged: onSearch,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            prefixIcon: const Icon(Icons.search, size: 16, color: AppColors.textSecondary),
            filled: true, fillColor: AppColors.inputFill,
            isDense: true, contentPadding: EdgeInsets.zero,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.inputBorder)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.inputBorder)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.primary)),
          ),
        )),
        const SizedBox(height: 6),
      ],
      SizedBox(height: 26, child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        itemBuilder: (_, i) {
          final sel = filterValues[i] == selected;
          return GestureDetector(
            onTap: () => onFilter(filterValues[i]),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: sel ? AppColors.primarySurface : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: sel ? AppColors.primary : AppColors.inputBorder),
              ),
              child: Text(filters[i], style: TextStyle(fontSize: 11,
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                  color: sel ? AppColors.primary : const Color(0xFF374151))),
            ),
          );
        },
      )),
    ]),
  );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Row(children: [
    Container(width: 20, height: 20,
        decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.12),
            borderRadius: BorderRadius.circular(5)),
        child: Icon(Icons.label_rounded, size: 11, color: AppColors.primary)),
    const SizedBox(width: 7),
    Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
        color: AppColors.primary, letterSpacing: 0.3)),
  ]);
}

class _UserCard extends StatelessWidget {
  final Map<String,dynamic> user;
  final VoidCallback onRefresh;
  const _UserCard({required this.user, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final name      = user['name']  as String? ?? '—';
    final email     = user['email'] as String? ?? '—';
    final isBlocked = user['prof_status'] == 'blocked';
    final isSA      = user['is_super_admin'] as bool? ?? false;
    final sub       = (user['subscriptions'] as List?)?.firstOrNull as Map?;
    final plan      = sub?['plans'] as Map?;
    final now       = DateTime.now();
    final exp       = sub?['expires_at'] != null ? DateTime.tryParse(sub!['expires_at']) : null;
    final isExpired = exp != null && exp.isBefore(now);
    final initials  = name.trim().split(' ')
        .map((w) => w.isNotEmpty ? w[0] : '').take(2).join().toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: isBlocked ? AppColors.error.withOpacity(0.4) : AppColors.inputBorder,
              width: isBlocked ? 1.5 : 1)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: CircleAvatar(
          radius: 19,
          backgroundColor: isBlocked
              ? AppColors.error.withOpacity(0.1) : AppColors.primarySurface,
          child: Text(initials.isNotEmpty ? initials : '?',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: isBlocked ? AppColors.error : AppColors.primary)),
        ),
        title: Row(children: [
          Flexible(child: Text(name, style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600))),
          if (isSA) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(4)),
              child: Text('SA', style: TextStyle(fontSize: 8,
                  fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
          ],
        ]),
        subtitle: Text(email, style: const TextStyle(
            fontSize: 11, color: AppColors.textSecondary)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (plan != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: isExpired
                      ? AppColors.error.withOpacity(0.1) : AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(5)),
              child: Text(plan['label'] ?? '—', style: TextStyle(fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: isExpired ? AppColors.error : AppColors.primary)),
            )
          else
            const Text('Sans plan', style: TextStyle(fontSize: 10,
                color: AppColors.textSecondary)),
          PopupMenuButton<String>(
            onSelected: (v) => _action(context, v),
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            itemBuilder: (_) => [
              if (!isSA) ...[
                if (isBlocked)
                  _item('unblock', Icons.check_circle_outline, 'Activer', AppColors.secondary)
                else
                  _item('block', Icons.block_rounded, 'Bloquer', AppColors.error),
                _item('sub', Icons.card_membership_rounded, 'Abonnement', AppColors.primary),
                _item('reset', Icons.lock_reset_rounded, 'Réinitialiser mdp', AppColors.warning),
                _item('delete', Icons.delete_outline_rounded, 'Supprimer', AppColors.error),
              ],
              _item('details', Icons.info_outline_rounded, 'Détails', AppColors.textSecondary),
            ],
          ),
        ]),
      ),
    );
  }

  PopupMenuItem<String> _item(String v, IconData icon, String label, Color color) =>
      PopupMenuItem(value: v, child: Row(children: [
        Icon(icon, size: 14, color: color), const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ]));

  void _action(BuildContext ctx, String v) {
    switch (v) {
      case 'block':   _setStatus(ctx, 'blocked');  break;
      case 'unblock': _setStatus(ctx, 'active');   break;
      case 'sub':     _showSub(ctx);               break;
      case 'reset':   _resetPwd(ctx);              break;
      case 'delete':  _confirmDel(ctx);            break;
      case 'details': _showDetails(ctx);           break;
    }
  }

  Future<void> _setStatus(BuildContext ctx, String status) async {
    await Supabase.instance.client.from('profiles').update({
      'prof_status': status,
      if (status == 'blocked') 'blocked_at': DateTime.now().toIso8601String()
      else 'blocked_at': null,
    }).eq('id', user['id']);
    await ActivityLogService.log(
      action:      status == 'blocked' ? 'user_blocked' : 'user_unblocked',
      targetType:  'user',
      targetId:    user['id'] as String?,
      targetLabel: user['name'] as String? ?? user['email'] as String?,
      details:     {'email': user['email']},
    );
    onRefresh();
  }

  void _resetPwd(BuildContext ctx) {
    showDialog(context: ctx, builder: (_) => _ResetPasswordDialog(
        targetEmail: user['email'] as String? ?? '',
        targetName:  user['name']  as String? ?? '—'));
  }

  void _confirmDel(BuildContext ctx) {
    final name  = user['name']  as String? ?? '—';
    final email = user['email'] as String? ?? '';
    final uid   = user['id']    as String;
    showDialog(context: ctx, builder: (_) => _SaDangerReauthDialog(
      icon: Icons.delete_forever_rounded,
      title: 'Supprimer le compte',
      warningTitle: 'Action irréversible',
      warningMessage:
          'Supprimer $name supprimera toutes ses boutiques, ventes, '
          'produits et abonnements. Cette action est irréversible.',
      confirmLabel: 'Supprimer définitivement',
      onConfirmed: () async {
        await Supabase.instance.client
            .rpc('delete_user_account', params: {'p_user_id': uid});
        // La RPC journalise déjà 'user_deleted' côté SQL — pas de doublon ici.
        onRefresh();
      },
    ));
  }

  void _showSub(BuildContext ctx) {
    showModalBottomSheet(context: ctx, isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _SubSheet(
            userId: user['id'], userName: user['name'] ?? '—',
            currentPlanName: ((user['subscriptions'] as List?)?.firstOrNull
            as Map?)?['plans']?['name'] as String?,
            onSaved: onRefresh));
  }

  void _showDetails(BuildContext ctx) {
    final fmt  = DateFormat('dd/MM/yyyy HH:mm');
    final sub  = (user['subscriptions'] as List?)?.firstOrNull as Map?;
    final plan = sub?['plans'] as Map?;
    showModalBottomSheet(context: ctx, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(user['name'] ?? '—', style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              _DetailRow('Email',    user['email'] ?? '—'),
              _DetailRow('Téléphone', user['phone'] ?? '—'),
              _DetailRow('Statut',   user['prof_status'] ?? '—'),
              _DetailRow('Plan',     plan?['label'] ?? 'Aucun'),
              _DetailRow('Abonnement', sub?['sub_status'] ?? '—'),
              if (sub?['expires_at'] != null)
                _DetailRow('Expire le', fmt.format(DateTime.parse(sub!['expires_at']))),
              if (sub?['amount_paid'] != null)
                _DetailRow('Montant', '${sub!['amount_paid']} XAF'),
              if (user['created_at'] != null)
                _DetailRow('Inscrit le', fmt.format(DateTime.parse(user['created_at']))),
            ]),
      ),
    );
  }
}

class _ShopRow extends StatelessWidget {
  final Map<String,dynamic> shop;
  final VoidCallback? onToggle, onDelete;
  const _ShopRow({required this.shop, required this.onToggle, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final isActive = shop['is_active'] as bool? ?? true;
    final owner    = (shop['owner_profile'] ?? shop['profiles']) as Map?;
    final fmt      = DateFormat('dd/MM/yy');
    final created  = shop['created_at'] != null ? DateTime.tryParse(shop['created_at']) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isActive
              ? AppColors.inputBorder : AppColors.error.withOpacity(0.3))),
      child: Row(children: [
        Container(width: 36, height: 36,
            decoration: BoxDecoration(
                color: isActive ? AppColors.primarySurface : AppColors.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(9)),
            child: Icon(Icons.store_rounded, size: 17,
                color: isActive ? AppColors.primary : AppColors.error)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(shop['name'] ?? '—', style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600)),
          Text(owner != null
              ? '${owner['name'] ?? ''} · ${shop['sector'] ?? ''}' : shop['sector'] ?? '—',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          if (created != null)
            Text('Créée le ${fmt.format(created)}', style: const TextStyle(
                fontSize: 10, color: Color(0xFFD1D5DB))),
        ])),
        if (onToggle != null)
          PopupMenuButton<String>(
            onSelected: (v) { if (v == 't') onToggle?.call(); if (v == 'd') onDelete?.call(); },
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            itemBuilder: (_) => [
              PopupMenuItem(value: 't', child: Row(children: [
                Icon(isActive ? Icons.pause_circle_outline : Icons.play_circle_outline,
                    size: 15, color: isActive ? AppColors.warning : AppColors.secondary),
                const SizedBox(width: 8),
                Text(isActive ? 'Désactiver' : 'Activer',
                    style: TextStyle(fontSize: 12,
                        color: isActive ? AppColors.warning : AppColors.secondary)),
              ])),
              const PopupMenuItem(value: 'd', child: Row(children: [
                Icon(Icons.delete_outline, size: 15, color: AppColors.error),
                SizedBox(width: 8),
                Text('Supprimer', style: TextStyle(fontSize: 12, color: AppColors.error)),
              ])),
            ],
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
                color: isActive ? AppColors.secondary.withOpacity(0.1) : AppColors.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(5)),
            child: Text(isActive ? 'Active' : 'Inactive',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
                    color: isActive ? AppColors.secondary : AppColors.error)),
          ),
      ]),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  final Map<String,dynamic> payment;
  const _PaymentRow({required this.payment});
  @override
  Widget build(BuildContext context) {
    final plan   = payment['plans'] as Map?;
    final fmt    = DateFormat('dd/MM/yy');
    final date   = payment['started_at'] != null ? DateTime.tryParse(payment['started_at']) : null;
    final amount = (payment['amount_paid'] as num?)?.toDouble() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.inputBorder)),
      child: Row(children: [
        Container(width: 32, height: 32,
            decoration: BoxDecoration(color: AppColors.secondary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.payments_rounded, size: 15, color: AppColors.secondary)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(plan?['label'] ?? '—', style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600)),
          Text(_cycleLabel(payment['billing_cycle']),
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${_fmt(amount)} XAF', style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.secondary)),
          if (date != null) Text(fmt.format(date),
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
        ]),
      ]),
    );
  }
}

class _PaymentCard extends StatelessWidget {
  final Map<String,dynamic> payment;
  final VoidCallback onRefresh;
  const _PaymentCard({required this.payment, required this.onRefresh});
  @override
  Widget build(BuildContext context) {
    final profile = payment['profiles'] as Map?;
    final plan    = payment['plans']    as Map?;
    final fmt     = DateFormat('dd/MM/yyyy');
    final date    = payment['started_at'] != null ? DateTime.tryParse(payment['started_at']) : null;
    final exp     = payment['expires_at'] != null ? DateTime.tryParse(payment['expires_at']) : null;
    final amount  = (payment['amount_paid'] as num?)?.toDouble() ?? 0;
    final status  = payment['sub_status'] as String? ?? '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.inputBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(profile?['name'] ?? profile?['email'] ?? '—',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            Text(profile?['email'] ?? '—',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          ])),
          Text('${_fmt(amount)} XAF', style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.secondary)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          _Badge(plan?['label'] ?? '—', AppColors.primary),
          const SizedBox(width: 5),
          _Badge(_cycleLabel(payment['billing_cycle']), AppColors.textSecondary),
          const SizedBox(width: 5),
          _StatusBadge(status),
          const Spacer(),
          if (payment['payment_ref'] != null)
            Text('Réf: ${payment['payment_ref']}', style: const TextStyle(
                fontSize: 10, color: AppColors.textSecondary)),
        ]),
        if (date != null || exp != null) ...[
          const SizedBox(height: 4),
          Text([if (date != null) 'Du ${fmt.format(date)}',
            if (exp != null) 'au ${fmt.format(exp)}'].join(' '),
              style: const TextStyle(fontSize: 10, color: Color(0xFFD1D5DB))),
        ],
        if (status != 'active') ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => showModalBottomSheet(
              context: context, isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _SubSheet(
                  userId: payment['user_id'] as String? ?? '',
                  userName: (payment['profiles'] as Map?)?['name'] ?? '—',
                  currentPlanName: (payment['plans'] as Map?)?['name'] as String?,
                  onSaved: onRefresh),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primary.withOpacity(0.3))),
              child: Text('Activer / Renouveler', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
          ),
        ],
      ]),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final Map<String,dynamic> plan;
  final VoidCallback onEdit;
  const _PlanCard({required this.plan, required this.onEdit});
  @override
  Widget build(BuildContext context) {
    final features = plan['features'] as List? ?? [];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.inputBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(plan['label'] ?? '—', style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.primary)),
          const Spacer(),
          GestureDetector(
            onTap: onEdit,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(8)),
              child: Text('Modifier', style: TextStyle(fontSize: 11,
                  fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        const Divider(height: 1, color: Color(0xFFF0F0F0)),
        const SizedBox(height: 10),
        Row(children: [
          _PriceCol('Mensuel',     plan['price_monthly']),
          _PriceCol('Trimestriel', plan['price_quarterly']),
          _PriceCol('Annuel',      plan['price_yearly']),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 4, children: [
          _InfoPill('${plan['max_shops']} boutique(s)', Icons.store_rounded),
          _InfoPill('${plan['max_users_per_shop']} users/shop', Icons.people_rounded),
          if (plan['offline_enabled'] == true)
            _InfoPill('Hors-ligne', Icons.wifi_off_rounded, color: AppColors.secondary),
        ]),
        if (features.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: features.map((f) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: AppColors.inputFill,
                borderRadius: BorderRadius.circular(4)),
            child: Text(f.toString(), style: const TextStyle(
                fontSize: 10, color: AppColors.textSecondary)),
          )).toList()),
        ],
      ]),
    );
  }
}

class _PriceCol extends StatelessWidget {
  final String label;
  final dynamic value;
  const _PriceCol(this.label, this.value);
  @override
  Widget build(BuildContext context) => Expanded(child: Column(children: [
    Text('${_fmt((value as num?)?.toDouble() ?? 0)} XAF',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
            color: AppColors.primary)),
    Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
  ]));
}

class _InfoPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color? color;
  const _InfoPill(this.label, this.icon, {this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
        color: (color ?? AppColors.primary).withOpacity(0.08),
        borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 10, color: color ?? AppColors.primary),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
          color: color ?? AppColors.primary)),
    ]),
  );
}

class _LogEntry {
  final String    action;      // raw action name (product_created, user_login…)
  final String    category;    // auth|shop|sale|account|alert|other
  final String    message;     // "Nouveau produit : Coca 33cl"
  final String    actorName;   // "Alice Martin" (ou email si name absent)
  final String?   targetLabel; // nom de la cible affichable
  final DateTime? date;
  final IconData  icon;
  final Color     color;

  const _LogEntry({
    required this.action,
    required this.category,
    required this.message,
    required this.actorName,
    required this.icon,
    required this.color,
    this.targetLabel,
    this.date,
  });

  /// Construit depuis une ligne activity_logs + nom résolu de l'acteur.
  factory _LogEntry.fromRow(Map<String, dynamic> r, {required String actorName}) {
    final action      = r['action']       as String? ?? 'unknown';
    final targetLabel = r['target_label'] as String?;
    final date        = r['created_at'] != null
        ? DateTime.tryParse(r['created_at'] as String)
        : null;
    final meta = _metaFor(action);
    return _LogEntry(
      action:      action,
      category:    meta.category,
      icon:        meta.icon,
      color:       meta.color,
      actorName:   actorName,
      targetLabel: targetLabel,
      date:        date,
      message:     _messageFor(action, targetLabel),
    );
  }
}

// Mapping action → catégorie / icône / couleur
class _LogMeta {
  final String   category;
  final IconData icon;
  final Color    color;
  const _LogMeta(this.category, this.icon, this.color);
}

_LogMeta _metaFor(String action) {
  switch (action) {
    case 'user_login':
      return const _LogMeta('auth', Icons.login_rounded, AppColors.secondary);
    case 'shop_created':
      return _LogMeta('shop', Icons.storefront_rounded, AppColors.primary);
    case 'shop_reset':
      return const _LogMeta('alert', Icons.cleaning_services_rounded, AppColors.warning);
    case 'sale_completed':
      return const _LogMeta('sale', Icons.point_of_sale_rounded, AppColors.secondary);
    case 'product_created':
      return _LogMeta('shop', Icons.add_box_outlined, AppColors.primary);
    case 'product_updated':
      return _LogMeta('shop', Icons.edit_outlined, AppColors.primary);
    case 'product_deleted':
      return const _LogMeta('shop', Icons.delete_outline_rounded, AppColors.warning);
    case 'user_blocked':
      return const _LogMeta('alert', Icons.block_rounded, AppColors.error);
    case 'user_unblocked':
      return const _LogMeta('account', Icons.check_circle_outline_rounded, AppColors.secondary);
    case 'subscription_activated':
      return const _LogMeta('account', Icons.verified_rounded, AppColors.secondary);
    case 'subscription_cancelled':
      return const _LogMeta('account', Icons.cancel_outlined, AppColors.warning);
    case 'user_deleted':
    case 'account_deleted':
      return const _LogMeta('alert', Icons.person_remove_rounded, AppColors.error);
    case 'platform_reset':
      return const _LogMeta('alert', Icons.restart_alt_rounded, AppColors.error);
    default:
      return const _LogMeta('other', Icons.info_outline_rounded, AppColors.textSecondary);
  }
}

String _messageFor(String action, String? label) {
  final l = (label != null && label.isNotEmpty) ? ' : $label' : '';
  switch (action) {
    case 'user_login':              return 'Connexion$l';
    case 'shop_created':            return 'Nouvelle boutique$l';
    case 'shop_reset':              return 'Boutique réinitialisée$l';
    case 'sale_completed':          return 'Vente encaissée${label == null ? '' : ' — $label'}';
    case 'product_created':         return 'Produit créé$l';
    case 'product_updated':         return 'Produit modifié$l';
    case 'product_deleted':         return 'Produit supprimé$l';
    case 'user_blocked':            return 'Utilisateur bloqué$l';
    case 'user_unblocked':          return 'Utilisateur débloqué$l';
    case 'subscription_activated':  return 'Abonnement activé$l';
    case 'subscription_cancelled':  return 'Abonnement annulé$l';
    case 'user_deleted':            return 'Compte supprimé$l';
    case 'account_deleted':         return 'Auto-suppression de compte$l';
    case 'platform_reset':          return 'Plateforme réinitialisée';
    default:                        return action.replaceAll('_', ' ');
  }
}

class _LogTile extends StatelessWidget {
  final _LogEntry entry;
  const _LogTile({required this.entry});
  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd/MM/yy HH:mm');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.inputBorder)),
      child: Row(children: [
        Container(width: 28, height: 28,
            decoration: BoxDecoration(color: entry.color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(7)),
            child: Icon(entry.icon, size: 14, color: entry.color)),
        const SizedBox(width: 10),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(entry.message, style: const TextStyle(
              fontSize: 12, color: AppColors.textPrimary)),
          Text('Par ${entry.actorName}', style: const TextStyle(
              fontSize: 10, color: AppColors.textSecondary)),
        ])),
        if (entry.date != null)
          Text(fmt.format(entry.date!), style: const TextStyle(
              fontSize: 10, color: AppColors.textSecondary)),
      ]),
    );
  }
}

// ─── Sheet abonnement ─────────────────────────────────────────────────────────
class _SubSheet extends StatefulWidget {
  final String userId, userName;
  final String? currentPlanName;
  final VoidCallback onSaved;
  const _SubSheet({required this.userId, required this.userName,
    this.currentPlanName, required this.onSaved});
  @override State<_SubSheet> createState() => _SubSheetState();
}

class _SubSheetState extends State<_SubSheet> {
  late String _plan;
  String _cycle = 'monthly';
  bool _saving  = false;
  final _refCtrl   = TextEditingController();
  final _notesCtrl = TextEditingController();

  @override void initState() { super.initState(); _plan = widget.currentPlanName ?? 'normal'; }
  @override void dispose() { _refCtrl.dispose(); _notesCtrl.dispose(); super.dispose(); }

  double get _price => switch ('${_plan}_$_cycle') {
    'normal_monthly'   => 5000,  'normal_quarterly' => 13500,
    'normal_yearly'    => 50000, 'pro_monthly'      => 10000,
    'pro_quarterly'    => 27000, 'pro_yearly'       => 100000,
    _                  => 0,
  };

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).padding.bottom),
    child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(color: AppColors.inputBorder,
                  borderRadius: BorderRadius.circular(2)))),
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text("Gérer l'abonnement",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              Text(widget.userName, style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
            ])),
            Text('${_price.toStringAsFixed(0)} XAF', style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.primary)),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _Btn('Normal', 'normal', _plan, (v) => setState(() => _plan = v))),
            const SizedBox(width: 8),
            Expanded(child: _Btn('Pro',    'pro',    _plan, (v) => setState(() => _plan = v))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _Btn('Mensuel',     'monthly',   _cycle, (v) => setState(() => _cycle = v))),
            const SizedBox(width: 6),
            Expanded(child: _Btn('Trimestriel', 'quarterly', _cycle, (v) => setState(() => _cycle = v))),
            const SizedBox(width: 6),
            Expanded(child: _Btn('Annuel',      'yearly',    _cycle, (v) => setState(() => _cycle = v))),
          ]),
          const SizedBox(height: 10),
          _Field(controller: _refCtrl, hint: 'Référence paiement', icon: Icons.receipt_outlined),
          const SizedBox(height: 6),
          _Field(controller: _notesCtrl, hint: 'Notes internes', icon: Icons.notes_rounded),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: _saving ? null : _save,
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                elevation: 0, padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white))
                : const Text('Enregistrer', style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700)),
          )),
        ]),
  );

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final planRow = await Supabase.instance.client
          .from('plans').select('id').eq('name', _plan).single();
      final now = DateTime.now();
      final exp = switch (_cycle) {
        'monthly'   => DateTime(now.year, now.month + 1, now.day),
        'quarterly' => DateTime(now.year, now.month + 3, now.day),
        _           => DateTime(now.year + 1, now.month, now.day),
      };
      final cancelled = await Supabase.instance.client.from('subscriptions')
          .update({'sub_status': 'cancelled', 'cancelled_at': now.toIso8601String()})
          .eq('user_id', widget.userId).eq('sub_status', 'active')
          .select();
      if ((cancelled as List).isNotEmpty) {
        await ActivityLogService.log(
          action:      'subscription_cancelled',
          targetType:  'subscription',
          targetId:    widget.userId,
          targetLabel: widget.userName,
        );
      }
      await Supabase.instance.client.from('subscriptions').insert({
        'user_id': widget.userId, 'plan_id': planRow['id'],
        'billing_cycle': _cycle, 'sub_status': 'active',
        'expires_at': exp.toIso8601String(), 'amount_paid': _price,
        'payment_ref': _refCtrl.text.trim().isEmpty ? null : _refCtrl.text.trim(),
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      });
      await ActivityLogService.log(
        action:      'subscription_activated',
        targetType:  'subscription',
        targetId:    widget.userId,
        targetLabel: widget.userName,
        details:     {'plan': _plan, 'cycle': _cycle, 'amount': _price},
      );
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Erreur: $e'), backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

// ─── Sheet modifier plan ──────────────────────────────────────────────────────
class _EditPlanSheet extends StatefulWidget {
  final Map<String,dynamic> plan;
  final VoidCallback onSaved;
  const _EditPlanSheet({required this.plan, required this.onSaved});
  @override State<_EditPlanSheet> createState() => _EditPlanSheetState();
}

class _EditPlanSheetState extends State<_EditPlanSheet> {
  late TextEditingController _monthly, _quarterly, _yearly, _maxShops, _maxUsers;
  late bool _offline, _active;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _monthly   = TextEditingController(text: '${widget.plan['price_monthly'] ?? ''}');
    _quarterly = TextEditingController(text: '${widget.plan['price_quarterly'] ?? ''}');
    _yearly    = TextEditingController(text: '${widget.plan['price_yearly'] ?? ''}');
    _maxShops  = TextEditingController(text: '${widget.plan['max_shops'] ?? '1'}');
    _maxUsers  = TextEditingController(text: '${widget.plan['max_users_per_shop'] ?? '3'}');
    _offline   = widget.plan['offline_enabled'] as bool? ?? false;
    _active    = widget.plan['is_active'] as bool? ?? true;
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).padding.bottom),
    child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Container(width: 36, height: 4,
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(color: AppColors.inputBorder,
              borderRadius: BorderRadius.circular(2)))),
      Text('Modifier — ${widget.plan['label']}', style: const TextStyle(
          fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: _Field(controller: _monthly, hint: 'Mensuel',
            icon: Icons.calendar_today_rounded, type: TextInputType.number)),
        const SizedBox(width: 6),
        Expanded(child: _Field(controller: _quarterly, hint: 'Trimestriel',
            icon: Icons.date_range_rounded, type: TextInputType.number)),
        const SizedBox(width: 6),
        Expanded(child: _Field(controller: _yearly, hint: 'Annuel',
            icon: Icons.calendar_month_rounded, type: TextInputType.number)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _Field(controller: _maxShops, hint: 'Max boutiques',
            icon: Icons.store_rounded, type: TextInputType.number)),
        const SizedBox(width: 6),
        Expanded(child: _Field(controller: _maxUsers, hint: 'Max users',
            icon: Icons.people_rounded, type: TextInputType.number)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        const Expanded(child: Text('Mode hors-ligne',
            style: TextStyle(fontSize: 13))),
        AppSwitch(value: _offline,
            onChanged: (v) => setState(() => _offline = v)),
      ]),
      Row(children: [
        const Expanded(child: Text('Plan actif',
            style: TextStyle(fontSize: 13))),
        AppSwitch(value: _active,
            onChanged: (v) => setState(() => _active = v)),
      ]),
      const SizedBox(height: 14),
      SizedBox(width: double.infinity, child: ElevatedButton(
        onPressed: _saving ? null : _save,
        style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary, foregroundColor: Colors.white,
            elevation: 0, padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        child: _saving
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(
            strokeWidth: 2, color: Colors.white))
            : const Text('Enregistrer', style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w700)),
      )),
    ])),
  );

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('plans').update({
        'price_monthly':      double.tryParse(_monthly.text)   ?? 0,
        'price_quarterly':    double.tryParse(_quarterly.text) ?? 0,
        'price_yearly':       double.tryParse(_yearly.text)    ?? 0,
        'max_shops':          int.tryParse(_maxShops.text)     ?? 1,
        'max_users_per_shop': int.tryParse(_maxUsers.text)     ?? 3,
        'offline_enabled':    _offline,
        'is_active':          _active,
      }).eq('id', widget.plan['id']);
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Erreur: $e'), backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

// ─── Settings widgets ─────────────────────────────────────────────────────────
class _SettingsCard extends StatelessWidget {
  final List<Widget> items;
  const _SettingsCard({required this.items});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.inputBorder),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
            blurRadius: 8, offset: const Offset(0, 2))]),
    child: Column(children: [
      for (int i = 0; i < items.length; i++) ...[
        items[i],
        if (i < items.length - 1)
          const Divider(height: 1, indent: 56, color: AppColors.inputFill),
      ],
    ]),
  );
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label, subtitle;
  final Color? color;
  final VoidCallback onTap;
  const _SettingsTile({required this.icon, required this.label,
    required this.subtitle, required this.onTap, this.color});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(children: [
        Container(width: 36, height: 36,
            decoration: BoxDecoration(
                color: (color ?? AppColors.primary).withOpacity(0.1),
                borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 17, color: color ?? AppColors.primary)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
              color: color ?? AppColors.textPrimary)),
          Text(subtitle, style: const TextStyle(fontSize: 11,
              color: AppColors.textSecondary)),
        ])),
        Icon(Icons.chevron_right_rounded, size: 16,
            color: AppColors.textSecondary.withOpacity(0.5)),
      ]),
    ),
  );
}

// ─── Petits widgets ───────────────────────────────────────────────────────────
class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: TextStyle(fontSize: 9,
        fontWeight: FontWeight.w700, color: color)),
  );
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge(this.status);
  @override
  Widget build(BuildContext context) {
    final (c, l) = switch (status) {
      'active'    => (AppColors.secondary, 'Actif'),
      'expired'   => (AppColors.error,     'Expiré'),
      'cancelled' => (AppColors.textSecondary, 'Annulé'),
      'trial'     => (AppColors.warning,   'Essai'),
      _           => (AppColors.textSecondary, status),
    };
    return _Badge(l, c);
  }
}

class _Btn extends StatelessWidget {
  final String label, value, selected;
  final ValueChanged<String> onTap;
  const _Btn(this.label, this.value, this.selected, this.onTap);
  @override
  Widget build(BuildContext context) {
    final sel = value == selected;
    return GestureDetector(
      onTap: () => onTap(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
            color: sel ? AppColors.primary : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: sel ? AppColors.primary : AppColors.inputBorder)),
        child: Text(label, textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: sel ? Colors.white : const Color(0xFF374151))),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType? type;
  const _Field({required this.controller, required this.hint,
    required this.icon, this.type});
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller, keyboardType: type,
    style: const TextStyle(fontSize: 13),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
      prefixIcon: Icon(icon, size: 16, color: AppColors.textSecondary),
      filled: true, fillColor: AppColors.inputFill, isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.inputBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.inputBorder)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary)),
    ),
  );
}

class _DetailRow extends StatelessWidget {
  final String label, value;
  const _DetailRow(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      SizedBox(width: 100, child: Text(label, style: const TextStyle(
          fontSize: 11, color: AppColors.textSecondary))),
      Expanded(child: Text(value, style: const TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600))),
    ]),
  );
}

class _ConfirmDialog extends StatelessWidget {
  final String title, body, confirmLabel;
  final Color confirmColor;
  final VoidCallback onConfirm;
  const _ConfirmDialog({required this.title, required this.body,
    required this.confirmLabel, required this.confirmColor, required this.onConfirm});
  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    content: Text(body, style: const TextStyle(fontSize: 13)),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler', style: TextStyle(color: AppColors.textSecondary))),
      ElevatedButton(
        onPressed: () { Navigator.of(context).pop(); onConfirm(); },
        style: ElevatedButton.styleFrom(
            backgroundColor: confirmColor, foregroundColor: Colors.white,
            elevation: 0, shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10))),
        child: Text(confirmLabel),
      ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState(this.message);
  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.inbox_rounded, size: 40, color: Color(0xFFD1D5DB)),
      const SizedBox(height: 10),
      Text(message, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState(this.message);
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(padding: const EdgeInsets.all(24),
        child: Text('Erreur: $message',
            style: const TextStyle(color: AppColors.error, fontSize: 13))),
  );
}


// ─── Dialogue réinitialisation mot de passe — authentification requise ─────────
class _ResetPasswordDialog extends StatefulWidget {
  final String targetEmail, targetName;
  const _ResetPasswordDialog({required this.targetEmail, required this.targetName});
  @override State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _pwdCtrl    = TextEditingController();
  bool  _obscure    = true;
  bool  _loading    = false;
  bool  _verified   = false;  // étape 1 passée
  String? _error;

  @override void dispose() { _pwdCtrl.dispose(); super.dispose(); }

  // Étape 1 : Vérifier le mot de passe du super admin
  Future<void> _verifySA() async {
    if (_pwdCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Veuillez entrer votre mot de passe.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final saEmail = Supabase.instance.client.auth.currentUser?.email ?? '';
      // Re-authentifier le super admin pour confirmer son identité
      await Supabase.instance.client.auth.signInWithPassword(
          email: saEmail, password: _pwdCtrl.text.trim());
      setState(() { _verified = true; _loading = false; _pwdCtrl.clear(); });
    } on AuthException catch (e) {
      setState(() { _loading = false; _error = 'Mot de passe incorrect. ${e.message}'; });
    } catch (e) {
      setState(() { _loading = false; _error = "Erreur d'authentification."; });
    }
  }

  // Étape 2 : Envoyer le mail de réinitialisation
  Future<void> _sendReset() async {
    setState(() { _loading = true; _error = null; });
    try {
      await Supabase.instance.client.auth
          .resetPasswordForEmail(widget.targetEmail);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(
                'Email de réinitialisation envoyé à ${widget.targetEmail}',
                style: const TextStyle(fontSize: 12))),
          ]),
          backgroundColor: AppColors.secondary,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      setState(() { _loading = false; _error = 'Erreur: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      title: Row(children: [
        Container(width: 36, height: 36,
            decoration: BoxDecoration(
                color: AppColors.warning.withOpacity(0.1),
                shape: BoxShape.circle),
            child: const Icon(Icons.lock_reset_rounded,
                color: AppColors.warning, size: 18)),
        const SizedBox(width: 10),
        const Expanded(child: Text('Réinitialiser le mot de passe',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
      ]),
      content: SizedBox(
        width: 340,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _verified ? _step2() : _step1(),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.inputBorder),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          child: const Text('Annuler',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _loading ? null : (_verified ? _sendReset : _verifySA),
          style: ElevatedButton.styleFrom(
              backgroundColor: _verified ? AppColors.warning : AppColors.primary,
              foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          child: _loading
              ? const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
              : Text(_verified ? 'Envoyer le lien' : 'Vérifier',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  // ── Étape 1 : Saisie mot de passe SA ──────────────────────────────────────
  Widget _step1() => Column(
    key: const ValueKey('step1'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      RichText(text: TextSpan(
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
        children: [
          const TextSpan(text: 'Pour réinitialiser le mot de passe de '),
          TextSpan(text: widget.targetName,
              style: const TextStyle(fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const TextSpan(text: ", vous devez d'abord confirmer votre identité."),
        ],
      )),
      const SizedBox(height: 14),
      // Cible
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: AppColors.inputFill,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.inputBorder)),
        child: Row(children: [
          const Icon(Icons.person_outline_rounded,
              size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Compte cible',
                style: TextStyle(fontSize: 9,
                    color: AppColors.textSecondary)),
            Text(widget.targetEmail,
                style: const TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ])),
        ]),
      ),
      const SizedBox(height: 12),
      // Saisie mdp SA
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.primary.withOpacity(0.3))),
        child: Row(children: [
          Icon(Icons.shield_rounded,
              size: 15, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(child: TextField(
            controller: _pwdCtrl,
            obscureText: _obscure,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'Votre mot de passe super admin',
              hintStyle: TextStyle(fontSize: 12,
                  color: AppColors.textSecondary),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
            ),
          )),
          GestureDetector(
            onTap: () => setState(() => _obscure = !_obscure),
            child: Icon(_obscure
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
                size: 16, color: AppColors.textSecondary),
          ),
        ]),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.error_outline_rounded,
              size: 13, color: AppColors.error),
          const SizedBox(width: 6),
          Expanded(child: Text(_error!, style: const TextStyle(
              fontSize: 11, color: AppColors.error))),
        ]),
      ],
      const SizedBox(height: 8),
    ],
  );

  // ── Étape 2 : Confirmation envoi ──────────────────────────────────────────
  Widget _step2() => Column(
    key: const ValueKey('step2'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Badge succès authentification
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
            color: AppColors.secondary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.secondary.withOpacity(0.3))),
        child: Row(children: [
          const Icon(Icons.verified_rounded,
              size: 14, color: AppColors.secondary),
          const SizedBox(width: 8),
          const Text('Identité vérifiée',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: AppColors.secondary)),
        ]),
      ),
      const SizedBox(height: 12),
      RichText(text: TextSpan(
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
        children: [
          const TextSpan(text: 'Un lien de réinitialisation sera envoyé à '),
          TextSpan(text: widget.targetEmail,
              style: const TextStyle(fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const TextSpan(text: ".\n\nL'utilisateur devra cliquer sur ce lien pour définir un nouveau mot de passe."),
        ],
      )),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.error_outline_rounded,
              size: 13, color: AppColors.error),
          const SizedBox(width: 6),
          Expanded(child: Text(_error!, style: const TextStyle(
              fontSize: 11, color: AppColors.error))),
        ]),
      ],
      const SizedBox(height: 8),
    ],
  );
}

// ─── Dialogue action destructive super admin — 2 étapes (warning + re-auth) ──
// Pattern aligné sur _ResetPasswordDialog : vérifie le mot de passe du SA
// via signInWithPassword avant d'exécuter onConfirmed.
class _SaDangerReauthDialog extends StatefulWidget {
  final IconData    icon;
  final String      title;
  final String      warningTitle;
  final String      warningMessage;
  final String      confirmLabel;
  final Future<void> Function() onConfirmed;

  const _SaDangerReauthDialog({
    required this.icon,
    required this.title,
    required this.warningTitle,
    required this.warningMessage,
    required this.confirmLabel,
    required this.onConfirmed,
  });

  @override
  State<_SaDangerReauthDialog> createState() => _SaDangerReauthDialogState();
}

class _SaDangerReauthDialogState extends State<_SaDangerReauthDialog> {
  final _pwdCtrl = TextEditingController();
  bool   _obscure   = true;
  bool   _loading   = false;
  bool   _acknowledged = false; // étape 1 validée
  String? _error;

  @override
  void dispose() { _pwdCtrl.dispose(); super.dispose(); }

  Future<void> _verifyAndRun() async {
    if (_pwdCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Veuillez entrer votre mot de passe.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final saEmail = Supabase.instance.client.auth.currentUser?.email ?? '';
      await Supabase.instance.client.auth.signInWithPassword(
          email: saEmail, password: _pwdCtrl.text.trim());
      await widget.onConfirmed();
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('${widget.title} — terminé',
              style: const TextStyle(fontSize: 12))),
        ]),
        backgroundColor: AppColors.secondary,
        behavior: SnackBarBehavior.floating,
      ));
    } on AuthException catch (e) {
      setState(() { _loading = false;
          _error = 'Mot de passe incorrect. ${e.message}'; });
    } catch (e) {
      setState(() { _loading = false;
          _error = 'Erreur: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      title: Row(children: [
        Container(width: 36, height: 36,
            decoration: BoxDecoration(
                color: AppColors.error.withOpacity(0.1),
                shape: BoxShape.circle),
            child: Icon(widget.icon, color: AppColors.error, size: 18)),
        const SizedBox(width: 10),
        Expanded(child: Text(widget.title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
      ]),
      content: SizedBox(
        width: 340,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _acknowledged ? _step2() : _step1(),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.inputBorder),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          child: const Text('Annuler',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _loading
              ? null
              : (_acknowledged
                  ? _verifyAndRun
                  : () => setState(() => _acknowledged = true)),
          style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          child: _loading
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_acknowledged ? widget.confirmLabel : 'Continuer',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _step1() => Column(
    key: const ValueKey('step1'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: AppColors.error.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.error.withOpacity(0.3))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded,
              size: 16, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.warningTitle, style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700,
                color: AppColors.error)),
            const SizedBox(height: 4),
            Text(widget.warningMessage, style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary, height: 1.45)),
          ])),
        ]),
      ),
      const SizedBox(height: 8),
    ],
  );

  Widget _step2() => Column(
    key: const ValueKey('step2'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Confirmez votre identité en entrant votre mot de passe super admin.',
        style: TextStyle(fontSize: 12,
            color: AppColors.textSecondary, height: 1.5),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.primary.withOpacity(0.3))),
        child: Row(children: [
          Icon(Icons.shield_rounded,
              size: 15, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(child: TextField(
            controller: _pwdCtrl,
            obscureText: _obscure,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'Votre mot de passe super admin',
              hintStyle: TextStyle(fontSize: 12,
                  color: AppColors.textSecondary),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
            ),
          )),
          GestureDetector(
            onTap: () => setState(() => _obscure = !_obscure),
            child: Icon(_obscure
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
                size: 16, color: AppColors.textSecondary),
          ),
        ]),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.error_outline_rounded,
              size: 13, color: AppColors.error),
          const SizedBox(width: 6),
          Expanded(child: Text(_error!, style: const TextStyle(
              fontSize: 11, color: AppColors.error))),
        ]),
      ],
      const SizedBox(height: 8),
    ],
  );
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

void _showLogoutConfirm(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      icon: Container(width: 48, height: 48,
          decoration: BoxDecoration(
              color: AppColors.error.withOpacity(0.1),
              shape: BoxShape.circle),
          child: const Icon(Icons.logout_rounded,
              color: AppColors.error, size: 22)),
      title: const Text('Déconnexion',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      content: const Text(
          'Vous allez quitter le panneau administrateur.\n\nÊtes-vous sûr de vouloir vous déconnecter ?',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(ctx).pop(),
          style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.inputBorder),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10)),
          child: const Text('Annuler',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            context.read<AuthBloc>().add(AuthLogoutRequested());
          },
          style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10)),
          child: const Text('Déconnecter',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

String _fmt(double v) {
  final n = v.toInt();
  if (n >= 1000000) return '${(n/1000000).toStringAsFixed(1)}M';
  if (n >= 1000) { final s = n.toString();
  return '${s.substring(0, s.length-3)} ${s.substring(s.length-3)}'; }
  return n.toString();
}

String _cycleLabel(dynamic c) => switch (c) {
  'monthly'   => 'Mensuel',
  'quarterly' => 'Trimestriel',
  'yearly'    => 'Annuel',
  _           => '—',
};

// ════════════════════════════════════════════════════════════════════════════
// SECTION MAINTENANCE — Checklist préventive
// ════════════════════════════════════════════════════════════════════════════

enum _CheckStatus { pending, running, ok, warning, critical }

class _Check {
  final String label;
  final String category; // hebdo, mensuel, trimestriel
  _CheckStatus status = _CheckStatus.pending;
  String detail = '';
  bool autoFixable = false;
  Future<void> Function()? autoFix;
  _Check(this.label, this.category);
}

class _MaintenanceSection extends StatefulWidget {
  const _MaintenanceSection();
  @override State<_MaintenanceSection> createState() => _MaintenanceSectionState();
}

class _MaintenanceSectionState extends State<_MaintenanceSection> {
  late List<_Check> _checks;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _checks = _buildChecks();
  }

  List<_Check> _buildChecks() => [
    // ── Hebdomadaire ──
    _Check('Connexion Supabase', 'Hebdomadaire'),
    _Check('RPC reset_shop_data', 'Hebdomadaire'),
    _Check('RPC accept_shop_invitation', 'Hebdomadaire'),
    _Check('Invitations expirées', 'Hebdomadaire')..autoFixable = true,
    _Check('File offline (queue)', 'Hebdomadaire'),
    // ── Mensuel ──
    _Check('Version de l\'app', 'Mensuel'),
    _Check('Entrées Hive par box', 'Mensuel'),
    _Check('Orphelins Hive', 'Mensuel')..autoFixable = true,
    _Check('Invitations > 30 jours', 'Mensuel')..autoFixable = true,
    // ── Trimestriel ──
    _Check('Total utilisateurs', 'Trimestriel'),
    _Check('Total boutiques', 'Trimestriel'),
    _Check('Lignes par table', 'Trimestriel'),
  ];

  int get _passed => _checks.where((c) => c.status == _CheckStatus.ok).length;
  int get _warnings => _checks.where((c) => c.status == _CheckStatus.warning).length;
  int get _criticals => _checks.where((c) => c.status == _CheckStatus.critical).length;
  bool get _done => _checks.every((c) => c.status != _CheckStatus.pending && c.status != _CheckStatus.running);
  bool get _hasAutoFix => _checks.any((c) => c.autoFixable && (c.status == _CheckStatus.warning || c.status == _CheckStatus.critical));

  Future<void> _runAll() async {
    setState(() => _running = true);
    final db = Supabase.instance.client;

    for (final c in _checks) {
      setState(() => c.status = _CheckStatus.running);
      try {
        switch (c.label) {
          // ── Hebdomadaire ─────────────────────────────────────
          case 'Connexion Supabase':
            await db.from('profiles').select('id').limit(1).timeout(const Duration(seconds: 5));
            c.status = _CheckStatus.ok;
            c.detail = 'Connecté';

          case 'RPC reset_shop_data':
            // Ping avec un UUID inexistant — l'erreur attendue est "Boutique introuvable"
            try { await db.rpc('reset_shop_data', params: {'p_shop_id': '00000000-0000-0000-0000-000000000000'}); }
            catch (e) { if (e.toString().contains('introuvable')) { c.status = _CheckStatus.ok; c.detail = 'RPC accessible'; break; } rethrow; }

          case 'RPC accept_shop_invitation':
            try { await db.rpc('accept_shop_invitation', params: {'p_token': 'test_ping'}); }
            catch (e) { if (e.toString().contains('introuvable') || e.toString().contains('expir') || e.toString().contains('Invalid')) { c.status = _CheckStatus.ok; c.detail = 'RPC accessible'; break; } rethrow; }

          case 'Invitations expirées':
            final rows = await db.from('pending_invitations').select('id').lt('expires_at', DateTime.now().toIso8601String());
            final n = (rows as List).length;
            c.status = n == 0 ? _CheckStatus.ok : _CheckStatus.warning;
            c.detail = n == 0 ? 'Aucune' : '$n à nettoyer';
            c.autoFix = () async {
              await db.from('pending_invitations').delete().lt('expires_at', DateTime.now().toIso8601String());
              c.status = _CheckStatus.ok; c.detail = 'Nettoyées';
            };

          case 'File offline (queue)':
            final n = HiveBoxes.offlineQueueBox.length;
            c.status = n == 0 ? _CheckStatus.ok : n < 20 ? _CheckStatus.warning : _CheckStatus.critical;
            c.detail = '$n opération${n > 1 ? 's' : ''} en attente';

          // ── Mensuel ──────────────────────────────────────────
          case 'Version de l\'app':
            c.status = _CheckStatus.ok;
            c.detail = 'Fortress POS v1.0';

          case 'Entrées Hive par box':
            final counts = <String, int>{
              'shops': HiveBoxes.shopsBox.length,
              'products': HiveBoxes.productsBox.length,
              'orders': HiveBoxes.ordersBox.length,
              'clients': HiveBoxes.clientsBox.length,
              'sales': HiveBoxes.salesBox.length,
              'users': HiveBoxes.usersBox.length,
              'memberships': HiveBoxes.membershipsBox.length,
            };
            final total = counts.values.fold(0, (a, b) => a + b);
            c.status = total < 5000 ? _CheckStatus.ok : _CheckStatus.warning;
            c.detail = counts.entries.map((e) => '${e.key}: ${e.value}').join(', ');

          case 'Orphelins Hive':
            final shopIds = HiveBoxes.shopsBox.values.map((m) => m['id']?.toString()).whereType<String>().toSet();
            int orphans = 0;
            for (final m in HiveBoxes.productsBox.values) {
              final sid = (m as Map)['store_id']?.toString();
              if (sid != null && !shopIds.contains(sid)) orphans++;
            }
            for (final m in HiveBoxes.ordersBox.values) {
              final sid = (m as Map)['shop_id']?.toString();
              if (sid != null && !shopIds.contains(sid)) orphans++;
            }
            c.status = orphans == 0 ? _CheckStatus.ok : _CheckStatus.warning;
            c.detail = orphans == 0 ? 'Aucun' : '$orphans entrées orphelines';
            c.autoFix = () async {
              for (final key in HiveBoxes.productsBox.keys.toList()) {
                final m = HiveBoxes.productsBox.get(key);
                final sid = (m as Map?)? ['store_id']?.toString();
                if (sid != null && !shopIds.contains(sid)) await HiveBoxes.productsBox.delete(key);
              }
              for (final key in HiveBoxes.ordersBox.keys.toList()) {
                final m = HiveBoxes.ordersBox.get(key);
                final sid = (m as Map?)? ['shop_id']?.toString();
                if (sid != null && !shopIds.contains(sid)) await HiveBoxes.ordersBox.delete(key);
              }
              c.status = _CheckStatus.ok; c.detail = 'Nettoyés';
            };

          case 'Invitations > 30 jours':
            final cutoff = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
            final rows = await db.from('pending_invitations').select('id').lt('expires_at', cutoff);
            final n = (rows as List).length;
            c.status = n == 0 ? _CheckStatus.ok : _CheckStatus.warning;
            c.detail = n == 0 ? 'Aucune' : '$n anciennes invitations';
            c.autoFix = () async {
              await db.from('pending_invitations').delete().lt('expires_at', cutoff);
              c.status = _CheckStatus.ok; c.detail = 'Nettoyées';
            };

          // ── Trimestriel ──────────────────────────────────────
          case 'Total utilisateurs':
            final rows = await db.from('profiles').select('id').eq('is_super_admin', false);
            final n = (rows as List).length;
            c.status = _CheckStatus.ok;
            c.detail = '$n utilisateurs';

          case 'Total boutiques':
            final rows = await db.from('shops').select('id');
            final n = (rows as List).length;
            c.status = _CheckStatus.ok;
            c.detail = '$n boutiques';

          case 'Lignes par table':
            try {
              final result = await db.rpc('exec_sql', params: {'sql': '''
                SELECT json_build_object(
                  'orders', (SELECT count(*) FROM orders),
                  'products', (SELECT count(*) FROM products),
                  'clients', (SELECT count(*) FROM clients),
                  'profiles', (SELECT count(*) FROM profiles),
                  'shops', (SELECT count(*) FROM shops)
                )::text
              '''});
              c.status = _CheckStatus.ok;
              c.detail = result?.toString() ?? 'OK';
            } catch (e) {
              c.status = _CheckStatus.ok;
              c.detail = 'exec_sql non disponible';
            }
        }
        if (c.status == _CheckStatus.running) c.status = _CheckStatus.ok;
      } catch (e) {
        c.status = _CheckStatus.critical;
        c.detail = e.toString().replaceAll('Exception: ', '').split('\n').first;
      }
      setState(() {});
    }
    setState(() => _running = false);
  }

  Future<void> _autoFixAll() async {
    for (final c in _checks) {
      if (c.autoFixable && c.autoFix != null &&
          (c.status == _CheckStatus.warning || c.status == _CheckStatus.critical)) {
        try { await c.autoFix!(); } catch (e) {
          c.detail = 'Erreur: $e';
        }
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final categories = ['Hebdomadaire', 'Mensuel', 'Trimestriel'];
    return ListView(padding: const EdgeInsets.all(16), children: [
      // Résumé
      if (_done) ...[
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _criticals > 0 ? const Color(0xFFFEF2F2)
                : _warnings > 0 ? const Color(0xFFFFFBEB)
                : const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _criticals > 0 ? const Color(0xFFFCA5A5)
                : _warnings > 0 ? const Color(0xFFFDE68A) : const Color(0xFFA7F3D0)),
          ),
          child: Row(children: [
            Icon(_criticals > 0 ? Icons.error_rounded
                : _warnings > 0 ? Icons.warning_rounded : Icons.check_circle_rounded,
                color: _criticals > 0 ? AppColors.error
                    : _warnings > 0 ? AppColors.warning : AppColors.secondary),
            const SizedBox(width: 10),
            Expanded(child: Text(
              '$_passed/${_checks.length} checks OK'
                  '${_warnings > 0 ? ' · $_warnings attention' : ''}'
                  '${_criticals > 0 ? ' · $_criticals critique${_criticals > 1 ? 's' : ''}' : ''}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            )),
          ]),
        ),
        const SizedBox(height: 12),
      ],

      // Boutons
      Row(children: [
        Expanded(child: ElevatedButton.icon(
          onPressed: _running ? null : _runAll,
          icon: _running
              ? const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.play_arrow_rounded, size: 18),
          label: Text(_running ? 'Vérification...' : 'Lancer la vérification'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary, foregroundColor: Colors.white,
            elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        )),
        if (_hasAutoFix) ...[
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: _autoFixAll,
            icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
            label: const Text('Corriger'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.warning, foregroundColor: Colors.white,
              elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 16),

      // Checklist par catégorie
      ...categories.map((cat) {
        final items = _checks.where((c) => c.category == cat).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Text(cat.toUpperCase(), style: const TextStyle(fontSize: 11,
                fontWeight: FontWeight.w700, letterSpacing: 0.5, color: AppColors.textSecondary))),
          ...items.map((c) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(children: [
              _statusIcon(c.status),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                if (c.detail.isNotEmpty)
                  Text(c.detail, style: const TextStyle(fontSize: 10, color: AppColors.textHint),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
              ])),
              if (c.autoFixable && c.autoFix != null &&
                  (c.status == _CheckStatus.warning || c.status == _CheckStatus.critical))
                GestureDetector(
                  onTap: () async { await c.autoFix!(); setState(() {}); },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6)),
                    child: const Text('Corriger', style: TextStyle(fontSize: 10,
                        fontWeight: FontWeight.w600, color: AppColors.warning)),
                  ),
                ),
            ]),
          )),
          const SizedBox(height: 12),
        ]);
      }),
    ]);
  }

  Widget _statusIcon(_CheckStatus s) => switch (s) {
    _CheckStatus.pending  => const Icon(Icons.radio_button_unchecked, size: 18, color: Color(0xFFD1D5DB)),
    _CheckStatus.running  => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    _CheckStatus.ok       => const Icon(Icons.check_circle_rounded, size: 18, color: AppColors.secondary),
    _CheckStatus.warning  => const Icon(Icons.warning_rounded, size: 18, color: AppColors.warning),
    _CheckStatus.critical => const Icon(Icons.error_rounded, size: 18, color: AppColors.error),
  };
}

// ════════════════════════════════════════════════════════════════════════════
// SECTION MONITORING — Logs, métriques DB
// ════════════════════════════════════════════════════════════════════════════

class _MonitoringSection extends StatefulWidget {
  const _MonitoringSection();
  @override State<_MonitoringSection> createState() => _MonitoringSectionState();
}

class _MonitoringSectionState extends State<_MonitoringSection>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  bool _loading = false;

  // Données
  Map<String, int> _rowCounts = {};
  List<Map<String, dynamic>> _offlineQueue = [];
  List<Map<String, dynamic>> _syncErrors = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _refresh();
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await Future.wait([_loadRowCounts(), _loadOfflineQueue(), _loadSyncErrors()]);
    setState(() => _loading = false);
  }

  Future<void> _loadRowCounts() async {
    try {
      final db = Supabase.instance.client;
      final result = await db.rpc('exec_sql', params: {'sql': '''
        SELECT json_build_object(
          'orders', (SELECT count(*) FROM orders),
          'products', (SELECT count(*) FROM products),
          'clients', (SELECT count(*) FROM clients),
          'profiles', (SELECT count(*) FROM profiles),
          'shops', (SELECT count(*) FROM shops),
          'categories', (SELECT count(*) FROM categories),
          'shop_memberships', (SELECT count(*) FROM shop_memberships),
          'activity_logs', (SELECT count(*) FROM activity_logs)
        )
      '''});
      if (result is String) {
        // exec_sql returns void, but we parse from the JSON result
        _rowCounts = {};
      } else if (result is Map) {
        _rowCounts = Map<String, int>.from(
            result.map((k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0)));
      }
    } catch (e) {
      // Fallback : compter depuis Hive
      _rowCounts = {
        'shops (local)': HiveBoxes.shopsBox.length,
        'products (local)': HiveBoxes.productsBox.length,
        'orders (local)': HiveBoxes.ordersBox.length,
        'clients (local)': HiveBoxes.clientsBox.length,
        'sales (local)': HiveBoxes.salesBox.length,
        'users (local)': HiveBoxes.usersBox.length,
        'offline_queue': HiveBoxes.offlineQueueBox.length,
      };
    }
  }

  Future<void> _loadOfflineQueue() async {
    final list = <Map<String, dynamic>>[];
    for (final raw in HiveBoxes.offlineQueueBox.values) {
      try {
        list.add(Map<String, dynamic>.from(raw));
      } catch (_) {
        // Entrée corrompue — l'ajouter avec des infos minimales
        list.add({'table': '?', 'op': '?', 'data': <String, dynamic>{}});
      }
    }
    _offlineQueue = list;
  }

  Future<void> _loadSyncErrors() async {
    final raw = HiveBoxes.settingsBox.get('sync_errors') as List?;
    _syncErrors = raw?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? [];
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Tabs
      Container(
        color: Colors.white,
        child: TabBar(
          controller: _tab,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textHint,
          indicatorColor: AppColors.primary,
          indicatorWeight: 2,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          tabs: [
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.storage_rounded, size: 14),
              const SizedBox(width: 6),
              const Text('Métriques'),
            ])),
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.cloud_queue_rounded, size: 14),
              const SizedBox(width: 6),
              const Text('File d\'attente'),
              if (_offlineQueue.isNotEmpty) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: AppColors.warning, borderRadius: BorderRadius.circular(8)),
                  child: Text('${_offlineQueue.length}', style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ],
            ])),
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline_rounded, size: 14),
              const SizedBox(width: 6),
              const Text('Erreurs sync'),
              if (_syncErrors.isNotEmpty) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(8)),
                  child: Text('${_syncErrors.length}', style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ],
            ])),
          ],
        ),
      ),
      // Refresh
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(children: [
          const Spacer(),
          GestureDetector(
            onTap: _loading ? null : _refresh,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(8)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_loading)
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Icon(Icons.refresh_rounded, size: 14, color: AppColors.primary),
                const SizedBox(width: 6),
                Text('Actualiser', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.primary)),
              ]),
            ),
          ),
        ]),
      ),
      // Content
      Expanded(child: TabBarView(controller: _tab, children: [
        _MetricsTab(rowCounts: _rowCounts),
        _OfflineQueueTab(queue: _offlineQueue, onFlush: () async {
          await AppDatabase.flushOfflineQueue();
          await _loadOfflineQueue();
          setState(() {});
        }),
        _SyncErrorsTab(errors: _syncErrors),
      ])),
    ]);
  }
}

// ── Onglet Métriques ─────────────────────────────────────────────────────────
class _MetricsTab extends StatelessWidget {
  final Map<String, int> rowCounts;
  const _MetricsTab({required this.rowCounts});

  @override
  Widget build(BuildContext context) {
    if (rowCounts.isEmpty) {
      return const Center(child: Text('Aucune donnée', style: TextStyle(color: AppColors.textHint)));
    }
    final sorted = rowCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value.clamp(1, 999999999);

    return ListView(padding: const EdgeInsets.all(16), children: [
      ...sorted.map((e) {
        final pct = e.value / maxVal;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.divider)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(e.key, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              Text(_fmt(e.value), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.primary)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: pct, minHeight: 4,
                  backgroundColor: AppColors.inputFill,
                  valueColor: AlwaysStoppedAnimation(AppColors.primary))),
          ]),
        );
      }),
      // Hive local
      const SizedBox(height: 12),
      const Text('CACHE LOCAL (HIVE)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
          letterSpacing: 0.5, color: AppColors.textSecondary)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _HiveChip('shops', HiveBoxes.shopsBox.length),
        _HiveChip('products', HiveBoxes.productsBox.length),
        _HiveChip('orders', HiveBoxes.ordersBox.length),
        _HiveChip('clients', HiveBoxes.clientsBox.length),
        _HiveChip('sales', HiveBoxes.salesBox.length),
        _HiveChip('users', HiveBoxes.usersBox.length),
        _HiveChip('queue', HiveBoxes.offlineQueueBox.length),
        // Ops critiques (orders/sales/expenses) qui ont échoué N fois et
        // restent bloquées dans la queue malgré les retries — un compteur
        // > 0 signale une potentielle vente perdue côté caissier.
        _HiveChip('stuck', AppDatabase.stuckCriticalOpsCount, alert: true),
      ]),
    ]);
  }

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

class _HiveChip extends StatelessWidget {
  final String label;
  final int count;
  /// Quand `true`, count > 0 affiche le chip en rouge (état d'alerte) au lieu
  /// de la couleur primaire neutre. Réservé aux compteurs de santé (ex: ops
  /// critiques bloquées) où une valeur non nulle nécessite une action.
  final bool alert;
  const _HiveChip(this.label, this.count, {this.alert = false});
  @override
  Widget build(BuildContext context) {
    final hot = count > 0;
    final bg = hot
        ? (alert ? AppColors.error.withOpacity(0.12) : AppColors.primarySurface)
        : AppColors.inputFill;
    final fg = hot
        ? (alert ? AppColors.error : AppColors.primary)
        : AppColors.textHint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8)),
      child: Text('$label: $count', style: TextStyle(fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg)),
    );
  }
}

// ── Onglet File d'attente offline ─────────────────────────────────────────────
class _OfflineQueueTab extends StatelessWidget {
  final List<Map<String, dynamic>> queue;
  final VoidCallback onFlush;
  const _OfflineQueueTab({required this.queue, required this.onFlush});

  static const _opColors = {
    'upsert': AppColors.info,
    'insert': AppColors.secondary,
    'delete': AppColors.error,
  };

  @override
  Widget build(BuildContext context) {
    if (queue.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_done_rounded, size: 40, color: AppColors.secondary),
        const SizedBox(height: 8),
        const Text('File d\'attente vide', style: TextStyle(fontSize: 13, color: AppColors.textHint)),
        const SizedBox(height: 4),
        const Text('Toutes les opérations sont synchronisées',
            style: TextStyle(fontSize: 11, color: Color(0xFFD1D5DB))),
      ]));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: queue.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              Expanded(child: Text(
                  '${queue.length} opération${queue.length > 1 ? 's' : ''} en attente',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: Color(0xFF374151)))),
              ElevatedButton.icon(
                onPressed: onFlush,
                icon: const Icon(Icons.cloud_upload_rounded, size: 14),
                label: const Text('Synchroniser'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                  elevation: 0, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ]),
          );
        }
        final op       = queue[i - 1];
        final table    = op['table']?.toString() ?? '?';
        final type     = op['op']?.toString() ?? '?';
        final color    = _opColors[type] ?? AppColors.textSecondary;
        final queuedAt = op['queued_at']?.toString() ?? '';
        String detail  = '';
        try {
          final rawData = op['data'];
          if (rawData is Map) {
            detail = rawData['id']?.toString()
                ?? rawData['name']?.toString() ?? '';
          }
          if (detail.isEmpty) detail = op['val']?.toString() ?? '';
        } catch (_) {}

        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFF0F0F0))),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4)),
              child: Text(type.toUpperCase(), style: TextStyle(fontSize: 9,
                  fontWeight: FontWeight.w800, color: color)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(table, style: const TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              if (detail.isNotEmpty)
                Text(detail, style: const TextStyle(fontSize: 10,
                    color: AppColors.textHint),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            if (queuedAt.isNotEmpty)
              Text(_fmtTime(queuedAt), style: const TextStyle(fontSize: 10,
                  color: Color(0xFFD1D5DB))),
          ]),
        );
      },
    );
  }

  static String _fmtTime(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 60) return '${diff.inMinutes}min';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}j';
  }
}

// ── Onglet Erreurs de sync ───────────────────────────────────────────────────
class _SyncErrorsTab extends StatelessWidget {
  final List<Map<String, dynamic>> errors;
  const _SyncErrorsTab({required this.errors});

  @override
  Widget build(BuildContext context) {
    if (errors.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check_circle_outline_rounded, size: 40, color: AppColors.secondary),
        const SizedBox(height: 8),
        const Text('Aucune erreur de synchronisation', style: TextStyle(fontSize: 13, color: AppColors.textHint)),
      ]));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: errors.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (_, i) {
        final e = errors[errors.length - 1 - i]; // plus récentes en premier
        final date = DateTime.tryParse(e['time']?.toString() ?? '');
        final dateStr = date != null ? DateFormat('dd/MM HH:mm').format(date) : '';
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFFCA5A5))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.error_outline_rounded, size: 14, color: AppColors.error),
              const SizedBox(width: 6),
              Text('${e['table']} · ${e['op']}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.error)),
              const Spacer(),
              Text(dateStr, style: const TextStyle(fontSize: 10, color: AppColors.textHint)),
            ]),
            const SizedBox(height: 4),
            Text(e['error']?.toString() ?? '', style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
                maxLines: 3, overflow: TextOverflow.ellipsis),
          ]),
        );
      },
    );
  }
}