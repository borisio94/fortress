import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import 'form_sheet.dart';

/// Réponse de l'utilisateur face à une suppression bloquée.
enum BlockedDeleteChoice { cancel, archive }

/// Affiche un bottom sheet qui informe l'utilisateur qu'une suppression est
/// impossible (entité utilisée ailleurs) et lui propose de l'archiver à la
/// place. Retourne le choix de l'utilisateur.
///
/// (Refonte UX : était un AlertDialog → maintenant un FormSheet verrouillé
/// avec bouton X intégré.)
///
/// - [reason]    : texte explicatif (ce qui empêche la suppression).
/// - [itemLabel] : nom de l'entité (ex: "Jean Dupont", "T-Shirt Bleu").
/// - [archiveDescription] : ce que signifie archiver dans ce contexte.
Future<BlockedDeleteChoice?> showBlockedDeleteDialog(
    BuildContext context, {
    required String itemLabel,
    required String reason,
    String archiveDescription =
        'L\'élément sera masqué des listes mais son historique sera préservé.',
}) {
  return showFormSheet<BlockedDeleteChoice>(
    context: context,
    builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      return Padding(
        padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FormSheetHeader(
                title: 'Suppression impossible',
                icon: Icons.warning_amber_rounded,
                iconColor: AppColors.warning,
              ),
              const Divider(height: 1, color: Color(0xFFF0F0F0)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('« $itemLabel »',
                        style: AppTextStyles.bodyBold.copyWith(
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF0F172A))),
                    const SizedBox(height: 6),
                    Text(reason,
                        style: AppTextStyles.bodySmSecondary.copyWith(
                            color: const Color(0xFF6B7280))),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppColors.primary
                                .withValues(alpha: 0.20)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.archive_outlined,
                              size: 14, color: AppColors.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text('Archiver à la place ?',
                                    style: AppTextStyles.bodySm.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primary)),
                                const SizedBox(height: 2),
                                Text(archiveDescription,
                                    style: AppTextStyles.caption.copyWith(
                                        color: const Color(0xFF6B7280))),
                              ],
                            ),
                          ),
                        ],
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
                      onPressed: () => Navigator.of(ctx)
                          .pop(BlockedDeleteChoice.cancel),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                      child: const Text('Annuler'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.of(ctx)
                          .pop(BlockedDeleteChoice.archive),
                      icon:
                          const Icon(Icons.archive_outlined, size: 16),
                      label: const Text('Archiver'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      );
    },
  );
}
