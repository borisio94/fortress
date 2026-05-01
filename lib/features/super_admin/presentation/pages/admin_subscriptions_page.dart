import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../subscription/domain/models/plan_type.dart';

// ═════════════════════════════════════════════════════════════════════════════
// AdminSubscriptionsPage — réservée au super_admin.
//
// Charge SELECT subscriptions JOIN profiles JOIN plans, et propose :
//   - Filtres : Tous / Trial / Actifs / Expirés
//   - Recherche par nom / email
//   - Stats : total clients / actifs / expirés / revenus mensuels estimés
//   - Sheet d'activation : plan + cycle + date début + note
//
// RLS : `subs_select` autorise déjà le super_admin à lire tous les rows.
// `subs_write` autorise l'INSERT/UPDATE pour super_admin uniquement.
// ═════════════════════════════════════════════════════════════════════════════

class AdminSubscriptionsPage extends ConsumerStatefulWidget {
  const AdminSubscriptionsPage({super.key});
  @override
  ConsumerState<AdminSubscriptionsPage> createState() =>
      _AdminSubscriptionsPageState();
}

class _AdminSubscriptionsPageState
    extends ConsumerState<AdminSubscriptionsPage> {
  String _filter = 'all';   // all | trial | active | expired
  String _query  = '';
  bool   _loading = true;
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _plans = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final db = Supabase.instance.client;
      // Tirer subscriptions + plans + profiles
      final subs = await db
          .from('subscriptions')
          .select('id, user_id, plan_id, billing_cycle, sub_status, '
              'started_at, expires_at, amount_paid, payment_ref, '
              'plans(name,label,price_monthly,price_quarterly,price_yearly), '
              'profiles!subscriptions_user_id_fkey(name,email)')
          .order('created_at', ascending: false);
      final plans = await db.from('plans')
          .select('id, name, label, price_monthly, price_quarterly, '
              'price_yearly, is_active')
          .order('sort_order');
      if (!mounted) return;
      setState(() {
        _rows = (subs as List).map((e) =>
            Map<String, dynamic>.from(e as Map)).toList();
        _plans = (plans as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((p) => p['is_active'] == true && p['name'] != 'trial')
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    Iterable<Map<String, dynamic>> rows = _rows;
    switch (_filter) {
      case 'trial':   rows = rows.where((r) => r['sub_status'] == 'trial');
      case 'active':  rows = rows.where((r) => r['sub_status'] == 'active');
      case 'expired': rows = rows.where((r) => r['sub_status'] == 'expired'
          || (DateTime.tryParse(r['expires_at']?.toString() ?? '')
              ?.isBefore(DateTime.now()) ?? false));
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      rows = rows.where((r) {
        final p = (r['profiles'] as Map?) ?? const {};
        final name   = (p['name']  ?? '').toString().toLowerCase();
        final email  = (p['email'] ?? '').toString().toLowerCase();
        // Recherche aussi par user_id (préfixe ou complet) pour les
        // identifiants techniques.
        final userId = (r['user_id'] ?? '').toString().toLowerCase();
        return name.contains(q) || email.contains(q) || userId.contains(q);
      });
    }
    return rows.toList();
  }

  Map<String, num> get _stats {
    int total = _rows.length;
    int active = 0, expired = 0;
    double revenue = 0;
    final now = DateTime.now();
    for (final r in _rows) {
      final st = r['sub_status'] as String?;
      final exp = DateTime.tryParse(r['expires_at']?.toString() ?? '');
      final isExpired = st == 'expired'
          || (exp != null && exp.isBefore(now));
      if (isExpired) {
        expired++;
      } else if (st == 'active') {
        active++;
        // Estimer revenu mensuel : si annuel/trimestriel, normaliser
        final cycle = r['billing_cycle'] as String?;
        final paid  = (r['amount_paid'] as num?)?.toDouble() ?? 0;
        revenue += switch (cycle) {
          'yearly'    => paid / 12,
          'quarterly' => paid / 3,
          _           => paid,
        };
      }
    }
    return {
      'total': total, 'active': active, 'expired': expired,
      'revenue': revenue,
    };
  }

  Future<void> _activate(Map<String, dynamic> row) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ActivationSheet(target: row, plans: _plans),
    );
    if (result == true) {
      _load();
      if (!mounted) return;
      final l = context.l10n;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l.adminSubsActivated),
        backgroundColor: Theme.of(context).semantic.success,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final plan  = ref.watch(currentPlanProvider);

    // Garde rôle : super_admin uniquement.
    if (!plan.isSuperAdmin) {
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Column(
                mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_rounded, size: 48, color: sem.danger),
              const SizedBox(height: 12),
              Text(l.adminSubsAccessDenied,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w600, color: cs.onSurface)),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: () => context.canPop()
                    ? context.pop() : context.go(RouteNames.shopSelector),
                style: ElevatedButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    elevation: 0),
                child: Text(l.commonCancel),
              ),
            ])),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _Topbar(title: l.adminSubsTitle,
                onBack: () => context.canPop()
                    ? context.pop() : context.go(RouteNames.shopSelector)),
            const SizedBox(height: 16),
            _StatsRow(stats: _stats),
            const SizedBox(height: 14),
            TextField(
              decoration: InputDecoration(
                hintText: l.adminSubsSearch,
                prefixIcon: Icon(Icons.search_rounded,
                    size: 18, color: cs.onSurface.withOpacity(0.5)),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                filled: true,
                fillColor: sem.elevatedSurface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: sem.borderSubtle),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: sem.borderSubtle),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 10),
            _FilterChips(
              current: _filter,
              onChange: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 14),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 60),
                child: Center(child: CircularProgressIndicator(
                    color: cs.primary)),
              )
            else if (_filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 60),
                child: Center(child: Text(l.noData,
                    style: TextStyle(fontSize: 13,
                        color: cs.onSurface.withOpacity(0.6)))),
              )
            else
              for (final r in _filtered)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _SubRow(row: r, onActivate: () => _activate(r)),
                ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Topbar
