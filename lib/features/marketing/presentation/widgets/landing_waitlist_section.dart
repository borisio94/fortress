import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';

// ═════════════════════════════════════════════════════════════════════════════
// LandingWaitlistSection — encadré "Bientôt Q3 2026" + capture email pour
// la feature Automatisation WhatsApp Pro (intégration Twilio). Insert
// anonyme dans la table `twilio_waitlist` (cf. hotfix_064). Idempotent :
// si email déjà inscrit (UNIQUE violation 23505) → traité comme succès UX.
// ═════════════════════════════════════════════════════════════════════════════

class LandingWaitlistSection extends StatefulWidget {
  const LandingWaitlistSection({super.key});
  @override
  State<LandingWaitlistSection> createState() => _LandingWaitlistSectionState();
}

class _LandingWaitlistSectionState extends State<LandingWaitlistSection> {
  final _emailCtrl = TextEditingController();
  bool _submitting = false;
  bool _submitted  = false;
  String? _error;

  static final _emailRe =
      RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (!_emailRe.hasMatch(email)) {
      setState(() => _error = 'Adresse email invalide.');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      await Supabase.instance.client.from('twilio_waitlist').insert({
        'email':      email,
        'source':     'landing_page',
        'user_agent': kIsWeb ? 'web' : 'native',
      });
      if (mounted) setState(() => _submitted = true);
    } catch (e) {
      debugPrint('[Waitlist] insert error: $e');
      // 23505 unique violation = email déjà inscrit → traité comme succès UX.
      final msg = e.toString();
      if (msg.contains('duplicate') || msg.contains('23505')) {
        if (mounted) setState(() => _submitted = true);
      } else if (mounted) {
        setState(() => _error =
            'Erreur lors de l\'inscription. Réessayez dans un instant.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      color: theme.colorScheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.25)),
              color: AppColors.primary.withValues(alpha: 0.04),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(4)),
                  child: Text('BIENTÔT — Q3 2026',
                      style: AppTextStyles.micro.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: Colors.white)),
                ),
                const SizedBox(height: 14),
                Text('Automatisation WhatsApp Pro',
                    style: AppTextStyles.title.copyWith(
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurface)),
                const SizedBox(height: 6),
                Text(
                    'Confirmations, rappels et factures envoyés '
                    'automatiquement à vos clients via WhatsApp Business API.',
                    style: AppTextStyles.body.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.7))),
                const SizedBox(height: 16),
                if (_submitted)
                  Row(children: [
                    Icon(Icons.check_circle_rounded,
                        size: 18, color: AppColors.secondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          'Inscrit ! Vous serez prévenu dès l\'ouverture.',
                          style: AppTextStyles.body.copyWith(
                              fontWeight: FontWeight.w600,
                              color: AppColors.secondary)),
                    ),
                  ])
                else
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        enabled: !_submitting,
                        decoration: InputDecoration(
                          hintText: 'votre@email.com',
                          isDense: true,
                          filled: true,
                          fillColor: theme.colorScheme.surface,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                  color: theme.colorScheme.outline
                                      .withValues(alpha: 0.3))),
                        ),
                        style: AppTextStyles.input,
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text('Être notifié',
                              style: AppTextStyles.body.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                    ),
                  ]),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: AppTextStyles.caption
                          .copyWith(color: theme.colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
