import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../providers/broadcasts_provider.dart';

/// Bannière(s) de réception des broadcasts super-admin (SA-5) côté client.
/// Affiche chaque message non lu ciblant la boutique courante ; le bouton
/// fermer marque le message comme vu (local) et ne le ré-affiche plus.
class BroadcastBanner extends ConsumerWidget {
  final String shopId;
  const BroadcastBanner({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(unreadBroadcastsProvider(shopId));
    final list = async.valueOrNull ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final b in list)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _BroadcastCard(
              message: b,
              onDismiss: () async {
                await BroadcastSeenStore.markSeen(b.id);
                ref.invalidate(unreadBroadcastsProvider(shopId));
              },
            ),
          ),
      ],
    );
  }
}

class _BroadcastCard extends StatelessWidget {
  final BroadcastMessage message;
  final VoidCallback onDismiss;
  const _BroadcastCard({required this.message, required this.onDismiss});

  ({Color color, IconData icon}) get _style => switch (message.type) {
        'warning'     => (color: AppColors.warning, icon: Icons.warning_amber_rounded),
        'maintenance' => (color: const Color(0xFF8B5CF6), icon: Icons.build_circle_rounded),
        _             => (color: AppColors.info, icon: Icons.campaign_rounded),
      };

  @override
  Widget build(BuildContext context) {
    final s = _style;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: s.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: s.color.withValues(alpha: 0.30)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(s.icon, color: s.color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(message.title,
                style: AppTextStyles.bodyBold.copyWith(color: s.color)),
            if (message.body.trim().isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(message.body,
                  style: AppTextStyles.bodySm.copyWith(
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.8))),
            ],
          ]),
        ),
        const SizedBox(width: 6),
        InkWell(
          onTap: onDismiss,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(Icons.close_rounded, size: 18,
                color: s.color.withValues(alpha: 0.7)),
          ),
        ),
      ]),
    );
  }
}