// ═════════════════════════════════════════════════════════════════════════════

class _Topbar extends StatelessWidget {
  final String       title;
  final VoidCallback onBack;
  const _Topbar({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return Row(children: [
      InkWell(
        onTap: onBack,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: sem.elevatedSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sem.borderSubtle),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.arrow_back_ios_new_rounded,
              size: 16, color: cs.onSurface),
        ),
      ),
      const SizedBox(width: 10),
      Text(title,
          style: TextStyle(fontSize: 17,
              fontWeight: FontWeight.w800, color: cs.onSurface)),
    ]);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Stats row (4 KPI)
// ═════════════════════════════════════════════════════════════════════════════

class _StatsRow extends StatelessWidget {
  final Map<String, num> stats;
  const _StatsRow({required this.stats});

  String _compact(num v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(0)}k';
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final items = [
      (l.adminSubsTotalUsers,   '${stats['total']}',     cs.primary),
      (l.adminSubsTotalActive,  '${stats['active']}',    sem.success),
      (l.adminSubsTotalExpired, '${stats['expired']}',   sem.danger),
      (l.adminSubsRevenueMonth, '${_compact(stats['revenue'] ?? 0)} XAF',
          sem.info),
    ];
    return Wrap(spacing: 8, runSpacing: 8, children: items.map((it) {
      return Container(
        width: (MediaQuery.of(context).size.width - 16 * 2 - 8) / 2,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: sem.elevatedSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sem.borderSubtle),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(it.$2,
              style: TextStyle(fontSize: 18,
                  fontWeight: FontWeight.w800, color: it.$3)),
          const SizedBox(height: 2),
          Text(it.$1,
              style: TextStyle(fontSize: 11,
                  color: cs.onSurface.withOpacity(0.6),
                  fontWeight: FontWeight.w500)),
        ]),
      );
    }).toList());
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Filter chips
// ═════════════════════════════════════════════════════════════════════════════

class _FilterChips extends StatelessWidget {
  final String              current;
  final ValueChanged<String> onChange;
  const _FilterChips({required this.current, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final items = <(String, String)>[
      ('all',     l.adminSubsAll),
      ('trial',   l.adminSubsTrial),
      ('active',  l.adminSubsActive),
      ('expired', l.adminSubsExpired),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: items.map((it) {
        final active = current == it.$1;
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: GestureDetector(
            onTap: () => onChange(it.$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: active ? cs.primary : sem.elevatedSurface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: active
                    ? cs.primary : sem.borderSubtle),
              ),
              child: Text(it.$2,
                  style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? cs.onPrimary
                          : cs.onSurface.withOpacity(0.7))),
            ),
          ),
        );
      }).toList()),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Subscription row
