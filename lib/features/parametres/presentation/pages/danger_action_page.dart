import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/app_switch.dart';

/// Page plein écran générique pour les actions destructives en 3 étapes.
///
/// Remplace l'ancien `_DangerActionSheet` (modal bottom sheet) — sur mobile,
/// les sheets contenant un `TextField` autofocus voient leur UI compromise
/// quand le clavier système se déploie. Une page complète gère correctement
/// le scroll au-dessus du clavier (`resizeToAvoidBottomInset` du Scaffold).
///
/// Flux :
///   - Étape 1 : présentation + conséquences.
///   - Étape 2 : switches d'acknowledgment (chaque point doit être validé).
///   - Étape 3 : saisie du `confirmText` + (optionnel) mot de passe pour
///     re-authentification Supabase.
///
/// Au succès, [onConfirm] est appelée puis la page se ferme avec `true`.
/// Annulation utilisateur → `false`.
class DangerActionPage extends StatefulWidget {
  final String                          title;
  final IconData                        icon;
  final String                          description;
  final List<String>                    consequences;
  final List<String>                    acknowledgments;
  final String                          confirmText;
  final String                          actionLabel;
  final bool                            requirePassword;
  final Future<void> Function(BuildContext) onConfirm;

  const DangerActionPage({
    super.key,
    required this.title,
    required this.icon,
    required this.description,
    required this.consequences,
    required this.acknowledgments,
    required this.confirmText,
    required this.actionLabel,
    required this.onConfirm,
    this.requirePassword = false,
  });

  /// Helper d'ouverture standardisé. Push une `MaterialPageRoute` au-dessus
  /// du shell go_router (sortie via le back button de la page).
  static Future<bool?> open(
    BuildContext context, {
    required String title,
    required IconData icon,
    required String description,
    required List<String> consequences,
    required List<String> acknowledgments,
    required String confirmText,
    required String actionLabel,
    required Future<void> Function(BuildContext) onConfirm,
    bool requirePassword = false,
  }) =>
      Navigator.of(context, rootNavigator: true).push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => DangerActionPage(
            title:           title,
            icon:            icon,
            description:     description,
            consequences:    consequences,
            acknowledgments: acknowledgments,
            confirmText:     confirmText,
            actionLabel:     actionLabel,
            onConfirm:       onConfirm,
            requirePassword: requirePassword,
          ),
        ),
      );

  @override
  State<DangerActionPage> createState() => _DangerActionPageState();
}

class _DangerActionPageState extends State<DangerActionPage> {
  final _pageCtrl    = PageController();
  final _confirmCtrl = TextEditingController();
  final _pwdCtrl     = TextEditingController();
  late List<bool> _acks;
  int     _page    = 0;
  bool    _obscure = true;
  bool    _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _acks = List<bool>.filled(widget.acknowledgments.length, false);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _confirmCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  bool get _canGoNext {
    if (_page == 0) return true;
    if (_page == 1) return _acks.every((v) => v);
    return false;
  }

  bool get _canConfirm {
    if (_loading) return false;
    if (_confirmCtrl.text.trim() != widget.confirmText) return false;
    if (widget.requirePassword && _pwdCtrl.text.trim().isEmpty) return false;
    return true;
  }

