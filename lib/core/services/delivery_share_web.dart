// Implémentation WEB du partage de fiche livraison.
//
// Stratégie (cf. demande utilisateur : web-only, envoi dans un GROUPE
// WhatsApp, qui n'est pas adressable par lien) :
//   1. Copier l'IMAGE dans le presse-papier via l'API navigateur
//      `navigator.clipboard.write([ClipboardItem({'image/png': blob})])`.
//      L'utilisateur ouvre son groupe et fait Coller (Ctrl+V). C'est la
//      seule voie fiable pour atteindre un groupe depuis un navigateur.
//   2. Repli si le navigateur refuse la copie image (Safari/Firefox,
//      contexte non sécurisé, geste perdu…) : TÉLÉCHARGER l'image.
//
// `clipboard.write` exige un contexte sécurisé (HTTPS) + un geste
// utilisateur récent. Le caller pré-génère l'image pour que l'appel suive
// le clic au plus près.

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'delivery_share_outcome.dart';

Future<DeliveryShareOutcome> shareDeliveryImage(
  Uint8List bytes,
  String filename, {
  bool isImage = true,
}) async {
  // 1. Copie presse-papier (image uniquement — un PDF n'est pas collable
  //    comme image dans WhatsApp).
  if (isImage && await _copyImageToClipboard(bytes)) {
    return DeliveryShareOutcome.copied;
  }
  // 2. Repli : téléchargement.
  if (_downloadBytes(bytes, filename, isImage)) {
    return DeliveryShareOutcome.downloaded;
  }
  return DeliveryShareOutcome.failed;
}

Future<bool> _copyImageToClipboard(Uint8List png) async {
  try {
    final clipboard = web.window.navigator.clipboard;
    final blob = web.Blob(
      <JSAny>[png.toJS].toJS,
      web.BlobPropertyBag(type: 'image/png'),
    );
    // new ClipboardItem({ 'image/png': blob })
    final items = <String, JSAny>{'image/png': blob}.jsify() as JSObject;
    final item = web.ClipboardItem(items);
    await clipboard.write(<web.ClipboardItem>[item].toJS).toDart;
    return true;
  } catch (_) {
    return false;
  }
}

bool _downloadBytes(Uint8List bytes, String filename, bool isImage) {
  try {
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: isImage ? 'image/png' : 'application/pdf'),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
    return true;
  } catch (_) {
    return false;
  }
}
