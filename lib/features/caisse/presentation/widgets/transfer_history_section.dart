import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/link.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../data/repositories/delivery_transfer_repository.dart';
import '../../domain/entities/delivery_transfer.dart';

/// Affiche, sous la fiche d'une commande, l'historique des transferts
/// WhatsApp effectués vers les livreurs. Lecture-seule mais permet de
/// **renvoyer** le même message au même destinataire (rouvre wa.me avec
/// le snapshot — n'insère pas de nouveau row dans `delivery_transfers`).
class TransferHistorySection extends ConsumerWidget {
  final String orderId;
  const TransferHistorySection({super.key, required this.orderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final asyncList = ref.watch(orderDeliveryTransfersProvider(orderId));
    return asyncList.when(
      loading: () => const SizedBox(
        height: 24,
        child: Center(child:
            SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5))),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(e.toString(),
            style: AppTextStyles.micro.copyWith(color: AppColors.error)),
      ),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Row(children: [
              Icon(Icons.history_rounded,
                  size: 12, color: AppColors.textHint),
              const SizedBox(width: 4),
              Text(l.deliveryHistoryTitle.toUpperCase(),
                  style: AppTextStyles.microBold.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: AppColors.textHint)),
            ]),
            const SizedBox(height: 6),
            for (final t in list) _TransferTile(transfer: t),
          ]),
        );
      },
    );
  }
}

class _TransferTile extends StatelessWidget {
  final DeliveryTransfer transfer;
  const _TransferTile({required this.transfer});

  bool get _isGroup => (transfer.targetGroupUrl ?? '').isNotEmpty;

  /// Mode 1-à-1 : wa.me/<phone>?text=<snapshot>.
  /// Mode groupe : ouvre directement le lien d'invitation (le snapshot est
  /// copié dans le presse-papiers en parallèle par le bouton).
  Uri _buildUri() {
    if (_isGroup) return Uri.parse(transfer.targetGroupUrl!);
    final digits = (transfer.targetPhone ?? '')
        .replaceAll(RegExp(r'[^\d]'), '');
    return Uri.parse('https://wa.me/$digits'
        '?text=${Uri.encodeComponent(transfer.messageSnapshot)}');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final uri = _buildUri();
    final identity = _isGroup
        ? 'Groupe WhatsApp'
        : (transfer.targetPhone ?? '');
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(children: [
        Icon(_isGroup ? Icons.group_rounded : _iconFor(transfer.targetType),
            size: 12, color: AppColors.primary),
        const SizedBox(width: 6),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${transfer.targetName} · $identity',
                style: AppTextStyles.captionBold,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(_formatDateTime(transfer.createdAt),
                style: AppTextStyles.micro
                    .copyWith(color: const Color(0xFF9CA3AF))),
          ],
        )),
        Link(
          uri: uri,
          target: LinkTarget.blank,
          builder: (ctx, follow) => OutlinedButton.icon(
            onPressed: () async {
              // En mode groupe on copie aussi le snapshot pour rappel.
              if (_isGroup) {
                await Clipboard.setData(
                    ClipboardData(text: transfer.messageSnapshot));
              }
              if (!kIsWeb && follow != null) follow();
            },
            icon: const Icon(Icons.send_rounded, size: 11),
            label: Text(l.deliveryResendBtn,
                style: AppTextStyles.micro
                    .copyWith(color: const Color(0xFF25D366))),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF25D366),
              side: const BorderSide(color: Color(0xFF25D366)),
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
            ),
          ),
        ),
      ]),
    );
  }

  IconData _iconFor(DeliveryTargetType t) => switch (t) {
        DeliveryTargetType.partner  => Icons.store_rounded,
        DeliveryTargetType.employee => Icons.person_rounded,
        DeliveryTargetType.free     => Icons.dialpad_rounded,
      };

  String _formatDateTime(DateTime d) {
    const days   = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    const months = ['jan', 'fév', 'mar', 'avr', 'mai', 'juin',
                    'juil', 'août', 'sep', 'oct', 'nov', 'déc'];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]} · $h:$m';
  }
}