// ═════════════════════════════════════════════════════════════════════════════

class _SubRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback         onActivate;
  const _SubRow({required this.row, required this.onActivate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final p     = (row['profiles'] as Map?) ?? const {};
    final pl    = (row['plans']    as Map?) ?? const {};
    final st    = row['sub_status'] as String? ?? 'none';
    final exp   = DateTime.tryParse(row['expires_at']?.toString() ?? '');
    final isExpired = st == 'expired'
        || (exp != null && exp.isBefore(DateTime.now()));
    final Color  statusColor;
    final String statusLabel;
    if (isExpired) {
      statusColor = sem.danger;
      statusLabel = l.planExpired;
    } else if (st == 'trial') {
      statusColor = sem.info;
      statusLabel = l.planTrial;
    } else if (st == 'active') {
      statusColor = sem.success;
      statusLabel = (pl['label'] as String?) ?? '—';
    } else {
      statusColor = cs.onSurface.withOpacity(0.5);
      statusLabel = (pl['label'] as String?) ?? '—';
    }
    final ctaLabel = isExpired ? l.adminSubsRenew : l.adminSubsActivate;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: cs.primary.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            _initials((p['name'] ?? p['email'] ?? '?').toString()),
            style: TextStyle(fontSize: 13,
                fontWeight: FontWeight.w800, color: cs.primary),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text((p['name'] ?? p['email'] ?? '—').toString(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w700, color: cs.onSurface)),
          if ((p['email'] as String?) != null) ...[
            const SizedBox(height: 1),
            Text((p['email'] as String?) ?? '',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11,
                    color: cs.onSurface.withOpacity(0.55))),
          ],
          const SizedBox(height: 6),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(statusLabel,
                  style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w800, color: statusColor)),
            ),
            const SizedBox(width: 6),
            if (exp != null)
              Text(_fmt(exp),
                  style: TextStyle(fontSize: 10,
                      color: cs.onSurface.withOpacity(0.55))),
          ]),
        ])),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: onActivate,
          style: OutlinedButton.styleFrom(
            foregroundColor: cs.primary,
            side: BorderSide(color: cs.primary.withOpacity(0.5)),
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(ctaLabel,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  static String _initials(String s) {
    final parts = s.split(RegExp(r'[\s.@_-]+'))
        .where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0,
          parts.first.length.clamp(1, 2)).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year.toString().substring(2)}';
}

// ═════════════════════════════════════════════════════════════════════════════
// Activation Sheet
// ═════════════════════════════════════════════════════════════════════════════

class _ActivationSheet extends StatefulWidget {
  final Map<String, dynamic>        target;
  final List<Map<String, dynamic>>  plans;
  const _ActivationSheet({required this.target, required this.plans});
  @override
  State<_ActivationSheet> createState() => _ActivationSheetState();
}

class _ActivationSheetState extends State<_ActivationSheet> {
  String?   _planId;
  String    _cycle = 'monthly';
  DateTime  _start = DateTime.now();
  final _noteCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _planId = widget.plans.isNotEmpty
        ? widget.plans.first['id'] as String? : null;
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  DateTime _expiresAt() {
    return switch (_cycle) {
      'monthly'   => DateTime(_start.year, _start.month + 1, _start.day),
      'quarterly' => DateTime(_start.year, _start.month + 3, _start.day),
      'yearly'    => DateTime(_start.year + 1, _start.month, _start.day),
      _           => DateTime(_start.year, _start.month + 1, _start.day),
    };
  }

  double _amountFor(Map<String, dynamic> plan) {
    return switch (_cycle) {
      'quarterly' => (plan['price_quarterly'] as num?)?.toDouble() ?? 0,
      'yearly'    => (plan['price_yearly']    as num?)?.toDouble() ?? 0,
      _           => (plan['price_monthly']   as num?)?.toDouble() ?? 0,
    };
  }

