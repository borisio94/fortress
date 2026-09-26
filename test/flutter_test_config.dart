// LA POLICE DE L'APP DANS TOUS LES TESTS (26/09/2026).
//
// `flutter test` exécute ce fichier avant chaque fichier de test du dossier :
// aucun banc ne peut l'oublier, ceux d'aujourd'hui comme ceux de demain.
//
// Sans lui, les tests dessinent le texte avec la police de test de Flutter,
// qui fait de chaque caractère un CARRÉ de la taille de la police : les
// LARGEURS y sont gonflées de ~40 % (« 4 500 FCFA » : 134 px au lieu de 78 en
// Inter). Une ligne qui tient dans l'app y débordait, et un débordement
// « constaté en production » s'est révélé n'exister que dans le test.
//
// Inter est la police de l'app (`pubspec.yaml`, `AppTheme` : `fontFamily:
// 'Inter'`), embarquée pour un rendu identique partout : c'est elle qu'on
// mesure. Les cinq graisses déclarées sont chargées.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final inter = FontLoader('Inter');
  for (final weight in [400, 500, 600, 700, 800]) {
    final bytes = File('assets/fonts/Inter-$weight.ttf').readAsBytesSync();
    inter.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await inter.load();
  await testMain();
}
