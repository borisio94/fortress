import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'app_snack.dart';

/// Lecture d'un code-barres à la caméra, en plein écran.
///
/// PARTAGÉE, et c'est le point : la fiche produit s'en sert pour renseigner
/// le code d'une variante, la feuille d'arrivage pour retrouver un article
/// déjà au catalogue sans le chercher au clavier. Le même geste doit se
/// comporter pareil des deux côtés ; une seconde copie privée aurait
/// divergé au premier correctif.
///
/// Renvoie le code lu, ou `null` si l'écran est quitté sans rien lire.
class BarcodeScannerPage extends StatefulWidget {
  const BarcodeScannerPage({super.key});

  /// Ouvre le scanner et renvoie le code lu. `null` = abandon.
  ///
  /// SUR WEB, ON N'OUVRE RIEN. `mobile_scanner` n'a pas d'implémentation
  /// web : le canal natif est absent, l'appel lève une MissingPluginException
  /// et l'utilisateur se retrouvait devant un écran noir, sans un mot. Mieux
  /// vaut le dire que de l'y envoyer.
  ///
  /// La garde vit ICI et non chez les appelants : le widget est partagé, et
  /// la placer à la source couvre aussi les appels à venir.
  static Future<String?> open(BuildContext context) async {
    if (kIsWeb) {
      AppSnack.info(context, 'Scanner disponible sur l\'application mobile');
      return null;
    }
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const BarcodeScannerPage()),
    );
  }

  @override
  State<BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends State<BarcodeScannerPage> {
  /// Le détecteur émet en rafale tant que le code reste dans le cadre : sans
  /// ce verrou, une seule lecture dépilerait l'écran plusieurs fois.
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Scanner le code-barres'),
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    ),
    backgroundColor: Colors.black,
    body: MobileScanner(
      onDetect: (capture) {
        if (_done) return;
        // Pas de `firstOrNull` : c'est une extension de `package:collection`,
        // qui n'arrive ici par aucun import. Un test explicite ne dépend de
        // rien.
        if (capture.barcodes.isEmpty) return;
        final code = capture.barcodes.first.rawValue;
        if (code == null || code.trim().isEmpty) return;
        _done = true;
        Navigator.of(context).pop(code.trim());
      },
    ),
  );
}
