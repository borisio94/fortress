import 'package:flutter/material.dart';

import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../data/onboarding_prefs.dart';

/// Bannière « Hier : X ventes · Y FCFA » affichée 1×/jour en haut du
/// dashboard (point 9 de l'onboarding spec).
///
/// Comportement
/// ────────────
///   • Au mount : check `wasJ1BannerShownToday()` — si vrai, render
///     `SizedBox.shrink()` (déjà vue aujourd'hui).
///   • Sinon : calcule les ventes complétées de J-1 depuis Hive.
///     Si 0 vente → render vide (l'utilisateur n'a rien fait hier, pas
///     besoin d'auto-célébration vide).
///   • Sinon affiche le résumé + bouton de fermeture qui marque le
///     flag du jour.
///
/// Implémentation 100% Hive, aucun fetch réseau — la bannière apparaît
/// même en offline-only.
class J1ResumeBanner extends StatefulWidget {
  final String shopId;
  const J1ResumeBanner({super.key, required this.shopId});

  @override
  State<J1ResumeBanner> createState() => _J1ResumeBannerState();
}

class _J1ResumeBannerState extends State<J1ResumeBanner> {
  bool? _shownToday;
  int    _yesterdayCount  = 0;
  double _yesterdayAmount = 0;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final shown = await OnboardingPrefs.wasJ1BannerShownToday();
    int    count  = 0;
    double amount = 0;
    if (!shown) {
      // Périmètre J-1 : entre minuit hier et minuit aujourd'hui (heure locale).
      final now      = DateTime.now();
      final today    = DateTime(now.year, now.month, now.day);
      final yStart   = today.subtract(const Duration(days: 1));
      final yEnd     = today;
      try {
        for (final raw in HiveBoxes.ordersBox.values) {
          final m = Map<String, dynamic>.from(raw);
          if (m['shop_id'] != widget.shopId) continue;
          if (m['deleted_at'] != null)       continue;
          if ((m['status'] as String?) != 'completed') continue;
          final completedAtStr =
              (m['completed_at'] ?? m['created_at']) as String?;
          if (completedAtStr == null) continue;
          final completedAt = DateTime.tryParse(completedAtStr)?.toLocal();
          if (completedAt == null) continue;
          if (completedAt.isBefore(yStart)) continue;
          if (!completedAt.isBefore(yEnd))  continue;
          count++;
          // Recalcul du total — la table orders ne stocke pas total,
          // donc on somme depuis items (cohérent avec le dashboard).
          final items    = (m['items'] as List?) ?? const [];
          double subtotal = 0;
          for (final it in items) {
            try {
              final mm    = Map<String, dynamic>.from(it as Map);
              final qty   = (mm['quantity'] as num?)?.toInt() ?? 0;
              final price = (mm['custom_price'] as num?)?.toDouble()
                  ?? (mm['unit_price'] as num?)?.toDouble() ?? 0;
              subtotal += qty * price;
            } catch (_) {}
          }
          final discount = (m['discount_amount'] as num?)?.toDouble() ?? 0;
          final taxRate  = (m['tax_rate']        as num?)?.toDouble() ?? 0;
          final taxable  = (subtotal - discount).clamp(0, double.infinity);
          amount += subtotal - discount + taxable * (taxRate / 100);
        }
      } catch (_) {/* hive pas prêt — banner masquée */}
    }
    if (!mounted) return;
    setState(() {
      _shownToday      = shown;
      _yesterdayCount  = count;
      _yesterdayAmount = amount;
    });
  }

  Future<void> _dismiss() async {
    await OnboardingPrefs.markJ1BannerShownToday();
    if (!mounted) return;
    setState(() => _shownToday = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_shownToday == null)      return const SizedBox.shrink();
    if (_shownToday!)             return const SizedBox.shrink();
    if (_yesterdayCount == 0)     return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
          colors: [
            AppColors.secondary.withValues(alpha: 0.18),
            AppColors.secondary.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: AppColors.secondary.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Icons.trending_up_rounded,
                color: AppColors.secondary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Hier : $_yesterdayCount vente'
                      '${_yesterdayCount > 1 ? "s" : ""} · '
                      '${CurrencyFormatter.format(_yesterdayAmount)}',
                  style: AppTextStyles.bodyBold,
                ),
                const SizedBox(height: 2),
                Text('Continuez sur cette lancée !',
                    style: AppTextStyles.bodySmSecondary),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Fermer',
            icon: Icon(Icons.close_rounded,
                color: AppColors.textSecondary, size: 18),
            onPressed: _dismiss,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
