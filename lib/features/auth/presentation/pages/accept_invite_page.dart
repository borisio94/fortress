import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;

import '../../../../core/database/app_database.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Page /accept-invite
// ═══════════════════════════════════════════════════════════════════════════
// Flux :
//   1. Lit ?token=xxx
//   2. Appelle get_invitation_info (token = capability, pas besoin d'auth)
//   3. Si utilisateur non connecté → affiche CTA vers /auth/login?next=…
//   4. Si utilisateur connecté avec le bon email → consomme via
//      accept_shop_invitation puis redirige vers le dashboard de la boutique.
//   5. Si email ne correspond pas / expirée / introuvable → message d'erreur.
// ═══════════════════════════════════════════════════════════════════════════

enum _InviteUiState { loading, invalid, expired, needsLogin, wrongUser, accepting, accepted, error }

class AcceptInvitePage extends ConsumerStatefulWidget {
  final String? token;
  const AcceptInvitePage({super.key, this.token});
  @override
  ConsumerState<AcceptInvitePage> createState() => _AcceptInvitePageState();
}

class _AcceptInvitePageState extends ConsumerState<AcceptInvitePage> {
  _InviteUiState _state = _InviteUiState.loading;
  Map<String, dynamic>? _info;
  String? _error;
  String? _shopId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final token = widget.token;
    if (token == null || token.isEmpty) {
      setState(() { _state = _InviteUiState.invalid; _error = 'Lien d\'invitation invalide'; });
      return;
    }

    try {
      final res = await Supabase.instance.client
          .rpc('get_invitation_info', params: {'p_token': token});
      final m = Map<String, dynamic>.from(res as Map);
      if (m['valid'] != true) {
        setState(() => _state = m['reason'] == 'expired'
            ? _InviteUiState.expired : _InviteUiState.invalid);
        return;
      }
      _info = m;

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        setState(() => _state = _InviteUiState.needsLogin);
        return;
      }
      final inviteEmail = (m['email'] as String?)?.toLowerCase();
      if ((user.email ?? '').toLowerCase() != inviteEmail) {
        setState(() => _state = _InviteUiState.wrongUser);
        return;
      }

      await _accept(token);
    } catch (e) {
      setState(() { _state = _InviteUiState.error; _error = e.toString(); });
    }
  }

  Future<void> _accept(String token) async {
    setState(() => _state = _InviteUiState.accepting);
    try {
      final res = await Supabase.instance.client
          .rpc('accept_shop_invitation', params: {'p_token': token});
      final m = Map<String, dynamic>.from(res as Map);
      _shopId = m['shop_id'] as String?;

      // Rafraîchir le cache local des memberships
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) await AppDatabase.syncMemberships(uid);

      if (!mounted) return;
      setState(() => _state = _InviteUiState.accepted);
      // Redirection après un court délai pour laisser voir le succès
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted && _shopId != null) {
        context.go('/shop/$_shopId/dashboard');
      }
    } catch (e) {
      setState(() {
        _state = _InviteUiState.error;
        _error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _buildContent(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_state) {
      case _InviteUiState.loading:
        return const _CenterLoader(label: 'Vérification de l\'invitation…');
      case _InviteUiState.accepting:
        return _CenterLoader(
            label: 'Ajout à ${_info?['shop_name'] ?? 'la boutique'}…');
      case _InviteUiState.accepted:
        return _StatusCard(
          color: AppColors.secondary,
          icon:  Icons.check_circle_rounded,
          title: 'Bienvenue !',
          body:  'Vous êtes maintenant membre de '
              '${_info?['shop_name'] ?? 'la boutique'}. Redirection…',
        );
      case _InviteUiState.invalid:
        return _StatusCard(
          color: AppColors.error,
          icon:  Icons.link_off_rounded,
          title: 'Invitation introuvable',
          body:  _error ?? 'Le lien d\'invitation est invalide ou a déjà été utilisé.',
          primaryLabel: 'Retour à la connexion',
          onPrimary:    () => context.go(RouteNames.login),
        );
      case _InviteUiState.expired:
        return _StatusCard(
          color: AppColors.warning,
          icon:  Icons.schedule_rounded,
          title: 'Invitation expirée',
          body:  'Demandez à l\'administrateur de la boutique de vous '
                 'renvoyer une invitation.',
          primaryLabel: 'Retour à la connexion',
          onPrimary:    () => context.go(RouteNames.login),
        );
      case _InviteUiState.needsLogin:
        final email = _info?['email'] as String?;
        return _StatusCard(
          color: AppColors.primary,
          icon:  Icons.login_rounded,
          title: 'Connectez-vous pour accepter',
          body:  'Invitation envoyée à ${email ?? 'votre adresse email'} pour '
                 'rejoindre ${_info?['shop_name'] ?? 'une boutique'}.',
          primaryLabel: 'Se connecter',
          onPrimary:    () => context.go(RouteNames.login),
          secondaryLabel: 'Créer un compte',
          onSecondary:    () => context.go(RouteNames.register),
        );
      case _InviteUiState.wrongUser:
        return _StatusCard(
          color: AppColors.error,
          icon:  Icons.person_off_rounded,
          title: 'Adresse email différente',
          body:  'Cette invitation a été envoyée à '
                 '${_info?['email'] ?? '—'}. Vous êtes connecté avec une autre adresse. '
                 'Déconnectez-vous puis reconnectez-vous avec la bonne adresse.',
          primaryLabel: 'Se déconnecter',
          onPrimary: () async {
            await Supabase.instance.client.auth.signOut();
            if (mounted) context.go(RouteNames.login);
          },
        );
      case _InviteUiState.error:
        return _StatusCard(
          color: AppColors.error,
          icon:  Icons.error_outline_rounded,
          title: 'Erreur',
          body:  _error ?? 'Une erreur est survenue.',
          primaryLabel: 'Retour',
          onPrimary: () => context.go(RouteNames.login),
        );
    }
  }
}

class _CenterLoader extends StatelessWidget {
  final String label;
  const _CenterLoader({required this.label});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const CircularProgressIndicator(),
      const SizedBox(height: 18),
      Text(label, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ],
  );
}

class _StatusCard extends StatelessWidget {
  final Color       color;
  final IconData    icon;
  final String      title;
  final String      body;
  final String?     primaryLabel;
  final VoidCallback? onPrimary;
  final String?     secondaryLabel;
  final VoidCallback? onSecondary;

  const _StatusCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.05),
            blurRadius: 14, offset: const Offset(0, 6)),
      ],
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 56, height: 56,
          decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle),
          child: Icon(icon, size: 28, color: color)),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17,
              fontWeight: FontWeight.w700, color: Color(0xFF0F172A))),
      const SizedBox(height: 8),
      Text(body, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13,
              color: Color(0xFF6B7280), height: 1.5)),
      if (primaryLabel != null) ...[
        const SizedBox(height: 22),
        SizedBox(width: double.infinity, height: 46,
          child: ElevatedButton(
            onPressed: onPrimary,
            style: ElevatedButton.styleFrom(
                backgroundColor: color, foregroundColor: Colors.white,
                elevation: 0, shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: Text(primaryLabel!,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
      if (secondaryLabel != null) ...[
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, height: 44,
          child: OutlinedButton(
            onPressed: onSecondary,
            style: OutlinedButton.styleFrom(
                side: BorderSide(color: color),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: Text(secondaryLabel!,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600,
                    color: color)),
          ),
        ),
      ],
    ]),
  );
}