  void _goTo(int i) {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() => _page = i);
    _pageCtrl.animateToPage(i,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut);
  }

  Future<void> _submit() async {
    if (!_canConfirm) return;
    FocusScope.of(context).unfocus();
    setState(() { _loading = true; _error = null; });
    try {
      // Re-auth optionnelle — confirme l'identité avant toute action
      // destructive (cohérent avec _DeleteAccountSheet).
      if (widget.requirePassword) {
        final auth = Supabase.instance.client.auth;
        final email = auth.currentUser?.email ?? '';
        if (email.isEmpty) throw Exception('Session expirée');
        await auth.signInWithPassword(
            email: email, password: _pwdCtrl.text.trim());
      }
      // Capturer le ctx racine — autorise onConfirm à naviguer (ex: push
      // shop-selector après suppression de boutique). On ferme la page
      // d'action avec `true` pour signaler le succès à l'appelant.
      final navigator = Navigator.of(context);
      await widget.onConfirm(context);
      if (mounted) navigator.pop(true);
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Mot de passe incorrect. ${e.message}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      // resizeToAvoidBottomInset = true par défaut — la page se redimensionne
      // quand le clavier monte, le PageView ListView reste scrollable.
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _loading ? null : () => Navigator.of(context).pop(false),
        ),
        title: Row(children: [
          Container(width: 28, height: 28,
              decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(7)),
              child: Icon(widget.icon, size: 16, color: AppColors.error)),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.title,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15,
                  fontWeight: FontWeight.w700))),
        ]),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _StepIndicator(step: _page),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(child: PageView(
            controller: _pageCtrl,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              _buildStep1(),
              _buildStep2(),
              _buildStep3(),
            ],
          )),
          _Footer(
            page: _page,
            loading: _loading,
            actionLabel: widget.actionLabel,
            canGoNext: _canGoNext,
            canConfirm: _canConfirm,
            onBack: () => _goTo(_page - 1),
            onNext: () => _goTo(_page + 1),
            onSubmit: _submit,
          ),
        ]),
      ),
    );
  }

  Widget _buildStep1() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    children: [
      const Text('Action destructive — lisez attentivement',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(widget.description,
          style: const TextStyle(fontSize: 13,
              color: AppColors.textSecondary, height: 1.5)),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.2)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Conséquences',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                  color: AppColors.error)),
          const SizedBox(height: 8),
          ...widget.consequences.map((c) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              const Icon(Icons.arrow_right_rounded, size: 16,
                  color: AppColors.error),
              const SizedBox(width: 4),
              Expanded(child: Text(c,
                  style: const TextStyle(fontSize: 12,
                      color: AppColors.textPrimary, height: 1.4))),
            ]),
          )),
        ]),
      ),
    ],
  );

  Widget _buildStep2() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    children: [
      const Text('Avant de continuer',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('Confirmez chaque point pour passer à la dernière étape.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      const SizedBox(height: 16),
      for (var i = 0; i < widget.acknowledgments.length; i++) ...[
        _SwitchRow(
          label: widget.acknowledgments[i],
          value: _acks[i],
          onChanged: (v) => setState(() => _acks[i] = v),
        ),
        const SizedBox(height: 12),
      ],
    ],
  );

  Widget _buildStep3() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    children: [
      const Text('Confirmation finale',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 12,
              color: AppColors.textSecondary),
          children: [
            const TextSpan(text: 'Pour confirmer, tapez exactement : '),
            TextSpan(text: widget.confirmText,
                style: const TextStyle(fontWeight: FontWeight.w700,
                    color: AppColors.error)),
          ],
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _confirmCtrl,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: widget.confirmText,
          hintStyle: const TextStyle(fontSize: 12, color: AppColors.textHint),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.divider)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.divider)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
        ),
      ),
      if (widget.requirePassword) ...[
        const SizedBox(height: 16),
        const Text('Mot de passe actuel',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: Color(0xFF374151))),
        const SizedBox(height: 6),
        TextField(
          controller: _pwdCtrl,
          obscureText: _obscure,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Votre mot de passe',
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textHint),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 12),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined, size: 18),
            ),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.divider)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.divider)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
          ),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.error_outline_rounded, size: 14, color: AppColors.error),
          const SizedBox(width: 6),
          Expanded(child: Text(_error!,
              style: const TextStyle(fontSize: 12, color: AppColors.error))),
        ]),
      ],
    ],
  );
}

class _StepIndicator extends StatelessWidget {
  final int step;
  const _StepIndicator({required this.step});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      for (var i = 0; i < 3; i++) ...[
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: i == step ? 24 : 6, height: 6,
          decoration: BoxDecoration(
              color: i <= step ? AppColors.error : AppColors.divider,
              borderRadius: BorderRadius.circular(3)),
        ),
        if (i < 2) const SizedBox(width: 5),
      ],
    ]);
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.divider),
    ),
    child: Row(children: [
      Expanded(child: Text(label,
          style: const TextStyle(fontSize: 13,
              color: AppColors.textPrimary, fontWeight: FontWeight.w500))),
      const SizedBox(width: 10),
      AppSwitch(value: value, onChanged: onChanged,
          activeColor: AppColors.error),
    ]),
  );
}

class _Footer extends StatelessWidget {
  final int page;
  final bool loading;
  final String actionLabel;
  final bool canGoNext;
  final bool canConfirm;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onSubmit;
  const _Footer({
    required this.page,
    required this.loading,
    required this.actionLabel,
    required this.canGoNext,
    required this.canConfirm,
    required this.onBack,
    required this.onNext,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(children: [
        if (page > 0)
          Expanded(child: OutlinedButton(
            onPressed: loading ? null : onBack,
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.divider),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Retour',
                style: TextStyle(color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600)),
          )),
        if (page > 0) const SizedBox(width: 10),
        Expanded(flex: 2, child: page < 2
            ? ElevatedButton(
                onPressed: canGoNext ? onNext : null,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.divider,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                child: const Text('Suivant',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              )
            : ElevatedButton(
                onPressed: canConfirm ? onSubmit : null,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.divider,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                child: loading
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(actionLabel,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
              )),
      ]),
    );
  }
}
