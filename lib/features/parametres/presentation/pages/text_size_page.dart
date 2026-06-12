import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/text_scale_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_scaffold.dart';

/// Réglage interactif de la taille du texte de toute l'application.
/// Le curseur redimensionne le texte EN DIRECT (l'aperçu — et toute l'app —
/// suit pendant le glissement via `textScaleProvider` observé dans PosApp).
class TextSizePage extends ConsumerWidget {
  final String? shopId;
  const TextSizePage({super.key, this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(textScaleProvider);
    final notifier = ref.read(textScaleProvider.notifier);
    // Pourcentage relatif à la taille de référence (= 100 %).
    final pct = (scale / TextScaleNotifier.referenceScale * 100).round();

    return AppScaffold(
      shopId: shopId ?? '',
      title: 'Taille du texte',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Ajustez la taille du texte de toute l\'application. '
            'L\'aperçu ci-dessous change en direct pendant que vous glissez.',
            style: AppTextStyles.bodySmSecondary,
          ),
          const SizedBox(height: 16),

          // ── Aperçu ────────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: Theme.of(context).semantic.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('APERÇU',
                    style: AppTextStyles.microBold
                        .copyWith(color: AppColors.textSecondary,
                            letterSpacing: 0.6)),
                const SizedBox(height: 10),
                Text('Boutique Étoile', style: AppTextStyles.subtitleBold),
                const SizedBox(height: 4),
                Text(
                  'Voici à quoi ressemble le texte de votre application à '
                  'cette taille : titres, descriptions et petits libellés.',
                  style: AppTextStyles.body,
                ),
                const SizedBox(height: 6),
                Text('Article · 2 500 XAF · En stock',
                    style: AppTextStyles.caption),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Curseur A− / A+ ───────────────────────────────────────────
          Row(children: [
            const Text('A', style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 16),
                ),
                child: Slider(
                  value: scale.clamp(
                      TextScaleNotifier.minScale, TextScaleNotifier.maxScale),
                  min: TextScaleNotifier.minScale,
                  max: TextScaleNotifier.maxScale,
                  divisions: 14, // pas d'environ 5 %
                  activeColor: AppColors.primary,
                  label: '$pct %',
                  onChanged: notifier.preview, // aperçu live
                  onChangeEnd: notifier.commit, // persiste au relâchement
                ),
              ),
            ),
            const Text('A', style: TextStyle(fontSize: 26, color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: 4),
          Center(
            child: Text('$pct % de la taille par défaut',
                style: AppTextStyles.bodySmSecondary),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton.icon(
              onPressed: () => notifier.reset(),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Réinitialiser (80 %)'),
              style: TextButton.styleFrom(foregroundColor: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}