  Future<void> _confirm() async {
    if (_planId == null) return;
    setState(() => _busy = true);
    try {
      final db = Supabase.instance.client;
      final userId = widget.target['user_id'] as String;
      final plan = widget.plans.firstWhere(
          (p) => p['id'] == _planId,
          orElse: () => widget.plans.first);

      // 1. Annuler la subscription active/trial existante (l'index unique
      //    partiel impose un seul actif/trial à la fois).
      await db.from('subscriptions').update({
        'sub_status': 'cancelled',
        'cancelled_at': DateTime.now().toIso8601String(),
      }).eq('user_id', userId).inFilter('sub_status', ['active','trial']);

      // 2. Créer la nouvelle subscription.
      await db.from('subscriptions').insert({
        'user_id':       userId,
        'plan_id':       _planId,
        'billing_cycle': _cycle,
        'sub_status':    'active',
        'started_at':    _start.toIso8601String(),
        'expires_at':    _expiresAt().toIso8601String(),
        'amount_paid':   _amountFor(plan),
        'notes':         _noteCtrl.text.trim().isEmpty
                            ? null : _noteCtrl.text.trim(),
        'activated_by':  Supabase.instance.client.auth.currentUser?.id,
      });

      // 3. Log activity
      await ActivityLogService.log(
        action:      'subscription_activated',
        targetType:  'subscription',
        targetId:    userId,
        targetLabel: ((widget.target['profiles'] as Map?)?['name']
                       ?? (widget.target['profiles'] as Map?)?['email']
                       ?? userId).toString(),
        details: {
          'plan':   plan['name'],
          'cycle':  _cycle,
          'amount': _amountFor(plan),
        },
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceAll('Exception: ', '')),
        backgroundColor: Theme.of(context).semantic.danger,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + viewInsets),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 36, height: 4,
                decoration: BoxDecoration(
                    color: sem.borderSubtle,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Text(l.adminSubsSheetTitle,
                style: TextStyle(fontSize: 16,
                    fontWeight: FontWeight.w800, color: cs.onSurface)),
            const SizedBox(height: 14),
            // Plan
            _Label(text: l.adminSubsPlan),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: widget.plans.map((p) {
              final active = _planId == p['id'];
              return GestureDetector(
                onTap: () => setState(() => _planId = p['id'] as String?),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: active ? cs.primary : sem.elevatedSurface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: active
                        ? cs.primary : sem.borderSubtle),
                  ),
                  child: Text((p['label'] as String?) ?? '',
                      style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: active
                              ? cs.onPrimary
                              : cs.onSurface.withOpacity(0.7))),
                ),
              );
            }).toList()),
            const SizedBox(height: 14),
            _Label(text: l.adminSubsCycle),
            const SizedBox(height: 6),
            Row(children: [
              for (final c in const ['monthly','quarterly','yearly'])
                Expanded(child: Padding(
                  padding: EdgeInsets.only(right: c != 'yearly' ? 6 : 0),
                  child: GestureDetector(
                    onTap: () => setState(() => _cycle = c),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _cycle == c
                            ? cs.primary
                            : sem.elevatedSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _cycle == c
                            ? cs.primary : sem.borderSubtle),
                      ),
                      alignment: Alignment.center,
                      child: Text(switch (c) {
                        'quarterly' => l.subBillQuarterly,
                        'yearly'    => l.subBillYearly,
                        _           => l.subBillMonthly,
                      },
                          style: TextStyle(fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _cycle == c
                                  ? cs.onPrimary
                                  : cs.onSurface.withOpacity(0.7))),
                    ),
                  ),
                )),
            ]),
            const SizedBox(height: 14),
            _Label(text: l.adminSubsStartDate),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _start,
                  firstDate: DateTime(2024),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked != null) setState(() => _start = picked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: sem.elevatedSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: sem.borderSubtle),
                ),
                child: Row(children: [
                  Icon(Icons.calendar_today_outlined,
                      size: 14, color: cs.onSurface.withOpacity(0.55)),
                  const SizedBox(width: 8),
                  Text(_fmtDate(_start),
                      style: TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface)),
                ]),
              ),
            ),
            const SizedBox(height: 14),
            _Label(text: l.adminSubsNote),
            const SizedBox(height: 6),
            TextField(
              controller: _noteCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                filled: true,
                fillColor: sem.elevatedSurface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: sem.borderSubtle),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: sem.borderSubtle),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity, height: 46,
              child: ElevatedButton(
                onPressed: _busy ? null : _confirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                  disabledBackgroundColor: cs.primary.withOpacity(0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: _busy
                    ? SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.onPrimary))
                    : Text(l.adminSubsConfirm,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';
}

class _Label extends StatelessWidget {
  final String text;
  const _Label({required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(text,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
              color: cs.onSurface.withOpacity(0.6))),
    );
  }
}
