import 'package:flutter/material.dart';

import '../../core/services/pending_image_upload_service.dart';
import '../../core/theme/app_colors.dart';

/// Pastille d'état d'envoi d'image, à poser dans un `Stack` au-dessus d'une
/// vignette produit.
///
/// L'envoi des photos est différé : la fiche se ferme aussitôt enregistrée et
/// l'image part en arrière-plan, parfois longtemps après sur une connexion
/// lente. Sans ce repère, l'utilisateur voyait une vignette vide sans savoir
/// si son image était perdue ou simplement en route.
///
/// S'abonne à la révision de la file : la pastille disparaît d'elle-même une
/// fois l'image partie, sans qu'il faille recharger l'écran.
///
/// Rien n'est affiché quand il n'y a pas d'envoi en cours — le widget peut
/// donc rester en place sans condition côté appelant.
class UploadStatusDot extends StatelessWidget {
  final String? productId;

  /// Côté de la pastille. 16 convient à une vignette de 34, 18 à partir de 64.
  final double size;

  const UploadStatusDot({super.key, required this.productId, this.size = 16});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: PendingImageUploadService.rev,
    builder: (_, __, ___) {
      if (!PendingImageUploadService.hasPendingFor(productId)) {
        return const SizedBox.shrink();
      }
      final failed = PendingImageUploadService.hasFailedFor(productId);
      // En échec : la pastille devient un bouton de reprise. La file n'est
      // pas indexée par produit et le worker traite tout d'un bloc, donc on
      // relance l'ensemble — ce qui revient au même pour l'utilisateur.
      return Tooltip(
        message: failed
            ? 'Envoi de l\'image interrompu — toucher pour réessayer'
            : 'Image en cours d\'envoi',
        child: GestureDetector(
          onTap: failed ? () => PendingImageUploadService.flush() : null,
          child: Container(
            width: size, height: size,
            decoration: BoxDecoration(
              color: failed ? AppColors.error : Colors.black54,
              shape: BoxShape.circle,
            ),
            child: failed
                ? Icon(Icons.cloud_off_rounded,
                    size: size * 0.62, color: Colors.white)
                : Padding(
                    padding: EdgeInsets.all(size * 0.22),
                    child: const CircularProgressIndicator(
                      strokeWidth: 1.6,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
          ),
        ),
      );
    },
  );
}
