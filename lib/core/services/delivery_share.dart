import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

import 'delivery_share_outcome.dart';

/// Implémentation NON-web (mobile / desktop natif).
///
/// Le presse-papier image n'est pas universel hors navigateur, donc on
/// retombe sur le partage natif (`share_plus`) : l'utilisateur choisit
/// WhatsApp puis le groupe. La version web (copie presse-papier + repli
/// téléchargement) est dans `delivery_share_web.dart`, sélectionnée par
/// import conditionnel `if (dart.library.html)`.
Future<DeliveryShareOutcome> shareDeliveryImage(
  Uint8List bytes,
  String filename, {
  bool isImage = true,
}) async {
  try {
    await Share.shareXFiles([
      XFile.fromData(
        bytes,
        name: filename,
        mimeType: isImage ? 'image/png' : 'application/pdf',
      ),
    ]);
    return DeliveryShareOutcome.shared;
  } catch (_) {
    return DeliveryShareOutcome.failed;
  }
}
