import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Réponse de l'utilisateur face à une suppression bloquée.
enum BlockedDeleteChoice { cancel, archive }

/// Affiche un dialogue qui informe l'utilisateur qu'une suppression est
/// impossible (entité utilisée ailleurs) et lui propose de l'archiver à la
/// place. Retourne le choix de l'utilisateur.
///
/// - [reason]    : texte explicatif (ce qui empêche la suppression).
/// - [itemLabel] : nom de l'entité (ex: "Jean Dupont", "T-Shirt Bleu").
/// - [archiveDescription] : ce que signifie archiver dans ce contexte
///   (ex: "masqué des listes, historique préservé").
Future<BlockedDeleteChoice?> showBlockedDeleteDialog(
    BuildContext context, {
    required String itemLabel,
    required String reason,
    String archiveDescription =
        'L\'élément sera masqué des listes mais son historique sera préservé.',
}) {
  return showDialog<BlockedDeleteChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      title: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.warning.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.warning_amber_rounded,
              size: 18, color: AppColors.warning),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Suppression impossible',
              style: TextStyle(fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A))),
        ),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('« $itemLabel »',
              style: const TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F172A))),
          const SizedBox(height: 6),
          Text(reason,
              style: const TextStyle(fontSize: 12,
                  color: Color(0xFF6B7280))),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.primary.withOpacity(0.20)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.archive_outlined,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Archiver à la place ?',
                        style: TextStyle(fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary)),
                    const SizedBox(height: 2),
                    Text(archiveDescription,
                        style: const TextStyle(fontSize: 11,
                            height: 1.35, color: Color(0xFF6B7280))),
                  ],
                ),
              ),
            ]),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(ctx).pop(BlockedDeleteChoice.cancel),
          child: const Text('Annuler'),
        ),
        ElevatedButton.icon(
          onPressed: () =>
              Navigator.of(ctx).pop(BlockedDeleteChoice.archive),
          icon: const Icon(Icons.archive_outlined, size: 16),
          label: const Text('Archiver'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ],
    ),
  );
}
