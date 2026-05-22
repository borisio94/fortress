import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../data/onboarding_prefs.dart';

/// Checklist d'activation 4 étapes (point 6 de l'onboarding spec).
///
/// Affichée en haut du dashboard tant que toutes les étapes ne sont
/// pas cochées. Disparaît complètement (et automatiquement) quand
/// l'utilisateur a complété les 4.
///
/// Étapes
/// ──────
///   1. Ajouter un produit         — auto si `getProductsForShop().isNotEmpty`
///   2. Inviter un vendeur         — manuel (toggle utilisateur)
///   3. Première vente             — auto si ≥ 1 commande status='completed'
///   4. Activer catalogue web      — manuel (toggle utilisateur)
///
/// La persistance utilise SharedPreferences via [OnboardingPrefs]
/// (préfixe `onboarding_checklist_<uid>_<step>`). Les étapes auto sont
/// recalculées à chaque build (rapide via Hive), les manuelles sont
/// lues depuis SharedPreferences au mount.
class ActivationChecklistCard extends StatefulWidget {
  final String shopId;
  const ActivationChecklistCard({super.key, required this.shopId});

  @override
  State<ActivationChecklistCard> createState() =>
      _ActivationChecklistCardState();
}

class _ActivationChecklistCardState
    extends State<ActivationChecklistCard> {
  static const _kInvite = 'invite_member';
  static const _kWeb    = 'web_catalogue';

  bool? _inviteDone;
  bool? _webDone;

  @override
  void initState() {
    super.initState();
    _loadManualFlags();
  }

  Future<void> _loadManualFlags() async {
    final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    final inv = await OnboardingPrefs.isChecklistStepDone(uid, _kInvite);
    final web = await OnboardingPrefs.isChecklistStepDone(uid, _kWeb);
    if (!mounted) return;
    setState(() {
      _inviteDone = inv;
      _webDone    = web;
    });
  }

  Future<void> _toggleManual(String key, bool current) async {
    final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    if (!current) {
      // Cochage manuel : on persiste. Pas de "uncheck" possible —
      // cohérent avec une checklist de premiers pas, pas un to-do.
      await OnboardingPrefs.markChecklistStepDone(uid, key);
    }
    if (!mounted) return;
    setState(() {
      if (key == _kInvite) _inviteDone = true;
      if (key == _kWeb)    _webDone    = true;
    });
  }

  bool get _addProductDone {
    try {
      return AppDatabase.getProductsForShop(widget.shopId).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool get _firstSaleDone {
    try {
      // Lecture directe Hive — pas besoin de getOrders complet, on
      // s'arrête à la 1ʳᵉ commande completed trouvée.
      for (final raw in HiveBoxes.ordersBox.values) {
        final m = Map<String, dynamic>.from(raw);
        if (m['shop_id'] != widget.shopId) continue;
        if (m['deleted_at'] != null)       continue;
        if ((m['status'] as String?) == 'completed') return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Tant que les flags manuels sont en cours de lecture, on ne rend
    // rien — évite un flash "tout coché par défaut" avant l'init.
    if (_inviteDone == null || _webDone == null) {
      return const SizedBox.shrink();
    }

    final steps = <_StepSpec>[
      _StepSpec(
        title: 'Ajoutez votre premier produit',
        icon:  Icons.inventory_2_outlined,
        done:  _addProductDone,
        onTap: () => context.push(
            '/shop/${widget.shopId}/inventaire/quick-add'),
      ),
      _StepSpec(
        title: 'Invitez un vendeur',
        icon:  Icons.group_add_outlined,
        done:  _inviteDone!,
        onTap: () async {
          await _toggleManual(_kInvite, _inviteDone!);
          if (!context.mounted) return;
          context.push('/shop/${widget.shopId}/employees');
        },
      ),
      _StepSpec(
        title: 'Encaissez votre première vente',
        icon:  Icons.point_of_sale_outlined,
        done:  _firstSaleDone,
        onTap: () => context.push('/shop/${widget.shopId}/caisse'),
      ),
      _StepSpec(
        title: 'Activez votre catalogue web',
        icon:  Icons.public_outlined,
        done:  _webDone!,
        onTap: () async {
          await _toggleManual(_kWeb, _webDone!);
          if (!context.mounted) return;
          context.push('/shop/${widget.shopId}/parametres/shop');
        },
      ),
    ];

    final doneCount = steps.where((s) => s.done).length;
    // Spec : disparaît quand tout est coché.
    if (doneCount == steps.length) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header : titre + compteur ─────────────────────────────────
          Row(
            children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.rocket_launch_rounded,
                    color: AppColors.primary, size: 18),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Bienvenue — premiers pas',
                    style: AppTextStyles.subtitleBold),
              ),
              Text('$doneCount / ${steps.length}',
                  style: AppTextStyles.captionBold
                      .copyWith(color: AppColors.primary)),
            ],
          ),
          const SizedBox(height: 10),

          // ── Barre de progression ───────────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: doneCount / steps.length,
              minHeight: 5,
              backgroundColor:
                  AppColors.primary.withValues(alpha: 0.10),
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
          const SizedBox(height: 12),

          // ── Étapes ────────────────────────────────────────────────────
          ...steps.map((s) => _StepRow(spec: s)),
        ],
      ),
    );
  }
}

class _StepSpec {
  final String       title;
  final IconData     icon;
  final bool         done;
  final VoidCallback onTap;
  const _StepSpec({
    required this.title,
    required this.icon,
    required this.done,
    required this.onTap,
  });
}

class _StepRow extends StatelessWidget {
  final _StepSpec spec;
  const _StepRow({required this.spec});

  @override
  Widget build(BuildContext context) {
    final iconColor = spec.done
        ? AppColors.secondary
        : AppColors.textSecondary;
    return InkWell(
      onTap: spec.onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(
              spec.done
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: iconColor,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                spec.title,
                style: AppTextStyles.body.copyWith(
                  decoration: spec.done
                      ? TextDecoration.lineThrough
                      : null,
                  color: spec.done
                      ? AppColors.textSecondary
                      : AppColors.textPrimary,
                ),
              ),
            ),
            if (!spec.done)
              const Icon(Icons.arrow_forward_ios_rounded,
                  color: AppColors.textHint, size: 14),
          ],
        ),
      ),
    );
  }
}
