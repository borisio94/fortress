import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../data/providers/pending_actions_provider.dart';
import '../../data/services/admin_actions_service.dart';

/// Banner affiché en haut de la page RH côté **owner** quand une demande
/// d'approbation est en attente. Le owner peut approuver (avec mot de
/// passe) ou refuser. Visible uniquement si :
///   - l'utilisateur courant est owner du shop
///   - au moins une PendingAction existe (status='pending', non expirée)
class OwnerApprovalBanner extends ConsumerStatefulWidget {
  final String shopId;
  final bool   isOwner;
  const OwnerApprovalBanner({
    super.key,
    required this.shopId,
    required this.isOwner,
  });

  @override
  ConsumerState<OwnerApprovalBanner> createState() =>
      _OwnerApprovalBannerState();
}

class _OwnerApprovalBannerState extends ConsumerState<OwnerApprovalBanner> {
  bool _alreadyChirped = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.isOwner) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final actionsAsync = ref.watch(pendingActionsProvider(widget.shopId));

    return actionsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (actions) {
        if (actions.isEmpty) {
          _alreadyChirped = false;
          return const SizedBox.shrink();
        }
        // Premier affichage de la liste non-vide → son d'alerte
        if (!_alreadyChirped) {
          _alreadyChirped = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            SystemSound.play(SystemSoundType.alert);
          });
        }
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha:0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha:0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.notifications_active_rounded,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(
                    actions.length == 1
                        ? '1 demande en attente'
                        : '${actions.length} demandes en attente',
                    style: AppTextStyles.body13Bold)),
              ]),
              const SizedBox(height: 8),
              for (final a in actions)
                _ActionRow(action: a, shopId: widget.shopId),
            ],
          ),
        );
      },
    );
  }
}

class _ActionRow extends ConsumerWidget {
  final PendingAction action;
  final String        shopId;
  const _ActionRow({required this.action, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final remainSec = action.remaining.inSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(action.type.labelFr, style: AppTextStyles.body13Bold),
              if (remainSec > 0)
                Text('Expire dans ${remainSec}s',
                    style: AppTextStyles.caption11Hint),
            ])),
        TextButton(
          onPressed: () => _reject(context, ref),
          style: TextButton.styleFrom(
            foregroundColor: theme.semantic.danger,
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 6),
          ),
          child: const Text('Refuser'),
        ),
        const SizedBox(width: 4),
        ElevatedButton(
          onPressed: () => _approve(context, ref),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            elevation: 0,
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
          ),
          child: const Text('Approuver'),
        ),
      ]),
    );
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    try {
      await AdminActionsService.reject(actionId: action.id);
      if (context.mounted) {
        AppSnack.success(context, 'Demande refusée.');
      }
    } on AdminActionException catch (e) {
      if (context.mounted) AppSnack.error(context, e.messageFr);
    }
    // refresh : le Realtime déclenchera une nouvelle fetch
  }

  // Refonte UX : dialog → bottom sheet verrouillé (cf. showFormSheet).
  // L'obscureText reste activé pour ne jamais afficher le mot de passe owner.
  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    final pwdCtrl = TextEditingController();
    final ok = await showFormSheet<bool>(
      context: context,
      builder: (dc) {
        final theme = Theme.of(dc);
        final mq = MediaQuery.of(dc);
        return Padding(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FormSheetHeader(
                  title: 'Confirmation propriétaire',
                  icon: Icons.lock_outline_rounded,
                ),
                Divider(height: 1, color: theme.semantic.borderSubtle),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Pour approuver "${action.type.labelFr}", '
                          'saisissez votre mot de passe.',
                          style: AppTextStyles.body13Secondary),
                      const SizedBox(height: 12),
                      TextField(
                        controller: pwdCtrl,
                        obscureText: true,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Mot de passe',
                          filled: true,
                          fillColor: AppColors.inputFill,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide:
                                BorderSide(color: AppColors.inputBorder),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(dc, false),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 44),
                        ),
                        child: const Text('Annuler'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () => Navigator.pop(dc, true),
                        child: const Text('Confirmer'),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        );
      },
    ) ?? false;

    if (!ok || !context.mounted) return;
    final email = Supabase.instance.client.auth.currentUser?.email;
    if (email == null) {
      AppSnack.error(context, 'Session invalide. Reconnecte-toi.');
      return;
    }
    try {
      await AdminActionsService.approve(
        actionId: action.id,
        email:    email,
        password: pwdCtrl.text,
      );
      if (context.mounted) {
        AppSnack.success(context, 'Action approuvée et exécutée.');
      }
    } on AdminActionException catch (e) {
      if (context.mounted) AppSnack.error(context, e.messageFr);
    }
  }
}
