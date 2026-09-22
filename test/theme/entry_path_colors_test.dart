// Les écrans d'entrée échappaient aux palettes.
//
// Pendant de `dark_readiness_test`, qui garde `lib/shared/widgets`. Le
// parcours d'entrée — connexion, mot de passe oublié, création de boutique —
// n'était gardé par rien, alors que c'est le premier écran que voit un
// commerçant et que ses couleurs en dur ignorent les huit palettes comme le
// mode sombre.
//
// CE QUE L'AUDIT DISAIT, ET QUI ÉTAIT FAUX : « 46 Colors. et 11 Color(0x ».
// Le compte confondait `Colors.` et `AppColors.` — un `grep -c 'Colors\.'`
// attrape les deux. Le vrai chiffre était SEIZE, dont trois qui n'étaient pas
// le même défaut : les couleurs d'identité des secteurs, parties depuis dans
// `kSectorColors`. Ces écrans étaient déjà largement tokenisés.
//
// Ce test compte JUSTE, lui : il exige zéro couleur brute, et son message
// d'échec nomme chaque ligne fautive.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Parcours d\'entrée — aucune couleur en dur', () {
    // Les trois écrans par lesquels on entre dans l'application. Le premier
    // contact d'un commerçant, et le seul endroit où une palette mal
    // appliquée se voit avant même qu'il ait un compte.
    const files = <String>[
      'lib/features/auth/presentation/pages/login_page.dart',
      'lib/features/auth/presentation/pages/forgot_password_page.dart',
      'lib/features/shop_selector/presentation/pages/create_shop_page.dart',
    ];

    // `Colors.` précédé d'un caractère non alphabétique — sans quoi on
    // attraperait `AppColors.`, qui est précisément ce qu'on veut voir.
    // C'est l'erreur qui avait gonflé le chiffre de l'audit.
    final raw = <RegExp>[
      RegExp(r'(^|[^A-Za-z])Colors\.'),
      RegExp(r'Color\(0x'),
    ];

    test('les trois écrans n\'en portent plus aucune', () {
      final offenders = <String>[];
      for (final path in files) {
        final f = File(path);
        if (!f.existsSync()) {
          markTestSkipped('$path absent — test lancé hors racine projet.');
          return;
        }
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // Les commentaires sont exclus : l'un d'eux CITE `Color(0xFF…)`
          // pour affirmer que le fichier n'en contient pas, et il aurait
          // fait échouer le test qu'il décrit.
          if (line.trimLeft().startsWith('//')) continue;
          for (final p in raw) {
            if (p.hasMatch(line)) {
              offenders.add('$path:${i + 1} → ${line.trim()}');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Couleurs en dur sur le parcours d\'entrée.\n'
            'Utilisez AppColors.* ou Theme.of(context).semantic.* — les huit '
            'palettes et le mode sombre les résolvent, pas une constante.\n'
            'Pour une couleur d\'IDENTITÉ (secteur, marque), nommez-la dans '
            'une constante partagée plutôt que de l\'écrire ici.\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
