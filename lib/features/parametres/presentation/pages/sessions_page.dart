import 'package:flutter/material.dart';
import '../../../../core/services/session_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';

/// Liste les sessions actives du compte (PC + mobile + tablette) et permet
/// de toutes les déconnecter sauf la session courante. La limite par rôle
/// est appliquée côté Supabase (`register_session` purge les plus
/// anciennes au-delà du seuil).
class SessionsPage extends StatefulWidget {
  final String shopId;
  const SessionsPage({super.key, required this.shopId});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  late Future<List<ActiveSession>> _future;
  bool _revoking = false;

  @override
  void initState() {
    super.initState();
    _future = SessionService.list();
  }

  Future<void> _refresh() async {
    setState(() => _future = SessionService.list());
    await _future;
  }

  Future<void> _revokeOthers() async {
    setState(() => _revoking = true);
    final n = await SessionService.revokeOthers();
    if (!mounted) return;
    setState(() => _revoking = false);
    AppSnack.success(context,
        n == 0
            ? 'Aucune autre session à déconnecter'
            : '$n session(s) déconnectée(s)');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Sessions actives',
      isRootPage: false,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<ActiveSession>>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final sessions = snap.data ?? const <ActiveSession>[];
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _Header(count: sessions.length),
                const SizedBox(height: 16),
                if (sessions.isEmpty)
                  _Empty(onRetry: _refresh)
                else
                  ...sessions.map((s) => _SessionTile(session: s)),
                if (sessions.length > 1) ...[
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: _revoking ? null : _revokeOthers,
                    icon: _revoking
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.logout_rounded, size: 18),
                    label: const Text(
                      'Déconnecter tous les autres appareils',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final int count;
  const _Header({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primaryLight],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(11),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.devices_other_rounded,
              color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                count == 0
                    ? 'Aucune session active'
                    : '$count session${count > 1 ? 's' : ''} active${count > 1 ? 's' : ''}',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Colors.white),
              ),
              const SizedBox(height: 2),
              Text(
                'Limite gérée selon votre rôle (1 à 5 sessions).',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.85)),
              ),
            ],
          ),
        ),
        Icon(Icons.shield_outlined,
            color: sem.success.withValues(alpha: 0.9), size: 20),
      ]),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ActiveSession session;
  const _SessionTile({required this.session});

  IconData _platformIcon() {
    switch (session.platform) {
      case 'web':     return Icons.public_rounded;
      case 'android': return Icons.phone_android_rounded;
      case 'ios':     return Icons.phone_iphone_rounded;
      case 'windows': return Icons.desktop_windows_rounded;
      case 'macos':   return Icons.laptop_mac_rounded;
      case 'linux':   return Icons.terminal_rounded;
    }
    return Icons.devices_rounded;
  }

  String _platformLabel() {
    switch (session.platform) {
      case 'web':     return 'Navigateur web';
      case 'android': return 'Android';
      case 'ios':     return 'iPhone / iPad';
      case 'windows': return 'Windows';
      case 'macos':   return 'macOS';
      case 'linux':   return 'Linux';
    }
    return 'Appareil';
  }

  String _formatLastSeen() {
    final diff = DateTime.now().difference(session.lastSeen);
    if (diff.inMinutes < 1)    return "À l'instant";
    if (diff.inMinutes < 60)   return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours   < 24)   return 'Il y a ${diff.inHours} h';
    if (diff.inDays    < 30)   return 'Il y a ${diff.inDays} j';
    return 'Plus d\'un mois';
  }

  @override
  Widget build(BuildContext context) {
    final isCurrent = session.isCurrent;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isCurrent
                ? AppColors.primary.withValues(alpha: 0.5)
                : Theme.of(context).semantic.borderSubtle,
            width: isCurrent ? 1.5 : 1),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(_platformIcon(),
              size: 20, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Text(_platformLabel(),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              if (isCurrent) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('Cet appareil',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
              ],
            ]),
            const SizedBox(height: 2),
            Text(_formatLastSeen(),
                style: TextStyle(
                    fontSize: 11, color: AppColors.textHint)),
          ],
        )),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  final VoidCallback onRetry;
  const _Empty({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.devices_outlined,
                size: 48, color: AppColors.textHint),
            const SizedBox(height: 12),
            Text('Aucune session enregistrée',
                style: TextStyle(
                    fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: onRetry,
              child: const Text('Recharger'),
            ),
          ],
        ),
      ),
    );
  }
}
