import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User, AuthState;

import '../../../../core/database/app_database.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Page /accept-invite — invitation employé par lien partageable.
//
// Flux (autonome, ne passe PAS par le tunnel owner qui crée une boutique) :
//   1. Lit ?token=xxx → get_invitation_info (capability, sans auth).
//   2. Non connecté → formulaire INLINE : « Créer mon mot de passe » (nouveau)
//      ou « Se connecter » (compte existant). Email verrouillé sur l'invitation.
//   3. Auth via AuthBloc → à AuthAuthenticated → accept_shop_invitation →
//      membership créée (rôle + permissions + statut) → dashboard.
//   4. Déjà connecté avec le bon email → accepte directement.
//   5. Mauvais email / expirée / introuvable → message.
// ═══════════════════════════════════════════════════════════════════════════

enum _InviteUiState {
  loading, invalid, expired, needsAuth, wrongUser, accepting, accepted, error
}

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

  // Formulaire inline
  bool _registerMode = true; // true = créer un compte, false = se connecter
  bool _authSubmitted = false;
  final _passCtrl = TextEditingController();
  final _confCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  String? get _inviteEmail => (_info?['email'] as String?)?.toLowerCase();

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
      _nameCtrl.text = (m['full_name'] as String?) ?? '';

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        setState(() => _state = _InviteUiState.needsAuth);
        return;
      }
      if ((user.email ?? '').toLowerCase() != _inviteEmail) {
        setState(() => _state = _InviteUiState.wrongUser);
        return;
      }
      await _accept(token);
    } catch (e) {
      setState(() { _state = _InviteUiState.error; _error = e.toString(); });
    }
  }

  void _submitAuth() {
    final email = _inviteEmail;
    if (email == null) return;
    if (_passCtrl.text.length < 6) {
      _snack('Mot de passe : minimum 6 caractères'); return;
    }
    if (_registerMode) {
      if (_nameCtrl.text.trim().length < 2) {
        _snack('Nom requis'); return;
      }
      if (_passCtrl.text != _confCtrl.text) {
        _snack('Les mots de passe ne correspondent pas'); return;
      }
    }
    setState(() => _authSubmitted = true);
    if (_registerMode) {
      context.read<AuthBloc>().add(AuthSignUpAutoLoginRequested(
        name: _nameCtrl.text.trim(), email: email, password: _passCtrl.text));
    } else {
      context.read<AuthBloc>().add(
        AuthLoginRequested(email: email, password: _passCtrl.text));
    }
  }

  void _onAuthState(AuthState state) {
    if (!_authSubmitted) return;
    if (state is AuthAuthenticated) {
      _authSubmitted = false;
      final token = widget.token;
      if (token != null) _accept(token);
    } else if (state is AuthError) {
      _authSubmitted = false;
      final msg = state.message.toLowerCase();
      if (_registerMode &&
          (msg.contains('exist') || msg.contains('déjà') || msg.contains('already'))) {
        setState(() => _registerMode = false);
        _snack('Un compte existe déjà avec cet email — connectez-vous.');
      } else {
        _snack(state.message);
      }
    }
  }

  Future<void> _accept(String token) async {
    setState(() => _state = _InviteUiState.accepting);
    try {
      final res = await Supabase.instance.client
          .rpc('accept_shop_invitation', params: {'p_token': token});
      final m = Map<String, dynamic>.from(res as Map);
      _shopId = m['shop_id'] as String?;
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) await AppDatabase.syncMemberships(uid);
      if (!mounted) return;
      setState(() => _state = _InviteUiState.accepted);
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted && _shopId != null) context.go('/shop/$_shopId/dashboard');
    } catch (e) {
      setState(() {
        _state = _InviteUiState.error;
        _error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthBloc, AuthState>(
      listener: (_, state) => _onAuthState(state),
      child: Scaffold(
        backgroundColor: AppColors.primarySurface,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _buildContent(),
                ),
              ),
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
          color: AppColors.secondary, icon: Icons.check_circle_rounded,
          title: 'Bienvenue !',
          body: 'Vous êtes maintenant membre de '
              '${_info?['shop_name'] ?? 'la boutique'}. Redirection…',
        );
      case _InviteUiState.invalid:
        return _StatusCard(
          color: AppColors.error, icon: Icons.link_off_rounded,
          title: 'Invitation introuvable',
          body: _error ?? 'Le lien d\'invitation est invalide ou déjà utilisé.',
          primaryLabel: 'Retour à la connexion',
          onPrimary: () => context.go(RouteNames.login),
        );
      case _InviteUiState.expired:
        return _StatusCard(
          color: AppColors.warning, icon: Icons.schedule_rounded,
          title: 'Invitation expirée',
          body: 'Demandez à l\'administrateur de vous renvoyer une invitation.',
          primaryLabel: 'Retour à la connexion',
          onPrimary: () => context.go(RouteNames.login),
        );
      case _InviteUiState.wrongUser:
        return _StatusCard(
          color: AppColors.error, icon: Icons.person_off_rounded,
          title: 'Adresse email différente',
          body: 'Cette invitation a été envoyée à ${_info?['email'] ?? '—'}. '
              'Vous êtes connecté avec une autre adresse. Déconnectez-vous '
              'puis rouvrez le lien.',
          primaryLabel: 'Se déconnecter',
          onPrimary: () async {
            await Supabase.instance.client.auth.signOut();
            if (mounted) setState(() => _state = _InviteUiState.needsAuth);
          },
        );
      case _InviteUiState.error:
        return _StatusCard(
          color: AppColors.error, icon: Icons.error_outline_rounded,
          title: 'Erreur', body: _error ?? 'Une erreur est survenue.',
          primaryLabel: 'Retour', onPrimary: () => context.go(RouteNames.login),
        );
      case _InviteUiState.needsAuth:
        return _buildAuthForm();
    }
  }

  Widget _buildAuthForm() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 14, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 56, height: 56,
            decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle),
            child: Icon(Icons.group_add_rounded, size: 28,
                color: AppColors.primary)),
        const SizedBox(height: 16),
        Text('Rejoindre ${_info?['shop_name'] ?? 'la boutique'}',
            textAlign: TextAlign.center,
            style: AppTextStyles.subtitleBold
                .copyWith(color: AppColors.onSurface)),
        const SizedBox(height: 6),
        Text(
          _registerMode
              ? 'Créez votre mot de passe pour rejoindre l\'équipe.'
              : 'Connectez-vous pour rejoindre l\'équipe.',
          textAlign: TextAlign.center,
          style: AppTextStyles.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 18),

        // Email (verrouillé)
        TextField(
          enabled: false,
          controller: TextEditingController(text: _info?['email'] as String? ?? ''),
          decoration: const InputDecoration(
            labelText: 'Email', border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 12),

        if (_registerMode) ...[
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Votre nom', border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
        ],

        TextField(
          controller: _passCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Mot de passe', border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        if (_registerMode) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _confCtrl,
            obscureText: true,
            onSubmitted: (_) => _submitAuth(),
            decoration: const InputDecoration(
              labelText: 'Confirmer le mot de passe',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
        ],
        const SizedBox(height: 20),

        SizedBox(width: double.infinity, height: 48,
          child: ElevatedButton(
            onPressed: _submitAuth,
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                elevation: 0, shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: Text(
                _registerMode ? 'Créer mon compte et rejoindre' : 'Se connecter et rejoindre',
                style: AppTextStyles.label
                    .copyWith(fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => setState(() => _registerMode = !_registerMode),
          child: Text(
            _registerMode
                ? 'J\'ai déjà un compte → Se connecter'
                : 'Nouvel employé → Créer un compte',
            style: AppTextStyles.bodySm.copyWith(
                color: AppColors.primary, fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
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
          style: AppTextStyles.bodySecondary),
    ],
  );
}

class _StatusCard extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String body;
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  const _StatusCard({
    required this.color, required this.icon, required this.title,
    required this.body, this.primaryLabel, this.onPrimary,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14, offset: const Offset(0, 6)),
      ],
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 56, height: 56,
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(icon, size: 28, color: color)),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center,
          style: AppTextStyles.subtitleBold
              .copyWith(color: AppColors.onSurface)),
      const SizedBox(height: 8),
      Text(body, textAlign: TextAlign.center,
          style: AppTextStyles.body.copyWith(color: AppColors.textSecondary)),
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
                style: AppTextStyles.label
                    .copyWith(fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ),
      ],
    ]),
  );
}
