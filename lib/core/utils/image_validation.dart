import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../i18n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Résultat d'une validation + ré-encodage d'image produit.
///
/// Quand `isValid` est `true`, `bytes` contient un PNG fraîchement encodé
/// à partir du décodage du fichier source (transparence préservée). Sinon,
/// `errorMessage` contient la raison du rejet (déjà affichée via SnackBar
/// au sein de [validateAndReadImage], pas besoin de la re-router à l'UI).
class ImageValidationResult {
  final Uint8List? bytes;
  final int width;
  final int height;
  final String? errorMessage;
  final String mimeType;

  const ImageValidationResult._({
    this.bytes,
    this.width = 0,
    this.height = 0,
    this.errorMessage,
    this.mimeType = 'image/png',
  });

  bool get isValid => bytes != null && errorMessage == null;
}

/// Lit l'[xFile] pické par `image_picker`, valide le format et la
/// résolution source, redimensionne au plus grand côté [maxOutputSize]
/// (préservation du ratio) et ré-encode en PNG lossless.
///
/// Choix design — PNG strict :
///   - canal alpha préservé (fond transparent indispensable pour les
///     photos produit mode/luxe affichées sur le fond du thème) ;
///   - pas de re-compression destructive comme `image_picker` peut le
///     faire sur web (où `maxWidth`/`imageQuality` sont parfois ignorés
///     ou forcent une conversion JPEG silencieuse).
///
/// Affiche un SnackBar d'erreur via `theme.semantic.danger` si la source
/// est non décodable ou trop petite. L'appelant n'a qu'à check
/// [ImageValidationResult.isValid] et bail si false.
Future<ImageValidationResult> validateAndReadImage(
  XFile xFile,
  BuildContext context, {
  int minWidth = 200,
  int minHeight = 200,
  int maxOutputSize = 2048,
  // Rectangles ACCEPTÉS (demande utilisateur). L'affichage produit utilise
  // `BoxFit.cover` → une image non carrée est recadrée au centre (jamais
  // déformée). Passer `true` uniquement si un contexte précis exige le 1:1.
  bool requireSquare = false,
}) async {
  final rawBytes = await xFile.readAsBytes();
  final decoded = img.decodeImage(rawBytes);

  if (decoded == null) {
    if (!context.mounted) {
      return const ImageValidationResult._(errorMessage: 'invalid');
    }
    final l = context.l10n.imageFormatInvalid;
    _showError(context, l);
    return ImageValidationResult._(errorMessage: l);
  }

  final srcW = decoded.width;
  final srcH = decoded.height;
  debugPrint(
      '[ImageValidation] source ${srcW}x$srcH, '
      '${(rawBytes.length / 1024).toStringAsFixed(0)} Ko');

  if (srcW < minWidth || srcH < minHeight) {
    if (!context.mounted) {
      return ImageValidationResult._(
          width: srcW, height: srcH, errorMessage: 'too small');
    }
    final l = context.l10n.imageTooSmall(srcW, srcH);
    _showError(context, l, durationSeconds: 5);
    return ImageValidationResult._(
        width: srcW, height: srcH, errorMessage: l);
  }

  // Vérification ratio 1:1 strict. La grille produit + les cards mode
  // dépendent d'un ratio carré : une image rectangulaire serait soit
  // déformée, soit recadrée arbitrairement → on rejette à la source
  // pour forcer le user à fournir une image déjà carrée.
  if (requireSquare && srcW != srcH) {
    if (!context.mounted) {
      return ImageValidationResult._(
          width: srcW, height: srcH, errorMessage: 'not square');
    }
    final l = context.l10n.imageNotSquare(srcW, srcH);
    _showError(context, l, durationSeconds: 5);
    return ImageValidationResult._(
        width: srcW, height: srcH, errorMessage: l);
  }

  var resized = decoded;
  if (srcW > maxOutputSize || srcH > maxOutputSize) {
    resized = srcW >= srcH
        ? img.copyResize(decoded,
            width: maxOutputSize, interpolation: img.Interpolation.average)
        : img.copyResize(decoded,
            height: maxOutputSize, interpolation: img.Interpolation.average);
  }

  // level 6 = bon compromis taille/CPU. level 9 gagne ~3-5% pour 2-3× le
  // temps d'encodage — pas la peine sur web où chaque ms compte côté UX.
  final pngBytes = Uint8List.fromList(img.encodePng(resized, level: 6));
  debugPrint(
      '[ImageValidation] output ${resized.width}x${resized.height}, '
      '${(pngBytes.length / 1024).toStringAsFixed(0)} Ko PNG');

  return ImageValidationResult._(
    bytes: pngBytes,
    width: resized.width,
    height: resized.height,
    mimeType: 'image/png',
  );
}

void _showError(BuildContext context, String message,
    {int durationSeconds = 4}) {
  final theme = Theme.of(context);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: theme.semantic.danger,
    duration: Duration(seconds: durationSeconds),
  ));
}
