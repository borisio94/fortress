import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  static Future<String?> open(BuildContext context) =>
      Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const BarcodeScannerPage()),
      );

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
