// Préparation au mode sombre.
//
// Deux garde-fous :
//   1. Les jetons sémantiques diffèrent réellement entre clair et sombre —
//      sans quoi basculer le thème ne changerait rien.
//   2. Les widgets PARTAGÉS ne contiennent plus de surface claire codée en
//      dur. Ils sont utilisés par presque tous les écrans : une régression
//      ici se voit partout, et elle est invisible en mode clair — donc
//      indétectable au coup d'œil pendant le développement.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_theme.dart';

void main() {
  group('Jetons sémantiques — clair vs sombre', () {
    test('les surfaces changent réellement entre les deux modes', () {
      const light = AppSemanticColors.light;
      const dark = AppSemanticColors.dark;
      expect(light.elevatedSurface, isNot(dark.elevatedSurface));
      expect(light.borderSubtle, isNot(dark.borderSubtle));
      expect(light.trackMuted, isNot(dark.trackMuted));
    });

    test('les couleurs de statut restent distinctes dans les deux modes', () {
      for (final s in [AppSemanticColors.light, AppSemanticColors.dark]) {
        expect(s.success, isNot(s.danger));
        expect(s.warning, isNot(s.info));
      }
    });

    test('la surface sombre est bien plus foncée que la claire', () {
      // Garde-fou de bon sens : si quelqu'un recopie les valeurs claires
      // dans le thème sombre, le test le voit.
      final lightLum =
          AppSemanticColors.light.elevatedSurface.computeLuminance();
      final darkLum =
          AppSemanticColors.dark.elevatedSurface.computeLuminance();
      expect(darkLum, lessThan(lightLum));
    });
  });

  group('Widgets partagés — aucune surface claire en dur', () {
    // Motifs qui produisent une tache blanche sur fond sombre. Le blanc
    // utilisé en PREMIER PLAN (texte ou icône sur un fond coloré) est
    // légitime dans les deux modes et volontairement exclu.
    final surfacePatterns = <RegExp>[
      RegExp(r'Color\(0xFFF9FAFB\)'),
      RegExp(r'Color\(0xFFF3F4F6\)'),
      RegExp(r'Color\(0xFFE5E7EB\)'),
      RegExp(r'backgroundColor:\s*Colors\.white'),
      RegExp(r'fillColor:\s*Colors\.white'),
    ];

    test('lib/shared/widgets est propre', () {
      final dir = Directory('lib/shared/widgets');
      if (!dir.existsSync()) {
        markTestSkipped('Répertoire absent — test lancé hors racine projet.');
        return;
      }

      final offenders = <String>[];
      for (final f in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          for (final p in surfacePatterns) {
            if (p.hasMatch(lines[i])) {
              offenders.add('${f.path}:${i + 1} → ${lines[i].trim()}');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Surfaces claires codées en dur dans les widgets partagés.\n'
            'Utilisez AppColors.inputFill / inputBorder / divider / surface '
            '(résolus selon le brightness) ou theme.semantic.*.\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
