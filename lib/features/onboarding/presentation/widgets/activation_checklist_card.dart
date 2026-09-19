import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';

/// Checklist d'activation (premiers pas) affichée en haut du dashboard tant
/// que toutes les étapes ne sont pas complétées. Disparaît automatiquement
/// quand tout est coché.
///
/// Étapes (toutes AUTO, recalculées à chaque build depuis Hive)
/// ────────────────────────────────────────────────────────────
///   1. Ajouter un produit  — auto si `getProductsForShop().isNotEmpty`
///   2. Première vente       — auto si ≥ 1 commande status='completed'
///
/// (Les anciennes étapes manuelles « Invitez un vendeur » et « Activez votre
///  catalogue web » ont été retirées à la demande — plus de flags manuels.)
class ActivationChecklistCard extends StatelessWidget {
  final String shopId;
  const ActivationChecklistCard({super.key, required this.shopId});

  bool get _addProductDone {
    try {
      return AppDatabase.getProductsForShop(shopId).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool get _firstSaleDone {
    try {
      // Lecture directe Hive — on s'arrête à la 1ʳᵉ commande completed.
      for (final raw in HiveBoxes.ordersBox.values) {
        final m = Map<String, dynamic>.from(raw);
        if (m['shop_id'] != shopId) continue;
        if (m['deleted_at'] != null) continue;
        if ((m['status'] as String?) == 'completed') return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = <_StepSpec>[
      _StepSpec(
        title: 'Ajoutez votre premier produit',
        done:  _addProductDone,
        onTap: () => context.push(
            '/shop/$shopId/inventaire/quick-add'),
      ),
      _StepSpec(
        title: 'Encaissez votre première vente',
        done:  _firstSaleDone,
        onTap: () => context.push('/shop/$shopId/caisse'),
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
  final bool         done;
  final VoidCallback onTap;
  const _StepSpec({
    required this.title,
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
              Icon(Icons.arrow_forward_ios_rounded,
                  color: AppColors.textHint, size: 14),
          ],
        ),
      ),
    );
  }
}
